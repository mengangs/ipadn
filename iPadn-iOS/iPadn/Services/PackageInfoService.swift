import Foundation
import ZIPFoundation

/// What a package declares about itself, read from its Info.plist files only.
/// Nothing in the package is run or decrypted.
struct PackageInfo: Equatable {
    struct Permission: Equatable, Identifiable {
        var key: String
        /// The developer's reason, in the package's own language.
        var reason: String
        var id: String { key }
    }
    struct Extension: Equatable, Identifiable {
        var name: String
        var point: String
        var id: String { point + "|" + name }
    }
    var name = ""
    var bundleID = ""
    var version = ""
    var build = ""
    var minimumOS = ""
    var devices = ""
    var languages: [String] = []
    var permissions: [Permission] = []
    var extensions: [Extension] = []
    var urlSchemes: [String] = []
    var backgroundModes: [String] = []
    var hasWatchApp = false
    var hasAppClip = false
    var frameworks = 0
}

enum PackageInfoService {
    static func read(_ url: URL) throws -> PackageInfo {
        let archive = try Archive(url: url, accessMode: .read)
        guard let main = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ToolError.message(AppText.text("这不是有效的 IPA 安装包")) }
        let prefix = String(main.path.dropLast("Info.plist".count))
        let plist = try readPlist(main, archive: archive)
        var paths: [String] = []
        for entry in archive where entry.path.hasPrefix(prefix) { paths.append(String(entry.path.dropFirst(prefix.count))) }

