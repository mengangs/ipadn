import SwiftUI

struct PackageInstallationView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let job: DownloadJob
    @State private var busy = false
    /// The link is open and the system is loading the install details: the
    /// button keeps showing progress until its prompt actually appears.
    @State private var openingSystem = false
    @State private var message: String?
    @State private var issue: String?
    @State private var sharedFile: SharedFile?
    /// The system took the install link; show how far it has got.
    @State private var started = false
    @State private var attempted = false
    /// Which request the delayed connection check belongs to.
    @State private var attempt = 0
    private let proxied = LocalHostRecord.proxyOrVPNActive
    /// How far a native installation has got; nil when none is running.
    @State private var nativePhase: NativeInstaller.Phase?
    private var native: Bool { store.settings.usesNativeInstallation }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        AppIcon(url: job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL, size: 96)
                        VStack(spacing: 4) {
                            Text(job.app.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                            Text([job.app.version.isEmpty ? "" : AppText.text("版本 \(job.app.version)"), job.app.size > 0 ? job.app.size.byteLabel : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button {
                            requestInstallation()
                        } label: {
                            HStack(spacing: 8) {
                                if busy || openingSystem { ProgressView().tint(UX.onAccent) }
                                Text(nativePhase != nil ? "正在安装…" : busy ? "正在准备…" : openingSystem ? "正在打开安装…" : "安装")
                                    .contentTransition(.opacity)
                            }
                            .frame(maxWidth: .infinity)
                            .animation(.easeOut(duration: 0.15), value: busy || openingSystem)
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy || openingSystem)
                        .accessibilityIdentifier("installation.request")
                        if !native, attempted || InstallLog.insideLiveContainer {
                            Button { requestInstallation(viaBrowser: true) } label: {
                                Label("在 Safari 中安装", systemImage: "safari").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless).disabled(busy || openingSystem)
                            .accessibilityIdentifier("installation.browser")
                        }
                        Button {
                            if let file = manager.fileURL(job) { sharedFile = SharedFile(url: file) }
                            else { issue = AppText.text("找不到安装包文件，请重新下载。") }
                        } label: { Label("导出安装包", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                if let nativePhase {
                    Section { NativeProgressRow(phase: nativePhase) }
                } else if started {
                    Section {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            InstallProgressRow(progress: InstallLog.shared.currentProgress, note: message)
                        }
                    }
                } else if let message {
                    Section { Label(message, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.primary) }
                }
                Section {
                    NavigationLink { InstallationSettingsView() } label: {
                        LabeledContent("安装方式", value: store.settings.installationMethodTitle)
                    }.accessibilityIdentifier("installation.settings")
                    .disabled(nativePhase != nil)
                } footer: {
                    if native {
                        Text("安装前请先在 LocalDevVPN 中点按连接，完成前请勿退出 iPadn。\n安装后 App Store 能识别并更新这个应用；设备上已有的 App Store 版本会被直接覆盖，数据保留。")
                    } else {
                        Text(installationHint)
                    }
                }
            }.toolPage().navigationTitle("安装").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(nativePhase != nil) } }
                .interactiveDismissDisabled(nativePhase != nil)
                .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
                .onChange(of: scenePhase) { _, phase in if phase != .active { openingSystem = false } }
                .alert("安装未开始", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                    Button("知道了", role: .cancel) { issue = nil }
                } message: { Text(issue ?? "") }
        }
    }
    /// What this install method needs to succeed.
    private var installationHint: String {
        var text = store.settings.automaticInstallation ? AppText.text("安装完成前请勿退出 iPadn。")
            : store.settings.localInstallation ? AppText.text("需先在安装方式中创建证书、安装描述文件并开启信任。")
            : AppText.text("需要已配置的代理规则。")
        if InstallLog.insideLiveContainer && store.settings.automaticInstallation {
            text += "\n" + AppText.text("在 LiveContainer 中运行时，一键安装可能不会弹出系统安装窗口，可以改用「本机证书」。")
        }
        text += proxied ? proxyHint : ""
        text += "\n" + AppText.text("这种方式安装的应用 App Store 无法识别和更新，也不能覆盖设备上已有的 App Store 版本；需要这两项时请改用「原生安装」或导出到电脑安装。")
        return text
    }
    /// Shown while a proxy or VPN is on: the address this method needs to reach directly.
    private var proxyHint: String {
        let host = store.settings.automaticInstallation ? "api.palera.in"
            : store.settings.localInstallation ? "ipadn.localtest.me" : nil
        guard let host else { return "" }
        return "\n" + AppText.text("已开启代理：如果无法安装，请为 \(host) 添加直连（DIRECT）规则。")
    }
    /// Hands the package to the system installer and waits for it to finish.
    private func requestNativeInstallation() {
        guard !busy else { return }
        UX.feedback()
        busy = true; message = nil; started = false; nativePhase = .connecting
        Task { @MainActor in
            defer { busy = false; nativePhase = nil }
            do {
                guard let file = manager.fileURL(job) else { throw ToolError.message("找不到安装包文件，请重新下载。") }
                let outcome = try await NativeInstaller.install(package: file, bundleID: job.app.bundleID) { phase in
                    Task { @MainActor in if nativePhase != nil { nativePhase = phase } }
                }
                UX.feedback()
                message = outcome.after?.recognisedByAppStore == false
                    ? AppText.text("安装完成，但系统没有保留这个安装包的购买记录，App Store 可能无法识别它。")
                    : outcome.upgraded ? AppText.text("已覆盖安装，原有数据保留。") : AppText.text("安装完成。")
            } catch is CancellationError {
                message = nil
            } catch { issue = error.localizedDescription }
        }
    }
    private func requestInstallation(viaBrowser: Bool = false) {
        if native, !viaBrowser { requestNativeInstallation(); return }
        guard !busy, !openingSystem else { return }
        UX.feedback()
        busy = true; message = nil; started = false; attempted = true
        attempt += 1
        let current = attempt
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let file = manager.fileURL(job) else { throw ToolError.message(AppText.text("找不到安装包文件，请重新下载。")) }
                let url: URL
                if store.settings.automaticInstallation {
                    url = try await store.installation.automaticInstallURL(job: job, file: file)
                } else if store.settings.localInstallation {
                    url = try await store.installation.localInstallURL(job: job, file: file, host: store.settings.localInstallHost,
                        icon: job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL)
                } else {
                    url = try await store.installation.installURL(job: job, file: file, plistServer: store.settings.plistServer)
                }
                let local = !store.settings.automaticInstallation && store.settings.localInstallation
                let served = InstallLog.shared.manifestCount
                InstallLog.shared.beginInstallation()
                let target = try viaBrowser ? store.installation.browserPage(installURL: url, app: job.app) : url
                openURL(target) { accepted in
                    InstallLog.shared.add((viaBrowser ? "install page handed to Safari: " : "install link handed to the system: ")
                                          + (accepted ? "accepted" : "refused"))
                    if accepted {
                        started = true
                        // Until the prompt (or Safari) takes over the screen.
                        openingSystem = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(12))
                            if attempt == current { openingSystem = false }
                        }
                        message = viaBrowser ? AppText.text("请在 Safari 中确认安装，然后回到 iPadn 等待完成。") : AppText.text("请在系统弹窗中确认安装，完成前请勿退出 iPadn。")
                    }
                    else { issue = AppText.text("无法开始安装，请检查安装方式，或导出安装包。"); store.installation.stopHosting() }
                    guard accepted, local else { return }
                    // The system fetches the install details from iPadn right away;
                    // if it never did, it could not connect.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        if attempt == current, InstallLog.shared.manifestCount == served, !viaBrowser {
                            message = nil; started = false
                            issue = proxied
                                ? AppText.text("系统没能连接到 iPadn 的本机安装服务。开启代理或 VPN 时，请在代理规则中为 ipadn.localtest.me 添加直连（DIRECT）规则，或暂时关闭代理；也可以改用一键安装。")
                                : AppText.text("系统没能连接到 iPadn 的本机安装服务。请在「设置 › 通用 › 关于本机 › 证书信任设置」中确认已开启 iPadn 本机安装 CA；也可以改用一键安装。")
                        }
                    }
                }
            } catch { issue = error.localizedDescription }
        }
    }
}

