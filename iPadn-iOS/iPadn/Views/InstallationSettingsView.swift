import SwiftUI

struct InstallationSettingsView: View {
    @EnvironmentObject private var store: ToolStore
    private enum Method: Hashable { case automatic, proxy }
    private var method: Binding<Method> {
        Binding(get: { store.settings.automaticInstallation ? .automatic : .proxy },
                set: { store.settings.automaticInstallation = $0 == .automatic })
    }
    var body: some View {
        Form {
            Section {
                Picker("安装方式", selection: method) {
                    Text("一键安装").tag(Method.automatic)
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
            } else {
                Section {
                    TextField("清单服务地址", text: $store.settings.plistServer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("installation.plist-server")
                } header: { Text("代理服务") } footer: {
                    Text("适用于已配置 Surge、Loon 等代理规则的用户。")
                }
            }
            Section {
                Link("安装帮助", destination: URL(string: "https://github.com/mengangs/ipadn#安装下载的应用")!)
            }
        }.toolPage().navigationTitle("安装设置").navigationBarTitleDisplayMode(.inline)
    }
}
