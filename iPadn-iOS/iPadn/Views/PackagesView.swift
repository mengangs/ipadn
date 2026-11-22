import SwiftUI

struct PackagesView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var ui = FairPlayPresentation.shared
    @ObservedObject private var service = FairPlayHub.shared.service
    @ObservedObject private var records = DecryptRecordStore.shared
    @ObservedObject private var packageRemovals = PackageFileRemovalStore.shared

    @State private var products = false
    @State private var picking = false
    @State private var importing = false
    @State private var term = ""
    @State private var sort = 0
    @State private var standalone: [URL] = []
    @State private var orphanedOutputs: [URL] = []
    @State private var importedIDs: Set<UUID> = []
    @State private var pendingImport: [URL] = []
    @State private var importIssue: String?
    @State private var presentation: PackageFilePresentation?
    @State private var pendingDelete: PendingDelete?
    @State private var swipingDeleteJobs = Set<UUID>()
    @State private var editing = false
    @State private var selection = Set<SelectionItem>()
    @State private var confirmingBatchDelete = false
    #if canImport(TestFlightKit)
    @ObservedObject private var tfProducts = TFProductIndex.shared
    @ObservedObject private var tfModel = TFHomeModel.shared
    @State private var installingTFItem: TFProductItem?
    #endif

    private enum SelectionItem: Hashable {
        case job(UUID)
        case standalone(URL)
        case output(UUID)
        case orphan(URL)
        #if canImport(TestFlightKit)
        case tf(String)
        #endif
    }

    private enum PendingDelete: Identifiable {
        case originalJob(DownloadJob)
        case standaloneFile(URL)
        case outputRecord(DecryptRecord, URL)
        case unlinkedFile(URL)
        #if canImport(TestFlightKit)
        case tfProduct(TFProductItem)
        #endif

        var id: String {
            switch self {
            case .originalJob(let job): return "job-\(job.id.uuidString)"
            case .standaloneFile(let url): return "file-\(url.path)"
            case .outputRecord(let record, _): return "rec-\(record.id.uuidString)"
            case .unlinkedFile(let url): return "orphan-\(url.path)"
            #if canImport(TestFlightKit)
            case .tfProduct(let item): return "tf-\(item.bundleID)"
            #endif
            }
        }
    }

    private var importFailures: [DownloadJob] {
        manager.jobs.filter { job in importedIDs.contains(job.id) && job.status == .failed }
    }

    private var allOriginals: [DownloadJob] {
        manager.jobs.filter { $0.rawFormat == nil && $0.status == .completed && manager.fileURL($0) != nil }
    }

    private var originals: [DownloadJob] {
        allOriginals.filter {
            matches([$0.app.name, $0.app.version, $0.app.bundleID, $0.localFilename ?? ""])
        }.sorted {
            sort == 1 ? $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending
                : sort == 2 ? $0.app.size > $1.app.size
                : $0.createdAt > $1.createdAt
        }
    }

    private var filteredStandalone: [URL] {
        standalone.filter { url in
            let meta = ui.localMetadata[url]
            return matches([meta?.name ?? "", meta?.version ?? "", meta?.bundleID ?? "", url.lastPathComponent])
        }.sorted { lhs, rhs in
            let lMeta = ui.localMetadata[lhs], rMeta = ui.localMetadata[rhs]
            let lName = PackageStage.displayName(lMeta?.name ?? lhs.deletingPathExtension().lastPathComponent)
            let rName = PackageStage.displayName(rMeta?.name ?? rhs.deletingPathExtension().lastPathComponent)
            if sort == 1 { return lName.localizedStandardCompare(rName) == .orderedAscending }
            if sort == 2 { return (lMeta?.bytes ?? 0) > (rMeta?.bytes ?? 0) }
            return lName.localizedStandardCompare(rName) == .orderedAscending
        }
    }

    private var allOutputs: [DecryptRecord] {
        records.records.filter { ui.currentOutput($0) != nil && $0.state != .plain }
    }

    private var outputs: [DecryptRecord] {
        allOutputs.filter { record in
            #if canImport(TestFlightKit)
            let source = ui.source(for: record, manager: manager)
            let tfItem = source.flatMap { tfProducts.item(forFile: $0) }
            let isTF = record.isTestFlight == true || tfItem != nil || source?.path.contains("/TestFlight/") == true
            var fields = [record.appName, tfItem?.displayName ?? "", record.version ?? "", record.bundleID ?? "", record.outputName ?? ""]
            if isTF { fields.append(contentsOf: ["TestFlight", "TF"]) }
            return matches(fields)
            #else
            var fields = [record.appName, record.version ?? "", record.bundleID ?? "", record.outputName ?? ""]
            if record.isTestFlight == true { fields.append(contentsOf: ["TestFlight", "TF"]) }
            return matches(fields)
            #endif
        }.sorted {
            sort == 1 ? $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
                : sort == 2 ? ($0.outputBytes ?? 0) > ($1.outputBytes ?? 0)
                : $0.startedAt > $1.startedAt
        }
    }

    private var filteredOrphans: [URL] {
        orphanedOutputs.filter { matches([$0.lastPathComponent]) }
    }

    #if canImport(TestFlightKit)
    private var filteredTFItems: [TFProductItem] {
        tfProducts.items.filter { item in
            matches([item.displayName, item.shortVersion, item.buildVersion, item.bundleID, "TestFlight", "TF"])
        }.sorted { lhs, rhs in
            if sort == 1 { return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending }
            if sort == 2 { return lhs.fileSize > rhs.fileSize }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }
    private var tfCount: Int { tfProducts.items.count }
    #else
    private var tfCount: Int { 0 }
    #endif

    private var originalCount: Int { allOriginals.count + standalone.count + tfCount }
    private var outputCount: Int { allOutputs.count + orphanedOutputs.count }
    private var allEmpty: Bool { originalCount == 0 && outputCount == 0 && !service.isRunning && !importing && importedIDs.isEmpty }
    private var hasVisibleItems: Bool {
        if products { return !(outputs.isEmpty && filteredOrphans.isEmpty) }
        #if canImport(TestFlightKit)
        return !(originals.isEmpty && filteredStandalone.isEmpty && filteredTFItems.isEmpty)
        #else
        return !(originals.isEmpty && filteredStandalone.isEmpty)
        #endif
    }
    private var selectableItems: [SelectionItem] {
        if products {
            return outputs.compactMap { !service.isRunning ? .output($0.id) : nil }
                + filteredOrphans.compactMap { !service.isRunning ? .orphan($0) : nil }
        }
        var items: [SelectionItem] = originals.compactMap { !ui.protects($0.id) ? .job($0.id) : nil }
            + filteredStandalone.compactMap { !ui.protects(url: $0) ? .standalone($0) : nil }
        #if canImport(TestFlightKit)
        items.append(contentsOf: filteredTFItems.compactMap { !ui.protects(url: $0.fileURL) ? .tf($0.bundleID) : nil })
        #endif
        return items
    }

    var body: some View {
        library
            .toolPage()
            .navigationTitle("应用包")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { libraryToolbar }
            .packageFilePresenter($presentation)
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
                .environmentObject(store.downloads)
            }
            #endif
            .sheet(isPresented: $picking, onDismiss: {
                let urls = pendingImport
                pendingImport = []
                if !urls.isEmpty { importFiles(urls) }
            }) {
                PackageDocumentPicker { result in
                    switch result {
                    case .success(let urls): pendingImport = urls
                    case .failure(let error): importIssue = error.localizedDescription
                    }
                    picking = false
                }.ignoresSafeArea()
            }
            .actionConfirmation(
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                title: deleteTitle,
                message: deleteMessage,
                confirmTitle: deleteConfirmTitle
            ) {
                if let item = pendingDelete { executeDelete(item) }
                pendingDelete = nil
            }
            .actionConfirmation(
                isPresented: $confirmingBatchDelete,
                title: "删除 \(selection.count) 个应用包？",
                message: products
                    ? "只删除所选产物和未关联文件，原始 IPA 和处理记录保留。"
                    : "将删除所选原始 IPA 及对应下载任务，解密产物和处理记录保留。",
                confirmTitle: "删除所选"
            ) {
                executeBatchDelete()
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

                        Text("已选 \(selection.count) 项")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("删除所选", systemImage: "trash", role: .destructive) {
                            confirmingBatchDelete = true
                        }
                        .fontWeight(.semibold)
                        .disabled(selection.isEmpty)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.regularMaterial)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .compatibleOnChange(of: products) { _ in selection.removeAll() }
            .compatibleOnChange(of: term) { _ in
                guard !selection.isEmpty else { return }
                selection.formIntersection(Set(selectableItems))
            }
            .compatibleOnChange(of: sort) { _ in UX.feedback() }
            .task { await refreshFiles() }
            .task(id: completionKey) { await refreshFiles(); finishImports() }
            .task(id: ui.fileRevision) { await refreshFiles() }
            .compatibleOnChange(of: service.phase) { _ in Task { await refreshFiles() } }
            .compatibleOnChange(of: outputRevision) { _ in Task { await refreshFiles() } }
            .compatibleOnChange(of: scenePhase) { phase in if phase == .active { Task { await refreshFiles() } } }
            .refreshable { await refreshFiles() }
    }

    private var completionKey: [String] { manager.jobs.map { "\($0.id):\($0.status.rawValue)" } }
    private var outputRevision: [String] {
        records.records.map { "\($0.id):\($0.state.rawValue):\($0.outputName ?? ""):\($0.outputIdentity ?? "")" }
    }

    private var library: some View {
        List {
            DecryptLiveSummary()
            if importing || !importedIDs.isEmpty { importProgress }
            if let importIssue {
                Section {
                    InlineIssue(message: importIssue)
                }
            }
            if allEmpty && term.isEmpty {
                Section {
                    VStack(spacing: 4) {
                        EmptyState(
                            title: "添加你的第一个 IPA",
                            message: "导入安装包，或在下载完成后到这里处理和管理。",
                            symbol: "shippingbox",
                            actionTitle: "导入 IPA"
                        ) { picking = true }
                        Button("前往下载") { store.selectTab(.downloads) }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    SearchInput(text: $term, placeholder: "搜索名称、版本或 Bundle ID", capsule: true)
                    categoryPicker
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                if products { productSections } else { originalSections }
            }
        }
    }

    @ViewBuilder private var categoryPicker: some View {
        let originalLabel = AppText.text("原始 IPA（\(originalCount)）")
        let outputLabel = AppText.text("已解密（\(outputCount)）")
        if typeSize.isAccessibilitySize {
            Picker("应用包分类", selection: $products) {
                Text(verbatim: originalLabel).tag(false)
                Text(verbatim: outputLabel).tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("应用包分类")
        } else {
            Picker("应用包分类", selection: $products) {
                Text(verbatim: originalLabel).tag(false)
                Text(verbatim: outputLabel).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
        }
    }

    private var importProgress: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在添加安装包…")
            }
            ForEach(importFailures) { job in
                Text(verbatim: job.error ?? AppText.text("安装包未能添加"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .compatibleTopBarTrailing) {
            if editing {
                Button("完成") {
                    withAnimation(UX.motion(reduceMotion)) {
                        editing = false
                        selection.removeAll()
                    }
                }
            } else {
                Button("导入", systemImage: "plus") { picking = true }
                    .disabled(importing)
                    .accessibilityIdentifier("packages.choose")
                moreMenu
            }
        }
    }

    private var sortSubtitle: String {
        switch sort {
        case 1: return AppText.text("名称")
        case 2: return AppText.text("大小")
        default: return AppText.text("添加时间")
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    withAnimation(UX.motion(reduceMotion)) {
                        editing = true
                        selection.removeAll()
                    }
                    UX.feedback()
                } label: {
                    Label("选择", systemImage: "checkmark.circle")
                }
                .disabled(allEmpty || !hasVisibleItems)
            }

            Section {
                Button { ui.push(.history) } label: {
                    Label(
                        records.records.isEmpty
                            ? AppText.text("处理记录")
                            : AppText.text("处理记录（\(records.records.count)）"),
                        systemImage: "clock"
                    )
                }
                Button { ui.push(.options) } label: {
                    Label("处理选项", systemImage: "slider.horizontal.3")
                }
                Button { ui.push(.help) } label: {
                    Label("使用说明与兼容性", systemImage: "questionmark.circle")
                }
            }

            Section {
                Menu {
                    Picker("排序", selection: $sort) {
                        Text("添加时间").tag(0)
                        Text("名称").tag(1)
                        Text("大小").tag(2)
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                    Text(verbatim: sortSubtitle)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多操作")
    }

    private func finishImports() {
        let existingIDs = Set(manager.jobs.map(\.id))
        importedIDs.formIntersection(existingIDs)
        var finished = Set<UUID>()
        for job in manager.jobs {
            guard importedIDs.contains(job.id) else { continue }
            if job.status == .completed {
                if importedIDs.count == 1, store.tabs.id == .packages, ui.path.isEmpty {
                    ui.navigate(.source(job.id))
                }
                finished.insert(job.id)
            } else if job.status == .failed {
                importIssue = job.error ?? AppText.text("安装包未能添加")
                finished.insert(job.id)
            }
        }
        importedIDs.subtract(finished)
    }

    private enum UnifiedOriginalEntry: Identifiable {
        case job(DownloadJob)
        #if canImport(TestFlightKit)
        case tf(TFProductItem)
        #endif

        var id: String {
            switch self {
            case .job(let job): return "job:" + job.id.uuidString
            #if canImport(TestFlightKit)
            case .tf(let item): return "tf:" + item.bundleID
            #endif
            }
        }

        var sortName: String {
            switch self {
            case .job(let job): return job.app.name
            #if canImport(TestFlightKit)
            case .tf(let item): return item.displayName
            #endif
            }
        }

        var sortSize: Int64 {
            switch self {
            case .job(let job): return job.app.size
            #if canImport(TestFlightKit)
            case .tf(let item): return item.fileSize
            #endif
            }
        }

        var sortDate: Date {
            switch self {
            case .job(let job): return job.createdAt
            #if canImport(TestFlightKit)
            case .tf(let item): return item.modifiedAt
            #endif
            }
        }
    }

    @ViewBuilder private var originalSections: some View {
        let currentOriginals = originals
        let currentStandalone = filteredStandalone
        #if canImport(TestFlightKit)
        let tfItems = filteredTFItems
        #endif
        let unifiedOriginals: [UnifiedOriginalEntry] = {
            var entries: [UnifiedOriginalEntry] = currentOriginals.map { .job($0) }
            #if canImport(TestFlightKit)
            entries.append(contentsOf: tfItems.map { .tf($0) })
            #endif
            entries.sort { lhs, rhs in
                if sort == 1 { return lhs.sortName.localizedStandardCompare(rhs.sortName) == .orderedAscending }
                if sort == 2 { return lhs.sortSize > rhs.sortSize }
                return lhs.sortDate > rhs.sortDate
            }
            return entries
        }()
        if unifiedOriginals.isEmpty && currentStandalone.isEmpty {
            Section {
                if term.isEmpty {
                    EmptyState(
                        title: "还没有原始 IPA",
                        message: "点右上角导入安装包，或从下载页获取应用。",
                        symbol: "shippingbox",
                        actionTitle: "导入 IPA"
                    ) { picking = true }
                } else {
                    EmptyState(
                        title: "没有匹配的应用包",
                        message: "试试换个关键词，或清除搜索条件。",
                        symbol: "magnifyingglass",
                        actionTitle: "清除搜索"
                    ) { term = "" }
                }
            }.listRowBackground(Color.clear)
        } else {
            if !unifiedOriginals.isEmpty {
                Section {
                    ForEach(unifiedOriginals) { entry in
                        switch entry {
                        case .job(let job):
                            originalJobRow(job)
                        #if canImport(TestFlightKit)
                        case .tf(let item):
                            tfProductRow(item)
                        #endif
                        }
                    }
                } footer: {
                    if currentStandalone.isEmpty {
                        Text("原始 IPA 是处理来源，可能已加密，也可能本来就未加密。")
                    }
                }
            }
            if !currentStandalone.isEmpty {
                Section {
                    ForEach(currentStandalone, id: \.self) { url in
                        standaloneRow(url)
                    }
                } header: {
                    if !unifiedOriginals.isEmpty { Text("本地文件") }
                } footer: {
                    Text("原始 IPA 是处理来源，可能已加密，也可能本来就未加密。")
                }
            }
        }
    }

    #if canImport(TestFlightKit)
    private func tfProductRow(_ item: TFProductItem) -> some View {
        let result = ui.attempts(url: item.fileURL).first
        let hasOutput = result.flatMap { ui.currentOutput($0) } != nil
        let status = PackageStage.sourceSummary(
            checking: ui.detecting.contains(item.fileURL),
            detection: ui.detections[item.fileURL],
            latest: result,
            hasOutput: hasOutput
        )
        let sizeText = item.fileSize > 0 ? item.fileSize.byteLabel : ""
        let metadata = [item.versionBuildLabel, sizeText].filter { !$0.isEmpty }.joined(separator: " · ")
        let row = PackageLibraryRow(
            name: item.displayName,
            icon: item.iconURL,
            metadata: metadata,
            status: status.text,
            symbol: status.symbol,
            color: status.color,
            isTestFlight: true
        )

        return selectableRow(.tf(item.bundleID), disabled: ui.protects(url: item.fileURL), content: { row }) {
            packageNavRow(route: .file(item.fileURL)) { row }
                .accessibilityIdentifier("packages.tf." + item.bundleID)
                .revealActions(
                    id: "pkg.tf." + item.bundleID,
                    enabled: !ui.protects(url: item.fileURL),
                    restored: tfProducts.recentlyRestoredBundleIDs.contains(item.bundleID),
                    [
                        .delete(fills: true) {
                            guard !ui.protects(url: item.fileURL) else {
                                store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
                                return
                            }
                            do {
                                try store.removeTFProductWithUndo(item, fromPackages: true)
                            } catch {
                                store.errorMessage = error.localizedDescription
                            }
                        },
                        RevealAction(title: "分享", systemImage: "square.and.arrow.up", tint: .blue, role: nil) {
                            exportFile(item.fileURL, suggestedName: item.displayName + ".ipa", kind: .share)
                        }
                    ]
                )
                .contextMenu {
                    Button("安装", systemImage: "square.and.arrow.down") {
                        installingTFItem = item
                    }
                    if let output = result, DecryptOutcomeStyle(output) == .success, ui.currentOutput(output) != nil {
                        Button("查看解密结果", systemImage: "checkmark.circle") { ui.navigate(.record(output.id)) }
                        Button("重新解密", systemImage: "arrow.clockwise") { ui.requestStart(url: item.fileURL) }
                    } else if ui.detections[item.fileURL]?.state != .plain {
                        Button("解密 IPA", systemImage: "lock.open") { ui.requestStart(url: item.fileURL) }
                    }
                    Button("保存原始 IPA", systemImage: "folder") { exportFile(item.fileURL, suggestedName: item.displayName + ".ipa", kind: .save) }
                    Button("分享原始 IPA", systemImage: "square.and.arrow.up") { exportFile(item.fileURL, suggestedName: item.displayName + ".ipa", kind: .share) }
                    Button("重新检查", systemImage: "arrow.triangle.2.circlepath") { Task { await ui.detect(item.fileURL, force: true) } }
                    Button("删除原始 IPA", systemImage: "trash", role: .destructive) { requestDeleteTFProduct(item) }
                        .disabled(ui.protects(url: item.fileURL))
                }
        }
    }

    private func requestDeleteTFProduct(_ item: TFProductItem) {
        guard !ui.protects(url: item.fileURL) else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        pendingDelete = .tfProduct(item)
    }
    #endif

    private func packageNavRow<Content: View>(route: PackageRoute, @ViewBuilder content: () -> Content) -> some View {
        Button {
            ui.push(route)
        } label: {
            HStack(spacing: 10) {
                content()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RevealRowButtonStyle())
    }

    @ViewBuilder private func selectableRow<Content: View, Active: View>(
        _ item: SelectionItem,
        disabled: Bool,
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(disabled)
        } else {
            active()
        }
    }

    @ViewBuilder
    private func originalJobRow(_ job: DownloadJob) -> some View {
        if let url = manager.fileURL(job) {
            let result = ui.attempts(url: url, jobID: job.id).first
            let hasOutput = result.flatMap { ui.currentOutput($0) } != nil
            let status = PackageStage.sourceSummary(
                checking: ui.detecting.contains(url),
                detection: ui.detections[url],
                latest: result,
                hasOutput: hasOutput
            )
            let metadata = [job.conciseVersionLabel, job.app.size > 0 ? job.app.size.byteLabel : ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let rowName = PackageStage.displayName(job.app.name)
            let row = PackageLibraryRow(
                name: rowName,
                icon: manager.packageIconURL(job) ?? job.app.iconURL,
                metadata: metadata,
                status: status.text,
                symbol: status.symbol,
                color: status.color
            )
            selectableRow(.job(job.id), disabled: ui.protects(job.id), content: { row }) {
                packageNavRow(route: .source(job.id)) { row }
                    .revealActions(
                        id: "pkg.job." + job.id.uuidString,
                        enabled: !ui.protects(job.id) && !swipingDeleteJobs.contains(job.id),
                        restored: manager.recentlyRestoredIDs.contains(job.id),
                        [
                            .delete(fills: true) { swipeDeleteOriginalJob(job) },
                            RevealAction(title: "分享", systemImage: "square.and.arrow.up", tint: .blue, role: nil) {
                                exportFile(url, suggestedName: rowName + ".ipa", kind: .share)
                            }
                        ]
                    )
                    .contextMenu {
                        if let active = result, active.id == service.activeRecordID, service.isRunning {
                            Button("查看解密进度", systemImage: "circle.dotted") { ui.navigate(.record(active.id)) }
                        } else if let output = result, DecryptOutcomeStyle(output) == .success, ui.currentOutput(output) != nil {
                            Button("查看解密结果", systemImage: "checkmark.circle") { ui.navigate(.record(output.id)) }
                            Button("重新解密", systemImage: "arrow.clockwise") { ui.requestStart(url: url, job: job) }
                        } else if ui.detections[url]?.state != .plain {
                            Button("解密 IPA", systemImage: "lock.open") { ui.requestStart(url: url, job: job) }
                        }
                        Button("保存原始 IPA", systemImage: "folder") { exportFile(url, suggestedName: rowName + ".ipa", kind: .save) }
                        Button("分享原始 IPA", systemImage: "square.and.arrow.up") { exportFile(url, suggestedName: rowName + ".ipa", kind: .share) }
                        Button("重新检查", systemImage: "arrow.triangle.2.circlepath") { Task { await ui.detect(url, force: true) } }
                        Button("删除原始 IPA", systemImage: "trash", role: .destructive) { requestDeleteOriginalJob(job) }
                            .disabled(ui.protects(job.id))
                    }
            }
        }
    }

    private func standaloneRow(_ url: URL) -> some View {
        let meta = ui.localMetadata[url]
        let displayName = PackageStage.displayName(meta?.name ?? url.deletingPathExtension().lastPathComponent)
        let result = ui.attempts(url: url).first
        let hasOutput = result.flatMap { ui.currentOutput($0) } != nil
        let status = PackageStage.sourceSummary(
            checking: ui.detecting.contains(url),
            detection: ui.detections[url],
            latest: result,
            hasOutput: hasOutput
        )
        let version = (meta?.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = meta?.bytes ?? 0
        let sizeText = bytes > 0 ? bytes.byteLabel : ""
        let metadata = [version.isEmpty ? "" : "v\(version)", sizeText, AppText.text("本地文件")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let row = PackageLibraryRow(
            name: displayName,
            icon: meta?.iconURL,
            metadata: metadata,
            status: status.text,
            symbol: status.symbol,
            color: status.color
        )

        return selectableRow(.standalone(url), disabled: ui.protects(url: url), content: { row }) {
            packageNavRow(route: .file(url)) { row }
                .revealActions(
                    id: "pkg.file." + PackageOutputPolicy.canonicalPath(url),
                    enabled: !ui.protects(url: url),
                    restored: packageRemovals.recentlyRestoredPaths.contains(PackageOutputPolicy.canonicalPath(url)),
                    [
                        .delete(fills: true) { swipeDeleteStandaloneFile(url) },
                        RevealAction(title: "分享", systemImage: "square.and.arrow.up", tint: .blue, role: nil) {
                            exportFile(url, suggestedName: displayName + ".ipa", kind: .share)
                        }
                    ]
                )
                .contextMenu {
                    if let output = result, DecryptOutcomeStyle(output) == .success, ui.currentOutput(output) != nil {
                        Button("查看解密结果", systemImage: "checkmark.circle") { ui.navigate(.record(output.id)) }
                        Button("重新解密", systemImage: "arrow.clockwise") { ui.requestStart(url: url) }
                    } else if ui.detections[url]?.state != .plain {
                        Button("解密 IPA", systemImage: "lock.open") { ui.requestStart(url: url) }
                    }
                    Button("保存原始 IPA", systemImage: "folder") { exportFile(url, suggestedName: displayName + ".ipa", kind: .save) }
                    Button("分享原始 IPA", systemImage: "square.and.arrow.up") { exportFile(url, suggestedName: displayName + ".ipa", kind: .share) }
                    Button("重新检查", systemImage: "arrow.triangle.2.circlepath") { Task { await ui.detect(url, force: true) } }
                    Button("删除文件", systemImage: "trash", role: .destructive) { requestDeleteStandaloneFile(url) }
                        .disabled(ui.protects(url: url))
                }
        }
    }

    @ViewBuilder private var productSections: some View {
        let currentOutputs = outputs
        let currentOrphans = filteredOrphans
        let partitioned: (verified: [DecryptRecord], review: [DecryptRecord]) = {
            var verified: [DecryptRecord] = []
            var review: [DecryptRecord] = []
            for record in currentOutputs {
                if DecryptOutcomeStyle(record) == .success { verified.append(record) }
                else { review.append(record) }
            }
            return (verified, review)
        }()
        let verified = partitioned.verified
        let review = partitioned.review
        if verified.isEmpty && review.isEmpty && currentOrphans.isEmpty {
            Section {
                if term.isEmpty {
                    EmptyState(
                        title: "还没有解密产物",
                        message: "在「原始 IPA」中选择应用发起解密，完成后产物会出现在这里。",
                        symbol: "lock.open",
                        actionTitle: "查看原始 IPA"
                    ) { products = false }
                } else {
                    EmptyState(
                        title: "没有匹配的应用包",
                        message: "试试换个关键词，或清除搜索条件。",
                        symbol: "magnifyingglass",
                        actionTitle: "清除搜索"
                    ) { term = "" }
                }
            }.listRowBackground(Color.clear)
        } else {
            if !verified.isEmpty {
                Section("校验通过") {
                    ForEach(verified) { record in productRow(record) }
                }
            }
            if !review.isEmpty {
                Section("需要检查") {
                    ForEach(review) { record in productRow(record) }
                }
            }
            if !currentOrphans.isEmpty {
                Section {
                    ForEach(currentOrphans, id: \.self) { url in
                        let row = PackageLibraryRow(
                            name: url.deletingPathExtension().lastPathComponent,
                            icon: nil,
                            metadata: AppText.text("缺少处理记录"),
                            status: AppText.text("尚未确认校验结果"),
                            symbol: "questionmark.circle"
                        )
                        selectableRow(.orphan(url), disabled: service.isRunning, content: { row }) {
                            packageNavRow(route: .unlinked(url)) { row }
                                .revealActions(
                                    id: "pkg.orphan." + url.lastPathComponent,
                                    enabled: !service.isRunning,
                                    restored: packageRemovals.recentlyRestoredPaths.contains(PackageOutputPolicy.canonicalPath(url)),
                                    [
                                        .delete(fills: true) { swipeDeleteUnlinkedFile(url) },
                                        RevealAction(title: "分享", systemImage: "square.and.arrow.up", tint: .blue, role: nil) {
                                            exportFile(url, suggestedName: url.lastPathComponent, kind: .share)
                                        }
                                    ]
                                )
                                .contextMenu {
                                    Button("保存未验证的 IPA…", systemImage: "folder") { exportFile(url, suggestedName: url.lastPathComponent, kind: .save) }
                                    Button("分享未验证的 IPA…", systemImage: "square.and.arrow.up") { exportFile(url, suggestedName: url.lastPathComponent, kind: .share) }
                                    Button("删除文件", systemImage: "trash", role: .destructive) { pendingDelete = .unlinkedFile(url) }
                                        .disabled(service.isRunning)
                                }
                        }
                    }
                } header: { Text("未关联文件") } footer: { Text("记录移除后文件仍会保留，不能据此确认过去的解密和校验结果。") }
            }
        }
    }

    private func productRow(_ record: DecryptRecord) -> some View {
        let style = DecryptOutcomeStyle(record)
        let job = ui.job(for: record, manager: manager)
        let source = ui.source(for: record, manager: manager)
        #if canImport(TestFlightKit)
        let tfItem = source.flatMap { tfProducts.item(forFile: $0) }
        let resolvedName = job?.app.name ?? tfItem?.displayName ?? record.appName
        let isTF = record.isTestFlight == true || tfItem != nil || source?.path.contains("/TestFlight/") == true
        let tfVersionLabel = tfItem?.versionBuildLabel ?? ""
        #else
        let resolvedName = job?.app.name ?? record.appName
        let isTF = record.isTestFlight == true
        let tfVersionLabel = ""
        #endif
        let cleanName = PackageStage.displayName(resolvedName)
        let rawVersion = (record.version ?? job?.app.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let versionLabel = !tfVersionLabel.isEmpty ? tfVersionLabel : (rawVersion.isEmpty ? "" : "v\(rawVersion)")
        let sizeText = record.outputBytes.map { Int64($0).byteLabel } ?? ""
        let metadata = [versionLabel, sizeText].filter { !$0.isEmpty }.joined(separator: " · ")
        let outputURL = ui.currentOutput(record)
        let suggestedName = [cleanName, record.version].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "_")
            + (record.verification == .clean ? "_decrypted.ipa" : "_PARTIAL.ipa")
        let row = PackageLibraryRow(
            name: cleanName,
            icon: ui.iconURL(for: record, manager: manager),
            metadata: metadata,
            status: style.title,
            symbol: style.symbol,
            color: style.color,
            trailingNote: record.finishedAt?.formatted(date: .omitted, time: .shortened),
            isTestFlight: isTF
        )

        return selectableRow(.output(record.id), disabled: service.isRunning, content: { row }) {
            packageNavRow(route: .record(record.id)) { row }
                .revealActions(
                    id: "pkg.out." + record.id.uuidString,
                    enabled: !service.isRunning && outputURL != nil,
                    restored: packageRemovals.recentlyRestoredRecordIDs.contains(record.id),
                    [
                        .delete(fills: true) {
                            if let url = outputURL { swipeDeleteOutput(record: record, url: url) }
                        },
                        RevealAction(title: "分享", systemImage: "square.and.arrow.up", tint: .blue, role: nil) {
                            if let url = outputURL, style == .success {
                                exportFile(url, suggestedName: suggestedName, kind: .share)
                            } else {
                                ui.navigate(.record(record.id))
                            }
                        }
                    ]
                )
                .contextMenu {
                    if let url = outputURL {
                        if style == .success {
                            Button("保存到文件", systemImage: "folder") { exportFile(url, suggestedName: suggestedName, kind: .save) }
                            Button("分享 IPA", systemImage: "square.and.arrow.up") { exportFile(url, suggestedName: suggestedName, kind: .share) }
                        } else {
                            Button("查看详情并导出…", systemImage: "exclamationmark.triangle") { ui.navigate(.record(record.id)) }
                        }
                    }
                    if let source {
                        Button("重新解密", systemImage: "arrow.clockwise") { ui.requestStart(url: source, job: job) }
                    }
                    Button("删除产物文件", systemImage: "trash", role: .destructive) {
                        if let url = outputURL { pendingDelete = .outputRecord(record, url) }
                    }.disabled(service.isRunning || outputURL == nil)
                    Button("移除处理记录", systemImage: "clock.badge.xmark", role: .destructive) {
                        records.remove(id: record.id)
                        ui.markFilesChanged()
                    }.disabled(service.activeRecordID == record.id && service.isRunning)
                }
        }
    }

    // MARK: - Deletion & Export Helpers

    private var deleteTitle: LocalizedStringKey {
        switch pendingDelete {
        case .originalJob: return "删除原始 IPA？"
        case .standaloneFile, .unlinkedFile: return "删除这个文件？"
        case .outputRecord: return "删除产物文件？"
        #if canImport(TestFlightKit)
        case .tfProduct: return "删除 TestFlight 安装包？"
        #endif
        case nil: return "删除？"
        }
    }

    private var deleteMessage: LocalizedStringKey? {
        switch pendingDelete {
        case .originalJob: return "对应下载任务和原始文件会一并移除。解密产物和处理记录保留。"
        case .standaloneFile: return "将从设备删除这个 IPA 文件，处理记录保留。"
        case .outputRecord: return "只删除当前产物，原始 IPA 和处理记录保留。"
        case .unlinkedFile: return "将从设备删除这个未关联文件。"
        #if canImport(TestFlightKit)
        case .tfProduct: return "已下载的 TestFlight 安装包会被删除，TestFlight 页对应应用将同步恢复为「获取」。"
        #endif
        case nil: return nil
        }
    }

    private var deleteConfirmTitle: LocalizedStringKey {
        switch pendingDelete {
        case .originalJob: return "删除原始 IPA"
        case .outputRecord: return "删除产物文件"
        #if canImport(TestFlightKit)
        case .tfProduct: return "删除文件"
        #endif
        case .standaloneFile, .unlinkedFile, nil: return "删除文件"
        }
    }

    private func swipeDeleteOriginalJob(_ job: DownloadJob) {
        guard !swipingDeleteJobs.contains(job.id) else { return }
        guard !ui.protects(job.id) else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        withAnimation(UX.motion(reduceMotion)) { _ = swipingDeleteJobs.insert(job.id) }
        Task { @MainActor in
            defer { _ = withAnimation(UX.motion(reduceMotion)) { swipingDeleteJobs.remove(job.id) } }
            do {
                try await SAPSigner.$userInitiated.withValue(true) {
                    try await store.removeDownloadWithUndo(job.id, fromPackages: true)
                }
            } catch is CancellationError {
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func swipeDeleteStandaloneFile(_ url: URL) {
        guard !ui.protects(url: url) else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        do {
            try store.removePackageFileWithUndo(url)
            let target = PackageOutputPolicy.canonicalPath(url)
            withAnimation(UX.motion(reduceMotion)) {
                standalone.removeAll { PackageOutputPolicy.canonicalPath($0) == target }
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func swipeDeleteOutput(record: DecryptRecord, url: URL) {
        guard !service.isRunning else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        do {
            try store.removeDecryptOutputWithUndo(recordID: record.id, fileURL: url)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func swipeDeleteUnlinkedFile(_ url: URL) {
        guard !service.isRunning else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        do {
            try store.removePackageFileWithUndo(url)
            let target = PackageOutputPolicy.canonicalPath(url)
            withAnimation(UX.motion(reduceMotion)) {
                orphanedOutputs.removeAll { PackageOutputPolicy.canonicalPath($0) == target }
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func requestDeleteOriginalJob(_ job: DownloadJob) {
        guard !ui.protects(job.id) else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        pendingDelete = .originalJob(job)
    }

    private func requestDeleteStandaloneFile(_ url: URL) {
        guard !ui.protects(url: url) else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        pendingDelete = .standaloneFile(url)
    }

    private func executeDelete(_ item: PendingDelete) {
        switch item {
        case .originalJob(let job):
            guard !ui.protects(job.id) else {
                store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
                return
            }
            Task { @MainActor in
                do {
                    _ = try await manager.removeBatch([job.id])
                    ui.markFilesChanged()
                    store.infoMessage = AppText.text("已删除原始 IPA")
                } catch { store.errorMessage = error.localizedDescription }
            }
        case .standaloneFile(let url):
            guard !ui.protects(url: url) else {
                store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
                return
            }
            do {
                try FileManager.default.removeItem(at: url)
                ui.markFilesChanged()
                store.infoMessage = AppText.text("已删除文件")
            } catch { store.errorMessage = error.localizedDescription }
        case .outputRecord(let record, let url):
            guard !service.isRunning else {
                store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
                return
            }
            do {
                try FileManager.default.removeItem(at: url)
                records.update(id: record.id) { $0.outputIdentity = "removed" }
                ui.markFilesChanged()
                store.infoMessage = AppText.text("已删除产物文件")
            } catch { store.errorMessage = error.localizedDescription }
        case .unlinkedFile(let url):
            guard !service.isRunning else {
                store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
                return
            }
            do {
                try FileManager.default.removeItem(at: url)
                ui.markFilesChanged()
                store.infoMessage = AppText.text("已删除文件")
            } catch { store.errorMessage = error.localizedDescription }
        #if canImport(TestFlightKit)
        case .tfProduct(let item):
            guard !ui.protects(url: item.fileURL) else {
                store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
                return
            }
            tfProducts.delete(item)
            ui.markFilesChanged()
            store.infoMessage = AppText.text("已删除原始 IPA")
        #endif
        }
    }

    private func executeBatchDelete() {
        let targets = selection
        selection.removeAll()
        editing = false
        guard !targets.isEmpty else { return }

        var jobIDs: [UUID] = []
        var fileURLs: [URL] = []
        var outputRecordIDs: [UUID] = []
        #if canImport(TestFlightKit)
        var tfBundles: [String] = []
        #endif
        for item in targets {
            switch item {
            case .job(let id):
                if !ui.protects(id) { jobIDs.append(id) }
            case .standalone(let url):
                if !ui.protects(url: url) { fileURLs.append(url) }
            case .output(let id):
                if !service.isRunning { outputRecordIDs.append(id) }
            case .orphan(let url):
                if !service.isRunning { fileURLs.append(url) }
            #if canImport(TestFlightKit)
            case .tf(let bundle):
                tfBundles.append(bundle)
            #endif
            }
        }

        Task { @MainActor in
            var removed = 0
            var firstError: Error?
            if !jobIDs.isEmpty {
                do { removed += try await manager.removeBatch(Set(jobIDs)) }
                catch { firstError = firstError ?? error }
            }
            #if canImport(TestFlightKit)
            for bundle in tfBundles {
                if let item = tfProducts.items.first(where: { $0.bundleID == bundle }),
                   !ui.protects(url: item.fileURL) {
                    tfProducts.delete(item)
                    removed += 1
                }
            }
            #endif
            for url in fileURLs {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                } catch { firstError = firstError ?? error }
            }
            for id in outputRecordIDs {
                guard !service.isRunning,
                      let record = records.records.first(where: { $0.id == id }),
                      let url = ui.currentOutput(record) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    records.update(id: id) { $0.outputIdentity = "removed" }
                    removed += 1
                } catch { firstError = firstError ?? error }
            }
            if removed > 0 {
                ui.markFilesChanged()
                store.infoMessage = AppText.text("已删除 \(removed) 个应用包")
            }
            if let firstError {
                store.errorMessage = firstError.localizedDescription
            }
        }
    }

    private func exportFile(_ url: URL, suggestedName: String, kind: PackageFilePresentation.Kind) {
        do { presentation = try PackageFileActions.prepare(url, name: suggestedName, kind: kind) }
        catch { store.errorMessage = error.localizedDescription }
    }

    // MARK: - Search & Scanning

    private func matches(_ values: [String]) -> Bool {
        term.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(term) }
    }

    private func refreshFiles() async {
        records.invalidateFileCaches()
        let sourcePaths = Set(manager.jobs.compactMap { manager.fileURL($0).map(PackageOutputPolicy.canonicalPath) })
        let knownOutputPaths = Set(records.records.compactMap { ui.currentOutput($0).map(PackageOutputPolicy.canonicalPath) })
        let docs = FairPlayEnvironment.documentsDirectory
        let output = records.outputDirectory
        let scanned = await Task.detached(priority: .utility) { () -> ([URL], [URL]) in
            let fm = FileManager.default
            let sources = [docs, docs.appendingPathComponent("Packages")].flatMap {
                (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
            }.filter {
                $0.pathExtension.lowercased() == "ipa"
                    && !sourcePaths.contains(PackageOutputPolicy.canonicalPath($0))
            }
            let outputs = PackageOutputPolicy.unlinkedOutputs(in: output, knownOutputPaths: knownOutputPaths, fileManager: fm)
            return (sources.sorted { $0.lastPathComponent < $1.lastPathComponent }, outputs)
        }.value
        standalone = scanned.0
        orphanedOutputs = scanned.1
        #if canImport(TestFlightKit)
        tfProducts.refresh()
        #endif
        for job in allOriginals {
            if let url = manager.fileURL(job) { await ui.detect(url) }
        }
        #if canImport(TestFlightKit)
        for item in tfProducts.items {
            await ui.detect(item.fileURL)
        }
        #endif
        for url in standalone {
            await ui.loadMetadata(for: url)
            await ui.detect(url)
        }
    }

    private func importFiles(_ urls: [URL]) {
        importing = true
        products = false
        term = ""
        importIssue = nil
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        Task { @MainActor in
            defer { importing = false }
            for url in urls {
                let before = Set(manager.jobs.map(\.id))
                do {
                    try await manager.importFile(url)
                    importedIDs.formUnion(Set(manager.jobs.map(\.id)).subtracting(before))
                } catch {
                    importIssue = (importIssue.map { $0 + "\n" } ?? "") + url.lastPathComponent + ": " + error.localizedDescription
                }
                if url.resolvingSymlinksInPath().path.hasPrefix(temporary) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            finishImports()
            await refreshFiles()
        }
    }
}

struct DecryptOptionsView: View {
    @ObservedObject private var service = FairPlayHub.shared.service
    var body: some View {
        Form {
            Section {
                Toggle("下载完成后自动解密", isOn: $service.autoDecryptOnComplete)
            } footer: {
                Text("仅在专业模式开启时生效。同一时间处理一份 IPA；已有产物或其他任务正在运行时不会自动开始，也不会排队或覆盖文件。")
            }
        }
        .toolPage()
        .navigationTitle("处理选项")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct UnlinkedPackageView: View {
    let url: URL
    @EnvironmentObject private var store: ToolStore
    @ObservedObject private var service = FairPlayHub.shared.service
    @ObservedObject private var ui = FairPlayPresentation.shared
    @State private var presentation: PackageFilePresentation?
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                Text(verbatim: url.lastPathComponent).font(.body.weight(.medium)).textSelection(.enabled)
                Text("缺少处理记录，尚未确认校验结果。").foregroundStyle(.secondary)
            }
            Section {
                NavigationLink { PackageInfoView(file: url) } label: { Label("安装包信息", systemImage: "info.circle") }
                Button("保存未验证的 IPA…", systemImage: "folder") { export(.save) }.disabled(service.isRunning)
                Button("分享未验证的 IPA…", systemImage: "square.and.arrow.up") { export(.share) }.disabled(service.isRunning)
            }
            Section {
                Button("删除文件", systemImage: "trash", role: .destructive) { deleting = true }.disabled(service.isRunning)
            }
        }
        .toolPage()
        .navigationTitle("未关联文件")
        .navigationBarTitleDisplayMode(.inline)
        .packageFilePresenter($presentation)
        .actionConfirmation(isPresented: $deleting, title: "删除这个文件？", message: "将从设备删除这个未关联文件。", confirmTitle: "删除文件") {
            guard !service.isRunning else { return }
            do {
                try FileManager.default.removeItem(at: url)
                ui.markFilesChanged()
                store.infoMessage = AppText.text("已删除文件")
                dismiss()
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func export(_ kind: PackageFilePresentation.Kind) {
        do { presentation = try PackageFileActions.prepare(url, kind: kind) }
        catch { store.errorMessage = error.localizedDescription }
    }
}
