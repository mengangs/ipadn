import SwiftUI
import UIKit

@MainActor
enum AppContainer {
    static let shared: ToolStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--visual-preview") {
            let a = StoreApp(id: "preview-1", name: "像素日记", bundleID: "example.pixel", version: "3.2.1", category: "摄影与录像", size: 128_000_000)
            let b = StoreApp(id: "preview-2", name: "专注时刻", bundleID: "example.focus", version: "2.8", category: "效率", size: 48_000_000)
            let jobs = [DownloadJob(app: a, status: .running, downloaded: 74_000_000, expected: 128_000_000), DownloadJob(app: b, status: .paused, downloaded: 12_000_000, expected: 48_000_000), DownloadJob(app: a, status: .completed), DownloadJob(app: b, status: .failed, error: "网络连接已中断，请检查网络后重试。")]
            let store = ToolStore(downloadManager: DownloadManager(previewJobs: jobs))
            store.prepareVisualPreview()
            store.settings.appearance = ProcessInfo.processInfo.arguments.contains("--dark") ? "dark" : "light"
            if ProcessInfo.processInfo.arguments.contains("--downloads") { store.tab = 1 }
            if ProcessInfo.processInfo.arguments.contains("--accounts") { store.prepareAccountPreview(); store.tab = 3 }
            if ProcessInfo.processInfo.arguments.contains("--purchased") { store.prepareAccountPreview(); store.tab = 2 }
            if ProcessInfo.processInfo.arguments.contains("--archive") { store.prepareArchivePreview() }
            return store
        }
        #endif
        return ToolStore()
    }()
}

final class AppDelegate: NSObject, UIApplicationDelegate {
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
    @ViewBuilder private var appContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--visual-preview") {
            PreviewScreen()
        } else { RootView() }
        #else
        RootView()
        #endif
    }
    var body: some Scene {
        WindowGroup {
            appContent
                .environmentObject(store)
                .environmentObject(store.apple)
                .environmentObject(store.downloads)
                .environmentObject(store.signer)
                .tint(UX.tint)
                .onOpenURL { store.handleURL($0) }
        }
    }
}

#if DEBUG
private struct PreviewScreen: View {
    @EnvironmentObject private var store: ToolStore
    private let args = ProcessInfo.processInfo.arguments
    var body: some View {
        Group {
            if args.contains("--login") { NavigationStack { LoginView() } }
            else if args.contains("--detail"), let app = store.favorites.first { NavigationStack { AppDetailView(app: app) } }
            else { RootView() }
        }
        .environment(\.dynamicTypeSize, args.contains("--large-text") ? .accessibility2 : .large)
    }
}
#endif
