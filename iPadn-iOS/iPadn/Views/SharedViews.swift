import SwiftUI
import WebKit
import UIKit
#if DEBUG
import os
#endif

struct AppIcon: View {
    var url: URL?
    var size: CGFloat = 56
    /// The image last loaded, with the address it came from.
    @State private var loaded: (url: URL, image: UIImage)?
    private var source: URL? { url.map { $0.isFileURL ? $0 : StoreService.sharpArtwork($0) } }
    var body: some View {
        let source = source
        // An icon already in memory shows in the very first frame.
        let image = loaded.flatMap { $0.url == source ? $0.image : nil } ?? source.flatMap { IconCache.cached($0, size: size) }
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit().transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * UX.iconCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * UX.iconCorner, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: source) {
            guard let source else { return }
            // Kept here too, in case memory pressure later empties the cache.
            if let cached = IconCache.cached(source, size: size) {
                if loaded?.url != source { loaded = (source, cached) }
                return
            }
            guard let image = await IconCache.load(source, size: size), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { loaded = (source, image) }
        }
    }
    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "app.fill").font(.system(size: size * 0.4)).foregroundStyle(.quaternary)
        }
    }
}

/// Decoded app icons shared by every `AppIcon`, so a row scrolled back into
/// view, or the same app on the next page, shows its icon at once instead of
/// a placeholder while it loads again.
enum IconCache {
    private actor Requests {
        var pending: [String: Task<UIImage?, Never>] = [:]
        func load(_ url: URL, side: CGFloat) async -> UIImage? {
            let key = "\(Int(side))|\(url.absoluteString)"
            if let task = pending[key] { return await task.value }
            let task = Task.detached(priority: .utility) { () -> UIImage? in
                let data: Data?
                if url.isFileURL { data = try? Data(contentsOf: url) }
                else { data = try? await URLSession.shared.data(from: url).0 }
                guard let data, let image = UIImage(data: data) else { return nil }
                return await image.byPreparingThumbnail(ofSize: CGSize(width: side, height: side)) ?? image
            }
            pending[key] = task
            let image = await task.value
            if let image { cache.setObject(image, forKey: key as NSString, cost: cost(of: image)) }
            pending.removeValue(forKey: key)
            return image
        }
    }
    private static let requests = Requests()
    /// Bounded by memory, not count: hundreds of list icons fit.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 80 * 1024 * 1024; return cache
    }()
    /// List rows and the large detail icon keep separate, right-sized copies.
    private static func pixels(for size: CGFloat) -> CGFloat { size <= 64 ? 192 : 384 }
    private static func key(_ url: URL, _ size: CGFloat) -> NSString { "\(Int(pixels(for: size)))|\(url.absoluteString)" as NSString }
    static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
    static func cached(_ url: URL, size: CGFloat) -> UIImage? { cache.object(forKey: key(url, size)) }
    static func load(_ url: URL, size: CGFloat) async -> UIImage? {
        if let image = cached(url, size: size) { return image }
        return await requests.load(url, side: pixels(for: size))
    }
}

/// App Store list row: icon, name, subtitle and an optional trailing action.
struct AppRow<Accessory: View>: View {
    let app: StoreApp
    var subtitle: String? = nil
    /// A short state shown next to the size, e.g. 已下载.
    var badge: (text: LocalizedStringKey, tint: Color)? = nil
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        HStack(spacing: 14) {
            AppIcon(url: app.iconURL, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? app.bundleID : app.name).font(.body.weight(.medium)).lineLimit(2)
                // The category gets its own line so a long name in another
                // language doesn't push the version out of view.
                let detail = subtitle ?? app.displayCategory
                if !detail.isEmpty {
                    // Scrolls once in place when the row is too narrow, like download cards.
                    MarqueeText(text: detail).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if app.isDelisted { TagBadge(text: "已下架", tint: .orange) }
                    if let badge { TagBadge(text: badge.text, tint: badge.tint) }
                    let facts = [subtitle == nil && !app.version.isEmpty ? "v\(app.version)" : "", app.size > 0 ? app.size.byteLabel : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    if !facts.isEmpty { Text(facts).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 4)
    }
}
extension AppRow where Accessory == EmptyView {
    init(app: StoreApp, subtitle: String? = nil, badge: (text: LocalizedStringKey, tint: Color)? = nil) {
        self.init(app: app, subtitle: subtitle, badge: badge) { EmptyView() }
    }
}

/// Binds an App Store morphing pill/ring button to live preparation and `DownloadManager` job state.
struct StoreDownloadActionButton: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var downloads: DownloadManager
    let app: StoreApp
    var platformOverride: AppPlatform? = nil
    var versionID: String? = nil
    var marketingVersion: String? = nil
    var idleTitle: String = "获取"
    var filled = false
    var enabled = true
    var cloudWhenIdle = false
    var insideNavigationLink = false
    var alignment: Alignment = .center
    var idleAccessibilityLabel: String? = nil
    var onEnqueued: (() -> Void)? = nil
    var onRequireVerification: (() -> Void)? = nil
    var onRequireReauthentication: ((String?) -> Void)? = nil

    private var platform: AppPlatform { platformOverride ?? store.settings.store.platform }

    var body: some View {
        let preparing = store.isPreparingDownload(appID: app.id, platform: platform, versionID: versionID)
        let job = preparing ? nil : store.matchingDownloadJob(for: app, platform: platform, versionID: versionID)
        StoreActionPhaseHost(
            preparing: preparing,
            job: job,
            progressState: job.map { downloads.progress(for: $0.id) } ?? StoreActionIdleState.progress,
            autoInstalling: job.flatMap { downloads.autoInstalling?.id == $0.id ? downloads.autoInstalling : nil },
            idlePhase: cloudWhenIdle ? .cloud(enabled: enabled) : .capsule(title: idleTitle, filled: filled, enabled: enabled),
            idleAccessibilityLabel: idleAccessibilityLabel,
            filled: filled,
            insideNavigationLink: insideNavigationLink,
            alignment: alignment,
            action: triggerAction
        )
    }

    private func triggerAction() {
        store.triggerAppStoreAction(
            for: app,
            platform: platform,
            versionID: versionID,
            marketingVersion: marketingVersion,
            onEnqueued: onEnqueued,
            onRequireVerification: onRequireVerification,
            onRequireReauthentication: onRequireReauthentication
        )
    }
}

@MainActor
private enum StoreActionIdleState {
    static let progress = DownloadProgressState()
}

private struct StoreActionPhaseHost: View {
    let preparing: Bool
    let job: DownloadJob?
    @ObservedObject var progressState: DownloadProgressState
    let autoInstalling: DownloadManager.AutoInstallProgress?
    let idlePhase: AppStoreActionPhase
    let idleAccessibilityLabel: String?
    let filled: Bool
    let insideNavigationLink: Bool
    let alignment: Alignment
    let action: () -> Void

