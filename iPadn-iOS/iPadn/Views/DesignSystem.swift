import SwiftUI
import UIKit

// Visual language modeled on the App Store with the iPadn monochrome accent:
// grouped backgrounds, capsule action buttons, ring progress, large titles.
enum UX {
    static func motion(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9)
    }
    static let tint = Color.accentColor
    static let buttonTint = Color.accentColor
    static let onAccent = Color(uiColor: .systemBackground)
    /// The monochrome accent is near-white in dark mode, which would make an "on" switch
    /// track blend into its white thumb; switch to system green there.
    static let switchTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGreen : (UIColor(named: "AccentColor") ?? .label)
    })
    static let iconCorner: CGFloat = 0.2237
    @MainActor private static let selectionGenerator = UISelectionFeedbackGenerator()
    @MainActor private static let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    @MainActor private static let notificationGenerator = UINotificationFeedbackGenerator()
    @MainActor static func prepare() {
        selectionGenerator.prepare()
        lightImpactGenerator.prepare()
    }
    @MainActor static func feedback() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }
    @MainActor static func tapLight() {
        lightImpactGenerator.impactOccurred(intensity: 0.72)
        lightImpactGenerator.prepare()
    }
    @MainActor static func tapSoft() {
        softImpactGenerator.impactOccurred(intensity: 0.6)
        softImpactGenerator.prepare()
    }
    @MainActor static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }
    @MainActor static func warning() {
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }
}

/// Full-width primary action (App Store sign-in "继续" style).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(configuration.role == .destructive ? Color.white : UX.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background((configuration.role == .destructive ? Color.red : UX.buttonTint).opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .compatibleSnappy(duration: 0.15), value: configuration.isPressed)
            .compatibleOnChange(of: configuration.isPressed) { down in if down { UX.prepare() } }
    }
}
typealias MonochromeButtonStyle = PrimaryButtonStyle

/// System switch with a tint that stays legible in both appearances (see `UX.switchTint`).
struct TintedSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(UX.switchTint)
    }
}

private struct CapsuleAppearanceModifier: ViewModifier {
    let filled: Bool
    let pressed: Bool
    let enabled: Bool
    let suppressesPress: Bool
    let pressScale: CGFloat
    let pressOpacity: Double
    var managesPressAndEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let down = pressed && !suppressesPress
        content
            .environment(\.isEnabled, enabled || suppressesPress)
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            // Capsule labels ("Download", "Get") must never be clipped.
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(filled ? UX.onAccent : UX.tint)
            .padding(.horizontal, 16).frame(minWidth: 74, minHeight: 30)
            .background(filled ? AnyShapeStyle(UX.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
            .opacity(managesPressAndEnabled ? (down ? pressOpacity : enabled || suppressesPress ? 1 : 0.4) : 1)
            .scaleEffect(managesPressAndEnabled && down && !reduceMotion ? pressScale : 1)
            .animation(managesPressAndEnabled && !reduceMotion ? .compatibleSnappy(duration: 0.14) : nil, value: down)
            .contentShape(Capsule())
    }
}

/// Shared touch-down tracker so custom UIKit tap targets highlight on finger-down
/// while cancelling cleanly during list scroll or horizontal swipe gestures.
final class TactileContainerView: UIView {
    var onPressChange: ((Bool) -> Void)?
    private var pressed = false

