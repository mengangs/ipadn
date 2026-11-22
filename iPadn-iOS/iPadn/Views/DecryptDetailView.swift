import SwiftUI

/// Unified detail view for live processing, completed outputs, partial runs, failures and history records.
struct DecryptDetailView: View {
    let recordID: UUID
    @ObservedObject private var records = DecryptRecordStore.shared
    @ObservedObject private var service = FairPlayHub.shared.service
    @ObservedObject private var ui = FairPlayPresentation.shared
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var presentation: PackageFilePresentation?
    @State private var deletion: String?
    @State private var unverifiedExport: PackageFilePresentation.Kind?

    private var record: DecryptRecord? { records.records.first { $0.id == recordID } }
    private var live: Bool { service.activeRecordID == recordID && service.isRunning }

    var body: some View {
        List {
            if let record {
                heroSection(record)
                if !live {
                    if record.counts.machO > 0 { metricsSection(record) }
                    if DecryptOutcomeStyle(record) != .success && record.state != .plain {
                        failureSection(record)
                    }
                }
                filesSection(record)
                if !live { informationSection(record) }
                Section {
                    NavigationLink(value: PackageRoute.log(record.id)) {
                        Label("技术日志与详情", systemImage: "text.alignleft")
                    }
                    NavigationLink(value: PackageRoute.help) {
                        Label("使用说明与兼容性", systemImage: "questionmark.circle")
                    }
                }
                if !live {
                    Section {
                        if ui.currentOutput(record) != nil {
                            Button("删除产物文件", systemImage: "trash", role: .destructive) { deletion = "output" }
                                .disabled(service.isRunning)
                        }
                        Button("移除处理记录", systemImage: "clock.badge.xmark", role: .destructive) { deletion = "record" }
                    } footer: {
                        Text("移除处理记录不会删除原始 IPA 或已保存的副本。")
                    }
                }
            } else {
                if #available(iOS 17, *) {
                    ContentUnavailableView("记录已不存在", systemImage: "clock.arrow.circlepath")
                } else {
                    EmptyState(
                        title: "记录已不存在",
                        message: "移除处理记录不会删除原始 IPA 或已保存的副本。",
                        symbol: "clock.arrow.circlepath"
                    )
                }
            }
        }
        .toolPage()
        .navigationTitle("解密详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Menu {
                    if let record {
                        if let source = ui.source(for: record, manager: manager), !live {
                            Button("重新解密", systemImage: "arrow.clockwise") {
                                ui.requestStart(url: source, job: sourceJob(record))
                            }
                        }
                        if ui.currentOutput(record) != nil {
                            Button("删除产物文件", systemImage: "trash", role: .destructive) { deletion = "output" }
                                .disabled(service.isRunning)
                        }
                        Button("移除处理记录", systemImage: "clock.badge.xmark", role: .destructive) { deletion = "record" }
                            .disabled(live)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("更多操作")
            }
        }
        .packageFilePresenter($presentation)
        .actionConfirmation(
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            title: deletion == "output" ? "删除产物文件？" : "移除处理记录？",
            message: deletion == "output" ? "只删除当前产物，原始 IPA 和处理记录保留。" : "只移除这次处理记录，所有 IPA 文件保留。",
            confirmTitle: "确认删除"
        ) {
            remove()
        }
        .actionConfirmation(
            isPresented: Binding(get: { unverifiedExport != nil }, set: { if !$0 { unverifiedExport = nil } }),
            title: "产物未通过校验",
            message: "文件可能仍包含加密内容或存在其他问题，不代表可以正常安装运行。",
            confirmTitle: "继续导出未通过校验的 IPA",
            destructive: false
        ) {
            if let kind = unverifiedExport, let record { export(record, kind: kind) }
            unverifiedExport = nil
        }
    }

    // MARK: - Hero

    private func heroSection(_ record: DecryptRecord) -> some View {
        let style = DecryptOutcomeStyle(record)
        let job = sourceJob(record)
        let source = ui.source(for: record, manager: manager)
        #if canImport(TestFlightKit)
        let tfItem = source.flatMap { TFProductIndex.shared.item(forFile: $0) }
        let isTF = record.isTestFlight == true || tfItem != nil || source?.path.contains("/TestFlight/") == true
        let title = PackageStage.displayName(job?.app.name ?? tfItem?.displayName ?? record.appName)
        let tfVersion = tfItem?.versionBuildLabel ?? ""
        #else
        let isTF = record.isTestFlight == true
        let title = PackageStage.displayName(job?.app.name ?? record.appName)
        let tfVersion = ""
        #endif
        let version = (record.version ?? job?.app.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let versionText = !tfVersion.isEmpty ? tfVersion : (version.isEmpty ? "" : "v\(version)")
        let sizeText = (ui.currentOutput(record) != nil ? record.outputBytes : record.sourceBytes)
            .flatMap { $0 > 0 ? Int64($0).byteLabel : nil } ?? ""
        let subtitle = [versionText, sizeText].filter { !$0.isEmpty }.joined(separator: " · ")

        return Section {
            VStack(spacing: 14) {
                AppIcon(url: ui.iconURL(for: record, manager: manager), size: 80)
                VStack(spacing: 4) {
                    Text(verbatim: title)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if isTF || !subtitle.isEmpty {
                        HStack(spacing: 5) {
                            if isTF {
                                TestFlightIcon(size: 14)
                            }
                            if !subtitle.isEmpty {
                                Text(verbatim: subtitle)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Label {
                    Text(verbatim: live ? PackageStage.title(service.step) : style.title)
                } icon: {
                    Image(systemName: style.symbol)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(style.color)

                if live {
                    liveProgressControls
                } else {
                    terminalHeroActions(record, style: style)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var liveProgressControls: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("处理进度").foregroundStyle(.secondary)
                    Spacer()
                    Text("约 \(Int(service.fraction * 100))%").monospacedDigit().fontWeight(.semibold)
                }
                .font(.footnote)
                ProgressView(value: service.fraction)
                    .tint(UX.tint)
                    .accessibilityIdentifier("fairplay.progress")
                Text(verbatim: ui.isCancelling
                     ? AppText.text("将在当前操作安全结束后停止。")
                     : PackageStage.shortDetail(service.detail))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)

            stageRail

            if ui.canCancel || ui.isCancelling {
                Button(role: .destructive) { ui.cancel() } label: {
                    Text(ui.isCancelling ? "正在取消…" : "取消解密").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .disabled(!ui.canCancel)
                .frame(minHeight: 40)
                .accessibilityIdentifier("fairplay.cancel")
            } else {
                Text("可以返回列表继续浏览。打包和校验阶段需要等待完成。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var stageRail: some View {
        let current = PackageStage.index(service.step)
        let stages = ["准备安装包", "解密二进制", "重新打包", "校验产物"]
        return HStack(spacing: 6) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, label in
                let done = current.map { index < $0 } ?? false
                let active = current == index
                VStack(spacing: 4) {
                    Image(systemName: done ? "checkmark.circle.fill" : active ? "circle.inset.filled" : "circle")
                        .font(.footnote)
                        .foregroundStyle(done || active ? UX.tint : Color.secondary.opacity(0.6))
                    Text(LocalizedStringKey(label))
                        .font(.caption2)
                        .foregroundStyle(done || active ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("处理阶段")
        .accessibilityValue(PackageStage.title(service.step))
    }

    @ViewBuilder private func terminalHeroActions(_ record: DecryptRecord, style: DecryptOutcomeStyle) -> some View {
        if style == .success || record.state == .plain {
            if exportURL(record) != nil {
                VStack(spacing: 10) {
                    Button {
                        export(record, kind: .save)
                    } label: {
                        Text(record.state == .plain ? "保存原始 IPA" : "保存到文件").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(service.isRunning)
                    .accessibilityIdentifier("detail.export")

                    Button {
                        export(record, kind: .share)
                    } label: {
                        Label("分享 IPA", systemImage: "square.and.arrow.up")
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
                    .disabled(service.isRunning)
                    .frame(minHeight: 36)
                }
            }
        } else {
            VStack(spacing: 10) {
                if let url = ui.source(for: record, manager: manager) {
                    Button {
                        ui.requestStart(url: url, job: sourceJob(record))
                    } label: {
                        Text("重新解密").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Text("原始 IPA 已不存在，请返回应用包导入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: - Metrics & Failure

    private func metricsSection(_ record: DecryptRecord) -> some View {
        Section {
            if typeSize.isAccessibilitySize {
                LabeledContent("本次解密", value: AppText.text("\(record.counts.decrypted) 个"))
                LabeledContent("原本未加密", value: AppText.text("\(record.counts.plain) 个"))
                LabeledContent("处理失败", value: AppText.text("\(record.counts.failed) 个"))
            } else {
                HStack(spacing: 0) {
                    metricCell(caption: "本次解密", value: "\(record.counts.decrypted)", tint: .green)
                    Divider()
                    metricCell(caption: "原本未加密", value: "\(record.counts.plain)", tint: .secondary)
                    Divider()
                    metricCell(caption: "处理失败", value: "\(record.counts.failed)", tint: record.counts.failed > 0 ? .red : .secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            if DecryptOutcomeStyle(record) == .success {
                Text("校验通过")
            }
        }
    }

    private func metricCell(caption: LocalizedStringKey, value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(verbatim: value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint == .secondary ? .primary : tint)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func failureSection(_ record: DecryptRecord) -> some View {
        let style = DecryptOutcomeStyle(record)
        Section {
            VStack(alignment: .leading, spacing: 8) {
                switch style {
                case .partial:
                    Text("部分内容未能解密，产物仍不完整。")
                        .font(.subheadline.weight(.medium))
                case .cancelled:
                    Text("这次解密已取消，原始 IPA 已保留。")
                        .font(.subheadline)
                case .interrupted:
                    Text("上次处理没有完成，可以从原始 IPA 重新开始。")
                        .font(.subheadline)
                case .failed:
                    if record.verification == .failed {
                        Text("产物校验未通过").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    }
                    if let failure = record.failure {
                        if failure.kind == .fairplayDenied {
                            Text("系统拒绝了解密请求").font(.headline)
                            Text("这次请求未被系统允许。账号授权不匹配或家庭共享等只是可能原因，无法仅凭 EPERM 确认。")
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(failure.title).font(.headline)
                            if !failure.isCertain {
                                Text("可能原因").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            }
                            Text(DiagnosticRedactor.sanitize(failure.reason))
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(DiagnosticRedactor.sanitize(failure.advice))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                default:
                    EmptyView()
                }
            }
            .padding(.vertical, 2)

            if ui.currentOutput(record) != nil {
                Button("保存未通过校验的 IPA…", systemImage: "folder") { unverifiedExport = .save }
                    .disabled(service.isRunning)
                Button("分享未通过校验的 IPA…", systemImage: "square.and.arrow.up") { unverifiedExport = .share }
                    .disabled(service.isRunning)
            }
        }
    }

    // MARK: - Files & Info

    private func filesSection(_ record: DecryptRecord) -> some View {
        Section("文件") {
            if let source = ui.source(for: record, manager: manager) {
                let targetRoute = sourceJob(record).map { PackageRoute.source($0.id) } ?? .file(source)
                Button {
                    if ui.previousRoute == targetRoute {
                        dismiss()
                    } else {
                        ui.push(targetRoute)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("原始 IPA")
                                .foregroundStyle(.primary)
                            Text(verbatim: PackageStage.detection(ui.detections[source] ?? record.detection))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(verbatim: PackageStage.displayName(record.sourceName))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Label("原始 IPA 已不存在，请重新导入。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            if let url = ui.currentOutput(record) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.verification == .clean ? "解密产物" : "待检查产物")
                    Text(verbatim: url.lastPathComponent)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let bytes = record.outputBytes {
                        Text(Int64(bytes).byteLabel)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else if record.outputName != nil {
                Text(records.outputURL(for: record) != nil ? "产物已被后续处理替换" : "产物文件已不存在")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func informationSection(_ record: DecryptRecord) -> some View {
        Section("处理信息") {
            LabeledContent("开始时间", value: record.startedAt.formatted(date: .abbreviated, time: .shortened))
            if let finished = record.finishedAt {
                LabeledContent("结束时间", value: finished.formatted(date: .abbreviated, time: .shortened))
            }
            if record.origin == .automatic {
                LabeledContent("发起方式", value: AppText.text("自动解密"))
            }
            if let summary = record.verificationSummary {
                DisclosureGroup("校验详情") {
                    Text(verbatim: DiagnosticRedactor.sanitize(summary))
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func sourceJob(_ record: DecryptRecord) -> DownloadJob? { ui.job(for: record, manager: manager) }
    private func exportURL(_ record: DecryptRecord) -> URL? {
        record.state == .plain ? ui.source(for: record, manager: manager) : ui.currentOutput(record)
    }

    private func export(_ record: DecryptRecord, kind: PackageFilePresentation.Kind) {
        guard let url = exportURL(record), !service.isRunning else { return }
        let suffix = record.state == .plain ? "" : record.verification == .clean ? "_decrypted" : "_PARTIAL"
        let cleanName = PackageStage.displayName(record.appName)
        let name = [cleanName, record.version].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "_") + suffix + ".ipa"
        do { presentation = try PackageFileActions.prepare(url, name: name, kind: kind) }
        catch { store.errorMessage = error.localizedDescription }
    }

    private func remove() {
        guard let record, let deletion, !live else { return }
        do {
            if deletion == "output" {
                guard !service.isRunning, let url = ui.currentOutput(record) else { return }
                try FileManager.default.removeItem(at: url)
                records.update(id: record.id) { $0.outputIdentity = "removed" }
                ui.markFilesChanged()
                store.infoMessage = AppText.text("已删除产物文件")
            } else {
                records.remove(id: record.id)
                ui.markFilesChanged()
                dismiss()
            }
        } catch { store.errorMessage = error.localizedDescription }
        self.deletion = nil
    }
}
