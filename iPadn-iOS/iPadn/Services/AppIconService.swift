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
    private var simulatesChanges: Bool {
        #if DEBUG
        return LocalResources.isPreview && !ProcessInfo.processInfo.arguments.contains("--system-icon-test")
        #else
        return false
        #endif
    }
    var supported: Bool { simulatesChanges || UIApplication.shared.supportsAlternateIcons }

    init() { refresh() }
    func refresh() {
        guard !simulatesChanges else { return }
        selected = UIApplication.shared.alternateIconName == Choice.flat.alternateName ? .flat : .dimensional
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
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(id, choice: choice, error: ToolError.message("系统未完成图标切换，请稍后重试。重新签名时请保留备用图标文件和 Info.plist 图标配置。"))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                requestID = id; pending = continuation
                UIApplication.shared.setAlternateIconName(choice.alternateName) { [weak self] error in
                    Task { @MainActor in self?.finish(id, choice: choice, error: error) }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finish(id, choice: choice, error: CancellationError()) }
        })
    }
    private func finish(_ id: UUID, choice: Choice, error: Error?) {
        guard requestID == id, let continuation = pending else { return }
        pending = nil; requestID = nil; refresh()
        if selected == choice { continuation.resume() }
        else { continuation.resume(throwing: error ?? ToolError.message("系统未应用所选图标，请检查重新签名后的安装包是否保留备用图标文件。")) }
    }
}
