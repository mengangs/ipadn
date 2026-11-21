import SwiftUI
import Combine

enum PackageRoute: Hashable {
    case source(UUID), record(UUID), file(URL), unlinked(URL), history, options, help, log(UUID)
}

struct StandalonePackageMeta: Equatable {
    let name: String
    let version: String
    let bundleID: String
    let bytes: Int64
    let iconURL: URL?
}

/// Presentation only. Tasks and history belong exclusively to the existing hub
/// and record store. No task is started until collision checks/confirmation pass.
@MainActor
final class FairPlayPresentation: ObservableObject {
    static let shared = FairPlayPresentation()
    @Published var path = NavigationPath() {
        didSet {
            if path.isEmpty {
                routes.removeAll()
            } else if path.count < routes.count {
                routes = Array(routes.prefix(path.count))
            }
        }
    }
    private(set) var routes: [PackageRoute] = []
    @Published private(set) var navigationRevision = UUID()
    @Published private(set) var fileRevision = UUID()
    @Published var replacement: StartRequest?
    @Published var busy = false
    @Published var message: String?
    @Published private(set) var detections: [URL: IPADetection] = [:]
    @Published private(set) var detecting: Set<URL> = []
    @Published private(set) var localMetadata: [URL: StandalonePackageMeta] = [:]
    private var detectedIdentities: [URL: String] = [:]
    private var metadataIdentities: [URL: String] = [:]
    private var detectionTasks: [URL: Task<Void, Never>] = [:]
    private var metadataTasks: [URL: Task<Void, Never>] = [:]
    private var cancellation = Set<UUID>()
    private var cachedFileRevision: UUID?
    private var cachedRecordRevision: Int = -1
    private var currentOutputCache: [UUID: URL?] = [:]
    private var fileSizeCache: [URL: Int] = [:]

    private func ensureLookupCacheCurrent() {
        let rev = records.cacheRevision
        if cachedFileRevision != fileRevision || cachedRecordRevision != rev {
            currentOutputCache.removeAll(keepingCapacity: true)
            fileSizeCache.removeAll(keepingCapacity: true)
            cachedFileRevision = fileRevision
            cachedRecordRevision = rev
        }
    }

    private func cachedFileSize(of url: URL) -> Int {
        ensureLookupCacheCurrent()
        if let size = fileSizeCache[url] { return size }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        fileSizeCache[url] = size
        return size
    }

    struct StartRequest: Identifiable {
        let id = UUID()
        let url: URL
        let job: DownloadJob?
        let collisions: [URL]
        let signatures: [String]
    }

    var service: FairPlayService { FairPlayHub.shared.service }
    var records: DecryptRecordStore { .shared }

    func navigate(_ route: PackageRoute) {
        var next = NavigationPath()
        next.append(route)
        routes = [route]
        path = next
        navigationRevision = UUID()
    }

    func push(_ route: PackageRoute) {
        routes.append(route)
        path.append(route)
        navigationRevision = UUID()
    }

    func showLibrary() {
        clearPath()
        navigationRevision = UUID()
    }

    /// Resets the package stack without bumping `navigationRevision` (used when leaving Pro Mode).
    func clearPath() {
        routes.removeAll()
        if !path.isEmpty { path = NavigationPath() }
    }

    func notePresented(_ route: PackageRoute) {
        guard path.count > 0 else { return }
        if routes.count == path.count {
            routes[routes.count - 1] = route
        } else if routes.count < path.count {
            routes.append(route)
        }
    }

    var previousRoute: PackageRoute? {
        routes.dropLast().last
    }

    func markFilesChanged() {
        records.invalidateFileCaches()
        currentOutputCache.removeAll(keepingCapacity: true)
        fileSizeCache.removeAll(keepingCapacity: true)
        fileRevision = UUID()
        cachedFileRevision = fileRevision
        cachedRecordRevision = records.cacheRevision
    }

    func source(for record: DecryptRecord, manager: DownloadManager) -> URL? {
        if let job = job(for: record, manager: manager), let url = manager.fileURL(job) { return url }
        return records.sourceURL(for: record)
    }

    func job(for record: DecryptRecord, manager: DownloadManager) -> DownloadJob? {
        if let id = record.sourceJobID { return manager.jobs.first { $0.id == id } }
        let matches = manager.jobs.filter { job in
            guard let url = manager.fileURL(job), url.lastPathComponent == record.sourceName else { return false }
            return cachedFileSize(of: url) == record.sourceBytes
        }
        return matches.count == 1 ? matches.first : nil
    }

    func attempts(url: URL, jobID: UUID? = nil) -> [DecryptRecord] {
        let size = cachedFileSize(of: url)
        return records.records.filter {
            if let jobID, $0.sourceJobID == jobID { return true }
            return $0.sourceJobID == nil && $0.sourceName == url.lastPathComponent && $0.sourceBytes == size
        }
    }

