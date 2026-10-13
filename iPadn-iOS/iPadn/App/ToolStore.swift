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
            do { LocalResources.defaults.set(try JSONEncoder().encode(settings), forKey: LocalResources.settings) }
            catch { errorMessage = "设置保存失败：" + error.localizedDescription }
            downloads.configure(settings)
        }
    }
    @Published var tab = 0
    @Published var searchText = ""
    @Published private(set) var searchError: String?
    @Published private(set) var lastSearchTerm = ""
    @Published private(set) var favorites: [StoreApp] = []
    private var favoritesStorageError: String?
    private var ownedStorageError: String?
    @Published private(set) var ownedRevision = UUID()
    @Published private(set) var ownedError: String?
    @Published private(set) var results: [StoreApp] = []
    @Published private(set) var localResults: [StoreApp] = []
    private var appCatalog = LocalResources.load([String: [StoreApp]].self, filename: "app-catalog.json") ?? [:]
    private var nameCatalog = (LocalResources.load([AppNameEntry].self, filename: AppNameCatalog.cacheFile) ?? []) + AppNameCatalog.bundled()
    private var catalogRequested = false
    private var ownedAutoAttempted = Set<String>()
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
    private var ownedByAccount: [String: [OwnedApp]] = [:]
    private var subscriptions = Set<AnyCancellable>()

    init(downloadManager: DownloadManager? = nil) {
        downloads = downloadManager ?? DownloadManager()
        if let data = LocalResources.defaults.data(forKey: LocalResources.settings),
           let saved = try? JSONDecoder().decode(ToolSettings.self, from: data) { settings = saved }
        else { settings = ToolSettings() }
        do { favorites = try LocalResources.loadChecked([StoreApp].self, filename: "favorites.json") ?? [] }
        catch { favoritesStorageError = "收藏文件读取失败；已保留原文件。"; errorMessage = favoritesStorageError }
        do { ownedByAccount = try LocalResources.loadChecked([String: [OwnedApp]].self, filename: LocalResources.ownedFilename) ?? [:] }
        catch { ownedStorageError = "已购缓存读取失败；已保留原文件，不能覆盖其他账号记录。"; errorMessage = ownedStorageError }
        if let data = LocalResources.defaults.data(forKey: LocalResources.searchHistory) {
            searchHistory = (try? JSONDecoder().decode([SearchHistoryItem].self, from: data)) ?? []
        }
        if ["https://api.scripting.fun/ipa-plist", "https://xiaobai.app/install"].contains(settings.plistServer) { settings.plistServer = "" }
        downloads.configure(settings)
        apple.$activeID.sink { [weak self] id in
            guard let self = self else { return }
            self.ownedRevision = UUID()
            self.ownedError = nil
            self.owned = id.flatMap { self.ownedByAccount[$0] } ?? []
            self.updateLocalResults()
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
        results = []
        localResults = []
        updateLocalResults(for: input)
        searching = true; hasSearched = true; searchError = nil; lastSearchTerm = input
        searchTask = Task {
            defer { if self.searchID == id { self.searching = false } }
            do {
                let query = try SearchQuery.parse(input)
                // Public search must never trigger purchase or download authorization.
                // Searching an App ID should work even if saved Apple credentials expired.
                let accountCountry = StoreService.country(forStorefront: apple.active?.storeFront ?? "")
                var apps = try await StoreService.search(query, store: context, limit: limit, accountCountry: accountCountry)
                if case .appID(let appID, _) = query, apps.isEmpty {
                    // Delisted or region-limited apps have no public listing;
                    // the account may still own them, so keep the ID usable.
                    var fallback = knownApp(appID) ?? StoreApp(id: appID, name: "App \(appID)", price: "")
                    fallback.delisted = true
                    apps = [fallback]
                }
                if case .appID(_, let versionID) = query, let versionID {
                    apps = apps.map {
                        var result = $0
                        result.externalVersionID = versionID
                        return result
                    }
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
                await fillMissingArtwork(searchID: id, store: context, accountCountry: accountCountry)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, searchID == id {
                    searchError = AppErrorMessage.forSearch(error)
                }
            }
        }
    }
    private func knownApp(_ id: String) -> StoreApp? {
        let known = owned.map(\.storeApp) + favorites + downloads.jobs.map(\.app)
            + appCatalog.values.flatMap { $0 } + nameCatalog.map(\.app)
        guard var app = known.first(where: { $0.id == id }) else { return nil }
        if app.iconURL == nil { app.iconURL = localArtwork(id) ?? known.first { $0.id == id && $0.iconURL != nil }?.iconURL }
        return app
    }

    /// Artwork we already hold for an App ID from a download: the icon in
    /// the package, or the artwork Apple sent with the download. Delisted
    /// apps have no public listing, so this is often the only source.
    func localArtwork(_ id: String) -> URL? {
        for job in downloads.jobs where job.app.id == id {
            if let icon = job.displayApp(packageIcon: downloads.packageIconURL(job)).iconURL { return icon }
        }
        return nil
    }

    /// Results from local records or other regions can lack artwork; look it
    /// up across storefronts (artwork is public even when the app is not
    /// available to the signed-in account's region).
    private func fillMissingArtwork(searchID id: UUID, store context: StoreContext, accountCountry: String?) async {
        func local(_ apps: [StoreApp]) -> [StoreApp] {
            apps.map { app in
                var app = app
                if app.iconURL == nil { app.iconURL = localArtwork(app.id) }
                return app
            }
        }
        results = local(results)
        localResults = local(localResults)
        let missing = Array(Set((results + localResults)
            .filter { $0.iconURL == nil && !$0.id.isEmpty && $0.id.allSatisfy({ $0.isASCII && $0.isNumber }) }
            .map(\.id))).prefix(50)
        guard !missing.isEmpty,
              let icons = try? await StoreService.artwork(Array(missing), store: context, accountCountry: accountCountry),
              !icons.isEmpty, searchID == id else { return }
        func filled(_ apps: [StoreApp]) -> [StoreApp] {
            apps.map { app in
                var app = app
                if app.iconURL == nil { app.iconURL = icons[app.id] }
                return app
            }
        }
        results = filled(results)
        localResults = filled(localResults)
    }

    private func updateLocalResults(for input: String? = nil) {
        guard case .keyword(let term)? = try? SearchQuery.parse(input ?? lastSearchTerm) else { return }
        let known = owned.map(\.storeApp) + favorites + downloads.jobs.map(\.app) + (appCatalog[settings.store.platform.rawValue] ?? [])
        let saved = AppSearchIndex.search(term, apps: known)
        let directory = AppNameCatalog.search(term, platform: settings.store.platform, entries: nameCatalog)
        let remoteIDs = Set(results.map(\.id))
        localResults = AppSearchIndex.unique(saved + directory).filter { !remoteIDs.contains($0.id) }
    }

    func loadNameCatalog() async {
        guard !catalogRequested else { return }
        catalogRequested = true
        #if DEBUG
        if visualPreview { return }
        #endif
        do {
            let entries = try await AppNameCatalog.updated()
            try Task.checkCancellation()
            nameCatalog = entries + AppNameCatalog.bundled()
            try? LocalResources.save(entries, filename: AppNameCatalog.cacheFile)
            updateLocalResults()
        } catch { } // Bundled and cached names remain searchable without a connection.
    }

    func ensureOwnedLoaded() async {
        #if DEBUG
        if visualPreview { return }
        #endif
        guard let id = apple.activeID, ownedByAccount[id] == nil, !ownedLoading,
              ownedAutoAttempted.insert(id).inserted else { return }
        await refreshOwned()
    }

    func cancelSearch() { searchTask?.cancel(); searchID = UUID(); searching = false; hasSearched = !results.isEmpty || !localResults.isEmpty; searchError = nil }
    func clearSearch() { cancelSearch(); searchText = ""; results = []; localResults = []; hasSearched = false; lastSearchTerm = "" }
    func isFavorite(_ app: StoreApp) -> Bool { favorites.contains { $0.id == app.id } }
    func toggleFavorite(_ app: StoreApp) {
        guard favoritesStorageError == nil else { errorMessage = favoritesStorageError; return }
        var next = favorites
        if next.contains(where: { $0.id == app.id }) { next.removeAll { $0.id == app.id } }
        else { next.insert(app, at: 0) }
        do { try LocalResources.save(next, filename: "favorites.json"); favorites = next; updateLocalResults() }
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
        if let data = try? JSONEncoder().encode(searchHistory) { LocalResources.defaults.set(data, forKey: LocalResources.searchHistory) }
    }

    func loadVersions(for app: StoreApp, force: Bool = false, official: Bool = false) async throws -> [AppVersion] {
        #if DEBUG
        if visualPreview { return [AppVersion(id: "123456789", version: "3.2.1", source: "版本资料"), AppVersion(id: "123456788", version: "3.1.0", source: "版本资料")] }
        #endif
        let context = settings.store
        if context.platform == .macOS { return [] }
        if context.platform == .tvOS {
            guard let listing = try await StoreService.platformApp(app.id, store: context),
                  let id = listing.externalVersionID, !id.isEmpty else { return [] }
            return [AppVersion(id: id, version: listing.version.isEmpty ? "未知版本" : listing.version, source: "Apple TV")]
        }
        if official {
            let asset = try await apple.asset(appID: app.id, versionID: nil, store: context,
                                              useCache: settings.useSignerCache, allowLicenseAcquisition: false)
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
        var asset = try await apple.asset(appID: app.id, versionID: versionID,
                                          store: settings.store, useCache: settings.useSignerCache)
        // Apple DownloadDispatch often omits artwork even when the store
        // listing showed it. Do not lose that listing before enqueuing.
        if asset.app.iconURL == nil { asset.app.iconURL = app.iconURL }
        try downloads.enqueue(asset)
        // A delisted app's only artwork may arrive with the download itself.
        if let icon = asset.app.iconURL {
            func patched(_ apps: [StoreApp]) -> [StoreApp] {
                apps.map { var item = $0; if item.id == app.id && item.iconURL == nil { item.iconURL = icon }; return item }
            }
            results = patched(results)
            localResults = patched(localResults)
        }
        tab = 1
    }

    func refreshDownload(_ job: DownloadJob) async throws {
        guard job.status == .failed, job.asset != nil else { throw ToolError.message("此任务无法重试") }
        guard apple.activeID == job.account else { throw ToolError.message("请先切换至原下载账号：\(job.account ?? "")") }
        let platform: AppPlatform
        switch job.asset?.platform.lowercased() {
        case "appletvos", "tvos", "atv9": platform = .tvOS
        case "ipad": platform = .iPadOS
        default: platform = .iOS
        }
        let asset = try await apple.asset(appID: job.app.id, versionID: job.asset?.app.externalVersionID,
            store: StoreContext(country: settings.store.country, platform: platform), useCache: settings.useSignerCache)
        try downloads.refreshFailed(job.id, asset: asset)
        tab = 1
    }

    func refreshOwned() async {
        guard !ownedLoading, let id = apple.activeID else {
            if apple.activeID == nil { errorMessage = "请先在账号页登录" }
            return
        }
        ownedLoading = true; ownedError = nil
        defer {
            ownedLoading = false
            if apple.activeID != id { Task { await self.ensureOwnedLoaded() } }
        }
        do {
            let apps = try await apple.ownedApps(useCache: settings.useSignerCache)
            guard apple.activeID == id else { return }
            let cached = Dictionary(owned.map { ($0.id, $0.iconURL) }, uniquingKeysWith: { first, _ in first })
            owned = apps.map { app in
                var item = app
                if item.iconURL == nil { item.iconURL = cached[item.id] ?? nil }
                return item
            }
            guard ownedStorageError == nil else { ownedError = ownedStorageError; return }
            var next = ownedByAccount; next[id] = owned
            try LocalResources.save(next, filename: LocalResources.ownedFilename)
            ownedByAccount = next
            updateLocalResults()
            ownedRevision = UUID()
        } catch is CancellationError { }
        catch { if apple.activeID == id { ownedError = error.localizedDescription } }
    }
    func loadOwnedArtwork() async {
        #if DEBUG
        if visualPreview { return }
        #endif
        guard let account = apple.activeID, ownedStorageError == nil else { return }
        let context = settings.store
        var artworkContext = context
        // Purchased iPhone/iPad apps are independent of the search platform picker.
        artworkContext.platform = .iOS
        let accountCountry = StoreService.country(forStorefront: apple.active?.storeFront ?? "")
        let revision = ownedRevision
        let ids = owned.filter { $0.iconURL == nil }.map(\.id)
        for offset in stride(from: 0, to: ids.count, by: 20) {
            do {
                try Task.checkCancellation()
                let urls = try await StoreService.artwork(Array(ids[offset..<min(offset + 20, ids.count)]), store: artworkContext, accountCountry: accountCountry)
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
        guard ownedStorageError == nil else { throw ToolError.message(ownedStorageError!) }
        var next = ownedByAccount; next.removeValue(forKey: id)
        try LocalResources.save(next, filename: LocalResources.ownedFilename)
        do { try apple.remove(id) }
        catch {
            try LocalResources.save(ownedByAccount, filename: LocalResources.ownedFilename)
            throw error
        }
        ownedByAccount = next
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
    func prepareAccountPreview() {
        apple.prepareAccountPreview()
        owned = [OwnedApp(id: "preview-app", bundleID: "example.pixel", name: "像素日记", version: "3.2", purchaseDate: Date(), iconURL: nil)]
    }
    func prepareArchivePreview() {
        searchText = "Forward"; lastSearchTerm = searchText; hasSearched = true
        updateLocalResults()
    }
    func prepareVisualPreview() {
        visualPreview = true
        results = []; hasSearched = false; searchText = ""
        favorites = [StoreApp(id: "preview-app", name: "像素日记", bundleID: "example.pixel", version: "3.2", category: "摄影与录像", size: 128_000_000)]
        searchHistory = [SearchHistoryItem(term: "效率工具", count: 3, lastUsed: Date()), SearchHistoryItem(term: "照片编辑", count: 1, lastUsed: Date())]
    }
}
#endif
