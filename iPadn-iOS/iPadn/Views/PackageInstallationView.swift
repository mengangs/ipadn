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
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        AppIcon(url: job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL, size: 96)
                        VStack(spacing: 4) {
                            Text(job.app.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                            Text([job.app.version.isEmpty ? "" : "版本 \(job.app.version)", job.app.size > 0 ? job.app.size.byteLabel : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button {
                            requestInstallation()
                        } label: {
                            HStack(spacing: 8) {
                                if busy || openingSystem { ProgressView().tint(UX.onAccent) }
                                Text(busy ? "正在准备…" : openingSystem ? "正在打开安装…" : "安装")
                                    .contentTransition(.opacity)
                            }
                            .frame(maxWidth: .infinity)
                            .animation(.easeOut(duration: 0.15), value: busy || openingSystem)
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy || openingSystem)
                        .accessibilityIdentifier("installation.request")
                        if attempted || InstallLog.insideLiveContainer {
                            Button { requestInstallation(viaBrowser: true) } label: {
                                Label("在 Safari 中安装", systemImage: "safari").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless).disabled(busy || openingSystem)
                            .accessibilityIdentifier("installation.browser")
                        }
                        Button {
                            if let file = manager.fileURL(job) { sharedFile = SharedFile(url: file) }
                            else { issue = "找不到安装包文件，请重新下载。" }
                        } label: { Label("导出安装包", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                if started {
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
                        LabeledContent("安装方式", value: store.settings.automaticInstallation ? "一键安装"
                                       : store.settings.localInstallation ? "本机证书" : "代理服务")
                    }.accessibilityIdentifier("installation.settings")
                } footer: {
                    Text((store.settings.automaticInstallation ? "安装完成前请勿退出 iPadn。"
                          : store.settings.localInstallation ? "需先在安装方式中创建证书、安装描述文件并开启信任。"
                          : "需要已配置的代理规则。")
                         + (InstallLog.insideLiveContainer && store.settings.automaticInstallation
                            ? "\n在 LiveContainer 中运行时，一键安装可能不会弹出系统安装窗口，可以改用「本机证书」。" : "")
                         + (proxied ? proxyHint : "")
                         + "\n从 App Store 安装的应用可以直接覆盖安装，数据会保留。如果系统提示先删除，通常是设备上的版本更新，或设备上的应用来自 TestFlight、其他签名工具等不同渠道。")
                }
            }.toolPage().navigationTitle("安装").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
                .onChange(of: scenePhase) { _, phase in if phase != .active { openingSystem = false } }
                .alert("安装未开始", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                    Button("知道了", role: .cancel) { issue = nil }
                } message: { Text(issue ?? "") }
        }
    }
    /// Shown while a proxy or VPN is on: the address this method needs to reach directly.
    private var proxyHint: String {
        let host = store.settings.automaticInstallation ? "api.palera.in"
            : store.settings.localInstallation ? "ipadn.localtest.me" : nil
        guard let host else { return "" }
        return "\n已开启代理：如果无法安装，请为 \(host) 添加直连（DIRECT）规则。"
    }
    private func requestInstallation(viaBrowser: Bool = false) {
        guard !busy, !openingSystem else { return }
        UX.feedback()
        busy = true; message = nil; started = false; attempted = true
        attempt += 1
        let current = attempt
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let file = manager.fileURL(job) else { throw ToolError.message("找不到安装包文件，请重新下载。") }
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
                        message = viaBrowser ? "请在 Safari 中确认安装，然后回到 iPadn 等待完成。" : "请在系统弹窗中确认安装，完成前请勿退出 iPadn。"
                    }
                    else { issue = "无法开始安装，请检查安装方式，或导出安装包。"; store.installation.stopHosting() }
                    guard accepted, local else { return }
                    // The system fetches the install details from iPadn right away;
                    // if it never did, it could not connect.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        if attempt == current, InstallLog.shared.manifestCount == served, !viaBrowser {
                            message = nil; started = false
                            issue = proxied
                                ? "系统没能连接到 iPadn 的本机安装服务。开启代理或 VPN 时，请在代理规则中为 ipadn.localtest.me 添加直连（DIRECT）规则，或暂时关闭代理；也可以改用一键安装。"
                                : "系统没能连接到 iPadn 的本机安装服务。请在「设置 › 通用 › 关于本机 › 证书信任设置」中确认已开启 iPadn 本机安装 CA；也可以改用一键安装。"
                        }
                    }
                }
            } catch { issue = error.localizedDescription }
        }
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
                Label(note ?? "请在系统弹窗中确认安装。", systemImage: "hand.tap")
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("installation.progress")
    }
}
