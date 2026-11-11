import UIKit
import Combine

@MainActor
final class AppIconService: ObservableObject {
    /// Icon style.
    enum Choice: String, CaseIterable, Identifiable {
        case dimensional, flat
        var id: String { rawValue }
        var title: String { self == .dimensional ? AppText.text("立体图标") : AppText.text("扁平图标") }
        var preview: String { self == .dimensional ? "BrandMark" : "FlatBrandMark" }
    }
    /// Light or dark icon: following the system appearance (iOS 18), or fixed.
    enum Theme: String, CaseIterable, Identifiable {
        case automatic, light, dark
        var id: String { rawValue }
        var title: String { self == .automatic ? AppText.text("跟随系统") : self == .light ? AppText.text("浅色") : AppText.text("深色") }
    }
    struct Selection: Equatable {
        var style: Choice
        var theme: Theme
        /// nil is the primary icon (立体, dark).
        var alternateName: String? {
            switch (style, theme) {
            case (.dimensional, .dark): return nil
            case (.dimensional, .automatic): return "AppIconAuto"
            case (.flat, .automatic): return "AppIconFlat"
            case (_, .light): return style == .flat ? "AppIconFlatLight" : "AppIconLight"
            case (.flat, .dark): return "AppIconFlatDark"
            }
        }
    }

    static let primary = Selection(style: .dimensional, theme: .dark)
    @Published private(set) var current = AppIconService.primary
    var selected: Choice { current.style }
    var theme: Theme { current.theme }
    @Published private(set) var changing = false
    @Published private(set) var awaitingSystem: Selection?
    @Published private(set) var statusHint: String?

    private var reconciliation: Task<Void, Never>?
    // alternateIconName can lag behind (or stay stale after) a change the
    // system already confirmed. Remember the confirmed choice for this
    // process; every Settings screen creates a new service instance.
    private static var confirmedThisLaunch: Selection?

    private var simulatesChanges: Bool {
        #if DEBUG
        return LocalResources.isPreview && !ProcessInfo.processInfo.arguments.contains("--system-icon-test")
        #else
        return false
        #endif
    }
    var supported: Bool { simulatesChanges || UIApplication.shared.supportsAlternateIcons }

    static func systemSelection(for alternateIconName: String?) -> Selection {
        // AppIconDark was the dark 立体 alternate before the primary icon became dark.
        if alternateIconName == "AppIconDark" { return primary }
        for style in Choice.allCases {
            for theme in Theme.allCases where Selection(style: style, theme: theme).alternateName == alternateIconName {
                return Selection(style: style, theme: theme)
            }
        }
        return primary
    }
    static func systemChoice(for alternateIconName: String?) -> Choice { systemSelection(for: alternateIconName).style }

    // After an update installed by a signing tool, the Home Screen keeps the
    // alternate icon while alternateIconName reports none. The last icon the
    // system confirmed is remembered so Settings shows the one on screen.
    private static let rememberedKey = "appIconRememberedAlternate"
    static var rememberedAlternate: String? {
        get { UserDefaults.standard.string(forKey: rememberedKey) }
        set { UserDefaults.standard.set(newValue, forKey: rememberedKey) }
    }
    /// The icon on the Home Screen: what the system reports, or, when it
    /// reports the primary icon, a remembered alternate this bundle still has.
    static func effectiveSelection(reported: String?, remembered: String?,
                                   isBundled: ((String) -> Bool)? = nil) -> Selection {
        if reported == nil, let remembered, isBundled?(remembered) ?? bundledAlternateIsAvailable(remembered) {
            return systemSelection(for: remembered)
        }
        return systemSelection(for: reported)
    }
    private static var observedSelection: Selection {
        effectiveSelection(reported: UIApplication.shared.alternateIconName, remembered: rememberedAlternate)
    }

    // External IPA re-signing tools can remove the uncompiled alternate PNGs.
    // supportsAlternateIcons alone does not prove that the installed bundle is complete.
    static func bundledAlternateIsAvailable(_ name: String = "AppIconFlat", in bundle: Bundle = .main) -> Bool {
        guard let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let alternates = icons["CFBundleAlternateIcons"] as? [String: Any],
              let entry = alternates[name] as? [String: Any],
              let names = entry["CFBundleIconFiles"] as? [String], !names.isEmpty
        else { return false }
        return bundle.url(forResource: name + "60x60@2x", withExtension: "png") != nil ||
            bundle.url(forResource: name + "60x60@3x", withExtension: "png") != nil
    }

