import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    /// Settings are grouped into pages, like the system's Settings app, so
    /// the first screen stays short.
    enum Page {
        case root, downloads, follow, appearance, sources, maintenance
        var title: LocalizedStringKey {
            switch self {
            case .root: return "设置"
            case .downloads: return "下载"
            case .follow: return "关注"
            case .appearance: return "外观与图标"
            case .sources: return "历史版本来源"
            case .maintenance: return "备份与维护"
            }
        }
    }
    var page = Page.root
    @EnvironmentObject private var store: ToolStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var icons = AppIconService()
    @State private var iconIssue: String?
    @State private var addingSource = false
    @State private var editingSourceID: UUID?
    /// Results of the last "check all sources", by source.
    @State private var sourceChecks: [UUID: SourceCheckState] = [:]
    @State private var share: SharedFile?
    @State private var resetSettings = false
    @State private var importingBackup = false
    @State private var pendingBackup: Data?
    @State private var clearCache = false
    /// The appearance the home screen icon has: fixed by the icon theme, or the
    /// system's (not iPadn's own appearance setting) when following the system.
    private var iconScheme: ColorScheme {
        switch icons.theme {
        case .light: return .light
        case .dark: return .dark
        case .automatic: return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
    }
    private func pageLink(_ page: Page, _ symbol: String, _ identifier: String) -> some View {
        NavigationLink { SettingsView(page: page) } label: { Label(page.title, systemImage: symbol) }
            .accessibilityIdentifier(identifier)
    }
    var body: some View {
        Form {
            if page == .root {
            Section {
                pageLink(.downloads, "arrow.down.circle", "settings.page.downloads")
                pageLink(.follow, "bell", "settings.page.follow")
                pageLink(.appearance, "paintbrush", "settings.page.appearance")
                pageLink(.sources, "clock.arrow.circlepath", "settings.page.sources")
                NavigationLink { InstallationSettingsView() } label: { Label("安装设置", systemImage: "arrow.down.app") }
                    .accessibilityIdentifier("settings.installation")
                pageLink(.maintenance, "wrench.and.screwdriver", "settings.page.maintenance")
            }
            }
            if page == .downloads {
            Section {
                Stepper("同时下载：\(store.settings.maxConcurrentDownloads)", value: $store.settings.maxConcurrentDownloads, in: 1...6)
                Stepper("等待任务上限：\(store.settings.maxQueuedDownloads)", value: $store.settings.maxQueuedDownloads, in: 1...100)
                Toggle("下载完成通知", isOn: $store.settings.notifications)
                Toggle("新版本提醒", isOn: $store.settings.updateNotifications)
                    .compatibleOnChange(of: store.settings.updateNotifications) { on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Toggle("实时活动显示下载进度", isOn: $store.settings.downloadLiveActivity)
                    .accessibilityIdentifier("settings.download-activity")
                Toggle("兼容下载模式", isOn: $store.settings.compatibleDownloadMode)
                if store.downloads.backgroundDownloadsUnavailable && !store.settings.compatibleDownloadMode {
                    Button(AppText.text("重新尝试后台下载")) { store.downloads.retryBackgroundDownloads(); store.infoMessage = AppText.text("下一个下载任务会重新尝试后台下载") }
                }
            } header: {
                Text("下载")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("关闭「新版本提醒」后，下载页不再显示新版本提示，也不发送通知。")
                    Text("下载时在锁定屏幕和灵动岛显示进度。iPadn 在后台时按测得的速度估算进度，回到 iPadn 后更新为实际进度。")
                    if store.downloads.backgroundDownloadsUnavailable && !store.settings.compatibleDownloadMode {
                        Text("当前签名下系统后台下载无法保存文件，已自动改用应用内下载，下载时请保持 iPadn 在前台。更换签名后可以点按「重新尝试后台下载」。")
                    } else {
                        Text("如在企业证书重签或特定环境下遇到“无法创建文件”报错，请开启兼容下载模式（使用应用前台直接下载，下载时请保持应用在前台）。")
                    }
                }
            }
            }
            if page == .follow {
            Section {
                Toggle("关注应用提醒", isOn: $store.settings.watchNotifications)
                    .compatibleOnChange(of: store.settings.watchNotifications) { on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Toggle("目标价提醒", isOn: $store.settings.targetPrices)
                    .accessibilityIdentifier("settings.target-prices")
            } header: { Text("关注") } footer: {
                Text("关注的应用有新版本、降价、限免或下架时通知你。后台检查的时间由系统决定，打开 iPadn 时也会检查。")
            }
            }
            if page == .appearance {
            Section("搜索与外观") {
                Picker("搜索结果数量", selection: $store.settings.searchLimit) {
                    ForEach([10, 30, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("外观", selection: $store.settings.appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }
            }
            Section {
                ForEach(AppIconService.Choice.allCases) { choice in
                    Button {
                        Task {
                            do { try await icons.select(choice) }
                            catch { iconIssue = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            // The preview shows the chosen theme (or the current one when following the system).
                            Image(choice.preview).resizable().scaledToFit().frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
                                .environment(\.colorScheme, iconScheme)
                            Text(choice.title).foregroundStyle(.primary)
                            Spacer()
                            if icons.changing && choice != icons.selected { ProgressView() }
                            else if icons.awaitingSystem?.style == choice {
                                Image(systemName: "clock").foregroundStyle(.secondary)
                                    .accessibilityLabel("等待系统同步")
                            }
                            else if icons.selected == choice { Image(systemName: "checkmark").foregroundStyle(.primary) }
                        }.frame(minHeight: 54).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(icons.changing || !icons.supported)
                        .accessibilityIdentifier("settings.icon." + choice.rawValue)
                        .accessibilityAddTraits(icons.selected == choice ? .isSelected : [])
                        .accessibilityRemoveTraits(icons.selected == choice ? [] : .isSelected)
                        .accessibilityValue(icons.selected == choice ? "已选中" : "未选中")
                }
                Picker("图标主题", selection: Binding(get: { icons.theme }, set: { theme in
                    Task {
                        do { try await icons.select(theme: theme) }
                        catch { iconIssue = error.localizedDescription }
                    }
                })) {
                    ForEach(AppIconService.Theme.allCases) { Text($0.title).tag($0) }
                }
                .disabled(icons.changing || !icons.supported)
                .accessibilityIdentifier("settings.icon.theme")
            } header: { Text("应用图标") } footer: {
                if let status = icons.statusHint {
                    Text(status)
                        .accessibilityIdentifier("settings.icon.status")
                } else if !icons.supported {
                    Text("当前设备不支持更换图标。")
                } else {
                    Text("默认使用深色图标。「跟随系统」会随主屏幕的浅色、深色和着色外观切换（iOS 18 及更新版本），也可以固定使用浅色图标。")
                }
            }
            }
            if page == .sources {
            ForEach($store.settings.versionSources) { $source in
                Section {
                    Button { editingSourceID = source.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                Text(source.urlTemplate).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if let check = sourceChecks[source.id] { SourceCheckLabel(state: check) }
                            }
                            Spacer()
                            Text(source.enabled ? "已启用" : "已停用").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("settings.source." + source.name)
                    .revealDelete(id: "source." + source.id.uuidString, title: "移除") {
                        let id = source.id
                        withAnimation { store.settings.versionSources.removeAll { $0.id == id } }
                    }
                } header: { if source.id == store.settings.versionSources.first?.id { Text("历史版本来源") } }
            }
            Section {
                Button { checkSources() } label: {
                    HStack {
                        Label("检测全部来源", systemImage: "checkmark.circle")
                        Spacer()
                        if sourceChecks.values.contains(.checking) { ProgressView() }
                    }
                }
                .disabled(sourceChecks.values.contains(.checking) || store.settings.versionSources.isEmpty)
                .accessibilityIdentifier("settings.sources.check")
                Button("添加版本来源", systemImage: "plus") { addingSource = true }
            } footer: {
                Text("用于查询应用的历史版本。检测会用微信的版本记录逐个请求每个来源，显示是否可用、返回的版本数和耗时。")
            }
            }
            if page == .downloads {
            Section {
                Toggle("加快重复下载", isOn: $store.settings.useSignerCache)
                Button("清除缓存") { store.signer.clearCache(); store.infoMessage = AppText.text("已清除缓存") }
            } header: { Text("性能") } footer: {
                Text("缓存仅在本次运行期间保留。")
            }
            }
            if page == .root {
            Section {
                Toggle("专业模式", isOn: $store.settings.proMode.animation())
                    .accessibilityIdentifier("settings.pro-mode")
                if store.settings.proMode {
                    NavigationLink { CredentialsView() } label: { Label("账号与设备标识", systemImage: "key") }
                        .accessibilityIdentifier("settings.credentials")
                }
            } footer: {
                Text(store.settings.proMode ? "可以在下载任务详情中浏览安装包内容，并查看账号令牌和设备标识。"
                     : "打开后可以浏览安装包内容、查看账号令牌和修改设备标识。")
            }
            }
            if page == .maintenance {
            Section {
                Button("导出设置与关注") {
                    do { share = SharedFile(url: try store.exportBackup()) } catch { store.errorMessage = error.localizedDescription }
                }
                .accessibilityIdentifier("settings.export-backup")
                Button("导入设置与关注") { importingBackup = true }
                    .accessibilityIdentifier("settings.import-backup")
            } header: { Text("备份") } footer: {
                Text("包含设置、版本来源、关注的应用及价格记录和最近搜索，不包含账号和已下载的安装包。换签名方式或换设备前导出，之后导入即可恢复。")
            }
            Section("维护") {
                NavigationLink { StorageView() } label: { Label("存储空间", systemImage: "internaldrive") }
                    .accessibilityIdentifier("settings.storage")
                Button("清除历史版本缓存") { clearCache = true }
                Button("导出诊断信息") {
                    do { share = SharedFile(url: try store.exportDiagnostics()) } catch { store.errorMessage = error.localizedDescription }
                }
                Button("复制诊断信息") { store.copyDiagnostics(); UX.feedback() }
                    .accessibilityIdentifier("settings.copy-diagnostics")
                Button("恢复默认设置", role: .destructive) { resetSettings = true }
            }
            }
            if page == .root {
            Section {
                // One compact row: the icon as chosen in 应用图标 (in the appearance
                // it currently shows), with the name, version and description beside it.
                HStack(alignment: .center, spacing: 14) {
                    Image(icons.selected.preview).resizable().scaledToFit().frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 52 * UX.iconCorner, style: .continuous))
                        .environment(\.colorScheme, iconScheme)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "iPadn").font(.headline)
                            Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("搜索、下载和管理你拥有许可的应用安装包，支持 iPhone、iPad、Apple TV 与 Mac。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                if let update = store.appUpdate {
                    NavigationLink { AppUpdateView(release: update) } label: {
                        Label("iPadn \(update.version) 可以更新", systemImage: "arrow.down.app.fill")
                            .foregroundStyle(.tint).fontWeight(.semibold)
                    }
                    .accessibilityIdentifier("settings.app-update")
                }
                Button {
                    Task {
                        let reached = await store.checkAppUpdate(force: true)
                        if !reached { store.errorMessage = AppText.text("暂时无法检查更新，请稍后重试。") }
                        else if store.appUpdate == nil { store.infoMessage = AppText.text("已是最新版本") }
                    }
                } label: {
                    HStack {
                        Text("检查更新")
                        Spacer()
                        if store.appUpdateChecking { ProgressView() }
                    }
                }
                .disabled(store.appUpdateChecking)
                Toggle("自动检查更新", isOn: $store.settings.appUpdateCheck)
                    .compatibleOnChange(of: store.settings.appUpdateCheck) { on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Link("项目与更新", destination: URL(string: "https://github.com/mengangs/ipadn")!)
            }
            Section {
                NavigationLink { SupportView() } label: { SupportRow() }
                    .accessibilityIdentifier("settings.support")
            }
            }
        }
        .toolPage().navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
        .compatibleOnChange(of: scenePhase) { phase in if phase == .active { icons.refresh() } }
        .alert("图标未更改", isPresented: Binding(get: { iconIssue != nil }, set: { if !$0 { iconIssue = nil } })) {
            Button("知道了", role: .cancel) { iconIssue = nil }
        } message: { Text(iconIssue ?? "") }
        .sheet(isPresented: $addingSource) { AddVersionSourceView() }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try AppBackup.decode(data)
                pendingBackup = data
            } catch { store.errorMessage = error.localizedDescription }
        }
        .actionConfirmation(isPresented: Binding(get: { pendingBackup != nil }, set: { if !$0 { pendingBackup = nil } }),
                            title: "导入这个备份？", message: "当前设置会被备份中的设置替换，关注的应用会合并。账号和已下载的安装包不受影响。",
                            confirmTitle: "导入", destructive: false) {
            guard let data = pendingBackup else { return }
            Task { do { try await store.importBackup(data) } catch { store.errorMessage = error.localizedDescription } }
        }
        .compatibleNavigationDestination(item: $editingSourceID) { id in
            if let index = store.settings.versionSources.firstIndex(where: { $0.id == id }) {
                VersionSourceEditor(source: $store.settings.versionSources[index])
            }
        }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .actionConfirmation(isPresented: $resetSettings, title: "恢复默认设置？", message: "账号、已下载的安装包和已购记录不受影响。", confirmTitle: "恢复默认设置") { store.settings = ToolSettings() }
        .actionConfirmation(isPresented: $clearCache, title: "清除历史版本缓存？", confirmTitle: "清除缓存") {
            Task { do { try await store.versions.clearCache(); store.infoMessage = AppText.text("已清除缓存") } catch { store.errorMessage = error.localizedDescription } }
        }
    }
}

extension SettingsView {
    /// Checks every source at once, enabled or not, and shows each result
    /// under its row as it arrives.
    private func checkSources() {
        let sources = store.settings.versionSources
        UX.feedback()
        for source in sources { sourceChecks[source.id] = .checking }
        for source in sources {
            Task {
                let result: SourceCheckState
                do {
                    let check = try await VersionService.check(source)
                    result = .available(versions: check.versions, seconds: check.seconds)
                } catch { result = .unavailable(error.localizedDescription) }
                sourceChecks[source.id] = result
            }
        }
    }
}

enum SourceCheckState: Equatable {
    case checking
    case available(versions: Int, seconds: Double)
    case unavailable(String)
}

/// One line under a version source: whether it answered, and how.
struct SourceCheckLabel: View {
    let state: SourceCheckState
    var body: some View {
        Group {
            switch state {
            case .checking:
                Label("正在检测…", systemImage: "clock").foregroundStyle(.secondary)
            case .available(let versions, let seconds):
                Label("可用 · \(versions) 个版本 · \(String(format: "%.1f", seconds)) 秒", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unavailable(let reason):
                Label("不可用：\(reason)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).lineLimit(2)
            }
        }
        .font(.caption)
        .accessibilityIdentifier("settings.sourceCheckResult")
    }
}

struct VersionSourceEditor: View {
    @Binding var source: VersionSource
    var body: some View {
        Form {
            Section("来源设置") {
                Toggle("启用", isOn: $source.enabled)
                TextField("来源名称", text: $source.name)
                TextField("接口地址，用 {id} 或 {appId} 代表 App ID", text: $source.urlTemplate)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("列表字段名（可留空）", text: $source.containerKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("倒序显示", isOn: $source.reverse)
            }
            Section("接口格式") {
                Text("[{\"external_identifier\":\"123\",\"bundle_version\":\"1.0\"}]")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("若返回 {\"data\":[…]}，列表容器键填写 data。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct AddVersionSourceView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = VersionSource(name: AppText.text("新来源"), urlTemplate: "https://", containerKey: "data", reverse: false)
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VersionSourceEditor(source: $source)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  source.url(for: "123") != nil else { error = AppText.text("请填写名称，以及包含 {id} 或 {appId} 的 https 接口地址"); return }
                            store.settings.versionSources.append(source); dismiss()
                        }
                    }
                }
                .alert("无法添加", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("好", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}