    private var phase: AppStoreActionPhase {
        if preparing { return .loading }
        guard let job else { return idlePhase }
        let liveJob = progressState.applying(to: job)
        if let autoInstalling {
            return autoInstalling.hasProgress ? .downloading(autoInstalling.fraction) : .processing
        }
        switch liveJob.status {
        case .queued:
            return .loading
        case .running:
            return liveJob.expected > 0 ? .downloading(liveJob.progress) : .loading
        case .pausing, .processing:
            return .processing
        case .paused:
            return .capsule(title: "继续", filled: false, enabled: true)
        case .failed:
            return .capsule(title: "重试", filled: false, enabled: true)
        case .completed:
            if job.rawFormat == nil {
                return .capsule(title: "安装", filled: filled, enabled: true)
            }
            return .capsule(title: "已完成", filled: false, enabled: true)
        }
    }

    private var accessibilityLabelText: String? {
        if preparing { return AppText.text("取消准备下载") }
        guard let job else { return idleAccessibilityLabel }
        if let autoInstalling {
            return AppText.text("正在安装") + " " + autoInstalling.name
        }
        switch progressState.applying(to: job).status {
        case .queued: return AppText.text("等待下载，点按暂停")
        case .running: return AppText.text("暂停")
        case .pausing, .processing: return AppText.text("正在处理")
        case .paused: return AppText.text("继续")
        case .failed: return AppText.text("重试")
        case .completed: return job.rawFormat == nil ? AppText.text("安装") : AppText.text("已完成")
        }
    }

    private var accessibilityValueText: String? {
        if case .downloading(let fraction) = phase {
            return "\(Int((fraction * 100).rounded()))%"
        }
        return nil
    }

