import SwiftUI
import UIKit

enum UX {
    static let tint = Color.accentColor
    static let buttonTint = Color.accentColor
    static let onAccent = Color(uiColor: .systemBackground)
    static func feedback() { UISelectionFeedbackGenerator().selectionChanged() }
}

struct MonochromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(UX.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(UX.buttonTint.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        Image("BrandMark").resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22)).accessibilityHidden(true)
    }
}

struct PageIntro: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if eyebrow == "iPadn" {
                    HStack(spacing: 10) { BrandMark(size: 32); Text("iPadn").font(.headline.weight(.semibold)) }
                } else { Label(eyebrow, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                Spacer()
            }
            Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 12).accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 76, height: 76).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(MonochromeButtonStyle()).controlSize(.large)
            }
        }.padding(.vertical, 28).frame(maxWidth: .infinity).padding(.horizontal, 12)
    }
}

struct InlineIssue: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("暂时未能完成", systemImage: "exclamationmark.circle.fill").font(.subheadline.bold()).foregroundStyle(.primary)
            Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let retry { Button("重新尝试", systemImage: "arrow.clockwise", action: retry).buttonStyle(.bordered).controlSize(.regular) }
        }.padding(.vertical, 6)
    }
}

struct SearchInput: View {
    @Binding var text: String
    var placeholder: String
    var submit: (() -> Void)? = nil
    var clear: (() -> Void)? = nil
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($focused).onSubmit { focused = false; submit?() }
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = ""; clear?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).accessibilityLabel("清空输入")
            }
        }.padding(.leading, 14).padding(.trailing, 2).frame(minHeight: 52)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StatCell: View {
    let value: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(.title2, design: .rounded, weight: .bold)).contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

struct TaskStatusPill: View {
    let status: DownloadStatus
    private var color: Color { status == .paused ? .secondary : .primary }
    var body: some View {
        Label(status.title, systemImage: status.symbol).font(.caption.weight(.medium))
            .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct AppSkeleton: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14).fill(Color(.tertiarySystemFill)).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 150, height: 13)
                RoundedRectangle(cornerRadius: 4).fill(Color(.quaternarySystemFill)).frame(width: 100, height: 10)
            }
        }.padding(.vertical, 6).accessibilityHidden(true)
    }
}

struct ToolPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground)).scrollDismissesKeyboard(.interactively)
    }
}
extension View { func toolPage() -> some View { modifier(ToolPageStyle()) } }