    private func setPressed(_ down: Bool) {
        guard pressed != down else { return }
        pressed = down
        if down { UX.prepare() }
        onPressChange?(down)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        setPressed(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        setPressed(bounds.insetBy(dx: -12, dy: -12).contains(touch.location(in: self)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        setPressed(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        setPressed(false)
    }
}

private struct TactileTapOverlay: UIViewRepresentable {
    let enabled: Bool
    let onPressChange: (Bool) -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> TactileContainerView {
        let view = TactileContainerView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isAccessibilityElement = false
        view.onPressChange = { [weak coordinator = context.coordinator] down in
            coordinator?.handlePressChange(down)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = true
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: TactileContainerView, context: Context) {
        context.coordinator.parent = self
        uiView.isUserInteractionEnabled = enabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TactileTapOverlay
        init(parent: TactileTapOverlay) { self.parent = parent }

        func handlePressChange(_ down: Bool) {
            parent.onPressChange(down)
        }

        @objc func tapped() {
            guard parent.enabled else { return }
            parent.onTap()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            parent.enabled
        }
    }
}

private struct TactileNavigationTapModifier: ViewModifier {
    let enabled: Bool
    let pressScale: CGFloat
    let pressOpacity: Double
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.revealSuppressesPress) private var suppressesPress
    @State private var pressed = false
    @State private var downAt: CFTimeInterval = 0
    @State private var pulseClearWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        let active = pressed && enabled && !suppressesPress
        content
            .opacity(active ? pressOpacity : (enabled || suppressesPress ? 1 : 0.4))
            .scaleEffect(active && !reduceMotion ? pressScale : 1)
            .animation(reduceMotion ? nil : .compatibleSnappy(duration: 0.14), value: active)
            .overlay {
                TactileTapOverlay(
                    enabled: enabled && !suppressesPress,
                    onPressChange: { down in
                        if down {
                            pulseClearWork?.cancel()
                            pulseClearWork = nil
                            downAt = CACurrentMediaTime()
                            pressed = true
                        } else if pulseClearWork == nil {
                            pressed = false
                        }
                    },
                    onTap: {
                        let elapsed = downAt > 0 ? CACurrentMediaTime() - downAt : 0
                        downAt = 0
                        if !reduceMotion && elapsed < 0.06 {
                            pulseClearWork?.cancel()
                            pressed = true
                            let work = DispatchWorkItem {
                                pulseClearWork = nil
                                pressed = false
                            }
                            pulseClearWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
                        } else {
                            pressed = false
                        }
                        onTap()
                    }
                )
            }
    }
}

extension View {
    /// Scroll-safe, swipe-safe tap control for buttons nested inside a List `NavigationLink`.
    func tactileNavigationTap(enabled: Bool = true, pressScale: CGFloat = 0.94, pressOpacity: Double = 0.72,
                              onTap: @escaping () -> Void) -> some View {
        modifier(TactileNavigationTapModifier(enabled: enabled, pressScale: pressScale, pressOpacity: pressOpacity, onTap: onTap))
    }
}

/// App Store "获取 / 打开" capsule. `filled` is the prominent variant.
struct CapsuleButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.revealSuppressesPress) private var suppressesPress
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && !suppressesPress
        configuration.label
            .modifier(CapsuleAppearanceModifier(filled: filled, pressed: pressed, enabled: enabled,
                                              suppressesPress: suppressesPress, pressScale: 0.94, pressOpacity: 0.72))
            .compatibleOnChange(of: pressed) { down in if down { UX.prepare() } }
    }
}

/// Primary row action pill: native `Button` outside `NavigationLink`, or
/// scroll-safe UIKit tap overlay inside a `NavigationLink` row so tapping
/// "Get" doesn't also push the detail page.
struct RowCapsule: View {
    let title: LocalizedStringKey
    var filled = false
    var enabled = true
    var insideNavigationLink = false
    var haptic = true
    let action: () -> Void
    @Environment(\.revealSuppressesPress) private var suppressesPress
    var body: some View {
        if insideNavigationLink {
            Text(title)
                .modifier(CapsuleAppearanceModifier(filled: filled, pressed: false, enabled: enabled,
                                                  suppressesPress: suppressesPress, pressScale: 1, pressOpacity: 1,
                                                  managesPressAndEnabled: false))
                .tactileNavigationTap(enabled: enabled) {
                    if haptic { UX.tapLight() }
                    action()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(title)
                .accessibilityAction {
                    if enabled {
                        if haptic { UX.tapLight() }
                        action()
                    }
                }
        } else {
            Button {
                if haptic { UX.tapLight() }
                action()
            } label: {
                Text(title)
            }
            .buttonStyle(CapsuleButtonStyle(filled: filled))
            .disabled(!enabled)
            .accessibilityLabel(title)
        }
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

/// The ring while a finished download is checked and prepared: an arc that
/// keeps turning on the same track, so the ring never disappears mid-task.
struct SpinningRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
            Circle().trim(from: 0, to: 0.28)
                .stroke(UX.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(turning ? 270 : -90))
                .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
        }
        .frame(width: 30, height: 30)
        .padding(7)
        .onAppear { turning = true }
    }
}

/// Telegram's finished state: the ring closes and a check draws inside it.
struct CompletionRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring: CGFloat = 0.28
    @State private var check: CGFloat = 0
    @State private var pop: CGFloat = 1
    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
            Circle().trim(from: 0, to: ring)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape().trim(from: 0, to: check)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 10)
        }
        .frame(width: 30, height: 30)
        .scaleEffect(pop)
        .padding(7)
        .onAppear {
            guard !reduceMotion else { ring = 1; check = 1; return }
            withAnimation(.easeOut(duration: 0.25)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.2).delay(0.2)) { check = 1 }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5).delay(0.35)) { pop = 1.12 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.5)) { pop = 1 }
        }
        .accessibilityLabel("下载完成")
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
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
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String
    var actionTitle: LocalizedStringKey? = nil
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
    /// Already in its final language: service errors and store state arrive as text.
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

