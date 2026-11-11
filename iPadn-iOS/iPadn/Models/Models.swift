import Foundation

enum ToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// The download queue is full. A batch stops on this instead of retrying each
/// remaining app, and it stays readable in any language.
struct DownloadQueueLimitError: LocalizedError {
    /// False for downloads that don't come from the settings page.
    var mentionsSettings = true
    var errorDescription: String? {
        mentionsSettings ? AppText.text("已达到等待任务上限，可在设置中调整") : AppText.text("已达到等待任务上限")
    }
}

/// A non-2xx response, kept typed so callers can tell "not found" apart.
struct HTTPStatusError: LocalizedError {
    let code: Int
    var errorDescription: String? { code == 404 ? AppText.text("找不到相关内容") : AppText.text("网络请求失败（\(code)），请稍后重试") }
}

enum AppErrorMessage {
    static func forSearch(_ error: Error) -> String {
        if error is CancellationError { return "" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return AppText.text("网络连接暂时不可用，请检查网络后重试。")
        }
        if error is AppleAuthError || error is AppleLoginError {
            return AppText.text("请到「账号」中重新登录 Apple 账号后再试。")
        }
        let message = error.localizedDescription
        if message.contains("2002") || message.contains("Your password has changed") {
            return AppText.text("Apple 账号需要重新登录，请到「账号」页面更新密码。")
        }
        if let status = error as? HTTPStatusError {
            return AppText.text("商店暂时无法返回结果（\(status.code)），请稍后重试或更换地区。")
        }
        if message.contains("HTTP") || message.contains("JSON") || message.contains("itunes.apple.com") {
            return AppText.text("商店暂时无法返回结果，请稍后重试或更换地区。")
        }
        return AppText.text("暂时无法完成搜索，请稍后重试。")
    }
}
 
enum AppPlatform: String, Codable, CaseIterable, Identifiable {
    case iOS = "itunes", iPadOS = "ipad", tvOS = "atv9", macOS = "mac"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iOS: return "iOS"
        case .iPadOS: return "iPad"
        case .tvOS: return "tvOS"
        case .macOS: return "Mac"
        }
    }
    var symbol: String {
        switch self {
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        case .tvOS: return "appletv"
        case .macOS: return "macbook"
        }
    }
    var supportsIPA: Bool { self != .macOS }
    var usesIOSStore: Bool { self == .iOS || self == .iPadOS }
    var searchEntity: String {
        switch self {
        case .iOS: return "software"
        case .iPadOS: return "iPadSoftware"
        case .tvOS: return "software,tvSoftware"
        case .macOS: return "macSoftware"
        }
    }
    var catalogPlatform: String { self == .iPadOS ? AppPlatform.iOS.rawValue : rawValue }
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
    var price = ""
    /// The listing's price as a number and its ISO currency, from the lookup API.
    var priceValue: Double?
    var currency: String?
    /// Free apps come back without a price; older saves stored the word itself.
    var isFree: Bool { price.isEmpty || price == "免费" }
    var priceLabel: String { isFree ? AppText.text("免费") : price }
    var rating: Double = 0
    var minimumOS = ""
    var externalVersionID: String?
    var developerURL: URL?
    // tvSoftware search is unavailable for some storefronts; candidate
    // listings are not proof of compatibility with Apple TV.
    var tvOSCandidate: Bool?
    // No public listing in any storefront (removed from sale); the App ID
    // still works for accounts that own it.
    var delisted: Bool?
    static let delistedPlaceholder = "未在公开商店找到"
    var isDelisted: Bool { delisted == true || category == Self.delistedPlaceholder }
    /// Category for display; never the legacy delisted placeholder.
    var displayCategory: String { category == Self.delistedPlaceholder ? "" : category }
}

struct AppVersion: Codable, Identifiable, Hashable {
    /// Version lists from Apple carry only IDs. The placeholder is data, not
    /// display text: it is stored, merged and compared, so it stays fixed.
    static let unknown = "未知版本"
    var id: String
    var version: String
    var source: String
}

/// Every third-party version source failed. Typed so the page can tell this
/// apart from "this account doesn't own the app".
struct VersionListUnavailableError: LocalizedError {
    var errorDescription: String? {
        AppText.text("暂时无法获取历史版本，可打开「从 Apple 获取完整版本列表」或手动输入版本 ID")
    }
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
    var sinfs: [Data]?
    var metadata: Data?
    var externalVersionIDs: [String]
    var platform: String
    var account: String

    init(app: StoreApp, url: URL, sinf: Data? = nil, sinfs: [Data]? = nil,
         metadata: Data? = nil, externalVersionIDs: [String] = [],
         platform: String = "", account: String = "") {
        self.app = app
        self.url = url
        self.sinf = sinf ?? sinfs?.first
        self.sinfs = sinfs ?? sinf.map { [$0] }
        self.metadata = metadata
        self.externalVersionIDs = externalVersionIDs
        self.platform = platform
        self.account = account
    }
}

