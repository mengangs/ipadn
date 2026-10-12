import Foundation
import Combine
import UserNotifications
import UIKit

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let sessionID = "IPATool.background.downloads"
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var storageError: String?
    var backgroundCompletion: (() -> Void)?
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var restoring = true
    private var maxConcurrent = 3
    private var maxQueued = 10
    private var processingIDs = Set<UUID>()
    private var notifications = true
    private var lastSave = Date.distantPast
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

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
                    jobs[index].status = .paused
                    download.cancel(byProducingResumeData: { data in
                        if let data = data { try? data.write(to: LocalResources.resumeURL(id), options: .atomic) }
                    })
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
        jobs.insert(DownloadJob(app: asset.app, asset: asset, sourceURL: asset.url, expected: asset.app.size), at: 0)
        persist(); requestNotifications(); schedule()
    }

    func enqueueURL(_ url: URL) throws {
        guard url.scheme == "https" else { throw ToolError.message("下载链接必须使用 HTTPS") }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        guard jobs.filter({ $0.status != .completed && $0.status != .failed }).count < maxQueued else {
            throw ToolError.message("已达到等待任务上限，可在设置中调整")
        }
        let name = url.deletingPathExtension().lastPathComponent
        jobs.insert(DownloadJob(app: StoreApp(id: UUID().uuidString, name: name.isEmpty ? "导入安装包" : name), sourceURL: url), at: 0)
        persist(); requestNotifications(); schedule()
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
        jobs[index].status = .running; jobs[index].error = nil
        persist(); task.resume()
    }
    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].status == .queued { jobs[index].status = .paused; persist(); return }
        guard jobs[index].status == .running, let task = tasks[id] else { return }
        jobs[index].status = .pausing; persist()
        task.cancel(byProducingResumeData: { data in
            if let data = data { try? data.write(to: LocalResources.resumeURL(id), options: .atomic) }
            Task { @MainActor in
                self.tasks.removeValue(forKey: id)
                if let index = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[index].status == .pausing {
                    self.jobs[index].status = .paused
                }
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
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard job.status != .processing, job.status != .pausing else { throw ToolError.message("请等待当前文件处理或暂停完成后再删除") }
        tasks.removeValue(forKey: id)?.cancel()
        if let file = fileURL(job) { try FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: LocalResources.resumeURL(id))
        try? FileManager.default.removeItem(at: LocalResources.stagingURL(id))
        jobs.removeAll { $0.id == id }; persist(); schedule()
    }
    func fileURL(_ job: DownloadJob) -> URL? {
        guard let filename = job.localFilename, filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        let url = LocalResources.packages.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func importFile(_ source: URL) async throws {
        guard source.isFileURL, ["ipa", "zip"].contains(source.pathExtension.lowercased()) else { throw ToolError.message("仅支持导入 IPA 或 ZIP 格式安装包") }
        guard storageError == nil else { throw ToolError.message(storageError!) }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let stage = LocalResources.stagingURL(id)
        let inspected = try await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.copyItem(at: source, to: stage)
                return try PackageService.inspect(stage)
            } catch { try? FileManager.default.removeItem(at: stage); throw error }
        }.value
        jobs.insert(DownloadJob(id: id, app: inspected, status: .processing), at: 0)
        persist(); process(id)
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
        Task {
            defer {
                self.processingIDs.remove(id)
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
                self.finishBackgroundIfReady()
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PackageService.finish(staging: LocalResources.stagingURL(id), id: id, asset: job.asset)
                }.value
                guard let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                self.jobs[index].localFilename = result.0
                let icon = self.jobs[index].app.iconURL
                self.jobs[index].app = result.1
                self.jobs[index].app.iconURL = icon
                self.jobs[index].status = .completed
                self.jobs[index].downloaded = result.1.size; self.jobs[index].expected = result.1.size
                self.jobs[index].error = nil
                try? FileManager.default.removeItem(at: LocalResources.stagingURL(id))
                try? FileManager.default.removeItem(at: LocalResources.resumeURL(id))
                self.persist(); self.notify(title: "安装包已准备好", body: result.1.name + " " + result.1.version)
            } catch { self.fail(id, error: error) }
        }
    }

    private func discoverLocalFiles() {
        guard storageError == nil else { return }
        let known = Set(jobs.compactMap(\.localFilename))
        let files = (try? FileManager.default.contentsOfDirectory(at: LocalResources.packages, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "ipa" && !known.contains(file.lastPathComponent) {
            Task {
                do {
                    let app = try await Task.detached { try PackageService.inspect(file) }.value
                    guard !self.jobs.contains(where: { $0.localFilename == file.lastPathComponent }) else { return }
                    self.jobs.append(DownloadJob(app: app, status: .completed, downloaded: app.size, expected: app.size, localFilename: file.lastPathComponent))
                    self.persist()
                } catch { self.storageError = "发现无法读取的本地 IPA：\(file.lastPathComponent)\n\(error.localizedDescription)" }
            }
        }
    }

    private func fail(_ id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        tasks.removeValue(forKey: id)
        jobs[index].status = .failed; jobs[index].error = error.localizedDescription
        persist(); schedule()
        notify(title: "下载任务失败", body: jobs[index].app.name + "：" + error.localizedDescription)
    }
    private func persist() {
        guard storageError == nil else { return }
        do { try LocalResources.save(jobs, filename: LocalResources.jobsFilename); lastSave = Date() }
        catch { storageError = "无法保存下载任务：" + error.localizedDescription }
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

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value) else { return }
        Task { @MainActor in
            guard let index = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[index].status == .running else { return }
            self.jobs[index].downloaded = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { self.jobs[index].expected = totalBytesExpectedToWrite }
            if Date().timeIntervalSince(self.lastSave) > 1 { self.persist() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw ToolError.message("下载失败：HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)，可刷新链接后重试")
            }
            let destination = LocalResources.stagingURL(id)
            try? FileManager.default.removeItem(at: destination)
            // Move synchronously: URLSession deletes its temporary file as soon as this delegate returns.
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in
                self.tasks.removeValue(forKey: id)
                guard let index = self.jobs.firstIndex(where: { $0.id == id }) else {
                    try? FileManager.default.removeItem(at: destination); return
                }
                self.jobs[index].status = .processing; self.persist(); self.schedule(); self.process(id)
            }
        } catch { Task { @MainActor in self.fail(id, error: error) } }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, let value = task.taskDescription, let id = UUID(uuidString: value) else { return }
        let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard let job = self.jobs.first(where: { $0.id == id }), job.status != .completed && job.status != .processing else { return }
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            if let current = self.tasks[id], current.taskIdentifier != task.taskIdentifier { return }
            if job.status == .pausing || job.status == .paused { return }
            if let resume = resume { try? resume.write(to: LocalResources.resumeURL(id), options: .atomic) }
            if error.code == NSURLErrorCannotResume { try? FileManager.default.removeItem(at: LocalResources.resumeURL(id)) }
            self.fail(id, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.finishBackgroundIfReady()
        }
    }
}
