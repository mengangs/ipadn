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
    private enum SelectionItem: Hashable {
        case job(UUID)
        #if canImport(TestFlightKit)
        case tf(String)
        #endif
    }

    @State private var pendingDeleteJobs: Set<UUID> = []
    #if canImport(TestFlightKit)
    @State private var pendingDeleteTF: [TFProductItem] = []
    #endif
    @State private var swipingDelete: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var installing: DownloadJob?
    /// The LiveContainer setup tip, once read, stays closed.
    @AppStorage("liveContainerTipDismissed") private var liveContainerTipDismissed = false
    @State private var inspecting: DownloadJob?
    private struct PackageInspectTarget: Identifiable {
        let id = UUID()
        let file: URL
        let job: DownloadJob?
    }
    @State private var inspectingPackage: PackageInspectTarget?
    @State private var editing = false
    @State private var selection = Set<SelectionItem>()
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
    #if canImport(TestFlightKit)
    @ObservedObject private var tfProducts = TFProductIndex.shared
    @ObservedObject private var tfModel = TFHomeModel.shared
    @State private var installingTFItem: TFProductItem?
    private var filteredActiveTFItems: [TFActiveDownloadItem] {
        tfModel.activeDownloads.filter { item in
            let state = tfModel.rows[item.id] ?? TFRowState()
            let isBusy = state.isBusy
            let isPaused = state.stage == .paused
            let isFailed = state.stage == .failed
            guard filter.includesActiveTestFlight(isBusy: isBusy, isPaused: isPaused, isFailed: isFailed) else { return false }
            return term.isEmpty
                || item.displayName.localizedCaseInsensitiveContains(term)
                || item.bundleID.localizedCaseInsensitiveContains(term)
                || item.versionLabel.localizedCaseInsensitiveContains(term)
                || "TestFlight".localizedCaseInsensitiveContains(term)
                || "TF".localizedCaseInsensitiveContains(term)
        }
    }
    private var filteredTFItems: [TFProductItem] {
        guard filter.includesTestFlight else { return [] }
        let activeIDs = Set(tfModel.activeDownloads.filter {
            let stage = tfModel.rows[$0.id]?.stage ?? .idle
            return stage == .resolving || stage == .installing || stage == .downloading || stage == .paused || stage == .verifying
        }.map(\.id))
        return tfProducts.items.filter { item in
            guard !activeIDs.contains(item.appID) else { return false }
            return term.isEmpty
                || item.displayName.localizedCaseInsensitiveContains(term)
                || item.bundleID.localizedCaseInsensitiveContains(term)
                || item.shortVersion.localizedCaseInsensitiveContains(term)
                || item.buildVersion.localizedCaseInsensitiveContains(term)
                || "TestFlight".localizedCaseInsensitiveContains(term)
                || "TF".localizedCaseInsensitiveContains(term)
        }
    }
    private var hasAnyDownloads: Bool { !manager.jobs.isEmpty || !tfProducts.items.isEmpty || !tfModel.activeDownloads.isEmpty }
    private var pendingDeleteCount: Int { pendingDeleteJobs.count + pendingDeleteTF.count }
    #else
    private var hasAnyDownloads: Bool { !manager.jobs.isEmpty }
    private var pendingDeleteCount: Int { pendingDeleteJobs.count }
    #endif
    private var filteredJobs: [DownloadJob] {
        manager.jobs.filter { !swipingDelete.contains($0.id) && filter.includes($0.status) && (term.isEmpty || $0.app.name.localizedCaseInsensitiveContains(term) || $0.app.bundleID.localizedCaseInsensitiveContains(term) || $0.app.version.localizedCaseInsensitiveContains(term)) }
    }
    private var selectableItems: [SelectionItem] {
        var items: [SelectionItem] = filteredJobs.compactMap { job in
            let blocked = packages.protects(job.id) || job.status == .processing || job.status == .pausing
            return blocked ? nil : .job(job.id)
        }
        #if canImport(TestFlightKit)
        items.append(contentsOf: filteredTFItems.compactMap { item in
            packages.protects(url: item.fileURL) ? nil : .tf(item.bundleID)
        })
        #endif
        return items
    }
    private var selectionPruneKey: [String] {
        var keys = filteredJobs.map { "\($0.id.uuidString):\($0.status.rawValue)" }
        #if canImport(TestFlightKit)
        keys.append(contentsOf: filteredTFItems.map { "tf:\($0.bundleID)" })
        #endif
        return keys
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
        downloadList(visible: visible, updates: updates)
        .task(id: manager.jobs.filter { $0.status == .completed }.map { $0.id.uuidString }.joined()) {
            await manager.loadPackageIcons()
            #if canImport(TestFlightKit)
            tfProducts.refresh()
            #endif
            if store.settings.updateNotifications { await store.checkForUpdates() }
            // Automatic starts are coordinated by RootView, including while
            // this tab is not visible. Existing products are never replaced.
        }
        .onAppear {
            #if canImport(TestFlightKit)
            tfProducts.refresh()
            #endif
        }
        .refreshable {
            #if canImport(TestFlightKit)
            tfProducts.refresh()
            #endif
            await store.checkForUpdates(force: true)
        }
        .animation(UX.motion(reduceMotion), value: manager.jobs.map(\.id))
        .toolPage().navigationTitle("下载").navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .compatibleTopBarLeading) {
                Button(editing ? "完成" : "编辑") {
                    withAnimation(UX.motion(reduceMotion)) {
                        editing.toggle()
                        if !editing { selection.removeAll() }
                    }
                    UX.feedback()
                }
                .disabled(!hasAnyDownloads)
                .accessibilityIdentifier("downloads.edit")
                if hasAnyDownloads {
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
                    .disabled(actionBusy || editing).accessibilityLabel("添加下载").accessibilityIdentifier("downloads.add")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editing {
                HStack(spacing: 16) {
                    let items = Set(selectableItems)
                    let all = !items.isEmpty && items.isSubset(of: selection)
                    Button(all ? "取消全选" : "全选") {
                        if all { selection.subtract(items) } else { selection.formUnion(items) }
                        UX.feedback()
                    }
                    .disabled(items.isEmpty)
                    .accessibilityIdentifier("downloads.select-all")
                    Text("已选 \(selection.count) 项")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("删除所选", systemImage: "trash", role: .destructive) { askDelete(selection) }
                        .fontWeight(.semibold)
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("downloads.delete-selected")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.regularMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .compatibleOnChange(of: filter) { _ in
            guard !selection.isEmpty else { return }
            selection.formIntersection(Set(selectableItems))
        }
        .compatibleOnChange(of: term) { _ in
            guard !selection.isEmpty else { return }
            selection.formIntersection(Set(selectableItems))
        }
        .compatibleOnChange(of: selectionPruneKey) { _ in
            if !selection.isEmpty {
                selection.formIntersection(Set(selectableItems))
            }
            if editing && !hasAnyDownloads {
                editing = false
            }
        }
        .sheet(isPresented: $showingActions, onDismiss: flushPackageNavigation) {
            #if canImport(TestFlightKit)
            let tfCanPause = tfModel.activeDownloads.contains {
                let stage = tfModel.rows[$0.id]?.stage ?? .idle
                return stage == .resolving || stage == .installing || stage == .downloading
            }
            let tfCanResume = tfModel.activeDownloads.contains { tfModel.rows[$0.id]?.stage == .paused }
            #else
            let tfCanPause = false
            let tfCanResume = false
            #endif
            AddDownloadSheet(
                hasActiveJobs: manager.jobs.contains { [.running, .queued, .paused].contains($0.status) } || tfCanPause || tfCanResume,
                canPause: manager.jobs.contains { [.running, .queued].contains($0.status) } || tfCanPause,
                canResume: manager.jobs.contains { $0.status == .paused } || tfCanResume,
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
                    #if canImport(TestFlightKit)
                    tfModel.pauseAllDownloads()
                    #endif
                    store.infoMessage = AppText.text("已暂停下载")
                },
                onResumeAll: {
                    showingActions = false
                    manager.resumeAll()
                    #if canImport(TestFlightKit)
                    tfModel.resumeAllDownloads()
                    #endif
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
                                        PackageBuildInfoRows(file: file)
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
        .actionConfirmation(isPresented: $confirmingDelete, title: "删除 \(pendingDeleteCount) 项任务？", message: "已下载的安装包也会一并删除。", confirmTitle: "删除任务与文件") {
            let jobIDs = pendingDeleteJobs.filter { !packages.protects($0) }
            pendingDeleteJobs.removeAll()
            #if canImport(TestFlightKit)
            let tfItems = pendingDeleteTF.filter { !packages.protects(url: $0.fileURL) }
            pendingDeleteTF.removeAll()
            #endif
            withAnimation(UX.motion(reduceMotion)) {
                selection.removeAll()
                editing = false
            }
            perform {
                #if canImport(TestFlightKit)
                try await store.removeDownloadsBatchImmediately(jobIDs: jobIDs, tfItems: tfItems)
                #else
                try await store.removeDownloadsBatchImmediately(jobIDs: jobIDs)
                #endif
            }
        }
        .sheet(item: $inspectingPackage) { target in
            NavigationStack {
                PackageInfoView(file: target.file, job: target.job)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { inspectingPackage = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $installing) { job in
            PackageInstallationView(job: job).sheetNotice().environmentObject(store).environmentObject(manager)
        }
        #if canImport(TestFlightKit)
        .sheet(item: $installingTFItem) { item in
            PackageInstallationView(
                job: item.makeInstallJob(),
                packageFileURL: item.fileURL,
                packageIconURL: item.iconURL,
                isTestFlight: true
            )
            .sheetNotice()
            .environmentObject(store)
            .environmentObject(manager)
        }
        #endif
        .overlay { if actionBusy { HStack { ProgressView(); Text("正在处理…").font(.subheadline) }.padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).allowsHitTesting(false) } }
    }
    /// Row-header count: the active filter, then how many have updates.
    private func headerSummary(totalCount: Int, updates: [UUID: StoreApp]) -> String {
        var text = filter == .all ? AppText.text("\(totalCount) 个项目") : AppText.text("\(filter.title) · \(totalCount)")
        if !updates.isEmpty { text += AppText.text(" · \(updates.count) 个可更新") }
        return text
    }

    private enum UnifiedDownloadEntry: Identifiable {
        case job(DownloadJob)
        #if canImport(TestFlightKit)
        case activeTF(TFActiveDownloadItem)
        case tfProduct(TFProductItem)
        #endif

        var id: String {
            switch self {
            case .job(let job): return "job:" + job.id.uuidString
            #if canImport(TestFlightKit)
            case .activeTF(let item): return "tf-active:" + item.id
            case .tfProduct(let item): return "tf:" + item.bundleID
            #endif
            }
        }

        var sortDate: Date {
            switch self {
            case .job(let job): return job.createdAt
            #if canImport(TestFlightKit)
            case .activeTF(let item): return item.startedAt
            case .tfProduct(let item): return item.modifiedAt
            #endif
            }
        }

        var isActiveTransfer: Bool {
            switch self {
            case .job(let job): return job.status != .completed && job.status != .failed
            #if canImport(TestFlightKit)
            case .activeTF: return true
            case .tfProduct: return false
            #endif
            }
        }
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
            editing: editing,
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
    @ViewBuilder private func selectableRow<Content: View, Active: View>(
        _ item: SelectionItem,
        disabled: Bool,
        identifier: String,
        accessibilityName: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder active: () -> Active
    ) -> some View {
        if editing {
            let selected = selection.contains(item)
            Button {
                if !selection.insert(item).inserted { selection.remove(item) }
                UX.feedback()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .compatibleSymbolReplacement()
                    content()
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(selected ? AppText.text("取消选择 \(accessibilityName)") : AppText.text("选择 \(accessibilityName)"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(identifier)
        } else {
            active()
        }
    }

    @ViewBuilder private func downloadList(visible: [DownloadJob], updates: [UUID: StoreApp]) -> some View {
            #if canImport(TestFlightKit)
            let visibleActiveTF = filteredActiveTFItems
            let visibleTF = filteredTFItems
            #endif
            let entries: [UnifiedDownloadEntry] = {
                var activeItems: [UnifiedDownloadEntry] = []
                var settledItems: [UnifiedDownloadEntry] = []
                for job in visible {
                    let entry = UnifiedDownloadEntry.job(job)
                    if entry.isActiveTransfer { activeItems.append(entry) }
                    else { settledItems.append(entry) }
                }
                #if canImport(TestFlightKit)
                for item in visibleActiveTF {
                    activeItems.append(.activeTF(item))
                }
                for item in visibleTF {
                    settledItems.append(.tfProduct(item))
                }
                #endif
                activeItems.sort { $0.sortDate > $1.sortDate }
                settledItems.sort { $0.sortDate > $1.sortDate }
                return activeItems + settledItems
            }()
            List {
                if hasAnyDownloads {
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
                if entries.isEmpty {
                    Section {
                        EmptyState(title: !hasAnyDownloads ? "暂无下载任务" : "没有匹配任务", message: !hasAnyDownloads ? "在搜索中获取应用，或点按右上角的 + 导入安装包。" : "试试其他筛选条件。", symbol: !hasAnyDownloads ? "tray.and.arrow.down" : "line.3.horizontal.decrease.circle", actionTitle: !hasAnyDownloads ? "搜索应用" : "显示全部", action: {
                            if !hasAnyDownloads { store.selectTab(.search) } else { term = ""; filter = .all }
                        })
                    }
                } else {
                    ForEach(entries) { entry in
                        Section {
                            switch entry {
                            case .job(let job):
                                let displayName = job.app.name.isEmpty ? job.app.bundleID : job.app.name
                                let blocked = packages.protects(job.id) || job.status == .processing || job.status == .pausing
                                selectableRow(
                                    .job(job.id),
                                    disabled: blocked,
                                    identifier: "download.select." + job.id.uuidString,
                                    accessibilityName: displayName,
                                    content: { taskContent(job, update: updates[job.id], editing: true) }
                                ) {
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
                                        if job.status == .completed, job.rawFormat == nil, let file = manager.fileURL(job) {
                                            Button("安装包信息", systemImage: "doc.text.magnifyingglass") {
                                                inspectingPackage = PackageInspectTarget(file: file, job: job)
                                            }
                                        }
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
                                            Button("删除任务及文件", systemImage: "trash", role: .destructive) { askDelete([.job(job.id)]) }
                                        }
                                    }
                                }
                            #if canImport(TestFlightKit)
                            case .activeTF(let item):
                                tfActiveDownloadRow(item)
                            case .tfProduct(let item):
                                tfProductRow(item)
                            #endif
                            }
                        } header: {
                            if entry.id == entries.first?.id {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(headerSummary(totalCount: entries.count, updates: updates))
                                    Spacer()
                                    // One update has its own button on the row.
                                    if !editing && updates.count > 1 {
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

    #if canImport(TestFlightKit)
    private func tfActiveDownloadRow(_ item: TFActiveDownloadItem) -> some View {
        let state = tfModel.rows[item.id] ?? TFRowState()
        let isFailed = state.stage == .failed
        let isPaused = state.stage == .paused
        let isDownloading = state.stage == .downloading
        let sizeText = state.total > 0 ? state.total.byteLabel : ""
        let metaText = [item.versionLabel, sizeText].filter { !$0.isEmpty }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                TFAppIconView(
                    fileURL: item.iconURL,
                    colors: item.iconColors,
                    appName: item.displayName,
                    size: 64,
                    revision: tfModel.iconRevisions[item.id] ?? 0
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        TestFlightIcon()
                            .frame(minWidth: 16)
                        if !metaText.isEmpty {
                            Text(verbatim: metaText)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    tfActiveStatusLine(item: item, state: state)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !editing {
                    tfActiveTrailingControl(item: item, state: state)
                        .frame(minWidth: 74, minHeight: 44, alignment: .center)
                }
            }
            if (isDownloading || isPaused), state.total > 0 {
                ProgressView(value: state.fraction)
                    .tint(isDownloading ? UX.tint : .secondary)
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: state.fraction)
                    .accessibilityLabel("下载进度")
                    .accessibilityValue("\(Int(state.fraction * 100))%")
            }
            if isFailed, let error = state.message, !error.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(verbatim: error).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download.tf.active." + item.id)
        .revealActions(
            id: "download.tf.active." + item.id,
            enabled: !editing && state.stage != .verifying,
            [
                .delete(isFailed ? "移除" : "删除", fills: true) {
                    UX.tapLight()
                    if isFailed { tfModel.dismissFailedDownload(item.id) }
                    else { tfModel.cancel(item.app) }
                }
            ]
        )
        .contextMenu {
            if isFailed {
                Button("重试", systemImage: "arrow.clockwise") {
                    UX.tapLight()
                    tfModel.start(item.app)
                }
                Button("移除", systemImage: "trash", role: .destructive) {
                    UX.tapLight()
                    tfModel.dismissFailedDownload(item.id)
                }
            } else if isPaused {
                Button("继续", systemImage: "play.fill") {
                    UX.tapLight()
                    tfModel.resume(item.app)
                }
                Button("取消", systemImage: "xmark.circle", role: .destructive) {
                    UX.tapLight()
                    tfModel.cancel(item.app)
                }
            } else if state.stage != .verifying {
                Button("暂停", systemImage: "pause.fill") {
                    UX.tapLight()
                    tfModel.pause(item.app)
                }
                Button("取消", systemImage: "xmark.circle", role: .destructive) {
                    UX.tapLight()
                    tfModel.cancel(item.app)
                }
            }
        }
    }

    @ViewBuilder
    private func tfActiveStatusLine(item: TFActiveDownloadItem, state: TFRowState) -> some View {
        switch state.stage {
        case .resolving:
            Text("读取构建信息…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .installing:
            Text("准备下载…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .downloading:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let metric = tfModel.metrics(for: item.id)
                let now = ProcessInfo.processInfo.systemUptime
                let speed = metric?.rate(at: now) ?? 0
                let progress = state.total > 0
                    ? "\(state.received.byteLabel) / \(state.total.byteLabel)"
                    : (state.received > 0 ? state.received.byteLabel : "")
                let speedText = speed > 0 ? "\(Int64(min(speed, Double(Int64.max / 2))).byteLabel)/s" : ""
                let eta: String = {
                    guard let seconds = metric?.remaining(expected: state.total, at: now), seconds.isFinite else { return "" }
                    return seconds < 60 ? AppText.text("剩余 \(max(1, Int(seconds))) 秒")
                        : seconds < 3600 ? AppText.text("剩余 \(Int(ceil(seconds / 60))) 分钟")
                        : AppText.text("剩余 \(Int(ceil(min(seconds / 3600, 999)))) 小时")
                }()
                Text([progress, speedText, eta].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .paused:
            let progress = state.total > 0
                ? "\(state.received.byteLabel) / \(state.total.byteLabel)"
                : (state.received > 0 ? state.received.byteLabel : "")
            Text([AppText.text("已暂停"), progress].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .verifying:
            Text("校验安装包…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failed:
            TaskStatusPill(status: .failed)
        case .idle, .done:
            EmptyView()
        }
    }

    @ViewBuilder
    private func tfActiveTrailingControl(item: TFActiveDownloadItem, state: TFRowState) -> some View {
        switch state.stage {
        case .resolving, .installing:
            Button {
                UX.tapLight()
                tfModel.pause(item.app)
            } label: {
                ProgressRing(progress: nil)
            }
            .buttonStyle(RevealRowButtonStyle())
            .accessibilityLabel("等待下载，点按暂停")
        case .downloading:
            Button {
                UX.tapLight()
                tfModel.pause(item.app)
            } label: {
                ProgressRing(progress: state.total > 0 ? state.fraction : nil, symbol: "pause.fill")
            }
            .buttonStyle(RevealRowButtonStyle())
            .accessibilityLabel("暂停")
            .accessibilityValue("\(Int(state.fraction * 100))%")
        case .paused:
            RowCapsule(title: "继续", haptic: false) {
                UX.tapLight()
                tfModel.resume(item.app)
            }
        case .verifying:
            SpinningRing()
                .accessibilityLabel(AppText.text("正在校验 \(item.displayName)"))
        case .failed:
            RowCapsule(title: "重试", haptic: false) {
                UX.tapLight()
                tfModel.start(item.app)
            }
        case .idle, .done:
            EmptyView()
        }
    }

    private func tfRowContent(_ item: TFProductItem, editing: Bool) -> some View {
        let isInstalling = tfModel.installingAppIDs.contains(item.appID)
        let record = packages.attempts(url: item.fileURL).first
        let hasDecrypted = store.settings.proMode
            && record.map { DecryptOutcomeStyle($0) == .success && packages.currentOutput($0) != nil } == true
        let sizeText = item.fileSize > 0 ? item.fileSize.byteLabel : ""
        let metaText = [item.compactVersionLabel, sizeText].filter { !$0.isEmpty }.joined(separator: " · ")

        return HStack(spacing: 14) {
            TFAppIconView(
                fileURL: item.iconURL,
                colors: item.iconColors,
                appName: item.displayName,
                size: 64,
                revision: tfModel.iconRevisions[item.appID] ?? 0
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    TestFlightIcon()
                        .frame(minWidth: 16)
                    if !metaText.isEmpty {
                        Text(verbatim: metaText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    TaskStatusPill(status: .completed)
                    if hasDecrypted {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.open.fill").imageScale(.small).accessibilityHidden(true)
                            Text("已解密")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !editing {
                Button(isInstalling ? "正在处理…" : "安装") {
                    UX.tapLight()
                    installingTFItem = item
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
                .disabled(isInstalling)
                .accessibilityIdentifier("download.tf.install." + item.bundleID)
            }
        }
        .padding(.vertical, 8)
    }

    private func tfProductRow(_ item: TFProductItem) -> some View {
        let record = packages.attempts(url: item.fileURL).first
        return selectableRow(
            .tf(item.bundleID),
            disabled: packages.protects(url: item.fileURL),
            identifier: "download.select.tf." + item.bundleID,
            accessibilityName: item.displayName,
            content: { tfRowContent(item, editing: true) }
        ) {
            tfRowContent(item, editing: false)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("download.tf." + item.bundleID)
                .revealActions(
                    id: "download.tf." + item.bundleID,
                    enabled: !actionBusy && !packages.protects(url: item.fileURL),
                    restored: tfProducts.recentlyRestoredBundleIDs.contains(item.bundleID),
                    [
                        .delete(fills: true) { removeTFWithUndo(item) },
                        RevealAction(title: "分享", systemImage: "square.and.arrow.up", tint: .blue, role: nil) {
                            share = SharedFile(url: item.fileURL)
                        }
                    ]
                )
                .contextMenu {
                    Button("安装", systemImage: "square.and.arrow.down") {
                        installingTFItem = item
                    }
                    Button("安装包信息", systemImage: "info.circle") {
                        inspectingPackage = PackageInspectTarget(file: item.fileURL, job: nil)
                    }
                    if store.settings.proMode {
                        if let record {
                            let style = DecryptOutcomeStyle(record)
                            if style == .running {
                                Button("查看解密进度", systemImage: "circle.dotted") { openPackage(.record(record.id)) }
                            } else if style == .success && packages.currentOutput(record) != nil {
                                Button("查看解密结果", systemImage: "lock.open") { openPackage(.record(record.id)) }
                            } else {
                                Button("解密 IPA", systemImage: "lock.open") {
                                    openPackage(.file(item.fileURL))
                                    packages.requestStart(url: item.fileURL)
                                }
                            }
                        } else {
                            Button("解密 IPA", systemImage: "lock.open") {
                                openPackage(.file(item.fileURL))
                                packages.requestStart(url: item.fileURL)
                            }
                        }
                        Button("查看原始 IPA", systemImage: "shippingbox") {
                            openPackage(.file(item.fileURL))
                        }
                    }
                    Button("导出文件", systemImage: "square.and.arrow.up") {
                        share = SharedFile(url: item.fileURL)
                    }
                    Button("删除任务及文件", systemImage: "trash", role: .destructive) {
                        askDelete([.tf(item.bundleID)])
                    }
                    .disabled(packages.protects(url: item.fileURL))
                }
        }
    }

    private func removeTFWithUndo(_ item: TFProductItem) {
        guard !packages.protects(url: item.fileURL) else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        do {
            try store.removeTFProductWithUndo(item)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
    #endif

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
    private func askDelete(_ items: Set<SelectionItem>) {
        var requestedJobIDs = Set<UUID>()
        #if canImport(TestFlightKit)
        var requestedTFBundles = Set<String>()
        #endif
        for item in items {
            switch item {
            case .job(let id): requestedJobIDs.insert(id)
            #if canImport(TestFlightKit)
            case .tf(let bundleID): requestedTFBundles.insert(bundleID)
            #endif
            }
        }
        pendingDeleteJobs = Set(
            manager.jobs.filter {
                requestedJobIDs.contains($0.id)
                    && !packages.protects($0.id)
                    && $0.status != .processing
                    && $0.status != .pausing
            }.map(\.id)
        )
        #if canImport(TestFlightKit)
        pendingDeleteTF = tfProducts.items.filter {
            requestedTFBundles.contains($0.bundleID) && !packages.protects(url: $0.fileURL)
        }
        #endif
        if pendingDeleteCount == 0 { store.infoMessage = AppText.text("任务处理完成后才能删除") }
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
    var editing = false
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
        !editing && (job.status != .completed || job.rawFormat == nil)
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
            let pct = total > 0 ? Int((Double(current.downloaded) / Double(total) * 100).rounded(.down)) : 0
            LabeledContent("已下载", value: total > 0 && current.downloaded > 0
                           ? AppText.text("\(current.downloaded.byteLabel)（\(pct)%）")
                           : current.downloaded.byteLabel)
                .accessibilityIdentifier("download.detail.downloaded")
            if total > 0 { LabeledContent("大小", value: total.byteLabel) }
        }
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
        ScrollView {
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
        }
        .compatibleScrollBounce()
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
