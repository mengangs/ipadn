import Foundation

enum ToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum AppPlatform: String, Codable, CaseIterable, Identifiable {
    case iOS = "itunes", tvOS = "atv9"
    var id: String { rawValue }
    var title: String { self == .iOS ? "iOS" : "tvOS" }
}

struct StoreContext: Codable, Equatable {
    var country = "CN"
    var platform: AppPlatform = .iOS
}

struct StoreApp: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var bundleID = ""
    var version = ""
    var iconURL: URL?
    var description = ""
    var category = ""
    var size: Int64 = 0
    var price = "免费"
    var rating: Double = 0
    var minimumOS = ""
    var externalVersionID: String?
}

struct AppVersion: Codable, Identifiable, Hashable {
    var id: String
    var version: String
    var source: String
}

struct AppleAccount: Codable, Identifiable {
    var id: String
    var name: String
    var password: String
    var cookie: String
    var dsid: String
    var passwordToken: String
    var storeFront: String
    var fullStoreFront: String
}

struct DownloadAsset: Codable {
    var app: StoreApp
    var url: URL
    var sinf: Data?
    var metadata: Data?
    var externalVersionIDs: [String]
    var platform: String
    var account: String
}

struct OwnedApp: Codable, Identifiable {
    var id: String
    var bundleID: String
    var name: String
    var version: String
    var purchaseDate: Date?
    var storeApp: StoreApp {
        StoreApp(id: id, name: name, bundleID: bundleID, version: version)
    }
}

enum DownloadStatus: String, Codable {
    case queued, running, pausing, paused, processing, completed, failed
    var title: String {
        switch self {
        case .queued: return "等待下载"
        case .running: return "下载中"
        case .pausing: return "正在暂停"
        case .paused: return "已暂停"
        case .processing: return "正在处理安装包"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        }
    }
}

struct DownloadJob: Codable, Identifiable {
    var id = UUID()
    var app: StoreApp
    var asset: DownloadAsset?
    var sourceURL: URL?
    var status: DownloadStatus = .queued
    var downloaded: Int64 = 0
    var expected: Int64 = 0
    var localFilename: String?
    var error: String?
    var createdAt = Date()
    var progress: Double { expected > 0 ? min(1, Double(downloaded) / Double(expected)) : 0 }
    var account: String? { asset?.account }
}

struct ToolSettings: Codable, Equatable {
    var store = StoreContext()
    var maxConcurrentDownloads = 3
    var maxQueuedDownloads = 10
    var searchLimit = 30
    var notifications = true
    var useSignerCache = true
    var appearance = "system"
    var plistServer = ""
    var versionSources: [VersionSource] = [
        VersionSource(name: "Timbrd", urlTemplate: "https://api.timbrd.com/apple/app-version/index.php?id={id}", containerKey: "", reverse: true),
        VersionSource(name: "Bilin", urlTemplate: "https://apis.bilin.eu.org/history/{id}", containerKey: "data", reverse: false)
    ]
}

struct VersionSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var urlTemplate: String
    var containerKey: String
    var reverse: Bool
    var enabled = true
}

enum SearchQuery: Equatable {
    case keyword(String), appID(String, versionID: String?)

    static func parse(_ input: String) throws -> SearchQuery {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError.message("请输入应用名称、App ID 或 App Store 链接") }
        if let url = URL(string: text), url.host?.lowercased() == "apps.apple.com" {
            let parts = url.pathComponents
            if let id = parts.first(where: { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count > 2 }) {
                return .appID(String(id.dropFirst(2)), versionID: nil)
            }
            throw ToolError.message("App Store 链接中没有有效 App ID")
        }
        let parts = text.components(separatedBy: CharacterSet(charactersIn: " ,，:/+\t\n")).filter { !$0.isEmpty }
        if (1...2).contains(parts.count), parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return .appID(parts[0], versionID: parts.count == 2 ? parts[1] : nil)
        }
        return .keyword(text)
    }
}

enum LocalResources {
    static let settings = "storage_downloadConfig"
    static let searchHistory = "storage_searchHistory"
    static let guid = "storage_appleStoreMac"
    static let accounts = "keychain_appleStoreLogin"
    static let activeAccount = "storage_activeAccount"
    static let jobsFilename = "download-jobs.json"
    static let versionsFilename = "versions.json"
    static let ownedFilename = "owned-apps.json"

    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPATool", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return url
    }
    static var packages: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Packages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return url
    }
    static func resumeURL(_ id: UUID) -> URL { support.appendingPathComponent("\(id.uuidString).resume") }
    static func stagingURL(_ id: UUID) -> URL { support.appendingPathComponent("\(id.uuidString).download") }
    static func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent(filename)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, filename: String) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: support.appendingPathComponent(filename), options: .atomic)
    }
}

extension Int64 {
    var byteLabel: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

func plistString(_ value: Any?) -> String {
    guard let value = value else { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}
