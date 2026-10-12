import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DownloadsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var filter: DownloadFilter = .all
    @State private var term = ""
    @State private var importing = false
    @State private var addLink = false
    @State private var link = ""
    @State private var share: SharedFile?
    @State private var pendingDelete: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var installing: DownloadJob?
    @State private var inspecting: DownloadJob?
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var actionBusy = false
    private var visible: [DownloadJob] {
        manager.jobs.filter { filter.includes($0.status) && (term.isEmpty || $0.app.name.localizedCaseInsensitiveContains(term) || $0.app.bundleID.localizedCaseInsensitiveContains(term) || $0.app.version.localizedCaseInsensitiveContains(term)) }
    }
    private var totalSize: Int64 { manager.jobs.filter { $0.status == .completed }.reduce(0) { $0 + $1.app.size } }
    var body: some View {
        List(selection: $selection) {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))) {
                    StatCell(value: "\(manager.jobs.filter { DownloadFilter.active.includes($0.status) }.count)", title: "进行中")
                    StatCell(value: "\(manager.jobs.filter { $0.status == .completed }.count)", title: "已保存")
                    StatCell(value: totalSize.byteLabel, title: "本地文件")
                }.padding(.vertical, 12)
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                    Button { importing = true } label: { Label("导入 IPA", systemImage: "plus.rectangle.on.folder").frame(maxWidth: .infinity, minHeight: 36) }
                        .buttonStyle(.borderedProminent).tint(UX.buttonTint)
                    Button { addLink = true } label: { Label("链接下载", systemImage: "link").frame(maxWidth: .infinity, minHeight: 36) }
                        .buttonStyle(.bordered)
                }.font(.subheadline.weight(.semibold)).disabled(actionBusy)
                if !manager.jobs.isEmpty { SearchInput(text: $term, placeholder: "搜索名称、版本或 Bundle ID") }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DownloadFilter.allCases) { item in
                            Button { filter = item; UX.feedback() } label: {
                                Text("\(item.rawValue) \(manager.jobs.filter { item.includes($0.status) }.count)")
                                    .font(.subheadline.weight(filter == item ? .semibold : .regular))
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                                    .foregroundStyle(filter == item ? Color.white : Color.primary)
                                    .background(filter == item ? UX.buttonTint : Color(.tertiarySystemFill), in: Capsule())
                            }.buttonStyle(.plain).accessibilityAddTraits(filter == item ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }
                }.padding(.vertical, 4)
            }.listRowSeparator(.hidden)
            if let error = manager.storageError { Section { InlineIssue(message: error) } }
            if visible.isEmpty {
                Section {
                    EmptyState(title: manager.jobs.isEmpty ? "把安装包整理在这里" : "这里暂时没有任务", message: manager.jobs.isEmpty ? "从文件导入 IPA，或发现应用后加入下载。" : "试试其他状态，或清除搜索条件。", symbol: manager.jobs.isEmpty ? "tray.and.arrow.down" : "line.3.horizontal.decrease.circle", actionTitle: manager.jobs.isEmpty ? "去发现应用" : "显示全部", action: {
                        if manager.jobs.isEmpty { store.tab = 0 } else { term = ""; filter = .all }
                    })
                }
            } else {
                Section {
                    ForEach(visible) { job in
                        DownloadTaskRow(job: job, inspecting: { inspecting = job }, primary: { primary(job) }, exporting: {
                            if let file = manager.fileURL(job) { share = SharedFile(url: file) }
                        })
                        .tag(job.id)
                        .contextMenu {
                            Button("任务详情", systemImage: "info.circle") { inspecting = job }
                            if let file = manager.fileURL(job) {
                                Button("导出 IPA", systemImage: "square.and.arrow.up") { share = SharedFile(url: file) }
                                Button("通过代理安装", systemImage: "square.and.arrow.down") { installing = job }
                                Button("复制本机链接", systemImage: "link") {
                                    perform {
                                        let url = try await store.installation.localURL(file: file)
                                        UIPasteboard.general.string = url.absoluteString
                                        store.infoMessage = "已复制本机链接，使用时请保持应用运行。"
                                    }
                                }
                            }
                            if job.status != .processing && job.status != .pausing {
                                Button("删除任务及文件", systemImage: "trash", role: .destructive) { askDelete([job.id]) }
                            }
                        }
                    }
                    .onDelete { offsets in askDelete(Set(offsets.map { visible[$0].id })) }
                    .onMove(perform: filter == .all && term.isEmpty ? { manager.move(from: $0, to: $1) } : nil)
                } header: { Text("\(visible.count) 项任务") } footer: { Text("点应用名称查看详情；长按可安装、复制链接或删除。") }
            }
        }
        .toolPage().navigationTitle("下载").navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton().disabled(manager.jobs.isEmpty) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("暂停全部", systemImage: "pause.circle") { manager.pauseAll(); store.infoMessage = "已暂停可暂停的任务" }
                        .disabled(!manager.jobs.contains { [.running, .queued].contains($0.status) })
                    Button("继续全部", systemImage: "play.circle") { manager.resumeAll() }
                        .disabled(!manager.jobs.contains { $0.status == .paused })
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("批量下载操作")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                HStack {
                    Text("已选 \(selection.count) 项").font(.subheadline)
                    Spacer()
                    Button("删除所选", systemImage: "trash", role: .destructive) { askDelete(selection) }.disabled(selection.isEmpty)
                }.padding(18).background(.regularMaterial)
            }
        }
        .onChange(of: editMode) { _, mode in if !mode.isEditing { selection.removeAll() } }
        .onChange(of: filter) { _, _ in selection.removeAll() }
        .onChange(of: term) { _, _ in selection.removeAll() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data, .zip], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                perform { for url in urls { try await manager.importFile(url) }; store.infoMessage = "已导入 \(urls.count) 个安装包" }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .sheet(item: $inspecting) { item in
            NavigationStack {
                if let job = manager.jobs.first(where: { $0.id == item.id }) {
                    Form {
                        Section { AppRow(app: job.app); TaskStatusPill(status: job.status) }
                        Section("任务信息") {
                            LabeledContent("创建时间", value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("已传输", value: job.downloaded.byteLabel)
                            if let account = job.account { Text(account).font(.footnote).textSelection(.enabled) }
                            if let filename = job.localFilename { Text(filename).font(.footnote.monospaced()).textSelection(.enabled) }
                        }
                        if let error = job.error { Section("错误详情") { Text(error).font(.subheadline).textSelection(.enabled) } }
                        if job.status == .completed {
                            if let file = manager.fileURL(job) {
                                Section { ShareLink(item: file) { Label("导出 IPA", systemImage: "square.and.arrow.up") } }
                            }
                        }
                    }.toolPage().navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { inspecting = nil } } }
                }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .alert("通过链接下载", isPresented: $addLink) {
            TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("加入下载") {
                do {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ToolError.message("链接无效") }
                    try manager.enqueueURL(url); link = ""; filter = .all; term = ""; store.infoMessage = "已加入下载队列"
                } catch { store.errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("填写可直接下载 IPA 文件的 HTTPS 地址。") }
        .confirmationDialog("删除 \(pendingDelete.count) 项任务及文件？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do {
                    for id in pendingDelete { try manager.remove(id) }
                    selection.subtract(pendingDelete); pendingDelete.removeAll(); store.infoMessage = "已删除所选任务"
                } catch { store.errorMessage = error.localizedDescription }
            }
        } message: { Text("本地安装包也会删除，此操作无法撤销。") }
        .confirmationDialog("安装 \(installing?.app.name ?? "")", isPresented: Binding(get: { installing != nil }, set: { if !$0 { installing = nil } }), titleVisibility: .visible) {
            Button("通过代理安装") {
                guard let job = installing, let file = manager.fileURL(job) else { return }; installing = nil
                perform {
                    let url = try await store.installation.installURL(job: job, file: file, plistServer: store.settings.plistServer)
                    openURL(url) { accepted in if !accepted { store.errorMessage = "系统未接受安装链接，请检查代理配置" } }
                }
            }
        } message: { Text("请先配置自己的 HTTPS 清单服务和 Surge/Loon 规则。也可导出 IPA 到签名工具。") }
        .overlay { if actionBusy { HStack { ProgressView(); Text("正在处理…").font(.subheadline) }.padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).allowsHitTesting(false) } }
    }
    private func primary(_ job: DownloadJob) {
        UX.feedback()
        switch job.status {
        case .running, .queued: manager.pause(job.id)
        case .paused: manager.resume(job.id)
        case .failed:
            if job.asset != nil { perform { try await store.refreshDownload(job) } } else { manager.resume(job.id) }
        default: break
        }
    }
    private func askDelete(_ ids: Set<UUID>) {
        pendingDelete = Set(manager.jobs.filter { ids.contains($0.id) && $0.status != .processing && $0.status != .pausing }.map(\.id))
        if pendingDelete.isEmpty { store.infoMessage = "这些任务正在处理，请稍后再删除。" }
        else { confirmingDelete = true }
    }
    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !actionBusy else { return }; actionBusy = true
        Task { defer { actionBusy = false }; do { try await operation() } catch is CancellationError { } catch { store.errorMessage = error.localizedDescription } }
    }
}

