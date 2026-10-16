import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var icons = AppIconService()
    @State private var iconIssue: String?
    @State private var addingSource = false
    @State private var share: SharedFile?
    @State private var resetSettings = false
    @State private var clearCache = false
    var body: some View {
        Form {
            Section("下载") {
                Stepper("同时下载：\(store.settings.maxConcurrentDownloads)", value: $store.settings.maxConcurrentDownloads, in: 1...6)
                Stepper("等待任务上限：\(store.settings.maxQueuedDownloads)", value: $store.settings.maxQueuedDownloads, in: 1...100)
                Toggle("下载完成通知", isOn: $store.settings.notifications)
                Toggle("新版本提醒", isOn: $store.settings.updateNotifications)
                    .onChange(of: store.settings.updateNotifications) { _, on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
            }
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
                                .environment(\.colorScheme, icons.theme == .light ? .light : icons.theme == .dark ? .dark : colorScheme)
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
            ForEach($store.settings.versionSources) { $source in
                Section {
                    NavigationLink { VersionSourceEditor(source: $source) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                Text(source.urlTemplate).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(source.enabled ? "已启用" : "已停用").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("移除") { let id = source.id; withAnimation { store.settings.versionSources.removeAll { $0.id == id } } }.tint(.red)
                    }
                } header: { if source.id == store.settings.versionSources.first?.id { Text("历史版本来源") } }
            }
            Section {
                Button("添加版本来源", systemImage: "plus") { addingSource = true }
            } footer: {
                Text("用于查询应用的历史版本。")
            }
            Section {
                Toggle("加快重复下载", isOn: $store.settings.useSignerCache)
                Button("清除缓存") { store.signer.clearCache(); store.infoMessage = "已清除缓存" }
            } header: { Text("性能") } footer: {
                Text("缓存仅在本次运行期间保留。")
            }
            Section {
                NavigationLink { InstallationSettingsView() } label: { Label("安装设置", systemImage: "arrow.down.app") }
                    .accessibilityIdentifier("settings.installation")
            }
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
            Section("维护") {
                NavigationLink { StorageView() } label: { Label("存储空间", systemImage: "internaldrive") }
                    .accessibilityIdentifier("settings.storage")
                Button("清除历史版本缓存") { clearCache = true }
                Button("导出诊断信息") {
                    do { share = SharedFile(url: try store.exportDiagnostics()) } catch { store.errorMessage = error.localizedDescription }
                }
                Button("恢复默认设置", role: .destructive) { resetSettings = true }
            }
            Section {
                BrandMark(size: 64)
                Text("iPadn " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).font(.headline)
                Text("搜索、下载和管理你拥有许可的应用安装包，支持 iPhone、iPad、Apple TV 与 Mac。")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("项目与更新", destination: URL(string: "https://github.com/mengangs/ipadn")!)
            }
        }
        .toolPage().navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in if phase == .active { icons.refresh() } }
        .alert("图标未更改", isPresented: Binding(get: { iconIssue != nil }, set: { if !$0 { iconIssue = nil } })) {
            Button("知道了", role: .cancel) { iconIssue = nil }
        } message: { Text(iconIssue ?? "") }
        .sheet(isPresented: $addingSource) { AddVersionSourceView() }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .actionConfirmation(isPresented: $resetSettings, title: "恢复默认设置？", message: "账号、已下载的安装包和已购记录不受影响。", confirmTitle: "恢复默认设置") { store.settings = ToolSettings() }
        .actionConfirmation(isPresented: $clearCache, title: "清除历史版本缓存？", confirmTitle: "清除缓存") {
            Task { do { try await store.versions.clearCache(); store.infoMessage = "已清除缓存" } catch { store.errorMessage = error.localizedDescription } }
        }
    }
}

struct VersionSourceEditor: View {
    @Binding var source: VersionSource
    var body: some View {
        Form {
            Section("来源设置") {
                Toggle("启用", isOn: $source.enabled)
                TextField("来源名称", text: $source.name)
                TextField("接口地址，用 {id} 代表 App ID", text: $source.urlTemplate)
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
    @State private var source = VersionSource(name: "新来源", urlTemplate: "https://", containerKey: "data", reverse: false)
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VersionSourceEditor(source: $source)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  source.urlTemplate.contains("{id}"),
                                  let url = URL(string: source.urlTemplate.replacingOccurrences(of: "{id}", with: "123")),
                                  url.scheme == "https", url.host != nil else { error = "请填写名称，以及包含 {id} 的 https 接口地址"; return }
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
