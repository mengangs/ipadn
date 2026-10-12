import SwiftUI
import UIKit

@MainActor
enum AppContainer { static let shared = ToolStore() }

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
struct IPAToolApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppContainer.shared
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.apple)
                .environmentObject(store.downloads)
                .environmentObject(store.signer)
                .tint(UX.tint)
                .onOpenURL { store.handleURL($0) }
        }
    }
}