/// In-list search field. `capsule` is the App Store search-tab bar: a
/// full-width pill that searches from the keyboard's Search key.
struct SearchInput: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var capsule = false
    var submit: (() -> Void)? = nil
    var clear: (() -> Void)? = nil
    @FocusState private var focused: Bool
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($focused)
                .onSubmit { focused = false; if !trimmed.isEmpty { submit?() } }
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = ""; clear?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 32, height: 32) }
                    .buttonStyle(.borderless).accessibilityLabel("清空输入")
            }
            if submit != nil && !capsule {
                Button { focused = false; submit?() } label: { Text("搜索").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.borderless)
                    .disabled(trimmed.isEmpty)
                    .accessibilityLabel("搜索应用").accessibilityIdentifier("search.submit")
            }
        }
        .padding(.leading, capsule ? 14 : 10).padding(.trailing, capsule ? 6 : 8)
        .frame(minHeight: capsule ? 44 : 40)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: capsule ? 22 : 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// A section header's 刷新 that turns into a small spinner while busy, in
/// the same place, so nothing around it moves. Taps while busy are ignored.
struct RefreshButton: View {
    let busy: Bool
    let action: () -> Void
    @State private var showsSpinner = false
    var body: some View {
        ZStack(alignment: .trailing) {
            Button("刷新") { if !busy { action() } }
                .font(.body).textCase(nil)
                .opacity(showsSpinner ? 0 : 1)
            if showsSpinner { ProgressView().controlSize(.small).transition(.opacity) }
        }
        .revealAfterDelay(busy, into: $showsSpinner)
        .accessibilityValue(busy ? "正在刷新" : "")
    }
}

/// Root-tab chrome that pairs with `PageHeader`. The navigation bar stays
/// visible (hiding it made the page jump when popping back from a pushed
/// page); it shows the small title only once the header has scrolled away.
struct RootTabBar: ViewModifier {
    let title: LocalizedStringKey
    let headerScrolledAway: Bool
    func body(content: Content) -> some View {
        content
            .compatibleVerticalContentMargin(.top, 0)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.headline)
                        .opacity(headerScrolledAway ? 1 : 0)
                        .animation(.easeInOut(duration: 0.18), value: headerScrolledAway)
                        .accessibilityHidden(!headerScrolledAway)
                }
            }
    }
}
extension View {
    /// Sets `shown` once `active` has lasted a moment and clears it as soon
    /// as it ends, so quick work (a cache hit) never flashes a spinner.
    func revealAfterDelay(_ active: Bool, into shown: Binding<Bool>, delay: Duration = .milliseconds(300)) -> some View {
        task(id: active) {
            guard active else {
                if shown.wrappedValue { withAnimation(.easeOut(duration: 0.15)) { shown.wrappedValue = false } }
                return
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) { shown.wrappedValue = true }
        }
    }
    func rootTabBar(_ title: LocalizedStringKey, headerScrolledAway: Bool) -> some View {
        modifier(RootTabBar(title: title, headerScrolledAway: headerScrolledAway))
    }
    /// Reports whether this view has scrolled up under the navigation bar.
    func onScrolledUnderBar(_ action: @escaping (Bool) -> Void) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .global).maxY < 104
        } action: { action($0) }
    }
}

/// App Store root-tab header: large title with the trailing control (the
/// account avatar) on the same line, instead of a separate toolbar row.
struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.largeTitle.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}
extension PageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey) { self.init(title: title) { EmptyView() } }
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
        // Not a Label: inside List rows a Label gets the list's icon column,
        // which leaves a wide gap between the glyph and the text.
        HStack(spacing: 4) {
            Image(systemName: status.symbol).imageScale(.small).accessibilityHidden(true)
            Text(status.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// Small outlined capsule for platform and state tags (iOS, 已下架…).
struct TagBadge: View {
    let text: LocalizedStringKey
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(nil)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
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
    let caption: LocalizedStringKey
    /// Store data (version, size, category): already in its final language.
    let value: String
    var detail: String? = nil
    var symbol: String? = nil
    var body: some View {
        VStack(spacing: 4) {
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.title3.weight(.semibold))
                } else {
                    Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(.secondary)
            .frame(height: 26)
            Text(detail ?? (symbol == nil ? " " : value)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
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
                .compatibleOnChange(of: code) { value in
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
        .compatibleOnChange(of: disabled) { value in if !value { focused = true } }
    }
}

struct ToolPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground)).scrollDismissesKeyboard(.interactively)
            .compatibleListSectionSpacing(20)
            .compatibleVerticalContentMargin(.bottom, 20)
    }
}
extension View { func toolPage() -> some View { modifier(ToolPageStyle()) } }

