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
    var body: some View {
        Form {
            Section {
                Picker("安装方式", selection: $store.settings.localInstallation) {
                    Text("本地 HTTPS").tag(true)
                    Text("代理清单服务").tag(false)
                }.accessibilityIdentifier("installation.method")
            } footer: {
                Text("通过 itms-services 请求系统安装已有授权的 IPA。系统会验证安装包签名和账号授权；有授权信息并不保证当前系统接受安装。")
            }
            if store.settings.localInstallation {
                Section {
                    TextField("证书包含的 IP 或域名", text: $store.settings.localInstallHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    LabeledContent("SSL 证书", value: certificateName)
                    Button("创建本机安装证书", systemImage: "lock.shield") {
                        if certificateName == "未导入" { createLocalCertificate() }
                        else { replacingCertificate = true }
                    }.disabled(busy).accessibilityIdentifier("installation.create-certificate")
                    if hasLocalProfile {
                        Button("安装本机证书描述文件", systemImage: "doc.badge.gearshape") { installProfile() }
                            .disabled(busy).accessibilityIdentifier("installation.local-profile")
                    }
                    Button("导入自己的 SSL 证书（高级）", systemImage: "square.and.arrow.down") { importing = true }
                        .accessibilityIdentifier("installation.certificate")
                    Button("检查证书与地址", systemImage: "checkmark.shield") { checkCertificate() }.disabled(busy)
                } header: { Text("本地服务器") } footer: {
                    Text("本机证书由你的设备自行创建，无需外部服务。首次需安装描述文件，再到「设置 → 通用 → 关于本机 → 证书信任设置」为 iPadn 本机 CA 启用完全信任。之后清单和 IPA 都由本机提供。高级导入须使用包含地址、未过期且受系统信任的服务器 SSL 证书。")
                }
                Section {
                    Text("清单和 IPA 由本机提供，无需上传安装包或配置外部清单服务。安装请求发出后，请保持 iPadn 运行；大型安装包可返回 iPadn 以继续传输。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField("HTTPS 清单服务地址", text: $store.settings.plistServer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    LabeledContent("本机文件服务", value: "127.0.0.1:8000")
                } header: { Text("代理服务") } footer: {
                    Text("保留 Surge/Loon 安装兼容方式，需要自己的 HTTPS 清单服务与对应代理规则。没有这些配置时，可选择本地 HTTPS，或将 IPA 导出给安装工具。")
                }
            }
            if let notice { Section { Label(notice, systemImage: "checkmark.circle").font(.subheadline) } }
            Section {
                Link("安装说明", destination: URL(string: "https://github.com/mengangs/ipadn#安装下载的应用")!)
            } footer: {
                Text("VPN / 配对文件安装需要专门的设备通信组件，当前版本未实现该方式。")
            }
        }.toolPage().navigationTitle("安装设置").navigationBarTitleDisplayMode(.inline)
            .task { refreshCertificate() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { throw ToolError.message("请选择不超过 2 MB 的 P12/PFX 证书") }
                    certificateData = try Data(contentsOf: url); password = ""
                } catch { issue = error.localizedDescription }
            }
            .sheet(isPresented: Binding(get: { certificateData != nil }, set: { if !$0 { certificateData = nil; password = "" } })) {
                NavigationStack {
                    Form {
                        Section { SecureField("证书密码（可留空）", text: $password) } footer: {
                            Text("证书私钥和密码仅保存于本机钥匙串，不会上传；导入失败会保留已有证书。")
                        }
                        if let issue { Section { Text(issue).foregroundStyle(.secondary) } }
                    }.navigationTitle("导入 SSL 证书").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { certificateData = nil; password = ""; issue = nil } }
                            ToolbarItem(placement: .confirmationAction) { Button("导入") { saveCertificate() } }
                        }
                }.presentationDetents([.medium, .large])
            }
            .actionConfirmation(isPresented: $replacingCertificate, title: "重新创建本机证书？", message: "将替换当前安装服务证书，需要重新安装并信任新的描述文件。账号和 IPA 不受影响。", confirmTitle: "重新创建", destructive: false) { createLocalCertificate() }
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
                notice = "本机证书已创建。请安装描述文件，并在系统设置中启用完全信任。"
            } catch { issue = error.localizedDescription }
        }
    }
    private func installProfile() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                guard let profile = try InstallationCertificate.localProfile() else { throw ToolError.message("请先创建本机安装证书") }
                let url = try await store.installation.profileURL(data: profile)
                openURL(url) { accepted in
                    if accepted { notice = "请在系统设置中安装已下载的描述文件，然后到「通用 → 关于本机 → 证书信任设置」启用 iPadn 本机 CA 的完全信任。" }
                    else { issue = "系统未打开本机描述文件地址，请稍后重试" }
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
            refreshCertificate(); notice = "SSL 证书已导入，请检查证书与地址。"
        } catch { issue = error.localizedDescription }
    }
    private func checkCertificate() {
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do {
                let host = try ManifestBuilder.localHost(store.settings.localInstallHost)
                guard let certificate = try InstallationCertificate.load() else { throw ToolError.message("请先导入 SSL 服务器证书") }
                try certificate.validate(host: host)
                notice = "证书有效且受系统信任。域名解析和系统安装仍需实际安装验证。"
            } catch { issue = error.localizedDescription }
        }
    }
}
