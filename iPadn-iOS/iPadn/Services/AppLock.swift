import LocalAuthentication
import SwiftUI
import UIKit

/// Face ID, Touch ID or the device passcode in front of iPadn (Settings ›
/// App Lock). The lock screen is its own window above everything, sheets
/// included, and also hides the app in the app switcher.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    enum Method { case faceID, touchID, passcode, unavailable }

    /// How this device can confirm its owner.
    static var method: Method {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return .unavailable }
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .passcode
        }
    }

    static var unlockTitle: LocalizedStringKey {
        switch method {
        case .faceID: return "使用面容 ID 解锁"
        case .touchID: return "使用触控 ID 解锁"
        default: return "使用密码解锁"
        }
    }

    @Published private(set) var locked = false
    /// The system prompt makes the scene inactive; that is not leaving the app.
    private var authenticating = false
    private var leftAt: Date?
    private var window: UIWindow?
    private var enabled = false
    private var delay: TimeInterval = 0
    private var appearance = "system"

    /// Called with the settings at launch and whenever they change.
    func configure(enabled: Bool, delay: Int, appearance: String, launching: Bool) {
        self.enabled = enabled
        self.delay = TimeInterval(max(0, delay))
        self.appearance = appearance
        if !enabled { locked = false }
        else if launching { locked = true }
        updateCover(active: true)
        window?.overrideUserInterfaceStyle = style
    }

    func sceneChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            if leftAt == nil { leftAt = Date() }
            updateCover(active: false)
        case .inactive:
            updateCover(active: false)
        case .active:
            // Only a return from the background asks again: the scene also
            // turns active when a cancelled prompt goes away.
            guard let left = leftAt else { updateCover(active: true); return }
            leftAt = nil
            if enabled, Date().timeIntervalSince(left) >= delay { locked = true }
            updateCover(active: true)
            if locked { Task { await unlock() } }
        @unknown default: break
        }
    }

    /// Asks for Face ID, Touch ID or the passcode.
    func authenticate(reason: String) async -> Bool {
        guard !authenticating else { return false }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    #if DEBUG
    /// Screenshots of the lock screen without asking anyone to authenticate.
    func showPreview() { locked = true }
    #endif

    func unlock() async {
        guard locked, UIApplication.shared.applicationState == .active else { return }
        if await authenticate(reason: AppText.text("解锁 iPadn")) {
            locked = false
            updateCover(active: true)
        }
    }

    private var style: UIUserInterfaceStyle {
        switch appearance { case "light": return .light; case "dark": return .dark; default: return .unspecified }
    }

    private func updateCover(active: Bool) {
        let visible = enabled && (locked || (!active && !authenticating))
        if visible, window == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = .alert + 1
            cover.overrideUserInterfaceStyle = style
            let host = UIHostingController(rootView: AppLockScreen(lock: self))
            host.view.backgroundColor = .systemBackground
            cover.rootViewController = host
            cover.makeKeyAndVisible()
            window = cover
        } else if !visible, let cover = window {
            window = nil
            cover.isHidden = true
            cover.windowScene?.windows.first { $0 !== cover && !$0.isHidden }?.makeKey()
        }
    }
}

struct AppLockScreen: View {
    @ObservedObject var lock: AppLock
    @Environment(\.colorScheme) private var colorScheme
    @State private var shown = false
    /// The icon the Home Screen shows: its style, and its light or dark look.
    private let icon = AppIconService().current
    private var brand: String { icon.style.preview }
    private var iconScheme: ColorScheme {
        switch icon.theme {
        case .light: return .light
        case .dark: return .dark
        case .automatic: return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
    }
    private var symbol: String {
        switch AppLock.method {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open.fill"
        }
    }
    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 18) {
                    Image(brand).resizable().scaledToFit().frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 92 * UX.iconCorner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 92 * UX.iconCorner, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .environment(\.colorScheme, iconScheme)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 22, y: 10)
                        .accessibilityHidden(true)
                    Text(verbatim: "iPadn").font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Label("已锁定", systemImage: "lock.fill")
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                }
                .scaleEffect(shown ? 1 : 0.94).opacity(shown ? 1 : 0)
                Spacer()
                if lock.locked {
                    Button { Task { await lock.unlock() } } label: {
                        VStack(spacing: 12) {
                            Image(systemName: symbol).font(.system(size: 34, weight: .regular))
                                .frame(width: 76, height: 76)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                            Text(AppLock.unlockTitle).font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("appLock.unlock")
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 56)
        }
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { shown = true } }
    }

    /// A quiet wash of grey with the brand mark blurred far behind.
    private var background: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: [Color(.secondarySystemBackground), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
            Image(brand).resizable().scaledToFit().frame(width: 420, height: 420)
                .environment(\.colorScheme, iconScheme)
                .blur(radius: 90).opacity(colorScheme == .dark ? 0.35 : 0.12)
                .offset(y: -120)
        }
        .ignoresSafeArea()
    }
}
