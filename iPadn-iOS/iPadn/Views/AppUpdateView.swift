import SwiftUI
import UIKit

/// A newer iPadn release: what changed, and its installation package.
struct AppUpdateView: View {
    @EnvironmentObject private var store: ToolStore
    let release: AppRelease
    @State private var progress: Double?
    @State private var downloaded: URL?
    @State private var share: SharedFile?
    @State private var downloading: Task<Void, Never>?

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
            let notes = AppUpdateService.blocks(release.notes, version: release.version)
            if !notes.isEmpty {
                Section("更新内容") {
                    ReleaseNotesText(blocks: notes).padding(.vertical, 4)
                }
            }
            Section {
                if release.package != nil {
                    if let downloaded {
                        Button { share = SharedFile(url: downloaded) } label: {
                            HStack {
                                Label("安装新版本", systemImage: "square.and.arrow.up")
                                Spacer()
                                Text("已下载").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("update.share")
                    } else {
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
                    }
                    if AppUpdateService.installedByTrollStore, let url = AppUpdateService.trollStoreURL(for: release) {
                        Button("用 TrollStore 安装", systemImage: "square.and.arrow.down") {
                            UIApplication.shared.open(url) { opened in
                                if !opened { store.errorMessage = "没有打开 TrollStore，请在 TrollStore 设置中开启 URL Scheme，或下载后通过分享安装。" }
                            }
                        }
                    }
                }
                Link(destination: release.page) { Label("在 GitHub 查看", systemImage: "arrow.up.right.square") }
            } footer: {
                Text(downloaded == nil
                     ? "安装包未签名。下载后在分享面板中选择你安装 iPadn 时用的签名工具（例如 TrollStore、轻松签），按原来的方式安装新版本即可。"
                     : "安装包已保存在本机，离开这个页面也不用重新下载。点「安装新版本」后，在分享面板中选择你安装 iPadn 时用的签名工具。")
            }
        }
        .navigationTitle("iPadn 更新")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .onAppear { if downloaded == nil { downloaded = AppUpdateService.downloadedPackage(for: release) } }
        .onDisappear { if share == nil { downloading?.cancel() } }
    }

    private func download() {
        guard downloading == nil else { return }
        progress = 0
        downloading = Task {
            defer { downloading = nil }
            do {
                let file = try await AppUpdateService.download(release) { value in
                    // A late report must not bring back a finished download's bar.
                    Task { @MainActor in if progress != nil { progress = value } }
                }
                progress = nil
                downloaded = file
                share = SharedFile(url: file)
            } catch {
                progress = nil
                if !(error is CancellationError) { store.errorMessage = "下载失败，请检查网络后重试。" }
            }
        }
    }
}

/// Release notes from Markdown: section headings, bullets and paragraphs,
/// with inline links and emphasis.
private struct ReleaseNotesText: View {
    let blocks: [AppUpdateService.NoteBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(inline(text)).font(.subheadline.weight(.semibold))
                        .padding(.top, index == 0 ? 0 : 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(text))
                    }
                    .font(.subheadline)
                case .paragraph(let text):
                    Text(inline(text)).font(.subheadline)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
