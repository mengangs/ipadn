import SwiftUI
import UIKit

/// A newer iPadn release: what changed, and its installation package.
struct AppUpdateView: View {
    @EnvironmentObject private var store: ToolStore
    let release: AppRelease
    @State private var progress: Double?
    @State private var share: SharedFile?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("iPadn \(release.version)").font(.title2.weight(.bold))
                    Text([release.published?.formatted(date: .abbreviated, time: .omitted),
                          release.packageSize > 0 ? release.packageSize.byteLabel : nil,
                          "当前 \(AppUpdateService.currentVersion)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if !release.notes.isEmpty {
                Section("更新内容") {
                    Text(release.notes).font(.subheadline).textSelection(.enabled)
                }
            }
            Section {
                if release.package != nil {
                    Button { download() } label: {
                        HStack {
                            Label(progress == nil ? "下载安装包" : "正在下载…", systemImage: "arrow.down.circle")
                            Spacer()
                            if let progress {
                                Text("\(Int(progress * 100))%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(progress != nil)
                    .accessibilityIdentifier("update.download")
                    if let progress { ProgressView(value: progress) }
                    if let url = AppUpdateService.trollStoreURL(for: release) {
                        Button("用 TrollStore 安装", systemImage: "square.and.arrow.down") {
                            UIApplication.shared.open(url) { opened in
                                if !opened { store.errorMessage = "没有找到 TrollStore。可以下载安装包后用其他签名工具安装。" }
                            }
                        }
                    }
                }
                Link(destination: release.page) { Label("在 GitHub 查看", systemImage: "arrow.up.right.square") }
            } footer: {
                Text("安装包未签名。下载后在分享面板中选择你安装 iPadn 时用的签名工具（例如 TrollStore、轻松签），按原来的方式安装新版本即可。")
            }
        }
        .navigationTitle("iPadn 更新")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
    }

    private func download() {
        progress = 0
        Task {
            do {
                let file = try await AppUpdateService.download(release) { value in
                    // A late report must not bring back a finished download's bar.
                    Task { @MainActor in if progress != nil { progress = value } }
                }
                progress = nil
                share = SharedFile(url: file)
            } catch {
                progress = nil
                if !(error is CancellationError) { store.errorMessage = "下载失败，请检查网络后重试。" }
            }
        }
    }
}
