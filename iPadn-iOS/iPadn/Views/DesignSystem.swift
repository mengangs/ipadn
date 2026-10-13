import SwiftUI
import UIKit

// Visual language modeled on the App Store: system blue accent, grouped
// backgrounds, capsule action buttons, ring progress and large titles.
enum UX {
    static let tint = Color.accentColor
    static let buttonTint = Color.accentColor
    static let onAccent = Color.white
    static let iconCorner: CGFloat = 0.2237
    static func feedback() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// Full-width primary action (App Store sign-in "继续" style).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(UX.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(UX.buttonTint.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
    }
}
typealias MonochromeButtonStyle = PrimaryButtonStyle

/// App Store "获取 / 打开" capsule. `filled` is the prominent variant.
struct CapsuleButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(filled ? UX.onAccent : UX.tint)
            .padding(.horizontal, 16).frame(minWidth: 74, minHeight: 30)
            .background(filled ? AnyShapeStyle(UX.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Capsule action inside a navigable List row. A Button there would be
/// swallowed by the row's link, so it uses a high-priority tap instead.
struct RowCapsule: View {
    let title: String
    var filled = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold)).lineLimit(1)
            .foregroundStyle(filled ? UX.onAccent : UX.tint)
            .padding(.horizontal, 16).frame(minWidth: 74, minHeight: 30)
            .background(filled ? AnyShapeStyle(UX.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .highPriorityGesture(TapGesture().onEnded { if enabled { action() } })
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityAction { if enabled { action() } }
    }
}

/// App Store download progress: a ring with a stop/pause glyph.
struct ProgressRing: View {
    var progress: Double?
    var symbol = "pause.fill"
    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
            if let progress {
                Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(UX.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
            }
            if progress == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(UX.tint)
            }
        }
        .frame(width: 30, height: 30)
        .padding(7)
        .contentShape(Circle())
    }
}

struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        Image("BrandMark").resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * UX.iconCorner, style: .continuous)).accessibilityHidden(true)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(CapsuleButtonStyle()).padding(.top, 8)
            }
        }.padding(.vertical, 28).frame(maxWidth: .infinity).padding(.horizontal, 12)
    }
}

struct InlineIssue: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let retry { Button("重试", action: retry).buttonStyle(CapsuleButtonStyle()) }
            }
        }.padding(.vertical, 6)
    }
}

/// In-list search field (used where the navigation search bar is not).
struct SearchInput: View {
    @Binding var text: String
    var placeholder: String
    var submit: (() -> Void)? = nil
    var clear: (() -> Void)? = nil
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($focused).onSubmit { focused = false; submit?() }
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = ""; clear?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 36, height: 36) }
                    .buttonStyle(.borderless).accessibilityLabel("清空输入")
            }
            if let submit {
                Button { focused = false; submit() } label: { Text("搜索").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("搜索应用").accessibilityIdentifier("search.submit")
            }
        }.padding(.leading, 10).padding(.trailing, 8).frame(minHeight: 40)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct TaskStatusPill: View {
    let status: DownloadStatus
    private var color: Color {
        switch status {
        case .failed: return .red
        case .completed: return .green
        case .paused: return .secondary
        default: return UX.tint
        }
    }
    var body: some View {
        Label(status.title, systemImage: status.symbol).font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

struct AppSkeleton: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemFill)).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 150, height: 13)
                RoundedRectangle(cornerRadius: 4).fill(Color(.quaternarySystemFill)).frame(width: 100, height: 10)
            }
            Spacer()
            Capsule().fill(Color(.tertiarySystemFill)).frame(width: 74, height: 30)
        }.padding(.vertical, 6).accessibilityHidden(true)
    }
}

/// One cell of the App Store product page's horizontal info strip.
struct InfoStripItem: View {
    let caption: String
    let value: String
    var detail: String? = nil
    var symbol: String? = nil
    var body: some View {
        VStack(spacing: 5) {
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).lineLimit(1)
            if let symbol {
                Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text(value).font(.title3.weight(.bold)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(detail ?? (symbol == nil ? " " : value)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 88)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Six separate digit boxes like Apple's two-factor screen. Backed by one
/// hidden one-time-code field so paste and SMS/AutoFill keep working.
struct VerificationCodeField: View {
    @Binding var code: String
    var length = 6
    var disabled = false
    var onComplete: (String) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .disabled(disabled)
                .foregroundStyle(.clear).tint(.clear)
                .frame(width: 1, height: 1).opacity(0.02)
                .accessibilityIdentifier("apple.verification.code")
                .onChange(of: code) { _, value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(length))
                    if digits != value { code = digits; return }
                    if digits.count == length { onComplete(digits) }
                }
            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in
                    let characters = Array(code)
                    let current = index == characters.count && focused
                    Text(index < characters.count ? String(characters[index]) : "")
                        .font(.title.monospacedDigit().weight(.semibold))
                        .frame(width: 44, height: 56)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(current ? UX.tint : Color(.separator), lineWidth: current ? 2 : 0.5))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("验证码，已输入 \(code.count) 位")
        }
        .onAppear { if !disabled { focused = true } }
        .onChange(of: disabled) { _, value in if !value { focused = true } }
    }
}

struct ToolPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground)).scrollDismissesKeyboard(.interactively)
            .listSectionSpacing(20)
    }
}
extension View { func toolPage() -> some View { modifier(ToolPageStyle()) } }