/// One line of text that, when it does not fit, scrolls once in place to
/// reveal the rest and returns, instead of being cut off with an ellipsis.
struct MarqueeText: View {
    let text: String
    var font: Font = .subheadline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    private var overflow: CGFloat { max(0, textWidth - boxWidth) }
    var body: some View {
        // The hidden copy sets the line height and takes the available width.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(text).font(font).lineLimit(1).fixedSize()
                    .offset(x: offset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    if overflow > 0 {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
            .task(id: overflow) {
                offset = 0
                guard overflow > 1, !reduceMotion else { return }
                do {
                    try await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeInOut(duration: max(0.8, Double(overflow) / 35))) { offset = -overflow - 14 }
                    try await Task.sleep(for: .milliseconds(Int(max(0.8, Double(overflow) / 35) * 1000) + 1200))
                    withAnimation(.easeInOut(duration: 0.45)) { offset = 0 }
                } catch { offset = 0 }
            }
    }
}

extension AnyTransition {
    /// Replaces a status label or button without the old and new content
    /// being visible at the same time: the old one fades out quickly, then
    /// the new one fades and scales in.
    static var statusSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.92))
                .animation(.easeOut(duration: 0.18).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
}

extension Animation {
    static var compatibleSnappy: Animation {
        if #available(iOS 17, *) { return .snappy }
        return compatibleSnappy(duration: 0.5)
    }
    static func compatibleSnappy(duration: Double) -> Animation {
        if #available(iOS 17, *) { return .snappy(duration: duration) }
        return .spring(response: duration, dampingFraction: 0.85)
    }
}

extension View {
    @ViewBuilder func compatibleSymbolReplacement() -> some View {
        if #available(iOS 17, *) { contentTransition(.symbolEffect(.replace)) }
        else { contentTransition(.opacity) }
    }
    @ViewBuilder func compatibleSelectionFeedback<T: Equatable>(trigger: T) -> some View {
        if #available(iOS 17, *) { sensoryFeedback(.selection, trigger: trigger) }
        else { onChange(of: trigger) { _ in UX.feedback() } }
    }
    @ViewBuilder func compatiblePresentationCornerRadius(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) { presentationCornerRadius(radius) }
        else { self }
    }
    @ViewBuilder func compatibleListSectionSpacing(_ spacing: CGFloat) -> some View {
        if #available(iOS 17, *) { listSectionSpacing(spacing) }
        else { self }
    }
    @ViewBuilder func compatibleVerticalContentMargin(_ edge: Edge.Set, _ length: CGFloat) -> some View {
        if #available(iOS 17, *) { contentMargins(edge, length, for: .scrollContent) }
        else if edge == .bottom {
            safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: length).allowsHitTesting(false) }
        } else { self }
    }
    @ViewBuilder func compatibleScrollTargetLayout() -> some View {
        if #available(iOS 17, *) { scrollTargetLayout() }
        else { self }
    }
    @ViewBuilder func compatibleViewAlignedScrolling() -> some View {
        if #available(iOS 17, *) { scrollTargetBehavior(.viewAligned) }
        else { self }
    }
}

