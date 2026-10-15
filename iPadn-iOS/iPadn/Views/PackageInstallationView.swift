import SwiftUI

struct PackageInstallationView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let job: DownloadJob
    @State private var busy = false
    @State private var message: String?
    @State private var issue: String?
    @State private var sharedFile: SharedFile?
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
                                if busy { ProgressView().tint(UX.onAccent) }
                                Text(busy ? "正在准备…" : "安装")
                            }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy)
                        .accessibilityIdentifier("installation.request")
                        Button {
                            if let file = manager.fileURL(job) { sharedFile = SharedFile(url: file) }
                            else { issue = "找不到安装包文件，请重新下载。" }
                        } label: { Label("导出安装包", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                if let message {
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
                            ? "
在 LiveContainer 中运行时，一键安装可能不会弹出系统安装窗口，可以改用「本机证书」。" : ""))
                }
            }.toolPage().navigationTitle("安装").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
                .alert("安装未开始", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                    Button("知道了", role: .cancel) { issue = nil }
                } message: { Text(issue ?? "") }
        }
    }
    private func requestInstallation() {
        guard !busy else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                guard let file = manager.fileURL(job) else { throw ToolError.message("找不到安装包文件，请重新下载。") }
                let url: URL
                if store.settings.automaticInstallation {
                    url = try await store.installation.automaticInstallURL(job: job, file: file)
                } else if store.settings.localInstallation {
                    url = try await store.installation.localInstallURL(job: job, file: file, host: store.settings.localInstallHost)
                } else {
                    url = try await store.installation.installURL(job: job, file: file, plistServer: store.settings.plistServer)
                }
                let local = !store.settings.automaticInstallation && store.settings.localInstallation
                let served = InstallLog.shared.manifestCount
                openURL(url) { accepted in
                    InstallLog.shared.add("install link handed to the system: " + (accepted ? "accepted" : "refused"))
                    if accepted { message = "请在系统弹窗中确认安装，完成前请勿退出 iPadn。" }
                    else { issue = "无法开始安装，请检查安装方式，或导出安装包。"; store.installation.stopHosting() }
                    guard accepted, local else { return }
                    // The system fetches the install details from iPadn right away;
                    // if it never did, it could not connect.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        if InstallLog.shared.manifestCount == served {
                            message = nil
                            issue = "系统没能连接到 iPadn 的本机安装服务。请在「设置 › 通用 › 关于本机 › 证书信任设置」中确认已开启 iPadn 本机安装 CA；也可以改用一键安装。"
                        }
                    }
                }
            } catch { issue = error.localizedDescription }
        }
    }
}
