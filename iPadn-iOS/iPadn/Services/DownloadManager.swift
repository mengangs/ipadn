import Foundation
import Combine
import Network
import UserNotifications
import UIKit

/// Progress has its own publisher: a byte counter must not invalidate every list.
@MainActor
final class DownloadProgressState: ObservableObject {
    @Published var bytes: (written: Int64, expected: Int64)?
    func applying(to job: DownloadJob) -> DownloadJob {
        guard let bytes, [.running, .pausing, .paused].contains(job.status) else { return job }
        var result = job
        result.downloaded = bytes.written; result.expected = bytes.expected
        return result
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    private final class DeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func begin() { lock.lock(); count += 1; lock.unlock() }
        func end() { lock.lock(); count -= 1; lock.unlock() }
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return count == 0 }
    }
    nonisolated private let deliveries = DeliveryGate()
    static var sessionID: String {
        (Bundle.main.bundleIdentifier ?? "app.local.iPadn") + ".background.downloads"
    }
    @Published private(set) var jobs: [DownloadJob] = [] { didSet { updateInstallKeepAlive() } }
    @Published var storageError: String?
    @Published private(set) var discoveryWarning: String?
    /// The last save failed (for example, the disk is full); cleared by the next successful save.
    @Published private(set) var saveWarning: String?
    /// Stage text for Mac App Store packages being processed on device.
    @Published private(set) var processingDetail: [UUID: String] = [:]
    /// Mac tasks the user asked to cancel and that have not stopped yet.
    @Published private(set) var cancelling: Set<UUID> = []
    var backgroundCompletion: (() -> Void)?
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var rowProgress: [UUID: DownloadProgressState] = [:]
    @Published private(set) var removingIDs = Set<UUID>()
    private var loadingJobs = false
    private var startupTask: Task<Void, Never>?
    /// Returns once the saved download list has been read (Shortcuts may
    /// run before the app ever showed it).
    func loaded() async { await startupTask?.value }
    func progress(for id: UUID) -> DownloadProgressState {
        if let progress = rowProgress[id] { return progress }
        let progress = DownloadProgressState(); rowProgress[id] = progress
        return progress
    }
    private var currentJobs: [DownloadJob] { jobs.map { rowProgress[$0.id]?.applying(to: $0) ?? $0 } }
    private func accepts(_ task: URLSessionTask, id: UUID, restoredDelivery: Bool = false) -> Bool {
        guard !removingIDs.contains(id) else { return false }
        if let current = tasks[id] { return current === task }
        return restoring || restoredDelivery
    }
    private var restoring = true
    private var maxConcurrent = 3
    private var maxQueued = 10
    private var processingIDs = Set<UUID>()
    private var iconsLoading = false
    private var catalogArtworkAttempted = Set<UUID>()
    private var iconSizeChecked = Set<UUID>()
    private var olderIconRetried = Set<UUID>()
    private var removalAfterCancel = Set<UUID>()
    private let persistQueue = DispatchQueue(label: "iPadn.download-jobs", qos: .utility)
    private var artworkCountry = "CN"
    private var notifications = true
    private var compatibleDownloadMode = false
    private var fallbackForegroundIDs = Set<UUID>()
    /// Settings: download only over Wi-Fi; install each finished download.
    private var wifiOnly = false
    private var autoInstall = false
    private var pathMonitor: NWPathMonitor?
    /// The network in use is cellular (no Wi-Fi or wired connection).
    private var onCellular = false
    /// "Download Anyway" until Wi-Fi is back.
    private var cellularAllowed = false
    /// Downloads wait for Wi-Fi: the setting is on and only cellular is available.
    @Published private(set) var waitingForWiFi = false
    /// Finished downloads waiting for the install sheet to open.
    @Published var pendingAutoInstalls: [UUID] = []
    /// Install When Downloaded with native installation: no prompt is needed,
    /// so finished downloads install by themselves, also in the background.
    private var silentInstall = false
    private var silentQueue: [UUID] = []
    private var silentRunning = false { didSet { updateInstallKeepAlive() } }
    /// iOS suspends iPadn soon after it leaves the screen, which would stop the
    /// install (and the Live Activity) until iPadn is opened again. From the
    /// download to the end of its silent installation, iPadn keeps running.
    private let installKeepAlive = BackgroundKeepAlive(name: "iPadn auto install")
    private var keepingAlive = false
    /// Progress for the system's view of the keep-alive: the download up to
    /// 80 %, then the installation.
    private func autoInstallStatus() -> (fraction: Double, subtitle: String) {
        if let install = autoInstalling {
            return (0.85 + install.fraction * 0.15, AppText.text("正在自动安装 \(install.name)"))
        }
        if let job = jobs.first(where: { $0.status == .processing }) {
            return (0.8, AppText.text("正在准备 \(job.app.name)"))
        }
        let running = jobs.filter { $0.status == .running }
        guard let lead = running.first else { return (0, AppText.text("自动安装")) }
        var written: Int64 = 0, expected: Int64 = 0
        for job in running {
            let bytes = progress(for: job.id).bytes
            written += bytes?.written ?? job.downloaded
            expected += max(bytes?.expected ?? 0, job.expected, job.app.size)
        }
        let fraction = expected > 0 ? Double(written) / Double(expected) : 0
        return (fraction * 0.8, AppText.text("正在下载 \(lead.app.name)"))
    }

    private func updateInstallKeepAlive() {
        let busy = silentInstall && (silentRunning || !silentQueue.isEmpty || jobs.contains { job in
            [.running, .queued, .processing].contains(job.status)
                && job.rawFormat == nil && job.protectedMacPackage != true && job.sourceURL != nil
        })
        guard busy != keepingAlive else { return }
        keepingAlive = busy
        InstallLog.shared.add(busy ? "keeping iPadn running for the automatic install" : "automatic install keep-alive ended")
        if busy {
            installKeepAlive.start(title: AppText.text("自动安装")) { [weak self] in self?.autoInstallStatus() ?? (0, "") }
        } else {
            installKeepAlive.stop()
        }
    }
    /// A line for iPadn's top notice while it is open (notifications only
    /// appear in the background).
    @Published var autoInstallNotice: String?
    /// The automatic installation in progress, for the Live Activity.
    struct AutoInstallProgress: Equatable { var id: UUID; var name: String; var fraction: Double }
    @Published private(set) var autoInstalling: AutoInstallProgress?
    /// The app just installed automatically (Live Activity "Installed").
    @Published private(set) var autoInstalled: String?
    /// A finished download about to be installed silently.
    func waitsForSilentInstall(_ id: UUID) -> Bool { silentInstall && waitingInstalls.contains(id.uuidString) }
    /// Finished downloads still waiting to be installed automatically. Kept
    /// across launches: iOS can end iPadn in the background mid-install.
    private static let autoInstallKey = "autoInstallWaiting"
    private var waitingInstalls: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.autoInstallKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoInstallKey) }
    }
    private func markWaiting(_ id: UUID, _ waiting: Bool) {
        var list = waitingInstalls.filter { $0 != id.uuidString }
        if waiting { list.append(id.uuidString) }
        waitingInstalls = list
    }

    /// iPadn is in front: install what is still waiting, silently with
    /// native installation, otherwise through the install sheet.
    func resumeAutoInstalls() {
        Task { @MainActor in
            await loaded()
            resumeWaitingInstalls()
        }
    }
    private func resumeWaitingInstalls() {
        guard autoInstall else { waitingInstalls = []; return }
        for value in waitingInstalls {
            guard let id = UUID(uuidString: value), jobs.contains(where: { $0.id == id && $0.status == .completed }) else {
                if let id = UUID(uuidString: value) { markWaiting(id, false) } else { waitingInstalls = waitingInstalls.filter { $0 != value } }
                continue
            }
            if silentInstall { installSilently(id) }
            else {
                // Other install methods ask once; cancelling that sheet is the answer.
                markWaiting(id, false)
                if !pendingAutoInstalls.contains(id) { pendingAutoInstalls.append(id) }
            }
        }
    }
    /// The system download service could not write into iPadn's container
    /// (seen with some re-signed builds). Kept per app build: a new install
    /// or signature may behave differently, so it is checked again then.
    @Published private(set) var backgroundDownloadsUnavailable = DownloadManager.loadBackgroundUnavailable()
    private static let backgroundUnavailableKey = "backgroundDownloadsUnavailableBuild"
    private static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "")-\(info?["CFBundleVersion"] as? String ?? "")-\(Bundle.main.bundlePath)"
    }
    private static func loadBackgroundUnavailable() -> Bool {
        UserDefaults.standard.string(forKey: backgroundUnavailableKey) == currentBuild
    }
    /// Lets the next download try the system download service again.
    func retryBackgroundDownloads() {
        UserDefaults.standard.removeObject(forKey: Self.backgroundUnavailableKey)
        UserDefaults.standard.removeObject(forKey: Self.backgroundProbedKey)
        backgroundDownloadsUnavailable = false
        startBackgroundProbeIfNeeded()
    }
    private func markBackgroundUnavailable() {
        guard !backgroundDownloadsUnavailable else { return }
        backgroundDownloadsUnavailable = true
        UserDefaults.standard.set(Self.currentBuild, forKey: Self.backgroundUnavailableKey)
    }

    // A tiny download through the system download service, once per install:
    // with signatures it cannot write for, it fails the same way a package
    // would, but before the user waits for a whole package to download twice.
    nonisolated static let backgroundProbeDescription = "ipadn.background-probe"
    /// Apple's own 68-byte connectivity page; no third-party host is contacted.
    private static let backgroundProbeURL = URL(string: "https://www.apple.com/library/test/success.html")!
    private static let backgroundProbedKey = "backgroundDownloadsProbedBuild"
    private func startBackgroundProbeIfNeeded() {
        guard !backgroundDownloadsUnavailable, !LocalResources.isPreview,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              UserDefaults.standard.string(forKey: Self.backgroundProbedKey) != Self.currentBuild else { return }
        let task = session.downloadTask(with: Self.backgroundProbeURL)
        task.taskDescription = Self.backgroundProbeDescription
        task.resume()
    }
    /// The probe's outcome. Only a file-creation failure, or a file iPadn
    /// can't read, says anything; other errors (offline, captive Wi-Fi) leave
    /// it to be tried on a later launch.
    private func finishBackgroundProbe(error: NSError?, unreadable: Bool = false) {
        if unreadable {
            markBackgroundUnavailable()
        } else if let error {
            guard error.domain == NSURLErrorDomain, error.code == NSURLErrorCannotCreateFile else { return }
            markBackgroundUnavailable()
        }
        UserDefaults.standard.set(Self.currentBuild, forKey: Self.backgroundProbedKey)
    }
    /// The system service saved the file where iPadn may not read it (seen
    /// with some re-signed builds): "you don't have permission to view it".
    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }
    /// Downloads the job again inside the app, once, and keeps later
    /// downloads there for this build.
    private func fallBackToForeground(_ id: UUID) -> Bool {
        guard !fallbackForegroundIDs.contains(id), let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        fallbackForegroundIDs.insert(id)
        markBackgroundUnavailable()
        tasks.removeValue(forKey: id)
        progressPublishedAt.removeValue(forKey: id)
        updateBackgroundTask()
        try? FileManager.default.removeItem(at: LocalResources.resumeURL(id))
        jobs[index].status = .queued
        jobs[index].downloaded = 0
        jobs[index].error = nil
        persist()
        schedule()
        return true
    }
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lastSave = Date.distantPast
    private var transferMetrics: [UUID: TransferMetrics] = [:]
    private var progressPublishedAt: [UUID: TimeInterval] = [:]
    private var saveJobs: ([DownloadJob]) throws -> Void = { try LocalResources.save($0, filename: LocalResources.jobsFilename) }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private func activeSession(for id: UUID) -> URLSession {
        if compatibleDownloadMode || backgroundDownloadsUnavailable || fallbackForegroundIDs.contains(id) {
            return foregroundSession
        }
        return session
    }

    private func updateBackgroundTask() {
        let hasActive = tasks.contains { id, _ in
            compatibleDownloadMode || backgroundDownloadsUnavailable || fallbackForegroundIDs.contains(id)
        }
        if hasActive {
            if backgroundTaskID == .invalid {
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "iPadn.foregroundDownload") { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.backgroundTaskID != .invalid {
                            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                            self.backgroundTaskID = .invalid
                        }
                    }
                }
            }
        } else if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    #if DEBUG
    init(previewJobs: [DownloadJob], activeTasks: [UUID: URLSessionDownloadTask] = [:], saveJobs: @escaping ([DownloadJob]) throws -> Void = { _ in }) {
        super.init()
        jobs = previewJobs
        self.saveJobs = saveJobs
        // Screenshots never create a URLSession or start real transfers.
        tasks = activeTasks
        restoring = activeTasks.isEmpty
    }
    #endif

    override init() {
        super.init()
        loadingJobs = true
        // Write the latest progress to disk before the app can be suspended.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist(wait: true) }
        }
        startupTask = Task {
            do {
                jobs = try await Task.detached(priority: .userInitiated) {
                    let saved = try LocalResources.loadChecked([DownloadJob].self, filename: LocalResources.jobsFilename) ?? []
                    try Self.recoverRemovals(saved)
                    return saved
                }.value
            } catch { storageError = AppText.text("任务文件读取失败；已保留原文件，请先导出诊断再处理。") + "\n" + error.localizedDescription }
            loadingJobs = false
            await restore()
            startBackgroundProbeIfNeeded()
        }
    }

    func configure(_ settings: ToolSettings) {
        maxConcurrent = min(6, max(1, settings.maxConcurrentDownloads))
        maxQueued = max(1, settings.maxQueuedDownloads)
        notifications = settings.notifications
        artworkCountry = settings.store.country
        compatibleDownloadMode = settings.compatibleDownloadMode
        autoInstall = settings.autoInstall
        silentInstall = settings.autoInstall && settings.usesNativeInstallation
        updateInstallKeepAlive()
        if !autoInstall { pendingAutoInstalls.removeAll(); silentQueue.removeAll() }
        wifiOnly = settings.wifiOnlyDownloads
        if wifiOnly { startPathMonitor() }
        applyNetworkRule()
        updateBackgroundTask()
        schedule()
        DownloadActivity.shared.attach(self, enabled: settings.downloadLiveActivity)
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.status == .satisfied && path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                guard let self else { return }
                if !cellular { self.cellularAllowed = false }
                guard cellular != self.onCellular else { return }
                self.onCellular = cellular
                self.applyNetworkRule()
                self.schedule()
            }
        }
        monitor.start(queue: DispatchQueue(label: "iPadn.network-path", qos: .utility))
        pathMonitor = monitor
    }

    /// On cellular with Wi-Fi only on, running downloads go back to the queue
    /// (keeping their progress) and continue once Wi-Fi is back.
    private func applyNetworkRule() {
        let blocked = wifiOnly && onCellular && !cellularAllowed
        if waitingForWiFi != blocked { waitingForWiFi = blocked }
        guard blocked else { return }
        for job in jobs where job.status == .running { pause(job.id, requeue: true) }
    }

    /// Downloads over cellular this time, until Wi-Fi is back.
    func downloadOverCellular() {
        cellularAllowed = true
        applyNetworkRule()
        schedule()
    }

    private func restore() async {
        let all = await session.allTasks
        for task in all {
            guard let value = task.taskDescription, let id = UUID(uuidString: value),
                  jobs.contains(where: { $0.id == id }), let download = task as? URLSessionDownloadTask else {
                task.cancel(); continue
            }
            tasks[id] = download
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                if jobs[index].status == .paused || jobs[index].status == .pausing {
                    tasks.removeValue(forKey: id)
                    jobs[index].status = .pausing
                    let data: Data? = await withCheckedContinuation { continuation in
                        download.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
                    }
                    if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .pausing {
                        if let data { try? data.write(to: LocalResources.resumeURL(id), options: .atomic) }
                        jobs[index].status = .paused
                    }
                } else if jobs[index].status == .completed || jobs[index].status == .failed {
                    tasks.removeValue(forKey: id); download.cancel()
                } else {
                    jobs[index].status = .running
                    if download.state == .suspended { download.resume() }
                }
            }
        }
        for index in jobs.indices {
            let id = jobs[index].id
            if jobs[index].status == .running && tasks[id] == nil { jobs[index].status = .paused }
            if jobs[index].status == .pausing { jobs[index].status = .paused }
            if jobs[index].status == .completed, fileURL(jobs[index]) == nil {
                progressPublishedAt.removeValue(forKey: id)
                jobs[index].status = .failed; jobs[index].error = AppText.text("本地安装包已被移走或删除")
            }
        }
        restoring = false
        for job in jobs where job.status == .processing {
            if adoptFinishedPackage(job.id) { continue }
            if FileManager.default.fileExists(atPath: LocalResources.stagingURL(job.id).path) { process(job.id) }
            else { fail(job.id, error: ToolError.message(AppText.text("下载文件丢失，请重试"))) }
        }
        discoverLocalFiles()
        persist(); schedule()
    }

    func enqueue(_ asset: DownloadAsset) throws {
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw DownloadQueueLimitError()
        }
        guard !jobs.contains(where: { $0.app.id == asset.app.id && $0.app.version == asset.app.version &&
            $0.account == asset.account && ![.failed, .completed].contains($0.status) }) else {
            throw ToolError.message(AppText.text("这个版本已有下载任务"))
        }
        var next = jobs
        next.insert(DownloadJob(app: asset.app, asset: asset, sourceURL: asset.url, expected: asset.app.size), at: 0)
        try saveNewJobs(next)
        requestNotifications(); schedule()
    }

    func enqueueMacInstaller(_ url: URL, for app: StoreApp) throws {
        guard MacInstallerService.directPackage(url) else {
            throw ToolError.message(AppText.text("仅支持 DMG、PKG 或 ZIP 安装包链接"))
        }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw DownloadQueueLimitError(mentionsSettings: false)
        }
        guard !jobs.contains(where: { $0.sourceURL == url && ![.completed, .failed].contains($0.status) }) else {
            throw ToolError.message(AppText.text("此安装包已有下载任务"))
        }
        var next = jobs
        next.insert(DownloadJob(app: app, sourceURL: url, packageIconScanned: true,
                                rawFormat: url.pathExtension.lowercased()), at: 0)
        try saveNewJobs(next)
        requestNotifications(); schedule()
    }

    // The authorized Mac App Store URL is provided by Apple's account-bound
    // dispatch. Protected packages are processed by StoreAgent on device after
    // the download; every finished file is verified as a XAR PKG before the
    // task completes, and Mac tasks only offer export (never iOS install).
    func enqueueOfficialMacPackage(_ offer: MacPackageOffer, for app: StoreApp) throws {
        if offer.protectedByApple {
            guard MacPackageDecryptor.isAvailable else {
                throw ToolError.message(AppText.text("当前版本不支持下载此 Mac 安装包"))
            }
            guard offer.dpInfo != nil, offer.hardwareID.count == 12 else {
                throw ToolError.message(AppText.text("暂时无法下载 Mac 安装包，请重试"))
            }
        }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw DownloadQueueLimitError(mentionsSettings: false)
        }
        guard !jobs.contains(where: { $0.sourceURL == offer.downloadURL &&
                                      ![.completed, .failed].contains($0.status) }) else {
            throw ToolError.message(AppText.text("此安装包已有下载任务"))
        }
        var macApp = app
        // The offer's version is the Mac build's; the listing may describe the iPhone app.
        if !offer.displayVersion.isEmpty, offer.displayVersion != app.version { macApp.version = offer.displayVersion; macApp.size = 0 }
        let job = DownloadJob(app: macApp, sourceURL: offer.downloadURL, packageIconScanned: true,
                              rawFormat: "pkg", protectedMacPackage: offer.protectedByApple ? true : nil)
        if offer.protectedByApple, let dpInfo = offer.dpInfo {
            try MacPackageSecrets.save(.init(hardwareID: offer.hardwareID, dpInfo: dpInfo), for: job.id)
        }
        var next = jobs
        next.insert(job, at: 0)
        do { try saveNewJobs(next) }
        catch { MacPackageSecrets.delete(job.id); throw error }
        requestNotifications()
        schedule()
    }

    func enqueueURL(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ToolError.message(AppText.text("请输入有效的下载链接")) }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw DownloadQueueLimitError()
        }
        let name = url.deletingPathExtension().lastPathComponent
        var next = jobs
        next.insert(DownloadJob(app: StoreApp(id: UUID().uuidString, name: name.isEmpty ? AppText.text("导入安装包") : name), sourceURL: url), at: 0)
        try saveNewJobs(next)
        requestNotifications(); schedule()
    }

    func refreshFailed(_ id: UUID, asset: DownloadAsset) throws {
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .failed,
              jobs[index].account == asset.account, jobs[index].app.id == asset.app.id else {
            throw ToolError.message(AppText.text("账号已切换，请重新下载"))
        }
        var next = jobs
        if next[index].foregroundFallback == true || next[index].error?.contains("无法创建") == true {
            fallbackForegroundIDs.insert(id)
        }
        next[index].asset = asset; next[index].sourceURL = asset.url; next[index].app = asset.app
        next[index].error = nil
        let staged = FileManager.default.fileExists(atPath: LocalResources.stagingURL(id).path)
        next[index].status = staged ? .processing : .queued
        if !staged { next[index].downloaded = 0; next[index].expected = asset.app.size }
        try saveNewJobs(next)
        try? FileManager.default.removeItem(at: LocalResources.resumeURL(id))
        if staged { process(id) } else { schedule() }
    }

    private func schedule() {
        guard !restoring, storageError == nil, removingIDs.isEmpty, !waitingForWiFi else { return }
        let running = jobs.filter { $0.status == .running || $0.status == .pausing }.count
        let count = max(0, maxConcurrent - running)
        for job in jobs.filter({ $0.status == .queued }).prefix(count) { start(job.id) }
    }
    private func start(_ id: UUID) {
        guard tasks[id] == nil, let index = jobs.firstIndex(where: { $0.id == id }), let url = jobs[index].sourceURL else { return }
        LocalResources.ensureDirectoriesExist()
        let active = activeSession(for: id)
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: LocalResources.resumeURL(id)), !resume.isEmpty {
            task = active.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: url)
            request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
            // Also holds while iPadn is suspended and cannot watch the network.
            request.allowsCellularAccess = !wifiOnly || cellularAllowed
            task = active.downloadTask(with: request)
        }
        task.taskDescription = id.uuidString
        tasks[id] = task
        rowProgress.removeValue(forKey: id)
        transferMetrics.removeValue(forKey: id)
        progressPublishedAt.removeValue(forKey: id)
        jobs[index].status = .running; jobs[index].error = nil
        updateBackgroundTask()
        persist(); task.resume()
    }
    /// Pauses a download; `requeue` puts it back in the queue instead.
    func pause(_ id: UUID, requeue: Bool = false) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].status == .queued { jobs[index].status = .paused; persist(); return }
        guard jobs[index].status == .running, let task = tasks[id] else { return }
        jobs[index].status = .pausing; persist()
        task.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                guard let index = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[index].status == .pausing,
                      self.tasks[id] === task else { return }
                if let data = data { try? data.write(to: LocalResources.resumeURL(id), options: .atomic) }
                self.tasks.removeValue(forKey: id)
                self.updateBackgroundTask()
                // The byte count lives in the row's progress while running;
                // keep it on the task so everything showing it stays right.
                if let progress = self.rowProgress[id] { self.jobs[index] = progress.applying(to: self.jobs[index]) }
                self.jobs[index].status = requeue ? .queued : .paused
                self.persist(); self.schedule()
            }
        })
    }
    func resume(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), [.paused, .failed].contains(jobs[index].status) else { return }
        if FileManager.default.fileExists(atPath: LocalResources.stagingURL(id).path) {
            jobs[index].status = .processing; jobs[index].error = nil; process(id)
        } else {
            jobs[index].status = .queued; jobs[index].error = nil; schedule()
        }
        persist()
    }
    func pauseAll() { for job in jobs where job.status == .running || job.status == .queued { pause(job.id) } }
    func resumeAll() { for job in jobs where job.status == .paused { resume(job.id) } }
    func move(from offsets: IndexSet, to destination: Int) {
        // SwiftUI's move helper lives in SwiftUI; explicit order mutation keeps service UI-independent.
        let selected = offsets.sorted().map { jobs[$0] }
        for index in offsets.sorted(by: >) { jobs.remove(at: index) }
        let adjusted = destination - offsets.filter { $0 < destination }.count
        jobs.insert(contentsOf: selected, at: max(0, min(adjusted, jobs.count)))
        persist()
    }
    /// Stops processing a Mac package (queued or running). The download is
    /// kept and the task becomes paused, so it can be continued later.
    func cancelProcessing(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .processing,
              job.protectedMacPackage == true else { return }
        guard cancelling.insert(id).inserted else { return } // repeated taps do nothing
        MacPackageDecryptor.cancel(job: id)
    }

    func remove(_ id: UUID) throws {
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if job.status == .processing, job.protectedMacPackage == true {
            // Deleted once processing has stopped (see process()).
            removalAfterCancel.insert(id); cancelProcessing(id); return
        }
        guard job.status != .processing, job.status != .pausing else { throw ToolError.message(AppText.text("请等待当前文件处理或暂停完成后再删除")) }
        let file = fileURL(job)
        let removal = LocalResources.support.appendingPathComponent("\(id.uuidString).removing.ipa")
        if let file { try FileManager.default.moveItem(at: file, to: removal) }
        do { try saveNewJobs(jobs.filter { $0.id != id }) }
        catch {
            if let file { try FileManager.default.moveItem(at: removal, to: file) }
            throw error
        }
        tasks.removeValue(forKey: id)?.cancel()
        rowProgress.removeValue(forKey: id)
        fallbackForegroundIDs.remove(id)
        updateBackgroundTask()
        progressPublishedAt.removeValue(forKey: id)
        transferMetrics.removeValue(forKey: id)
        if file != nil { try? FileManager.default.removeItem(at: removal) }
        try? FileManager.default.removeItem(at: LocalResources.resumeURL(id))
        try? FileManager.default.removeItem(at: LocalResources.stagingURL(id))
        try? FileManager.default.removeItem(at: PackageIconService.cacheURL(id))
        try? FileManager.default.removeItem(at: Self.decryptedURL(id))
        MacPackageSecrets.delete(id)
        catalogArtworkAttempted.remove(id)
        schedule()
    }

    /// One durable commit for a batch. Pause live transfers first; move packages
    /// aside and roll them back if the task-list write fails. Disk work is serial
    /// with earlier progress saves, and never runs on the main actor.
    func removeBatch(_ ids: Set<UUID>) async throws -> Int {
        guard removingIDs.isEmpty, !loadingJobs else { throw ToolError.message(AppText.text("正在保存任务，请稍后重试")) }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        let selected = jobs.filter { ids.contains($0.id) }
        guard !selected.contains(where: { $0.status == .processing || $0.status == .pausing }) else {
            throw ToolError.message(AppText.text("请等待当前文件处理或暂停完成后再删除"))
        }
        for job in selected where job.status == .running { pause(job.id) }
        let deadline = Date().addingTimeInterval(15)
        while jobs.contains(where: { ids.contains($0.id) && $0.status == .pausing }) {
            guard Date() < deadline else { throw ToolError.message(AppText.text("暂停下载尚未完成，请稍后重试删除")) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard removingIDs.isEmpty else { throw ToolError.message(AppText.text("正在删除任务，请稍后重试")) }
        let targets = jobs.filter { ids.contains($0.id) }
        guard !targets.contains(where: { $0.status == .processing }) else { throw ToolError.message(AppText.text("任务正在处理，请稍后重试")) }
        let removed = Set(targets.map(\.id))
        guard !removed.isEmpty else { return 0 }
        removingIDs = removed
        defer { removingIDs.removeAll(); persist(); schedule(); finishBackgroundIfReady() }
        let next = currentJobs.filter { !removed.contains($0.id) }, save = saveJobs
        let files = targets.compactMap { job in fileURL(job).map { (job.id, $0) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            persistQueue.async {
                var moved: [(URL, URL)] = []
                do {
                    for (id, file) in files {
                        let aside = LocalResources.support.appendingPathComponent("\(id.uuidString).removing.ipa")
                        try FileManager.default.moveItem(at: file, to: aside)
                        moved.append((aside, file))
                    }
                    try save(next)
                } catch {
                    for (aside, file) in moved.reversed() { try? FileManager.default.moveItem(at: aside, to: file) }
                    continuation.resume(throwing: error); return
                }
                for (aside, _) in moved { try? FileManager.default.removeItem(at: aside) }
                for id in removed {
                    for url in [LocalResources.resumeURL(id), LocalResources.stagingURL(id), PackageIconService.cacheURL(id), Self.decryptedURL(id)] {
                        try? FileManager.default.removeItem(at: url)
                    }
                    MacPackageSecrets.delete(id)
                }
                continuation.resume()
            }
        }
        jobs.removeAll { removed.contains($0.id) }
        for id in removed {
            tasks.removeValue(forKey: id)?.cancel()
            rowProgress.removeValue(forKey: id); transferMetrics.removeValue(forKey: id)
            progressPublishedAt.removeValue(forKey: id); fallbackForegroundIDs.remove(id)
            catalogArtworkAttempted.remove(id)
        }
        updateBackgroundTask()
        return removed.count
    }

    /// Crash between moving a package aside and committing jobs must never
    /// make a retained package disappear. A committed removal has no job left.
    nonisolated static func recoverRemovals(_ jobs: [DownloadJob], support: URL = LocalResources.support,
                                           packages: URL = LocalResources.packages) throws {
        let fm = FileManager.default
        let root = packages.resolvingSymlinksInPath().standardizedFileURL
        let retained = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let files = (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for aside in files where aside.lastPathComponent.hasSuffix(".removing.ipa") {
            let prefix = String(aside.lastPathComponent.dropLast(".removing.ipa".count))
            guard let id = UUID(uuidString: prefix),
                  (try? aside.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if let job = retained[id] {
                guard let name = job.localFilename, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { continue }
                let destination = root.appendingPathComponent(name).standardizedFileURL
                guard destination.deletingLastPathComponent() == root else { continue }
                if !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: aside, to: destination) }
            } else { try? fm.removeItem(at: aside) }
        }
    }

    nonisolated static func decryptedURL(_ id: UUID) -> URL {
        LocalResources.support.appendingPathComponent("\(id.uuidString).decrypted.pkg")
    }
    func metrics(for id: UUID) -> TransferMetrics? { transferMetrics[id] }

    func fileURL(_ job: DownloadJob) -> URL? {
        job.localFilename.flatMap(LocalResources.packageURL)
    }

    func packageIconURL(_ job: DownloadJob) -> URL? {
        let url = PackageIconService.cacheURL(job.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Packages whose icon scan has started but not finished.
    private static let iconScanKey = "packageIconScansInProgress"
    func loadPackageIcons() async {
        guard !iconsLoading else { return }
        iconsLoading = true
        defer { iconsLoading = false }
        // A scan that ended the app last time is not tried again: the list
        // would otherwise end the app on every launch.
        var interrupted = Set(UserDefaults.standard.stringArray(forKey: Self.iconScanKey) ?? [])
        for job in jobs where job.status == .completed && job.rawFormat == nil {
            guard let file = fileURL(job), !Task.isCancelled else { continue }
            if job.packageIconScanned != true, interrupted.remove(job.id.uuidString) != nil,
               let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].packageIconScanned = true
                if jobs[index].app.iconURL == nil { jobs[index].app.iconURL = jobs[index].asset?.app.iconURL }
                persist()
                UserDefaults.standard.set(Array(interrupted), forKey: Self.iconScanKey)
                continue
            }
            // Older versions scanned before they could keep a small icon get one more look.
            let rescan = job.packageIconScanned == true && job.isOlderVersion && packageIconURL(job) == nil
                && olderIconRetried.insert(job.id).inserted
            if job.packageIconScanned != true || rescan {
                interrupted.insert(job.id.uuidString)
                UserDefaults.standard.set(Array(interrupted), forKey: Self.iconScanKey)
                // With store artwork available, only keep a package icon that is
                // sharp at list size (64 pt at 3x). An older version keeps its own
                // icon at any size: the store shows today's, which may look different.
                let minimum = job.displayApp(packageIcon: nil).iconURL == nil || job.isOlderVersion ? 0 : 180
                _ = await Task.detached(priority: .utility) {
                    try? PackageIconService.save(from: file, id: job.id, minimumPixels: minimum)
                }.value
                guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
                    try? FileManager.default.removeItem(at: PackageIconService.cacheURL(job.id))
                    continue
                }
                jobs[index].packageIconScanned = true
                interrupted.remove(job.id.uuidString)
                UserDefaults.standard.set(Array(interrupted), forKey: Self.iconScanKey)
                // Never erase the catalog icon because IPA icon extraction failed.
                if jobs[index].app.iconURL == nil {
                    jobs[index].app.iconURL = jobs[index].asset?.app.iconURL
                }
                persist()
            }
            // Icons cached before small package PNGs were rejected: fall back to
            // the sharper store artwork.
            if iconSizeChecked.insert(job.id).inserted, let cached = packageIconURL(job),
               job.displayApp(packageIcon: nil).iconURL != nil, !job.isOlderVersion,
               PackageIconService.pixelWidth(cached) < 180 {
                try? FileManager.default.removeItem(at: cached)
                objectWillChange.send()
            }
            // tvOS packages keep their icon in a layered asset catalog, and the
            // stored artwork can be the shared App ID's iPhone icon. Replace
            // the cached icon once with the Apple TV catalog artwork.
            guard job.platformLabel == "tvOS", job.appleTVArtwork != true,
                  catalogArtworkAttempted.insert(job.id).inserted,
                  jobs.contains(where: { $0.id == job.id }) else { continue }
            var tvArtwork: URL?
            if job.app.id.allSatisfy({ $0.isASCII && $0.isNumber }) {
                let countries = artworkCountry == "US" ? ["US"] : [artworkCountry, "US"]
                for country in countries {
                    if Task.isCancelled { break }
                    let context = StoreContext(country: country, platform: .tvOS)
                    if let listing = try? await StoreService.platformApp(job.app.id, store: context),
                       let icon = listing.iconURL {
                        tvArtwork = icon
                        break
                    }
                }
            }
            let current = jobs.first { $0.id == job.id } ?? job
            let fallback = packageIconURL(job) == nil ? current.displayApp(packageIcon: nil).iconURL : nil
            guard let artwork = tvArtwork ?? fallback, !Task.isCancelled else { continue }
            if (try? await PackageIconService.saveCatalogArtwork(from: artwork, id: job.id)) == true {
                // A download can be deleted while the artwork request is in flight.
                guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
                    try? FileManager.default.removeItem(at: PackageIconService.cacheURL(job.id))
                    continue
                }
                if tvArtwork != nil {
                    jobs[index].app.iconURL = artwork
                    jobs[index].appleTVArtwork = true
                    persist()
                }
                objectWillChange.send()
            }
        }
    }

    func importFile(_ source: URL) async throws {
        guard storageError == nil else { throw ToolError.message(storageError!) }
        let id = UUID()
        let inspected = try await Task.detached(priority: .userInitiated) {
            try PackageImportService.prepare(source, id: id)
        }.value
        guard storageError == nil else {
            try? FileManager.default.removeItem(at: LocalResources.stagingURL(id))
            throw ToolError.message(storageError!)
        }
        var next = jobs
        next.insert(DownloadJob(id: id, app: inspected, status: .processing), at: 0)
        do { try saveNewJobs(next) }
        catch { try? FileManager.default.removeItem(at: LocalResources.stagingURL(id)); throw error }
        process(id)
    }

    private func process(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), processingIDs.insert(id).inserted else { return }
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Prepare IPA") { [weak self] in
            // Called on the main thread; the task must be ended before returning.
            MainActor.assumeIsolated {
                self?.persist(wait: true)
                let completion = self?.backgroundCompletion; self?.backgroundCompletion = nil; completion?()
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
            }
        }
        let monitor: Task<Void, Never>? = job.protectedMacPackage == true
            ? Task { await self.monitorMacProcessing(id) } : nil
        Task {
            defer {
                monitor?.cancel()
                self.processingDetail.removeValue(forKey: id)
                self.processingIDs.remove(id)
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
                self.finishBackgroundIfReady()
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    if job.protectedMacPackage == true {
                        // StoreAgent turns Apple's protected download into the
                        // real PKG, which must then pass full XAR validation.
                        let secret = try MacPackageSecrets.load(id)
                        let decrypted = Self.decryptedURL(id)
                        defer { try? FileManager.default.removeItem(at: decrypted) }
                        try await MacPackageDecryptor.process(job: id, hardwareID: secret.hardwareID, dpInfo: secret.dpInfo,
                                                              from: LocalResources.stagingURL(id), to: decrypted)
                        return try MacPackageStorage.finish(staging: decrypted, job: job)
                    }
                    if job.rawFormat != nil {
                        return try MacPackageStorage.finish(staging: LocalResources.stagingURL(id), job: job)
                    }
                    let result = try PackageService.finish(staging: LocalResources.stagingURL(id), id: id, asset: job.asset)
                    _ = try? PackageIconService.save(from: LocalResources.packages.appendingPathComponent(result.0), id: id)
                    return result
                }.value
                guard let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                self.jobs[index].localFilename = result.0
                self.jobs[index].app = job.completing(with: result.1)
                self.jobs[index].packageIconScanned = true
                self.jobs[index].status = .completed
                self.jobs[index].downloaded = result.1.size; self.jobs[index].expected = result.1.size
                self.jobs[index].error = nil
                try? FileManager.default.removeItem(at: LocalResources.stagingURL(id))
                try? FileManager.default.removeItem(at: LocalResources.resumeURL(id))
                if job.protectedMacPackage == true { MacPackageSecrets.delete(id) }
                self.persist()
                // Only downloaded app packages; imported files and Mac packages are not installed here.
                let installs = self.autoInstall && job.rawFormat == nil && job.protectedMacPackage != true && job.sourceURL != nil
                // Kept across launches only for the silent install, which iOS can interrupt.
                if installs && self.silentInstall { self.markWaiting(id, true) }
                if installs && self.silentInstall {
                    self.installSilently(id)
                } else {
                    self.notify(title: AppText.text("安装包已准备好"), body: result.1.name + " " + result.1.version)
                    if installs, !self.pendingAutoInstalls.contains(id) { self.pendingAutoInstalls.append(id) }
                }
                Task { await self.loadPackageIcons() }
            } catch is CancellationError {
                self.cancelling.remove(id)
                // Cancelled by the user: keep the download, continue later.
                guard let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                self.jobs[index].status = .paused
                self.jobs[index].error = nil
                self.persist(); self.schedule()
                if self.removalAfterCancel.remove(id) != nil { try? self.remove(id) }
            } catch {
                self.cancelling.remove(id)
                // Retrying must download again rather than reprocess the same bad
                // file (imported files have nothing to download and keep theirs).
                // A protected Mac package keeps its download: its processing
                // can fail for transient reasons (component download, network).
                if job.protectedMacPackage != true, job.sourceURL != nil {
                    try? FileManager.default.removeItem(at: LocalResources.stagingURL(id))
                    try? FileManager.default.removeItem(at: LocalResources.resumeURL(id))
                    if let index = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[index].downloaded = 0 }
                }
                self.fail(id, error: error)
            }
        }
    }

    private func monitorMacProcessing(_ id: UUID) async {
        let total = (try? FileManager.default.attributesOfItem(atPath: LocalResources.stagingURL(id).path)[.size] as? NSNumber)?.int64Value ?? 0
        while !Task.isCancelled {
            if MacPackageDecryptor.currentJob != id {
                processingDetail[id] = AppText.text("排队等待处理")
            } else if let status = MacPackageDecryptor.status() {
                var text = status.stage.title
                if status.stage == .decrypting, total > 0 {
                    text += String(format: " %.0f%%", min(100, Double(status.bytes) * 100 / Double(total)))
                } else if status.stage == .components {
                    text += AppText.text("（首次需下载约 47 MB）")
                }
                processingDetail[id] = text
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Processing moves the result into Packages before the job is saved as
    /// completed; if the app was killed in between, finish the job from that file.
    private func adoptFinishedPackage(_ id: UUID) -> Bool {
        let prefix = id.uuidString + "-"
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              let names = try? FileManager.default.contentsOfDirectory(atPath: LocalResources.packages.path),
              let name = names.first(where: { $0.hasPrefix(prefix) }) else { return false }
        jobs[index].localFilename = name
        jobs[index].status = .completed
        jobs[index].error = nil
        if let size = (try? FileManager.default.attributesOfItem(atPath: LocalResources.packages.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value {
            jobs[index].downloaded = size; jobs[index].expected = size
        }
        try? FileManager.default.removeItem(at: LocalResources.stagingURL(id))
        try? FileManager.default.removeItem(at: LocalResources.resumeURL(id))
        if jobs[index].protectedMacPackage == true { MacPackageSecrets.delete(id) }
        return true
    }

    private func discoverLocalFiles() {
        guard storageError == nil else { return }
        Task {
            let files = await Task.detached(priority: .utility) {
                ((try? FileManager.default.contentsOfDirectory(at: LocalResources.packages, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension.lowercased() == "ipa" && LocalResources.packageURL($0.lastPathComponent) != nil }
            }.value
            for file in files {
                guard !self.jobs.contains(where: { $0.localFilename == file.lastPathComponent }) else { continue }
                do {
                    let app = try await Task.detached(priority: .utility) { try PackageService.inspect(file) }.value
                    guard !self.jobs.contains(where: { $0.localFilename == file.lastPathComponent }) else { continue }
                    self.jobs.append(DownloadJob(app: app, status: .completed, downloaded: app.size, expected: app.size, localFilename: file.lastPathComponent))
                    self.persist()
                } catch { self.discoveryWarning = AppText.text("本地 IPA 无法读取，已保留原文件；其他任务可继续使用：\(file.lastPathComponent)\n\(error.localizedDescription)") }
            }
        }
    }

    private func fail(_ id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        tasks.removeValue(forKey: id)
        progressPublishedAt.removeValue(forKey: id)
        updateBackgroundTask()
        RequestFailureLog.record(nil, status: (error as? HTTPStatusError)?.code,
                                 error: error is HTTPStatusError || error is ToolError ? nil : error, stage: "download")
        jobs[index].status = .failed; jobs[index].error = error.localizedDescription
        jobs[index].foregroundFallback = Self.cannotCreateFile(error)
        persist(); schedule()
        notify(title: AppText.text("下载任务失败"), body: AppText.text("\(jobs[index].app.name)：\(error.localizedDescription)"))
    }
    /// Saves a snapshot of the task list. Encoding and writing happen on a
    /// serial background queue, so writes stay in order and the main thread
    /// never waits for the disk; `wait` blocks until it is written (used when
    /// the app is about to be suspended).
    /// A background session that cannot create its file needs a foreground
    /// retry. Checked on the error, never on its localized text.
    private static func cannotCreateFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCannotCreateFile || ns.code == NSURLErrorCannotWriteToFile {
            return true
        }
        let text = error.localizedDescription
        return text.contains("无法创建") || text.localizedCaseInsensitiveContains("could not create")
    }
    private func persist(wait: Bool = false) {
        // storageError means the saved list could not be read; never overwrite it.
        guard storageError == nil, !loadingJobs, removingIDs.isEmpty else { return }
        let snapshot = currentJobs, save = saveJobs
        lastSave = Date()
        let write: @Sendable () -> Void = { [weak self] in
            let failed: Bool
            do { try save(snapshot); failed = false } catch { failed = true }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if failed { self.saveWarning = AppText.text("下载任务暂时无法保存，请检查设备存储空间。") }
                else if self.saveWarning != nil { self.saveWarning = nil }
            }
        }
        if wait { persistQueue.sync(execute: write) } else { persistQueue.async(execute: write) }
    }
    private func saveNewJobs(_ next: [DownloadJob]) throws {
        guard !loadingJobs, removingIDs.isEmpty else { throw ToolError.message(AppText.text("正在保存任务，请稍后重试")) }
        let next = next.map { rowProgress[$0.id]?.applying(to: $0) ?? $0 }
        // Commit the file before publishing a newly enqueued/imported/retried
        // task; on the same queue, after any earlier pending save.
        try persistQueue.sync { try saveJobs(next) }
        jobs = next; lastSave = Date()
    }
    private func requestNotifications() {
        guard notifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    /// Installs finished downloads one at a time through native installation,
    /// without the install sheet. One that can't finish (no connection, iOS
    /// ended the background time) gets the sheet when iPadn is open again.
    private func installSilently(_ id: UUID) {
        guard !silentQueue.contains(id) else { return }
        silentQueue.append(id)
        guard !silentRunning else { return }
        silentRunning = true
        Task { @MainActor in
            defer { silentRunning = false }
            while !silentQueue.isEmpty {
                let id = silentQueue.removeFirst()
                guard let job = jobs.first(where: { $0.id == id && $0.status == .completed }), let file = fileURL(job) else {
                    markWaiting(id, false); continue
                }
                let name = [job.app.name, job.app.version].filter { !$0.isEmpty }.joined(separator: " ")
                autoInstallNotice = AppText.text("正在自动安装 \(name)")
                autoInstalled = nil
                autoInstalling = AutoInstallProgress(id: id, name: name, fraction: 0)
                defer { autoInstalling = nil }
                do {
                    _ = try await NativeInstaller.install(package: file, bundleID: job.app.bundleID) { phase in
                        // Sending the package is most of the wait; the system's own step follows.
                        let fraction: Double
                        switch phase {
                        case .uploading(let done): fraction = done * 0.7
                        case .installing(let done): fraction = 0.7 + done * 0.3
                        default: fraction = 0
                        }
                        Task { @MainActor in
                            if self.autoInstalling?.id == id { self.autoInstalling?.fraction = fraction }
                        }
                    }
                    markWaiting(id, false)
                    autoInstalled = name
                    autoInstallNotice = AppText.text("已自动安装 \(name)")
                    notify(title: AppText.text("已自动安装"), body: name)
                } catch {
                    autoInstallNotice = nil
                    InstallLog.shared.add("silent install not finished: \(error.localizedDescription.prefix(160))")
                    if UIApplication.shared.applicationState == .active {
                        // In front and still failing (e.g. LocalDevVPN not connected): the sheet explains.
                        markWaiting(id, false)
                        if !pendingAutoInstalls.contains(id) { pendingAutoInstalls.append(id) }
                    } else {
                        // In the background iOS may simply have run out of time: retried when iPadn is back.
                        notify(title: AppText.text("自动安装未完成"), body: AppText.text("打开 iPadn 继续安装 \(name)"))
                    }
                }
            }
        }
    }

    private func notify(title: String, body: String) {
        guard notifications else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    private func finishBackgroundIfReady() {
        guard !restoring, deliveries.isEmpty, processingIDs.isEmpty, removingIDs.isEmpty else { return }
        guard let completion = backgroundCompletion else { return }
        backgroundCompletion = nil
        // The app may be suspended right after this: finish pending saves first.
        persistQueue.sync {}
        completion()
    }
}

// Mac downloads are exported as original files. Never feed them to the IPA
// parser or iOS system installer. Reject encrypted or truncated fake PKGs.
enum MacPackageStorage {
    static func plausibleXARHeader(_ header: Data, fileSize: Int64) -> Bool {
        guard header.count >= 28, fileSize >= 29,
              header.prefix(4) == Data("xar!".utf8) else { return false }
        func number(_ offset: Int, length: Int) -> UInt64 {
            header[offset..<(offset + length)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let headerSize = number(4, length: 2)
        let version = number(6, length: 2)
        let compressedTOC = number(8, length: 8)
        let uncompressedTOC = number(16, length: 8)
        // Cheap header sanity check; XARValidator performs the full TOC and
        // checksum verification afterwards.
        return headerSize >= 28 && headerSize <= 4096 && version == 1 &&
            compressedTOC > 0 && uncompressedTOC > 0 &&
            uncompressedTOC <= 32 * 1024 * 1024 &&
            headerSize < UInt64(fileSize) &&
            compressedTOC <= UInt64(fileSize) - headerSize
    }

    static func finish(staging: URL, job: DownloadJob) throws -> (String, StoreApp) {
        guard let format = job.rawFormat, ["dmg", "pkg", "zip"].contains(format),
              let length = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value,
              length >= 8 else { throw ToolError.message(AppText.text("下载的 Mac 文件不完整")) }
        let file = try FileHandle(forReadingFrom: staging)
        defer { try? file.close() }
        let prefix = try file.read(upToCount: 4) ?? Data()
        let valid: Bool
        switch format {
        case "pkg":
            try file.seek(toOffset: 0)
            let header = try file.read(upToCount: 28) ?? Data()
            guard plausibleXARHeader(header, fileSize: length) else { valid = false; break }
            // Inflate the TOC and verify every checksum before export, so an
            // encrypted or damaged package can never be offered as a PKG.
            _ = try XARValidator.validate(staging)
            valid = true
        case "zip": valid = prefix.starts(with: [0x50, 0x4B, 0x03, 0x04])
        default:
            guard length >= 512 else { throw ToolError.message(AppText.text("DMG 文件不完整")) }
            try file.seek(toOffset: UInt64(length - 512))
            valid = (try file.read(upToCount: 4) ?? Data()) == Data("koly".utf8)
        }
        guard valid else { throw ToolError.message(AppText.text("文件内容不是有效的 \(format.uppercased()) 安装包")) }
        let filename = "\(job.id.uuidString)-\(PackageService.safeName(job.app.name).prefix(40)).\(format)"
        let destination = LocalResources.packages.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError.message(AppText.text("同名安装包已存在"))
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        var app = job.app
        app.size = length
        return (filename, app)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value) else { return }
        Task { @MainActor in
            guard let index = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[index].status == .running,
                  self.accepts(downloadTask, id: id) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let finished = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
            guard finished || now - (self.progressPublishedAt[id] ?? 0) >= 0.25 else { return }
            self.progressPublishedAt[id] = now
            if var metric = self.transferMetrics[id] {
                metric.record(bytes: totalBytesWritten, at: now)
                self.transferMetrics[id] = metric
            } else { self.transferMetrics[id] = TransferMetrics(bytes: totalBytesWritten, sampledAt: now) }
            self.progress(for: id).bytes = (totalBytesWritten, max(0, totalBytesExpectedToWrite))
            // Resume data, not this count, is what a restart relies on.
            if Date().timeIntervalSince(self.lastSave) > 5 { self.persist() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if downloadTask.taskDescription == Self.backgroundProbeDescription {
            // The service created the file; iPadn must also be able to read it.
            var unreadable = false
            do { _ = try Data(contentsOf: location) } catch { unreadable = Self.isPermissionError(error) }
            try? FileManager.default.removeItem(at: location)
            Task { @MainActor in self.finishBackgroundProbe(error: nil, unreadable: unreadable); self.finishBackgroundIfReady() }
            return
        }
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value) else { return }
        deliveries.begin()
        LocalResources.ensureDirectoriesExist()
        let received = LocalResources.support.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).received")
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw ToolError.message(AppText.text("下载失败（\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)），请重试"))
            }
            if FileManager.default.fileExists(atPath: received.path) {
                try? FileManager.default.removeItem(at: received)
            }
            // Move synchronously: URLSession deletes its temporary file as soon as this delegate returns.
            do {
                try FileManager.default.moveItem(at: location, to: received)
            } catch {
                try FileManager.default.copyItem(at: location, to: received)
                try? FileManager.default.removeItem(at: location)
            }
            Task { @MainActor in
                let restoredDelivery = (self.loadingJobs || self.restoring) && session.configuration.identifier == Self.sessionID
                await self.startupTask?.value
                defer {
                    try? FileManager.default.removeItem(at: received)
                    self.updateBackgroundTask()
                    self.deliveries.end(); self.finishBackgroundIfReady()
                }
                // A transfer can finish while the app is not running; after a
                // relaunch the job may already read paused or queued with no task.
                guard let index = self.jobs.firstIndex(where: { $0.id == id }),
                      [.running, .pausing, .paused, .queued].contains(self.jobs[index].status),
                      self.accepts(downloadTask, id: id, restoredDelivery: restoredDelivery) else { return }
                do {
                    let destination = LocalResources.stagingURL(id)
                    try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    do {
                        try FileManager.default.moveItem(at: received, to: destination)
                    } catch {
                        try FileManager.default.copyItem(at: received, to: destination)
                        try? FileManager.default.removeItem(at: received)
                    }
                } catch { self.fail(id, error: error); return }
                self.tasks.removeValue(forKey: id)
                self.progressPublishedAt.removeValue(forKey: id)
                self.jobs[index].status = .processing; self.persist(); self.schedule(); self.process(id)
            }
        } catch {
            try? FileManager.default.removeItem(at: received)
            let unreadable = Self.isPermissionError(error)
            Task { @MainActor in
                defer { self.deliveries.end(); self.finishBackgroundIfReady() }
                await self.startupTask?.value
                self.updateBackgroundTask()
                guard self.accepts(downloadTask, id: id) else { return }
                if unreadable, self.fallBackToForeground(id) { return }
                self.fail(id, error: error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task.taskDescription == Self.backgroundProbeDescription {
            if let error = error as NSError? {
                Task { @MainActor in self.finishBackgroundProbe(error: error); self.finishBackgroundIfReady() }
            }
            return
        }
        guard let error = error as NSError?, let value = task.taskDescription, let id = UUID(uuidString: value) else { return }
        let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            let restoredDelivery = (self.loadingJobs || self.restoring) && session.configuration.identifier == Self.sessionID
            await self.startupTask?.value
            guard let job = self.jobs.first(where: { $0.id == id }), job.status != .completed && job.status != .processing else { return }
            guard self.accepts(task, id: id, restoredDelivery: restoredDelivery) else { return }

            // Automatic fallback: if background nsurlsessiond failed to create file (-3000), retry in foreground process
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCannotCreateFile, self.fallBackToForeground(id) { return }

            // Save resume data first: it is what lets a cancelled transfer continue.
            if let resume = resume { try? resume.write(to: LocalResources.resumeURL(id), options: .atomic) }
            if job.status == .pausing || job.status == .paused { return }
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled, resume != nil,
               let index = self.jobs.firstIndex(where: { $0.id == id }) {
                // Cancelled by the system (app quit, low storage): pause, keep progress.
                self.tasks.removeValue(forKey: id)
                self.progressPublishedAt.removeValue(forKey: id)
                self.updateBackgroundTask()
                self.jobs[index].status = .paused
                self.persist(); self.schedule()
                return
            }
            if resume == nil { try? FileManager.default.removeItem(at: LocalResources.resumeURL(id)) }
            self.fail(id, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            await self.startupTask?.value
            self.finishBackgroundIfReady()
        }
    }
}
