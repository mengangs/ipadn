import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var icons = AppIconService()
    @State private var addingSource = false
    @State private var share: SharedFile?
    @State private var resetSettings = false
    @State private var clearCache = false
    var body: some View {
        Form {
            Section("下载") {
                Stepper("同时下载：\(store.settings.maxConcurrentDownloads)", value: $store.settings.maxConcurrentDownloads, in: 1...6)
                Stepper("等待任务上限：\(store.settings.maxQueuedDownloads)", value: $store.settings.maxQueuedDownloads, in: 1...100)
                Toggle("下载结果通知", isOn: $store.settings.notifications)
                LabeledContent("切到后台继续下载", value: "支持")
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
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(choice.preview).resizable().scaledToFit().frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
                            Text(choice.title).foregroundStyle(.primary)
                            Spacer()
                            if icons.changing && choice != icons.selected { ProgressView() }
                            else if icons.selected == choice { Image(systemName: "checkmark").foregroundStyle(.primary) }
                        }.frame(minHeight: 54).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(icons.changing || !icons.supported)
                        .accessibilityIdentifier("settings.icon." + choice.rawValue)
                        .accessibilityAddTraits(icons.selected == choice ? .isSelected : [])
                }
            } header: { Text("应用图标") } footer: {
                Text(icons.supported ? "默认使用立体图标，也可切换为原先的扁平风格。系统会提示图标已更改。" : "当前设备或安装方式不支持切换图标。")
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
                } header: { if source.id == store.settings.versionSources.first?.id { Text("可扩展版本来源") } }
            }
            Section {
                Button("添加版本来源", systemImage: "plus") { addingSource = true }
            } footer: {
                Text("兼容 external_identifier / bundle_version 字段。并发查询启用的来源，使用首个有效结果；版本缓存有效期 24 小时。")
            }
            Section {
                Toggle("加速重复验证和下载准备", isOn: $store.settings.useSignerCache)
                Button("清除签名内存缓存") { store.signer.clearCache(); store.infoMessage = "已清除签名缓存。" }
            } header: { Text("签名引擎") } footer: {
                Text("验证过程在本机运行，缓存仅保留在内存中；退出应用后自动清除。")
            }
            Section {
                TextField("自定义 HTTPS plist 服务", text: $store.settings.plistServer)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                LabeledContent("安装文件服务", value: "127.0.0.1:8000")
            } header: { Text("安装兼容配置") } footer: {
                Text("使用你配置的 HTTPS 清单服务和 Surge/Loon 规则。文件服务仅监听本机；也可直接导出安装包到签名工具。")
            }
            Section("维护") {
                Button("清除版本查询缓存") { clearCache = true }
                Button("导出诊断摘要") {
                    do { share = SharedFile(url: try store.exportDiagnostics()) } catch { store.errorMessage = error.localizedDescription }
                }
                Button("恢复默认设置", role: .destructive) { resetSettings = true }
            }
            Section {
                BrandMark(size: 64)
                Text("iPadn " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")).font(.headline)
                Text("搜索、下载、管理你的应用安装包。支持 iPhone、iPad 和快捷指令。")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("项目与更新", destination: URL(string: "https://github.com/mengangs/ipadn")!)
            }
        }
        .toolPage().navigationTitle("设置与扩展").navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in if phase == .active { icons.refresh() } }
        .sheet(isPresented: $addingSource) { AddVersionSourceView() }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .actionConfirmation(isPresented: $resetSettings, title: "恢复默认设置？", message: "保留账号、下载文件、已购记录和历史版本缓存。", confirmTitle: "恢复默认设置") { store.settings = ToolSettings() }
        .actionConfirmation(isPresented: $clearCache, title: "清除版本查询缓存？", confirmTitle: "清除缓存") {
            Task { do { try await store.versions.clearCache(); store.infoMessage = "已清除版本查询缓存" } catch { store.errorMessage = error.localizedDescription } }
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
                TextField("HTTPS 地址，使用 {id} 占位符", text: $source.urlTemplate)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("列表容器键，顶层数组留空", text: $source.containerKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("反转接口结果顺序", isOn: $source.reverse)
            }
            Section("支持的 JSON 格式") {
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
                                  url.scheme == "https", url.host != nil else { error = "请填写来源名称和带 {id} 的 HTTPS 接口地址"; return }
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