    var body: some View {
        AppStoreActionButton(
            phase: phase,
            alignment: alignment,
            insideNavigationLink: insideNavigationLink,
            accessibilityLabelText: accessibilityLabelText,
            accessibilityValueText: accessibilityValueText,
            action: action
        )
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct SharedFile: Identifiable { let id = UUID(); let url: URL }

struct SignerWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

struct RootView: View {
    @ObservedObject private var packages = FairPlayPresentation.shared
    @State private var completedPackageIDs: Set<UUID> = []
    @State private var seededCompletedPackages = false
    @State private var handledPackageProbe = false
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var tabs: TabState
    @EnvironmentObject private var signer: SAPSigner
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var vectorTabBarUnavailable = false
    private struct Destination {
        let id: TabID
        let title: LocalizedStringKey
        let symbol: String
        let kind: RevealAnimationKind
    }

    private let searchDestination = Destination(id: .search, title: "搜索", symbol: "magnifyingglass", kind: .tabSearch)
    private let downloadsDestination = Destination(id: .downloads, title: "下载", symbol: "arrow.down.circle.fill", kind: .tabDownloads)
    private let packagesDestination = Destination(id: .packages, title: "应用包", symbol: "shippingbox.fill", kind: .tabPackages)
    private let purchasedDestination = Destination(id: .purchased, title: "已购", symbol: "bag.fill", kind: .tabPurchased)
    private let accountsDestination = Destination(id: .accounts, title: "账号", symbol: "person.crop.circle.fill", kind: .tabAccount)

    /// 应用包 sits between 下载 and 已购, and only exists while 专业模式 is on.
    private var destinations: [Destination] {
        var list: [Destination] = [searchDestination, downloadsDestination]
        if store.settings.proMode {
            list.append(packagesDestination)
        }
        list.append(contentsOf: [purchasedDestination, accountsDestination])
        return list
    }

    private var tabOrder: [TabID] { destinations.map(\.id) }

    private var downloadsBadge: Int {
        downloads.jobs.filter { DownloadFilter.active.includes($0.status) }.count
    }

    private var tabSelectionBinding: Binding<TabID> {
        Binding(
            get: { tabs.id },
            set: { store.selectTab($0) }
        )
    }

    private var sidebarSelectionBinding: Binding<TabID?> {
        Binding<TabID?>(
            get: { tabs.id },
            set: { value in
                guard let value else { return }
                store.selectTab(value)
            }
        )
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(selection: sidebarSelectionBinding) {
                        Section {
                            ForEach(destinations, id: \.id) { item in
                                Label(item.title, systemImage: item.symbol)
                                    .badge(item.id == .downloads ? downloadsBadge : (item.id == .accounts && store.appUpdate != nil ? 1 : 0))
                                    .tag(item.id)
                            }
                        }

                    }.navigationTitle("iPadn").navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                } detail: {
                    // Keep every section alive, like the iPhone tab bar does, so
                    // switching sections keeps navigation, filters and scroll position.
                    ZStack {
                        ForEach(destinations, id: \.id) { item in
                            pageStack(item.id)
                                .frame(maxWidth: 900).frame(maxWidth: .infinity)
                                .background(Color(.systemGroupedBackground))
                                .opacity(tabs.id == item.id ? 1 : 0)
                                .allowsHitTesting(tabs.id == item.id)
                                .accessibilityHidden(tabs.id != item.id)
                        }
                    }
                }
            } else {
                TabView(selection: tabSelectionBinding) {
                    pageStack(.search)
                        .tabItem { tabLabel(searchDestination) }
                        .tag(TabID.search)
                    pageStack(.downloads)
                        .tabItem { tabLabel(downloadsDestination) }
                        .badge(downloadsBadge)
                        .tag(TabID.downloads)
                    if store.settings.proMode {
                        pageStack(.packages)
                            .tabItem { tabLabel(packagesDestination) }
                            .tag(TabID.packages)
                    }
                    pageStack(.purchased)
                        .tabItem { tabLabel(purchasedDestination) }
                        .tag(TabID.purchased)
                    pageStack(.accounts)
                        .tabItem { tabLabel(accountsDestination) }
                        .badge(store.appUpdate != nil ? 1 : 0)
                        .tag(TabID.accounts)
                }
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .background {
                    TabReselectScroll(
                        selected: tabs.selection,
                        selectedID: tabs.id,
                        reduceMotion: reduceMotion,
                        kinds: destinations.map(\.kind),
                        enableVectorIcons: !vectorTabBarUnavailable,
                        onVectorFallback: { vectorTabBarUnavailable = true }
                    )
                }
            }
        }
        .preferredColorScheme(store.settings.appearance == "system" ? nil : store.settings.appearance == "dark" ? .dark : .light)
        .compatibleSelectionFeedback(trigger: tabs.id)
        .onAppear {
            tabs.reconcile(with: tabOrder)
            packages.adoptLegacyOutputIdentities()
            if downloads.isLoaded {
                completedPackageIDs = Set(downloads.jobs.filter { $0.status == .completed }.map(\.id))
                seededCompletedPackages = true
            }
        }
        .compatibleOnChange(of: downloads.isLoaded) { loaded in
            guard loaded, !seededCompletedPackages else { return }
            completedPackageIDs = Set(downloads.jobs.filter { $0.status == .completed }.map(\.id))
            seededCompletedPackages = true
        }
        .task {
            #if DEBUG
            guard !handledPackageProbe, CommandLine.arguments.contains("--fp-ux") else { return }
            handledPackageProbe = true
            // The stack and its destination registration now exist. No timer
            // and no synthetic task/record are used by this test-only route.
            if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--ux-record=") }),
               let id = UUID(uuidString: String(value.dropFirst("--ux-record=".count))) {
                packages.navigate(.record(id))
            } else if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--ux-source=") }) {
                let name = String(value.dropFirst("--ux-source=".count))
                if !name.contains("/"), !name.contains("\\") {
                    packages.navigate(.file(FairPlayEnvironment.documentsDirectory.appendingPathComponent(name)))
                }
            }
            #endif
        }
        .compatibleOnChange(of: packages.navigationRevision) { _ in
            guard store.settings.proMode else { packages.clearPath(); return }
            tabs.select(.packages, in: tabOrder)
        }
        .onReceive(packages.service.$phase.removeDuplicates()) { phase in
            guard phase != .running && phase != .idle else { return }
            // Published emits before the service completes its synchronous
            // record update. The next actor turn observes the committed state.
            Task { @MainActor in packages.captureOutputIdentity() }
        }
        .compatibleOnChange(of: downloads.jobs.filter { $0.status == .completed }.map(\.id)) { ids in
            let current = Set(ids)
            guard downloads.isLoaded else { return }
            if !seededCompletedPackages {
                completedPackageIDs = current
                seededCompletedPackages = true
                return
            }
            let added = current.subtracting(completedPackageIDs)
            completedPackageIDs = current
            guard store.settings.proMode, packages.service.autoDecryptOnComplete else { return }
            for job in downloads.jobs where added.contains(job.id) && job.rawFormat == nil && (job.asset != nil || job.sourceURL != nil) {
                if let url = downloads.fileURL(job), packages.attempts(url: url, jobID: job.id).isEmpty {
                    packages.requestStart(url: url, job: job, automatic: true)
                }
            }
        }
        .actionConfirmation(
            isPresented: Binding(get: { packages.replacement != nil }, set: { if !$0 { packages.replacement = nil } }),
            title: "替换已有解密产物？",
            message: "重新解密可能替换以下文件。请先保存需要保留的产物；原始 IPA 不受影响。",
            detail: packages.replacement?.collisions.map(\.lastPathComponent).joined(separator: "\n"),
            confirmTitle: "替换并重新解密"
        ) {
            if let request = packages.replacement { packages.confirmReplacement(request) }
        }
        .alert("已有任务正在运行", isPresented: $packages.busy) {
            Button("查看当前任务") { if let id = packages.service.activeRecordID { packages.navigate(.record(id)) } }
            Button("稍后再试", role: .cancel) {}
        } message: { Text("同一时间只能处理一份 IPA。当前操作没有加入队列。") }
        .compatibleOnChange(of: packages.message) { message in
            if let message { store.infoMessage = message; packages.message = nil }
        }
        .compatibleOnChange(of: store.settings.proMode) { _ in
            // 专业模式 toggled: keep the current page identity without animating
            // UITabBarController child insertion, and fall back to 下载 when 应用包 disappears.
            tabs.reconcile(with: tabOrder)
            if !store.settings.proMode {
                packages.replacement = nil
                packages.clearPath()
                store.accountNav.removeRoutes { $0 == .credentials }
            }
        }
        .alert("确认通过外部链接下载？", isPresented: Binding(
            get: { store.externalDownloadPrompt != nil },
            set: { if !$0 { store.externalDownloadPrompt = nil } }
        )) {
            Button("加入下载") {
                if let prompt = store.externalDownloadPrompt {
                    store.confirmExternalDownload(prompt)
                }
            }
            Button("取消", role: .cancel) {
                store.externalDownloadPrompt = nil
            }
        } message: {
            if let prompt = store.externalDownloadPrompt {
                Text("来源：\(prompt.url.host ?? "")\n\(prompt.displayURL)\n\n外部直链下载完成后不会自动安装，可在「下载」页手动检查或安装。")
            }
        }
        .sheet(item: $store.verificationRequest) { request in
            ExistingAccountVerificationView(accountID: request.accountID) {
                // Runs after the sheet has closed, so a retry can present again.
                let retry = request.retry
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); retry?() }
            }
        }
        .sheet(item: $store.installingJob) { job in
            PackageInstallationView(job: job).sheetNotice()
                .environmentObject(store)
                .environmentObject(downloads)
        }
        .sheet(item: $store.loginPrompt) { prompt in
            NavigationStack {
                LoginView(initialAccountID: prompt.accountID) {
                    let retry = prompt.retry
                    store.loginPrompt = nil
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); retry?() }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { store.loginPrompt = nil }
                    }
                }
            }
        }
        .background {
            if let web = signer.webView {
                SignerWebView(web: web).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        // Global success notices belong above the page, never on top of
        // AppDetailView's fixed download CTA or the tab bar.
        // Isolating the overlay view keeps notice spring animations from
        // re-evaluating RootView's entire TabView / split hierarchy.
        .overlay(alignment: .top) {
            RootNoticeOverlay(notices: store.notices, onUndo: { store.undoLastAction() })
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.clearError() } })) {
            if let action = store.errorAction {
                Button(action.title) {
                    let perform = action.perform
                    store.clearError()
                    perform()
                }
            }
            Button("知道了", role: .cancel) { store.clearError() }
        } message: { Text(store.errorMessage ?? "") }
        .dismissRevealsWhenTabChanges(tabs.id)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
        }
    }
    @ViewBuilder private func pageStack(_ id: TabID) -> some View {
        switch id {
        case .packages:
            NavigationStack(path: $packages.path) {
                PackagesView().navigationDestination(for: PackageRoute.self) { route in
                    Group {
                        switch route {
                        case .source(let id): PackageSourceDetailView(jobID: id)
                        case .record(let id): DecryptDetailView(recordID: id)
                        case .file(let url): PackageSourceDetailView(file: url)
                        case .unlinked(let url): UnlinkedPackageView(url: url)
                        case .history: DecryptHistoryView()
                        case .options: DecryptOptionsView()
                        case .help: DecryptHelpView()
                        case .log(let id): DecryptLogView(recordID: id)
                        }
                    }
                    .onAppear { packages.notePresented(route) }
                }
            }
        case .accounts:
            AccountsTabStack(nav: store.accountNav)
        default:
            NavigationStack { page(id) }
        }
    }
    @ViewBuilder private func tabLabel(_ item: Destination) -> some View {
        if !vectorTabBarUnavailable, RevealAnimationLibrary.syncLoad(item.kind) != nil {
            Label { Text(item.title) } icon: { Image(uiImage: TabVectorIconView.placeholderImage) }
        } else {
            Label(item.title, systemImage: item.symbol)
        }
    }
    @ViewBuilder private func page(_ id: TabID) -> some View {
        switch id {
        case .search: SearchView()
        case .downloads: DownloadsView()
        case .packages: PackagesView()
        case .purchased: PurchasedView()
        case .accounts: AccountsView()
        }
    }
}

