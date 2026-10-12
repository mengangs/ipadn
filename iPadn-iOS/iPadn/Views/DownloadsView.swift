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
    private var visible: [DownloadJob] {
        manager.jobs.filter { filter.includes($0.status) && (term.isEmpty || $0.app.name.localizedCaseInsensitiveContains(term) || $0.app.bundleID.localizedCaseInsensitiveContains(term) || $0.app.version.localizedCaseInsensitiveContains(term)) }
    }
    var body: some View {
        List {
            if !manager.jobs.isEmpty {
                Section { SearchInput(text: $term, placeholder: "搜索名称、版本或 Bundle ID") }
                    .listRowSeparator(.hidden)
            }
            if let error = manager.storageError { Section { InlineIssue(message: error) } }
            if let warning = manager.discoveryWarning { Section { InlineIssue(message: warning) } }
            if visible.isEmpty {
                Section {
                    EmptyState(title: manager.jobs.isEmpty ? "暂无下载任务" : "没有匹配任务", message: manager.jobs.isEmpty ? "搜索应用后下载，或通过右上角导入 IPA。" : "试试其他状态，或清除搜索条件。", symbol: manager.jobs.isEmpty ? "tray.and.arrow.down" : "line.3.horizontal.decrease.circle", actionTitle: manager.jobs.isEmpty ? "搜索应用" : "显示全部", action: {
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
                                        store.infoMessage = "已复制本机链接，使用时请保持应用运行。"
                                    }
                                }
                            }
                            if job.status != .processing && job.status != .pausing {
                                Button("删除任务及文件", systemImage: "trash", role: .destructive) { askDelete([job.id]) }
                            }
                            }
                        }
                    } header: {
                        if job.id == visible.first?.id { Text("\(visible.count) 项任务") }
                    }
                }
                .onMove(perform: editMode.isEditing && filter == .all && term.isEmpty ? { manager.move(from: $0, to: $1) } : nil)
            }
        }
        .task(id: manager.jobs.filter { $0.status == .completed }.map { $0.id.uuidString }.joined()) { await manager.loadPackageIcons() }
        .toolPage().navigationTitle("下载").navigationBarTitleDisplayMode(.inline)
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
                    Label("链接下载", systemImage: "link").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
                            LabeledContent("创建时间", value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("已传输", value: job.downloaded.byteLabel)
                            if let account = job.account { Text(account).font(.footnote).textSelection(.enabled) }
                            if let filename = job.localFilename { Text(filename).font(.footnote.monospaced()).textSelection(.enabled) }
                        }
                        if let error = job.error { Section("错误详情") { Text(error).font(.subheadline).textSelection(.enabled) } }
                        if job.status == .completed {
                            if let file = manager.fileURL(job) {
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
                    try manager.enqueueURL(url); link = ""; filter = .all; term = ""; store.infoMessage = "已加入下载队列"
                } catch { store.errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("填写可直接下载 IPA 文件的 HTTPS 地址。") }
        .actionConfirmation(isPresented: $confirmingDelete, title: "删除 \(pendingDelete.count) 项任务？", message: "本地安装包也会删除，此操作无法撤销。", confirmTitle: "删除任务与文件") {
            do {
                for id in pendingDelete { try manager.remove(id) }
                selection.subtract(pendingDelete); pendingDelete.removeAll()
                if manager.jobs.isEmpty { editMode = .inactive }
                store.infoMessage = "已删除任务"
            } catch { store.errorMessage = error.localizedDescription }
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
            for url in files {
                do { try await manager.importFile(url); imported += 1 }
                catch { failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var displayedApp: StoreApp {
        job.displayApp(packageIcon: manager.packageIconURL(job))
    }
    private var platformBadge: some View {
        Text(job.platformLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .accessibilityIdentifier("download.platform." + job.platformLabel)
    }
    private var appHeading: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIcon(url: displayedApp.iconURL)
            VStack(alignment: .leading, spacing: 5) {
                Text(displayedApp.name).font(.headline).lineLimit(2)
                Text([displayedApp.category,
                      displayedApp.version.isEmpty ? "" : "v\(displayedApp.version)"]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    if displayedApp.size > 0 {
                        Text(displayedApp.size.byteLabel)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    platformBadge
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
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
    private var installButton: some View {
        Button("安装", systemImage: "square.and.arrow.down", action: primary)
            .buttonStyle(DownloadActionStyle()).accessibilityIdentifier("download.install." + job.app.id)
    }
    private var exportButton: some View {
        Button("导出", systemImage: "square.and.arrow.up", action: exporting)
            .buttonStyle(DownloadActionStyle(secondary: true)).accessibilityIdentifier("download.export." + job.app.id)
    }
    @ViewBuilder private var taskAction: some View {
        switch job.status {
        case .running, .queued:
            Button("暂停", systemImage: "pause.fill", action: primary).buttonStyle(.bordered).controlSize(.large)
        case .paused, .failed:
            Button(job.status == .failed ? "重试" : "继续", systemImage: job.status == .failed ? "arrow.clockwise" : "play.fill", action: primary).buttonStyle(.bordered).controlSize(.large)
        case .completed:
            if job.rawFormat != nil {
                exportButton
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { installButton; exportButton }
            } else {
                HStack(spacing: 12) { installButton; exportButton }
            }
        case .processing, .pausing: ProgressView()
        }
    }
    @ViewBuilder private func etaLabel(_ seconds: TimeInterval?) -> some View {
        if let seconds, seconds.isFinite {
            Text(seconds < 60 ? "预计剩余 \(max(1, Int(seconds))) 秒" : seconds < 3600 ? "预计剩余 \(Int(ceil(seconds / 60))) 分钟" : "预计剩余 \(Int(ceil(min(seconds / 3600, 999)))) 小时")
        } else { Text(job.expected > 0 ? "正在估算剩余时间" : "总大小未知") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: inspecting) { appHeading }.buttonStyle(.plain)
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
            if job.status == .completed {
                TaskStatusPill(status: job.status)
                taskAction.font(.subheadline.weight(.semibold))
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { TaskStatusPill(status: job.status); Spacer(minLength: 8); taskAction }
                    VStack(alignment: .leading, spacing: 10) { TaskStatusPill(status: job.status); taskAction }
                }.font(.subheadline)
            }
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.primary).lineLimit(2) }
        }.padding(.vertical, 10)
    }
}

private struct DownloadActionStyle: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(secondary ? Color.primary : UX.onAccent)
            .background(secondary ? Color(uiColor: .tertiarySystemFill) : UX.buttonTint, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
