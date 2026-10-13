import Foundation
import Combine
import UserNotifications
import UIKit

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let sessionID = "iPadn.background.downloads"
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var storageError: String?
    @Published private(set) var discoveryWarning: String?
    /// Stage text for Mac App Store packages being processed on device.
    @Published private(set) var processingDetail: [UUID: String] = [:]
    var backgroundCompletion: (() -> Void)?
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var restoring = true
    private var maxConcurrent = 3
    private var maxQueued = 10
    private var processingIDs = Set<UUID>()
    private var iconsLoading = false
    private var catalogArtworkAttempted = Set<UUID>()
    private var artworkCountry = "CN"
    private var notifications = true
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

    #if DEBUG
    init(previewJobs: [DownloadJob], saveJobs: @escaping ([DownloadJob]) throws -> Void = { _ in }) {
        super.init()
        jobs = previewJobs
        self.saveJobs = saveJobs
        // Screenshots never create a URLSession or start real transfers.
        restoring = true
    }
    #endif

    override init() {
        super.init()
        let file = LocalResources.support.appendingPathComponent(LocalResources.jobsFilename)
        if FileManager.default.fileExists(atPath: file.path) {
            do { jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: file)) }
            catch { storageError = "任务文件读取失败；已保留原文件，请先导出诊断再处理。\n" + error.localizedDescription }
        }
        Task { await restore() }
    }

    func configure(_ settings: ToolSettings) {
        maxConcurrent = min(6, max(1, settings.maxConcurrentDownloads))
        maxQueued = max(1, settings.maxQueuedDownloads)
        notifications = settings.notifications
        artworkCountry = settings.store.country
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
                jobs[index].status = .failed; jobs[index].error = "本地安装包已被移走或删除"
            }
        }
        restoring = false
        for job in jobs where job.status == .processing {
            if FileManager.default.fileExists(atPath: LocalResources.stagingURL(job.id).path) { process(job.id) }
            else { fail(job.id, error: ToolError.message("待处理下载文件不存在，请重试")) }
        }
        discoverLocalFiles()
        persist(); schedule()
    }

    func enqueue(_ asset: DownloadAsset) throws {
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw ToolError.message("已达到等待任务上限，可在设置中调整")
        }
        guard !jobs.contains(where: { $0.app.id == asset.app.id && $0.app.version == asset.app.version &&
            $0.account == asset.account && ![.failed, .completed].contains($0.status) }) else {
            throw ToolError.message("这个版本已有下载任务")
        }
        var next = jobs
        next.insert(DownloadJob(app: asset.app, asset: asset, sourceURL: asset.url, expected: asset.app.size), at: 0)
        try saveNewJobs(next)
        requestNotifications(); schedule()
    }

    func enqueueMacInstaller(_ url: URL, for app: StoreApp) throws {
        guard MacInstallerService.directPackage(url) else {
            throw ToolError.message("只支持开发者网站提供的 HTTPS DMG、PKG 或 ZIP 文件")
        }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw ToolError.message("已达到等待任务上限")
        }
        guard !jobs.contains(where: { $0.sourceURL == url && ![.completed, .failed].contains($0.status) }) else {
            throw ToolError.message("此安装包已有下载任务")
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
                throw ToolError.message("此版本未包含 Mac 安装包处理组件，请使用 GitHub Actions 构建的 iPadn。")
            }
            guard offer.dpInfo != nil, offer.hardwareID.count == 12 else {
                throw ToolError.message("Apple 没有返回完整的 Mac 下载授权，请重试")
            }
        }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw ToolError.message("已达到等待任务上限")
        }
        guard !jobs.contains(where: { $0.sourceURL == offer.downloadURL &&
                                      ![.completed, .failed].contains($0.status) }) else {
            throw ToolError.message("此安装包已有下载任务")
        }
        var macApp = app
        if !offer.displayVersion.isEmpty { macApp.version = offer.displayVersion }
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
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ToolError.message("下载链接必须是有效的 HTTPS 地址，不能包含账号密码") }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw ToolError.message("已达到等待任务上限，可在设置中调整")
        }
        let name = url.deletingPathExtension().lastPathComponent
        var next = jobs
        next.insert(DownloadJob(app: StoreApp(id: UUID().uuidString, name: name.isEmpty ? "导入安装包" : name), sourceURL: url), at: 0)
        try saveNewJobs(next)
        requestNotifications(); schedule()
    }

    func refreshFailed(_ id: UUID, asset: DownloadAsset) throws {
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .failed,
              jobs[index].account == asset.account, jobs[index].app.id == asset.app.id else {
            throw ToolError.message("任务或账号已改变，请重新执行重试")
        }
        var next = jobs
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
        guard !restoring, storageError == nil else { return }
        let running = jobs.filter { $0.status == .running || $0.status == .pausing }.count
        let count = max(0, maxConcurrent - running)
        for job in jobs.filter({ $0.status == .queued }).prefix(count) { start(job.id) }
    }
    private func start(_ id: UUID) {
        guard tasks[id] == nil, let index = jobs.firstIndex(where: { $0.id == id }), let url = jobs[index].sourceURL else { return }
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: LocalResources.resumeURL(id)), !resume.isEmpty {
            task = session.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: url)
            request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = id.uuidString
        tasks[id] = task
        transferMetrics.removeValue(forKey: id)
        progressPublishedAt.removeValue(forKey: id)
        jobs[index].status = .running; jobs[index].error = nil
        persist(); task.resume()
    }
    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].status == .queued { jobs[index].status = .paused; persist(); return }
        guard jobs[index].status == .running, let task = tasks[id] else { return }
        jobs[index].status = .pausing; persist()
        task.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                guard let index = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[index].status == .pausing,
                      self.tasks[id]?.taskIdentifier == task.taskIdentifier else { return }
                if let data = data { try? data.write(to: LocalResources.resumeURL(id), options: .atomic) }
                self.tasks.removeValue(forKey: id)
                self.jobs[index].status = .paused
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
    func remove(_ id: UUID) throws {
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard job.status != .processing, job.status != .pausing else { throw ToolError.message("请等待当前文件处理或暂停完成后再删除") }
        let file = fileURL(job)
        let removal = LocalResources.support.appendingPathComponent("\(id.uuidString).removing.ipa")
        if let file { try FileManager.default.moveItem(at: file, to: removal) }
        do { try saveNewJobs(jobs.filter { $0.id != id }) }
        catch {
            if let file { try FileManager.default.moveItem(at: removal, to: file) }
            throw error
        }
        tasks.removeValue(forKey: id)?.cancel()
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

    func loadPackageIcons() async {
        guard !iconsLoading else { return }
        iconsLoading = true
        defer { iconsLoading = false }
        for job in jobs where job.status == .completed && job.rawFormat == nil {
            guard let file = fileURL(job), !Task.isCancelled else { continue }
            if job.packageIconScanned != true {
                _ = await Task.detached(priority: .utility) {
                    try? PackageIconService.save(from: file, id: job.id)
                }.value
                guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
                    try? FileManager.default.removeItem(at: PackageIconService.cacheURL(job.id))
                    continue
                }
                jobs[index].packageIconScanned = true
                // Never erase the catalog icon because IPA icon extraction failed.
                if jobs[index].app.iconURL == nil {
                    jobs[index].app.iconURL = jobs[index].asset?.app.iconURL
                }
                persist()
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
            Task { @MainActor in
                self?.persist()
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
                        try MacPackageDecryptor.decrypt(hardwareID: secret.hardwareID, dpInfo: secret.dpInfo,
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
                self.persist(); self.notify(title: "安装包已准备好", body: result.1.name + " " + result.1.version)
                Task { await self.loadPackageIcons() }
            } catch { self.fail(id, error: error) }
        }
    }

    private func monitorMacProcessing(_ id: UUID) async {
        let total = (try? FileManager.default.attributesOfItem(atPath: LocalResources.stagingURL(id).path)[.size] as? NSNumber)?.int64Value ?? 0
        while !Task.isCancelled {
            if let status = MacPackageDecryptor.status() {
                var text = status.stage.title
                if status.stage == .decrypting, total > 0 {
                    text += String(format: " %.0f%%", min(100, Double(status.bytes) * 100 / Double(total)))
                } else if status.stage == .components {
                    text += "（首次使用需从 Apple 下载约 47 MB）"
                }
                processingDetail[id] = text
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func discoverLocalFiles() {
        guard storageError == nil else { return }
        let known = Set(jobs.compactMap(\.localFilename))
        let files = (try? FileManager.default.contentsOfDirectory(at: LocalResources.packages, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "ipa" && !known.contains(file.lastPathComponent) {
            guard LocalResources.packageURL(file.lastPathComponent) != nil else { continue }
            Task {
                do {
                    let app = try await Task.detached { try PackageService.inspect(file) }.value
                    guard !self.jobs.contains(where: { $0.localFilename == file.lastPathComponent }) else { return }
                    self.jobs.append(DownloadJob(app: app, status: .completed, downloaded: app.size, expected: app.size, localFilename: file.lastPathComponent))
                    self.persist()
                } catch { self.discoveryWarning = "本地 IPA 无法读取，已保留原文件；其他任务可继续使用：\(file.lastPathComponent)\n\(error.localizedDescription)" }
            }
        }
    }

    private func fail(_ id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        tasks.removeValue(forKey: id)
        progressPublishedAt.removeValue(forKey: id)
        jobs[index].status = .failed; jobs[index].error = error.localizedDescription
        persist(); schedule()
        notify(title: "下载任务失败", body: jobs[index].app.name + "：" + error.localizedDescription)
    }
    private func persist() {
        guard storageError == nil else { return }
        do { try saveJobs(jobs); lastSave = Date() }
        catch { storageError = "无法保存下载任务：" + error.localizedDescription }
    }
    private func saveNewJobs(_ next: [DownloadJob]) throws {
        // Commit the file before publishing a newly enqueued/imported/retried task.
        try saveJobs(next)
        jobs = next; lastSave = Date()
    }
    private func requestNotifications() {
        guard notifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    private func notify(title: String, body: String) {
        guard notifications else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    private func finishBackgroundIfReady() {
        guard processingIDs.isEmpty else { return }
        let completion = backgroundCompletion; backgroundCompletion = nil; completion?()
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
              length >= 8 else { throw ToolError.message("下载的 Mac 文件不完整") }
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
            guard length >= 512 else { throw ToolError.message("DMG 文件不完整") }
            try file.seek(toOffset: UInt64(length - 512))
            valid = (try file.read(upToCount: 4) ?? Data()) == Data("koly".utf8)
        }
        guard valid else { throw ToolError.message("文件内容不是有效的 \(format.uppercased()) 安装包") }
        let filename = "\(job.id.uuidString)-\(PackageService.safeName(job.app.name).prefix(40)).\(format)"
        let destination = LocalResources.packages.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError.message("文件名已存在，停止覆盖原始安装包")
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
                  self.tasks[id]?.taskIdentifier == downloadTask.taskIdentifier else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let finished = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
            guard finished || now - (self.progressPublishedAt[id] ?? 0) >= 0.25 else { return }
            self.progressPublishedAt[id] = now
            if var metric = self.transferMetrics[id] {
                metric.record(bytes: totalBytesWritten, at: now)
                self.transferMetrics[id] = metric
            } else { self.transferMetrics[id] = TransferMetrics(bytes: totalBytesWritten, sampledAt: now) }
            var job = self.jobs[index]
            job.downloaded = totalBytesWritten
            job.expected = max(0, totalBytesExpectedToWrite)
            self.jobs[index] = job
            if Date().timeIntervalSince(self.lastSave) > 1 { self.persist() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value) else { return }
        // A callback from an old task must never replace a newer task's staging file.
        let received = LocalResources.support.appendingPathComponent("\(id.uuidString)-\(downloadTask.taskIdentifier).received")
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw ToolError.message("下载失败：HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)，可刷新链接后重试")
            }
            // Move synchronously: URLSession deletes its temporary file as soon as this delegate returns.
            try FileManager.default.moveItem(at: location, to: received)
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: received) }
                guard let index = self.jobs.firstIndex(where: { $0.id == id }),
                      [.running, .pausing].contains(self.jobs[index].status),
                      self.tasks[id]?.taskIdentifier == downloadTask.taskIdentifier || self.restoring else { return }
                do {
                    let destination = LocalResources.stagingURL(id)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: received, to: destination)
                } catch { self.fail(id, error: error); return }
                self.tasks.removeValue(forKey: id)
                self.progressPublishedAt.removeValue(forKey: id)
                self.jobs[index].status = .processing; self.persist(); self.schedule(); self.process(id)
            }
        } catch {
            try? FileManager.default.removeItem(at: received)
            Task { @MainActor in
                guard self.tasks[id]?.taskIdentifier == downloadTask.taskIdentifier || self.restoring else { return }
                self.fail(id, error: error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, let value = task.taskDescription, let id = UUID(uuidString: value) else { return }
        let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard let job = self.jobs.first(where: { $0.id == id }), job.status != .completed && job.status != .processing else { return }
            guard self.tasks[id]?.taskIdentifier == task.taskIdentifier || self.restoring else { return }
            if job.status == .pausing || job.status == .paused { return }
            if let resume = resume { try? resume.write(to: LocalResources.resumeURL(id), options: .atomic) }
            else { try? FileManager.default.removeItem(at: LocalResources.resumeURL(id)) }
            self.fail(id, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.finishBackgroundIfReady()
        }
    }
}
