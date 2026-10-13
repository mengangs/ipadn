import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DownloadsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @State private var filter: DownloadFilter = .all
    @State private var term = ""
    @State private var importing = false
    @State private var showingActions = false
    @State private var nextAction: AdditionAction?
    @State private var pickedFiles: [URL] = []
    private enum AdditionAction { case file, link }
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
    private var filteredJobs: [DownloadJob] {
        manager.jobs.filter { filter.includes($0.status) && (term.isEmpty || $0.app.name.localizedCaseInsensitiveContains(term) || $0.app.bundleID.localizedCaseInsensitiveContains(term) || $0.app.version.localizedCaseInsensitiveContains(term)) }
    }
    var body: some View {
        // Filter once per render; rows and headers read this copy.
        let visible = filteredJobs
        List {
            if !manager.jobs.isEmpty {
                Section {
                    SearchInput(text: $term, placeholder: "搜索名称、版本或 Bundle ID", capsule: true)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if let error = manager.storageError { Section { InlineIssue(message: error) } }
            if let warning = manager.discoveryWarning { Section { InlineIssue(message: warning) } }
            if let warning = manager.saveWarning { Section { InlineIssue(message: warning) } }
            if visible.isEmpty {
                Section {
                    EmptyState(title: manager.jobs.isEmpty ? "暂无下载任务" : "没有匹配任务", message: manager.jobs.isEmpty ? "在搜索中获取应用，或点按右上角的 + 导入安装包。" : "试试其他筛选条件。", symbol: manager.jobs.isEmpty ? "tray.and.arrow.down" : "line.3.horizontal.decrease.circle", actionTitle: manager.jobs.isEmpty ? "搜索应用" : "显示全部", action: {
                        if manager.jobs.isEmpty { store.tab = 0 } else { term = ""; filter = .all }
                    })
                }
            } else {
                ForEach(visible) { job in
                    Section {
                        Group {
                            if editMode.isEditing {
                                Button { toggleSelection(job.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selection.contains(job.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2)
                                            .foregroundStyle(selection.contains(job.id) ? Color.accentColor : Color.secondary)
                                            .frame(width: 32)
                                        taskContent(job).allowsHitTesting(false)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel((selection.contains(job.id) ? "取消选择 " : "选择 ") + job.app.name)
                                .accessibilityIdentifier("download.select." + job.id.uuidString)
                            } else {
                                taskContent(job)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("download.task." + job.app.id + "." + job.status.rawValue)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !editMode.isEditing && job.status != .processing && job.status != .pausing {
                                Button { askDelete([job.id]) } label: { Label("删除", systemImage: "trash") }.tint(.red)
                            }
                        }
                        .contextMenu {
                            if !editMode.isEditing {
                                Button("任务详情", systemImage: "info.circle") { inspecting = job }
                                if let file = manager.fileURL(job) {
                                    Button("导出文件", systemImage: "square.and.arrow.up") { share = SharedFile(url: file) }
                                    if job.rawFormat == nil {
                                        Button("安装", systemImage: "square.and.arrow.down") { installing = job }
                                    }
                                    Button("复制本机链接", systemImage: "link") {
                                        perform {
                                            let url = try await store.installation.localURL(file: file)
                                            UIPasteboard.general.string = url.absoluteString
                                            store.infoMessage = "已复制链接"
                                        }
                                    }
                                }
                                if job.status != .processing && job.status != .pausing {
                                    Button("删除任务及文件", systemImage: "trash", role: .destructive) { askDelete([job.id]) }
                                }
                            }
                        }
                    } header: {
                        if job.id == visible.first?.id {
                            Text(filter == .all ? "\(visible.count) 个项目" : "\(filter.rawValue) · \(visible.count)")
                        }
                    }
                }
                .onMove(perform: editMode.isEditing && filter == .all && term.isEmpty ? { manager.move(from: $0, to: $1) } : nil)
            }
        }
        .task(id: manager.jobs.filter { $0.status == .completed }.map { $0.id.uuidString }.joined()) { await manager.loadPackageIcons() }
        .toolPage().navigationTitle("下载").navigationBarTitleDisplayMode(.large)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(editMode.isEditing ? "完成" : "编辑") {
                    editMode = editMode.isEditing ? .inactive : .active
                }
                .disabled(manager.jobs.isEmpty)
                .accessibilityIdentifier("downloads.edit")
                if !manager.jobs.isEmpty {
                    Menu {
                        Picker("下载状态", selection: $filter) {
                            ForEach(DownloadFilter.allCases) { item in
                                Label(item.rawValue, systemImage: item.symbol).tag(item)
                                    .accessibilityIdentifier("download.filter." + item.id)
                            }
                        }
                    } label: {
                        Image(systemName: filter.symbol)
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("筛选下载任务，当前" + filter.rawValue).accessibilityIdentifier("download.filter.menu")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingActions = true } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .disabled(actionBusy).accessibilityLabel("添加下载").accessibilityIdentifier("downloads.add")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                HStack {
                    Text("已选 \(selection.count) 项").font(.subheadline)
                    Spacer()
                    Button("删除所选", systemImage: "trash", role: .destructive) { askDelete(selection) }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("downloads.delete-selected")
                }.padding(18).background(.regularMaterial)
            }
        }
        .onChange(of: editMode) { _, mode in if !mode.isEditing { selection.removeAll() } }
        .onChange(of: filter) { _, _ in selection.removeAll() }
        .onChange(of: term) { _, _ in selection.removeAll() }
        .sheet(isPresented: $showingActions, onDismiss: {
            let action = nextAction; nextAction = nil
            switch action {
            case .file: importing = true
            case .link: addLink = true
            case nil: break
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("添加下载").font(.title3.weight(.semibold)).padding(.bottom, 6)
                Button { nextAction = .file; showingActions = false } label: {
                    Label("导入 IPA", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("downloads.import")
                Button { nextAction = .link; showingActions = false } label: {
                    Label("通过链接下载", systemImage: "link").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
                if manager.jobs.contains(where: { [.running, .queued, .paused].contains($0.status) }) {
                    Divider()
                    Button("暂停全部", systemImage: "pause.circle") { manager.pauseAll(); showingActions = false; store.infoMessage = "已暂停下载" }
                        .disabled(!manager.jobs.contains { [.running, .queued].contains($0.status) }).frame(minHeight: 44)
                    Button("继续全部", systemImage: "play.circle") { manager.resumeAll(); showingActions = false }
                        .disabled(!manager.jobs.contains { $0.status == .paused }).frame(minHeight: 44)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .presentationDetents([.height(manager.jobs.contains { [.running, .queued, .paused].contains($0.status) } ? 360 : 240), .large])
                .presentationDragIndicator(.visible).presentationCornerRadius(28)
        }
        .sheet(isPresented: $importing, onDismiss: importPickedFiles) {
            PackageDocumentPicker { result in
                switch result {
                case .success(let urls): pickedFiles = urls
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
                importing = false
            }.ignoresSafeArea()
        }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .sheet(item: $inspecting) { item in
            NavigationStack {
                if let job = manager.jobs.first(where: { $0.id == item.id }) {
                    Form {
                        Section { AppRow(app: packageDisplayApp(job)); TaskStatusPill(status: job.status) }
                        Section("任务信息") {
                            LabeledContent("添加时间", value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                            if job.status != .completed { LabeledContent("已下载", value: job.downloaded.byteLabel) }
                            if let account = job.account { LabeledContent("Apple 账号", value: account) }
                        }
                        if let error = job.error { Section("未完成原因") { Text(error).font(.subheadline) } }
                        if job.status == .completed {
                            if let file = manager.fileURL(job) {
                                if job.rawFormat == nil { Section { PackagePlatformRow(file: file) } }
                                Section { ShareLink(item: file) { Label("导出文件", systemImage: "square.and.arrow.up") } }
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
                    try manager.enqueueURL(url); link = ""; filter = .all; term = ""; store.infoMessage = "已开始下载"
                } catch { store.errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("输入 IPA 安装包的下载链接。") }
        .actionConfirmation(isPresented: $confirmingDelete, title: "删除 \(pendingDelete.count) 项任务？", message: "已下载的安装包也会一并删除。", confirmTitle: "删除任务与文件") {
            // Delete what can be deleted; one task that just started processing
            // must not keep the others.
            var failure: Error?
            for id in pendingDelete {
                do { try manager.remove(id); selection.remove(id) } catch { failure = failure ?? error }
            }
            pendingDelete.removeAll()
            if manager.jobs.isEmpty { editMode = .inactive }
            if let failure { store.errorMessage = failure.localizedDescription } else { store.infoMessage = "已删除任务" }
        }
        .sheet(item: $installing) { job in
            PackageInstallationView(job: job).environmentObject(store).environmentObject(manager)
        }
        .overlay { if actionBusy { HStack { ProgressView(); Text("正在处理…").font(.subheadline) }.padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).allowsHitTesting(false) } }
    }
    private func taskContent(_ job: DownloadJob) -> some View {
        DownloadTaskRow(job: job, inspecting: { inspecting = job }, primary: { primary(job) }, exporting: {
            if let file = manager.fileURL(job) { share = SharedFile(url: file) }
        })
    }
    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    private func importPickedFiles() {
        let files = pickedFiles; pickedFiles.removeAll()
        guard !files.isEmpty else { return }
        perform {
            var imported = 0
            var failures: [String] = []
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            for url in files {
                do { try await manager.importFile(url); imported += 1 }
                catch { failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
                // The picker hands over a private copy; don't leave a second copy of a large IPA behind.
                if url.resolvingSymlinksInPath().path.hasPrefix(temporary) { try? FileManager.default.removeItem(at: url) }
            }
            if imported > 0 { filter = .all; term = ""; store.infoMessage = "已导入 \(imported) 个安装包" }
            if !failures.isEmpty { store.errorMessage = failures.joined(separator: "\n") }
        }
    }
    private func packageDisplayApp(_ job: DownloadJob) -> StoreApp {
        var app = job.app
        app.iconURL = job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL
        return app
    }
    private func primary(_ job: DownloadJob) {
        UX.feedback()
        switch job.status {
        case .running, .queued: manager.pause(job.id)
        case .paused: manager.resume(job.id)
        case .failed:
            if job.asset != nil { perform { try await store.refreshDownload(job) } } else { manager.resume(job.id) }
        case .completed:
            if job.rawFormat != nil, let file = manager.fileURL(job) {
                share = SharedFile(url: file)
            } else { installing = job }
        default: break
        }
    }
    private func askDelete(_ ids: Set<UUID>) {
        pendingDelete = Set(manager.jobs.filter { ids.contains($0.id) && $0.status != .processing && $0.status != .pausing }.map(\.id))
        if pendingDelete.isEmpty { store.infoMessage = "任务处理完成后才能删除" }
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
    private var displayedApp: StoreApp {
        job.displayApp(packageIcon: manager.packageIconURL(job))
    }
    private var platformSymbol: String {
        switch job.platformLabel {
        case "tvOS": return "appletv"
        case "iPad": return "ipad"
        case "Mac": return "macbook"
        case "iOS": return "iphone"
        default: return "shippingbox"
        }
    }
    /// Platform shown as its device glyph, like the App Store's compatibility icons.
    private var platformIcon: some View {
        Image(systemName: platformSymbol)
            .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            .frame(minWidth: 16)
            .accessibilityLabel(job.platformLabel)
            .accessibilityIdentifier("download.platform." + job.platformLabel)
    }
    private var appHeading: some View {
        let displayedApp = self.displayedApp
        return HStack(alignment: .center, spacing: 14) {
            AppIcon(url: displayedApp.iconURL, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayedApp.name).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    platformIcon
                    // Version and size scroll once in place when the row is too narrow.
                    MarqueeText(text: [displayedApp.version.isEmpty ? "" : "v\(displayedApp.version)",
                                       displayedApp.size > 0 ? displayedApp.size.byteLabel : ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("download.size." + job.app.id)
                }
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
    @ViewBuilder private var statusLine: some View {
        switch job.status {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let metric = manager.metrics(for: job.id)
                let now = ProcessInfo.processInfo.systemUptime
                let speed = metric?.rate(at: now) ?? 0
                Text([progressText, speed > 0 ? "\(Int64(min(speed, Double(Int64.max / 2))).byteLabel)/s" : "",
                      etaText(metric?.remaining(expected: job.expected, at: now))]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        case .paused, .pausing:
            Text([job.status.title, progressText].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        case .processing:
            Text(manager.processingDetail[job.id] ?? job.status.title)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
        default:
            TaskStatusPill(status: job.status)
        }
    }
    private var progressText: String {
        job.expected > 0 ? "\(job.downloaded.byteLabel) / \(job.expected.byteLabel)" : job.downloaded > 0 ? job.downloaded.byteLabel : ""
    }
    private func etaText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        return seconds < 60 ? "剩余 \(max(1, Int(seconds))) 秒" : seconds < 3600 ? "剩余 \(Int(ceil(seconds / 60))) 分钟"
            : "剩余 \(Int(ceil(min(seconds / 3600, 999)))) 小时"
    }
    @ViewBuilder private var trailingControl: some View {
        switch job.status {
        case .running:
            Button(action: primary) { ProgressRing(progress: job.expected > 0 ? job.progress : nil, symbol: "pause.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("暂停").accessibilityValue("\(Int(job.progress * 100))%")
        case .queued:
            Button(action: primary) { ProgressRing(progress: nil) }
                .buttonStyle(.borderless).accessibilityLabel("等待下载，点按暂停")
        case .processing where job.protectedMacPackage == true:
            // Mac packages can take minutes to process; let the user stop it.
            RowCapsule(title: "取消") { manager.cancelProcessing(job.id) }
                .accessibilityLabel("取消处理")
        case .pausing, .processing:
            ProgressView().frame(width: 44, height: 44)
        case .paused:
            RowCapsule(title: "继续", action: primary)
        case .failed:
            RowCapsule(title: "重试", action: primary)
        case .completed:
            HStack(spacing: 8) {
                if job.rawFormat == nil {
                    Button("安装", action: primary)
                        .buttonStyle(CapsuleButtonStyle(filled: true))
                        .accessibilityIdentifier("download.install." + job.app.id)
                }
                Button(action: exporting) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("分享")
                .accessibilityIdentifier("download.export." + job.app.id)
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: inspecting) { appHeading }.buttonStyle(.plain)
                trailingControl
            }
            if job.status == .running || job.status == .paused, job.expected > 0 {
                ProgressView(value: job.progress).tint(job.status == .paused ? .secondary : UX.tint)
                    .animation(.linear(duration: 0.25), value: job.progress)
                    .accessibilityLabel("下载进度").accessibilityValue("\(Int(job.progress * 100))%")
            }
            if let error = job.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
        // No implicit animation on status changes: cross-fading the old and
        // new status text and button title made them overlap mid-transition.
    }
}

/// Reads the platforms a downloaded IPA declares (UIDeviceFamily and
/// CFBundleSupportedPlatforms) off the main thread.
private struct PackagePlatformRow: View {
    let file: URL
    @State private var summary: String?
    var body: some View {
        LabeledContent("适用设备", value: summary ?? "…")
            .accessibilityIdentifier("download.package-platform")
            .task(id: file) {
                let url = file
                summary = await Task.detached(priority: .utility) {
                    (try? PackageService.platformSummary(url)) ?? "未知"
                }.value
            }
    }
}
