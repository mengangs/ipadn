import SwiftUI
import UIKit

@MainActor
enum AppContainer {
    static let shared: ToolStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--visual-preview") {
            let apps = PreviewData.apps
            var jobs = [DownloadJob(app: apps[0], status: .running, downloaded: 131_000_000, expected: apps[0].size),
                        DownloadJob(app: apps[1], status: .paused, downloaded: 96_000_000, expected: apps[1].size),
                        DownloadJob(app: apps[2], status: .completed),
                        DownloadJob(app: apps[3], status: .failed, error: AppText.text("网络连接暂时不可用，请检查网络后重试。"))]
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--stress-records=") }),
               let count = Int(argument.dropFirst("--stress-records=".count)), [100, 500, 1000].contains(count) {
                jobs = (0..<count).map { index in
                    DownloadJob(app: StoreApp(id: "stress-\(index)", name: "测试安装包 \(index)", bundleID: "example.stress.\(index)", version: "1.0"), status: .paused)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--updates") {
                jobs = PreviewData.updatable.map { DownloadJob(app: $0, status: .completed) }
            }
            let store = ToolStore(downloadManager: DownloadManager(previewJobs: jobs))
            store.prepareVisualPreview()
            store.settings.appearance = ProcessInfo.processInfo.arguments.contains("--dark") ? "dark" : "light"
            if ProcessInfo.processInfo.arguments.contains("--downloads") { store.tab = 1 }
            if ProcessInfo.processInfo.arguments.contains("--accounts") { store.prepareAccountPreview(); store.tab = 3 }
            if ProcessInfo.processInfo.arguments.contains("--purchased") { store.prepareAccountPreview(); store.tab = 2 }
            if ProcessInfo.processInfo.arguments.contains("--archive") { store.prepareArchivePreview() }
            if ProcessInfo.processInfo.arguments.contains("--notice-preview") { store.infoMessage = "已复制到剪贴板" }
            return store
        }
        #endif
        return ToolStore()
    }()
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !LocalResources.isPreview { UpdateCheckScheduler.register() }
        #if DEBUG
        // Device tests: open an iPadn link at launch, e.g. --open-url=ipadn://download?url=…
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--open-url=") }),
           let url = URL(string: String(argument.dropFirst("--open-url=".count))) {
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); AppContainer.shared.handleURL(url) }
        }
        #endif
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            guard identifier == DownloadManager.sessionID else { completionHandler(); return }
            AppContainer.shared.downloads.backgroundCompletion = completionHandler
        }
    }
}

@main
@MainActor
struct iPadnApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppContainer.shared
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder private var appContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--visual-preview") {
            PreviewScreen()
        } else { RootView() }
        #else
        RootView()
        #endif
    }
    private var lockSettings: String {
        "\(store.settings.appLock)-\(store.settings.appLockDelay)-\(store.settings.appearance)"
    }
    private func configureLock(launching: Bool) {
        guard !LocalResources.isPreview else { return }
        AppLock.shared.configure(enabled: store.settings.appLock, delay: store.settings.appLockDelay,
                                 appearance: store.settings.appearance, launching: launching)
    }
    var body: some Scene {
        WindowGroup {
            appContent
                .environmentObject(store)
                .environmentObject(store.apple)
                .environmentObject(store.downloads)
                .environmentObject(store.signer)
                .tint(UX.tint)
                .toggleStyle(TintedSwitchToggleStyle())
                .onOpenURL { store.handleURL($0) }
                .onAppear { configureLock(launching: true) }
                .task { if !LocalResources.isPreview { await AppLock.shared.unlock() } }
                .compatibleOnChange(of: lockSettings) { _ in configureLock(launching: false) }
                .onReceive(store.downloads.$pendingAutoInstalls) { _ in AutoInstall.presentNext(store) }
                .onReceive(AppLock.shared.$locked) { locked in if !locked { AutoInstall.presentNext(store) } }
                .task {
                    guard !LocalResources.isPreview, store.settings.appUpdateCheck else { return }
                    await store.checkAppUpdate()
                }
        }
        .onChange(of: scenePhase) { phase in
            if !LocalResources.isPreview { AppLock.shared.sceneChanged(to: phase) }
            if phase == .active { AutoInstall.presentNext(store) }
            guard phase == .background, !LocalResources.isPreview else { return }
            // Session cookies kept in memory must survive the app being closed.
            store.apple.saveLiveCookies()
            // Only worth waking up for when there is something to check.
            if (store.settings.updateNotifications && store.downloads.jobs.contains(where: { $0.status == .completed && $0.updateKey != nil }))
                || (store.settings.watchNotifications && !store.favorites.isEmpty) || store.settings.appUpdateCheck {
                UpdateCheckScheduler.schedule()
            } else {
                UpdateCheckScheduler.cancel()
            }
        }
    }
}

