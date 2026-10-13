import UIKit
import Combine

@MainActor
final class AppIconService: ObservableObject {
    enum Choice: String, CaseIterable, Identifiable {
        case dimensional, flat
        var id: String { rawValue }
        var title: String { self == .dimensional ? "立体图标" : "扁平图标" }
        var preview: String { self == .dimensional ? "BrandMark" : "FlatBrandMark" }
        var alternateName: String? { self == .flat ? "AppIconFlat" : nil }
    }

    @Published private(set) var selected: Choice = .dimensional
    @Published private(set) var changing = false
    @Published private(set) var awaitingSystem: Choice?
    @Published private(set) var statusHint: String?

    private var reconciliation: Task<Void, Never>?
    // alternateIconName can lag behind (or stay stale after) a change the
    // system already confirmed. Remember the confirmed choice for this
    // process; every Settings screen creates a new service instance.
    private static var confirmedThisLaunch: Choice?

    private var simulatesChanges: Bool {
        #if DEBUG
        return LocalResources.isPreview && !ProcessInfo.processInfo.arguments.contains("--system-icon-test")
        #else
        return false
        #endif
    }
    var supported: Bool { simulatesChanges || UIApplication.shared.supportsAlternateIcons }

    static func systemChoice(for alternateIconName: String?) -> Choice {
        alternateIconName == Choice.flat.alternateName ? .flat : .dimensional
    }

    // External IPA re-signing tools can remove the uncompiled alternate PNGs.
    // supportsAlternateIcons alone does not prove that the installed bundle is complete.
    static func bundledAlternateIsAvailable(in bundle: Bundle = .main) -> Bool {
        guard let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let alternates = icons["CFBundleAlternateIcons"] as? [String: Any],
              let flat = alternates["AppIconFlat"] as? [String: Any],
              let names = flat["CFBundleIconFiles"] as? [String], !names.isEmpty
        else { return false }
        return bundle.url(forResource: "AppIconFlat60x60@2x", withExtension: "png") != nil ||
            bundle.url(forResource: "AppIconFlat60x60@3x", withExtension: "png") != nil
    }

    /// EAGAIN: SpringBoard is still busy with the previous icon change.
    static func isTransientIconError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == 35
    }

    init() { refresh() }
    func refresh() {
        guard !simulatesChanges else { return }
        let observed = Self.systemChoice(for: UIApplication.shared.alternateIconName)
        selected = Self.confirmedThisLaunch ?? observed
        if awaitingSystem == observed {
            confirm(observed)
        }
    }

    private func confirm(_ choice: Choice) {
        Self.confirmedThisLaunch = choice
        selected = choice
        awaitingSystem = nil
        statusHint = nil
        reconciliation?.cancel()
        reconciliation = nil
    }

    func select(_ choice: Choice) async throws {
        guard !changing else { throw ToolError.message("正在等待系统处理图标切换") }
        refresh()
        guard choice != selected else { return }
        guard supported else { throw ToolError.message("当前安装方式不支持切换应用图标") }
        guard simulatesChanges || UIApplication.shared.applicationState == .active else {
            throw ToolError.message("请回到应用前台再切换图标")
        }
        changing = true
        defer { changing = false }
        if simulatesChanges { selected = choice; return }
        guard Self.bundledAlternateIsAvailable() else {
            throw ToolError.message("当前安装包缺少备用图标资源，请重新签名并安装保留完整图标文件的 IPA。")
        }
        reconciliation?.cancel()
        reconciliation = nil
        awaitingSystem = nil
        statusHint = nil

        var lastError: Error?
        // SpringBoard rejects a change with EAGAIN while it is still applying
        // the previous one (for example switching back right away): back off.
        // iOS throttles a second change made within seconds of the previous
        // one; keep retrying (about 30 s in total) rather than giving up.
        let delays = [800, 1600, 2400, 3200, 4000, 4000, 4000, 5000, 5000]
        for attempt in 0...delays.count {
            let result = await request(choice)
            // A nil error is the system's confirmation, even if
            // alternateIconName has not caught up yet.
            if result == nil || Self.systemChoice(for: UIApplication.shared.alternateIconName) == choice {
                confirm(choice); return
            }
            lastError = result
            guard let error = result, Self.isTransientIconError(error), attempt < delays.count else { break }
            try await Task.sleep(for: .milliseconds(delays[attempt]))
            if Self.systemChoice(for: UIApplication.shared.alternateIconName) == choice {
                confirm(choice); return
            }
        }
        if lastError is IconRequestTimeout || lastError.map(Self.isTransientIconError) == true {
            // No final answer yet: keep watching alternateIconName instead of
            // inventing a failure; the selection updates when the system does.
            awaitingSystem = choice
            statusHint = "系统正在处理图标更换，完成后会自动更新。"
            beginReconciliation()
            return
        }
        let code = (lastError as NSError?)?.code ?? 0
        throw ToolError.message("iOS 未能应用所选图标（错误 \(code)）。请稍后重试；若仍失败，请检查安装包中的备用图标资源。")
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
    private func request(_ choice: Choice) async -> Error? {
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
            self.statusHint = "系统没有确认这次切换。请返回桌面检查；若未变化，请检查重新签名的安装包。"
            self.refresh()
        }
    }
}
