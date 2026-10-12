import Foundation
import Combine

struct SearchHistoryItem: Codable, Identifiable {
    var id: String { term }
    var term: String
    var count: Int
    var lastUsed: Date
}

@MainActor
final class ToolStore: ObservableObject {
    let signer = SAPSigner()
    let versions = VersionService()
    let downloads: DownloadManager
    let installation = InstallationService()
    lazy var apple = AppleService(signer: signer)
    @Published var settings: ToolSettings {
        didSet {
            do { UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: LocalResources.settings) }
            catch { errorMessage = "设置保存失败：" + error.localizedDescription }
            downloads.configure(settings)
        }
    }
    @Published var tab = 0
    @Published var searchText = ""
    @Published private(set) var searchError: String?
    @Published private(set) var lastSearchTerm = ""
    @Published private(set) var favorites = LocalResources.load([StoreApp].self, filename: "favorites.json") ?? []
    @Published private(set) var ownedRevision = UUID()
    @Published private(set) var avatars: [String: Data] = [:]
    @Published private(set) var ownedError: String?
    @Published private(set) var results: [StoreApp] = []
    @Published private(set) var localResults: [StoreApp] = []
    private var appCatalog = LocalResources.load([String: [StoreApp]].self, filename: "app-catalog.json") ?? [:]
    @Published private(set) var searching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var searchHistory: [SearchHistoryItem] = []
    @Published private(set) var owned: [OwnedApp] = []
    @Published private(set) var ownedLoading = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    #if DEBUG
    private var visualPreview = false
    #endif
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()
    private var ownedByAccount = LocalResources.load([String: [OwnedApp]].self, filename: LocalResources.ownedFilename) ?? [:]
    private var subscriptions = Set<AnyCancellable>()

    init(downloadManager: DownloadManager? = nil) {
        downloads = downloadManager ?? DownloadManager()
        if let data = UserDefaults.standard.data(forKey: LocalResources.settings),
           let saved = try? JSONDecoder().decode(ToolSettings.self, from: data) { settings = saved }
        else { settings = ToolSettings() }
        if let data = UserDefaults.standard.data(forKey: LocalResources.searchHistory) {
            searchHistory = (try? JSONDecoder().decode([SearchHistoryItem].self, from: data)) ?? []
        }
        if ["https://api.scripting.fun/ipa-plist", "https://xiaobai.app/install"].contains(settings.plistServer) { settings.plistServer = "" }
        downloads.configure(settings)
        for account in apple.accounts {
            avatars[account.id] = try? Data(contentsOf: AvatarStorage.url(account.id))
        }
        apple.$activeID.sink { [weak self] id in
            guard let self = self else { return }
            self.ownedRevision = UUID()
            self.ownedError = nil
            self.owned = id.flatMap { self.ownedByAccount[$0] } ?? []
        }.store(in: &subscriptions)
    }

    func search(_ text: String? = nil) {
        if let text = text { searchText = text }
        let input = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { clearSearch(); return }
        searchTask?.cancel()
        let id = UUID(); searchID = id
        let context = settings.store
        let limit = settings.searchLimit
        if input != lastSearchTerm { results = [] }
        localResults = []
        if case .keyword(let term)? = try? SearchQuery.parse(input) {
            let known = owned.map(\.storeApp) + favorites + downloads.jobs.map(\.app) + (appCatalog[context.platform.rawValue] ?? [])
            localResults = AppSearchIndex.search(term, apps: known)
        }
        searching = true; hasSearched = true; searchError = nil; lastSearchTerm = input
        searchTask = Task {
            defer { if self.searchID == id { self.searching = false } }
            do {
                let query = try SearchQuery.parse(input)
                let apps: [StoreApp]
                if case .appID(let appID, let versionID) = query, versionID != nil {
                    let asset = try await apple.asset(appID: appID, versionID: versionID, store: context, useCache: settings.useSignerCache)
                    apps = [asset.app]
                } else {
                    let publicResults = try await StoreService.search(query, store: context, limit: limit)
                    if publicResults.isEmpty, case .appID(let appID, _) = query, apple.active != nil {
                        apps = [try await apple.asset(appID: appID, versionID: nil, store: context, useCache: settings.useSignerCache).app]
                    } else { apps = publicResults }
                }
                try Task.checkCancellation()
                guard searchID == id else { return }
                results = apps
                let remoteIDs = Set(apps.map(\.id))
                localResults.removeAll { remoteIDs.contains($0.id) }
                let key = context.platform.rawValue
                appCatalog[key] = Array(AppSearchIndex.unique(apps + (appCatalog[key] ?? [])).prefix(1000))
                try? LocalResources.save(appCatalog, filename: "app-catalog.json")
                remember(input)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, searchID == id { searchError = error.localizedDescription }
            }
        }
    }
    func cancelSearch() { searchTask?.cancel(); searchID = UUID(); searching = false; hasSearched = !results.isEmpty || !localResults.isEmpty; searchError = nil }
    func clearSearch() { cancelSearch(); searchText = ""; results = []; localResults = []; hasSearched = false; lastSearchTerm = "" }
    func isFavorite(_ app: StoreApp) -> Bool { favorites.contains { $0.id == app.id } }
    func toggleFavorite(_ app: StoreApp) {
        var next = favorites
        if next.contains(where: { $0.id == app.id }) { next.removeAll { $0.id == app.id } }
        else { next.insert(app, at: 0) }
        do { try LocalResources.save(next, filename: "favorites.json"); favorites = next }
        catch { errorMessage = "收藏保存失败：" + error.localizedDescription }
    }

    private func remember(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = searchHistory.firstIndex(where: { $0.term == term }) {
            var item = searchHistory.remove(at: index); item.count += 1; item.lastUsed = Date(); searchHistory.insert(item, at: 0)
        } else { searchHistory.insert(SearchHistoryItem(term: term, count: 1, lastUsed: Date()), at: 0) }
        searchHistory = Array(searchHistory.prefix(50)); persistHistory()
    }
    func removeHistory(_ term: String) { searchHistory.removeAll { $0.term == term }; persistHistory() }
    func clearHistory() { searchHistory.removeAll(); persistHistory() }
    private func persistHistory() {
        if let data = try? JSONEncoder().encode(searchHistory) { UserDefaults.standard.set(data, forKey: LocalResources.searchHistory) }
    }

    func loadVersions(for app: StoreApp, force: Bool = false, official: Bool = false) async throws -> [AppVersion] {
        #if DEBUG
        if visualPreview { return [AppVersion(id: "123456789", version: "3.2.1", source: "版本资料"), AppVersion(id: "123456788", version: "3.1.0", source: "版本资料")] }
        #endif
        let context = settings.store
        if official || context.platform == .tvOS {
            let asset = try await apple.asset(appID: app.id, versionID: nil, store: context, useCache: settings.useSignerCache)
            let third = context.platform == .iOS ? (try? await versions.thirdParty(app.id, sources: settings.versionSources, force: force)) ?? [] : []
            let names = Dictionary(third.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
            let ids = asset.externalVersionIDs.isEmpty ? [asset.app.externalVersionID ?? ""] : Array(asset.externalVersionIDs.reversed())
            var seen = Set<String>()
            return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { id in
                AppVersion(id: id, version: id == asset.app.externalVersionID ? asset.app.version : names[id] ?? "未知版本", source: "Apple")
            }
        }
        return try await versions.thirdParty(app.id, sources: settings.versionSources, force: force)
    }

    func startDownload(app: StoreApp, versionID: String?) async throws {
        let asset = try await apple.asset(appID: app.id, versionID: versionID, store: settings.store, useCache: settings.useSignerCache)
        try downloads.enqueue(asset)
        tab = 1
    }

    func refreshDownload(_ job: DownloadJob) async throws {
        guard job.status == .failed, job.asset != nil else { throw ToolError.message("只有失败的 Apple 下载任务可以刷新链接") }
        guard apple.activeID == job.account else { throw ToolError.message("请先切换至原下载账号：\(job.account ?? "")") }
        let platform: AppPlatform = job.asset?.platform.lowercased() == "ios" ? .iOS : .tvOS
        let asset = try await apple.asset(appID: job.app.id, versionID: job.asset?.app.externalVersionID,
            store: StoreContext(country: settings.store.country, platform: platform), useCache: settings.useSignerCache)
        // Enqueue first; retain the failed task if refreshing or saving the replacement fails.
        try downloads.enqueue(asset)
        try downloads.remove(job.id)
        tab = 1
    }

    func refreshOwned() async {
        guard !ownedLoading, let id = apple.activeID else {
            if apple.activeID == nil { errorMessage = "请先在账号页登录" }
            return
        }
        ownedLoading = true; ownedError = nil
        defer { ownedLoading = false }
        do {
            let apps = try await apple.ownedApps(useCache: settings.useSignerCache)
            guard apple.activeID == id else { return }
            let cached = Dictionary(owned.map { ($0.id, $0.iconURL) }, uniquingKeysWith: { first, _ in first })
            owned = apps.map { app in
                var item = app
                if item.iconURL == nil { item.iconURL = cached[item.id] ?? nil }
                return item
            }
            ownedByAccount[id] = owned
            ownedRevision = UUID()
            try LocalResources.save(ownedByAccount, filename: LocalResources.ownedFilename)
        } catch is CancellationError { }
        catch { if apple.activeID == id { ownedError = error.localizedDescription } }
    }
    func avatarData(for id: String) -> Data? { avatars[id] }
    func setAvatar(_ data: Data?, for id: String) throws {
        guard apple.accounts.contains(where: { $0.id == id }) else { return }
        let url = AvatarStorage.url(id)
        if let data { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        avatars[id] = data
    }

    func loadOwnedArtwork() async {
        guard let account = apple.activeID else { return }
        let context = settings.store
        let revision = ownedRevision
        let ids = owned.filter { $0.iconURL == nil }.map(\.id)
        for offset in stride(from: 0, to: ids.count, by: 20) {
            do {
                try Task.checkCancellation()
                let urls = try await StoreService.artwork(Array(ids[offset..<min(offset + 20, ids.count)]), store: context)
                try Task.checkCancellation()
                guard apple.activeID == account, settings.store == context, ownedRevision == revision else { return }
                for index in owned.indices { if let url = urls[owned[index].id] { owned[index].iconURL = url } }
                ownedByAccount[account] = owned
                try LocalResources.save(ownedByAccount, filename: LocalResources.ownedFilename)
                // Keep the public lookup service below its documented request budget.
                if offset + 20 < ids.count { try await Task.sleep(nanoseconds: 3_100_000_000) }
            } catch { return } // Artwork is optional; purchase records remain usable offline.
        }
    }

    func deleteAccount(_ id: String) throws {
        try apple.remove(id)
        avatars.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: AvatarStorage.url(id))
        ownedByAccount.removeValue(forKey: id)
        try LocalResources.save(ownedByAccount, filename: LocalResources.ownedFilename)
    }

    func handleURL(_ url: URL) {
        if url.isFileURL {
            tab = 1
            Task { do { try await downloads.importFile(url) } catch { errorMessage = error.localizedDescription } }
        } else if url.scheme == "ipadn" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let id = components?.queryItems?.first(where: { $0.name == "id" })?.value { tab = 0; search(id) }
            else if let address = components?.queryItems?.first(where: { $0.name == "url" })?.value,
                    let download = URL(string: address) {
                do { try downloads.enqueueURL(download); tab = 1 } catch { errorMessage = error.localizedDescription }
            }
        } else if url.host == "apps.apple.com" { tab = 0; search(url.absoluteString) }
    }

    func exportDiagnostics() throws -> URL {
        let details = [
            "iPadn " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""), "Platform: \(settings.store.platform.title)", "Region: \(settings.store.country)",
            "Jobs: \(downloads.jobs.count)", "Concurrent limit: \(settings.maxConcurrentDownloads)",
            "Version sources: \(settings.versionSources.filter(\.enabled).count)",
            "Task states: " + downloads.jobs.map { "\($0.id.uuidString.prefix(8)): \($0.status.rawValue)" }.joined(separator: ", "),
            "Contains no credentials, cookies, Apple account names or download URLs."
        ].joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iPadn-Diagnostics.txt")
        try details.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}


#if DEBUG
extension ToolStore {
    func prepareVisualPreview() {
        visualPreview = true
        results = []; hasSearched = false; searchText = ""
        favorites = [StoreApp(id: "preview-app", name: "像素日记", bundleID: "example.pixel", version: "3.2", category: "摄影与录像", size: 128_000_000)]
        searchHistory = [SearchHistoryItem(term: "效率工具", count: 3, lastUsed: Date()), SearchHistoryItem(term: "照片编辑", count: 1, lastUsed: Date())]
    }
}
#endif
