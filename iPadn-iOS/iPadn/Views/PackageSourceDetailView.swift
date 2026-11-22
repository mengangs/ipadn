import SwiftUI

struct PackageSourceDetailView: View {
    var jobID: UUID? = nil
    var file: URL? = nil
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var store: ToolStore
    @ObservedObject private var ui = FairPlayPresentation.shared
    @ObservedObject private var service = FairPlayHub.shared.service
    @ObservedObject private var records = DecryptRecordStore.shared
    @State private var presentation: PackageFilePresentation?
    @State private var confirmingDelete = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss

    private var job: DownloadJob? { manager.jobs.first { $0.id == jobID } }
    private var url: URL? { job.flatMap { manager.fileURL($0) } ?? file }
    private var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    private var attempts: [DecryptRecord] { url.map { ui.attempts(url: $0, jobID: jobID) } ?? [] }
    private var localMeta: StandalonePackageMeta? { url.flatMap { ui.localMetadata[$0] } }
    #if canImport(TestFlightKit)
    private var tfItem: TFProductItem? { url.flatMap { TFProductIndex.shared.item(forFile: $0) } }
    #endif

    private var name: String {
        #if canImport(TestFlightKit)
        let tfName = tfItem?.displayName
        #else
        let tfName: String? = nil
        #endif
        return PackageStage.displayName(
            job?.app.name
                ?? tfName
                ?? localMeta?.name
                ?? url?.deletingPathExtension().lastPathComponent
                ?? AppText.text("原始 IPA")
        )
    }

