import SwiftUI

struct PackageLibraryRow: View {
    let name: String
    let icon: URL?
    let metadata: String
    let status: String
    var symbol: String? = nil
    var color: Color = .secondary
    var iconSize: CGFloat = 54
    var trailingNote: String? = nil
    var badge: String? = nil
    var badgeTint: Color = .blue
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        AppIcon(url: icon, size: min(iconSize, 44)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: name)
                                    .font(.body.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                if badge == "TF" {
                                    TestFlightBadge()
                                } else if let badge, !badge.isEmpty {
                                    TagBadge(text: LocalizedStringKey(badge), tint: badgeTint)
                                }
                            }
                            if let trailingNote, !trailingNote.isEmpty {
                                Text(verbatim: trailingNote)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    rowDetails
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    AppIcon(url: icon, size: iconSize).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(verbatim: name)
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            if badge == "TF" {
                                TestFlightBadge()
                            } else if let badge, !badge.isEmpty {
                                TagBadge(text: LocalizedStringKey(badge), tint: badgeTint)
                            }
                            if let trailingNote, !trailingNote.isEmpty {
                                Spacer(minLength: 4)
                                Text(verbatim: trailingNote)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        rowDetails
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var rowDetails: some View {
        if !metadata.isEmpty {
            Text(verbatim: metadata)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            Text(verbatim: status)
                .foregroundStyle(color)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
    }
}

struct DecryptLiveSummary: View {
    @ObservedObject private var service = FairPlayHub.shared.service
    @ObservedObject private var records = DecryptRecordStore.shared
    @ObservedObject private var ui = FairPlayPresentation.shared
    @EnvironmentObject private var manager: DownloadManager
    var body: some View {
        if service.isRunning, let id = service.activeRecordID {
            let record = records.records.first(where: { $0.id == id })
            let icon = record.flatMap { ui.iconURL(for: $0, manager: manager) }
            Section("正在处理") {
                NavigationLink(value: PackageRoute.record(id)) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            AppIcon(url: icon, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: PackageStage.displayName(service.sourceName))
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text(verbatim: PackageStage.title(service.step))
                                    .font(.footnote)
                                    .foregroundStyle(UX.tint)
                            }
                            Spacer(minLength: 8)
                            Text("约 \(Int(service.fraction * 100))%")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: service.fraction)
                            .tint(UX.tint)
                            .accessibilityLabel("处理进度")
                            .accessibilityValue("\(Int(service.fraction * 100))%")
                        HStack(spacing: 8) {
                            Text(verbatim: ui.isCancelling
                                 ? AppText.text("将在当前操作安全结束后停止。")
                                 : PackageStage.shortDetail(service.detail))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if ui.canCancel {
                                Text("取消")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.red.opacity(0.12), in: Capsule())
                                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                    .contentShape(Rectangle())
                                    .tactileNavigationTap { ui.cancel() }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel("取消解密")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("packages.running")
            }
        }
    }
}

enum PackageStage {
    static func displayName(_ name: String) -> String {
        if name.count > 37, UUID(uuidString: String(name.prefix(36))) != nil,
           name[name.index(name.startIndex, offsetBy: 36)] == "-" {
            return String(name.dropFirst(37))
        }
        return name
    }

    static func title(_ raw: String) -> String {
        switch raw {
        case "准备中", "解包安装包", "准备解密": return AppText.text("准备安装包")
        case "正在解密": return AppText.text("解密二进制")
        case "重新打包": return AppText.text("重新打包")
        case "校验产物": return AppText.text("校验产物")
        case "正在取消…": return AppText.text("正在取消…")
        case "完成": return AppText.text("完成")
        default: return raw
        }
    }

    static func index(_ raw: String) -> Int? {
        switch raw {
        case "准备中", "解包安装包", "准备解密": return 0
        case "正在解密": return 1
        case "重新打包": return 2
        case "校验产物": return 3
        default: return nil
        }
    }

    static func shortDetail(_ raw: String) -> String {
        // Keep the service's current index (not a success count), shortening
        // only the path. No progress is inferred from diagnostic prose.
        let parts = raw.components(separatedBy: " · ")
        if parts.count == 2 { return parts[0] + " · " + (parts[1] as NSString).lastPathComponent }
        return (raw as NSString).lastPathComponent
    }

    static func detection(_ value: IPADetection?) -> String {
        switch value?.state {
        case .encrypted: return AppText.text("已加密")
        case .plain: return AppText.text("未加密")
        case .unknown: return AppText.text("无法确定加密状态")
        case nil: return AppText.text("尚未检查加密状态")
        }
    }

    static func sourceSummary(checking: Bool, detection: IPADetection?, latest: DecryptRecord?, hasOutput: Bool) -> (text: String, symbol: String, color: Color) {
        if checking {
            return (AppText.text("正在检查…"), "circle.dotted", .secondary)
        }
        let state = Self.detection(detection)
        if let latest {
            let style = DecryptOutcomeStyle(latest)
            if style == .running {
                return (state + " · " + AppText.text("正在解密"), "lock.open", UX.tint)
            }
            if style == .success && hasOutput {
                return (state + " · " + AppText.text("已有解密产物"), "checkmark.circle.fill", .green)
            }
            if style == .partial {
                return (state + " · " + AppText.text("部分成功"), "exclamationmark.triangle.fill", .orange)
            }
            if style == .failed || style == .interrupted {
                return (state + " · " + style.title, "exclamationmark.triangle.fill", .orange)
            }
            if style == .cancelled {
                return (state + " · " + style.title, "xmark.circle", .secondary)
            }
        }
        switch detection?.state {
        case .encrypted:
            return (state, "lock.fill", .primary)
        case .plain:
            return (state, "checkmark.seal", .secondary)
        case .unknown:
            return (state, "questionmark.circle", .orange)
        case nil:
            return (state, "circle.dotted", .secondary)
        }
    }
}