/// The step a native installation is at.
private struct NativeProgressRow: View {
    let phase: NativeInstaller.Phase
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .connecting:
                Label("正在连接本机安装服务…", systemImage: "point.3.connected.trianglepath.dotted")
                ProgressView().tint(UX.tint)
            case .uploading(let fraction):
                Label("正在传输安装包 \(Int(fraction * 100))%", systemImage: "arrow.down.app")
                ProgressView(value: fraction).tint(UX.tint).animation(.linear(duration: 0.3), value: fraction)
            case .installing(let fraction):
                Label("系统正在安装 \(Int(fraction * 100))%", systemImage: "gearshape.2")
                ProgressView(value: fraction).tint(UX.tint).animation(.linear(duration: 0.3), value: fraction)
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("installation.native-progress")
    }
}

/// What the system is doing with the installation right now.
private struct InstallProgressRow: View {
    let progress: InstallLog.Progress
    let note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if progress.finished {
                Label("安装包已传输完成，可以在主屏幕查看安装进度。", systemImage: "checkmark.circle.fill")
            } else if progress.started {
                Label("正在传输安装包 \(Int(progress.fraction * 100))%", systemImage: "arrow.down.app")
                ProgressView(value: progress.fraction).tint(UX.tint)
                    .animation(.linear(duration: 0.4), value: progress.fraction)
            } else {
                Label(note ?? AppText.text("请在系统弹窗中确认安装。"), systemImage: "hand.tap")
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("installation.progress")
    }
}
