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
        var path: String = ""
        var id: String { path.isEmpty ? (point + "|" + name) : path }
    }
    var name = ""
    var bundleID = ""
    var version = ""
    var build = ""
    var minimumOS = ""
    var sdkName = ""
    var sdkVersion = ""
    var sdkBuild = ""
    var machOSDKVersion = ""
    var xcodeVersion = ""
    var xcodeBuild = ""
    var devices = ""
    var languages: [String] = []
    var permissions: [Permission] = []
    var extensions: [Extension] = []
    var urlSchemes: [String] = []
    var backgroundModes: [String] = []
    var hasWatchApp = false
    var hasAppClip = false
    var frameworks = 0
    var frameworkNames: [String] = []
    /// The package file's size on disk.
    var packageSize: Int64 = 0

    var formattedSDK: String {
        let lower = sdkName.lowercased()
        let platform: String
        if lower.hasPrefix("appletvos") { platform = "tvOS" }
        else if lower.hasPrefix("macosx") { platform = "macOS" }
        else if lower.hasPrefix("xros") { platform = "visionOS" }
        else if lower.hasPrefix("watchos") { platform = "watchOS" }
        else { platform = "iOS" }
        let version = !machOSDKVersion.isEmpty ? machOSDKVersion : sdkVersion
        if version.isEmpty { return sdkName }
        return sdkBuild.isEmpty ? "\(platform) \(version)" : "\(platform) \(version) (\(sdkBuild))"
    }

    var formattedXcode: String {
        if !xcodeVersion.isEmpty {
            return xcodeBuild.isEmpty ? "Xcode \(xcodeVersion)" : "Xcode \(xcodeVersion) (\(xcodeBuild))"
        }
        if !xcodeBuild.isEmpty { return "Xcode (\(xcodeBuild))" }
        return ""
    }
}

struct QuickBuildInfo: Equatable, Sendable {
    let sdk: String
    let xcode: String
    let minimumOS: String

