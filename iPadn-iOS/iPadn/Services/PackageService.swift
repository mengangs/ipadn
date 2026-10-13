import Foundation
import ZIPFoundation

enum PackageService {
    static func inspect(_ url: URL) throws -> StoreApp {
        let archive = try Archive(url: url, accessMode: .read)
        guard let info = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ToolError.message("这不是有效的 IPA 安装包") }
        let plist = try readPlist(info, archive: archive)
        let metadata: [String: Any]
        if let entry = archive["iTunesMetadata.plist"] { metadata = (try? readPlist(entry, archive: archive)) ?? [:] }
        else { metadata = [:] }
        let name = plistString(plist["CFBundleDisplayName"] ?? plist["CFBundleName"])
        let id = plistString(metadata["itemId"])
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return StoreApp(id: id.isEmpty ? UUID().uuidString : id, name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
                        bundleID: plistString(plist["CFBundleIdentifier"]), version: plistString(plist["CFBundleShortVersionString"]),
                        size: size, minimumOS: plistString(plist["MinimumOSVersion"]))
    }

    static func deviceFamilies(_ url: URL) throws -> Set<Int> {
        let archive = try Archive(url: url, accessMode: .read)
        guard let info = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" &&
                parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ToolError.message("这不是有效的 IPA 安装包") }
        let plist = try readPlist(info, archive: archive)
        return Set(plist["UIDeviceFamily"] as? [Int] ?? [])
    }

    static func supportedPlatforms(_ url: URL) throws -> Set<String> {
        let archive = try Archive(url: url, accessMode: .read)
        guard let info = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" &&
                parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ToolError.message("这不是有效的 IPA 安装包") }
        let plist = try readPlist(info, archive: archive)
        return Set(plist["CFBundleSupportedPlatforms"] as? [String] ?? [])
    }

    /// What the package itself says it runs on, for showing the user which
    /// platform a downloaded file really is (not what was requested).
    static func describePlatforms(families: Set<Int>, platforms: Set<String>) -> String {
        let names: [(Int, String)] = [(1, "iPhone"), (2, "iPad"), (3, "Apple TV"), (4, "Apple Watch"), (6, "Mac"), (7, "Vision Pro")]
        let devices = names.filter { families.contains($0.0) }.map(\.1)
        // Device names only; the raw platform identifiers mean nothing to users.
        if devices.isEmpty { return platforms.contains("AppleTVOS") ? "Apple TV" : "未知" }
        return devices.joined(separator: "、")
    }

    static func platformSummary(_ url: URL) throws -> String {
        describePlatforms(families: try deviceFamilies(url), platforms: try supportedPlatforms(url))
    }

    private static func readPlist(_ entry: Entry, archive: Archive) throws -> [String: Any] {
        let limit = 2 * 1024 * 1024
        guard entry.type == .file, entry.uncompressedSize <= UInt64(limit) else { throw ToolError.message("安装包已损坏") }
        var data = Data()
        let checksum = try archive.extract(entry, consumer: {
            guard data.count + $0.count <= limit else { throw ToolError.message("安装包已损坏") }
            data.append($0)
        })
        guard checksum == entry.checksum else { throw ToolError.message("安装包已损坏，请重新下载") }
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToolError.message("安装包已损坏")
        }
        return result
    }

    static func finish(staging: URL, id: UUID, asset: DownloadAsset?) throws -> (String, StoreApp) {
        let working = LocalResources.support.appendingPathComponent("\(id.uuidString).working.ipa")
        try? FileManager.default.removeItem(at: working)
        try FileManager.default.copyItem(at: staging, to: working)
        defer { try? FileManager.default.removeItem(at: working) }
        if let asset = asset {
            guard let sinf = asset.sinf, !sinf.isEmpty, let metadata = asset.metadata else {
                throw ToolError.message("下载授权缺失，请重新下载")
            }
            let archive = try Archive(url: working, accessMode: .update)
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
            guard let sourcePath = supplemental?.path ?? existingSinf?.path else { throw ToolError.message("安装包缺少授权信息，无法使用") }
            var sinfPath = sourcePath
            if sinfPath.hasSuffix(".supp") { sinfPath = String(sinfPath.dropLast(5)) + ".sinf" }
            sinfPath = sinfPath.replacingOccurrences(of: #"\.v\d+(?=\.sinf$)"#, with: "", options: .regularExpression)
            try replace("iTunesMetadata.plist", data: metadata, archive: archive)
            try replace(sinfPath, data: sinf, archive: archive)
        }
        var app = try inspect(working)
        if let asset = asset {
            let platform = asset.platform.lowercased()
            if platform == "appletvos" || platform == "tvos" || platform == "atv9" {
                guard try deviceFamilies(working).contains(3),
                      try supportedPlatforms(working).contains("AppleTVOS") else {
                    throw ToolError.message("下载的文件不支持 Apple TV")
                }
            } else if platform == "ipad" {
                guard try deviceFamilies(working).contains(2) else {
                    throw ToolError.message("此安装包不支持 iPad")
                }
            }
            guard app.bundleID == asset.app.bundleID, app.version == asset.app.version else {
                throw ToolError.message("下载的文件与所选应用或版本不一致，请重试")
            }
            app.id = asset.app.id
            app.externalVersionID = asset.app.externalVersionID
        }
        let filename = "\(id.uuidString)-\(filenameComponent(app.name, limit: 100))_\(filenameComponent(app.version, limit: 40)).ipa"
        let destination = LocalResources.packages.appendingPathComponent(filename)
        // A retry or identifier collision must not delete an existing user package.
        try FileManager.default.moveItem(at: working, to: destination)
        return (filename, app)
    }

    private static func replace(_ path: String, data: Data, archive: Archive) throws {
        guard isSafeArchivePath(path) else { throw ToolError.message("安装包已损坏") }
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