private struct AccountsTabStack: View {
    @ObservedObject var nav: AccountNavigation
    var body: some View {
        NavigationStack(path: $nav.path) {
            AccountsView()
                .accountNavigationDestinations()
        }
    }
}

private struct AccountNavigationDestinationsModifier: ViewModifier {
    @EnvironmentObject private var store: ToolStore
    func body(content: Content) -> some View {
        content.navigationDestination(for: AccountRoute.self) { route in
            Group {
                switch route {
                case .login:
                    LoginView()
                case .reauthenticate(let id):
                    LoginView(initialAccountID: id)
                case .installedApps:
                    InstalledAppsView()
                case .wifiTransfer:
                    WiFiTransferView()
                case .testFlight:
                    TestFlightRouteDestination()
                case .settings(let page):
                    SettingsView(page: page)
                case .installation:
                    InstallationSettingsView()
                case .credentials:
                    ProModeCredentialsDestination()
                case .storage:
                    StorageView()
                case .versionSource(let id):
                    VersionSourceRouteDestination(sourceID: id)
                case .appUpdate:
                    AppUpdateRouteDestination()
                case .support:
                    SupportView()
                }
            }
            .onAppear { store.accountNav.notePresented(route) }
        }
    }
}

/// TestFlight entry point.
///
/// The page lives in the `TestFlightKit` package target, which only links in the
/// device (xtool) build; every other build gets an explicit "unavailable" page
/// instead of a compile error, so Xcode and CI stay green.
private struct TestFlightRouteDestination: View {
    var body: some View {
        #if canImport(TestFlightKit)
        TestFlightHomeView()
        #else
        List {
            Section {
                EmptyState(
                    title: "TestFlight 不可用",
                    message: "当前构建未包含 TestFlight 模块。",
                    symbol: "airplane"
                )
            }
        }
        .toolPage()
        .navigationTitle("TestFlight")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct ProModeCredentialsDestination: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        CredentialsView()
            .onAppear { if !store.settings.proMode { dismiss() } }
            .compatibleOnChange(of: store.settings.proMode) { enabled in
                if !enabled { dismiss() }
            }
    }
}

