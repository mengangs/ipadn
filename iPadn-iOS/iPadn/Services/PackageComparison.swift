import Foundation

/// What changed between two packages of the same app (Pro mode).
struct PackageComparison: Equatable {
    struct Change: Equatable, Identifiable {
        var title: String
        var old: String
        var new: String
        var id: String { title }
    }
    struct ListChange: Equatable {
        var added: [String] = []
        var removed: [String] = []
        var isEmpty: Bool { added.isEmpty && removed.isEmpty }
        init(old: [String], new: [String]) {
            let before = Set(old), after = Set(new)
            added = new.filter { !before.contains($0) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            removed = old.filter { !after.contains($0) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
        init() { }
    }

    var basics: [Change] = []
    var permissions = ListChange()
    var extensions = ListChange()
    var frameworks = ListChange()
    var languages = ListChange()
    var urlSchemes = ListChange()
    var backgroundModes = ListChange()

    var lists: [(title: String, change: ListChange)] {
        [(AppText.text("权限"), permissions), (AppText.text("扩展"), extensions), (AppText.text("内置框架"), frameworks),
         (AppText.text("支持的语言"), languages), (AppText.text("后台运行"), backgroundModes), ("URL Scheme", urlSchemes)]
    }
    var unchanged: Bool { basics.isEmpty && lists.allSatisfy { $0.change.isEmpty } }

    static func compare(_ old: PackageInfo, _ new: PackageInfo, locale: Locale = AppText.locale) -> PackageComparison {
        var result = PackageComparison()
        func basic(_ title: String, _ before: String, _ after: String) {
            if before != after { result.basics.append(Change(title: title, old: before.isEmpty ? "–" : before, new: after.isEmpty ? "–" : after)) }
        }
        func included(_ value: Bool) -> String { value ? AppText.text("包含") : AppText.text("不包含") }
        basic(AppText.text("版本"), old.version, new.version)
        basic(AppText.text("构建号"), old.build, new.build)
        basic(AppText.text("最低系统"), old.minimumOS.isEmpty ? "" : "iOS " + old.minimumOS, new.minimumOS.isEmpty ? "" : "iOS " + new.minimumOS)
        basic(AppText.text("适用设备"), old.devices, new.devices)
        if old.packageSize > 0, new.packageSize > 0, old.packageSize != new.packageSize {
            result.basics.append(Change(title: AppText.text("安装包大小"), old: old.packageSize.byteLabel, new: new.packageSize.byteLabel))
        }
        basic("Apple Watch", included(old.hasWatchApp), included(new.hasWatchApp))
        basic("App Clip", included(old.hasAppClip), included(new.hasAppClip))

        let permissionNames = { (info: PackageInfo) in PackageInfoService.groupedPermissions(info.permissions).map(\.name) }
        result.permissions = ListChange(old: permissionNames(old), new: permissionNames(new))
        let extensionNames = { (info: PackageInfo) in
            info.extensions.map { "\($0.name)（\(PackageInfoService.extensionKind($0.point) ?? $0.point)）" }
        }
        result.extensions = ListChange(old: extensionNames(old), new: extensionNames(new))
        result.frameworks = ListChange(old: old.frameworkNames, new: new.frameworkNames)
        let languageNames = { (info: PackageInfo) in info.languages.map { locale.localizedString(forIdentifier: $0) ?? $0 } }
        result.languages = ListChange(old: languageNames(old), new: languageNames(new))
        let modes = { (info: PackageInfo) in info.backgroundModes.map { PackageInfoService.backgroundModeName($0) ?? $0 } }
        result.backgroundModes = ListChange(old: modes(old), new: modes(new))
        result.urlSchemes = ListChange(old: old.urlSchemes, new: new.urlSchemes)
        return result
    }
}