        var info = describe(plist)
        info.devices = PackageService.describePlatforms(families: Set(plist["UIDeviceFamily"] as? [Int] ?? []),
                                                        platforms: Set(plist["CFBundleSupportedPlatforms"] as? [String] ?? []))
        info.languages = languages(in: paths)
        info.hasWatchApp = paths.contains { $0.hasPrefix("Watch/") }
        info.hasAppClip = paths.contains { $0.hasPrefix("AppClips/") }
        info.frameworks = Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            return parts.count >= 2 && parts[0] == "Frameworks" ? String(parts[1]) : nil
        }).count
        // Extensions: PlugIns/*.appex and Extensions/*.appex, each with its own Info.plist.
        for path in paths where isExtensionInfo(path) {
            guard let entry = archive[prefix + path], let extensionPlist = try? readPlist(entry, archive: archive) else { continue }
            let point = plistString((extensionPlist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
                                    ?? (extensionPlist["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"])
            let name = plistString(extensionPlist["CFBundleDisplayName"] ?? extensionPlist["CFBundleName"])
            info.extensions.append(.init(name: name.isEmpty ? String(path.split(separator: "/")[1].dropLast(".appex".count)) : name, point: point))
        }
        info.extensions.sort { ($0.point, $0.name) < ($1.point, $1.name) }
        return info
    }

    /// The parts of a main Info.plist the page shows. Internal for tests.
    static func describe(_ plist: [String: Any]) -> PackageInfo {
        var info = PackageInfo()
        info.name = plistString(plist["CFBundleDisplayName"] ?? plist["CFBundleName"])
        info.bundleID = plistString(plist["CFBundleIdentifier"])
        info.version = plistString(plist["CFBundleShortVersionString"])
        info.build = plistString(plist["CFBundleVersion"])
        info.minimumOS = plistString(plist["MinimumOSVersion"])
        info.permissions = plist.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted()
            .map { PackageInfo.Permission(key: $0, reason: plistString(plist[$0])) }
        info.urlSchemes = ((plist["CFBundleURLTypes"] as? [[String: Any]]) ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .filter { !$0.isEmpty }
        info.urlSchemes = Array(NSOrderedSet(array: info.urlSchemes)) as? [String] ?? info.urlSchemes
        info.backgroundModes = (plist["UIBackgroundModes"] as? [String] ?? []).sorted()
        return info
    }

    static func isExtensionInfo(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count == 3 && (parts[0] == "PlugIns" || parts[0] == "Extensions")
            && parts[1].hasSuffix(".appex") && parts[2] == "Info.plist"
    }

    /// Localizations the app ships, as language codes; Base is not a language.
    static func languages(in paths: [String]) -> [String] {
        Set(paths.compactMap { path -> String? in
            guard let first = path.split(separator: "/").first, first.hasSuffix(".lproj") else { return nil }
            let code = String(first.dropLast(".lproj".count))
            return code == "Base" || code.isEmpty ? nil : code
        }).sorted()
    }

    private static func readPlist(_ entry: Entry, archive: Archive) throws -> [String: Any] {
        let limit = 2 * 1024 * 1024
        guard entry.type == .file, entry.uncompressedSize <= UInt64(limit) else { throw ToolError.message(AppText.text("安装包已损坏")) }
        var data = Data()
        _ = try archive.extract(entry, consumer: {
            guard data.count + $0.count <= limit else { throw ToolError.message(AppText.text("安装包已损坏")) }
            data.append($0)
        })
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToolError.message(AppText.text("安装包已损坏"))
        }
        return result
    }

    /// Permissions under their readable names, one row per name: several keys
    /// mean the same thing (old and new Bluetooth or location keys).
    static func groupedPermissions(_ permissions: [PackageInfo.Permission]) -> [(name: String, reasons: [String])] {
        var groups: [(name: String, reasons: [String])] = []
        for permission in permissions {
            let name = permissionName(permission.key) ?? permission.key
            let reason = permission.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = groups.firstIndex(where: { $0.name == name }) {
                if !reason.isEmpty && !groups[index].reasons.contains(reason) { groups[index].reasons.append(reason) }
            } else {
                groups.append((name, reason.isEmpty ? [] : [reason]))
            }
        }
        return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A readable name for a privacy permission key; nil for keys without one.
    static func permissionName(_ key: String) -> String? {
        let names: [String: String] = [
            "NSCameraUsageDescription": "相机",
            "NSMicrophoneUsageDescription": "麦克风",
            "NSPhotoLibraryUsageDescription": "照片",
            "NSPhotoLibraryAddUsageDescription": "添加到照片",
            "NSLocationWhenInUseUsageDescription": "使用期间的位置",
            "NSLocationAlwaysAndWhenInUseUsageDescription": "始终访问位置",
            "NSLocationAlwaysUsageDescription": "始终访问位置",
            "NSLocationUsageDescription": "位置",
            "NSContactsUsageDescription": "通讯录",
            "NSCalendarsUsageDescription": "日历",
            "NSCalendarsFullAccessUsageDescription": "日历",
            "NSCalendarsWriteOnlyAccessUsageDescription": "添加日历事件",
            "NSRemindersUsageDescription": "提醒事项",
            "NSRemindersFullAccessUsageDescription": "提醒事项",
            "NSBluetoothAlwaysUsageDescription": "蓝牙",
            "NSBluetoothPeripheralUsageDescription": "蓝牙",
            "NSLocalNetworkUsageDescription": "本地网络",
            "NSMotionUsageDescription": "运动与健身",
            "NSHealthShareUsageDescription": "读取健康数据",
            "NSHealthUpdateUsageDescription": "写入健康数据",
            "NSSpeechRecognitionUsageDescription": "语音识别",
            "NSAppleMusicUsageDescription": "媒体与 Apple Music",
            "NSFaceIDUsageDescription": "面容 ID",
            "NSUserTrackingUsageDescription": "跨 App 追踪",
            "NSHomeKitUsageDescription": "家庭",
            "NSSiriUsageDescription": "Siri",
            "NSNearbyInteractionUsageDescription": "附近交互",
            "NSFocusStatusUsageDescription": "专注模式状态",
        ]
        return names[key].map { AppText.text(String.LocalizationValue($0)) }
    }

    /// A readable name for a background mode; nil for unknown modes.
    static func backgroundModeName(_ mode: String) -> String? {
        let names: [String: String] = [
            "audio": "后台播放音频", "location": "后台定位", "voip": "网络通话", "fetch": "后台刷新",
            "remote-notification": "远程通知", "processing": "后台任务", "bluetooth-central": "蓝牙连接",
            "bluetooth-peripheral": "蓝牙连接", "external-accessory": "外接配件", "nearby-interaction": "附近交互",
            "push-to-talk": "对讲",
        ]
        return names[mode].map { AppText.text(String.LocalizationValue($0)) }
    }

    /// A readable name for an extension point; nil for unknown points.
    static func extensionKind(_ point: String) -> String? {
        let kinds: [String: String] = [
            "com.apple.widgetkit-extension": "小组件",
            "com.apple.share-services": "分享扩展",
            "com.apple.ui-services": "操作扩展",
            "com.apple.usernotifications.service": "通知服务",
            "com.apple.usernotifications.content-extension": "通知内容",
            "com.apple.keyboard-service": "键盘",
            "com.apple.intents-service": "Siri 与快捷指令",
            "com.apple.intents-ui-service": "Siri 与快捷指令",
            "com.apple.appintents-extension": "Siri 与快捷指令",
            "com.apple.photo-editing": "照片编辑",
            "com.apple.fileprovider-nonui": "文件提供者",
            "com.apple.fileprovider-actionsui": "文件提供者",
            "com.apple.networkextension.packet-tunnel": "VPN",
            "com.apple.Safari.web-extension": "Safari 扩展",
            "com.apple.Safari.content-blocker": "Safari 内容拦截",
            "com.apple.callkit.call-directory": "来电识别",
            "com.apple.broadcast-services-upload": "屏幕直播",
            "com.apple.broadcast-services-setupui": "屏幕直播",
            "com.apple.message-payload-provider": "iMessage 信息",
            "com.apple.background-asset-downloader-extension": "后台资源下载",
            "com.apple.spotlight.import": "聚焦搜索",
        ]
        return kinds[point].map { AppText.text(String.LocalizationValue($0)) }
    }
}
