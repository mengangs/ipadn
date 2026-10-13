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
    private enum Method: Hashable { case automatic, localCertificate, proxy }
    private var method: Binding<Method> {
        Binding(get: {
            store.settings.automaticInstallation ? .automatic
                : store.settings.localInstallation ? .localCertificate : .proxy
        }, set: { value in
            store.settings.automaticInstallation = value == .automatic
            if value != .automatic { store.settings.localInstallation = value == .localCertificate }
        })
    }
    var body: some View {
        Form {
            Section {
                Picker("安装方式", selection: method) {
                    Text("一键安装").tag(Method.automatic)
                    Text("本机证书").tag(Method.localCertificate)
                    Text("代理服务").tag(Method.proxy)
                }.pickerStyle(.segmented).accessibilityIdentifier("installation.method")
            }
            if store.settings.automaticInstallation {
                Section {
                    Label("无需描述文件或证书", systemImage: "checkmark.seal")
                    Label("安装包不会离开这台设备", systemImage: "iphone")
                } header: { Text("一键安装（推荐）") } footer: {
                    Text("安装时需要联网。安装完成前请勿退出 iPadn。")
                }
            } else if store.settings.localInstallation {
                Section {
                    TextField("服务器地址", text: $store.settings.localInstallHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    LabeledContent("证书", value: certificateName)
                    Button("创建证书", systemImage: "lock.shield") {
                        if certificateName == "未导入" { createLocalCertificate() }
                        else { replacingCertificate = true }
                    }.disabled(busy).accessibilityIdentifier("installation.create-certificate")
                    if hasLocalProfile {
                        Button("安装描述文件", systemImage: "doc.badge.gearshape") { installProfile() }
                            .disabled(busy).accessibilityIdentifier("installation.local-profile")
                    }
                    Button("导入证书", systemImage: "square.and.arrow.down") { importing = true }
                        .accessibilityIdentifier("installation.certificate")
                    Button("检查证书", systemImage: "checkmark.shield") { checkCertificate() }.disabled(busy)
                } header: { Text("本机证书") } footer: {
                    Text("首次使用需创建证书并安装描述文件，然后在「设置 › 通用 › 关于本机 › 证书信任设置」中开启信任。")
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
            .task { refreshCertificate() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
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
            .actionConfirmation(isPresented: $replacingCertificate, title: "重新创建证书？", message: "需要重新安装并信任新的描述文件。", confirmTitle: "重新创建", destructive: false) { createLocalCertificate() }
            .alert("安装设置", isPresented: Binding(get: { issue != nil && certificateData == nil }, set: { if !$0 { issue = nil } })) {
                Button("知道了", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
    }
    private func refreshCertificate() {
        do {
            certificateName = try InstallationCertificate.load()?.name ?? "未导入"
            hasLocalProfile = try InstallationCertificate.localProfile() != nil
        }
        catch { issue = error.localizedDescription }
    }
    private func createLocalCertificate() {
        guard !busy else { return }; busy = true; notice = nil
        Task {
            defer { busy = false }
            do {
                let material = try await Task.detached(priority: .userInitiated) { try LocalInstallationIdentityFactory.create() }.value
                try InstallationCertificate.save(data: material.pkcs12, password: material.password,
                    localRoot: material.rootCertificate, localIdentifier: material.identifier)
                store.installation.stopHosting(); store.settings.localInstallation = true; store.settings.localInstallHost = "127.0.0.1"
                refreshCertificate()
                notice = "证书已创建，请安装描述文件。"
            } catch { issue = error.localizedDescription }
        }
    }
    private func installProfile() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                guard let profile = try InstallationCertificate.localProfile() else { throw ToolError.message("请先创建证书") }
                let url = try await store.installation.profileURL(data: profile)
                openURL(url) { accepted in
                    if accepted { notice = "请在「设置」中安装描述文件，然后在「通用 › 关于本机 › 证书信任设置」中开启信任。" }
                    else { issue = "无法打开描述文件，请稍后重试。" }
                }
            } catch { issue = error.localizedDescription }
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
    private func checkCertificate() {
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do {
                let host = try ManifestBuilder.localHost(store.settings.localInstallHost)
                guard let certificate = try InstallationCertificate.load() else { throw ToolError.message("请先创建或导入证书") }
                try await certificate.validateAsync(host: host)
                notice = "证书有效。"
            } catch { issue = error.localizedDescription }
        }
    }
}