struct DownloadTaskRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let job: DownloadJob
    var inspecting: () -> Void
    var primary: () -> Void
    var exporting: () -> Void
    private var byteProgress: some View {
        Text("\(job.downloaded.byteLabel) / \(job.expected > 0 ? job.expected.byteLabel : "大小未知")")
    }
    @ViewBuilder private var percentage: some View {
        if job.expected > 0 { Text("\(Int(job.progress * 100))%").foregroundStyle(.primary) }
    }
    private func speedLabel(_ speed: Double) -> some View {
        Label(speed > 0 ? "\(Int64(min(speed, Double(Int64.max / 2))).byteLabel)/s" : "正在测速…", systemImage: "speedometer")
    }
    @ViewBuilder private func etaLabel(_ seconds: TimeInterval?) -> some View {
        if let seconds, seconds.isFinite {
            Text(seconds < 60 ? "预计剩余 \(max(1, Int(seconds))) 秒" : seconds < 3600 ? "预计剩余 \(Int(ceil(seconds / 60))) 分钟" : "预计剩余 \(Int(ceil(min(seconds / 3600, 999)))) 小时")
        } else { Text(job.expected > 0 ? "正在估算剩余时间" : "总大小未知") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: inspecting) { AppRow(app: job.app).contentShape(Rectangle()) }.buttonStyle(.plain)
            if [.running, .paused, .pausing].contains(job.status) {
                if job.expected > 0 {
                    ProgressView(value: job.progress).tint(job.status == .paused ? .secondary : UX.tint)
                        .accessibilityLabel("下载进度").accessibilityValue("\(Int(job.progress * 100))%")
                } else if job.status == .running { ProgressView().accessibilityLabel("正在下载，文件大小未知") }
                ViewThatFits(in: .horizontal) {
                    HStack { byteProgress; Spacer(); percentage }
                    VStack(alignment: .leading, spacing: 4) { byteProgress; percentage }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if job.status == .running {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let metric = manager.metrics(for: job.id)
                        let now = ProcessInfo.processInfo.systemUptime
                        let speed = metric?.rate(at: now) ?? 0
                        ViewThatFits(in: .horizontal) {
                            HStack { speedLabel(speed); Spacer(); etaLabel(metric?.remaining(expected: job.expected, at: now)) }
                            VStack(alignment: .leading, spacing: 4) { speedLabel(speed); etaLabel(metric?.remaining(expected: job.expected, at: now)) }
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(alignment: .center) {
                TaskStatusPill(status: job.status)
                Spacer(minLength: 8)
                switch job.status {
                case .running, .queued:
                    Button("暂停", systemImage: "pause.fill", action: primary).buttonStyle(.bordered).controlSize(.large)
                case .paused, .failed:
                    Button(job.status == .failed ? "重试" : "继续", systemImage: job.status == .failed ? "arrow.clockwise" : "play.fill", action: primary).buttonStyle(.bordered).controlSize(.large)
                case .completed:
                    Button("导出", systemImage: "square.and.arrow.up", action: exporting).buttonStyle(.borderedProminent).tint(UX.buttonTint).controlSize(.large)
                case .processing, .pausing: ProgressView()
                }
            }.font(.subheadline)
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }.padding(.vertical, 10)
    }
}
