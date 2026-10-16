import Foundation
import Combine
import UIKit
import UserNotifications

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
    let metadataStore = VersionMetadataStore()
    let downloads: DownloadManager
    let installation = InstallationService()
    lazy var apple = AppleService(signer: signer)
    @Published var settings: ToolSettings {
        didSet {
            do { LocalResources.defaults.set(try JSONEncoder().encode(settings), forKey: LocalResources.settings) }
            catch { errorMessage = "设置保存失败：" + error.localizedDescription }
            downloads.configure(settings)
            // Region or platform changed: refresh the results here, so it also
            // happens when the search page is not on screen (iPad sidebar).
            if oldValue.store != settings.store, hasSearched { search() }
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
    /// Newer store versions of downloaded apps, by `DownloadJob.updateKey`.
    @Published private(set) var availableUpdates: [String: StoreApp] = [:]
    private var updatesChecked: (date: Date, keys: Set<String>)?
    /// What the latest checks saw of followed apps, by `WatchRecord.key`.
    @Published private(set) var watch: [String: WatchRecord] = [:]
    @Published private(set) var watchChecking = false
    private var watchChecked: (date: Date, keys: Set<String>)?
    private var officialVersionCache: [String: (date: Date, versions: [AppVersion])] = [:]
    @Published var infoMessage: String?
    #if DEBUG
    private var visualPreview = false
    #endif
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()
    private var ownedByAccount: [String: [OwnedApp]] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var lastAccountID: String?
    private var ownedArtworkAttempted = Set<String>()

    init(downloadManager: DownloadManager? = nil) {
        downloads = downloadManager ?? DownloadManager()
        if let data = LocalResources.defaults.data(forKey: LocalResources.settings),
           let saved = try? JSONDecoder().decode(ToolSettings.self, from: data) { settings = saved }
        else { settings = ToolSettings() }
        do { favorites = try LocalResources.loadChecked([StoreApp].self, filename: "favorites.json") ?? [] }
        catch { favoritesStorageError = "关注列表读取失败；已保留原文件。"; errorMessage = favoritesStorageError }
        watch = (try? LocalResources.loadChecked([String: WatchRecord].self, filename: "watch.json")) ?? [:]
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
        // A switch, sign-in or sign-out (not the restored account at launch).
        lastAccountID = apple.activeID
        apple.$activeID.dropFirst().removeDuplicates().sink { [weak self] id in
            Task { @MainActor in self?.accountChanged(to: id) }
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
                // Cache real listings only, without the long descriptions (kept small for quick saves).
                let listed = apps.filter { $0.delisted != true }.map { app -> StoreApp in var app = app; app.description = ""; return app }
                appCatalog[key] = Array(AppSearchIndex.unique(listed + (appCatalog[key] ?? [])).prefix(1000))
                try? LocalResources.save(appCatalog, filename: "app-catalog.json")
                remember(input)
                // The results are in: missing artwork fills in quietly.
                searching = false
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

    /// Follow the new account: confirm the change, show its own storefront
    /// (the region can still be changed by hand afterwards) and sync its
    /// purchases in the background.
    private func accountChanged(to id: String?) {
        // Re-login and token refresh select the same account again: not a switch.
        guard id != lastAccountID else { return }
        let previous = lastAccountID
        lastAccountID = id
        guard let id, let account = apple.accounts.first(where: { $0.id == id }) else {
            // Removing the signed-in account reports its own confirmation.
            if let previous, apple.accounts.contains(where: { $0.id == previous }) { infoMessage = "已退出登录" }
            return
        }
        infoMessage = "已切换到 " + (account.name.isEmpty ? account.id : account.name)
        if let country = StoreService.country(forStorefront: account.storeFront), settings.store.country != country {
            // Changing the region re-runs the search (see settings).
            settings.store.country = country
        } else if hasSearched {
            search()
        }
        #if DEBUG
        if visualPreview { return }
        #endif
        Task { await refreshOwned() }
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
        let following = !next.contains(where: { $0.id == app.id })
        if following { next.insert(app, at: 0) } else { next.removeAll { $0.id == app.id } }
        do { try LocalResources.save(next, filename: "favorites.json"); favorites = next; updateLocalResults() }
        catch { errorMessage = "关注保存失败：" + error.localizedDescription; return }
        if following {
            // Start the record now, so price changes count from this moment.
            Task { await checkWatched(force: true) }
            if settings.watchNotifications {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        } else {
            watch = watch.filter { $0.value.id != app.id }
            persistWatch()
        }
    }

    /// The storefront followed apps are checked in: the signed-in account's,
    /// else the search region.
    var watchCountry: String {
        (apple.active.flatMap { StoreService.country(forStorefront: $0.storeFront) } ?? settings.store.country).uppercased()
    }
    func watchRecord(_ id: String) -> WatchRecord? { watch[WatchRecord.key(id: id, country: watchCountry)] }

    typealias WatchEvent = (app: StoreApp, change: WatchChange, currency: String, country: String)

    /// Looks up every followed app and records version, price and removal
    /// changes in the account's storefront, and prices in the comparison
    /// storefronts. Runs at most every three hours unless forced or the list
    /// changed. Returns the changes worth a notification.
    @discardableResult
    func checkWatched(force: Bool = false) async -> [WatchEvent] {
        #if DEBUG
        if visualPreview { return [] }
        #endif
        let apps = favorites
        let ids = Set(apps.map(\.id))
        let primary = watchCountry
        var countries = [primary]
        for country in settings.priceRegions.map({ $0.uppercased() }) where !countries.contains(country) { countries.append(country) }
        let keys = ids.union(countries.map { "@" + $0 })
        guard !apps.isEmpty, !watchChecking else { return [] }
        if !force, let checked = watchChecked, checked.keys == keys, Date().timeIntervalSince(checked.date) < 3 * 3600 { return [] }
        watchChecking = true
        defer { watchChecking = false }
        var listings: [String: [String: StoreApp]] = [:]
        await withTaskGroup(of: (String, [String: StoreApp]?).self) { group in
            for country in countries {
                group.addTask { (country, try? await StoreService.lookup(ids: Array(ids), country: country).apps) }
            }
            // A failed request says nothing about the apps: that storefront's records stay as they are.
            for await (country, found) in group { if let found { listings[country] = found } }
        }
        guard var found = listings[primary] else { return [] }
        // The list lookup can leave out an app now and then; ask once more
        // on its own before treating it as removed from sale.
        for app in apps where found[app.id] == nil && watch[WatchRecord.key(id: app.id, country: primary)]?.listed == true {
            guard let single = try? await StoreService.lookup(ids: [app.id], country: primary).apps else { return [] }
            if let listing = single[app.id] { found[app.id] = listing }
        }
        listings[primary] = found
        guard !Task.isCancelled, primary == watchCountry else { return [] }
        var records = watch
        var events: [WatchEvent] = []
        var refreshed = favorites
        // Skip apps unfollowed while the lookups were running.
        for app in apps where refreshed.contains(where: { $0.id == app.id }) {
            for (country, found) in listings {
                let key = WatchRecord.key(id: app.id, country: country)
                let listing = found[app.id]
                let result = WatchService.update(records[key], id: app.id, country: country, listing: listing)
                records[key] = result.record
                // Other storefronts only matter for their prices.
                let changes = country == primary ? result.changes : result.changes.filter {
                    if case .priceDrop = $0 { return true }; if case .free = $0 { return true }; return false
                }
                events += changes.map { (app: listing ?? app, change: $0, currency: result.record.currency, country: country) }
            }
            // Keep the list's version and price current.
            if let listing = found[app.id], let index = refreshed.firstIndex(where: { $0.id == app.id }) {
                var updated = refreshed[index]
                if !listing.version.isEmpty { updated.version = listing.version }
                updated.price = listing.price; updated.priceValue = listing.priceValue; updated.currency = listing.currency
                if updated.iconURL == nil { updated.iconURL = listing.iconURL }
                refreshed[index] = updated
            }
        }
        watch = records
        watchChecked = (Date(), keys)
        persistWatch()
        if refreshed != favorites, (try? LocalResources.save(refreshed, filename: "favorites.json")) != nil { favorites = refreshed }
        return events
    }

    private func persistWatch() {
        try? LocalResources.save(watch, filename: "watch.json")
    }

    /// One notification for the changes a background check found.
    func notifyWatchChanges(_ events: [WatchEvent]) {
        let primary = watchCountry
        let lines = events.compactMap { event in
            WatchService.message(event.change, currency: event.currency).map {
                event.app.name + (event.country == primary ? "" : "（\(StoreRegions.name(event.country))）") + $0
            }
        }
        guard !lines.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = lines.count == 1 ? "关注的应用有变化" : "\(lines.count) 条关注应用变化"
        content.body = lines.prefix(4).joined(separator: "\n") + (lines.count > 4 ? "\n等" : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-" + UUID().uuidString, content: content, trigger: nil))
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
        if official, let account = apple.activeID {
            // Apple's list costs a signed request: reuse it for a while, so
            // opening the same app again does not ask Apple again.
            let key = "\(account)|\(context.platform.rawValue)|\(context.country)|\(app.id)"
            if !force, let hit = officialVersionCache[key], Date().timeIntervalSince(hit.date) < 30 * 60 { return hit.versions }
            let list = try await appleVersions(for: app, context: context, force: force)
            officialVersionCache[key] = (Date(), list)
            return list
        }
        if context.platform == .macOS {
            // Only the latest version is public; the full list needs the account.
            guard let id = try await MacStoreOfferService.latestVersionID(appID: app.id, bundleID: app.bundleID, country: context.country)
            else { return [] }
            return [AppVersion(id: id, version: app.version.isEmpty ? "未知版本" : app.version, source: "App Store")]
        }
        if context.platform == .tvOS {
            guard let listing = try await StoreService.platformApp(app.id, store: context),
                  let id = listing.externalVersionID, !id.isEmpty else { return [] }
            return [AppVersion(id: id, version: listing.version.isEmpty ? "未知版本" : listing.version, source: "Apple TV")]
        }
        return try await versions.thirdParty(app.id, sources: settings.versionSources, force: force)
    }

    /// Every version Apple lists for the active account. Never claims a license.
    private func appleVersions(for app: StoreApp, context: StoreContext, force: Bool) async throws -> [AppVersion] {
        var seen = Set<String>()
        if context.platform == .macOS {
            let offer = try await apple.macPackageOffer(app, useCache: settings.useSignerCache, allowLicenseAcquisition: false)
            let ids = offer.externalVersionIDs.isEmpty ? [offer.versionID] : Array(offer.externalVersionIDs.reversed())
            return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { id in
                AppVersion(id: id, version: id == offer.versionID && !offer.displayVersion.isEmpty ? offer.displayVersion : "未知版本", source: "Apple")
            }
        }
        let asset = try await apple.asset(appID: app.id, versionID: nil, store: context,
                                          useCache: settings.useSignerCache, allowLicenseAcquisition: false)
        let third = context.platform == .iOS ? (try? await versions.thirdParty(app.id, sources: settings.versionSources, force: force)) ?? [] : []
        let names = Dictionary(third.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        let ids = asset.externalVersionIDs.isEmpty ? [asset.app.externalVersionID ?? ""] : Array(asset.externalVersionIDs.reversed())
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { id in
            AppVersion(id: id, version: id == asset.app.externalVersionID ? asset.app.version : names[id] ?? "未知版本", source: "Apple")
        }
    }

    func cachedVersionMetadata(app: StoreApp, versionIDs: [String]) async -> [String: VersionMetadata] {
        let platform = settings.store.platform
        let keys = Dictionary(versionIDs.map { (VersionMetadataStore.key(platform: platform, appID: app.id, versionID: $0), $0) },
                              uniquingKeysWith: { first, _ in first })
        let found = await metadataStore.cached(Array(keys.keys))
        return Dictionary(found.compactMap { key, value in keys[key].map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The version number and date of one version, read from Apple. Lookups
    /// are cached and run one at a time.
    func versionMetadata(app: StoreApp, versionID: String) async throws -> VersionMetadata {
        #if DEBUG
        if visualPreview { return VersionMetadata(version: "3.2.1", released: Date(timeIntervalSince1970: 1_714_694_400)) }
        #endif
        let platform = settings.store.platform
        let useCache = settings.useSignerCache
        let key = VersionMetadataStore.key(platform: platform, appID: app.id, versionID: versionID)
        return try await metadataStore.load(key) { @MainActor [apple] in
            if platform == .macOS {
                // A Mac package cannot be read in part; Apple's ticket names the version.
                let offer = try await apple.macPackageOffer(app, versionID: versionID, useCache: useCache,
                                                            allowLicenseAcquisition: false)
                guard !offer.displayVersion.isEmpty else { throw RemoteZip.Failure.notFound }
                return VersionMetadata(version: offer.displayVersion, released: nil)
            }
            let url = try await apple.versionTicket(appID: app.id, versionID: versionID, useCache: useCache)
            return try await RemoteZip.versionMetadata(HTTPRangeReader(url: url))
        }
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

    /// Compares finished downloads with the store's current versions. Runs
    /// at most every six hours unless forced or the set of apps changed.
    func checkForUpdates(force: Bool = false) async {
        #if DEBUG
        if visualPreview { return }
        #endif
        let jobs = downloads.jobs.filter { $0.status != .failed && $0.updateKey != nil && !$0.storeVersion.isEmpty }
        let keys = Set(jobs.filter { $0.status == .completed }.compactMap(\.updateKey))
        if !force, let checked = updatesChecked, checked.keys == keys,
           Date().timeIntervalSince(checked.date) < 6 * 3600 { return }
        guard !keys.isEmpty else { availableUpdates = [:]; return }
        let country = apple.active.flatMap { StoreService.country(forStorefront: $0.storeFront) } ?? settings.store.country
        // The newest version already downloaded (or downloading) per app.
        var newest: [String: String] = [:]
        for job in jobs {
            guard let key = job.updateKey else { continue }
            if let known = newest[key], !VersionOrder.isNewer(job.storeVersion, than: known) { continue }
            newest[key] = job.storeVersion
        }
        var listings: [String: StoreApp] = [:]
        let byPlatform = Dictionary(grouping: keys, by: { $0.split(separator: "|").first.map(String.init) ?? "" })
        func ids(_ platform: AppPlatform) -> [String] {
            (byPlatform[platform.rawValue] ?? []).compactMap { $0.split(separator: "|").last.map(String.init) }
        }
        let lookupIDs = Set(ids(.iOS) + ids(.iPadOS) + ids(.macOS))
        if let found = try? await StoreService.lookup(ids: Array(lookupIDs), country: country) {
            for platform in [AppPlatform.iOS, .iPadOS, .macOS] {
                for id in ids(platform) {
                    guard let app = found.apps[id] else { continue }
                    // A Mac download sharing an iPhone App ID: the listing is the
                    // iPhone version, so it says nothing about the Mac one.
                    if platform == .macOS && !found.nativeMac.contains(id) { continue }
                    listings["\(platform.rawValue)|\(id)"] = app
                }
            }
        }
        for id in ids(.tvOS).prefix(30) {
            if let app = try? await StoreService.platformApp(id, store: StoreContext(country: country, platform: .tvOS)) {
                listings["\(AppPlatform.tvOS.rawValue)|\(id)"] = app
            }
        }
        guard !Task.isCancelled else { return }
        var updates: [String: StoreApp] = [:]
        for (key, app) in listings {
            if let current = newest[key], VersionOrder.isNewer(app.version, than: current) { updates[key] = app }
        }
        availableUpdates = updates
        updatesChecked = (Date(), keys)
    }

    /// Notifies about updates found in the background, once per version.
    func notifyNewUpdates() {
        let key = "storage_notifiedUpdates"
        var notified = LocalResources.defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let fresh = availableUpdates.filter { notified[$0.key] != $0.value.version }
        guard !fresh.isEmpty else { return }
        for (id, app) in fresh { notified[id] = app.version }
        LocalResources.defaults.set(notified, forKey: key)
        let names = fresh.values.sorted { $0.name < $1.name }.prefix(3).map { "\($0.name) \($0.version)" }
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "\(fresh.values.first!.name) 有新版本" : "\(fresh.count) 个应用有新版本"
        content.body = names.joined(separator: "、") + (fresh.count > 3 ? " 等" : "") + "。打开 iPadn 下载新版本。"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-" + UUID().uuidString, content: content, trigger: nil))
    }

    /// Downloads the store's current version of a finished download.
    func downloadUpdate(of job: DownloadJob) async throws {
        guard let key = job.updateKey, let platform = job.updatePlatform, let latest = availableUpdates[key] else { return }
        guard apple.active != nil else { throw ToolError.message("请先在「账号」中登录 Apple 账号") }
        var app = latest
        if app.iconURL == nil { app.iconURL = job.app.iconURL }
        if platform == .macOS {
            let offer = try await apple.macPackageOffer(app, useCache: settings.useSignerCache)
            try downloads.enqueueOfficialMacPackage(offer, for: app)
        } else {
            var asset = try await apple.asset(appID: job.app.id, versionID: nil,
                store: StoreContext(country: settings.store.country, platform: platform), useCache: settings.useSignerCache)
            if asset.app.iconURL == nil { asset.app.iconURL = app.iconURL }
            try downloads.enqueue(asset)
        }
        infoMessage = "已开始下载新版本"
    }

    /// Adds the latest version of several apps, one at a time. A problem
    /// that would repeat for every app (sign-in, the queue limit) stops the
    /// batch; anything else is reported per app.
    func startDownloads(_ apps: [StoreApp], progress: @escaping (Int) -> Void) async -> (added: Int, failures: [String]) {
        var added = 0
        var failures: [String] = []
        for (index, app) in apps.enumerated() {
            if Task.isCancelled { break }
            do {
                if settings.store.platform == .macOS {
                    let offer = try await apple.macPackageOffer(app, useCache: settings.useSignerCache)
                    try downloads.enqueueOfficialMacPackage(offer, for: app)
                } else {
                    var asset = try await apple.asset(appID: app.id, versionID: nil, store: settings.store,
                                                      useCache: settings.useSignerCache)
                    if asset.app.iconURL == nil { asset.app.iconURL = app.iconURL }
                    try downloads.enqueue(asset)
                }
                added += 1
            } catch let error where error is AppleAuthError || error is AppleLoginError {
                failures.append("请到「账号」中重新验证 Apple 账号后再试。")
                break
            } catch {
                let message = error.localizedDescription
                failures.append((app.name.isEmpty ? app.id : app.name) + "：" + message)
                if message.contains("上限") { break }
            }
            progress(index + 1)
        }
        return (added, failures)
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
        // An earlier error stays until this sync settles, instead of
        // disappearing and coming back.
        ownedLoading = true
        defer {
            ownedLoading = false
            // The account changed mid-sync: sync the new one now.
            if apple.activeID != id, apple.activeID != nil { Task { await self.refreshOwned() } }
        }
        do {
            let apps = try await apple.ownedApps(useCache: settings.useSignerCache)
            guard apple.activeID == id else { return }
            ownedError = nil
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
        // Each App ID is looked up once per launch: delisted apps never resolve,
        // and repeating them on every visit would exceed the lookup rate limit.
        let ids = owned.filter { $0.iconURL == nil && !ownedArtworkAttempted.contains($0.id) }.map(\.id)
        for offset in stride(from: 0, to: ids.count, by: 20) {
            do {
                try Task.checkCancellation()
                let batch = Array(ids[offset..<min(offset + 20, ids.count)])
                let urls = try await StoreService.artwork(batch, store: artworkContext, accountCountry: accountCountry)
                try Task.checkCancellation()
                guard apple.activeID == account, settings.store == context, ownedRevision == revision else { return }
                ownedArtworkAttempted.formUnion(batch)
                if !urls.isEmpty {
                    // Apply the batch in one update so the list re-renders once.
                    var updated = owned
                    for index in updated.indices { if let url = urls[updated[index].id] { updated[index].iconURL = url } }
                    owned = updated
                    ownedByAccount[account] = owned
                    try LocalResources.save(ownedByAccount, filename: LocalResources.ownedFilename)
                }
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
            "Installation: " + (settings.automaticInstallation ? "one-tap" : settings.localInstallation ? "local certificate" : "proxy"),
            "Runs inside LiveContainer: " + (InstallLog.insideLiveContainer ? "yes" : "no"),
            "Proxy or VPN on: " + (LocalHostRecord.proxyOrVPNActive ? "yes" : "no"),
            "iOS " + UIDevice.current.systemVersion,
            "Installation server log:", InstallLog.shared.text.isEmpty ? "(empty)" : InstallLog.shared.text,
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
        let day: TimeInterval = 86400
        var record = WatchRecord(id: "preview-app", country: watchCountry, version: "3.2", price: 18, currency: "CNY",
                                 history: [PricePoint(date: Date().addingTimeInterval(-30 * day), price: 30),
                                           PricePoint(date: Date().addingTimeInterval(-3 * day), price: 18)],
                                 started: Date().addingTimeInterval(-30 * day), checked: Date())
        record.change = .priceDrop(from: 30, to: 18); record.changed = Date().addingTimeInterval(-3 * day)
        watch = [record.key: record]
        searchHistory = [SearchHistoryItem(term: "效率工具", count: 3, lastUsed: Date()), SearchHistoryItem(term: "照片编辑", count: 1, lastUsed: Date())]
    }
}
#endif