/// The reveal animation needs independently animated top and bottom radii.
/// Native continuous corners are retained on iOS 17; iOS 16 uses circular arcs.
struct CompatibleCardShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        if #available(iOS 17, *) {
            return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous).path(in: rect)
        }
        let limit = max(0, min(rect.width, rect.height) / 2)
        let t = min(max(0, top), limit), b = min(max(0, bottom), limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - t, y: rect.minY + t), radius: t,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        path.addArc(center: CGPoint(x: rect.maxX - b, y: rect.maxY - b), radius: b,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + b, y: rect.maxY - b), radius: b,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        path.addArc(center: CGPoint(x: rect.minX + t, y: rect.minY + t), radius: t,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

extension ToolbarItemPlacement {
    static var compatibleTopBarLeading: Self {
        if #available(iOS 17, *) { return .topBarLeading }
        return .navigationBarLeading
    }

    static var compatibleTopBarTrailing: Self {
        if #available(iOS 17, *) { return .topBarTrailing }
        return .navigationBarTrailing
    }
}

extension View {
    @ViewBuilder func compatibleOnChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17, *) { onChange(of: value) { _, newValue in action(newValue) } }
        else { onChange(of: value, perform: action) }
    }

    @ViewBuilder func compatibleNavigationDestination<Item: Hashable, Destination: View>(
        item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17, *) {
            navigationDestination(item: item, destination: destination)
        } else {
            navigationDestination(isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            )) {
                if let value = item.wrappedValue { destination(value) }
            }
        }
    }

    @ViewBuilder func compatibleInteractionShape<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 17, *) { contentShape([.interaction, .accessibility], shape) }
        else { contentShape(.interaction, shape) }
    }

    @ViewBuilder func compatibleScrollBounce() -> some View {
        if #available(iOS 16.4, *) { scrollBounceBehavior(.basedOnSize) }
        else { self }
    }

    /// Digits roll down as a countdown ticks, like Telegram's undo timer.
    @ViewBuilder func compatibleCountdownTransition() -> some View {
        if #available(iOS 17, *) { contentTransition(.numericText(countsDown: true)) }
        else { contentTransition(.numericText()) }
    }

    @ViewBuilder func compatibleNumericTransition() -> some View {
        contentTransition(.numericText())
    }

    @ViewBuilder func compatibleBounce(trigger: some Equatable) -> some View {
        if #available(iOS 17, *) { symbolEffect(.bounce, value: trigger) }
        else { self }
    }

    @ViewBuilder func compatibleHorizontalScrollMargins(_ margin: CGFloat) -> some View {
        if #available(iOS 17, *) { contentMargins(.horizontal, margin, for: .scrollContent) }
        else { self }
    }

    @ViewBuilder func legacyHorizontalPadding(_ margin: CGFloat) -> some View {
        if #available(iOS 17, *) { self }
        else { padding(.horizontal, margin) }
    }
}

/// Places views left to right and wraps to a new line when one doesn't fit,
/// like tags (recent searches).
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current); current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A capsule chip whose long-press menu lifts only the chip, keeping its round
/// ends. SwiftUI's own context menu inside a List lifts the whole row as a
/// square-cornered rectangle, so the menu comes from UIKit here.
struct MenuChip: UIViewRepresentable {
    let title: String
    let symbol: String
    let identifier: String
    let deleteTitle: String
    let onTap: () -> Void
    let onDelete: () -> Void

    struct Label: View {
        let title: String
        let symbol: String
        var pressed = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                Text(verbatim: title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 38)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            .opacity(pressed ? 0.72 : 1)
            .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .compatibleSnappy(duration: 0.14), value: pressed)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TactileContainerView {
        let host = UIHostingController(rootView: Label(title: title, symbol: symbol))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        context.coordinator.host = host
        let view = TactileContainerView()
        view.backgroundColor = .clear
        view.onPressChange = { [weak coordinator = context.coordinator] down in
            coordinator?.setPressed(down)
        }
        host.view.frame = view.bounds
        view.addSubview(host.view)
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        update(view, context: context)
        return view
    }

    func updateUIView(_ view: TactileContainerView, context: Context) {
        context.coordinator.chip = self
        context.coordinator.host?.rootView = Label(title: title, symbol: symbol, pressed: context.coordinator.pressed)
        update(view, context: context)
    }

    private func update(_ view: UIView, context: Context) {
        view.accessibilityLabel = title
        view.accessibilityIdentifier = identifier
        let coordinator = context.coordinator
        view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: deleteTitle) { _ in
            coordinator.chip.onDelete(); return true
        }]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TactileContainerView, context: Context) -> CGSize? {
        context.coordinator.host?.sizeThatFits(in: CGSize(width: proposal.width ?? .greatestFiniteMagnitude,
                                                          height: .greatestFiniteMagnitude))
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var chip: MenuChip
        var host: UIHostingController<Label>?
        var pressed = false
        init(_ chip: MenuChip) { self.chip = chip }

        func setPressed(_ down: Bool) {
            guard pressed != down else { return }
            pressed = down
            host?.rootView = Label(title: chip.title, symbol: chip.symbol, pressed: down)
        }

        @objc func tapped() {
            setPressed(false)
            UX.tapSoft()
            chip.onTap()
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                return UIMenu(children: [
                    UIAction(title: self.chip.deleteTitle, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                        self?.chip.onDelete()
                    },
                ])
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            UIView.performWithoutAnimation { setPressed(false) }
            return preview(interaction)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            preview(interaction)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            setPressed(false)
        }

        private func preview(_ interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view, let window = view.window else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: view.bounds.height / 2)
            // No drop shadow around the lifted chip.
            parameters.shadowPath = UIBezierPath()
            // Lift it in the window: the list cell clips the enlarged chip at its edge.
            let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
            return UITargetedPreview(view: view, parameters: parameters, target: UIPreviewTarget(container: window, center: center))
        }
    }
}