struct OwnedApp: Codable, Identifiable {
    var id: String
    var bundleID: String
    var name: String
    var version: String
    var purchaseDate: Date?
    var iconURL: URL?
    var storeApp: StoreApp {
        StoreApp(id: id, name: name, bundleID: bundleID, version: version, iconURL: iconURL)
    }
}

enum DownloadStatus: String, Codable {
    case queued, running, pausing, paused, processing, completed, failed
    var title: String {
        switch self {
        case .queued: return AppText.text("等待下载")
        case .running: return AppText.text("下载中")
        case .pausing: return AppText.text("正在暂停")
        case .paused: return AppText.text("已暂停")
        case .processing: return AppText.text("正在处理安装包")
        case .completed: return AppText.text("已完成")
        case .failed: return AppText.text("下载失败")
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
    var packageIconScanned: Bool?
    // The cached icon of a tvOS job is the Apple TV catalog artwork.
    var appleTVArtwork: Bool?
    // Non-IPA downloads are saved as raw Mac files, never processed as an IPA.
    var rawFormat: String?
    // Mac App Store package that must be processed by StoreAgent on device;
    // its dpInfo lives in MacPackageSecrets until processing succeeds.
    var protectedMacPackage: Bool?
    var localFilename: String?
    var error: String?
    /// The download failed because its staging file could not be created:
    /// retrying in the foreground avoids the background session's sandbox.
    var foregroundFallback: Bool?
    var createdAt = Date()
    var progress: Double { expected > 0 ? min(1, max(0, Double(downloaded) / Double(expected))) : 0 }
    var account: String? { asset?.account }
    // IPA metadata usually contains no artwork; keep the App Store icon
    // already associated with the authorized download.
    func completing(with inspected: StoreApp) -> StoreApp {
        var completed = inspected
        completed.iconURL = inspected.iconURL ?? app.iconURL ?? asset?.app.iconURL
        return completed
    }
    func displayApp(packageIcon: URL?) -> StoreApp {
        var displayed = app
        displayed.iconURL = packageIcon ?? app.iconURL ?? asset?.app.iconURL
        return displayed
    }
    /// Where a newer version of this download would come from; nil for
    /// developer-site installers and files without an App ID.
    var updatePlatform: AppPlatform? {
        guard UInt64(app.id).map({ $0 > 0 }) == true else { return nil }
        if rawFormat != nil {
            return rawFormat == "pkg" && sourceURL?.host?.hasSuffix(".apple.com") == true ? .macOS : nil
        }
        switch platformLabel {
        case "tvOS": return .tvOS
        case "iPad": return .iPadOS
        default: return .iOS
        }
    }
    var updateKey: String? { updatePlatform.map { "\($0.rawValue)|\(app.id)" } }
    /// The version as the store names it. A finished IPA reports its own
    /// Info.plist version, which some apps number differently from the store.
    var storeVersion: String {
        let ticket = asset?.app.version ?? ""
        return ticket.isEmpty ? app.version : ticket
    }
    var platformLabel: String {
        if rawFormat != nil { return "Mac" }
        switch asset?.platform.lowercased() {
        case "appletvos", "tvos", "atv9": return "tvOS"
        case "ipad": return "iPad"
        case "ios", "iphoneos": return "iOS"
        default: return "IPA"
        }
    }
}

struct ToolSettings: Codable, Equatable {
    var store = StoreContext()
    var maxConcurrentDownloads = 3
    var maxQueuedDownloads = 10
    var searchLimit = 30
    var notifications = true
    /// Background checks for newer versions of downloaded apps, with a notification.
    var updateNotifications = true
    /// Background checks of followed apps (new version, price drop, removal), with a notification.
    var watchNotifications = true
    /// Checks GitHub for new iPadn releases, with a notification.
    var appUpdateCheck = true
    /// Storefronts compared on the price page and tracked for followed apps.
    var priceRegions = StoreRegions.defaultComparison
    /// Currency prices are converted to for comparison.
    var baseCurrency = "CNY"
    /// Use foreground in-process downloads to bypass nsurlsessiond sandbox issues on enterprise resigns.
    var compatibleDownloadMode = false
    /// Shows tools for advanced users: package contents, tokens, device ID.
    var proMode = false
    var useSignerCache = true
    var appearance = "system"
    /// 2 once the appearance default is following the system (1.7.0 saved its dark default).
    var appearanceSchema = 2
    var plistServer = ""
    /// One-tap installation through the public loopback certificate (default).
    var automaticInstallation = true
    var localInstallation = true
    var localInstallHost = ManifestBuilder.defaultLocalHost
    /// Install through the system installer over a loopback VPN and a pairing
    /// file, keeping the App Store purchase record. Takes precedence when on.
    var nativeInstallation = false
    var versionSources: [VersionSource] = [
        VersionSource(name: "Timbrd", urlTemplate: "https://api.timbrd.com/apple/app-version/index.php?id={id}", containerKey: "", reverse: true),
        VersionSource(name: "Bilin", urlTemplate: "https://apis.bilin.eu.org/history/{id}", containerKey: "data", reverse: false),
        VersionSource.iosDump
    ]
    /// 2 once the iosdump source was offered to lists saved before it existed.
    var versionSourcesSchema = 2

    init() { }
    private enum CodingKeys: String, CodingKey {
        case store, maxConcurrentDownloads, maxQueuedDownloads, searchLimit, notifications
        case useSignerCache, appearance, plistServer, versionSources, localInstallation, localInstallHost
        case automaticInstallation, updateNotifications, proMode, watchNotifications, priceRegions, baseCurrency, appUpdateCheck
        case appearanceSchema, compatibleDownloadMode, nativeInstallation, versionSourcesSchema
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        store = try values.decodeIfPresent(StoreContext.self, forKey: .store) ?? store
        maxConcurrentDownloads = min(6, max(1, try values.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? maxConcurrentDownloads))
        maxQueuedDownloads = min(100, max(1, try values.decodeIfPresent(Int.self, forKey: .maxQueuedDownloads) ?? maxQueuedDownloads))
        searchLimit = min(200, max(1, try values.decodeIfPresent(Int.self, forKey: .searchLimit) ?? searchLimit))
        notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
        updateNotifications = try values.decodeIfPresent(Bool.self, forKey: .updateNotifications) ?? updateNotifications
        proMode = try values.decodeIfPresent(Bool.self, forKey: .proMode) ?? proMode
        watchNotifications = try values.decodeIfPresent(Bool.self, forKey: .watchNotifications) ?? watchNotifications
        let regions = (try values.decodeIfPresent([String].self, forKey: .priceRegions) ?? priceRegions).filter { StoreRegions.codes.contains($0) }
        priceRegions = regions.isEmpty ? priceRegions : regions
        baseCurrency = try values.decodeIfPresent(String.self, forKey: .baseCurrency) ?? baseCurrency
        compatibleDownloadMode = try values.decodeIfPresent(Bool.self, forKey: .compatibleDownloadMode) ?? compatibleDownloadMode
        appUpdateCheck = try values.decodeIfPresent(Bool.self, forKey: .appUpdateCheck) ?? appUpdateCheck
        useSignerCache = try values.decodeIfPresent(Bool.self, forKey: .useSignerCache) ?? useSignerCache
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        if !["system", "light", "dark"].contains(appearance) { appearance = "system" }
        // 1.7.0 (the only version writing appUpdateCheck without appearanceSchema)
        // defaulted to dark and saved it like a choice: follow the system instead.
        if try values.decodeIfPresent(Int.self, forKey: .appearanceSchema) == nil,
           values.contains(.appUpdateCheck), appearance == "dark" { appearance = "system" }
        plistServer = try values.decodeIfPresent(String.self, forKey: .plistServer) ?? plistServer
        localInstallation = try values.decodeIfPresent(Bool.self, forKey: .localInstallation) ?? plistServer.isEmpty
        localInstallHost = ManifestBuilder.migratedLocalHost(try values.decodeIfPresent(String.self, forKey: .localInstallHost) ?? localInstallHost)
        automaticInstallation = try values.decodeIfPresent(Bool.self, forKey: .automaticInstallation) ?? automaticInstallation
        nativeInstallation = try values.decodeIfPresent(Bool.self, forKey: .nativeInstallation) ?? nativeInstallation
        versionSources = try values.decodeIfPresent([VersionSource].self, forKey: .versionSources) ?? versionSources
        // Lists saved before iosdump was a default get it once; removing it later sticks.
        if (try values.decodeIfPresent(Int.self, forKey: .versionSourcesSchema) ?? 1) < 2,
           !versionSources.contains(where: { $0.url(for: "1")?.host == VersionSource.iosDump.url(for: "1")?.host }) {
            versionSources.append(VersionSource.iosDump)
        }
        versionSourcesSchema = 2
    }
}

struct VersionSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var urlTemplate: String
    var containerKey: String
    var reverse: Bool
    var enabled = true

    static let iosDump = VersionSource(name: "iosdump", urlTemplate: "https://iosdump.apdoilaan.work/history/{appId}", containerKey: "data", reverse: false)
    /// Placeholders for the App ID; both spellings are in use.
    static let placeholders = ["{id}", "{appId}", "{appid}", "{APPID}"]
    var hasPlaceholder: Bool { Self.placeholders.contains { urlTemplate.contains($0) } }
    /// The request URL for `appID`, or nil when the template is not a usable https address.
    func url(for appID: String) -> URL? {
        guard hasPlaceholder else { return nil }
        let filled = Self.placeholders.reduce(urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)) {
            $0.replacingOccurrences(of: $1, with: appID)
        }
        guard let url = URL(string: filled), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

enum SearchQuery: Equatable {
    case keyword(String), appID(String, versionID: String?)

    static func parse(_ input: String) throws -> SearchQuery {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError.message(AppText.text("请输入应用名称、App ID 或 App Store 链接")) }
        if let url = URL(string: text), url.host?.lowercased() == "apps.apple.com" {
            let parts = url.pathComponents
            if let id = parts.first(where: { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) && $0.count > 2 }) {
                return .appID(String(id.dropFirst(2)), versionID: nil)
            }
            throw ToolError.message(AppText.text("App Store 链接中没有有效 App ID"))
        }
        let parts = text.components(separatedBy: CharacterSet(charactersIn: " ,，:/+\t\n")).filter { !$0.isEmpty }
        if (1...2).contains(parts.count), parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) {
            return .appID(parts[0], versionID: parts.count == 2 ? parts[1] : nil)
        }
        return .keyword(text)
    }
}