private struct VersionSourceRouteDestination: View {
    let sourceID: UUID
    @EnvironmentObject private var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    @State private var fallback = VersionSource(name: "", urlTemplate: "", containerKey: "", reverse: false)

    private var sourceBinding: Binding<VersionSource> {
        Binding(
            get: {
                store.settings.versionSources.first(where: { $0.id == sourceID }) ?? fallback
            },
            set: { updated in
                fallback = updated
                guard let index = store.settings.versionSources.firstIndex(where: { $0.id == sourceID }) else { return }
                store.settings.versionSources[index] = updated
            }
        )
    }

    var body: some View {
        VersionSourceEditor(source: sourceBinding)
            .onAppear {
                if let current = store.settings.versionSources.first(where: { $0.id == sourceID }) {
                    fallback = current
                } else {
                    dismiss()
                }
            }
            .compatibleOnChange(of: store.settings.versionSources.map(\.id)) { ids in
                if !ids.contains(sourceID) { dismiss() }
            }
    }
}

private struct AppUpdateRouteDestination: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    @State private var cachedRelease: AppRelease?

    var body: some View {
        Group {
            if let release = store.appUpdate ?? cachedRelease {
                AppUpdateView(release: release)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if let current = store.appUpdate {
                cachedRelease = current
            } else if cachedRelease == nil {
                dismiss()
            }
        }
        .compatibleOnChange(of: store.appUpdate == nil) { isNil in
            if !isNil, let current = store.appUpdate {
                cachedRelease = current
            } else if isNil {
                dismiss()
            }
        }
    }
}

extension View {
    func accountNavigationDestinations() -> some View {
        modifier(AccountNavigationDestinationsModifier())
    }
}

private struct RootNoticeOverlay: View {
    @ObservedObject var notices: NoticeCenter
    let onUndo: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let message = notices.undoNotice?.message ?? notices.infoMessage
        let isUndo = notices.undoNotice != nil
        ZStack(alignment: .top) {
            if let message {
                Group {
                    if let notice = notices.undoNotice {
                        HStack(spacing: 8) {
                            UndoCountdown(start: notice.created, duration: UndoNotice.duration)
                            Text(message).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .compatibleNumericTransition()
                            Button("撤销") {
                                UX.tapLight()
                                withAnimation(UX.motion(reduceMotion)) { onUndo() }
                            }
                            .font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                            .compatibleInteractionShape(Rectangle())
                            .accessibilityIdentifier("notice.undo")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90), value: notice.revision)
                    } else {
                        // Match 1.8.0: the whole compact notice dismisses on tap.
                        Button { notices.infoMessage = nil } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(message).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .contentTransition(.opacity)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 11).frame(minHeight: 44)
                        }
                        .compatibleInteractionShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityLabel(message).accessibilityHint("点按关闭提示")
                        .accessibilityIdentifier("notice.banner")
                    }
                }
                // Solid elevated capsule avoids animated `.regularMaterial` SDFLayer backdrop
                // recomputation (120fps on all devices and avoids iOS 26/27 AsyncRenderer lock contention).
                .background(Color(.secondarySystemGroupedBackground).opacity(0.97),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .buttonStyle(.plain)
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)
                // The top of the root tab container includes the navigation bar.
                // On compact-height devices show the banner nearer the top.
                .padding(.top, sizeClass == .regular ? 16 : verticalSizeClass == .compact ? 8 : 52)
                .id(isUndo ? "undo" : "info")
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90), value: notices.infoMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90), value: notices.undoNotice?.id)
        .task(id: notices.undoNotice.map { "\($0.id.uuidString)-\($0.revision)" }) {
            guard let notice = notices.undoNotice else { return }
            if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning {
                UIAccessibility.post(notification: .announcement, argument: AppText.text("\(notice.message)，可以撤销"))
            }
            let remaining = notice.created.addingTimeInterval(UndoNotice.duration).timeIntervalSinceNow
            if remaining > 0 {
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            if notices.undoNotice?.id == notice.id && notices.undoNotice?.revision == notice.revision {
                notices.undoNotice = nil
            }
        }
        .task(id: notices.infoMessage) {
            guard let message = notices.infoMessage else { return }
            if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
            #if DEBUG
            // Deterministic geometry checks without changing real notice timing.
            if LocalResources.isPreview && ProcessInfo.processInfo.arguments.contains("--notice-preview") { return }
            #endif
            // Longer notices (setup steps, other languages) stay up longer.
            let seconds = min(8, max(3.5, Double(message.count) / 14))
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            if notices.infoMessage == message { notices.infoMessage = nil }
        }
    }
}