    /// EAGAIN: SpringBoard is still busy with the previous icon change.
    static func isTransientIconError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == 35
    }

    init() { refresh() }
    func refresh() {
        guard !simulatesChanges else { return }
        let observed = Self.observedSelection
        current = Self.confirmedThisLaunch ?? observed
        // A pending change is confirmed by the system's own report.
        let reported = Self.systemSelection(for: UIApplication.shared.alternateIconName)
        if awaitingSystem == reported {
            confirm(reported)
        }
    }

    private func confirm(_ choice: Selection) {
        Self.confirmedThisLaunch = choice
        Self.rememberedAlternate = choice.alternateName
        current = choice
        awaitingSystem = nil
        statusHint = nil
        reconciliation?.cancel()
        reconciliation = nil
    }

    /// A different style, keeping the theme.
    func select(_ style: Choice) async throws {
        refresh()
        try await apply(Selection(style: style, theme: current.theme))
    }
    /// A different theme, keeping the style.
    func select(theme: Theme) async throws {
        refresh()
        try await apply(Selection(style: current.style, theme: theme), reapplyPrimary: true)
    }

    private func apply(_ choice: Selection, reapplyPrimary: Bool = false) async throws {
        guard !changing else { throw ToolError.message(AppText.text("正在等待系统处理图标切换")) }
        // Choosing the primary icon again is allowed: after an update the
        // Home Screen may still show an alternate the system no longer reports.
        guard choice != current || (reapplyPrimary && choice.alternateName == nil) else { return }
        guard supported else { throw ToolError.message(AppText.text("当前设备不支持更换图标")) }
        guard simulatesChanges || UIApplication.shared.applicationState == .active else {
            throw ToolError.message(AppText.text("请回到应用前台再切换图标"))
        }
        changing = true
        defer { changing = false }
        if simulatesChanges { current = choice; return }
        guard choice.alternateName.map({ Self.bundledAlternateIsAvailable($0) }) ?? true else {
            throw ToolError.message(AppText.text("当前安装的 iPadn 缺少图标资源，无法更换图标"))
        }
        reconciliation?.cancel()
        reconciliation = nil
        awaitingSystem = nil
        statusHint = nil

        // The system believes the primary icon is set while an alternate may
        // be on screen; asking for the primary would change nothing, so set
        // an alternate first.
        if choice.alternateName == nil, UIApplication.shared.alternateIconName == nil,
           let restated = [Self.rememberedAlternate, "AppIconLight"].compactMap({ $0 }).first(where: { Self.bundledAlternateIsAvailable($0) }),
           Self.rememberedAlternate != nil || (reapplyPrimary && choice == current) {
            _ = await request(Self.systemSelection(for: restated))
            try? await Task.sleep(for: .milliseconds(800))
        }

        var lastError: Error?
        // SpringBoard rejects a change with EAGAIN while it is still applying
        // the previous one (for example switching back right away): back off.
        // iOS throttles a second change made soon after the previous one,
        // sometimes for most of a minute; keep retrying (about 60 s in total)
        // rather than giving up.
        let delays = [800, 1600, 2400, 3200, 4000, 5000, 6000, 8000, 10000, 10000, 10000]
        for attempt in 0...delays.count {
            let result = await request(choice)
            // A nil error is the system's confirmation, even if
            // alternateIconName has not caught up yet.
            if result == nil || Self.systemSelection(for: UIApplication.shared.alternateIconName) == choice {
                confirm(choice); return
            }
            lastError = result
            guard let error = result, Self.isTransientIconError(error), attempt < delays.count else { break }
            try await Task.sleep(for: .milliseconds(delays[attempt]))
            if Self.systemSelection(for: UIApplication.shared.alternateIconName) == choice {
                confirm(choice); return
            }
        }
        if lastError is IconRequestTimeout || lastError.map(Self.isTransientIconError) == true {
            // No final answer yet: keep watching alternateIconName instead of
            // inventing a failure; the selection updates when the system does.
            awaitingSystem = choice
            statusHint = AppText.text("正在更换图标…")
            beginReconciliation()
            return
        }
        throw ToolError.message(AppText.text("图标更换失败，请稍后重试"))
    }

    private struct IconRequestTimeout: Error {}

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Error?, Never>?
        init(_ continuation: CheckedContinuation<Error?, Never>) { self.continuation = continuation }
        func resume(_ error: Error?) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: error)
        }
    }

    /// One setAlternateIconName call; returns its error, or a timeout after 15 s.
    private func request(_ choice: Selection) async -> Error? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            let once = ResumeOnce(continuation)
            UIApplication.shared.setAlternateIconName(choice.alternateName) { error in once.resume(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { once.resume(IconRequestTimeout()) }
        }
    }

    private func beginReconciliation() {
        reconciliation?.cancel()
        reconciliation = Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                guard let self, self.awaitingSystem != nil else { return }
                self.refresh()
            }
            guard let self, self.awaitingSystem != nil else { return }
            self.awaitingSystem = nil
            // Show what the system reports from now on, not an earlier choice.
            Self.confirmedThisLaunch = nil
            self.statusHint = AppText.text("系统未确认更换，请回到主屏幕查看")
            self.refresh()
        }
    }
}
