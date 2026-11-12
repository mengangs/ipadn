import AppIntents
import Foundation

struct SearchAppIntent: AppIntent {
    static var title: LocalizedStringResource = "搜索应用或商店链接"
    static var description = IntentDescription("打开 iPadn，搜索名称、App ID、商店链接或 App ID 与版本 ID。")
    static var openAppWhenRun = true
    @Parameter(title: "搜索内容") var query: String
    static var parameterSummary: some ParameterSummary { Summary("搜索 \(\.$query)") }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try SearchQuery.parse(query)
        AppContainer.shared.tab = 0
        AppContainer.shared.search(query)
        return .result()
    }
}

struct ImportIPAIntent: AppIntent {
    static var title: LocalizedStringResource = "导入 IPA 安装包"
    static var description = IntentDescription("将文件导入 iPadn，并打开下载管理。可用于分享菜单中的快捷指令。")
    static var openAppWhenRun = true
    @Parameter(title: "IPA 文件") var file: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("导入 \(\.$file)") }
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppContainer.shared
        store.tab = 1
        if let url = file.fileURL { try await store.downloads.importFile(url) }
        else {
            let name = PackageService.safeName(file.filename)
            guard ["ipa", "zip"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
                throw ToolError.message(AppText.text("仅支持 IPA 或 ZIP 文件"))
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try file.data.write(to: temporary, options: .atomic)
            try await store.downloads.importFile(temporary)
        }
        return .result()
    }
}

struct DownloadIPAURLIntent: AppIntent {
    static var title: LocalizedStringResource = "下载 IPA 链接"
    static var description = IntentDescription("把 HTTPS 安装包链接添加至后台下载队列。")
    static var openAppWhenRun = true
    @Parameter(title: "HTTPS 下载链接") var url: URL
    static var parameterSummary: some ParameterSummary { Summary("下载 \(\.$url)") }
    @MainActor func perform() async throws -> some IntentResult {
        try AppContainer.shared.downloads.enqueueURL(url)
        AppContainer.shared.tab = 1
        return .result()
    }
}

/// Looks up an App ID or App Store link in the current storefront.
@MainActor
private func storeApp(_ input: String) async throws -> (app: StoreApp, versionID: String?) {
    guard case .appID(let id, let versionID) = try SearchQuery.parse(input) else {
        throw ToolError.message(AppText.text("请输入 App ID 或 App Store 链接"))
    }
    let store = AppContainer.shared
    let country = store.settings.store.country
    guard let app = try await StoreService.lookup(ids: [id], country: country).apps[id] else {
        throw ToolError.message(AppText.text("在 \(StoreRegions.name(country.uppercased())) 商店找不到这个应用"))
    }
    return (app, versionID)
}

struct DownloadAppIntent: AppIntent {
    static var title: LocalizedStringResource = "下载应用"
    static var description = IntentDescription("用当前账号下载 App ID 或 App Store 链接对应的应用（可带版本 ID），并打开下载管理。")
    static var openAppWhenRun = true
    @Parameter(title: "App ID 或商店链接") var app: String
    static var parameterSummary: some ParameterSummary { Summary("下载 \(\.$app)") }
    @MainActor func perform() async throws -> some IntentResult {
        let store = AppContainer.shared
        guard store.apple.active != nil else { throw ToolError.message(AppText.text("请先在「账号」中登录 Apple 账号")) }
        let found = try await storeApp(app)
        await store.downloads.loaded()
        try await store.startDownload(app: found.app, versionID: found.versionID)
        return .result()
    }
}

struct CheckUpdatesIntent: AppIntent {
    static var title: LocalizedStringResource = "检查已下载应用的更新"
    static var description = IntentDescription("对比已下载的应用与商店的最新版本，返回有新版本的应用。")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let store = AppContainer.shared
        await store.downloads.loaded()
        await store.checkForUpdates(force: true)
        let lines = store.updatableJobs.compactMap { job -> String? in
            guard let key = job.updateKey, let latest = store.availableUpdates[key] else { return nil }
            return "\(job.app.name) \(job.app.version) → \(latest.version)"
        }
        let text = lines.isEmpty ? AppText.text("已下载的应用都是最新版本。") : lines.joined(separator: "\n")
        return .result(value: lines, dialog: "\(text)")
    }
}