/// Telegram's undo countdown: a ring that runs down with the seconds left
/// inside it, so it's clear how long Undo stays offered.
struct UndoCountdown: View {
    let start: Date
    let duration: TimeInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation) { context in
            let left = max(0, duration - context.date.timeIntervalSince(start))
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
                Circle().trim(from: 0, to: min(1, left / duration))
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: start)
                Text("\(Int(left.rounded(.up)))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .compatibleCountdownTransition()
                    .animation(.easeOut(duration: 0.2), value: Int(left.rounded(.up)))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

@MainActor
private final class TabVectorIconView: UIView {
    static let placeholderImage: UIImage = {
        let size = CGSize(width: 26, height: 26)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in }.withRenderingMode(.alwaysTemplate)
    }()

    let kind: RevealAnimationKind
    private let stage = CALayer()
    private var shapes: [CAShapeLayer] = []
    private var prepared: PreparedRevealAnimation?

    init(kind: RevealAnimationKind) {
        self.kind = kind
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = false
        layer.addSublayer(stage)
        if let loaded = RevealAnimationLibrary.syncLoad(kind) {
            prepared = loaded
            shapes = loaded.makeShapeLayers(color: resolvedColor(), into: stage)
            loaded.applyFrame(last: true, to: shapes)
        }
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: TabVectorIconView, _) in
                self.syncColors()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func resolvedColor() -> CGColor {
        tintColor.resolvedColor(with: traitCollection).cgColor
    }

    func syncColors() {
        prepared?.applyColors(resolvedColor(), to: shapes)
    }

    override func didMoveToSuperview() { super.didMoveToSuperview(); syncColors() }
    override func didMoveToWindow() { super.didMoveToWindow(); syncColors(); layoutStage() }
    override func tintColorDidChange() { super.tintColorDidChange(); syncColors() }
    override func layoutSubviews() { super.layoutSubviews(); layoutStage() }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #available(iOS 17.0, *) { return }
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            syncColors()
        }
    }

    private func layoutStage() {
        guard let asset = prepared?.asset, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / asset.canvas[0], bounds.height / asset.canvas[1])
        let width = asset.canvas[0] * scale
        let height = asset.canvas[1] * scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.anchorPoint = .zero
        stage.position = CGPoint(x: (bounds.width - width) * 0.5, y: (bounds.height - height) * 0.5)
        stage.bounds = CGRect(x: 0, y: 0, width: asset.canvas[0], height: asset.canvas[1])
        stage.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func play(beginTime: CFTimeInterval) {
        prepared?.play(on: shapes, in: window, beginTime: beginTime, key: "tab.vector")
    }
}

/// Tapping the tab you are already on scrolls its list back to the top, as in
/// Telegram. It also renders multi-part vector animations inside native UITabBar
/// / Liquid Glass tab slots at full display refresh rate.
struct TabReselectScroll: UIViewRepresentable {
    enum VectorAttachmentResult: Equatable {
        case attached
        case deferred
        case unsupportedHierarchy
    }

