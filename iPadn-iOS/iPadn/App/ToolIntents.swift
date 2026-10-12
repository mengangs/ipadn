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
                throw ToolError.message("仅支持 IPA 或 ZIP 文件")
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

struct ToolShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchAppIntent(), phrases: ["在 \(.applicationName) 搜索应用"],
                    shortTitle: "搜索应用", systemImageName: "magnifyingglass")
        AppShortcut(intent: ImportIPAIntent(), phrases: ["用 \(.applicationName) 导入安装包"],
                    shortTitle: "导入 IPA", systemImageName: "doc.badge.plus")
    }
}
