import ActivityKit
import SwiftUI
import WidgetKit

private extension DownloadActivityAttributes.ContentState {
    private static let byteFormatter: ByteCountFormatter = {
        let style = ByteCountFormatter()
        style.countStyle = .file
        return style
    }()

    var title: String {
        switch phase {
        case 0: return String(localized: "正在下载")
        case 1: return String(localized: "正在准备安装包")
        case 2: return String(localized: "下载完成")
        case 4: return String(localized: "正在安装")
        case 5: return String(localized: "已安装")
        case 6: return String(localized: "安装未完成")
        case 7: return String(localized: "已暂停")
        case 8: return String(localized: "下载失败")
        default: return String(localized: "等待下载")
        }
    }
    var finished: Bool { phase == 2 || phase == 5 }
    var failed: Bool { phase == 6 || phase == 8 }
    var paused: Bool { phase == 7 }
    /// Nothing more to show moving: done or failed.
    var ended: Bool { finished || failed }
    var fraction: Double {
        guard expected > 0 else { return finished ? 1 : 0 }
        return min(1, max(0, Double(written) / Double(expected)))
    }
    /// The bar's interval: it shows `fraction` at `updated` and reaches the
    /// end at `estimatedEnd`, so it moves on its own between updates.
    var interval: ClosedRange<Date>? {
        guard phase == 0, let end = estimatedEnd, end > updated, fraction < 1 else { return nil }
        let start = end.addingTimeInterval(-end.timeIntervalSince(updated) / (1 - fraction))
        return start...end
    }
    var bytes: String {
        if phase == 6 { return String(localized: "回到 \("iPadn") 继续安装") }
        if phase == 8 { return String(localized: "回到 \("iPadn") 查看或重试") }
        guard phase != 4, phase != 5 else { return "" }
        let volume: String
        if expected > 0 {
            volume = Self.byteFormatter.string(fromByteCount: written) + " / " + Self.byteFormatter.string(fromByteCount: expected)
        } else if written > 0 {
            volume = Self.byteFormatter.string(fromByteCount: written)
        } else {
            volume = ""
        }
        guard phase == 0, speed > 0 else { return volume }
        let rate = Self.byteFormatter.string(fromByteCount: speed) + "/s"
        return volume.isEmpty ? rate : volume + " · " + rate
    }
    var others: String? { count > 1 ? String(localized: "另有 \(count - 1) 个任务") : nil }
    var tint: Color { failed ? .orange : finished ? .green : paused ? .secondary : .accentColor }
    /// What is happening, at a glance in the compact Dynamic Island.
    var symbol: String {
        switch phase {
        case 0: return "arrow.down"
        case 1: return "shippingbox.fill"
        case 2, 5: return "checkmark"
        case 4: return "arrow.down.app.fill"
        case 6, 8: return "exclamationmark"
        case 7: return "pause.fill"
        default: return "clock.fill"
        }
    }
    /// A word or a percentage beside it.
    var short: String {
        switch phase {
        case 0, 4: return fraction.formatted(.percent.precision(.fractionLength(0)))
        case 1: return String(localized: "准备中")
        case 2: return String(localized: "完成")
        case 5: return String(localized: "已安装")
        case 6: return String(localized: "未完成")
        case 7: return expected > 0 ? fraction.formatted(.percent.precision(.fractionLength(0))) : String(localized: "已暂停")
        case 8: return String(localized: "失败")
        default: return String(localized: "等待")
        }
    }
}

private struct DownloadBar: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        Group {
            if let interval = state.interval {
                ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: state.fraction)
            }
        }
        .tint(state.tint)
    }
}

private struct DownloadRing: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        Group {
            if state.failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            } else if state.finished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if state.paused {
                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            } else if let interval = state.interval {
                ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
            } else {
                ProgressView(value: state.fraction).progressViewStyle(.circular)
            }
        }
        .tint(state.tint)
        .frame(width: 20, height: 20)
    }
}

/// Time left while downloading, otherwise the state in a word or two.
private struct DownloadTrailing: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        if let interval = state.interval, interval.upperBound > .now {
            Text(timerInterval: Date.now...interval.upperBound, countsDown: true)
                .monospacedDigit().multilineTextAlignment(.trailing)
        } else if state.phase == 0 || state.phase == 4 || (state.paused && state.expected > 0) {
            Text(state.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
        } else {
            Text(state.phase == 8 ? String(localized: "失败") : state.failed ? String(localized: "未完成") : state.finished ? String(localized: "完成") : state.paused ? String(localized: "已暂停") : state.phase == 1 ? String(localized: "准备中") : String(localized: "等待"))
        }
    }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            let state = context.state
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AppMarkView(size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.isStale && !state.ended && !state.paused ? String(localized: "已暂停更新") : state.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(state.name).font(.headline).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    DownloadTrailing(state: state).font(.subheadline.weight(.semibold)).frame(maxWidth: 80, alignment: .trailing)
                }
                if !state.ended { DownloadBar(state: state) }
                HStack {
                    Text(state.bytes)
                    Spacer()
                    if let others = state.others { Text(others) }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(16)
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AppMarkView(size: 34).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DownloadTrailing(state: state).font(.headline).foregroundStyle(state.tint)
                        .frame(maxWidth: 76, alignment: .trailing).padding(.trailing, 4).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(context.isStale && !state.ended && !state.paused ? String(localized: "已暂停更新") : state.title).font(.caption).foregroundStyle(.secondary)
                        Text(state.name).font(.headline).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if !state.ended { DownloadBar(state: state) }
                        HStack {
                            Text(state.bytes)
                            Spacer()
                            if let others = state.others { Text(others) }
                        }
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                AppMarkView(size: 22)
            } compactTrailing: {
                // The step (downloading, installing, done) and how far it is.
                HStack(spacing: 3) {
                    Image(systemName: state.symbol).font(.caption2.weight(.bold))
                    Text(state.short).font(.caption.weight(.semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .foregroundStyle(state.tint)
                .frame(maxWidth: 64)
            } minimal: {
                DownloadRing(state: state)
            }
            .keylineTint(state.tint)
        }
    }
}
