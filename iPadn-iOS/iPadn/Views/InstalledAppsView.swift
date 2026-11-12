import SwiftUI

/// Apps installed on this device, read through the native installation
/// connection: which have a newer store version, which the App Store doesn't
/// recognise (installed from a link, shown with a cloud) and where the rest
/// came from.
struct InstalledAppsView: View {
    @EnvironmentObject private var store: ToolStore
    @State private var apps: [NativeInstaller.InstalledApp] = []
    @State private var listings: [String: StoreApp] = [:]
    @State private var loading = false
    @State private var loaded = false
    @State private var issue: String?
    @State private var term = ""
    @State private var updating = false

    /// The system can list apps for iPadn from iOS 17.4, like native installation.
    static var isSupported: Bool {
        NativeInstaller.listingIsAvailable
            && ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0))
    }

    enum Group: CaseIterable {
        case update, link, store, other
    }

    /// Previews show sample data without a pairing file.
    private var paired: Bool { NativeInstaller.hasPairingFile || LocalResources.isPreview }

    private func listing(_ app: NativeInstaller.InstalledApp) -> StoreApp? { app.storeItemID.flatMap { listings[$0] } }

    func group(of app: NativeInstaller.InstalledApp) -> Group {
        if app.manifestInstall == true { return .link }
        if let latest = listing(app), let installed = app.version, Self.isUpdate(latest, installed: installed, versionID: app.storeVersionID) { return .update }
        return app.storeItemID != nil ? .store : .other
    }

    /// Whether the store has a newer version than the installed one. The same
    /// store version ID, or a store version that only adds a build number to
    /// the installed one ("10.0.10" against "10.0.10.105"), is the same release.
    static func isUpdate(_ latest: StoreApp, installed: String, versionID: String?) -> Bool {
        if let versionID, let current = latest.externalVersionID, versionID == current { return false }
        if latest.version.hasPrefix(installed + ".") { return false }
        return VersionOrder.isNewer(latest.version, than: installed)
    }

    private var visible: [NativeInstaller.InstalledApp] {
        let query = term.trimmingCharacters(in: .whitespaces)
        return apps.filter { app in
            query.isEmpty || (app.name ?? "").localizedCaseInsensitiveContains(query)
                || (app.bundleID ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let shown = visible
        let grouped = Dictionary(grouping: shown, by: group(of:))
        List {
            if !paired {
                Section {
                    Text("读取本机应用需要原生安装：先完成配对，并在 LocalDevVPN 中连接。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    NavigationLink { InstallationSettingsView() } label: { Label("前往安装设置", systemImage: "arrow.down.app") }
                }
            } else if let issue, apps.isEmpty {
                Section {
                    InlineIssue(message: issue) { Task { await load() } }
                    NavigationLink { InstallationSettingsView() } label: { Label("前往安装设置", systemImage: "arrow.down.app") }
                }
            } else if loading && apps.isEmpty {
                Section {
                    HStack(spacing: 10) { ProgressView(); Text("正在读取本机应用…").foregroundStyle(.secondary) }
                }
            } else {
                if !apps.isEmpty {
                    Section {
                        SearchInput(text: $term, placeholder: "搜索已装应用", capsule: true)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                }
                section(.update, grouped[.update] ?? [])
                section(.link, grouped[.link] ?? [])
                section(.store, grouped[.store] ?? [])
                section(.other, grouped[.other] ?? [])
                if loaded && shown.isEmpty {
                    Section { Text(apps.isEmpty ? "没有可显示的应用" : "没有匹配的应用").foregroundStyle(.secondary) }
                }
                if loaded {
                    Section {} footer: {
                        Text("已装应用列表只在本机读取。检查更新时会向 Apple 查询这些应用的商店版本。")
                    }
                }
            }
        }
        .toolPage().navigationTitle("本机应用").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .overlay { if updating { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
    }

    @ViewBuilder private func section(_ kind: Group, _ rows: [NativeInstaller.InstalledApp]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending },
                        id: \.identity) { app in row(app, kind: kind) }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(kind)) + Text(verbatim: " · \(rows.count)")
                    Spacer()
                    if kind == .update && rows.count > 1 {
                        Button("全部更新") { updateAll(rows) }
                            .font(.body.weight(.semibold)).textCase(nil).buttonStyle(.borderless)
                            .disabled(updating)
                            .accessibilityIdentifier("installed.update-all")
                    }
                }
            } footer: {
                switch kind {
                case .link: Text("这些应用是通过网页安装的，App Store 显示云朵、无法更新。用原生安装重新安装一次即可恢复，数据会保留。")
                case .other: Text("用其他签名工具安装的应用，App Store 无法更新。")
                default: EmptyView()
                }
            }
        }
    }

    private func title(_ kind: Group) -> LocalizedStringKey {
        switch kind {
        case .update: return "可更新"
        case .link: return "App Store 不认的应用"
        case .store: return "来自 App Store"
        case .other: return "其他来源"
        }
    }

    @ViewBuilder private func row(_ app: NativeInstaller.InstalledApp, kind: Group) -> some View {
        let latest = listing(app)
        let installed = app.version ?? ""
        let subtitle = kind == .update
            ? AppText.text("已装 \(installed)，商店最新 \(latest?.version ?? "")")
            : (installed.isEmpty ? (app.bundleID ?? "") : AppText.text("已装 \(installed)"))
        let shown = StoreApp(id: app.storeItemID ?? app.bundleID ?? "", name: latest?.name ?? app.name ?? app.bundleID ?? "",
                             bundleID: app.bundleID ?? "", version: installed, iconURL: latest?.iconURL)
        if let latest {
            NavigationLink { AppDetailView(app: latest) } label: { AppRow(app: shown, subtitle: subtitle) }
        } else {
            AppRow(app: shown, subtitle: subtitle)
        }
    }

    private func load() async {
        guard paired, !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        #if DEBUG
        if LocalResources.isPreview { apps = Self.previewApps; listings = Self.previewListings; issue = nil; return }
        #endif
        do {
            let found = try await NativeInstaller.installedApps().filter { $0.placeholder != true }
            apps = found
            issue = nil
            let ids = found.compactMap(\.storeItemID)
            if !ids.isEmpty, let result = try? await StoreService.lookup(ids: ids, country: store.watchCountry) {
                listings = result.apps
            }
        } catch is CancellationError {
        } catch { issue = error.localizedDescription }
    }

    private func updateAll(_ rows: [NativeInstaller.InstalledApp]) {
        let targets = rows.compactMap(listing)
        guard !targets.isEmpty else { return }
        updating = true
        UX.feedback()
        Task {
            defer { updating = false }
            let result = await store.startDownloads(targets) { _ in }
            if result.added > 0 { store.infoMessage = AppText.text("已添加 \(result.added) 个下载任务") }
            if !result.failures.isEmpty { store.errorMessage = result.failures.joined(separator: "\n") }
        }
    }

    #if DEBUG
    /// Screenshot data: one app per group.
    static var previewApps: [NativeInstaller.InstalledApp] {
        let apps = PreviewData.updatable
        func make(_ app: StoreApp, version: String, link: Bool = false) -> NativeInstaller.InstalledApp {
            var installed = NativeInstaller.InstalledApp(installed: true)
            installed.bundleID = app.bundleID; installed.name = app.name; installed.version = version
            installed.storeItemID = app.id; installed.hasPurchaseRecord = !link; installed.manifestInstall = link
            return installed
        }
        var other = NativeInstaller.InstalledApp(installed: true)
        other.bundleID = "com.example.tool"; other.name = "LocalDevVPN"; other.version = "1.2"
        return [make(apps[0], version: "26.4.0"), make(apps[1], version: "9.1.98", link: true), make(apps[2], version: "1.7.353"), other]
    }
    static var previewListings: [String: StoreApp] {
        Dictionary(uniqueKeysWithValues: PreviewData.updatable.map { app in
            var latest = app
            if app.id == PreviewData.updatable[0].id { latest.version = "26.5.0" }
            return (app.id, latest)
        })
    }
    #endif
}

extension NativeInstaller.InstalledApp {
    /// Stable row identity: the bundle ID, unique on a device.
    var identity: String { bundleID ?? storeItemID ?? UUID().uuidString }
}
