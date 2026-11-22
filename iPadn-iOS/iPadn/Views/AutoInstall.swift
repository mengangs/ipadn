import SwiftUI
import UIKit

/// Opens the install sheet for downloads that just finished (Settings ›
/// Downloads › Install When Downloaded), one at a time, above whatever page
/// or sheet is showing, once iPadn is in front and unlocked.
@MainActor
enum AutoInstall {
    private static weak var showing: UIViewController?

    /// From a publisher, which fires before the published value is set.
    static func presentSoon(_ store: ToolStore) {
        DispatchQueue.main.async { presentNext(store) }
    }

    static func presentNext(_ store: ToolStore) {
        guard !LocalResources.isPreview, showing == nil, store.installingJob == nil,
              UIApplication.shared.applicationState == .active, !AppLock.shared.locked,
              store.externalDownloadPrompt == nil, store.errorMessage == nil else { return }

        let nextView: AnyView
        if let id = store.downloads.pendingAutoInstalls.first {
            guard let job = store.downloads.jobs.first(where: { $0.id == id && $0.status == .completed }) else {
                store.downloads.pendingAutoInstalls.removeAll { $0 == id }
                presentNext(store)
                return
            }
            nextView = AnyView(
                PackageInstallationView(job: job, startsAutomatically: true)
                    .sheetNotice()
                    .environmentObject(store)
                    .environmentObject(store.apple)
                    .environmentObject(store.downloads)
                    .environmentObject(store.signer)
                    .tint(UX.tint)
                    .toggleStyle(TintedSwitchToggleStyle())
                    .preferredColorScheme(store.settings.appearance == "system" ? nil : store.settings.appearance == "dark" ? .dark : .light)
            )
            store.downloads.pendingAutoInstalls.removeAll { $0 == id }
        } else if let target = store.downloads.pendingExternalAutoInstalls.first {
            guard FileManager.default.fileExists(atPath: target.fileURL.path) else {
                store.downloads.pendingExternalAutoInstalls.removeAll { $0.id == target.id }
                presentNext(store)
                return
            }
            nextView = AnyView(
                PackageInstallationView(
                    job: target.job,
                    startsAutomatically: true,
                    packageFileURL: target.fileURL,
                    packageIconURL: target.iconURL,
                    isTestFlight: target.isTestFlight,
                    onInstalled: target.onInstalled
                )
                    .sheetNotice()
                    .environmentObject(store)
                    .environmentObject(store.apple)
                    .environmentObject(store.downloads)
                    .environmentObject(store.signer)
                    .tint(UX.tint)
                    .toggleStyle(TintedSwitchToggleStyle())
                    .preferredColorScheme(store.settings.appearance == "system" ? nil : store.settings.appearance == "dark" ? .dark : .light)
            )
            store.downloads.pendingExternalAutoInstalls.removeAll { $0.id == target.id }
        } else {
            return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow && $0.windowLevel == .normal })
                ?? scene.windows.first(where: { $0.windowLevel == .normal && !$0.isHidden && $0.rootViewController != nil }),
              var top = window.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        if top.isBeingDismissed || top.presentedViewController != nil || top is UIAlertController || String(describing: type(of: top)).contains("PackageInstallation") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                presentNext(store)
            }
            return
        }
        let sheet = AutoInstallHost(rootView: nextView)
        sheet.closed = {
            showing = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                presentNext(store)
            }
        }
        showing = sheet
        top.present(sheet, animated: true)
    }
}

private final class AutoInstallHost: UIHostingController<AnyView> {
    var closed: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Gone for good, not just covered by something it presented.
        if presentingViewController == nil || isBeingDismissed {
            closed?(); closed = nil
        }
    }
}

/// Shown above the download list while downloads wait for Wi-Fi.
struct WiFiWaitRow: View {
    @EnvironmentObject private var manager: DownloadManager
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text("等待 Wi‑Fi").font(.subheadline.weight(.semibold))
                Text("当前只有蜂窝数据，下载会在连上 Wi‑Fi 后继续。").font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("仍使用蜂窝数据下载") { manager.downloadOverCellular() }.buttonStyle(CapsuleButtonStyle())
                    .accessibilityIdentifier("downloads.cellular")
            }
        }
        .padding(.vertical, 6)
    }
}