#if DEBUG
/// Public App Store apps used as screenshot data, so previews show real
/// names and icons without any account's own records.
enum PreviewData {
    static func icon(_ path: String) -> URL? {
        URL(string: "https://is1-ssl.mzstatic.com/image/thumb/" + path + "/512x512bb.jpg")
    }
    static let apps = [
        StoreApp(id: "preview-1", name: "Netflix", bundleID: "com.netflix.Netflix", version: "26.5.0",
                 iconURL: icon("Purple221/v4/32/c6/6a/32c66aca-fb60-4d0e-46fb-8e861d280d6a/AppIcon-0-0-1x_U007epad-0-1-0-sRGB-0-85-220.png"),
                 category: "娱乐", size: 209_844_224),
        StoreApp(id: "preview-2", name: "Spotify", bundleID: "com.spotify.client", version: "9.1.98",
                 iconURL: icon("Purple211/v4/d5/ca/fa/d5cafa8a-079b-f708-4704-6cc55a8fb160/AppIcon-0-0-1x_U007epad-0-1-0-0-85-220.png"),
                 category: "音乐", size: 329_352_192),
        StoreApp(id: "1232780281", name: "Notion", bundleID: "notion.id", version: "1.7.353",
                 iconURL: icon("Purple211/v4/4a/fa/7a/4afa7a74-b27e-17db-4293-50450fc8423c/AppIconProd-0-0-1x_U007epad-0-0-0-1-0-0-85-220.png"),
                 category: "效率", size: 537_577_472),
        StoreApp(id: "1446075923", name: "Disney+", bundleID: "com.disney.disneyplus", version: "5.21.0",
                 iconURL: icon("Purple221/v4/d7/b3/67/d7b36785-baf0-d87b-7868-ea2170bc4ea6/AppIcon-0-0-1x_U007emarketing-0-8-0-0-0-85-220.png"),
                 category: "娱乐", size: 325_474_304),
    ]
    /// Finished downloads with real store IDs, for previews of update rows.
    static var updatable: [StoreApp] {
        zip(apps.prefix(3), ["363590051", "324684580", "1232780281"]).map { app, id in var app = app; app.id = id; return app }
    }
    /// The followed app; UI tests find it by this identifier.
    static var favorite: StoreApp { var app = apps[0]; app.id = "preview-app"; return app }
    static var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
}

private struct PreviewScreen: View {
    @EnvironmentObject private var store: ToolStore
    private let args = ProcessInfo.processInfo.arguments
    var body: some View {
        Group {
            if args.contains("--login") { NavigationStack { LoginView() } }
            else if args.contains("--detail"), let app = store.favorites.first { NavigationStack { AppDetailView(app: app) } }
            else if args.contains("--installation") { NavigationStack { InstallationSettingsView() } }
            else if args.contains("--support") { NavigationStack { SupportView() } }
            else if args.contains("--lock") { AppLockScreen(lock: AppLock.shared).onAppear { AppLock.shared.showPreview() }
                .preferredColorScheme(store.settings.appearance == "dark" ? .dark : .light) }
            else if args.contains("--installed") { NavigationStack { InstalledAppsView() } }
            else { RootView() }
        }
        .environment(\.dynamicTypeSize, args.contains("--largest-text") ? .accessibility5 : args.contains("--large-text") ? .accessibility2 : .large)
    }
}
#endif
