import SwiftUI
import UniformTypeIdentifiers

struct InstallationSettingsView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.openURL) private var openURL
    @State private var importing = false
    @State private var hasLocalProfile = false
    @State private var replacingCertificate = false
    @State private var certificateData: Data?
    @State private var password = ""
    @State private var certificateName = "未导入"
    @State private var issue: String?
    @State private var notice: String?
    @State private var busy = false
    /// Which action is running, shown with a spinner on its own row.
    @State private var working: Action?
    private enum Action { case create, profile, check, connection }
    /// What the file picker is importing.
    private enum ImportKind { case certificate, pairingFile }
    @State private var importKind = ImportKind.certificate
    @State private var hasPairingFile = NativeInstaller.hasPairingFile
    @State private var removingPairingFile = false
    @StateObject private var pairing = OnDevicePairing()
    @State private var showingPairingGuide = false
    @Environment(\.scenePhase) private var scenePhase
    private enum Method: Hashable { case native, automatic, localCertificate, proxy }
    private var method: Binding<Method> {
        Binding(get: {
            store.settings.usesNativeInstallation ? .native
                : store.settings.automaticInstallation ? .automatic
                : store.settings.localInstallation ? .localCertificate : .proxy
        }, set: { value in
            // The other choices are kept, so leaving native returns to them.
            store.settings.nativeInstallation = value == .native
            guard value != .native else { return }
            store.settings.automaticInstallation = value == .automatic
            if value != .automatic { store.settings.localInstallation = value == .localCertificate }
        })
    }
    var body: some View {
        Form {
            Section {
                Picker("安装方式", selection: method) {
                    Text("一键安装").tag(Method.automatic)
                    if NativeInstaller.isAvailable { Text("原生安装").tag(Method.native) }
                    Text("本机证书").tag(Method.localCertificate)
                    Text("代理服务").tag(Method.proxy)
                }.pickerStyle(.segmented).accessibilityIdentifier("installation.method")
            }
            if store.settings.usesNativeInstallation {
                Section {
                    Label("App Store 能识别并更新安装的应用", systemImage: "checkmark.seal")
                    Label("可以直接覆盖 App Store 安装的应用，数据保留", systemImage: "arrow.triangle.2.circlepath")
                    LabeledContent("配对文件", value: hasPairingFile ? "已导入" : "未导入")
                    if OnDevicePairing.isSupported {
                        Button { pairing.start(); showingPairingGuide = true } label: {
                            actionLabel(hasPairingFile ? "重新配对" : "在本机配对", systemImage: "iphone.radiowaves.left.and.right", running: pairing.phase.isActive)
                        }
                        .disabled(pairing.phase.isActive).accessibilityIdentifier("installation.pair-on-device")
                    }
                    Button("导入配对文件", systemImage: "square.and.arrow.down") { importPairingFile() }
                        .accessibilityIdentifier("installation.pairing-file")
                    Button { checkConnection() } label: { actionLabel("检查连接", systemImage: "point.3.connected.trianglepath.dotted", action: .connection) }
                        .disabled(busy || !hasPairingFile).accessibilityIdentifier("installation.native-check")
                    if hasPairingFile {
                        Button("移除配对文件", systemImage: "trash", role: .destructive) { removingPairingFile = true }
                    }
                } header: { Text("原生安装") } footer: {
                    if OnDevicePairing.isSupported {
                        Text("通过系统自带的安装服务安装，效果与用电脑安装相同。\n1. 点按「在本机配对」，然后打开「设置 › 隐私与安全性 › 开发者模式」，点按「与 iPadn 配对」，输入 iPadn 显示的配对码。看不到开发者模式时，需要先在该页面开启并重启设备。\n2. 安装前打开 LocalDevVPN 并点按连接，或使用已配置好环回路由的代理工具。\n修改锁屏密码、系统还原后需要重新配对。安装包不会离开这台设备。")
                    } else {
                        Text("通过系统自带的安装服务安装，效果与用电脑安装相同。需要两样东西：\n1. 从 App Store 安装 LocalDevVPN，安装前在其中点按连接。它与其他代理或 VPN 不能同时开启。\n2. 在电脑上用 idevice_pair 为这台设备生成「远程配对（RPPairing）」文件，放进「文件 › 我的 iPhone › iPadn」后点按「导入配对文件」，也可以从其他位置选取。系统更新或还原后可能需要重新生成。\n安装包不会离开这台设备。")
                    }
                }
                if pairing.phase != .idle, !showingPairingGuide {
                    Section { PairingStatusRow(phase: pairing.phase) { pairing.cancel() } }
                }
            } else if store.settings.automaticInstallation {
                Section {
                    Label("无需描述文件或证书", systemImage: "checkmark.seal")
                    Label("安装包不会离开这台设备", systemImage: "iphone")
                } header: { Text("一键安装（推荐）") } footer: {
                    Text("安装时需要联网。安装完成前请勿退出 iPadn。使用代理工具时，请为 api.palera.in 添加直连（DIRECT）规则。")
                }
            } else if store.settings.localInstallation {
                Section {
                    TextField("服务器地址", text: $store.settings.localInstallHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    LabeledContent("证书", value: certificateName)
                    Button {
                        if certificateName == "未导入" { createLocalCertificate() }
                        else { replacingCertificate = true }
                    } label: { actionLabel("创建证书", systemImage: "lock.shield", action: .create) }
                    .disabled(busy).accessibilityIdentifier("installation.create-certificate")
                    if hasLocalProfile {
                        Button { installProfile() } label: {
                            actionLabel("安装描述文件", systemImage: "doc.badge.gearshape", action: .profile)
                        }
                        .disabled(busy).accessibilityIdentifier("installation.local-profile")
                    }
                    Button("导入证书", systemImage: "square.and.arrow.down") { importKind = .certificate; importing = true }
                        .accessibilityIdentifier("installation.certificate")
                    Button { checkCertificate() } label: { actionLabel("检查证书", systemImage: "checkmark.shield", action: .check) }
                        .disabled(busy)
                } header: { Text("本机证书") } footer: {
                    Text("首次使用需创建证书并安装描述文件，然后在「设置 › 通用 › 关于本机 › 证书信任设置」中开启信任。使用代理工具时，请为 ipadn.localtest.me 添加直连（DIRECT）规则。")
                }
            } else {
                Section {
                    TextField("清单服务地址", text: $store.settings.plistServer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("代理服务") } footer: {
                    Text("适用于已配置 Surge、Loon 等代理规则的用户。")
                }
            }
            if let notice { Section { Label(notice, systemImage: "checkmark.circle").font(.subheadline) } }
            Section {
                Link("安装帮助", destination: URL(string: "https://github.com/mengangs/ipadn#安装下载的应用")!)
            }
        }.toolPage().navigationTitle("安装设置").navigationBarTitleDisplayMode(.inline)
            .task {
                refreshCertificate()
                // A pairing file dropped into iPadn's folder is picked up without asking.
                if store.settings.usesNativeInstallation, !hasPairingFile, (try? NativeInstaller.importPairingFileFromDocuments()) == true {
                    hasPairingFile = NativeInstaller.hasPairingFile
                    notice = "已从 iPadn 文件夹导入配对文件。请在 LocalDevVPN 中连接后点按「检查连接」。"
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active, working == .profile { working = nil } }
            .sheet(isPresented: $showingPairingGuide) {
                PairingGuideView(pairing: pairing)
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled(pairing.phase.isActive)
            }
            .onChange(of: pairing.phase) { _, phase in
                if phase == .finished {
                    hasPairingFile = NativeInstaller.hasPairingFile
                    notice = "配对完成。安装前请在 LocalDevVPN 中连接，可以点按「检查连接」确认。"
                }
            }
            // Pairing files come as .plist, .rppairing or no extension at all.
            .fileImporter(isPresented: $importing, allowedContentTypes: importKind == .pairingFile ? [.propertyList, .xml, .data, .item] : [.data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if importKind == .pairingFile {
                        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 else { throw ToolError.message("这不是有效的配对文件。") }
                        try NativeInstaller.importPairingFile(try Data(contentsOf: url))
                        hasPairingFile = NativeInstaller.hasPairingFile
                        notice = "配对文件已导入。请在 LocalDevVPN 中连接后点按「检查连接」。"
                        return
                    }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { throw ToolError.message("请选择 .p12 或 .pfx 证书文件") }
                    certificateData = try Data(contentsOf: url); password = ""
                } catch { issue = error.localizedDescription }
            }
            .sheet(isPresented: Binding(get: { certificateData != nil }, set: { if !$0 { certificateData = nil; password = "" } })) {
                NavigationStack {
                    Form {
                        Section { SecureField("证书密码（可留空）", text: $password) } footer: {
                            Text("证书仅保存在这台设备上。")
                        }
                        if let issue { Section { Text(issue).foregroundStyle(.secondary) } }
                    }.navigationTitle("导入证书").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { certificateData = nil; password = ""; issue = nil } }
                            ToolbarItem(placement: .confirmationAction) { Button("导入") { saveCertificate() } }
                        }
                }.presentationDetents([.medium, .large])
            }
            .actionConfirmation(isPresented: $removingPairingFile, title: "移除配对文件？", message: "之后使用原生安装需要重新导入。", confirmTitle: "移除", destructive: true) {
                do { try NativeInstaller.removePairingFile(); hasPairingFile = NativeInstaller.hasPairingFile; notice = "配对文件已移除。" }
                catch { issue = error.localizedDescription }
            }
            .actionConfirmation(isPresented: $replacingCertificate, title: "重新创建证书？", message: "需要重新安装并信任新的描述文件。", confirmTitle: "重新创建", destructive: false) { createLocalCertificate() }
            .alert("安装设置", isPresented: Binding(get: { issue != nil && certificateData == nil }, set: { if !$0 { issue = nil } })) {
                Button("知道了", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
    }
    private func actionLabel(_ title: String, systemImage: String, action: Action) -> some View {
        actionLabel(title, systemImage: systemImage, running: working == action)
    }
    private func actionLabel(_ title: String, systemImage: String, running: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if running { ProgressView().transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: running)
    }
    private func refreshCertificate() {
        do {
            certificateName = try InstallationCertificate.load()?.name ?? "未导入"
            hasLocalProfile = try InstallationCertificate.localProfile() != nil
        }
        catch { issue = error.localizedDescription }
    }
    private func createLocalCertificate() {
        guard !busy else { return }; busy = true; notice = nil; working = .create
        UX.feedback()
        Task {
            defer { busy = false; working = nil }
            do {
                let material = try await Task.detached(priority: .userInitiated) { try LocalInstallationIdentityFactory.create() }.value
                try InstallationCertificate.save(data: material.pkcs12, password: material.password,
                    localRoot: material.rootCertificate, localIdentifier: material.identifier)
                store.installation.stopHosting(); store.settings.localInstallation = true; store.settings.localInstallHost = ManifestBuilder.defaultLocalHost
                refreshCertificate()
                notice = "证书已创建，请安装描述文件。"
            } catch { issue = error.localizedDescription }
        }
    }
    private func installProfile() {
        guard !busy else { return }; busy = true; working = .profile
        UX.feedback()
        Task {
            // The spinner stays until Settings opens with the profile (the app
            // leaves the screen) or a few seconds pass.
            defer { busy = false; Task { try? await Task.sleep(for: .seconds(8)); if working == .profile { working = nil } } }
            do {
                guard let profile = try InstallationCertificate.localProfile() else { throw ToolError.message("请先创建证书") }
                let url = try await store.installation.profileURL(data: profile)
                openURL(url) { accepted in
                    if accepted { notice = "请在「设置」中安装描述文件，然后在「通用 › 关于本机 › 证书信任设置」中开启信任。" }
                    else { issue = "无法打开描述文件，请稍后重试。"; working = nil }
                }
            } catch { issue = error.localizedDescription; working = nil }
        }
    }
    private func saveCertificate() {
        guard let data = certificateData else { return }
        do {
            try InstallationCertificate.save(data: data, password: password)
            store.installation.stopHosting()
            certificateData = nil; password = ""; issue = nil
            refreshCertificate(); notice = "证书已导入。"
        } catch { issue = error.localizedDescription }
    }
    /// Takes a pairing file from iPadn's own folder first; the system file
    /// picker is the fallback for files kept elsewhere.
    private func importPairingFile() {
        notice = nil
        do {
            if try NativeInstaller.importPairingFileFromDocuments() {
                hasPairingFile = NativeInstaller.hasPairingFile
                notice = "已从 iPadn 文件夹导入配对文件。请在 LocalDevVPN 中连接后点按「检查连接」。"
                return
            }
        } catch {
            issue = error.localizedDescription
            return
        }
        importKind = .pairingFile
        importing = true
    }
    /// Goes through the VPN, the pairing and the tunnel, then asks the system
    /// about iPadn itself: a full rehearsal without installing anything.
    private func checkConnection() {
        guard !busy else { return }; busy = true; notice = nil; working = .connection
        UX.feedback()
        Task {
            defer { busy = false; working = nil }
            do {
                _ = try await NativeInstaller.lookup(bundleID: Bundle.main.bundleIdentifier ?? "app.local.iPadn")
                notice = "连接正常，可以使用原生安装。"
            } catch { issue = error.localizedDescription }
        }
    }
    private func checkCertificate() {
        busy = true; notice = nil; working = .check
        UX.feedback()
        Task {
            defer { busy = false; working = nil }
            do {
                let host = try ManifestBuilder.localHost(store.settings.localInstallHost)
                guard let certificate = try InstallationCertificate.load() else { throw ToolError.message("请先创建或导入证书") }
                try await certificate.validateAsync(host: host)
                notice = "证书有效。"
            } catch { issue = error.localizedDescription }
        }
    }
}

extension OnDevicePairing.Phase {
    var isActive: Bool {
        switch self {
        case .waiting, .connected, .code: return true
        default: return false
        }
    }
}

/// Where on-device pairing is, with the code to type once there is one.
private struct PairingStatusRow: View {
    let phase: OnDevicePairing.Phase
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .waiting:
                Label("请打开「设置 › 隐私与安全性 › 开发者模式」，点按「与 iPadn 配对」。", systemImage: "gear")
            case .connected:
                Label("设备已连接，正在开始配对…", systemImage: "iphone.radiowaves.left.and.right")
            case .code(let code):
                Text("在「设置」中输入配对码").font(.subheadline).foregroundStyle(.secondary)
                Text(code).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit().tracking(6)
                    .textSelection(.enabled).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("installation.pairing-code")
            case .finished:
                Label("配对完成", systemImage: "checkmark.circle.fill")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
            case .idle:
                EmptyView()
            }
            if phase.isActive {
                Button("取消配对", role: .cancel, action: cancel).frame(maxWidth: .infinity)
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("installation.pairing-status")
    }
}

/// Shown as soon as pairing starts: what to do next, where pairing is, and
/// the code once the device asks for it.
private struct PairingGuideView: View {
    @ObservedObject var pairing: OnDevicePairing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var step: Int {
        switch pairing.phase {
        case .waiting: return 1
        case .connected: return 2
        case .code: return 3
        case .finished: return 4
        default: return 0
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    guideRow(1, "打开「设置」", "隐私与安全性 › 开发者模式 › 与 iPadn 配对")
                    guideRow(2, "等待设备连接", "选中 iPadn 后会自动连接")
                    guideRow(3, "输入配对码", "配对码会显示在这里、灵动岛和通知中")
                } footer: {
                    Text("看不到「开发者模式」时，需要先在该页面开启并按提示重启设备。配对期间 iPadn 会在后台保持运行，完成后自动停止。")
                }
                Section { PairingStatusRow(phase: pairing.phase) { pairing.cancel() } }
            }
            .navigationTitle("在本机配对").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if pairing.phase.isActive {
                        Button("打开设置") { openSettings() }.accessibilityIdentifier("installation.pairing-open-settings")
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }
    private func guideRow(_ number: Int, _ title: String, _ detail: String) -> some View {
        let done = step > number && step != 0
        let current = step == number
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done || current ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(current ? .white : .secondary) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(current ? .semibold : .regular))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
    /// The Developer Mode page when the system allows it, else Settings.
    private func openSettings() {
        let candidates = ["App-prefs:Privacy&path=DEVELOPER_MODE", "App-prefs:Privacy", UIApplication.openSettingsURLString]
        func attempt(_ index: Int) {
            guard index < candidates.count, let url = URL(string: candidates[index]) else { return }
            openURL(url) { accepted in if !accepted { attempt(index + 1) } }
        }
        attempt(0)
    }
}
