import SwiftUI

struct PackageInstallationView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let job: DownloadJob
    /// Opened because the download just finished: start installing right away.
    var startsAutomatically = false
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
    @State private var cancelling = false
    @State private var autoStartPending = false
    @State private var autoStartTask: Task<Void, Never>?
    @State private var installTask: Task<Void, Never>?
    @State private var followUpTask: Task<Void, Never>?
    /// Native installation only: keep the App Store from offering updates.
    @State private var blockUpdates = false
    private var native: Bool { store.settings.usesNativeInstallation }
    private var isNativeCancellable: Bool { nativePhase?.isCancellable == true }
    private var isLockedInSystemInstall: Bool { nativePhase?.isCancellable == false }
    private var canCancel: Bool { autoStartPending || busy || isNativeCancellable }
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
                                Text(cancelling ? "正在取消…"
                                     : isLockedInSystemInstall ? "系统正在安装…"
                                     : nativePhase != nil ? "正在安装…"
                                     : busy ? "正在准备…"
                                     : openingSystem ? "正在打开安装…" : "安装")
                                    .contentTransition(.opacity)
                            }
                            .frame(maxWidth: .infinity)
                            .animation(.easeOut(duration: 0.15), value: busy || openingSystem || cancelling || nativePhase != nil)
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy || openingSystem || cancelling || nativePhase != nil)
                        .accessibilityIdentifier("installation.request")
                        if canCancel || isLockedInSystemInstall {
                            Button {
                                cancelInstallation()
                            } label: {
                                Label(isLockedInSystemInstall ? "系统安装阶段无法取消" : cancelling ? "正在取消…" : "取消安装",
                                      systemImage: isLockedInSystemInstall ? "lock.fill" : "xmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(isLockedInSystemInstall || cancelling ? Color.secondary : Color.primary)
                            .disabled(isLockedInSystemInstall || cancelling)
                            .accessibilityIdentifier("installation.cancel")
                        }
                        if !native, attempted || InstallLog.insideLiveContainer {
                            Button { requestInstallation(viaBrowser: true) } label: {
                                Label("在 Safari 中安装", systemImage: "safari").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless).disabled(busy || openingSystem || cancelling)
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
                    Section { NativeProgressRow(phase: nativePhase, cancelling: cancelling) }
                } else if started {
                    Section {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            InstallProgressRow(progress: InstallLog.shared.currentProgress, note: message)
                        }
                    }
                } else if let message {
                    Section { Label(message, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.primary) }
                }
                if native {
                    Section {
                        Toggle("阻止 App Store 更新", isOn: $blockUpdates)
                            .disabled(nativePhase != nil)
                            .accessibilityIdentifier("installation.block-updates")
                    } footer: {
                        Text("开启后，App Store 会把这个应用当作最新版本，不再提示或自动更新。想恢复更新时，关闭此项再安装一次即可。")
                    }
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
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") {
                    cancelInstallation(silent: true)
                    dismiss()
                }.disabled(isLockedInSystemInstall || cancelling) } }
                .interactiveDismissDisabled(isLockedInSystemInstall || cancelling)
                .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
                .compatibleOnChange(of: scenePhase) { phase in if phase != .active { openingSystem = false } }
                .onAppear {
                    guard startsAutomatically, !attempted, autoStartTask == nil else { return }
                    autoStartPending = true
                    autoStartTask = Task { @MainActor in
                        defer { autoStartPending = false; autoStartTask = nil }
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                        guard !Task.isCancelled else { return }
                        requestInstallation()
                    }
                }
                .onDisappear { cancelInstallation(silent: true) }
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
            text += "\n" + AppText.text("在 LiveContainer 中运行时，请在 LiveContainer 里长按 iPadn，打开设置中的「修复文件导入」，一键安装才能弹出系统安装窗口；仍不行时可以改用「本机证书」。")
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
    private func cancelInstallation(silent: Bool = false) {
        autoStartTask?.cancel(); autoStartTask = nil
        autoStartPending = false
        followUpTask?.cancel(); followUpTask = nil
        openingSystem = false
        if isLockedInSystemInstall {
            cancelling = false
            if !silent {
                message = AppText.text("已进入系统安装阶段，无法中断，请等待完成。")
            }
            return
        }
        guard busy || isNativeCancellable || installTask != nil else {
            if !silent, attempted { message = AppText.text("已取消安装。") }
            return
        }
        UX.feedback()
        if nativePhase != nil {
            cancelling = true
            NativeInstaller.cancel()
            installTask?.cancel()
            return
        }
        attempt += 1
        installTask?.cancel(); installTask = nil
        store.installation.stopHosting()
        busy = false
        cancelling = false
        started = false
        message = silent ? nil : AppText.text("已取消安装。")
    }

    /// Hands the package to the system installer and waits for it to finish.
    private func requestNativeInstallation() {
        guard !busy, !cancelling, nativePhase == nil else { return }
        UX.feedback()
        autoStartTask?.cancel(); autoStartTask = nil; autoStartPending = false
        followUpTask?.cancel(); followUpTask = nil
        installTask?.cancel()
        attempt += 1
        let current = attempt
        busy = true; cancelling = false; message = nil; issue = nil; started = false; attempted = true; nativePhase = .connecting
        installTask = Task { @MainActor in
            defer {
                if attempt == current {
                    busy = false
                    cancelling = false
                    nativePhase = nil
                    installTask = nil
                }
            }
            do {
                guard let file = manager.fileURL(job) else { throw ToolError.message(AppText.text("找不到安装包文件，请重新下载。")) }
                let outcome = try await NativeInstaller.install(package: file, bundleID: job.app.bundleID, blockUpdates: blockUpdates) { phase in
                    Task { @MainActor in
                        guard attempt == current, nativePhase != nil else { return }
                        nativePhase = phase
                        if !phase.isCancellable && cancelling {
                            cancelling = false
                            message = AppText.text("已进入系统安装阶段，无法中断，请等待完成。")
                        }
                    }
                }
                guard attempt == current else { return }
                UX.feedback()
                message = outcome.after?.recognisedByAppStore == false
                    ? AppText.text("安装完成，但系统没有保留这个安装包的购买记录，App Store 可能无法识别它。")
                    : outcome.upgraded ? AppText.text("已覆盖安装，原有数据保留。") : AppText.text("安装完成。")
                if blockUpdates, outcome.after?.updatesBlocked == true {
                    message = (message ?? "") + "\n" + AppText.text("已阻止 App Store 更新这个应用。")
                }
            } catch is CancellationError {
                guard attempt == current else { return }
                message = AppText.text("已取消安装。")
            } catch {
                guard attempt == current else { return }
                issue = error.localizedDescription
            }
        }
    }
    private func requestInstallation(viaBrowser: Bool = false) {
        if native, !viaBrowser { requestNativeInstallation(); return }
        guard !busy, !openingSystem, !cancelling else { return }
        UX.feedback()
        autoStartTask?.cancel(); autoStartTask = nil; autoStartPending = false
        followUpTask?.cancel(); followUpTask = nil
        installTask?.cancel()
        busy = true; cancelling = false; message = nil; issue = nil; started = false; attempted = true
        attempt += 1
        let current = attempt
        installTask = Task { @MainActor in
            defer {
                if attempt == current {
                    busy = false
                    cancelling = false
                    installTask = nil
                }
            }
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
                try Task.checkCancellation()
                guard attempt == current else { return }
                let local = !store.settings.automaticInstallation && store.settings.localInstallation
                let served = InstallLog.shared.manifestCount
                let target = try viaBrowser ? store.installation.browserPage(installURL: url, app: job.app) : url
                try Task.checkCancellation()
                guard attempt == current else { return }
                InstallLog.shared.beginInstallation()
                openURL(target) { accepted in
                    guard attempt == current else { return }
                    InstallLog.shared.add((viaBrowser ? "install page handed to Safari: " : "install link handed to the system: ")
                                          + (accepted ? "accepted" : "refused"))
                    if accepted {
                        started = true
                        // Until the prompt (or Safari) takes over the screen.
                        openingSystem = true
                        message = viaBrowser ? AppText.text("请在 Safari 中确认安装，然后回到 iPadn 等待完成。") : AppText.text("请在系统弹窗中确认安装，完成前请勿退出 iPadn。")
                        followUpTask?.cancel()
                        followUpTask = Task { @MainActor in
                            if local, !viaBrowser {
                                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                                guard attempt == current else { return }
                                if InstallLog.shared.manifestCount == served {
                                    message = nil; started = false; openingSystem = false
                                    issue = proxied
                                        ? AppText.text("系统没能连接到 iPadn 的本机安装服务。开启代理或 VPN 时，请在代理规则中为 ipadn.localtest.me 添加直连（DIRECT）规则，或暂时关闭代理；也可以改用一键安装。")
                                        : AppText.text("系统没能连接到 iPadn 的本机安装服务。请在「设置 › 通用 › 关于本机 › 证书信任设置」中确认已开启 iPadn 本机安装 CA；也可以改用一键安装。")
                                    return
                                }
                                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                            } else {
                                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                            }
                            if attempt == current { openingSystem = false }
                        }
                    }
                    else { issue = AppText.text("无法开始安装，请检查安装方式，或导出安装包。"); store.installation.stopHosting() }
                }
            } catch is CancellationError {
                store.installation.stopHosting()
                guard attempt == current else { return }
                message = AppText.text("已取消安装。")
            } catch {
                guard attempt == current else { return }
                issue = error.localizedDescription
            }
        }
    }
}

/// The step a native installation is at.
private struct NativeProgressRow: View {
    let phase: NativeInstaller.Phase
    var cancelling = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .connecting:
                Label(cancelling ? "正在取消连接…" : "正在连接本机安装服务…", systemImage: "point.3.connected.trianglepath.dotted")
                ProgressView().tint(UX.tint)
            case .uploading(let fraction):
                Label(cancelling ? "正在取消传输…" : "正在传输安装包 \(Int(fraction * 100))%", systemImage: "arrow.down.app")
                ProgressView(value: fraction).tint(UX.tint).animation(.linear(duration: 0.3), value: fraction)
            case .installing(let fraction):
                Label("系统正在安装 \(Int(fraction * 100))%", systemImage: "gearshape.2")
                ProgressView(value: fraction).tint(UX.tint).animation(.linear(duration: 0.3), value: fraction)
                Text("已进入系统安装阶段，请等待完成，期间无法取消。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
