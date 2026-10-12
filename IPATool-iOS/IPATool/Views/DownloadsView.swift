import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DownloadsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @State private var filter = "全部"
    @State private var importing = false
    @State private var addLink = false
    @State private var link = ""
    @State private var share: SharedFile?
    @State private var pendingDelete: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var installing: DownloadJob?
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var actionBusy = false
    private var visible: [DownloadJob] {
        manager.jobs.filter { filter == "全部" || (filter == "已完成" ? $0.status == .completed : $0.status != .completed) }
    }
    private var totalSize: Int64 { manager.jobs.filter { $0.status == .completed }.reduce(0) { $0 + $1.app.size } }
    var body: some View {
        List(selection: $selection) {
            Section {
                HStack {
                    stat("任务", "\(manager.jobs.count)")
                    Spacer(); stat("进行中", "\(manager.jobs.filter { $0.status == .running }.count)")
                    Spacer(); stat("本地文件", totalSize.byteLabel)
                }.padding(.vertical, 8)
                Picker("任务筛选", selection: $filter) { ForEach(["全部", "进行中", "已完成"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented)
            }.listRowSeparator(.hidden)
            if let error = manager.storageError { Section { StatusBanner(text: error, symbol: "exclamationmark.triangle") } }
            if visible.isEmpty {
                Section { ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle", description: Text("搜索应用并下载，或导入自己的 IPA 文件。")) }
            } else {
                Section {
                    ForEach(visible) { job in
                        jobRow(job).tag(job.id)
                            .contextMenu {
                                if let file = manager.fileURL(job) {
                                    Button("分享 IPA", systemImage: "square.and.arrow.up") { share = SharedFile(url: file) }
                                    Button("复制本地文件链接", systemImage: "link") {
                                        perform {
                                            let url = try await store.installation.localURL(file: file)
                                            UIPasteboard.general.string = url.absoluteString
                                            store.infoMessage = "已复制本地链接，仅本机可访问；文件服务需保持应用运行。"
                                        }
                                    }
                                }
                                if job.status == .failed, job.asset != nil {
                                    Button("刷新下载链接后重试", systemImage: "arrow.clockwise") { perform { try await store.refreshDownload(job) } }
                                }
                                if job.status != .processing, job.status != .pausing {
                                    Button("删除任务及文件", systemImage: "trash", role: .destructive) { askDelete([job.id]) }
                                }
                            }
                    }
                    .onDelete { offsets in askDelete(Set(offsets.map { visible[$0].id })) }
                    .onMove(perform: filter == "全部" ? { manager.move(from: $0, to: $1) } : nil)
                }
            }
            Section {
                StatusBanner(text: "下载完成后可导出到签名工具。代理安装需要配置自己的 HTTPS 清单服务及 Surge/Loon 规则。")
            }.listRowBackground(Color.clear)
        }
        .navigationTitle("下载管理")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("导入 IPA 文件", systemImage: "doc.badge.plus") { importing = true }
                    Button("从 HTTPS 链接下载", systemImage: "link") { addLink = true }
                    Divider()
                    Button("暂停全部", systemImage: "pause.circle") { manager.pauseAll() }
                    Button("继续全部", systemImage: "play.circle") { manager.resumeAll() }
                    if !selection.isEmpty { Button("删除选中 \(selection.count) 项", systemImage: "trash", role: .destructive) { askDelete(selection) } }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("下载操作")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data, .zip], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                perform { for url in urls { try await manager.importFile(url) } }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .alert("下载安装包", isPresented: $addLink) {
            TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("开始下载") {
                do {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ToolError.message("链接无效") }
                    try manager.enqueueURL(url); link = ""
                } catch { store.errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("只下载和管理文件；链接导入不会自动生成 Apple 账号授权信息。") }
        .confirmationDialog("删除 \(pendingDelete.count) 项任务及本地文件？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do {
                    for id in pendingDelete { try manager.remove(id) }
                    selection.subtract(pendingDelete); pendingDelete.removeAll()
                } catch { store.errorMessage = error.localizedDescription }
            }
        }
        .confirmationDialog("安装 \(installing?.app.name ?? "")", isPresented: Binding(get: { installing != nil }, set: { if !$0 { installing = nil } }), titleVisibility: .visible) {
            Button("通过代理安装") {
                guard let job = installing, let file = manager.fileURL(job) else { return }
                installing = nil
                perform {
                    let url = try await store.installation.installURL(job: job, file: file, plistServer: store.settings.plistServer)
                    openURL(url) { accepted in if !accepted { store.errorMessage = "系统未接受安装链接，请检查安装环境和代理配置" } }
                }
            }
        } message: { Text("请先启用适配本应用文件路径的 Surge/Loon 规则。安装和降级是否成功取决于系统、账号许可和安装包签名。") }
        .overlay { if actionBusy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value).font(.title3.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func jobRow(_ job: DownloadJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AppIcon(url: job.app.iconURL, size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.app.name).font(.headline)
                Text([job.app.version, job.status.title].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if job.status == .running {
                    ProgressView(value: job.progress)
                    Text("\(job.downloaded.byteLabel) / \(job.expected > 0 ? job.expected.byteLabel : "大小未知")").font(.caption2).foregroundStyle(.secondary)
                }
                if let account = job.account { Text(account).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
                if job.status == .completed {
                    HStack {
                        Text(job.app.size.byteLabel).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let file = manager.fileURL(job) {
                            Button { share = SharedFile(url: file) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            switch job.status {
            case .running, .queued:
                Button { manager.pause(job.id) } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).accessibilityLabel("暂停 \(job.app.name)")
            case .paused, .failed:
                Button { manager.resume(job.id) } label: { Image(systemName: job.status == .failed ? "arrow.clockwise.circle" : "play.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).accessibilityLabel("继续 \(job.app.name)")
            case .processing, .pausing: ProgressView()
            case .completed:
                Button { installing = job } label: { Image(systemName: "square.and.arrow.down.fill").font(.title2) }
                    .buttonStyle(.borderless).accessibilityLabel("安装 \(job.app.name)")
            }
        }.padding(.vertical, 8)
    }
    private func askDelete(_ ids: Set<UUID>) { pendingDelete = ids; confirmingDelete = true }
    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !actionBusy else { return }
        actionBusy = true
        Task { defer { actionBusy = false }; do { try await operation() } catch { store.errorMessage = error.localizedDescription } }
    }
}
