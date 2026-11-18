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
    @State private var editing = false
    @State private var selection = Set<SelectionItem>()
    @State private var confirmingBatchDelete = false

    private enum SelectionItem: Hashable {
        case job(UUID)
        case standalone(URL)
        case output(UUID)
        case orphan(URL)
    }

    private enum PendingDelete: Identifiable {
        case originalJob(DownloadJob)
        case standaloneFile(URL)
        case outputRecord(DecryptRecord, URL)
        case unlinkedFile(URL)

        var id: String {
            switch self {
            case .originalJob(let job): return "job-\(job.id.uuidString)"
            case .standaloneFile(let url): return "file-\(url.path)"
            case .outputRecord(let record, _): return "rec-\(record.id.uuidString)"
            case .unlinkedFile(let url): return "orphan-\(url.path)"
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
        allOutputs.filter {
            matches([$0.appName, $0.version ?? "", $0.bundleID ?? "", $0.outputName ?? ""])
        }.sorted {
            sort == 1 ? $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
                : sort == 2 ? ($0.outputBytes ?? 0) > ($1.outputBytes ?? 0)
                : $0.startedAt > $1.startedAt
        }
    }

    private var filteredOrphans: [URL] {
        orphanedOutputs.filter { matches([$0.lastPathComponent]) }
    }

    private var originalCount: Int { allOriginals.count + standalone.count }
    private var outputCount: Int { allOutputs.count + orphanedOutputs.count }
    private var allEmpty: Bool { originalCount == 0 && outputCount == 0 && !service.isRunning && !importing && importedIDs.isEmpty }
    private var hasVisibleItems: Bool {
        products ? !(outputs.isEmpty && filteredOrphans.isEmpty) : !(originals.isEmpty && filteredStandalone.isEmpty)
    }
    private var selectableItems: [SelectionItem] {
        if products {
            return outputs.compactMap { !service.isRunning ? .output($0.id) : nil }
                + filteredOrphans.compactMap { !service.isRunning ? .orphan($0) : nil }
        }
        return originals.compactMap { !ui.protects($0.id) ? .job($0.id) : nil }
            + filteredStandalone.compactMap { !ui.protects(url: $0) ? .standalone($0) : nil }
    }

    var body: some View {
        library
            .toolPage()
            .navigationTitle("应用包")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { libraryToolbar }
            .packageFilePresenter($presentation)
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

    @ViewBuilder private var originalSections: some View {
        if originals.isEmpty && filteredStandalone.isEmpty {
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
            if !originals.isEmpty {
                Section {
                    ForEach(originals) { job in
                        originalJobRow(job)
                    }
                } footer: {
                    if filteredStandalone.isEmpty {
                        Text("原始 IPA 是处理来源，可能已加密，也可能本来就未加密。")
                    }
                }
            }
            if !filteredStandalone.isEmpty {
                Section {
                    ForEach(filteredStandalone, id: \.self) { url in
                        standaloneRow(url)
                    }
                } header: {
                    if !originals.isEmpty { Text("本地文件") }
                } footer: {
                    Text("原始 IPA 是处理来源，可能已加密，也可能本来就未加密。")
                }
            }
        }
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
                NavigationLink(value: PackageRoute.source(job.id)) { row }
                    .revealActions(
                        id: "pkg.job." + job.id.uuidString,
                        enabled: !ui.protects(job.id),
                        [
                            .delete(fills: false) { requestDeleteOriginalJob(job) },
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
            NavigationLink(value: PackageRoute.file(url)) { row }
                .revealActions(
                    id: "pkg.file." + PackageOutputPolicy.canonicalPath(url),
                    enabled: !ui.protects(url: url),
                    [
                        .delete(fills: false) { requestDeleteStandaloneFile(url) },
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
        let verified = outputs.filter { DecryptOutcomeStyle($0) == .success }
        let review = outputs.filter { DecryptOutcomeStyle($0) != .success }
        if verified.isEmpty && review.isEmpty && filteredOrphans.isEmpty {
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
            if !filteredOrphans.isEmpty {
                Section {
                    ForEach(filteredOrphans, id: \.self) { url in
                        let row = PackageLibraryRow(
                            name: url.deletingPathExtension().lastPathComponent,
                            icon: nil,
                            metadata: AppText.text("缺少处理记录"),
                            status: AppText.text("尚未确认校验结果"),
                            symbol: "questionmark.circle"
                        )
                        selectableRow(.orphan(url), disabled: service.isRunning, content: { row }) {
                            NavigationLink(value: PackageRoute.unlinked(url)) { row }
                                .revealActions(
                                    id: "pkg.orphan." + url.lastPathComponent,
                                    enabled: !service.isRunning,
                                    [
                                        .delete(fills: false) { pendingDelete = .unlinkedFile(url) },
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
        let cleanName = PackageStage.displayName(record.appName)
        let versionText = (record.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sizeText = record.outputBytes.map { Int64($0).byteLabel } ?? ""
        let metadata = [versionText.isEmpty ? "" : "v\(versionText)", sizeText].filter { !$0.isEmpty }.joined(separator: " · ")
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
            trailingNote: record.finishedAt?.formatted(date: .omitted, time: .shortened)
        )

        return selectableRow(.output(record.id), disabled: service.isRunning, content: { row }) {
            NavigationLink(value: PackageRoute.record(record.id)) { row }
                .revealActions(
                    id: "pkg.out." + record.id.uuidString,
                    enabled: !service.isRunning,
                    [
                        .delete(fills: false) {
                            if let url = outputURL { pendingDelete = .outputRecord(record, url) }
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
                    if let source = ui.source(for: record, manager: manager) {
                        Button("重新解密", systemImage: "arrow.clockwise") { ui.requestStart(url: source, job: ui.job(for: record, manager: manager)) }
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
        case nil: return "删除？"
        }
    }

    private var deleteMessage: LocalizedStringKey? {
        switch pendingDelete {
        case .originalJob: return "对应下载任务和原始文件会一并移除。解密产物和处理记录保留。"
        case .standaloneFile: return "将从设备删除这个 IPA 文件，处理记录保留。"
        case .outputRecord: return "只删除当前产物，原始 IPA 和处理记录保留。"
        case .unlinkedFile: return "将从设备删除这个未关联文件。"
        case nil: return nil
        }
    }

    private var deleteConfirmTitle: LocalizedStringKey {
        switch pendingDelete {
        case .originalJob: return "删除原始 IPA"
        case .outputRecord: return "删除产物文件"
        case .standaloneFile, .unlinkedFile, nil: return "删除文件"
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
            }
        }

        Task { @MainActor in
            var removed = 0
            var firstError: Error?
            if !jobIDs.isEmpty {
                do { removed += try await manager.removeBatch(Set(jobIDs)) }
                catch { firstError = firstError ?? error }
            }
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
        for job in allOriginals {
            if let url = manager.fileURL(job) { await ui.detect(url) }
        }
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