    func iconURL(for url: URL, job: DownloadJob?, manager: DownloadManager) -> URL? {
        if let job { return manager.packageIconURL(job) ?? job.app.iconURL }
        if let icon = localMetadata[url]?.iconURL { return icon }
        #if canImport(TestFlightKit)
        if let icon = TFProductIndex.shared.item(forFile: url)?.iconURL { return icon }
        #endif
        return nil
    }

    func iconURL(for record: DecryptRecord, manager: DownloadManager) -> URL? {
        if let cached = records.iconURL(for: record) { return cached }
        if let job = job(for: record, manager: manager) {
            return manager.packageIconURL(job) ?? job.app.iconURL
        }
        if let source = records.sourceURL(for: record) {
            if let icon = localMetadata[source]?.iconURL { return icon }
            #if canImport(TestFlightKit)
            if let icon = TFProductIndex.shared.item(forFile: source)?.iconURL { return icon }
            #endif
        }
        return nil
    }

    func requestStart(url: URL, job: DownloadJob? = nil, automatic: Bool = false) {
        guard AppContainer.shared.settings.proMode else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if !automatic { message = AppText.text("原始 IPA 已不存在，请重新导入。") }
            return
        }
        guard !service.isRunning else {
            if !automatic {
                if let record = records.records.first(where: { $0.id == service.activeRecordID }),
                   record.sourceJobID == job?.id && record.sourceName == url.lastPathComponent {
                    navigate(.record(record.id))
                } else { busy = true }
            }
            return
        }
        if detections[url] == nil || detectedIdentities[url] != signature(url) {
            Task { @MainActor in
                await detect(url)
                requestStart(url: url, job: job, automatic: automatic)
            }
            return
        }
        if detections[url]?.state == .plain {
            if !automatic { message = AppText.text("这份 IPA 未加密，可以直接保存或分享原始文件。") }
            return
        }
        let collisions = collisionURLs(source: url)
        if !collisions.isEmpty {
            // Automatic operation NEVER implicitly accepts replacement.
            if !automatic {
                replacement = StartRequest(url: url, job: job, collisions: collisions, signatures: collisions.map(signature))
            }
            return
        }
        start(url: url, job: job, automatic: automatic)
    }

    func confirmReplacement(_ request: StartRequest) {
        replacement = nil
        guard AppContainer.shared.settings.proMode else { return }
        guard !service.isRunning else { busy = true; return }
        let current = collisionURLs(source: request.url)
        guard current.map(signature) == request.signatures else {
            // A file changed while the dialog was open: consent is invalid.
            requestStart(url: request.url, job: request.job)
            return
        }
        start(url: request.url, job: request.job, automatic: false)
    }

    private func start(url: URL, job: DownloadJob?, automatic: Bool) {
        guard AppContainer.shared.settings.proMode else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { message = AppText.text("原始 IPA 已不存在，请重新导入。"); return }
        let meta = localMetadata[url]
        #if canImport(TestFlightKit)
        let tfItem = TFProductIndex.shared.item(forFile: url)
        let tfDisplayName = tfItem?.displayName
        let tfBundleID = tfItem?.bundleID
        let tfVersion = tfItem?.shortVersion.isEmpty == false ? tfItem?.shortVersion : nil
        let tfIconURL = tfItem?.iconURL
        #else
        let tfDisplayName: String? = nil
        let tfBundleID: String? = nil
        let tfVersion: String? = nil
        let tfIconURL: URL? = nil
        #endif
        let name = job?.app.name ?? tfDisplayName ?? meta?.name ?? url.deletingPathExtension().lastPathComponent
        if automatic {
            service.autoStartIfNeeded(source: url, displayName: name, appName: name, jobID: job?.id)
        } else {
            service.start(source: url, displayName: name, appName: name, jobID: job?.id,
                          origin: job?.asset == nil && job?.sourceURL == nil ? .imported : .manual)
        }
        if let id = service.activeRecordID {
            let fallbackIcon = job.flatMap({ DownloadManagerIcon.url($0) }) ?? meta?.iconURL ?? tfIconURL
            records.update(id: id) { record in
                record.bundleID = job?.app.bundleID ?? meta?.bundleID ?? tfBundleID
                record.version = job?.app.version ?? meta?.version ?? tfVersion
                record.detection = detections[url]
            }
            Task.detached(priority: .utility) { [url, id, fallbackIcon] in
                let png: Data?
                if let icon = fallbackIcon, icon.isFileURL, let data = try? Data(contentsOf: icon) {
                    png = data
                } else {
                    png = try? PackageIconService.png(from: url)
                }
                guard let png else { return }
                await MainActor.run {
                    DecryptRecordStore.shared.update(id: id) { record in
                        if record.iconName == nil {
                            record.iconName = DecryptRecordStore.shared.storeIcon(png, for: id)
                        }
                    }
                }
            }
            if !automatic { navigate(.record(id)) }
        }
    }

    enum StandaloneDecryptOutcome {
        case started(UUID)
        case unavailable(String)
    }

    /// Starts decryption for a standalone / TestFlight IPA from an in-place modal sheet,
    /// enforcing file existence, single-active-run guard, and full metadata/icon recording
    /// (never hijacking another running job's `activeRecordID`).
    func startStandaloneDecrypt(url: URL, displayName: String) -> StandaloneDecryptOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable(AppText.text("原始 IPA 已不存在，请重新导入。"))
        }
        if service.isRunning {
            if let activeID = service.activeRecordID,
               let active = records.records.first(where: { $0.id == activeID }),
               active.sourceJobID == nil,
               active.sourceName == url.lastPathComponent {
                return .started(activeID)
            }
            return .unavailable(AppText.text("当前已有解密任务正在进行，请等待完成后再试。"))
        }
        let meta = localMetadata[url]
        #if canImport(TestFlightKit)
        let tfItem = TFProductIndex.shared.item(forFile: url)
        let tfName = tfItem?.displayName
        let tfBundleID = tfItem?.bundleID
        let tfVersion = tfItem?.shortVersion.isEmpty == false ? tfItem?.shortVersion : nil
        let tfIconURL = tfItem?.iconURL
        #else
        let tfName: String? = nil
        let tfBundleID: String? = nil
        let tfVersion: String? = nil
        let tfIconURL: URL? = nil
        #endif
        let resolvedName = displayName.isEmpty ? (tfName ?? meta?.name ?? url.deletingPathExtension().lastPathComponent) : displayName
        service.start(source: url, displayName: resolvedName, appName: resolvedName, jobID: nil, origin: .imported)
        guard let id = service.activeRecordID else {
            return .unavailable(AppText.text("无法启动解密任务，请稍后重试。"))
        }
        let fallbackIcon = meta?.iconURL ?? tfIconURL
        records.update(id: id) { record in
            record.bundleID = meta?.bundleID ?? tfBundleID
            record.version = meta?.version ?? tfVersion
            record.detection = detections[url]
        }
        Task.detached(priority: .utility) { [url, id, fallbackIcon] in
            let png: Data?
            if let icon = fallbackIcon, icon.isFileURL, let data = try? Data(contentsOf: icon) {
                png = data
            } else {
                png = try? PackageIconService.png(from: url)
            }
            guard let png else { return }
            await MainActor.run {
                DecryptRecordStore.shared.update(id: id) { record in
                    if record.iconName == nil {
                        record.iconName = DecryptRecordStore.shared.storeIcon(png, for: id)
                    }
                }
            }
        }
        return .started(id)
    }

    func collisionURLs(source: URL) -> [URL] {
        PackageOutputPolicy.existing(source: source, directory: records.outputDirectory)
    }

    private func signature(_ url: URL) -> String {
        PackageOutputPolicy.identity(url)
    }

    func currentOutput(_ record: DecryptRecord) -> URL? {
        guard let name = record.outputName else { return nil }
        ensureLookupCacheCurrent()
        if let cached = currentOutputCache[record.id] { return cached }
        // Multiple historical attempts can point at one physical output. Only
        // the newest writer's verification belongs to that file.
        guard records.records.first(where: { $0.outputName == name })?.id == record.id else {
            currentOutputCache[record.id] = nil
            return nil
        }
        guard let url = records.outputURL(for: record) else {
            currentOutputCache[record.id] = nil
            return nil
        }
        if let identity = record.outputIdentity {
            if !PackageOutputPolicy.matches(identity, url: url) {
                currentOutputCache[record.id] = nil
                return nil
            }
        }
        currentOutputCache[record.id] = url
        return url
    }

    func captureOutputIdentity() {
        guard !service.isRunning, let id = service.activeRecordID,
              let record = records.records.first(where: { $0.id == id }), let url = records.outputURL(for: record) else { return }
        let identity = signature(url)
        guard record.outputIdentity != identity else { return }
        records.update(id: id) { $0.outputIdentity = identity }
    }

    func adoptLegacyOutputIdentities() {
        var names = Set<String>()
        for record in records.records {
            guard let name = record.outputName else { continue }
            let newest = names.insert(name).inserted
            guard record.outputIdentity == nil else { continue }
            let identity = newest ? records.outputURL(for: record).map(signature) : nil
            records.update(id: record.id) { $0.outputIdentity = identity ?? "superseded-or-missing" }
        }
    }

    func protects(_ jobID: UUID) -> Bool {
        service.isRunning && records.records.first(where: { $0.id == service.activeRecordID })?.sourceJobID == jobID
    }

    func protects(url: URL) -> Bool {
        guard service.isRunning, let id = service.activeRecordID,
              let record = records.records.first(where: { $0.id == id }) else { return false }
        let size = cachedFileSize(of: url)
        return record.sourceName == url.lastPathComponent && record.sourceBytes == size
    }

    func cancel() {
        guard let id = service.activeRecordID, service.isRunning, cancellation.insert(id).inserted else { return }
        service.cancel()
    }

    var isCancelling: Bool { service.activeRecordID.map { cancellation.contains($0) } ?? false }
    var canCancel: Bool { service.isRunning && !isCancelling && !["重新打包", "校验产物", "完成"].contains(service.step) }

    func detect(_ url: URL, force: Bool = false) async {
        if let running = detectionTasks[url] {
            await running.value
            if !force { return }
        }
        let identity = signature(url)
        guard force || detections[url] == nil || detectedIdentities[url] != identity else { return }
        detecting.insert(url)
        let task = Task { @MainActor in
            let result = await Task.detached(priority: .utility) { IPAInspector.inspect(url: url) }.value
            detections[url] = result
            detectedIdentities[url] = identity
            detecting.remove(url)
            detectionTasks[url] = nil
        }
        detectionTasks[url] = task
        await task.value
    }

    func loadMetadata(for url: URL) async {
        if let running = metadataTasks[url] {
            await running.value
            return
        }
        let identity = signature(url)
        guard localMetadata[url] == nil || metadataIdentities[url] != identity else { return }
        let task = Task { @MainActor in
            let meta = await Task.detached(priority: .utility) { () -> StandalonePackageMeta? in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let inspected = try? PackageService.inspect(url)
                let iconFolder = LocalResources.support.appendingPathComponent("StandaloneIcons", isDirectory: true)
                let key = "\(PackageService.safeName(url.deletingPathExtension().lastPathComponent))-\(bytes).png"
                let iconTarget = iconFolder.appendingPathComponent(key)
                var iconURL: URL? = FileManager.default.fileExists(atPath: iconTarget.path) ? iconTarget : nil
                if iconURL == nil, let png = try? PackageIconService.png(from: url) {
                    try? FileManager.default.createDirectory(at: iconFolder, withIntermediateDirectories: true)
                    if (try? png.write(to: iconTarget, options: .atomic)) != nil {
                        iconURL = iconTarget
                    }
                }
                let rawName = inspected?.name ?? url.deletingPathExtension().lastPathComponent
                return StandalonePackageMeta(
                    name: rawName,
                    version: inspected?.version ?? "",
                    bundleID: inspected?.bundleID ?? "",
                    bytes: bytes,
                    iconURL: iconURL
                )
            }.value
            if let meta {
                localMetadata[url] = meta
                metadataIdentities[url] = identity
            }
            metadataTasks[url] = nil
        }
        metadataTasks[url] = task
        await task.value
    }
}

