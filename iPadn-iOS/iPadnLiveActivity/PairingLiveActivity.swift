import ActivityKit
import SwiftUI
import WidgetKit

@main
struct iPadnLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        PairingLiveActivity()
        DownloadLiveActivity()
        ShortcutsWidget()
    }
}

private extension PairingActivityAttributes.ContentState {
    var title: String {
        switch step {
        case 1: return String(localized: "打开「设置」")
        case 2: return String(localized: "正在配对")
        case 3: return String(localized: "输入配对码")
        case 4: return String(localized: "配对完成")
        default: return String(localized: "配对未完成")
        }
    }
    func detail(host: String) -> String {
        switch step {
        case 1: return String(localized: "隐私与安全性 › 开发者模式 › 与 \(host) 配对")
        case 2: return String(localized: "设备已连接，正在生成配对码")
        case 3: return String(localized: "在「设置」中输入下面的配对码")
        case 4: return String(localized: "回到 \(host) 继续安装")
        default: return message ?? String(localized: "回到 \(host) 重试")
        }
    }
    var symbol: String {
        switch step {
        case 1: return "gear"
        case 2: return "iphone.radiowaves.left.and.right"
        case 3: return "number"
        case 4: return "checkmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch step {
        case 4: return .green
        case 0: return .orange
        default: return .blue
        }
    }
}

/// The code split into two groups of three, as Settings shows it.
private struct CodeText: View {
    let code: String
    var size: CGFloat
    var body: some View {
        let digits = Array(code)
        let text = digits.count == 6 ? String(digits[0..<3]) + " " + String(digits[3...]) : code
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

/// Steps 1 to 3 as dots, so the user sees how far along they are.
private struct StepDots: View {
    let step: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...3, id: \.self) { index in
                Capsule()
                    .fill(index <= step || step == 4 ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: index == step ? 16 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

struct PairingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            let state = context.state
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AppMarkView(size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPadn · " + state.title).font(.headline)
                        Label(state.detail(host: context.attributes.hostName), systemImage: state.symbol)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    StepDots(step: state.step)
                }
                if let code = state.code, state.step == 3 {
                    CodeText(code: code, size: 40).frame(maxWidth: .infinity)
                }
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
                    StepDots(step: state.step).padding(.trailing, 4).padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    Label(state.title, systemImage: state.symbol).font(.headline).foregroundStyle(state.tint).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let code = state.code, state.step == 3 {
                            CodeText(code: code, size: 36)
                        }
                        Text(state.detail(host: context.attributes.hostName))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                    }
                }
            } compactLeading: {
                AppMarkView(size: 22)
            } compactTrailing: {
                if let code = state.code, state.step == 3 {
                    CodeText(code: code, size: 15).foregroundStyle(state.tint)
                } else {
                    Text(state.step == 4 ? String(localized: "完成") : "\(min(max(state.step, 1), 3))/3").font(.caption.weight(.semibold))
                }
            } minimal: {
                AppMarkView(size: 22)
            }
            .keylineTint(state.tint)
        }
    }
}
