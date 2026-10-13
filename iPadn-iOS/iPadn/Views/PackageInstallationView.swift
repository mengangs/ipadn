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
                            else { issue = "安装包文件不可用，请检查任务详情" }
                        } label: { Label("导出到其他安装工具", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
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
                    Text(store.settings.automaticInstallation
                         ? "IPA 由 iPadn 在本机提供，无需描述文件或服务器；安装清单由公共清单服务生成（需联网）。安装期间请保持 iPadn 运行，系统会校验 IPA 签名与账号授权。"
                         : "本机证书方式需先在「安装方式」中安装描述文件，并在「设置 → 通用 → 关于本机 → 证书信任设置」中完全信任，否则系统会提示无法连接 127.0.0.1；代理方式需要清单服务与规则。")
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
                guard let file = manager.fileURL(job) else { throw ToolError.message("安装包文件不可用，请检查任务详情") }
                let url: URL
                if store.settings.automaticInstallation {
                    url = try await store.installation.automaticInstallURL(job: job, file: file)
                } else if store.settings.localInstallation {
                    url = try await store.installation.localInstallURL(job: job, file: file, host: store.settings.localInstallHost)
                } else {
                    url = try await store.installation.installURL(job: job, file: file, plistServer: store.settings.plistServer)
                }
                openURL(url) { accepted in
                    if accepted { message = "已向系统发送安装请求，请查看系统提示。安装是否完成以系统结果为准；请保持 iPadn 运行以提供安装文件。" }
                    else { issue = "系统未接受安装链接。请检查安装设置，或导出给安装工具。"; store.installation.stopHosting() }
                }
            } catch { issue = error.localizedDescription }
        }
    }
}