    var isEmpty: Bool { sdk.isEmpty && xcode.isEmpty }
    var compactLabel: String {
        let shortSDK = Self.stripBuildSuffix(sdk)
        let shortXcode = Self.stripBuildSuffix(xcode)
        return [shortSDK.isEmpty ? "" : "SDK " + shortSDK, shortXcode]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func stripBuildSuffix(_ value: String) -> String {
        guard let range = value.range(of: " ("), value.hasSuffix(")") else { return value }
        let prefix = String(value[..<range.lowerBound])
        return prefix == "Xcode" ? value : prefix
    }
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
        let executableName = plistString(plist["CFBundleExecutable"])
        if !executableName.isEmpty {
            info.machOSDKVersion = readMachOSDKVersion(executableName: executableName, appPrefix: prefix, archive: archive)
        }
        let metadata: [String: Any]
        if let entry = archive["iTunesMetadata.plist"] { metadata = (try? readPlist(entry, archive: archive)) ?? [:] }
        else { metadata = [:] }
        let localizedName = PackageService.localizedBundleDisplayName(in: archive, appPrefix: prefix, basePlist: plist, metadata: metadata)
        if !localizedName.isEmpty { info.name = localizedName }
        info.devices = PackageService.describePlatforms(families: Set(plist["UIDeviceFamily"] as? [Int] ?? []),
                                                        platforms: Set(plist["CFBundleSupportedPlatforms"] as? [String] ?? []))
        info.languages = languages(in: paths)
        info.hasWatchApp = paths.contains { $0.hasPrefix("Watch/") }
        info.hasAppClip = paths.contains { $0.hasPrefix("AppClips/") }
        info.frameworkNames = Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            return parts.count >= 2 && parts[0] == "Frameworks" ? String(parts[1]) : nil
        }).sorted()
        info.frameworks = info.frameworkNames.count
        info.packageSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        // Extensions: PlugIns/*.appex and Extensions/*.appex, each with its own Info.plist.
        var seenExtensionPaths = Set<String>()
        for path in paths where isExtensionInfo(path) && seenExtensionPaths.insert(path).inserted {
            guard let entry = archive[prefix + path], let extensionPlist = try? readPlist(entry, archive: archive) else { continue }
            let point = plistString((extensionPlist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
                                    ?? (extensionPlist["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"])
            let name = plistString(extensionPlist["CFBundleDisplayName"] ?? extensionPlist["CFBundleName"])
            let bundleRelativePath = String(path.dropLast("/Info.plist".count))
            info.extensions.append(.init(
                name: name.isEmpty ? String(path.split(separator: "/")[1].dropLast(".appex".count)) : name,
                point: point,
                path: bundleRelativePath
            ))
        }
        info.extensions.sort { ($0.point, $0.name, $0.path) < ($1.point, $1.name, $1.path) }
        return info
    }

    /// Fast read of SDK version, Xcode version and MinimumOSVersion from an IPA without scanning all bundle entries.
    static func quickBuildInfo(_ url: URL) -> QuickBuildInfo? {
        guard let archive = try? Archive(url: url, accessMode: .read),
              let main = archive.first(where: { entry in
                  let parts = entry.path.split(separator: "/")
                  return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
              }),
              let plist = try? readPlist(main, archive: archive) else { return nil }
        let prefix = String(main.path.dropLast("Info.plist".count))
        var info = describe(plist)
        let executableName = plistString(plist["CFBundleExecutable"])
        if !executableName.isEmpty {
            info.machOSDKVersion = readMachOSDKVersion(executableName: executableName, appPrefix: prefix, archive: archive)
        }
        return QuickBuildInfo(
            sdk: info.formattedSDK,
            xcode: info.formattedXcode,
            minimumOS: info.minimumOS.isEmpty ? "" : "iOS " + info.minimumOS
        )
    }

    /// The parts of a main Info.plist the page shows. Internal for tests.
    static func describe(_ plist: [String: Any]) -> PackageInfo {
        var info = PackageInfo()
        info.name = plistString(plist["CFBundleDisplayName"] ?? plist["CFBundleName"])
        info.bundleID = plistString(plist["CFBundleIdentifier"])
        info.version = plistString(plist["CFBundleShortVersionString"])
        info.build = plistString(plist["CFBundleVersion"])
        info.minimumOS = plistString(plist["MinimumOSVersion"])
        info.sdkName = plistString(plist["DTSDKName"])
        info.sdkVersion = extractSDKVersion(from: info.sdkName, platformVersion: plistString(plist["DTPlatformVersion"]))
        info.sdkBuild = plistString(plist["DTSDKBuild"])
        info.xcodeVersion = formatDTXcode(plistString(plist["DTXcode"]))
        info.xcodeBuild = plistString(plist["DTXcodeBuild"])
        info.permissions = plist.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted()
            .map { PackageInfo.Permission(key: $0, reason: plistString(plist[$0])) }
        info.urlSchemes = ((plist["CFBundleURLTypes"] as? [[String: Any]]) ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .filter { !$0.isEmpty }
        info.urlSchemes = Array(NSOrderedSet(array: info.urlSchemes)) as? [String] ?? info.urlSchemes
        info.backgroundModes = (plist["UIBackgroundModes"] as? [String] ?? []).sorted()
        return info
    }

    /// Parses Apple's 4-digit `DTXcode` (e.g. `"1620"` -> `"16.2"`, `"1601"` -> `"16.0.1"`, `"2600"` -> `"26.0"`).
    static func formatDTXcode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return trimmed }
        let chars = Array(trimmed)
        if chars.count == 4,
           let major = Int(String(chars[0...1])),
           let minor = Int(String(chars[2])),
           let patch = Int(String(chars[3])) {
            return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        }
        if chars.count == 3,
           let major = Int(String(chars[0])),
           let minor = Int(String(chars[1])),
           let patch = Int(String(chars[2])) {
            return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        }
        return trimmed
    }

    static func extractSDKVersion(from sdkName: String, platformVersion: String) -> String {
        let pv = platformVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pv.isEmpty { return pv }
        let trimmed = sdkName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstDigit = trimmed.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return "" }
        return String(trimmed[firstDigit...])
    }

    private struct MachOHeaderStop: Error {}

    private static func readEntryPrefix(_ entry: Entry, archive: Archive, limit: Int) -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, Int(min(entry.uncompressedSize, UInt64(limit)))))
        do {
            _ = try archive.extract(entry, bufferSize: 1 << 16, skipCRC32: true) { chunk in
                data.append(chunk)
                if data.count >= limit { throw MachOHeaderStop() }
            }
        } catch {
            // Early stop or unreadable entry; parse whatever prefix was read.
        }
        return data
    }

    private static func formatPackedSDK(_ value: UInt32) -> String {
        guard value > 0 else { return "" }
        let major = (value >> 16) & 0xFFFF
        let minor = (value >> 8) & 0xFF
        let patch = value & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    static func parseMachOSDKVersion(from data: Data, sliceOffset: Int = 0) -> String {
        guard sliceOffset >= 0, sliceOffset <= data.count - 32 else { return "" }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: sliceOffset, as: UInt32.self) }
        guard magic == 0xFEEDFACF else { return "" }
        let ncmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: sliceOffset + 16, as: UInt32.self) }
        let sizeofcmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: sliceOffset + 20, as: UInt32.self) }
        var cursor = sliceOffset + 32
        let end = min(data.count, cursor + Int(sizeofcmds))
        for _ in 0..<ncmds {
            guard cursor <= end - 8 else { break }
            let cmd = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
            let cmdsize = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self) }
            guard cmdsize >= 8, (cmdsize & 3) == 0, cursor <= end - Int(cmdsize) else { break }
            if cmd == 0x32, cmdsize >= 24, cursor + 20 <= end { // LC_BUILD_VERSION
                let sdk = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 16, as: UInt32.self) }
                let formatted = formatPackedSDK(sdk)
                if !formatted.isEmpty { return formatted }
            } else if cmd == 0x25, cmdsize >= 16, cursor + 16 <= end { // LC_VERSION_MIN_IPHONEOS
                let sdk = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 12, as: UInt32.self) }
                let formatted = formatPackedSDK(sdk)
                if !formatted.isEmpty { return formatted }
            }
            cursor += Int(cmdsize)
        }
        return ""
    }

    private static func readMachOSDKVersion(executableName: String, appPrefix: String, archive: Archive) -> String {
        guard let entry = archive[appPrefix + executableName], entry.type == .file, entry.uncompressedSize >= 32 else {
            return ""
        }
        var head = readEntryPrefix(entry, archive: archive, limit: 64 << 10)
        guard head.count >= 32 else { return "" }
        let magicBE = head.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
        if magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF {
            let is64 = magicBE == 0xCAFEBABF
            let count = Int(min(head.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }, 16))
            let stride = is64 ? 32 : 20
            guard 8 + count * stride <= head.count else { return "" }
            var offsets: [Int] = []
            for i in 0..<count {
                let base = 8 + i * stride
                let cputype = head.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: base, as: UInt32.self)) }
                guard (cputype & 0x0100_0000) != 0 else { continue }
                let off: UInt64 = head.withUnsafeBytes {
                    is64 ? UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: base + 8, as: UInt64.self))
                         : UInt64(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)))
                }
                if off <= 4 * 1024 * 1024 { offsets.append(Int(off)) }
            }
            if let maxOffset = offsets.max(), maxOffset + (64 << 10) > head.count {
                head = readEntryPrefix(entry, archive: archive, limit: min(maxOffset + (64 << 10), 4 * 1024 * 1024 + (64 << 10)))
            }
            for offset in offsets {
                let version = parseMachOSDKVersion(from: head, sliceOffset: offset)
                if !version.isEmpty { return version }
            }
            return ""
        }
        return parseMachOSDKVersion(from: head, sliceOffset: 0)
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
