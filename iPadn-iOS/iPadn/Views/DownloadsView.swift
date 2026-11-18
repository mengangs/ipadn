import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DownloadsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: DownloadFilter = .all
    @State private var term = ""
    @State private var showingActions = false
    @State private var addLink = false
    @State private var link = ""
    @State private var share: SharedFile?
    @State private var presentedShareURL: URL?
    @State private var pendingDelete: Set<UUID> = []
    @State private var swipingDelete: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var installing: DownloadJob?
    /// The LiveContainer setup tip, once read, stays closed.
    @AppStorage("liveContainerTipDismissed") private var liveContainerTipDismissed = false
    @State private var inspecting: DownloadJob?
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    /// Drives the compact rows' staggered entrance in edit mode.
    @State private var editRowsShown = false
    /// The same entrance for the cards when edit mode ends.
    @State private var cardsShown = true
    /// A mode change is running; taps wait so two changes never overlap.
    @State private var switchingMode = false
    @State private var actionBusy = false
    /// FairPlay decryption of a downloaded or imported IPA.
    @ObservedObject private var fairPlay = FairPlayHub.shared.service
    @ObservedObject private var decryptRecords = DecryptRecordStore.shared
    @ObservedObject private var packages = FairPlayPresentation.shared
    @State private var pendingPackage: PackageRoute?
    @State private var pendingStart: UUID?
    @State private var pendingLibrary = false
    @State private var pendingAddLink = false
    @State private var pendingActionError: String?
    private var filteredJobs: [DownloadJob] {
        manager.jobs.filter { !swipingDelete.contains($0.id) && filter.includes($0.status) && (term.isEmpty || $0.app.name.localizedCaseInsensitiveContains(term) || $0.app.bundleID.localizedCaseInsensitiveContains(term) || $0.app.version.localizedCaseInsensitiveContains(term)) }
    }
    /// The newest finished download of each app with a newer store version.
    private var updateTargets: [UUID: StoreApp] {
        // "New version alerts" off: no hints here either.
        guard store.settings.updateNotifications else { return [:] }
        var targets: [UUID: StoreApp] = [:]
        var seen = Set<String>()
        for job in manager.jobs where job.status == .completed {
            guard let key = job.updateKey, seen.insert(key).inserted, let latest = store.availableUpdates[key] else { continue }
            targets[job.id] = latest
        }
        return targets
    }
    var body: some View {
        // Filter once per render; rows and headers read this copy.
        let visible = filteredJobs
        let updates = updateTargets
        // Both layouts stay alive and only their visibility swaps, so changing
        // modes rebuilds nothing mid-animation; the rows do all the moving.
        ZStack {
            downloadList(edit: false, visible: visible, updates: updates)
                .environment(\.editMode, .constant(.inactive))
                .opacity(editMode.isEditing ? 0 : 1)
                .allowsHitTesting(!editMode.isEditing)
                .accessibilityHidden(editMode.isEditing)
            downloadList(edit: true, visible: visible, updates: updates)
                .environment(\.editMode, $editMode)
                .opacity(editMode.isEditing ? 1 : 0)
                .allowsHitTesting(editMode.isEditing)
                .accessibilityHidden(!editMode.isEditing)
        }
        .task(id: manager.jobs.filter { $0.status == .completed }.map { $0.id.uuidString }.joined()) {
            await manager.loadPackageIcons()
            if store.settings.updateNotifications { await store.checkForUpdates() }
            // Automatic starts are coordinated by RootView, including while
            // this tab is not visible. Existing products are never replaced.
        }
        .refreshable { await store.checkForUpdates(force: true) }
        .animation(UX.motion(reduceMotion), value: manager.jobs.map(\.id))
        .toolPage().navigationTitle("下载").navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .compatibleTopBarLeading) {
                Button(editMode.isEditing ? "完成" : "编辑") { toggleEditMode() }
                .disabled(manager.jobs.isEmpty || switchingMode)
                .accessibilityIdentifier("downloads.edit")
                if !manager.jobs.isEmpty {
                    Menu {
                        // Buttons rather than a Picker: each menu item keeps its
                        // own accessibility identifier, which a Picker does not
                        // reliably carry through to the menu.
                        ForEach(DownloadFilter.allCases) { item in
                            Button {
                                filter = item
                            } label: {
                                Label(item.title, systemImage: item.symbol)
                            }
                            .accessibilityIdentifier("download.filter." + item.id)
                            .accessibilityAddTraits(filter == item ? .isSelected : [])
                        }
                    } label: {
                        Image(systemName: filter.symbol)
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(AppText.text("筛选下载任务，当前\(filter.title)")).accessibilityIdentifier("download.filter.menu")
                }
            }
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Button { showingActions = true } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .disabled(actionBusy).accessibilityLabel("添加下载").accessibilityIdentifier("downloads.add")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode.isEditing {
                HStack(spacing: 16) {
                    let ids = Set(filteredJobs.map(\.id))
                    let all = !ids.isEmpty && ids.isSubset(of: selection)
                    Button(all ? "取消全选" : "全选") {
                        if all { selection.subtract(ids) } else { selection.formUnion(ids) }
                        UX.feedback()
                    }
                    .disabled(ids.isEmpty)
                    .accessibilityIdentifier("downloads.select-all")
                    Text("已选 \(selection.count) 项").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("删除所选", systemImage: "trash", role: .destructive) { askDelete(selection) }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("downloads.delete-selected")
                }.padding(18).background(.regularMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .compatibleOnChange(of: editMode) { mode in
            if !mode.isEditing { selection.removeAll() }
            // Cards are back on screen: pull them out one after another.
            if !mode.isEditing && !cardsShown { DispatchQueue.main.async { cardsShown = true } }
            if !mode.isEditing { editRowsShown = false }
            // The edit list is already built; pull its rows out once it shows.
            if mode.isEditing { DispatchQueue.main.async { editRowsShown = true } }
        }
        .compatibleOnChange(of: filter) { _ in selection.removeAll() }
        .compatibleOnChange(of: term) { _ in selection.removeAll() }
        .sheet(isPresented: $showingActions, onDismiss: flushPackageNavigation) {
            AddDownloadSheet(
                hasActiveJobs: manager.jobs.contains { [.running, .queued, .paused].contains($0.status) },
                canPause: manager.jobs.contains { [.running, .queued].contains($0.status) },
                canResume: manager.jobs.contains { $0.status == .paused },
                onImport: { urls in
                    showingActions = false
                    importPicked(urls)
                },
                proMode: store.settings.proMode,
                onPackages: {
                    pendingLibrary = true
                    showingActions = false
                },
                onLink: {
                    pendingAddLink = true
                    showingActions = false
                },
                onPauseAll: {
                    showingActions = false
                    manager.pauseAll()
                    store.infoMessage = AppText.text("已暂停下载")
                },
                onResumeAll: {
                    showingActions = false
                    manager.resumeAll()
                },
                onError: {
                    pendingActionError = $0
                    showingActions = false
                }
            )
        }
        .sheet(item: $share, onDismiss: {
            if let url = presentedShareURL {
                presentedShareURL = nil
                TemporaryExportSweeper.scheduleDelayedRemoval(of: url)
            }
        }) { file in
            ShareSheet(items: [file.url])
                .onAppear { presentedShareURL = file.url }
        }
        .sheet(item: $inspecting, onDismiss: flushPackageNavigation) { item in
            NavigationStack {
                if let job = manager.jobs.first(where: { $0.id == item.id }) {
                    Form {
                        Section { AppRow(app: packageDisplayApp(job)); TaskStatusPill(status: job.status) }
                        Section("任务信息") {
                            LabeledContent("添加时间", value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                            TaskSizeRows(job: job, progress: manager.progress(for: job.id))
                            if let marketing = job.resolvedMarketingVersion {
                                LabeledContent("商店版本", value: marketing)
                            }
                            let packageShort = job.app.version.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !packageShort.isEmpty && packageShort != AppVersion.unknown {
                                LabeledContent("包内版本", value: packageShort)
                            }
                            if let build = job.resolvedBundleVersion {
                                LabeledContent("构建号", value: build)
                            }
                            if let versionID = job.resolvedExternalVersionID {
                                LabeledContent("商店版本 ID", value: versionID)
                            }
                            if let account = job.account { LabeledContent("Apple 账号", value: account) }
                        }
                        if let error = job.error { Section("未完成原因") { Text(error).font(.subheadline) } }
                        if job.status == .completed {
                            if let file = manager.fileURL(job) {
                                if job.rawFormat == nil {
                                    Section {
                                        PackagePlatformRow(file: file)
                                        NavigationLink { PackageInfoView(file: file, job: job) } label: {
                                            Label("安装包信息", systemImage: "info.circle")
                                        }
                                        .accessibilityIdentifier("download.package-info")
                                        if store.settings.proMode {
                                            NavigationLink { PackageContentsView(file: file) } label: {
                                                Label("浏览安装包内容", systemImage: "folder")
                                            }
                                            .accessibilityIdentifier("download.package-contents")
                                        }
                                    }
                                }
                                Section { ShareLink(item: file) { Label("导出文件", systemImage: "square.and.arrow.up") } }
                                if store.settings.proMode {
                                    decryptSection(job: job, file: file)
                                }
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
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ToolError.message(AppText.text("链接无效")) }
                    try manager.enqueueURL(url); link = ""; filter = .all; term = ""; store.infoMessage = AppText.text("已开始下载")
                } catch { store.errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("输入 IPA 安装包的下载链接。") }
        .actionConfirmation(isPresented: $confirmingDelete, title: "删除 \(pendingDelete.count) 项任务？", message: "已下载的安装包也会一并删除。", confirmTitle: "删除任务与文件") {
            // Recheck task states before the durable batch commit.
            let ids = pendingDelete.filter { !packages.protects($0) }
            pendingDelete.removeAll()
            perform {
                let count = try await manager.removeBatch(ids)
                selection.subtract(ids)
                if manager.jobs.isEmpty { editMode = .inactive }
                store.infoMessage = AppText.text("已删除 \(count) 项任务与文件")
            }
        }
        .sheet(item: $installing) { job in
            PackageInstallationView(job: job).sheetNotice().environmentObject(store).environmentObject(manager)
        }
        .overlay { if actionBusy { HStack { ProgressView(); Text("正在处理…").font(.subheadline) }.padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).allowsHitTesting(false) } }
    }
    /// Row-header count: the active filter, then how many have updates.
    private func headerSummary(visible: [DownloadJob], updates: [UUID: StoreApp]) -> String {
        var text = filter == .all ? AppText.text("\(visible.count) 个项目") : AppText.text("\(filter.title) · \(visible.count)")
        if !updates.isEmpty { text += AppText.text(" · \(updates.count) 个可更新") }
        return text
    }
    private func taskContent(_ job: DownloadJob, update: StoreApp?, editing: Bool = false) -> some View {
        let hasDecrypted = store.settings.proMode
            && job.status == .completed
            && job.rawFormat == nil
            && packageRecord(job).map { DecryptOutcomeStyle($0) == .success && packages.currentOutput($0) != nil } == true
        return DownloadTaskRow(
            snapshot: job,
            progress: manager.progress(for: job.id),
            update: update,
            kept: store.keepsVersion(job),
            decrypted: hasDecrypted,
            inspecting: { inspecting = job },
            primary: { primary(job) },
            updating: { downloadUpdate(job) }
        )
    }
    private func packageRecord(_ job: DownloadJob) -> DecryptRecord? {
        guard let url = manager.fileURL(job) else { return decryptRecords.record(for: job.id) }
        return packages.attempts(url: url, jobID: job.id).first
    }
    /// All cross-tab requests wait for the actual sheet onDismiss callback.
    private func openPackage(_ route: PackageRoute, start: UUID? = nil) {
        pendingPackage = route
        pendingStart = start
        if inspecting != nil { inspecting = nil }
        else if showingActions { showingActions = false }
        else { flushPackageNavigation() }
    }
    private func flushPackageNavigation() {
        guard !showingActions, inspecting == nil else { return }
        if let error = pendingActionError {
            pendingActionError = nil
            store.errorMessage = error
        }
        if pendingAddLink {
            pendingAddLink = false
            addLink = true
            return
        }
        guard store.settings.proMode else {
            pendingLibrary = false
            pendingPackage = nil
            pendingStart = nil
            return
        }
        if pendingLibrary { pendingLibrary = false; packages.showLibrary() }
        guard let route = pendingPackage else { return }
        let start = pendingStart
        pendingPackage = nil; pendingStart = nil
        packages.navigate(route)
        if let id = start, let job = manager.jobs.first(where: { $0.id == id }), let url = manager.fileURL(job) {
            packages.requestStart(url: url, job: job)
        }
    }
    private func startDecrypt(_ job: DownloadJob) {
        guard store.settings.proMode, job.status == .completed, manager.fileURL(job) != nil else { return }
        openPackage(.source(job.id), start: job.id)
    }
    @ViewBuilder private func decryptSection(job: DownloadJob, file: URL) -> some View {
        let record = packageRecord(job)
        Section("应用包") {
            LabeledContent(
                "原始 IPA",
                value: packages.detecting.contains(file)
                    ? AppText.text("正在检查…")
                    : PackageStage.detection(packages.detections[file] ?? record?.detection)
            )
            .task(id: file) { await packages.detect(file) }
            if let record {
                let style = DecryptOutcomeStyle(record)
                LabeledContent("最近处理", value: style.title)
                if style == .running {
                    Button("查看解密进度", systemImage: "circle.dotted") { openPackage(.record(record.id)) }
                } else if style == .success && packages.currentOutput(record) != nil {
                    Button("查看解密结果", systemImage: "lock.open") { openPackage(.record(record.id)) }
                } else if style == .partial && packages.currentOutput(record) != nil {
                    Button("查看部分成功产物", systemImage: "exclamationmark.triangle") { openPackage(.record(record.id)) }
                } else {
                    Button("查看处理记录", systemImage: "clock") { openPackage(.record(record.id)) }
                    if packages.detections[file]?.state != .plain {
                        Button("重新解密", systemImage: "lock.open") { startDecrypt(job) }
                            .accessibilityIdentifier("download.details.decrypt")
                    }
                }
            } else if packages.detections[file]?.state != .plain {
                Button("解密 IPA", systemImage: "lock.open") { startDecrypt(job) }
                    .accessibilityIdentifier("download.details.decrypt")
            }
            Button("查看原始 IPA", systemImage: "shippingbox") { openPackage(.source(job.id)) }
        }
    }
    private func shareAction(_ job: DownloadJob) -> [RevealAction] {
        guard job.status == .completed, manager.fileURL(job) != nil else { return [] }
        return [RevealAction(title: "分享", systemImage: "square.and.arrow.up", tint: .blue, role: nil) {
            if let file = manager.exportURL(job) { share = SharedFile(url: file) }
        }]
    }
    private func downloadUpdate(_ job: DownloadJob) {
        UX.feedback()
        perform { try await store.downloadUpdate(of: job); filter = .all; term = "" }
    }
    private func downloadAllUpdates() {
        let jobs = manager.jobs.filter { updateTargets[$0.id] != nil }
        UX.feedback()
        perform { try await store.downloadAllUpdates(of: jobs); filter = .all; term = "" }
    }
    /// One layout of the list: task cards, or the compact rows of edit mode.
    @ViewBuilder private func downloadList(edit: Bool, visible: [DownloadJob], updates: [UUID: StoreApp]) -> some View {
            List {
                if !manager.jobs.isEmpty {
                    Section {
                        SearchInput(text: $term, placeholder: "搜索名称、版本或 Bundle ID", capsule: true)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if let error = manager.storageError { Section { InlineIssue(message: error) } }
                if InstallLog.insideLiveContainer && !liveContainerTipDismissed {
                    Section {
                        LiveContainerTip { withAnimation { liveContainerTipDismissed = true } }
                    }
                }
                if let autoInstall = manager.autoInstalling {
                    Section {
                        HStack(spacing: 12) {
                            Group {
                                if autoInstall.hasProgress || !autoInstall.canCancel {
                                    ProgressView(value: autoInstall.fraction)
                                        .progressViewStyle(.circular)
                                } else {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                }
                            }
                            .tint(UX.tint)
                            .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(autoInstall.hasProgress || !autoInstall.canCancel
                                     ? AppText.text("正在自动安装 \(autoInstall.name)（\(Int((autoInstall.fraction * 100).rounded()))%）")
                                     : AppText.text("正在准备自动安装 \(autoInstall.name)"))
                                    .font(.subheadline.weight(.medium))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                Text(autoInstall.stage == .installing || !autoInstall.canCancel
                                     ? AppText.text("已进入系统安装阶段，无法取消")
                                     : autoInstall.stage == .uploading
                                     ? AppText.text("正在传输安装包，可随时取消")
                                     : AppText.text("正在连接本机安装服务，可随时取消"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if autoInstall.canCancel {
                                Button("取消") {
                                    UX.feedback()
                                    _ = manager.cancelAutoInstall(autoInstall.id)
                                }
                                .buttonStyle(CapsuleButtonStyle())
                                .accessibilityIdentifier("downloads.auto-install.cancel")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            if manager.waitingForWiFi, manager.jobs.contains(where: { [.queued, .pausing].contains($0.status) }) {
                Section { WiFiWaitRow() }
            }
                if let warning = manager.discoveryWarning { Section { InlineIssue(message: warning) } }
                if let warning = manager.saveWarning { Section { InlineIssue(message: warning) } }
                if visible.isEmpty {
                    Section {
                        EmptyState(title: manager.jobs.isEmpty ? "暂无下载任务" : "没有匹配任务", message: manager.jobs.isEmpty ? "在搜索中获取应用，或点按右上角的 + 导入安装包。" : "试试其他筛选条件。", symbol: manager.jobs.isEmpty ? "tray.and.arrow.down" : "line.3.horizontal.decrease.circle", actionTitle: manager.jobs.isEmpty ? "搜索应用" : "显示全部", action: {
                            if manager.jobs.isEmpty { store.selectTab(.search) } else { term = ""; filter = .all }
                        })
                    }
                } else if edit {
                    Section {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, job in
                            editRow(job)
                                // Rows settle in one after another, a few hundredths apart.
                                .modifier(DrawerRow(shown: editRowsShown || reduceMotion, index: index, travel: 18))
                        }
                        .onMove(perform: filter == .all && term.isEmpty ? { manager.move(from: $0, to: $1) } : nil)
                    } header: {
                        Text(headerSummary(visible: visible, updates: updates))
                    } footer: {
                        if filter == .all && term.isEmpty && visible.count > 1 {
                            // Shown with the rows, not before them.
                            Text("拖动右侧的把手调整顺序，等待中的任务按这个顺序下载。")
                                .opacity(editRowsShown || reduceMotion ? 1 : 0)
                                .animation(.easeOut(duration: 0.18).delay(0.08), value: editRowsShown)
                        }
                    }
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, job in
                        Section {
                            taskContent(job, update: updates[job.id], editing: false)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("download.task." + job.app.id + "." + job.status.rawValue)
                            // Swipe for Delete (full swipe) and, with a file, Share: the row keeps its room for the version.
                            .revealActions(id: "download." + job.id.uuidString,
                                           enabled: !actionBusy && job.status != .processing && job.status != .pausing,
                                           restored: manager.recentlyRestoredIDs.contains(job.id),
                                           [.delete(fills: true) { swipeDelete(job.id) }] + shareAction(job))
                            .contextMenu {
                                if let latest = updates[job.id] {
                                    Button("下载新版本 \(latest.version)", systemImage: "arrow.down.circle") { downloadUpdate(job) }
                                }
                                if job.status == .completed && job.updateKey != nil {
                                    if store.keepsVersion(job) {
                                        Button("恢复更新提醒", systemImage: "bell") { store.keepVersion(false, of: job); UX.feedback() }
                                    } else {
                                        Button("保留此版本", systemImage: "pin") {
                                            store.keepVersion(true, of: job); UX.feedback()
                                            store.infoMessage = AppText.text("已保留此版本，不再提醒更新")
                                        }
                                    }
                                }
                                Button("任务详情", systemImage: "info.circle") { inspecting = job }
                                if store.settings.proMode, job.status == .completed, job.rawFormat == nil, manager.fileURL(job) != nil {
                                    if let record = packageRecord(job) {
                                        let style = DecryptOutcomeStyle(record)
                                        if style == .running {
                                            Button("查看解密进度", systemImage: "circle.dotted") { openPackage(.record(record.id)) }
                                        } else if style == .success && packages.currentOutput(record) != nil {
                                            Button("查看解密结果", systemImage: "lock.open") { openPackage(.record(record.id)) }
                                        } else if style == .partial && packages.currentOutput(record) != nil {
                                            Button("查看部分成功产物", systemImage: "exclamationmark.triangle") { openPackage(.record(record.id)) }
                                        } else {
                                            Button("重新解密", systemImage: "lock.open") { startDecrypt(job) }
                                        }
                                    } else {
                                        Button("解密 IPA", systemImage: "lock.open") { startDecrypt(job) }
                                    }
                                }
                                if let file = manager.fileURL(job) {
                                    Button("导出文件", systemImage: "square.and.arrow.up") { share = SharedFile(url: manager.exportURL(job) ?? file) }
                                    if job.rawFormat == nil {
                                        Button("安装", systemImage: "square.and.arrow.down") { installing = job }
                                    }
                                    Button("复制本机链接", systemImage: "link") {
                                        perform {
                                            let url = try await store.installation.localURL(file: file)
                                            UIPasteboard.general.string = url.absoluteString
                                            store.infoMessage = AppText.text("已复制链接")
                                        }
                                    }
                                }
                                if job.status != .processing && job.status != .pausing {
                                    Button("删除任务及文件", systemImage: "trash", role: .destructive) { askDelete([job.id]) }
                                }
                            }
                            // Outside the card background, so the whole card slides.
                            .modifier(DrawerRow(shown: cardsShown || reduceMotion, index: index, travel: 28))
                        } header: {
                            if job.id == visible.first?.id {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(headerSummary(visible: visible, updates: updates))
                                    Spacer()
                                    // One update has its own button on the row.
                                    if updates.count > 1 {
                                        Button("全部更新") { downloadAllUpdates() }
                                            .font(.body.weight(.semibold)).textCase(nil).buttonStyle(.borderless)
                                            .disabled(actionBusy)
                                            .accessibilityIdentifier("downloads.update-all")
                                    }
                                }
                            }
                        }
                    }
                }
            }
    }

    /// Like a drawer: the current rows slide up and in, the list swaps while
    /// nothing is showing, then the other layout's rows slide down and out.
    private func toggleEditMode() {
        guard !switchingMode else { return }
        let entering = !editMode.isEditing
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { editMode = entering ? .active : .inactive }
            return
        }
        switchingMode = true
        if entering { cardsShown = false } else { editRowsShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // The list itself swaps without a transition; this animation only
            // moves the bottom bar and the toolbar title.
            if entering { editRowsShown = false } else { cardsShown = false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { editMode = entering ? .active : .inactive }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { switchingMode = false }
        }
    }

    /// A compact row for edit mode: selection mark, icon, name and state.
    private func editRow(_ job: DownloadJob) -> some View {
        let app = job.displayApp(packageIcon: manager.packageIconURL(job))
        let selected = selection.contains(job.id)
        let details = [job.conciseVersionLabel, job.status.title].filter { !$0.isEmpty }.joined(separator: " · ")
        return Button { toggleSelection(job.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .compatibleSymbolReplacement()
                AppIcon(url: app.iconURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name.isEmpty ? app.bundleID : app.name).font(.body).lineLimit(1)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? AppText.text("取消选择 \(app.name)") : AppText.text("选择 \(app.name)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("download.select." + job.id.uuidString)
    }
    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    private func importPicked(_ files: [URL]) {
        guard !files.isEmpty else { return }
        perform {
            var imported = 0
            var failures: [String] = []
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            for url in files {
                do { try await manager.importFile(url); imported += 1 }
                catch { failures.append(AppText.text("\(url.lastPathComponent)：\(error.localizedDescription)")) }
                // The picker hands over a private copy; don't leave a second copy of a large IPA behind.
                if url.resolvingSymlinksInPath().path.hasPrefix(temporary) { try? FileManager.default.removeItem(at: url) }
            }
            if imported > 0 { filter = .all; term = ""; store.infoMessage = AppText.text("已导入 \(imported) 个安装包") }
            if !failures.isEmpty { store.errorMessage = failures.joined(separator: "\n") }
        }
    }
    private func packageDisplayApp(_ job: DownloadJob) -> StoreApp {
        var app = job.displayApp(packageIcon: manager.packageIconURL(job))
        app.version = job.userFacingVersion
        return app
    }
    private func primary(_ job: DownloadJob) {
        UX.tapLight()
        #if DEBUG
        if LocalResources.isPreview, ProcessInfo.processInfo.arguments.contains("--completion-preview"), job.status == .running {
            manager.completePreviewDownload(job.id)
            return
        }
        #endif
        switch job.status {
        case .running, .queued: manager.pause(job.id)
        case .paused: manager.resume(job.id)
        case .failed:
            let isRetryableOfficialMacPkg = job.rawFormat == "pkg" && UInt64(job.app.id) != nil && store.apple.active != nil
            if job.asset != nil || isRetryableOfficialMacPkg {
                perform { try await store.refreshDownload(job) }
            } else {
                manager.resume(job.id)
            }
        case .completed:
            if job.rawFormat != nil, let file = manager.exportURL(job) {
                share = SharedFile(url: file)
            } else { installing = job }
        default: break
        }
    }
    private func swipeDelete(_ id: UUID) {
        guard !actionBusy, !swipingDelete.contains(id), !packages.protects(id) else { return }
        withAnimation(UX.motion(reduceMotion)) { _ = swipingDelete.insert(id) }
        Task { @MainActor in
            defer { _ = withAnimation(UX.motion(reduceMotion)) { swipingDelete.remove(id) } }
            do {
                try await SAPSigner.$userInitiated.withValue(true) {
                    try await store.removeDownloadWithUndo(id)
                }
            } catch is CancellationError {
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
    private func askDelete(_ ids: Set<UUID>) {
        pendingDelete = Set(manager.jobs.filter { ids.contains($0.id) && !packages.protects($0.id) && $0.status != .processing && $0.status != .pausing }.map(\.id))
        if pendingDelete.isEmpty { store.infoMessage = AppText.text("任务处理完成后才能删除") }
        else { confirmingDelete = true }
    }
    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !actionBusy else { return }; actionBusy = true
        Task {
            defer { actionBusy = false }
            do { try await SAPSigner.$userInitiated.withValue(true) { try await operation() } }
            catch is CancellationError { }
            catch AppleLoginError.verificationRequired { store.requestVerification { perform(operation) } }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

struct DownloadTaskRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let snapshot: DownloadJob
    @ObservedObject var progress: DownloadProgressState
    private var job: DownloadJob { progress.applying(to: snapshot) }
    /// The store's newer version of this app, when there is one.
    var update: StoreApp? = nil
    /// Kept at this version: no update reminders.
    var kept = false
    var decrypted = false
    var inspecting: () -> Void
    var primary: () -> Void
    var updating: () -> Void = {}
    /// The status seen last, so finishing in front of the user can be shown.
    @State private var seenStatus: DownloadStatus?
    /// Just finished: the ring closes into a check before Install appears.
    @State private var celebrating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        let versionText = job.conciseVersionLabel
        let sizeText = displayedApp.size > 0 ? displayedApp.size.byteLabel : ""
        return HStack(alignment: .center, spacing: 14) {
            AppIcon(url: displayedApp.iconURL, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayedApp.name).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    platformIcon
                    if !versionText.isEmpty || !sizeText.isEmpty {
                        // Keep file size visible when version labels are long or screens are narrow.
                        HStack(spacing: 4) {
                            if !versionText.isEmpty {
                                Text(verbatim: versionText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(0)
                            }
                            if !versionText.isEmpty && !sizeText.isEmpty {
                                Text(verbatim: "·")
                                    .layoutPriority(1)
                            }
                            if !sizeText.isEmpty {
                                Text(verbatim: sizeText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.8 : 1.0)
                                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
                                    .layoutPriority(2)
                            }
                        }
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("download.size." + job.app.id)
                    }
                }
                statusLine
                    .id(controlKey)
                    .transition(.statusSwap(reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
    /// Identity of the status line and trailing control: a change swaps them
    /// with the sequential transition below instead of a cross-fade.
    private var controlKey: String {
        "\(job.status.rawValue)-\(manager.cancelling.contains(job.id))"
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
            Text(manager.cancelling.contains(job.id) ? AppText.text("正在取消…") : manager.processingDetail[job.id] ?? job.status.title)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
        case .completed:
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    completedStatusItems
                }
            } else {
                HStack(spacing: 8) {
                    completedStatusItems
                }
            }
        default:
            TaskStatusPill(status: job.status)
        }
    }
    @ViewBuilder private var completedStatusItems: some View {
        TaskStatusPill(status: job.status)
        if decrypted {
            HStack(spacing: 3) {
                Image(systemName: "lock.open.fill").imageScale(.small).accessibilityHidden(true)
                Text("已解密")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
        }
    }
    private var progressText: String {
        job.expected > 0 ? "\(job.downloaded.byteLabel) / \(job.expected.byteLabel)" : job.downloaded > 0 ? job.downloaded.byteLabel : ""
    }
    private func etaText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        return seconds < 60 ? AppText.text("剩余 \(max(1, Int(seconds))) 秒")
            : seconds < 3600 ? AppText.text("剩余 \(Int(ceil(seconds / 60))) 分钟")
            : AppText.text("剩余 \(Int(ceil(min(seconds / 3600, 999)))) 小时")
    }
    @ViewBuilder private var trailingControl: some View {
        switch job.status {
        case .running:
            Button(action: primary) { ProgressRing(progress: job.expected > 0 ? job.progress : nil, symbol: "pause.fill") }
                .buttonStyle(RevealRowButtonStyle())
                .accessibilityLabel("暂停").accessibilityValue("\(Int(job.progress * 100))%")
        case .queued:
            Button(action: primary) { ProgressRing(progress: nil) }
                .buttonStyle(RevealRowButtonStyle()).accessibilityLabel("等待下载，点按暂停")
        case .processing where manager.cancelling.contains(job.id):
            ProgressView().frame(width: 44, height: 44)
                .accessibilityLabel("正在取消")
        case .processing where job.protectedMacPackage == true:
            // Mac packages can take minutes to process; let the user stop it.
            RowCapsule(title: "取消") { manager.cancelProcessing(job.id) }
                .accessibilityLabel("取消处理")
        case .pausing, .processing:
            SpinningRing()
                .accessibilityLabel(job.status == .pausing ? job.status.title : AppText.text("正在处理"))
        case .paused:
            RowCapsule(title: "继续", haptic: false, action: primary)
        case .failed:
            RowCapsule(title: "重试", haptic: false, action: primary)
        case .completed where celebrating:
            CompletionRing()
        case .completed:
            // Share moved into the row's swipe actions.
            if job.rawFormat == nil {
                Button("安装", action: primary)
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                    .accessibilityIdentifier("download.install." + job.app.id)
            }
        }
    }
    private var showsTrailingControl: Bool {
        job.status != .completed || job.rawFormat == nil
    }
    @ViewBuilder private var trailingControls: some View {
        if showsTrailingControl {
            trailingControl
                .id(controlKey + (celebrating ? "-done" : ""))
                .transition(.statusSwap(reduceMotion: reduceMotion))
                .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? nil : 74, minHeight: 44, alignment: .center)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: inspecting) { appHeading }.buttonStyle(RevealRowButtonStyle())
                    trailingControls
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 10) {
                    Button(action: inspecting) { appHeading }.buttonStyle(RevealRowButtonStyle())
                    trailingControls
                }
            }
            if [.running, .pausing, .paused].contains(job.status), job.expected > 0 {
                ProgressView(value: job.progress).tint(job.status == .running ? UX.tint : .secondary)
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: job.progress)
                    .transition(.opacity)
                    .accessibilityLabel("下载进度").accessibilityValue("\(Int(job.progress * 100))%")
            }
            if job.status == .completed && kept {
                Label("已保留此版本，不提醒更新", systemImage: "pin.fill")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("download.kept." + job.app.id)
            } else if job.status == .completed, let update {
                // Its own button: the heading above is already one.
                Button(action: updating) {
                    Label("有新版本 \(update.version)，点按下载", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(UX.tint).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(RevealRowButtonStyle())
                .transition(.opacity)
                .accessibilityLabel("下载新版本 \(update.version)")
                .accessibilityIdentifier("download.update." + job.app.id)
            }
            if let error = job.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption).foregroundStyle(.red)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : .compatibleSnappy(duration: 0.34), value: controlKey)
        .animation(reduceMotion ? nil : .compatibleSnappy(duration: 0.34), value: celebrating)
        .animation(reduceMotion ? nil : .compatibleSnappy(duration: 0.34), value: job.error)
        .animation(reduceMotion ? nil : .compatibleSnappy(duration: 0.34), value: job.expected > 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: update?.version)
        .onAppear { seenStatus = job.status }
        .compatibleOnChange(of: job.status) { status in
            let before = seenStatus
            seenStatus = status
            if status != .completed { celebrating = false }
            // Finished while on screen: give tactile confirmation and celebrate briefly.
            guard status == .completed, before == .running || before == .processing else { return }
            UX.success()
            guard !reduceMotion else { return }
            celebrating = true
        }
        .task(id: celebrating) {
            guard celebrating else { return }
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            celebrating = false
        }
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
                    (try? PackageService.platformSummary(url)) ?? AppText.text("未知")
                }.value
            }
    }
}

/// Size rows of a task's details. Running and paused tasks read the live
/// byte counter, which the stored task only catches up with on save.
private struct TaskSizeRows: View {
    let job: DownloadJob
    @ObservedObject var progress: DownloadProgressState
    var body: some View {
        let current = progress.applying(to: job)
        let total = current.expected > 0 ? current.expected : current.app.size
        if current.status == .completed {
            if total > 0 { LabeledContent("大小", value: total.byteLabel) }
        } else {
            LabeledContent("已下载", value: total > 0 && current.downloaded > 0
                           ? "\(current.downloaded.byteLabel)（\(Int((Double(current.downloaded) / Double(total) * 100).rounded(.down)))%）"
                           : current.downloaded.byteLabel)
                .accessibilityIdentifier("download.detail.downloaded")
            if total > 0 { LabeledContent("大小", value: total.byteLabel) }
        }
    }
}

/// A row that slides down out of the list's top edge a few hundredths of a
/// second after the one above it, like a drawer pulled out; hidden again, all
/// rows slide back up together.
private struct DrawerRow: ViewModifier {
    let shown: Bool
    let index: Int
    let travel: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -travel)
            .scaleEffect(x: 1, y: shown ? 1 : 0.9, anchor: .top)
            .animation(shown ? .spring(response: 0.32, dampingFraction: 0.84).delay(0.01 + Double(min(index, 10)) * 0.02)
                             : .easeIn(duration: 0.12), value: shown)
    }
}

/// "Add download" menu. It owns the document picker itself: a picker presented
/// from the dismissing menu sheet is dropped by SwiftUI, which is why importing
/// and decrypt-import used to do nothing.
private struct AddDownloadSheet: View {
    let hasActiveJobs: Bool
    let canPause: Bool
    let canResume: Bool
    let onImport: ([URL]) -> Void
    let proMode: Bool
    let onPackages: () -> Void
    let onLink: () -> Void
    let onPauseAll: () -> Void
    let onResumeAll: () -> Void
    let onError: (String) -> Void

    @State private var picker: PickerKind?

    private enum PickerKind: String, Identifiable {
        case ipa, decrypt
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加下载").font(.title3.weight(.semibold)).padding(.bottom, 6)
            Button { picker = .ipa } label: {
                Label("导入 IPA", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("downloads.import")
            Button(action: onLink) {
                Label("通过链接下载", systemImage: "link")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            if proMode {
            Button(action: onPackages) {
                Label("管理与解密 IPA", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("downloads.decrypt-import")
            }
            if hasActiveJobs {
                Divider()
                Button("暂停全部", systemImage: "pause.circle", action: onPauseAll)
                    .disabled(!canPause)
                    .frame(minHeight: 44)
                Button("继续全部", systemImage: "play.circle", action: onResumeAll)
                    .disabled(!canResume)
                    .frame(minHeight: 44)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(hasActiveJobs ? 380 : 260), .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $picker) { kind in
            PackageDocumentPicker { result in
                picker = nil
                switch result {
                case .success(let urls):
                    onImport(urls)
                case .failure(let error):
                    onError(error.localizedDescription)
                }
            }
            .ignoresSafeArea()
        }
    }
}
