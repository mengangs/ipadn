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
    var supported: Bool { LocalResources.isPreview || UIApplication.shared.supportsAlternateIcons }

    init() { refresh() }
    func refresh() {
        guard !LocalResources.isPreview else { return }
        selected = UIApplication.shared.alternateIconName == Choice.flat.alternateName ? .flat : .dimensional
    }
    func select(_ choice: Choice) async throws {
        guard !changing, choice != selected else { return }
        guard supported else { throw ToolError.message("当前安装方式不支持切换图标，请使用完整安装包重新签名") }
        changing = true
        defer { changing = false }
        if LocalResources.isPreview { selected = choice; return }
        try await UIApplication.shared.setAlternateIconName(choice.alternateName)
        refresh()
    }
}
