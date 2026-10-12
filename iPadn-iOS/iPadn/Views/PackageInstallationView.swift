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
                Section { AppRow(app: job.app) }
                Section {
                    NavigationLink { InstallationSettingsView() } label: {
                        LabeledContent("安装方式", value: store.settings.localInstallation ? "本地 HTTPS" : "代理清单服务")
                    }.accessibilityIdentifier("installation.settings")
                    Button {
                        requestInstallation()
                    } label: {
                        HStack { Label("请求系统安装", systemImage: "arrow.down.app"); Spacer(); if busy { ProgressView() } }
                    }.disabled(busy).accessibilityIdentifier("installation.request")
                    Button("导出到安装工具", systemImage: "square.and.arrow.up") {
                        if let file = manager.fileURL(job) { sharedFile = SharedFile(url: file) }
                        else { issue = "安装包文件不可用，请检查任务详情" }
                    }
                } footer: {
                    Text("本地 HTTPS 需要受信任的服务器证书；代理方式需要清单服务与规则。系统会验证 IPA 的签名和账号授权。")
                }
                if let message { Section { Text(message).font(.subheadline) } }
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
                if store.settings.localInstallation {
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
