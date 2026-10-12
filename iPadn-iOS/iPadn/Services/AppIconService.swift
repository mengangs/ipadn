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
    private var pending: CheckedContinuation<Void, Error>?
    private var requestID: UUID?
    private var callbackError: Error?

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

    init() { refresh() }
    func refresh() {
        guard !simulatesChanges else { return }
        selected = Self.systemChoice(for: UIApplication.shared.alternateIconName)
    }

    func select(_ choice: Choice) async throws {
        guard !changing else { throw ToolError.message("正在等待系统更改图标，请稍候") }
        refresh()
        guard choice != selected else { return }
        guard supported else { throw ToolError.message("当前安装方式不支持切换图标，请使用完整安装包重新签名") }
        guard simulatesChanges || UIApplication.shared.applicationState == .active else {
            throw ToolError.message("请回到应用前台再切换图标")
        }
        changing = true
        defer { changing = false }
        if simulatesChanges { selected = choice; return }

        let id = UUID()
        callbackError = nil
        // On some iOS builds setAlternateIconName's completion fires before
        // alternateIconName changes, or reports an error after applying the icon.
        // Only the observed system state can confirm which checkmark to display.
        let observer = Task { [weak self] in
            for attempt in 0..<80 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                guard let self, self.requestID == id else { return }
                if Self.systemChoice(for: UIApplication.shared.alternateIconName) == choice {
                    self.finish(id, choice: choice, error: nil)
                    return
                }
                if let error = self.callbackError, attempt >= 14 {
                    self.finish(id, choice: choice, error: error)
                    return
                }
            }
            self?.finish(id, choice: choice, error: ToolError.message("系统未确认图标已更改。请重新打开应用检查图标，或检查重签名 IPA 中的备用图标文件。"))
        }
        defer { observer.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                requestID = id
                pending = continuation
                UIApplication.shared.setAlternateIconName(choice.alternateName) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.requestID == id else { return }
                        // A callback is informative; do not forge selected state.
                        if let error { self.callbackError = error }
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finish(id, choice: choice, error: CancellationError()) }
        })
    }

    private func finish(_ id: UUID, choice: Choice, error: Error?) {
        guard requestID == id, let continuation = pending else { return }
        pending = nil; requestID = nil; callbackError = nil
        refresh()
        if let error, error is CancellationError { continuation.resume(throwing: error) }
        else if selected == choice {
            continuation.resume()
        } else {
            continuation.resume(throwing: error ?? ToolError.message("系统未应用所选图标，请检查备用图标配置"))
        }
    }
}