struct DownloadAllUpdatesIntent: AppIntent {
    static var title: LocalizedStringResource = "下载全部更新"
    static var description = IntentDescription("检查已下载应用的更新，并把所有新版本加入下载队列。")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppContainer.shared
        await store.downloads.loaded()
        await store.checkForUpdates(force: true)
        let jobs = store.updatableJobs
        guard !jobs.isEmpty else { return .result(dialog: "\(AppText.text("已下载的应用都是最新版本。"))") }
        store.tab = 1
        try await store.downloadAllUpdates(of: jobs)
        return .result(dialog: "\(AppText.text("已添加 \(jobs.count) 个下载任务"))")
    }
}

struct DownloadStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "获取下载进度"
    static var description = IntentDescription("返回正在进行和等待中的下载任务及其进度。")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let manager = AppContainer.shared.downloads
        await manager.loaded()
        let lines = manager.jobs.compactMap { job -> String? in
            let state = manager.progress(for: job.id).bytes
            let written = state?.written ?? job.downloaded, expected = max(state?.expected ?? 0, job.expected)
            let percent = (expected > 0 ? Double(written) / Double(expected) : 0).formatted(.percent.precision(.fractionLength(0)))
            switch job.status {
            case .running, .pausing: return AppText.text("\(job.app.name)：正在下载 \(percent)%")
            case .queued: return AppText.text("\(job.app.name)：等待中")
            case .paused: return AppText.text("\(job.app.name)：已暂停 \(percent)%")
            case .processing: return AppText.text("\(job.app.name)：正在处理")
            default: return nil
            }
        }
        let text = lines.isEmpty ? AppText.text("没有进行中的下载。") : lines.joined(separator: "\n")
        return .result(value: lines, dialog: "\(text)")
    }
}

struct PauseAllDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "暂停全部下载"
    static var description = IntentDescription("暂停正在进行和等待中的下载，进度会保留。")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = AppContainer.shared.downloads
        await manager.loaded()
        let count = manager.jobs.filter { $0.status == .running || $0.status == .queued }.count
        manager.pauseAll()
        return .result(dialog: "\(AppText.text("已暂停 \(count) 个下载任务"))")
    }
}

struct ResumeAllDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "继续全部下载"
    static var description = IntentDescription("继续所有已暂停的下载。")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = AppContainer.shared.downloads
        await manager.loaded()
        let count = manager.jobs.filter { $0.status == .paused }.count
        manager.resumeAll()
        return .result(dialog: "\(AppText.text("已继续 \(count) 个下载任务"))")
    }
}

struct FollowAppIntent: AppIntent {
    static var title: LocalizedStringResource = "关注应用"
    static var description = IntentDescription("关注 App ID 或 App Store 链接对应的应用；有新版本、降价或限免时提醒你。")
    @Parameter(title: "App ID 或商店链接") var app: String
    static var parameterSummary: some ParameterSummary { Summary("关注 \(\.$app)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppContainer.shared
        let found = try await storeApp(app).app
        if store.isFavorite(found) { return .result(dialog: "\(AppText.text("已经在关注 \(found.name)"))") }
        store.toggleFavorite(found)
        return .result(dialog: "\(AppText.text("已关注 \(found.name)"))")
    }
}

struct ToolShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchAppIntent(), phrases: ["在 \(.applicationName) 搜索应用"],
                    shortTitle: "搜索应用", systemImageName: "magnifyingglass")
        AppShortcut(intent: ImportIPAIntent(), phrases: ["用 \(.applicationName) 导入安装包"],
                    shortTitle: "导入 IPA", systemImageName: "doc.badge.plus")
        AppShortcut(intent: CheckUpdatesIntent(), phrases: ["用 \(.applicationName) 检查更新"],
                    shortTitle: "检查更新", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: DownloadStatusIntent(), phrases: ["\(.applicationName) 的下载进度"],
                    shortTitle: "下载进度", systemImageName: "arrow.down.circle")
    }
}
