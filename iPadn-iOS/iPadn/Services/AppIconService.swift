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

    private var pending: CheckedContinuation<Void, Error>?
    private var requestID: UUID?
    private var callbackError: Error?
    private var reconciliation: Task<Void, Never>?

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

    init() { refresh() }
    func refresh() {
        guard !simulatesChanges else { return }
        let observed = Self.systemChoice(for: UIApplication.shared.alternateIconName)
        selected = observed
        if awaitingSystem == observed {
            awaitingSystem = nil
            statusHint = nil
            reconciliation?.cancel()
            reconciliation = nil
        }
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
        callbackError = nil
        let id = UUID()
        let monitor = Task { [weak self] in
            for attempt in 0..<120 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                guard let self, self.requestID == id else { return }
                if Self.systemChoice(for: UIApplication.shared.alternateIconName) == choice {
                    self.finish(id, choice: choice, error: nil, systemAccepted: true)
                    return
                }
                if let error = self.callbackError, attempt >= 15 {
                    self.finish(id, choice: choice, error: error, systemAccepted: false)
                    return
                }
            }
            // Some iOS releases delay both the callback and alternateIconName
            // while SpringBoard applies the icon. Do not invent a failure.
            self?.finish(id, choice: choice, error: nil, systemAccepted: false)
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                requestID = id
                pending = continuation
                UIApplication.shared.setAlternateIconName(choice.alternateName) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.requestID == id else { return }
                        if let error {
                            self.callbackError = error
                        } else {
                            self.finish(id, choice: choice, error: nil, systemAccepted: true)
                        }
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                self?.finish(id, choice: choice, error: CancellationError(), systemAccepted: false)
            }
        })
    }

    private func finish(_ id: UUID, choice: Choice, error: Error?, systemAccepted: Bool) {
        guard requestID == id, let continuation = pending else { return }
        pending = nil
        requestID = nil
        callbackError = nil
        refresh()
        if let error, error is CancellationError {
            continuation.resume(throwing: error)
        } else if selected == choice {
            continuation.resume()
        } else if let error {
            let ns = error as NSError
            continuation.resume(throwing: ToolError.message(
                "iOS 未能应用所选图标（错误 \(ns.code)）。请检查安装包中的备用图标资源或重新安装。"))
        } else {
            awaitingSystem = choice
            statusHint = systemAccepted
                ? "系统已接受更换请求，正在等待桌面图标同步。"
                : "系统暂未返回最终结果，请回到桌面查看图标。"
            beginReconciliation()
            continuation.resume()
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
