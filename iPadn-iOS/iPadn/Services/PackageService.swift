import Foundation
import ZIPFoundation

enum PackageService {
    static func inspect(_ url: URL) throws -> StoreApp {
        let archive = try Archive(url: url, accessMode: .read)
        guard let info = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ToolError.message(AppText.text("这不是有效的 IPA 安装包")) }
        let appPrefix = String(info.path.dropLast("Info.plist".count))
        let plist = try readPlist(info, archive: archive)
        let metadata: [String: Any]
        if let entry = archive["iTunesMetadata.plist"] { metadata = (try? readPlist(entry, archive: archive)) ?? [:] }
        else { metadata = [:] }
        let name = localizedBundleDisplayName(in: archive, appPrefix: appPrefix, basePlist: plist, metadata: metadata)
        let id = plistString(metadata["itemId"])
        let build = plistString(plist["CFBundleVersion"])
        let externalID = plistString(metadata["softwareVersionExternalIdentifier"])
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return StoreApp(id: id.isEmpty ? UUID().uuidString : id, name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                        bundleID: plistString(plist["CFBundleIdentifier"]), version: plistString(plist["CFBundleShortVersionString"]),
                        size: size, minimumOS: plistString(plist["MinimumOSVersion"]),
                        externalVersionID: externalID.isEmpty ? nil : externalID,
                        bundleVersion: build.isEmpty ? nil : build)
    }

    /// Resolves an IPA's display name in priority order:
    /// 1) `iTunesMetadata.plist["itemName"]`
    /// 2) `*.lproj/InfoPlist.strings` matching `Locale.preferredLanguages` (`CFBundleDisplayName` / `CFBundleName`)
    /// 3) root `Info.plist` (`CFBundleDisplayName` / `CFBundleName`)
    static func localizedBundleDisplayName(in archive: Archive, appPrefix: String,
                                           basePlist: [String: Any], metadata: [String: Any]) -> String {
        let storeItemName = plistString(metadata["itemName"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !storeItemName.isEmpty { return storeItemName }

        if let localized = localizedInfoPlistName(in: archive, appPrefix: appPrefix) {
            return localized
        }

        return plistString(basePlist["CFBundleDisplayName"] ?? basePlist["CFBundleName"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func localizedInfoPlistName(in archive: Archive, appPrefix: String,
                                               preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
        var candidates: [String] = []
        var seen = Set<String>()
        func addCandidate(_ code: String) {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            candidates.append(trimmed)
        }
        for pref in preferredLanguages {
            let normalized = pref.replacingOccurrences(of: "_", with: "-")
            addCandidate(normalized)
            addCandidate(pref)
            let parts = normalized.split(separator: "-").map(String.init)
            if parts.count >= 2 {
                addCandidate(parts[0] + "-" + parts[1])
                addCandidate(parts[0] + "_" + parts[1])
            }
            if parts.first?.lowercased() == "zh" {
                let lowerParts = parts.map { $0.lowercased() }
                let isHant = lowerParts.contains("hant") || lowerParts.contains("tw") || lowerParts.contains("hk") || lowerParts.contains("mo")
                if isHant {
                    for code in ["zh-Hant", "zh_TW", "zh-TW", "zh_HK", "zh-HK", "zh-Hant-TW", "zh-Hant-HK"] { addCandidate(code) }
                } else {
                    for code in ["zh-Hans", "zh_CN", "zh-CN", "zh-Hans-CN", "zh"] { addCandidate(code) }
                }
            }
            if let lang = parts.first { addCandidate(lang) }
        }
        for code in candidates {
            let entryPath = appPrefix + code + ".lproj/InfoPlist.strings"
            guard let entry = archive[entryPath] else { continue }
            if let dict = try? readStrings(entry, archive: archive) {
                let display = (dict["CFBundleDisplayName"] ?? dict["CFBundleName"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !display.isEmpty { return display }
            }
        }
        return nil
    }

    private static func readStrings(_ entry: Entry, archive: Archive) throws -> [String: String] {
        let limit = 512 * 1024
        guard entry.type == .file, entry.uncompressedSize <= UInt64(limit) else { return [:] }
        var data = Data()
        _ = try archive.extract(entry, consumer: {
            guard data.count + $0.count <= limit else { throw ToolError.message(AppText.text("安装包已损坏")) }
            data.append($0)
        })
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            var result: [String: String] = [:]
            for (k, v) in plist {
                if let s = v as? String { result[k] = s }
            }
            if !result.isEmpty { return result }
        }
        // Fallback for UTF-16 / UTF-8 `.strings` text format if PropertyListSerialization declines comments/BOM.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
            ?? ""
        guard !text.isEmpty else { return [:] }
        var parsed: [String: String] = [:]
        let pattern = #"\"([^\"]+)\"\s*=\s*\"([^\"]*)\"\s*;"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let kr = Range(match.range(at: 1), in: text),
                   let vr = Range(match.range(at: 2), in: text) {
                    parsed[String(text[kr])] = String(text[vr])
                }
            }
        }
        return parsed
    }

    static func deviceFamilies(_ url: URL) throws -> Set<Int> {
        let archive = try Archive(url: url, accessMode: .read)
        guard let info = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" &&
                parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ToolError.message(AppText.text("这不是有效的 IPA 安装包")) }
        let plist = try readPlist(info, archive: archive)
        return Set(plist["UIDeviceFamily"] as? [Int] ?? [])
    }

    static func supportedPlatforms(_ url: URL) throws -> Set<String> {
        let archive = try Archive(url: url, accessMode: .read)
        guard let info = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" &&
                parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ToolError.message(AppText.text("这不是有效的 IPA 安装包")) }
        let plist = try readPlist(info, archive: archive)
        return Set(plist["CFBundleSupportedPlatforms"] as? [String] ?? [])
    }

    /// What the package itself says it runs on, for showing the user which
    /// platform a downloaded file really is (not what was requested).
    static func describePlatforms(families: Set<Int>, platforms: Set<String>) -> String {
        let names: [(Int, String)] = [(1, "iPhone"), (2, "iPad"), (3, "Apple TV"), (4, "Apple Watch"), (6, "Mac"), (7, "Vision Pro")]
        let devices = names.filter { families.contains($0.0) }.map(\.1)
        // Device names only; the raw platform identifiers mean nothing to users.
        if devices.isEmpty { return platforms.contains("AppleTVOS") ? "Apple TV" : AppText.text("未知") }
        return ListFormatter.localizedString(byJoining: devices)
    }

    static func platformSummary(_ url: URL) throws -> String {
        describePlatforms(families: try deviceFamilies(url), platforms: try supportedPlatforms(url))
    }

    private static func readPlist(_ entry: Entry, archive: Archive) throws -> [String: Any] {
        let limit = 2 * 1024 * 1024
        guard entry.type == .file, entry.uncompressedSize <= UInt64(limit) else { throw ToolError.message(AppText.text("安装包已损坏")) }
        var data = Data()
        let checksum = try archive.extract(entry, consumer: {
            guard data.count + $0.count <= limit else { throw ToolError.message(AppText.text("安装包已损坏")) }
            data.append($0)
        })
        guard checksum == entry.checksum else { throw ToolError.message(AppText.text("安装包已损坏，请重新下载")) }
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToolError.message(AppText.text("安装包已损坏"))
        }
        return result
    }

    static func finish(staging: URL, id: UUID, asset: DownloadAsset?) throws -> (String, StoreApp) {
        let working = LocalResources.support.appendingPathComponent("\(id.uuidString).working.ipa")
        try? FileManager.default.removeItem(at: working)
        try FileManager.default.copyItem(at: staging, to: working)
        defer { try? FileManager.default.removeItem(at: working) }
        var stagingMetadata: [String: Any]?
        if let asset = asset {
            guard let sinf = asset.sinf, !sinf.isEmpty, let metadata = asset.metadata else {
                throw ToolError.message(AppText.text("下载授权缺失，请重新下载"))
            }
            let archive = try Archive(url: working, accessMode: .update)
            if let existingMetadataEntry = archive["iTunesMetadata.plist"] {
                stagingMetadata = try? readPlist(existingMetadataEntry, archive: archive)
            }

            // 1. Write / Update iTunesMetadata.plist
            try replace("iTunesMetadata.plist", data: metadata, archive: archive)

            // 2. Replicate SINFs for all binaries (ipatool parity)
            let allSinfs = (asset.sinfs?.isEmpty == false) ? asset.sinfs! : [sinf]
            var sinfReplicated = false

            // Look for Manifest.plist in Payload/*.app/SC_Info/Manifest.plist
            if let manifestEntry = archive.first(where: { entry in
                let parts = entry.path.split(separator: "/")
                return parts.count == 4 && parts[0] == "Payload" && parts[1].hasSuffix(".app") &&
                    parts[2] == "SC_Info" && parts[3] == "Manifest.plist"
            }) {
                let manifestData = try readPlist(manifestEntry, archive: archive)
                guard let sinfPaths = manifestData["SinfPaths"] as? [String], !sinfPaths.isEmpty else {
                    throw ToolError.message(AppText.text("安装包的多组件授权清单无效"))
                }
                let parts = manifestEntry.path.split(separator: "/")
                let bundleFolder = String(parts[1])
                for target in try sinfTargets(paths: sinfPaths, sinfs: allSinfs, bundleFolder: bundleFolder) {
                    try replace(target.path, data: target.data, archive: archive)
                }
                sinfReplicated = true
            }

            // Fallback for packages without Manifest.plist
            if !sinfReplicated {
                let supplemental = archive.first { entry in
                    let parts = entry.path.split(separator: "/")
                    return parts.count == 4 && parts[0] == "Payload" && parts[1].hasSuffix(".app") &&
                        parts[2] == "SC_Info" && parts[3].hasSuffix(".supp")
                }
                let existingSinf = archive.first { entry in
                    let parts = entry.path.split(separator: "/")
                    return parts.count == 4 && parts[0] == "Payload" && parts[1].hasSuffix(".app") &&
                        parts[2] == "SC_Info" && parts[3].hasSuffix(".sinf")
                }
                if let sourcePath = supplemental?.path ?? existingSinf?.path {
                    var sinfPath = sourcePath
                    if sinfPath.hasSuffix(".supp") { sinfPath = String(sinfPath.dropLast(5)) + ".sinf" }
                    sinfPath = sinfPath.replacingOccurrences(of: #"\.v\d+(?=\.sinf$)"#, with: "", options: .regularExpression)
                    try replace(sinfPath, data: sinf, archive: archive)
                } else if let mainApp = archive.first(where: { entry in
                    let parts = entry.path.split(separator: "/")
                    return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
                }), let infoPlist = try? readPlist(mainApp, archive: archive),
                   let executable = infoPlist["CFBundleExecutable"] as? String {
                    let parts = mainApp.path.split(separator: "/")
                    let bundleFolder = String(parts[1])
                    let targetPath = "Payload/\(bundleFolder)/SC_Info/\(executable).sinf"
                    try replace(targetPath, data: sinf, archive: archive)
                } else {
                    throw ToolError.message(AppText.text("安装包缺少授权信息，无法使用"))
                }
            }
        }
        var app = try inspect(working)
        if let asset = asset {
            let platform = asset.platform.lowercased()
            if platform == "appletvos" || platform == "tvos" || platform == "atv9" {
                guard try deviceFamilies(working).contains(3),
                      try supportedPlatforms(working).contains("AppleTVOS") else {
                    throw ToolError.message(AppText.text("下载的文件不支持 Apple TV"))
                }
            } else if platform == "ipad" {
                guard try deviceFamilies(working).contains(2) else {
                    throw ToolError.message(AppText.text("此安装包不支持 iPad"))
                }
            }
            try verifyPackageMatchesAsset(package: app, stagingMetadata: stagingMetadata, asset: asset)
            app.id = asset.app.id
            if (app.externalVersionID ?? "").isEmpty {
                app.externalVersionID = asset.app.externalVersionID
            }
        }
        let filename = "\(id.uuidString)-\(filenameComponent(app.name, limit: 100))_\(filenameComponent(app.version, limit: 40)).ipa"
        let destination = LocalResources.packages.appendingPathComponent(filename)
        // A retry or identifier collision must not delete an existing user package.
        try? FileManager.default.createDirectory(at: LocalResources.packages, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: working, to: destination)
        return (filename, app)
    }

    static func verifyPackageMatchesAsset(package: StoreApp, stagingMetadata: [String: Any]?, asset: DownloadAsset) throws {
        let mismatch = ToolError.message(AppText.text("下载的文件与所选应用或版本不一致，请重试"))
        guard !package.bundleID.isEmpty, package.bundleID == asset.app.bundleID else { throw mismatch }

        let dispatchMetadata = asset.decodedMetadata
        if let dispatchBundleID = dispatchMetadata.map({ plistString($0["softwareVersionBundleId"]) }),
           !dispatchBundleID.isEmpty, dispatchBundleID != package.bundleID {
            throw mismatch
        }

        let expectedExt = (asset.app.externalVersionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dispatchExt = dispatchMetadata.map { plistString($0["softwareVersionExternalIdentifier"]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let stagingExt = stagingMetadata.map { plistString($0["softwareVersionExternalIdentifier"]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if !expectedExt.isEmpty && !dispatchExt.isEmpty && expectedExt != dispatchExt { throw mismatch }
        if !expectedExt.isEmpty && !stagingExt.isEmpty && expectedExt != stagingExt { throw mismatch }
        if !asset.app.id.isEmpty, asset.app.id.allSatisfy(\.isNumber),
           let stagingItemID = stagingMetadata.map({ plistString($0["itemId"]).trimmingCharacters(in: .whitespacesAndNewlines) }),
           !stagingItemID.isEmpty, stagingItemID != asset.app.id {
            throw mismatch
        }

        let packageShort = package.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageBuild = (package.bundleVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assetShort = asset.app.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let dispatchShort = dispatchMetadata.map { plistString($0["bundleShortVersionString"]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let dispatchBuild = dispatchMetadata.map { plistString($0["bundleVersion"]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let marketing = (asset.app.storeMarketingVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // When Apple DownloadDispatch echoes a dotless live short version (e.g. "4800") alongside
        // a dotted historical `bundleVersion` (e.g. "2.0.02"), only treat `dispatchShort` as an
        // acceptable IPA short string when the build number does not contradict it.
        var allowedShorts = [assetShort, dispatchBuild, marketing].filter { !$0.isEmpty }
        if !dispatchShort.isEmpty {
            let allowStaleDispatchShort = packageBuild.isEmpty || dispatchBuild.isEmpty || packageBuild == dispatchBuild ||
                VersionService.versionPreference(dispatchShort) >= VersionService.versionPreference(dispatchBuild)
            if allowStaleDispatchShort { allowedShorts.append(dispatchShort) }
        }

        let directMatch = !packageShort.isEmpty && allowedShorts.contains(packageShort)
        let compatibleMarketingMatch = !packageShort.isEmpty && !marketing.isEmpty &&
            (expectedExt.isEmpty || dispatchExt.isEmpty || expectedExt == dispatchExt) &&
            VersionService.compatibleMarketingPrecision(marketing, buildRaw: packageShort) != nil
        let legacyEmptyShortBuildMatch = packageShort.isEmpty && !packageBuild.isEmpty &&
            !dispatchBuild.isEmpty && packageBuild == dispatchBuild
        guard directMatch || compatibleMarketingMatch || legacyEmptyShortBuildMatch else { throw mismatch }
    }

    static func sinfTargets(paths: [String], sinfs: [Data], bundleFolder: String) throws -> [(path: String, data: Data)] {
        guard !paths.isEmpty, paths.count == sinfs.count else {
            throw ToolError.message(AppText.text("应用的多组件授权数量与安装包不匹配，请重新下载"))
        }
        var seen = Set<String>()
        return try zip(paths, sinfs).map { pair in
            let (relative, data) = pair
            guard !relative.hasPrefix("/"), relative.hasSuffix(".sinf"), isSafeArchivePath(relative) else {
                throw ToolError.message(AppText.text("安装包中的授权路径无效"))
            }
            let fullPath = "Payload/\(bundleFolder)/\(relative)"
            guard isSafeArchivePath(fullPath), seen.insert(fullPath).inserted else {
                throw ToolError.message(AppText.text("安装包中的授权路径无效"))
            }
            return (fullPath, data)
        }
    }

    private static func replace(_ path: String, data: Data, archive: Archive) throws {
        guard isSafeArchivePath(path) else { throw ToolError.message(AppText.text("安装包已损坏")) }
        if let entry = archive[path] { try archive.remove(entry) }
        // Use the file API rather than depending on a version-specific Provider integer type.
        let scratch = LocalResources.support.appendingPathComponent("entry-\(UUID().uuidString)", isDirectory: true)
        let file = scratch.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try data.write(to: file, options: .atomic)
        try archive.addEntry(with: path, relativeTo: scratch, compressionMethod: .deflate)
    }

    static func isSafeArchivePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.contains("\\") && !path.contains("\0") && !parts.isEmpty &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func safeName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t").union(.controlCharacters)
        let value = name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "App" : String(value.prefix(80))
    }

    private static func filenameComponent(_ value: String, limit: Int) -> String {
        var result = "", bytes = 0
        for character in safeName(value) {
            let count = String(character).utf8.count
            if bytes + count > limit { break }
            result.append(character); bytes += count
        }
        return result.isEmpty ? "App" : result
    }
}