    private var subtitleText: String {
        let version: String
        let bytes: Int64
        if let job {
            version = job.conciseVersionLabel
            bytes = job.app.size
        } else {
            #if canImport(TestFlightKit)
            if let tfItem {
                version = tfItem.versionBuildLabel
                bytes = tfItem.fileSize
                return [version, bytes > 0 ? bytes.byteLabel : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            #endif
            let v = (localMeta?.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            version = v.isEmpty ? "" : "v\(v)"
            bytes = localMeta?.bytes ?? 0
        }
        return [version, bytes > 0 ? bytes.byteLabel : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var iconURL: URL? {
        if let job { return manager.packageIconURL(job) ?? job.app.iconURL }
        if let icon = localMeta?.iconURL { return icon }
        #if canImport(TestFlightKit)
        if let icon = tfItem?.iconURL { return icon }
        #endif
        return nil
    }

    private var activeAttempt: DecryptRecord? {
        guard service.isRunning else { return nil }
        return attempts.first { $0.id == service.activeRecordID }
    }

    private var latestCleanOutput: DecryptRecord? {
        attempts.first { DecryptOutcomeStyle($0) == .success && ui.currentOutput($0) != nil }
    }

    var body: some View {
        List {
            heroSection
            if exists, let url {
                detailsSection(url)
                exportSection
            }
            if !attempts.isEmpty {
                Section("处理记录") {
                    ForEach(attempts) { record in
                        let style = DecryptOutcomeStyle(record)
                        NavigationLink(value: PackageRoute.record(record.id)) {
                            HStack(spacing: 12) {
                                Image(systemName: style.symbol)
                                    .foregroundStyle(style.color)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: style.title).font(.body)
                                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            if exists {
                Section {
                    Button("删除原始 IPA", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .disabled(isProtected || deleting)
                }
            }
        }
        .toolPage()
        .navigationTitle("原始 IPA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Menu {
                    if exists, let url {
                        Button("重新检查", systemImage: "arrow.clockwise") {
                            Task { await ui.detect(url, force: true) }
                        }.disabled(ui.detecting.contains(url))
                        if ui.detections[url]?.state != .plain {
                            Button("重新解密", systemImage: "lock.open") { ui.requestStart(url: url, job: job) }
                        }
                        Button("删除原始 IPA", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                            .disabled(isProtected || deleting)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("更多操作")
            }
        }
        .task(id: url) {
            if let url, exists {
                if job == nil { await ui.loadMetadata(for: url) }
                await ui.detect(url)
            }
        }
        .packageFilePresenter($presentation)
        .actionConfirmation(
            isPresented: $confirmingDelete,
            title: "删除原始 IPA？",
            message: "对应下载任务和原始文件会一并移除。解密产物和处理记录保留。",
            confirmTitle: "删除原始 IPA"
        ) {
            remove()
        }
    }

    private var isProtected: Bool {
        if let job, ui.protects(job.id) { return true }
        if let url, ui.protects(url: url) { return true }
        return false
    }

    private var heroSection: some View {
        Section {
            VStack(spacing: 14) {
                AppIcon(url: iconURL, size: 80)
                VStack(spacing: 4) {
                    Text(verbatim: name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if !subtitleText.isEmpty {
                        Text(verbatim: subtitleText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if exists, let url {
                    let status = PackageStage.sourceSummary(
                        checking: ui.detecting.contains(url),
                        detection: ui.detections[url],
                        latest: attempts.first,
                        hasOutput: latestCleanOutput != nil
                    )
                    Label {
                        Text(verbatim: status.text)
                    } icon: {
                        Image(systemName: status.symbol)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(status.color)

                    heroPrimaryControl(url: url)
                } else {
                    Label("原始 IPA 已不存在，请重新导入。", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private func heroPrimaryControl(url: URL) -> some View {
        if let active = activeAttempt {
            Button {
                ui.push(.record(active.id))
            } label: {
                Text("查看解密进度").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        } else if let output = latestCleanOutput {
            VStack(spacing: 10) {
                Button {
                    ui.push(.record(output.id))
                } label: {
                    Text("查看解密结果").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())

                if ui.detections[url]?.state != .plain {
                    Button("重新解密") { ui.requestStart(url: url, job: job) }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.borderless)
                        .frame(minHeight: 36)
                }
            }
        } else if ui.detections[url]?.state == .plain {
            Button {
                export(.save)
            } label: {
                Text("保存原始 IPA").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        } else {
            Button {
                ui.requestStart(url: url, job: job)
            } label: {
                HStack(spacing: 8) {
                    if ui.detecting.contains(url) { ProgressView().tint(UX.onAccent) }
                    Text(ui.detecting.contains(url) ? "正在检查…"
                         : ui.detections[url]?.state == .encrypted ? "解密 IPA" : "检查并解密…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(ui.detecting.contains(url))
            .accessibilityIdentifier("source.decrypt")
        }
    }

    private func detailsSection(_ url: URL) -> some View {
        Section("文件与检测") {
            LabeledContent(
                "加密状态",
                value: ui.detecting.contains(url) ? AppText.text("正在检查…") : PackageStage.detection(ui.detections[url])
            )
            if let checked = ui.detections[url]?.checkedAt {
                LabeledContent("检测时间", value: checked.formatted(date: .abbreviated, time: .shortened))
            }
            PackageBuildInfoRows(file: url)
            if let detection = ui.detections[url] {
                DisclosureGroup("检测详情") {
                    if let note = detection.note {
                        Text(verbatim: note).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(detection.binaries) { binary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: binary.path).font(.footnote.monospaced()).textSelection(.enabled)
                            Text(verbatim: PackageStage.detection(IPADetection(state: binary.state)))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            NavigationLink { PackageInfoView(file: url, job: job) } label: {
                Label("安装包信息", systemImage: "info.circle")
            }
            NavigationLink { PackageContentsView(file: url) } label: {
                Label("浏览安装包内容", systemImage: "folder")
            }
            Text(verbatim: url.lastPathComponent)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var exportSection: some View {
        Section {
            Button("保存原始 IPA", systemImage: "folder") { export(.save) }
            Button("分享原始 IPA", systemImage: "square.and.arrow.up") { export(.share) }
        } footer: {
            Text("解密会生成独立产物，原始 IPA 保持不变。")
        }
    }

    private func export(_ kind: PackageFilePresentation.Kind) {
        guard let url else { return }
        do { presentation = try PackageFileActions.prepare(url, name: name + ".ipa", kind: kind) }
        catch { store.errorMessage = error.localizedDescription }
    }

    private func remove() {
        guard !isProtected, !deleting else { return }
        deleting = true
        Task { @MainActor in
            defer { deleting = false }
            do {
                if let job {
                    _ = try await manager.removeBatch([job.id])
                    ui.markFilesChanged()
                    store.infoMessage = AppText.text("已删除原始 IPA")
                } else if let url {
                    #if canImport(TestFlightKit)
                    if let tfItem = TFProductIndex.shared.item(forFile: url) {
                        TFProductIndex.shared.delete(tfItem)
                        ui.markFilesChanged()
                        store.infoMessage = AppText.text("已删除原始 IPA")
                    } else {
                        try FileManager.default.removeItem(at: url)
                        ui.markFilesChanged()
                        store.infoMessage = AppText.text("已删除原始 IPA")
                    }
                    #else
                    try FileManager.default.removeItem(at: url)
                    ui.markFilesChanged()
                    store.infoMessage = AppText.text("已删除原始 IPA")
                    #endif
                }
                dismiss()
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}
