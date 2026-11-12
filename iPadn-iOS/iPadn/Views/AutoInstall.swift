import SwiftUI
import UIKit

/// Opens the install sheet for downloads that just finished (Settings ›
/// Downloads › Install When Downloaded), one at a time, above whatever page
/// or sheet is showing, once iPadn is in front.
@MainActor
enum AutoInstall {
    private static weak var showing: UIViewController?

    static func presentNext(_ store: ToolStore) {
        guard !LocalResources.isPreview, showing == nil,
              UIApplication.shared.applicationState == .active,
              let id = store.downloads.pendingAutoInstalls.first else { return }
        guard let job = store.downloads.jobs.first(where: { $0.id == id && $0.status == .completed }) else {
            store.downloads.pendingAutoInstalls.removeAll { $0 == id }
            presentNext(store)
            return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.windowLevel == .normal && !$0.isHidden }),
              var top = window.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        guard !top.isBeingDismissed else { return }
        let sheet = AutoInstallHost(rootView: AnyView(
            PackageInstallationView(job: job, startsAutomatically: true)
                .environmentObject(store)
                .environmentObject(store.apple)
                .environmentObject(store.downloads)
                .environmentObject(store.signer)
                .tint(UX.tint)
                .toggleStyle(TintedSwitchToggleStyle())
                .preferredColorScheme(store.settings.appearance == "system" ? nil : store.settings.appearance == "dark" ? .dark : .light)))
        sheet.closed = {
            showing = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                presentNext(store)
            }
        }
        store.downloads.pendingAutoInstalls.removeAll { $0 == id }
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