enum LocalResources {
    static var isPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--visual-preview")
        #else
        return false
        #endif
    }
    static var defaults: UserDefaults {
        isPreview ? UserDefaults(suiteName: "app.local.iPadn.visual-preview")! : .standard
    }
    static let settings = "storage_downloadConfig"
    static let searchHistory = "storage_searchHistory"
    static let guid = "storage_appleStoreMac"
    static let accounts = "keychain_appleStoreLogin"
    static let activeAccount = "storage_activeAccount"
    static let jobsFilename = "download-jobs.json"
    static let versionsFilename = "versions.json"
    static let ownedFilename = "owned-apps.json"

    // Resolved and created once per launch: these are read from list rows
    // many times a second, so they must not touch the file system each time.
    static let support: URL = prepared(
        (isPreview ? FileManager.default.temporaryDirectory.appendingPathComponent("iPadn-Preview/Support") :
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("iPadn", isDirectory: true))
    static let packages: URL = prepared(
        (isPreview ? FileManager.default.temporaryDirectory.appendingPathComponent("iPadn-Preview/Documents") :
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Packages", isDirectory: true))
    private static func prepared(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return url
    }
    @discardableResult
    static func ensureDirectoriesExist() -> Bool {
        let fm = FileManager.default
        let s = (try? fm.createDirectory(at: support, withIntermediateDirectories: true)) != nil
        let p = (try? fm.createDirectory(at: packages, withIntermediateDirectories: true)) != nil
        return s && p
    }
    static func resumeURL(_ id: UUID) -> URL { support.appendingPathComponent("\(id.uuidString).resume") }
    static func stagingURL(_ id: UUID) -> URL { support.appendingPathComponent("\(id.uuidString).download") }
    static func packageURL(_ filename: String) -> URL? {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else { return nil }
        let root = packages.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(filename).resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent() == root,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }
    static func load<T: Decodable>(_ type: T.Type, filename: String) -> T? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent(filename)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func loadChecked<T: Decodable>(_ type: T.Type, filename: String) throws -> T? {
        let file = support.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
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


enum VersionOrder {
    /// Dotted versions compared part by part ("1.10" is newer than "1.9",
    /// "2.0" equals "2.0.0").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
    private static func parts(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var result: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            // "3b2" counts as 3; anything without leading digits ends the comparison.
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard let value = Int(digits) else { return result }
            result.append(value)
        }
        return result
    }
}

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "全部", active = "进行中", paused = "已暂停", completed = "已完成", failed = "失败"
    var id: String { rawValue }
    /// Shown in menus and row headers; `rawValue` also tags the row identifiers.
    var title: String {
        switch self {
        case .all: return AppText.text("全部")
        case .active: return AppText.text("进行中")
        case .paused: return AppText.text("已暂停")
        case .completed: return AppText.text("已完成")
        case .failed: return AppText.text("失败")
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.stack"
        case .active: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }
    func includes(_ status: DownloadStatus) -> Bool {
        switch self {
        case .all: return true
        case .active: return [.queued, .running, .pausing, .processing].contains(status)
        case .paused: return status == .paused
        case .completed: return status == .completed
        case .failed: return status == .failed
        }
    }
}

extension DownloadStatus {
    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .running: return "arrow.down"
        case .pausing, .paused: return "pause.fill"
        case .processing: return "shippingbox"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark.circle"
        }
    }
}
