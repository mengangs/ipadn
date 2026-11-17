import SwiftUI
import UIKit

struct DecryptLogView: View {
    let recordID: UUID
    @ObservedObject private var service = FairPlayHub.shared.service
    @ObservedObject private var records = DecryptRecordStore.shared
    @EnvironmentObject private var store: ToolStore
    @State private var warningsOnly = false
    @State private var follow = true
    @State private var presentation: PackageFilePresentation?

    private var record: DecryptRecord? { records.records.first { $0.id == recordID } }
    private var ownsLog: Bool { service.activeRecordID == recordID }

    private var secrets: [String] {
        let accountSecrets = store.apple.accounts.flatMap { account in
            let explicit = [account.id, account.password, account.passwordToken, account.dsid, account.cookie]
                .filter { $0.count >= 4 }
            let cookieValues = account.cookie.split(separator: ";").compactMap { field -> String? in
                guard let raw = field.split(separator: "=", maxSplits: 1).last else { return nil }
                let value = String(raw).trimmingCharacters(in: .whitespaces)
                return value.count >= 6 ? value : nil
            }
            return explicit + cookieValues
        }
        let sharedCookies = (HTTPCookieStorage.shared.cookies ?? [])
            .map(\.value)
            .filter { $0.count >= 6 }
        return accountSecrets + sharedCookies
    }

    private var lines: [FairPlayLine] {
        guard ownsLog else { return [] }
        return service.lines.filter { !warningsOnly || $0.kind == .warn || $0.kind == .fail }
    }

    private var sanitizedExportText: String {
        // Each service line is a logical event and may itself contain multiple
        // untrusted lines. Sanitize before joining, preserving useful events.
        var parts: [String] = []
        let lineText = lines.map { DiagnosticRedactor.sanitize($0.rendered, secrets: secrets) }.joined(separator: "\n")
        if !lineText.isEmpty { parts.append(lineText) }
        if !ownsLog || service.lines.isEmpty, let summary = record?.verificationSummary, !summary.isEmpty {
            parts.append(DiagnosticRedactor.sanitize(summary, secrets: secrets))
        }
        if let details = record?.failure?.details, !details.isEmpty {
            parts.append(DiagnosticRedactor.sanitize(details, secrets: secrets))
        }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if ownsLog && !service.lines.isEmpty {
                    Section {
                        Picker("日志筛选", selection: $warningsOnly) {
                            Text("全部").tag(false)
                            Text("警告与错误").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if service.isRunning {
                            Toggle("跟随最新日志", isOn: $follow)
                        }
                    } footer: {
                        Text("显示和导出前会脱敏账号、凭据、令牌和 Cookie。仅保留当前任务最近 400 行。")
                    }

                    if lines.isEmpty {
                        Section {
                            Text("当前任务没有警告或错误记录。").foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(verbatim: DiagnosticRedactor.sanitize(line.rendered, secrets: secrets))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(color(for: line.kind))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("fairplay.log")
                        }
                    }
                } else {
                    Section {
                        Text("未保留这次处理的完整日志。以下仅显示已有的技术详情。")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("显示和导出前会脱敏账号、凭据、令牌和 Cookie。仅保留当前任务最近 400 行。")
                    }
                    if let summary = record?.verificationSummary, !summary.isEmpty {
                        Section("校验详情") {
                            Text(verbatim: DiagnosticRedactor.sanitize(summary, secrets: secrets))
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let details = record?.failure?.details, !details.isEmpty {
                        Section("技术详情") {
                            Text(verbatim: DiagnosticRedactor.sanitize(details, secrets: secrets))
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("fairplay.log")
                        }
                    }
                }
                Color.clear.frame(height: 1).listRowBackground(Color.clear).id("latest")
            }
            .toolPage()
            .navigationTitle("技术日志与详情")
            .navigationBarTitleDisplayMode(.inline)
            .simultaneousGesture(DragGesture().onChanged { _ in if follow { follow = false } })
            .compatibleOnChange(of: service.lines.last?.rendered) { _ in
                if follow && ownsLog { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .compatibleTopBarTrailing) {
                    if ownsLog && !lines.isEmpty {
                        Button {
                            follow = true
                            withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down.to.line")
                        }
                        .accessibilityLabel("回到最新")
                    }
                    Menu {
                        Button("复制脱敏日志", systemImage: "doc.on.doc") {
                            UIPasteboard.general.setItems(
                                [["public.utf8-plain-text": DiagnosticRedactor.sanitize(sanitizedExportText, secrets: secrets)]],
                                options: [.localOnly: true]
                            )
                            store.infoMessage = AppText.text("已复制脱敏日志")
                        }
                        Button("保存脱敏日志", systemImage: "folder") { export(.save) }
                        Button("分享脱敏日志", systemImage: "square.and.arrow.up") { export(.share) }
                    } label: {
                        Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(sanitizedExportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("导出脱敏日志")
                }
            }
            .packageFilePresenter($presentation)
        }
    }

    private func color(for kind: FairPlayLine.Kind) -> Color {
        switch kind {
        case .fail: return .red
        case .warn: return .orange
        case .ok: return .green
        case .phase: return .primary
        case .info: return .secondary
        }
    }

    private func export(_ kind: PackageFilePresentation.Kind) {
        do {
            // Re-sanitize at the export boundary. Raw fairplay-last.log is
            // deliberately never used, copied or handed to an extension.
            let text = DiagnosticRedactor.sanitize(sanitizedExportText, secrets: secrets)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("PackageExports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("iPadn-diagnostic-redacted.txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            presentation = PackageFilePresentation(url: url, kind: kind)
        } catch { store.errorMessage = error.localizedDescription }
    }
}