    let selected: Int
    let selectedID: TabID
    let reduceMotion: Bool
    let kinds: [RevealAnimationKind]
    let enableVectorIcons: Bool
    let onVectorFallback: () -> Void
    final class Anchor: UIView {
        var moved: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); moved?() }
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var anchor: Anchor?
        private weak var watched: UITabBar?
        private var tap: UITapGestureRecognizer?
        private var selectedAtTouch: Int?
        private var lastSelectedID: TabID?
        private var installTask: Task<Void, Never>?
        private var followUpTask: Task<Void, Never>?
        private var fallbackNotified = false
        var reduceMotion = false
        var kinds: [RevealAnimationKind] = []
        var enableVectorIcons = true
        var onVectorFallback: (() -> Void)?

        func install() {
            installTask?.cancel()
            installTask = nil
            if attachCurrent() == .attached {
                if enableVectorIcons { scheduleFollowUpAttach() }
                return
            }
            installTask = Task { @MainActor [weak self] in
                for delayMs in [16, 40, 100, 220, 450] {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard !Task.isCancelled, let self else { return }
                    let result = self.attachCurrent()
                    if result == .attached {
                        if self.enableVectorIcons { self.scheduleFollowUpAttach() }
                        return
                    }
                    if delayMs == 450, result == .unsupportedHierarchy {
                        self.notifyVectorFallbackIfNeeded(in: self.watched)
                    }
                }
            }
        }

        private func scheduleFollowUpAttach() {
            guard enableVectorIcons else { return }
            followUpTask?.cancel()
            followUpTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, self.enableVectorIcons, let bar = self.watched else { return }
                if TabReselectScroll.attachVectorIcons(in: bar, kinds: self.kinds) == .unsupportedHierarchy {
                    self.install()
                }
            }
        }

        @discardableResult
        private func attachCurrent() -> VectorAttachmentResult {
            guard let window = anchor?.window, let bar = Self.tabBar(in: window) else { return .deferred }
            if bar !== watched {
                detachTapOnly()
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                tap.cancelsTouchesInView = false
                tap.delegate = self
                bar.addGestureRecognizer(tap)
                self.tap = tap
                watched = bar
            }
            guard enableVectorIcons else {
                TabReselectScroll.removeVectorIcons(in: bar)
                return .attached
            }
            return TabReselectScroll.attachVectorIcons(in: bar, kinds: kinds)
        }

        func updateSelection(_ selected: Int, selectedID: TabID, reduceMotion: Bool, kinds: [RevealAnimationKind],
                             enableVectorIcons: Bool, onVectorFallback: @escaping () -> Void) {
            self.reduceMotion = reduceMotion
            self.kinds = kinds
            self.enableVectorIcons = enableVectorIcons
            self.onVectorFallback = onVectorFallback
            install()
            guard let previousID = lastSelectedID else {
                lastSelectedID = selectedID
                return
            }
            guard previousID != selectedID else { return }
            lastSelectedID = selectedID
            guard !reduceMotion, enableVectorIcons, let bar = watched else { return }
            DispatchQueue.main.async { [weak self, weak bar, kinds] in
                guard let self, let bar, self.enableVectorIcons else { return }
                let result = TabReselectScroll.attachVectorIcons(in: bar, kinds: kinds)
                if result == .attached {
                    Self.playTabIcon(at: selected, in: bar, kinds: kinds)
                } else if result == .unsupportedHierarchy {
                    self.install()
                }
            }
        }

        private func notifyVectorFallbackIfNeeded(in bar: UITabBar?) {
            if let bar { TabReselectScroll.removeVectorIcons(in: bar) }
            guard !fallbackNotified else { return }
            fallbackNotified = true
            enableVectorIcons = false
            #if DEBUG
            if CommandLine.arguments.contains("--reveal-metrics") {
                Logger(subsystem: "app.local.iPadn", category: "Reveal")
                    .notice("TabBar vector hierarchy unavailable; reverting to SF Symbols")
            }
            #endif
            onVectorFallback?()
        }

        private func detachTapOnly() {
            if let tap { watched?.removeGestureRecognizer(tap) }
            tap = nil; watched = nil; selectedAtTouch = nil
        }

        func detach() {
            installTask?.cancel()
            installTask = nil
            followUpTask?.cancel()
            followUpTask = nil
            detachTapOnly()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let bar = watched else { return false }
            // Capture BEFORE UIKit changes selection, not when the tap ends.
            // Comparing item indices also avoids assuming LTR button positions.
            let current = bar.items?.firstIndex { $0 === bar.selectedItem }
            selectedAtTouch = current
            var view = touch.view
            while let node = view, node !== bar {
                if node is UIControl { return true }
                view = node.superview
            }
            if let current, Self.tabIndex(at: touch.location(in: bar), in: bar) == current {
                return true
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let bar = gesture.view as? UITabBar, let before = selectedAtTouch else { return }
            selectedAtTouch = nil
            let reduce = reduceMotion
            let kinds = kinds
            DispatchQueue.main.async { [weak self, weak bar] in
                guard let self, let bar, bar.items?.firstIndex(where: { $0 === bar.selectedItem }) == before else { return }
                let scrolled = Self.scrollToTop(in: bar.window)
                #if DEBUG
                if CommandLine.arguments.contains("--reveal-metrics") {
                    Logger(subsystem: "app.local.iPadn", category: "Reveal")
                        .info("TabBar reselect index=\(before, privacy: .public) scrolled=\(scrolled, privacy: .public)")
                }
                #endif
                if !reduce, self.enableVectorIcons {
                    if TabReselectScroll.attachVectorIcons(in: bar, kinds: kinds) == .attached {
                        Self.playTabIcon(at: before, in: bar, kinds: kinds)
                    } else {
                        self.install()
                    }
                }
            }
        }

        private static func tabButtonGroups(in bar: UITabBar, count: Int) -> [[UIView]] {
            var byParent: [ObjectIdentifier: [UIView]] = [:]
            var stack: [UIView] = [bar]
            while let view = stack.popLast() {
                let name = String(describing: type(of: view))
                if name.contains("Badge") { continue }
                if (name.contains("TabButton") || name.contains("TabBarButton")), let parent = view.superview, !view.isHidden, view.alpha > 0.01 {
                    byParent[ObjectIdentifier(parent), default: []].append(view)
                    continue
                }
                stack.append(contentsOf: view.subviews)
            }
            let isRTL = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
            return byParent.values.compactMap { group in
                guard group.count == count else { return nil }
                let sorted = group.sorted {
                    $0.convert($0.bounds, to: bar).midX < $1.convert($1.bounds, to: bar).midX
                }
                return isRTL ? Array(sorted.reversed()) : sorted
            }
        }

        private static func firstTabImageView(in button: UIView) -> UIImageView? {
            var stack: [UIView] = [button]
            while let view = stack.popLast() {
                let name = String(describing: type(of: view))
                if name.contains("Badge") { continue }
                if let imageView = view as? UIImageView,
                   !imageView.isHidden, imageView.alpha > 0.01,
                   imageView.image != nil,
                   imageView.bounds.width >= 14, imageView.bounds.width <= 48,
                   imageView.bounds.height >= 14, imageView.bounds.height <= 48 {
                    return imageView
                }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }

        private static func fallbackImageColumns(in bar: UITabBar, count: Int) -> [[UIImageView]] {
            var candidates: [(midX: CGFloat, view: UIImageView)] = []
            var stack: [UIView] = [bar]
            while let view = stack.popLast() {
                let name = String(describing: type(of: view))
                if name.contains("Badge") { continue }
                if let imageView = view as? UIImageView,
                   !imageView.isHidden, imageView.alpha > 0.01,
                   imageView.image != nil,
                   imageView.bounds.width >= 14, imageView.bounds.width <= 48,
                   imageView.bounds.height >= 14, imageView.bounds.height <= 48 {
                    let midX = imageView.convert(CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY), to: bar).x
                    candidates.append((midX, imageView))
                }
                stack.append(contentsOf: view.subviews)
            }
            candidates.sort { $0.midX < $1.midX }
            var columns: [(anchorX: CGFloat, views: [UIImageView])] = []
            for item in candidates {
                if let idx = columns.firstIndex(where: { abs($0.anchorX - item.midX) <= 14 }) {
                    columns[idx].views.append(item.view)
                } else {
                    columns.append((item.midX, [item.view]))
                }
            }
            guard columns.count == count else { return [] }
            let ordered = columns.map(\.views)
            return bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? Array(ordered.reversed()) : ordered
        }

        fileprivate static func resolvedTabImageViews(in bar: UITabBar, count: Int) -> [[UIImageView]] {
            bar.layoutIfNeeded()
            let groups = tabButtonGroups(in: bar, count: count)
            if !groups.isEmpty {
                var byIndex = Array(repeating: [UIImageView](), count: count)
                for group in groups {
                    for (index, button) in group.enumerated() {
                        button.clipsToBounds = false
                        if let imageView = firstTabImageView(in: button) {
                            byIndex[index].append(imageView)
                        }
                    }
                }
                if byIndex.allSatisfy({ !$0.isEmpty }) {
                    return byIndex
                }
            }
            return fallbackImageColumns(in: bar, count: count)
        }

        private static func playTabIcon(at index: Int, in bar: UITabBar, kinds: [RevealAnimationKind]) {
            guard (0..<kinds.count).contains(index) else { return }
            let kind = kinds[index]
            let columns = resolvedTabImageViews(in: bar, count: kinds.count)
            guard columns.count == kinds.count else { return }
            let syncTime = CACurrentMediaTime()
            var played = 0
            for imageView in columns[index] {
                if let iconView = imageView.subviews.compactMap({ $0 as? TabVectorIconView }).first(where: { $0.kind == kind }) {
                    iconView.play(beginTime: syncTime)
                    played += 1
                }
            }
            #if DEBUG
            if CommandLine.arguments.contains("--reveal-metrics") {
                Logger(subsystem: "app.local.iPadn", category: "Reveal")
                    .info("TabBar vector index=\(index, privacy: .public) views=\(played, privacy: .public)")
            }
            #endif
        }

        private static func tabIndex(at point: CGPoint, in bar: UITabBar) -> Int? {
            guard bar.bounds.contains(point), let count = bar.items?.count, count > 0, bar.bounds.width > 0 else { return nil }
            let groups = tabButtonGroups(in: bar, count: count)
            if let primary = groups.first {
                return primary.enumerated().min(by: {
                    let a = $0.element.convert($0.element.bounds, to: bar).midX
                    let b = $1.element.convert($1.element.bounds, to: bar).midX
                    return abs(a - point.x) < abs(b - point.x)
                })?.offset
            }
            let raw = min(count - 1, max(0, Int((point.x / bar.bounds.width) * CGFloat(count))))
            return bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? (count - 1 - raw) : raw
        }

        private static func tabBar(in view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar { return bar }
            for sub in view.subviews { if let bar = tabBar(in: sub) { return bar } }
            return nil
        }
        private static func enclosingNavigationController(for view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view.next
            while let current = responder {
                if let vc = current as? UIViewController {
                    return (vc as? UINavigationController) ?? vc.navigationController
                }
                responder = current.next
            }
            return nil
        }
        /// The visible, scrollable list with the most area on screen.
        @discardableResult
        private static func scrollToTop(in window: UIWindow?) -> Bool {
            guard let window else { return false }
            var best: UIScrollView?
            var bestArea: CGFloat = 0
            var stack: [UIView] = [window]
            while let view = stack.popLast() {
                guard !view.isHidden, view.alpha > 0.01, view.layer.opacity > 0.01 else { continue }
                if let scroll = view as? UIScrollView,
                   scroll.contentSize.height > scroll.bounds.height + 2 {
                    let visible = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
                    let area = visible.width * visible.height
                    if area > bestArea { best = scroll; bestArea = area }
                }
                stack.append(contentsOf: view.subviews)
            }
            guard let scroll = best else { return false }
            if let nav = enclosingNavigationController(for: scroll),
               let root = nav.viewControllers.first,
               nav.viewControllers.count > 1,
               nav.topViewController !== root {
                return false
            }
            let topY = -scroll.adjustedContentInset.top
            guard scroll.contentOffset.y > topY + 2 else { return false }
            UX.tapSoft()
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: topY), animated: true)
            return true
        }
    }
    @MainActor
    @discardableResult
    static func attachVectorIcons(in bar: UITabBar, kinds: [RevealAnimationKind]) -> VectorAttachmentResult {
        guard !kinds.isEmpty, bar.window != nil, bar.bounds.width > 0,
              let items = bar.items, items.count == kinds.count else {
            return .deferred
        }
        let expectedSlots = kinds.filter { RevealAnimationLibrary.syncLoad($0) != nil }.count
        guard expectedSlots > 0 else {
            removeVectorIcons(in: bar)
            return .unsupportedHierarchy
        }
        let columns = Coordinator.resolvedTabImageViews(in: bar, count: kinds.count)
        guard columns.count == kinds.count else {
            removeVectorIcons(in: bar)
            return .unsupportedHierarchy
        }
        var attachedSlots = 0
        for (index, imageViews) in columns.enumerated() {
            let kind = kinds[index]
            guard RevealAnimationLibrary.syncLoad(kind) != nil else { continue }
            var slotReady = false
            for imageView in imageViews {
                imageView.clipsToBounds = false
                if let existing = imageView.subviews.compactMap({ $0 as? TabVectorIconView }).first {
                    if existing.kind == kind {
                        existing.frame = imageView.bounds
                        existing.syncColors()
                        slotReady = true
                        continue
                    }
                    existing.removeFromSuperview()
                }
                let iconView = TabVectorIconView(kind: kind)
                iconView.frame = imageView.bounds
                iconView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                imageView.addSubview(iconView)
                slotReady = true
            }
            if slotReady { attachedSlots += 1 }
        }
        guard attachedSlots == expectedSlots else {
            removeVectorIcons(in: bar)
            return .unsupportedHierarchy
        }
        return .attached
    }

    @MainActor
    static func removeVectorIcons(in root: UIView) {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let icon = view as? TabVectorIconView {
                icon.removeFromSuperview()
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        context.coordinator.anchor = view
        view.moved = { [weak coordinator = context.coordinator] in coordinator?.install() }
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        context.coordinator.updateSelection(selected, selectedID: selectedID, reduceMotion: reduceMotion, kinds: kinds,
                                            enableVectorIcons: enableVectorIcons, onVectorFallback: onVectorFallback)
    }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) {
        view.moved = nil
        coordinator.detach()
    }
}

/// The top notice inside a sheet, which covers RootView's own banner. The
/// root still times the notice out and announces it; this only shows it.
private struct SheetNotice: ViewModifier {
    @EnvironmentObject private var store: ToolStore
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            SheetNoticeOverlay(notices: store.notices)
        }
    }
}

private struct SheetNoticeOverlay: View {
    @ObservedObject var notices: NoticeCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .top) {
            if let message = notices.infoMessage {
                Button { notices.infoMessage = nil } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(message).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 11).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .background(Color(.secondarySystemGroupedBackground).opacity(0.97),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .frame(maxWidth: 320)
                .padding(.horizontal, 24).padding(.top, 8)
                .accessibilityLabel(message).accessibilityHint("点按关闭提示")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: notices.infoMessage)
    }
}

extension View {
    /// Shows the app's top notice while this view is presented as a sheet.
    func sheetNotice() -> some View { modifier(SheetNotice()) }
}