/// Existing icon cache location, no archive read on the main thread.
private enum DownloadManagerIcon {
    static func url(_ job: DownloadJob) -> URL? {
        let url = PackageIconService.cacheURL(job.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum DecryptOutcomeStyle: Equatable {
    case running, success, plain, partial, failed, cancelled, interrupted
    init(_ record: DecryptRecord) {
        if record.state == .running { self = .running }
        else if record.state == .cancelled { self = .cancelled }
        else if record.state == .interrupted { self = .interrupted }
        else if record.state == .plain { self = .plain }
        else if record.verification == .partial || record.failure?.kind == .partial { self = .partial }
        else if record.state == .finished && record.verification == .clean { self = .success }
        else { self = .failed }
    }
    var title: String {
        switch self {
        case .running: return AppText.text("正在解密")
        case .success: return AppText.text("解密完成")
        case .plain: return AppText.text("无需解密")
        case .partial: return AppText.text("部分成功")
        case .failed: return AppText.text("解密未完成")
        case .cancelled: return AppText.text("已取消")
        case .interrupted: return AppText.text("任务被中断")
        }
    }
    var symbol: String {
        switch self {
        case .running: return "lock.open"
        case .success: return "checkmark.circle.fill"
        case .plain: return "info.circle"
        case .partial, .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        case .interrupted: return "bolt.horizontal.circle"
        }
    }
    var color: Color {
        switch self {
        case .success: return .green
        case .partial, .interrupted: return .orange
        case .failed: return .red
        case .running: return UX.tint
        default: return .secondary
        }
    }
}
