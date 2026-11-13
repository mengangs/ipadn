import SwiftUI

/// Apps installed on this device, read through the native installation
/// connection: which have a newer store version, which the App Store doesn't
/// recognise (installed from a link, shown with a cloud) and where the rest
/// came from.
@MainActor
struct InstalledAppsView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var apps: [NativeInstaller.InstalledApp] = []
    @StateObject private var catalog = InstalledAppCatalog()
    @State private var selected: Selection?

    /// Snapshot the selected destination, independent of later regrouping.
    private struct Selection: Hashable {
        let app: NativeInstaller.InstalledApp
        let listing: StoreApp?
        func hash(into hasher: inout Hasher) {
            hasher.combine(app.bundleID)
            hasher.combine(app.storeItemID)
            hasher.combine(listing)
        }
    }
    @State private var loading = false
    @State private var loaded = false
    @State private var issue: String?
    @State private var term = ""
    @State private var updating = false

    /// The system can list apps for iPadn from iOS 17.4, like native installation.
    nonisolated static var isSupported: Bool {
        NativeInstaller.listingIsAvailable
            && ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0))
    }

    enum Group: CaseIterable {
        case update, link, store, other
    }

    /// Previews show sample data without a pairing file.
    private var paired: Bool { NativeInstaller.hasPairingFile || LocalResources.isPreview }

    private func listing(_ app: NativeInstaller.InstalledApp) -> StoreApp? { catalog.listing(for: app) }

    func group(of app: NativeInstaller.InstalledApp) -> Group {
        if app.manifestInstall == true { return .link }
        // Blocked on purpose: the App Store offers nothing, so neither does this list.
        if !app.updatesBlocked, let latest = listing(app), let installed = app.version,
           Self.isUpdate(latest, installed: installed, versionID: app.storeVersionID) { return .update }
        return app.storeItemID != nil ? .store : .other
    }

    /// Whether the store has a newer version than the installed one. The same
    /// store version ID, or a store version that only adds a build number to
    /// the installed one ("10.0.10" against "10.0.10.105"), is the same release.
    nonisolated static func isUpdate(_ latest: StoreApp, installed: String, versionID: String?) -> Bool {
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
                requirement(title: "需要先完成原生安装配对",
                            message: "本机应用借助原生安装读取手机上已装的应用。在安装设置中完成一次配对后即可使用。",
                            retry: false)
            } else if let issue, apps.isEmpty {
                requirement(title: "需要连接 LocalDevVPN",
                            message: "本机应用通过 LocalDevVPN 读取手机上已装的应用。打开 LocalDevVPN 并点按连接，回到 iPadn 后会自动读取。",
                            retry: true, detail: issue)
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
        .compatibleNavigationDestination(item: $selected) { selection in
            if let listing = selection.listing { AppDetailView(app: listing) }
            else { InstalledAppInfoView(app: selection.app, catalog: catalog, retry: { await refreshListings() }) }
        }
        .compatibleOnChange(of: store.watchCountry) { _ in
            Task { await refreshListings() }
        }
        // Back from LocalDevVPN: try again without asking.
        .compatibleOnChange(of: scenePhase) { phase in
            if phase == .active, issue != nil, apps.isEmpty { Task { await load() } }
        }
        .overlay { if updating { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
    }

    /// What this page needs, shown like a feature that waits for its setup
    /// rather than an error.
    @ViewBuilder private func requirement(title: LocalizedStringKey, message: LocalizedStringKey, retry: Bool, detail: String? = nil) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .regular)).foregroundStyle(.secondary)
                    .padding(.bottom, 2).accessibilityHidden(true)
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if retry {
                    Button { Task { await load() } } label: {
                        if loading { ProgressView() } else { Text("重新读取") }
                    }
                    .buttonStyle(CapsuleButtonStyle()).disabled(loading).padding(.top, 4)
                    .accessibilityIdentifier("installed.retry")
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            NavigationLink { InstallationSettingsView() } label: { Label("前往安装设置", systemImage: "arrow.down.app") }
        } footer: {
            if let detail { Text(detail) }
        }
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
        case .link: return "App Store 未识别的应用"
        case .store: return "来自 App Store"
        case .other: return "其他来源"
        }
    }

    @ViewBuilder private func row(_ app: NativeInstaller.InstalledApp, kind: Group) -> some View {
        let latest = listing(app)
        let installed = app.version ?? ""
        let subtitle = kind == .update
            ? AppText.text("已装 \(installed)，商店最新 \(latest?.version ?? "")")
            : app.updatesBlocked ? AppText.text("已装 \(installed) · 已阻止更新")
            : (installed.isEmpty ? (app.bundleID ?? "") : AppText.text("已装 \(installed)"))
        let shown = StoreApp(id: app.storeItemID ?? app.bundleID ?? "", name: latest?.name ?? app.name ?? app.bundleID ?? "",
                             bundleID: app.bundleID ?? "", version: installed, iconURL: latest?.iconURL)
        Button { selected = Selection(app: app, listing: latest) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    AppRow(app: shown, subtitle: subtitle)
                    if latest == nil, InstalledAppCatalog.storeID(app) != nil {
                        Text(catalog.missingTitle).font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 78)
                    }
                }
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RevealRowButtonStyle())
        .accessibilityIdentifier("installed.app." + app.identity)
    }

    /// Store retries do not need another connection to the installation service.
    private func refreshListings() async {
        #if DEBUG
        if LocalResources.isPreview {
            catalog.preview(Self.previewListings, country: store.watchCountry)
            return
        }
        #endif
        await catalog.load(ids: apps.compactMap(InstalledAppCatalog.storeID), country: store.watchCountry)
    }

    private func load() async {
        guard paired, !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        #if DEBUG
        if LocalResources.isPreview {
            apps = Self.previewApps
            var listings = Self.previewListings
            if ProcessInfo.processInfo.arguments.contains("--installed-missing-preview") {
                listings.removeValue(forKey: PreviewData.updatable[2].id)
            }
            let failed = ProcessInfo.processInfo.arguments.contains("--installed-failed-preview")
            catalog.preview(failed ? [:] : listings, country: store.watchCountry, failed: failed)
            issue = nil
            return
        }
        #endif
        do {
            let found = try await NativeInstaller.installedApps().filter { $0.placeholder != true }
            apps = found
            issue = nil
            await refreshListings()
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

/// Device discovery and storefront availability are independent. A successful
/// empty lookup is not a network failure, and neither confirms delisting.
@MainActor
final class InstalledAppCatalog: ObservableObject {
    enum State: Equatable { case idle, loading, ready, failed(String) }
    typealias Fetch = ([String], String) async throws -> [String: StoreApp]
    @Published private(set) var listings: [String: StoreApp] = [:]
    @Published private(set) var state: State = .idle
    @Published private(set) var country = ""
    private var generation = UUID()
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { ids, country in
        try await StoreService.lookup(ids: ids, country: country).apps
    }) { self.fetch = fetch }

    nonisolated static func storeID(_ app: NativeInstaller.InstalledApp) -> String? {
        guard let id = app.storeItemID, let number = UInt64(id), number > 0 else { return nil }
        return String(number)
    }
    func listing(for app: NativeInstaller.InstalledApp) -> StoreApp? {
        Self.storeID(app).flatMap { listings[$0] }
    }
    var missingTitle: LocalizedStringKey {
        switch state {
        case .idle: return "尚未查询商店资料"
        case .loading: return "正在查询商店资料…"
        case .ready: return "当前地区未查到商店资料"
        case .failed: return "商店查询失败"
        }
    }
    var isLoading: Bool { state == .loading }

    func load(ids: [String], country: String) async {
        let token = UUID()
        generation = token
        self.country = country.uppercased()
        // A failed refresh must not retain another region's update eligibility.
        listings = [:]
        state = .loading
        let ids = Array(Set(ids.compactMap { UInt64($0) }.filter { $0 > 0 }.map(String.init))).sorted()
        guard !ids.isEmpty else { state = .ready; return }
        do {
            try Task.checkCancellation()
            let result = try await fetch(ids, self.country)
            try Task.checkCancellation()
            guard generation == token else { return }
            let requested = Set(ids)
            listings = result.filter { requested.contains($0.key) }
            state = .ready
        } catch is CancellationError {
            guard generation == token else { return }
            state = .idle
        } catch {
            guard generation == token else { return }
            state = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    func preview(_ listings: [String: StoreApp], country: String, failed: Bool = false) {
        generation = UUID()
        self.country = country.uppercased()
        self.listings = listings
        state = failed ? .failed(AppText.text("网络连接暂时不可用，请检查网络后重试。")) : .ready
    }
    #endif
}

/// The installed identity stays readable without a matching store listing.
@MainActor
private struct InstalledAppInfoView: View {
    let app: NativeInstaller.InstalledApp
    @ObservedObject var catalog: InstalledAppCatalog
    let retry: () async -> Void

    var body: some View {
        Form {
            Section("本机信息") {
                field("名称", app.name)
                field("Bundle ID", app.bundleID)
                field("版本", app.version)
                field("构建号", app.build)
                field("App ID", app.storeItemID)
                field("商店版本 ID", app.storeVersionID)
                field("签名标识", app.signer)
            }
            .accessibilityIdentifier("installed.local-info")
            Section {
                if InstalledAppCatalog.storeID(app) == nil {
                    Text("此应用没有商店 App ID，仅显示本机信息。")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("installed.lookup.no-id")
                } else {
                    LabeledContent("商店地区", value: StoreRegions.name(catalog.country))
                    if let listing = catalog.listing(for: app) {
                        NavigationLink { AppDetailView(app: listing) } label: { Text("查看商店详情") }
                            .accessibilityIdentifier("installed.store-details")
                    } else {
                        HStack(spacing: 10) {
                            if catalog.isLoading { ProgressView() }
                            Text(catalog.missingTitle).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("installed.lookup.status")
                        if case .failed(let message) = catalog.state {
                            Text(verbatim: message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button("重新查询") { Task { await retry() } }
                        .disabled(catalog.isLoading)
                        .accessibilityIdentifier("installed.lookup.retry")
                }
            } header: { Text("商店资料") } footer: {
                if InstalledAppCatalog.storeID(app) != nil, catalog.listing(for: app) == nil, catalog.state == .ready {
                    Text("未查到资料不代表应用已下架，也不影响查看本机信息。")
                }
            }
        }
        .toolPage().navigationTitle(app.name ?? app.bundleID ?? AppText.text("本机信息"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func field(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                Text(verbatim: value).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

extension NativeInstaller.InstalledApp {
    /// Stable row identity: the bundle ID, unique on a device.
    var identity: String { bundleID ?? storeItemID ?? UUID().uuidString }
}
