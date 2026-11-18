import Foundation
import Combine
import SwiftUI
import UIKit
import UserNotifications

struct SearchHistoryItem: Codable, Identifiable {
    var id: String { term }
    var term: String
    var count: Int
    var lastUsed: Date
}

/// Settings, followed apps, and full portable Apple account sessions (including cookies,
/// tokens, passwords, device GUID, and StoreProof records) in one file,
/// to carry over before changing signing certificates or switching devices.
struct AppBackup: Codable {
    static let currentFormat = 3
    var format = AppBackup.currentFormat
    var app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    var created = Date()
    var settings: ToolSettings
    var favorites: [StoreApp]
    var watch: [String: WatchRecord]
    var keptVersions: [String: String]
    var searchHistory: [SearchHistoryItem]
    /// v2 legacy non-sensitive profiles (decoded for backwards compatibility).
    var accountProfiles: [AccountProfileEntry]? = nil
    /// v3 full portable Apple account entries including cookies, tokens, DSIDs, and passwords.
    var accountSessions: [AccountSessionEntry]? = nil
    var preferredActiveAccountID: String? = nil
    var deviceGUID: String? = nil
    var storeProofRecords: [String: StoreProofRecord]? = nil

    var effectiveAccountEntries: [AccountSessionEntry] {
        if let sessions = accountSessions, !sessions.isEmpty {
            return sessions
        }
        if let profiles = accountProfiles, !profiles.isEmpty {
            return profiles.map(AccountSessionEntry.init(from:))
        }
        return []
    }

    var includesSensitiveCredentials: Bool {
        effectiveAccountEntries.contains(where: \.hasAnyCredential)
            || deviceGUID != nil
            || !(storeProofRecords?.isEmpty ?? true)
    }

    static func decode(_ data: Data) throws -> AppBackup {
        guard data.count <= AccountProfileBackup.maxImportBytes else {
            throw ToolError.message(AppText.text("备份文件过大，请确认它是有效的 iPadn 备份文件。"))
        }
        if EncryptedBackupEnvelope.isEncryptedEnvelope(data) {
            throw AccountBackupError.encryptedPasswordRequired
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let kind = object["kind"] as? String, ["encrypted", "vault", "secrets"].contains(kind.lowercased()) {
                throw AccountBackupError.encryptedUnsupported
            }
            if object["sealedBox"] != nil || object["cipher"] != nil {
                throw AccountBackupError.encryptedUnsupported
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var backup = try? decoder.decode(AppBackup.self, from: data), backup.format >= 1 else {
            throw ToolError.message(AppText.text("这不是有效的 iPadn 备份文件。"))
        }
        guard backup.format <= currentFormat else {
            throw ToolError.message(AppText.text("这个备份来自更新版本的 iPadn，请先更新 iPadn。"))
        }
        if let rawSessions = backup.accountSessions {
            let cleanSessions = try AccountBackupService.deduplicatedSessions(from: rawSessions)
            backup.accountSessions = cleanSessions.isEmpty ? nil : cleanSessions
        }
        if let rawProfiles = backup.accountProfiles {
            let clean = try AccountBackupService.deduplicatedEntries(from: rawProfiles)
            backup.accountProfiles = clean.isEmpty ? nil : clean
        }
        let trimmedActive = backup.preferredActiveAccountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        backup.preferredActiveAccountID = trimmedActive?.isEmpty == true ? nil : trimmedActive
        backup.deviceGUID = AccountBackupService.normalizedDeviceGUID(backup.deviceGUID)
        backup.storeProofRecords = AccountBackupService.sanitizedStoreProofRecords(backup.storeProofRecords)
        return backup
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    /// The backup's followed apps first, then the ones only this install has.
    static func merged(_ imported: [StoreApp], with existing: [StoreApp]) -> [StoreApp] {
        let ids = Set(imported.map(\.id))
        var seen = Set<String>()
        return (imported + existing.filter { !ids.contains($0.id) }).filter { seen.insert($0.id).inserted }
    }
}

struct UnifiedBackupPreview: Equatable {
    enum Source: Equatable {
        case unified
        case legacyAccountsOnly
    }

    let data: Data
    let source: Source
    let created: Date
    let favoritesCount: Int
    let accountEntries: [AccountSessionEntry]
    let newAccountEntries: [AccountSessionEntry]
    let existingAccountEntries: [AccountSessionEntry]
    let deviceGUID: String?
    let hasStoreProofs: Bool
    let wasEncrypted: Bool

    var includesSettingsAndFollowed: Bool { source == .unified }
    var duplicateAccountCount: Int { existingAccountEntries.count }
    var includesSensitiveCredentials: Bool {
        accountEntries.contains(where: \.hasAnyCredential) || deviceGUID != nil || hasStoreProofs
    }
    var credentialReadyCount: Int { accountEntries.filter(\.hasValidSession).count }
}

enum BackupInspectResult: Equatable {
    case ready(UnifiedBackupPreview)
    case needsPassword(Data)
}

struct UndoNotice: Identifiable {
    /// How long the undo stays offered.
    static let duration: TimeInterval = 5
    var id = UUID()
    var revision = 1
    var created = Date()
    let message: String
    let restore: (UndoNotice) -> Void
}

/// Stable identity of a bottom-bar page. `TabView` and `NavigationSplitView`
/// bind directly to `TabID`, while `selection` stays derived from the active
/// `tabOrder` for vector-icon indexing and legacy integer callers.
enum TabID: String, CaseIterable, Hashable, Sendable {
    case search, downloads, packages, purchased, accounts
}

enum AccountRoute: Hashable, Codable {
    case login
    case reauthenticate(String)
    case installedApps
    case wifiTransfer
    case settings(SettingsView.Page)
    case installation
    case credentials
    case storage
    case versionSource(UUID)
    case appUpdate
    case support
}

struct ExternalDownloadPrompt: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var displayURL: String {
        let raw = url.absoluteString
        return raw.count > 160 ? String(raw.prefix(157)) + "…" : raw
    }
}

@MainActor
final class AccountNavigation: ObservableObject {
    @Published var path = NavigationPath() {
        didSet {
            if path.isEmpty {
                routes.removeAll()
            } else if path.count < routes.count {
                routes = Array(routes.prefix(path.count))
            }
        }
    }
    private(set) var routes: [AccountRoute] = []

    func push(_ route: AccountRoute) {
        routes.append(route)
        path.append(route)
    }

    func setRoutes(_ newRoutes: [AccountRoute]) {
        var next = NavigationPath()
        for route in newRoutes { next.append(route) }
        routes = newRoutes
        path = next
    }

    func reset() {
        routes.removeAll()
        if !path.isEmpty { path = NavigationPath() }
    }

    func notePresented(_ route: AccountRoute) {
        guard path.count > 0 else { return }
        if routes.count == path.count {
            routes[routes.count - 1] = route
        } else if routes.count < path.count {
            routes.append(route)
        }
    }

    func removeRoutes(where predicate: (AccountRoute) -> Bool) {
        guard routes.contains(where: predicate) else { return }
        let kept = routes.filter { !predicate($0) }
        setRoutes(kept)
    }
}

@MainActor
final class TabState: ObservableObject {
    @Published private(set) var selection = 0
    @Published private(set) var id: TabID = .search

    /// User or code selected a tab: resolve against the live tab order so `id`
    /// and `selection` update atomically without index-shift races.
    func select(_ target: TabID, in order: [TabID]) {
        let fallback: TabID = order.contains(.downloads) ? .downloads : (order.first ?? .search)
        let resolved = order.contains(target) ? target : fallback
        if id != resolved { id = resolved }
        let nextIndex = order.firstIndex(of: resolved) ?? 0
        if selection != nextIndex { selection = nextIndex }
    }

    /// Legacy integer setter: maps a valid index in `order` to its `TabID`.
    func selectIndex(_ index: Int, in order: [TabID]) {
        guard order.indices.contains(index) else { return }
        select(order[index], in: order)
    }

    /// The array changed (专业模式 toggled): keep the same page when possible.
    func reconcile(with order: [TabID]) {
        select(id, in: order)
    }
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
            catch { errorMessage = AppText.text("设置保存失败：\(error.localizedDescription)") }
            downloads.configure(settings)
            if oldValue.proMode != settings.proMode {
                tabs.reconcile(with: tabOrder)
                if !settings.proMode {
                    accountNav.removeRoutes { $0 == .credentials }
                }
            }
            let validSourceIDs = Set(settings.versionSources.map(\.id))
            accountNav.removeRoutes { route in
                if case .versionSource(let id) = route { return !validSourceIDs.contains(id) }
                return false
            }
            // Region or platform changed: refresh the results here, so it also
            // happens when the search page is not on screen (iPad sidebar).
            if oldValue.store != settings.store, hasSearched { search() }
            else if oldValue.prioritizeDelistedSearchResults != settings.prioritizeDelistedSearchResults,
                    hasSearched, !searching {
                reapplySearchOrdering()
            }
        }
    }
    /// The selected tab lives in its own object: only the tab bar observes
    /// it, so switching tabs doesn't make every page that watches the store
    /// rebuild (issue #41).
    let tabs = TabState()
    let accountNav = AccountNavigation()
    var tabOrder: [TabID] {
        var order: [TabID] = [.search, .downloads]
        if settings.proMode { order.append(.packages) }
        order.append(contentsOf: [.purchased, .accounts])
        return order
    }
    func selectTab(_ id: TabID) {
        tabs.select(id, in: tabOrder)
    }
    var tab: Int {
        get { tabs.selection }
        set {
            tabs.selectIndex(newValue, in: tabOrder)
        }
    }
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
    private var appCatalog: [String: [StoreApp]] = [:]
    private var nameCatalog: [AppNameEntry] = []
    @Published private(set) var cacheLoading = true
    @Published var undoNotice: UndoNotice?
    private var cacheLoadTask: Task<Void, Never>?
    private let cacheWrites = DispatchQueue(label: "iPadn.catalog-writes", qos: .utility)
    private var resultsContext: StoreContext?
    private var favoriteTask: Task<Void, Never>?
    @Published private(set) var accountRemoving: String?
    @Published var externalDownloadPrompt: ExternalDownloadPrompt?
    private var pendingExternalURL: URL?
    private var isImportingBackup = false

    private func saveCache<T: Encodable>(_ value: T, filename: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cacheWrites.async {
                do { try LocalResources.save(value, filename: filename); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
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
    /// Apps kept at a downloaded version: no update reminders. Keyed by
    /// `DownloadJob.updateKey`, valued by the kept version.
    @Published private(set) var keptVersions: [String: String] =
        LocalResources.defaults.dictionary(forKey: "storage_keptVersions") as? [String: String] ?? [:]
    /// What the latest checks saw of followed apps, by `WatchRecord.key`.
    @Published private(set) var watch: [String: WatchRecord] = [:]
    @Published private(set) var watchChecking = false
    private var watchChecked: (date: Date, keys: Set<String>)?
    private var watchRecheck = false
    private var officialVersionCache: [String: (date: Date, versions: [AppVersion])] = [:]
    @Published var infoMessage: String?
    /// Apple wants the active account verified before an action can go on.
    /// RootView shows the code page; `retry` runs once it is verified.
    struct VerificationRequest: Identifiable {
        let id = UUID()
        let accountID: String
        let retry: (@MainActor () -> Void)?
    }
    @Published var verificationRequest: VerificationRequest?
    /// Opens the code page for the active account, then runs `retry`.
    func requestVerification(retry: (@MainActor () -> Void)? = nil) {
        guard let id = apple.activeID else { errorMessage = "请先在「账号」中登录 Apple 账号"; return }
        verificationRequest = VerificationRequest(accountID: id, retry: retry)
    }
    struct DownloadTargetKey: Hashable {
        let appID: String
        let platform: AppPlatform
        let versionID: String?

        init(appID: String, platform: AppPlatform, versionID: String? = nil) {
            self.appID = appID
            self.platform = platform
            let trimmed = versionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.versionID = trimmed.isEmpty ? nil : trimmed
        }
    }
    struct LoginPrompt: Identifiable {
        let id = UUID()
        let accountID: String?
        let retry: (@MainActor () -> Void)?
    }
    @Published private(set) var preparingDownloads: Set<DownloadTargetKey> = []
    @Published private(set) var resolvedLatestVersionIDs: [String: String] = [:]
    @Published var installingJob: DownloadJob?
    @Published var loginPrompt: LoginPrompt?
    private var prepareTasks: [DownloadTargetKey: Task<Void, Never>] = [:]
    #if DEBUG
    private var visualPreview = false
    #endif
    private var searchTask: Task<Void, Never>?
    private var localSearchTask: Task<Void, Never>?
    private var delistedVerifyTask: Task<Void, Never>?
    private var localSearchID = UUID()
    private var searchID = UUID()
    private var lastRemoteResults: [StoreApp] = []
    private var lastLocalCandidates: [StoreApp] = []
    private var lastLocalAliases: [String: [String]] = [:]
    private var delistedStatusCache: [String: (date: Date, delisted: Bool)] = [:]
    private var ownedByAccount: [String: [OwnedApp]] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var lastAccountID: String?
    private var ownedArtworkAttempted = Set<String>()

    init(downloadManager: DownloadManager? = nil) {
        downloads = downloadManager ?? DownloadManager()
        if let data = LocalResources.defaults.data(forKey: LocalResources.settings),
           let saved = try? JSONDecoder().decode(ToolSettings.self, from: data) { settings = saved }
        else { settings = ToolSettings() }
        if let data = LocalResources.defaults.data(forKey: LocalResources.searchHistory) {
            searchHistory = (try? JSONDecoder().decode([SearchHistoryItem].self, from: data)) ?? []
        }
        if ["https://api.scripting.fun/ipa-plist", "https://xiaobai.app/install"].contains(settings.plistServer) { settings.plistServer = "" }
        downloads.configure(settings)
        // Restore the decryption log once per process; runs that did not survive
        // the last launch are re-labelled "interrupted" there.
        DecryptRecordStore.shared.load()
        FairPlayDecryptor.cleanupStaleStaging()
        apple.$activeID.sink { [weak self] id in
            guard let self = self else { return }
            self.ownedRevision = UUID()
            self.ownedError = nil
            self.owned = id.flatMap { self.ownedByAccount[$0] } ?? []
            self.ownedListed = [:]
            self.updateLocalResults()
        }.store(in: &subscriptions)
        // A switch, sign-in or sign-out (not the restored account at launch).
        lastAccountID = apple.activeID
        apple.$activeID.dropFirst().removeDuplicates().sink { [weak self] id in
            Task { @MainActor in self?.accountChanged(to: id) }
        }.store(in: &subscriptions)
        cacheLoadTask = Task { await loadCachedState() }
    }

    private func loadCachedState() async {
        struct Snapshot {
            var favorites: [StoreApp] = []
            var watch: [String: WatchRecord] = [:]
            var owned: [String: [OwnedApp]] = [:]
            var catalog: [String: [StoreApp]] = [:]
            var names: [AppNameEntry] = []
            var favoritesError: String?
            var ownedError: String?
        }
        let snapshot = await Task.detached(priority: .userInitiated) {
            var snapshot = Snapshot()
            do { snapshot.favorites = try LocalResources.loadChecked([StoreApp].self, filename: "favorites.json") ?? [] }
            catch { snapshot.favoritesError = AppText.text("关注列表读取失败；已保留原文件。") }
            do { snapshot.owned = try LocalResources.loadChecked([String: [OwnedApp]].self, filename: LocalResources.ownedFilename) ?? [:] }
            catch { snapshot.ownedError = AppText.text("已购缓存读取失败；已保留原文件，不能覆盖其他账号记录。") }
            snapshot.watch = LocalResources.load([String: WatchRecord].self, filename: "watch.json") ?? [:]
            snapshot.catalog = LocalResources.load([String: [StoreApp]].self, filename: "app-catalog.json") ?? [:]
            snapshot.names = Self.mergeNameEntries((LocalResources.load([AppNameEntry].self, filename: AppNameCatalog.cacheFile) ?? []) + AppNameCatalog.bundled())
            return snapshot
        }.value
        #if DEBUG
        if visualPreview {
            nameCatalog = snapshot.names; cacheLoading = false
            updateLocalResults(); return
        }
        #endif
        favorites = snapshot.favorites; watch = snapshot.watch; ownedByAccount = snapshot.owned
        appCatalog = snapshot.catalog; nameCatalog = snapshot.names
        favoritesStorageError = snapshot.favoritesError; ownedStorageError = snapshot.ownedError
        if let issue = snapshot.favoritesError ?? snapshot.ownedError { errorMessage = issue }
        owned = apple.activeID.flatMap { ownedByAccount[$0] } ?? []
        cacheLoading = false
        updateLocalResults()
    }

    func search(_ text: String? = nil) {
        if let text = text { searchText = text }
        let input = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { clearSearch(); return }
        searchTask?.cancel()
        delistedVerifyTask?.cancel()
        if cacheLoading {
            searching = true
            searchTask = Task {
                await cacheLoadTask?.value
                guard !Task.isCancelled else { return }
                search(input)
            }
            return
        }
        let id = UUID(); searchID = id
        let context = settings.store
        let limit = settings.searchLimit
        if input != lastSearchTerm || resultsContext != context {
            results = []
            lastRemoteResults = []
            lastLocalCandidates = []
            lastLocalAliases = [:]
        }
        resultsContext = context
        localResults = []
        searching = true; hasSearched = true; searchError = nil; lastSearchTerm = input
        updateLocalResults(for: input)
        searchTask = Task {
            defer { if self.searchID == id { self.searching = false } }
            do {
                let query = try SearchQuery.parse(input)
                // Public search must never trigger purchase or download authorization.
                // Searching an App ID should work even if saved Apple credentials expired.
                let accountCountry = StoreService.country(forStorefront: apple.active?.storeFront ?? "")
                let prioritizeDelisted = settings.prioritizeDelistedSearchResults
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
                let remoteListedIDs = apps.filter { $0.delisted != true }.map(\.id)
                let now = Date()
                for appID in remoteListedIDs { delistedStatusCache[appID] = (now, false) }
                apps = apps.map { item in
                    var copy = item
                    if copy.delisted != true { copy.delisted = false }
                    return copy
                }
                try Task.checkCancellation()
                guard searchID == id else { return }
                let catalogPlatformKey = context.platform.rawValue
                // Cache real listings only, without long descriptions or pinned historical externalVersionIDs.
                let listed = apps.filter { $0.delisted != true }.map { app -> StoreApp in
                    var app = app
                    app.description = ""
                    if case .appID(_, let versionID) = query, versionID != nil {
                        app.externalVersionID = nil
                    }
                    return app
                }
                appCatalog[catalogPlatformKey] = Array(AppSearchIndex.unique(listed + (appCatalog[catalogPlatformKey] ?? [])).prefix(1000))
                let snapshot = appCatalog
                cacheWrites.async { try? LocalResources.save(snapshot, filename: "app-catalog.json") }
                remember(input)
                if case .keyword(let term) = query {
                    let knownAfterSearch = owned.map(\.storeApp) + favorites + downloads.jobs.map(\.app) + (appCatalog[catalogPlatformKey] ?? [])
                    let refreshed = Self.findLocalMatches(term: term, platform: context.platform, known: knownAfterSearch, directory: nameCatalog)
                    let enriched = applyCachedDelistedStatuses(to: refreshed.candidates)
                    localSearchTask?.cancel()
                    lastRemoteResults = apps
                    lastLocalCandidates = enriched
                    lastLocalAliases = refreshed.aliases
                    applySearchArrangement(for: term)
                    if prioritizeDelisted {
                        startDelistedVerificationIfNeeded(for: term, context: context, accountCountry: accountCountry, queryID: id)
                    }
                } else {
                    let uniqueApps = AppSearchRanking.deduplicatePreservingOrder(apps)
                    lastRemoteResults = uniqueApps
                    lastLocalCandidates = []
                    lastLocalAliases = [:]
                    publishSearchResults(primary: uniqueApps, secondary: localResults)
                }
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
        publishSearchResults(primary: local(results), secondary: local(localResults))
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
        publishSearchResults(primary: filled(results), secondary: filled(localResults))
        lastRemoteResults = filled(lastRemoteResults)
        lastLocalCandidates = filled(lastLocalCandidates)
    }

    nonisolated private static func mergeNameEntries(_ entries: [AppNameEntry]) -> [AppNameEntry] {
        var merged: [AppNameEntry] = []
        var indices: [String: Int] = [:]
        for entry in entries {
            let trimmedID = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else { continue }
            let key = "\(entry.platform.rawValue)|\(trimmedID)"
            if let index = indices[key] {
                let existing = merged[index]
                var combinedAliases = existing.aliases
                for candidate in [entry.name] + entry.aliases {
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed != existing.name && !combinedAliases.contains(trimmed) {
                        combinedAliases.append(trimmed)
                    }
                }
                merged[index] = AppNameEntry(id: existing.id, name: existing.name, aliases: combinedAliases,
                                             platform: existing.platform, source: existing.source)
            } else {
                indices[key] = merged.count
                merged.append(entry)
            }
        }
        return merged
    }

    private func publishSearchResults(primary: [StoreApp], secondary: [StoreApp], updatePrimary: Bool = true) {
        let cleanPrimary = AppSearchRanking.deduplicatePreservingOrder(primary)
        let primaryIDs = Set(cleanPrimary.map(\.id))
        let primaryBundles = Set(cleanPrimary.compactMap { app -> String? in
            let key = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return key.isEmpty ? nil : key
        })
        let cleanSecondary = AppSearchRanking.deduplicatePreservingOrder(secondary).filter { app in
            guard !primaryIDs.contains(app.id) else { return false }
            let bundleKey = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return bundleKey.isEmpty || !primaryBundles.contains(bundleKey)
        }
        if updatePrimary {
            results = cleanPrimary
        }
        localResults = cleanSecondary
    }

    nonisolated private static func findLocalMatches(
        term: String,
        platform: AppPlatform,
        known: [StoreApp],
        directory: [AppNameEntry]
    ) -> (candidates: [StoreApp], aliases: [String: [String]]) {
        let saved = AppSearchIndex.search(term, apps: known)
        let named = AppNameCatalog.searchWithAliases(term, platform: platform, entries: directory)
        let aliases = Dictionary(named.map { ($0.app.id, $0.aliases) }, uniquingKeysWith: { first, _ in first })
        let candidates = AppSearchRanking.mergeUnique(saved + named.map(\.app))
        return (candidates, aliases)
    }

    private func freshDelistedCache(for appID: String) -> Bool? {
        guard let cached = delistedStatusCache[appID],
              Date().timeIntervalSince(cached.date) < 600 else { return nil }
        return cached.delisted
    }

    private func applyCachedDelistedStatuses(to candidates: [StoreApp]) -> [StoreApp] {
        candidates.map { candidate in
            var item = candidate
            if !item.isDelisted, freshDelistedCache(for: item.id) == true {
                item.delisted = true
            }
            return item
        }
    }

    private func applyVerifiedDelistedStatuses(
        _ statuses: [String: StoreService.DelistedVerification],
        to candidates: [StoreApp],
        excludingIDs: Set<String>
    ) -> [StoreApp] {
        let now = Date()
        for (appID, status) in statuses where !excludingIDs.contains(appID) {
            switch status {
            case .delisted: delistedStatusCache[appID] = (now, true)
            case .listed: delistedStatusCache[appID] = (now, false)
            case .inconclusive: break
            }
        }
        return applyCachedDelistedStatuses(to: candidates)
    }

    private func applySearchArrangement(for term: String) {
        let enriched = applyCachedDelistedStatuses(to: lastLocalCandidates)
        lastLocalCandidates = enriched
        let arranged = AppSearchRanking.arrange(
            remote: lastRemoteResults,
            local: enriched,
            aliasesByID: lastLocalAliases,
            query: term,
            prioritizeDelisted: settings.prioritizeDelistedSearchResults
        )
        publishSearchResults(primary: arranged.results, secondary: arranged.localResults)
    }

    private func startDelistedVerificationIfNeeded(
        for term: String,
        context: StoreContext,
        accountCountry: String?,
        queryID: UUID
    ) {
        delistedVerifyTask?.cancel()
        delistedVerifyTask = nil
        guard term.count >= 2 else { return }
        let remoteListedSet = Set(lastRemoteResults.filter { $0.delisted != true }.map(\.id))
        let probeIDs = lastLocalCandidates.enumerated()
            .compactMap { offset, candidate -> (id: String, tier: Int, sparse: Bool, offset: Int)? in
                guard !remoteListedSet.contains(candidate.id),
                      !candidate.isDelisted,
                      freshDelistedCache(for: candidate.id) == nil else { return nil }
                let tier = AppSearchRanking.relevanceTier(
                    for: candidate, query: term, aliases: lastLocalAliases[candidate.id] ?? []
                )
                guard tier >= 2 else { return nil }
                return (candidate.id, tier, candidate.version.isEmpty && candidate.category.isEmpty, offset)
            }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
                if lhs.sparse != rhs.sparse { return lhs.sparse && !rhs.sparse }
                return lhs.offset < rhs.offset
            }
            .prefix(15)
            .map(\.id)
        guard !probeIDs.isEmpty else { return }
        delistedVerifyTask = Task { @MainActor [weak self] in
            let verified = await StoreService.verifyDelistedStatuses(
                ids: probeIDs,
                store: context,
                accountCountry: accountCountry
            )
            guard !Task.isCancelled, let self,
                  self.searchID == queryID,
                  self.settings.store == context,
                  self.settings.prioritizeDelistedSearchResults,
                  case .keyword(let currentTerm)? = try? SearchQuery.parse(self.lastSearchTerm),
                  currentTerm == term else { return }
            let previouslyDelisted = Set(self.results.filter(\.isDelisted).map(\.id))
            _ = self.applyVerifiedDelistedStatuses(verified, to: [], excludingIDs: remoteListedSet)
            let hasNewPromotion = verified.contains { appID, status in
                status == .delisted && !remoteListedSet.contains(appID) && !previouslyDelisted.contains(appID)
            }
            if hasNewPromotion {
                self.applySearchArrangement(for: currentTerm)
            }
        }
    }

    private func reapplySearchOrdering() {
        guard case .keyword(let term)? = try? SearchQuery.parse(lastSearchTerm) else { return }
        applySearchArrangement(for: term)
        if settings.prioritizeDelistedSearchResults {
            let accountCountry = StoreService.country(forStorefront: apple.active?.storeFront ?? "")
            startDelistedVerificationIfNeeded(
                for: term,
                context: settings.store,
                accountCountry: accountCountry,
                queryID: searchID
            )
        } else {
            delistedVerifyTask?.cancel()
            delistedVerifyTask = nil
        }
    }

    private func updateLocalResults(for input: String? = nil) {
        localSearchTask?.cancel()
        let request = UUID(); localSearchID = request
        guard case .keyword(let term)? = try? SearchQuery.parse(input ?? lastSearchTerm) else { return }
        let context = settings.store, queryID = searchID, directory = nameCatalog
        let known = owned.map(\.storeApp) + favorites + downloads.jobs.map(\.app) + (appCatalog[settings.store.platform.rawValue] ?? [])
        let prioritize = settings.prioritizeDelistedSearchResults
        localSearchTask = Task {
            let match = await Task.detached(priority: .userInitiated) {
                Self.findLocalMatches(term: term, platform: context.platform, known: known, directory: directory)
            }.value
            guard !Task.isCancelled, localSearchID == request, searchID == queryID, settings.store == context else { return }
            let existingIcons = Dictionary(
                (results + localResults + lastLocalCandidates).compactMap { app in app.iconURL.map { (app.id, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            let enriched = applyCachedDelistedStatuses(to: match.candidates).map { item -> StoreApp in
                var copy = item
                if copy.iconURL == nil { copy.iconURL = existingIcons[copy.id] ?? localArtwork(copy.id) }
                return copy
            }
            lastLocalCandidates = enriched
            lastLocalAliases = match.aliases
            let currentRemote = lastRemoteResults.isEmpty ? results : lastRemoteResults
            let arranged = AppSearchRanking.arrange(remote: currentRemote,
                                                    local: enriched, aliasesByID: match.aliases,
                                                    query: term, prioritizeDelisted: prioritize)
            if !searching && !lastRemoteResults.isEmpty {
                // Background catalogs or late delisted probes can promote local matches;
                // update `results` together when promotions change so items never vanish.
                let shouldUpdatePrimary = results.map(\.id) != arranged.results.map(\.id)
                    || results.map(\.isDelisted) != arranged.results.map(\.isDelisted)
                publishSearchResults(
                    primary: shouldUpdatePrimary ? arranged.results : results,
                    secondary: arranged.localResults,
                    updatePrimary: shouldUpdatePrimary
                )
            } else {
                // Keep skeletons clear while remote search is in flight (or offline/preview)
                // without losing promoted local candidates into an unassigned `results` array.
                publishSearchResults(
                    primary: results,
                    secondary: arranged.results + arranged.localResults,
                    updatePrimary: false
                )
            }
        }
    }

    func loadNameCatalog() async {
        await cacheLoadTask?.value
        guard !catalogRequested else { return }
        catalogRequested = true
        #if DEBUG
        if visualPreview { return }
        #endif
        do {
            let entries = try await AppNameCatalog.updated()
            try Task.checkCancellation()
            nameCatalog = Self.mergeNameEntries(entries + AppNameCatalog.bundled())
            cacheWrites.async { try? LocalResources.save(entries, filename: AppNameCatalog.cacheFile) }
            updateLocalResults()
        } catch { } // Bundled and cached names remain searchable without a connection.
    }

    /// Follow the new account: confirm the change, show its own storefront
    /// (the region can still be changed by hand afterwards) and sync its
    /// purchases in the background.
    private func accountChanged(to id: String?) {
        // Re-login and token refresh select the same account again: not a switch.
        guard id != lastAccountID else { return }
        for task in prepareTasks.values { task.cancel() }
        prepareTasks.removeAll()
        preparingDownloads.removeAll()
        let previous = lastAccountID
        lastAccountID = id
        if isImportingBackup {
            // Backup import restores its own storefront settings and displays its own summary banner.
            return
        }
        guard let id, let account = apple.accounts.first(where: { $0.id == id }) else {
            // Removing the signed-in account reports its own confirmation.
            if let previous, apple.accounts.contains(where: { $0.id == previous }) { infoMessage = AppText.text("已退出登录") }
            return
        }
        infoMessage = AppText.text("已切换到 \(account.name.isEmpty ? account.id : account.name)")
        let switchedID = id
        let storefrontCountry = StoreService.country(forStorefront: account.storeFront)
        // Let the notice banner begin rendering before encoding settings / firing search & purchase sync.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.lastAccountID == switchedID else { return }
            if let country = storefrontCountry, self.settings.store.country != country {
                // Changing the region re-runs the search (see settings).
                self.settings.store.country = country
            } else if self.hasSearched {
                self.search()
            }
            #if DEBUG
            if self.visualPreview { return }
            #endif
            await self.refreshOwned()
        }
    }

    func ensureOwnedLoaded() async {
        await cacheLoadTask?.value
        #if DEBUG
        if visualPreview { return }
        #endif
        guard let id = apple.activeID, ownedByAccount[id] == nil, !ownedLoading,
              ownedAutoAttempted.insert(id).inserted else { return }
        await refreshOwned()
    }

    func cancelSearch() { searchTask?.cancel(); localSearchTask?.cancel(); delistedVerifyTask?.cancel(); delistedVerifyTask = nil; searchID = UUID(); searching = false; hasSearched = !results.isEmpty || !localResults.isEmpty; searchError = nil }
    func clearSearch() {
        cancelSearch(); searchText = ""; results = []; localResults = []; hasSearched = false; lastSearchTerm = ""
        lastRemoteResults = []; lastLocalCandidates = []; lastLocalAliases = [:]; resultsContext = nil
    }
    func isFavorite(_ app: StoreApp) -> Bool { favorites.contains { $0.id == app.id } }
    func toggleFavorite(_ app: StoreApp) {
        let previous = favoriteTask
        favoriteTask = Task {
            await previous?.value
            await changeFavorite(app)
        }
    }
    private func changeFavorite(_ app: StoreApp) async {
        guard !cacheLoading else { infoMessage = AppText.text("正在载入本地记录，请稍后重试"); return }
        guard favoritesStorageError == nil else { errorMessage = favoritesStorageError; return }
        var next = favorites
        let following = !next.contains(where: { $0.id == app.id })
        let previousIndex = next.firstIndex { $0.id == app.id } ?? 0
        if following { next.insert(app, at: 0) } else { next.removeAll { $0.id == app.id } }
        do { try await saveCache(next, filename: "favorites.json"); favorites = next; updateLocalResults() }
        catch { errorMessage = AppText.text("关注保存失败：\(error.localizedDescription)"); return }
        if following {
            // Start the record now, so price changes count from this moment.
            Task { await checkWatched(force: true) }
            if settings.watchNotifications {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        } else {
            let previousRecords = watch.filter { $0.value.id == app.id }
            watch = watch.filter { $0.value.id != app.id }
            persistWatch()
            undoNotice = UndoNotice(message: AppText.text("已取消关注 \(app.name)")) { [weak self] notice in
                guard let self, !self.isFavorite(app) else { return }
                let previous = self.favoriteTask
                self.favoriteTask = Task {
                    await previous?.value
                    guard !self.isFavorite(app) else { return }
                    var restored = self.favorites
                    restored.insert(app, at: min(previousIndex, restored.count))
                    do {
                        try await self.saveCache(restored, filename: "favorites.json")
                        self.favorites = restored
                        self.watch.merge(previousRecords) { current, _ in current }
                        self.persistWatch(); self.updateLocalResults()
                    }
                    catch {
                        self.errorMessage = error.localizedDescription
                        self.rearmUndoNotice(notice)
                    }
                }
            }
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
        await cacheLoadTask?.value
        #if DEBUG
        if visualPreview { return [] }
        #endif
        let apps = favorites
        let ids = Set(apps.map(\.id))
        let primary = watchCountry
        var countries = [primary]
        for country in settings.priceRegions.map({ $0.uppercased() }) where !countries.contains(country) { countries.append(country) }
        let keys = ids.union(countries.map { "@" + $0 })
        guard !apps.isEmpty else { return [] }
        if watchChecking {
            // An app followed during a check gets its own check right after.
            if force { watchRecheck = true }
            return []
        }
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
        // The list lookup can leave out an app now and then: ask once more,
        // together, for apps that just went missing before treating them as
        // removed from sale. Apps already known to be removed aren't asked again.
        let missing = apps.map(\.id).filter { id in
            guard found[id] == nil, let record = watch[WatchRecord.key(id: id, country: primary)] else { return false }
            return record.listed && !record.delisted
        }
        var unsure = Set<String>()
        if !missing.isEmpty {
            if let again = try? await StoreService.lookup(ids: missing, country: primary).apps {
                found.merge(again) { first, _ in first }
            } else {
                // No answer: those records stay as they are this time.
                unsure = Set(missing)
            }
        }
        listings[primary] = found
        guard !Task.isCancelled, primary == watchCountry else { return [] }
        var records = watch
        var events: [WatchEvent] = []
        var refreshed = favorites
        // Skip apps unfollowed while the lookups were running.
        for app in apps where refreshed.contains(where: { $0.id == app.id }) {
            for (country, found) in listings where !(country == primary && unsure.contains(app.id)) {
                let key = WatchRecord.key(id: app.id, country: country)
                let listing = found[app.id]
                let result = WatchService.update(records[key], id: app.id, country: country, listing: listing)
                records[key] = result.record
                // Other storefronts only matter for their prices.
                let changes = country == primary ? result.changes : result.changes.filter {
                    if case .priceDrop = $0 { return true }; if case .free = $0 { return true }; return false
                }
                events += changes.filter { WatchService.notifies($0, target: settings.targetPrices ? result.record.target : nil) }
                    .map { (app: listing ?? app, change: $0, currency: result.record.currency, country: country) }
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
        let followed = Set(favorites.map(\.id))
        watch = records.filter { followed.contains($0.value.id) }
        watchChecked = (Date(), keys)
        persistWatch()
        if refreshed != favorites {
            let metadata = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let previous = favoriteTask
            favoriteTask = Task {
                await previous?.value
                let next = self.favorites.map { metadata[$0.id] ?? $0 }
                do { try await self.saveCache(next, filename: "favorites.json"); self.favorites = next }
                catch { self.errorMessage = AppText.text("关注保存失败：\(error.localizedDescription)") }
            }
        }
        if watchRecheck {
            watchRecheck = false
            Task { await self.checkWatched(force: true) }
        }
        return events
    }

    /// Sets or clears the price at which a followed app's drop is announced.
    func setWatchTarget(_ target: Double?, id: String, country: String) {
        let key = WatchRecord.key(id: id, country: country)
        guard watch[key] != nil else { return }
        watch[key]?.target = target.flatMap { $0 > 0 ? $0 : nil }
        persistWatch()
    }

    private func persistWatch() {
        let snapshot = watch
        cacheWrites.async { try? LocalResources.save(snapshot, filename: "watch.json") }
    }

    /// One notification for the changes a background check found.
    func notifyWatchChanges(_ events: [WatchEvent]) {
        let primary = watchCountry
        let lines = events.compactMap { event in
            WatchService.message(event.change, currency: event.currency).map { message in
                event.country == primary
                    ? AppText.text("\(event.app.name)：\(message)")
                    : AppText.text("\(event.app.name)（\(StoreRegions.name(event.country))）：\(message)")
            }
        }
        guard !lines.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = lines.count == 1 ? AppText.text("关注的应用有变化") : AppText.text("\(lines.count) 条关注应用变化")
        let shown = lines.prefix(4).joined(separator: "\n")
        content.body = lines.count > 4 ? shown + "\n" + AppText.text("等") : shown
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
    func removeHistory(_ term: String) {
        searchHistory.removeAll { $0.term == term }
        persistHistory()
    }
    func clearHistory() {
        searchHistory.removeAll()
        persistHistory()
    }

    private var downloadUndoTokens: [UUID] = []
    private var downloadUndoNoticeID: UUID?
    func removeDownloadWithUndo(_ id: UUID) async throws {
        guard let receipt = try await downloads.removeReversibly(id) else { return }
        let reusingBanner = undoNotice?.id != nil
            && undoNotice?.id == downloadUndoNoticeID
            && Date().timeIntervalSince(undoNotice?.created ?? .distantPast) < UndoNotice.duration
        if !reusingBanner {
            downloadUndoTokens.removeAll()
        }
        downloadUndoTokens.append(receipt.token)
        let tokens = downloadUndoTokens
        downloads.extendRemovalUndo(tokens, until: receipt.created.addingTimeInterval(UndoNotice.duration))
        let noticeID = reusingBanner ? (undoNotice?.id ?? UUID()) : UUID()
        let revision = reusingBanner ? (undoNotice?.revision ?? 0) + 1 : 1
        let notice = UndoNotice(id: noticeID, revision: revision, created: receipt.created,
            message: AppText.text("已删除 \(tokens.count) 项任务与文件")) { [weak self] notice in
            guard let self else { return }
            Task { @MainActor in
                do { try await self.downloads.undoRemovalGroup(tokens) }
                catch {
                    self.errorMessage = error.localizedDescription
                    self.rearmUndoNotice(notice, downloadNotice: true)
                }
            }
        }
        undoNotice = notice
        downloadUndoNoticeID = notice.id
    }
    func undoLastAction() {
        let notice = undoNotice; undoNotice = nil
        guard let notice, Date().timeIntervalSince(notice.created) < UndoNotice.duration else { return }
        notice.restore(notice)
    }
    private func rearmUndoNotice(_ notice: UndoNotice, downloadNotice: Bool = false) {
        guard undoNotice == nil, Date().timeIntervalSince(notice.created) < UndoNotice.duration else { return }
        undoNotice = notice
        if downloadNotice { downloadUndoNoticeID = notice.id }
    }
    private func persistHistory() {
        if let data = try? JSONEncoder().encode(searchHistory) { LocalResources.defaults.set(data, forKey: LocalResources.searchHistory) }
    }

    func loadVersions(for app: StoreApp, force: Bool = false, official: Bool = false) async throws -> [AppVersion] {
        #if DEBUG
        if visualPreview {
            var list = [AppVersion(id: "123456789", version: "3.2.1", source: "版本资料"),
                        AppVersion(id: "123456788", version: "3.1.0", source: "版本资料")]
            if ProcessInfo.processInfo.arguments.contains("--version-dates-preview") {
                list.append(AppVersion(id: "123456787", version: "2.0.0", source: "版本资料"))
            }
            return list
        }
        #endif
        let context = settings.store
        if official, let account = apple.activeID {
            // Apple's list costs a signed request: reuse it for a while, so
            // opening the same app again does not ask Apple again.
            let key = "\(account)|\(context.platform.rawValue)|\(context.country)|\(app.id)"
            if !force, let hit = officialVersionCache[key], Date().timeIntervalSince(hit.date) < 30 * 60 {
                let cachedNames = context.platform == .iOS ? await versions.cachedVersionMap(appID: app.id, sources: settings.versionSources) : [:]
                let reconciled = await reconcileVersionEntries(hit.versions, for: app, platform: context.platform, extraNames: cachedNames)
                if reconciled != hit.versions { officialVersionCache[key] = (hit.date, reconciled) }
                return reconciled
            }
            let list = try await appleVersions(for: app, context: context, force: force)
            officialVersionCache[key] = (Date(), list)
            return list
        }
        if context.platform == .macOS {
            // Only the latest version is public; the full list needs the account.
            guard let id = try await MacStoreOfferService.latestVersionID(appID: app.id, bundleID: app.bundleID, country: context.country)
            else { return [] }
            return [AppVersion(id: id, version: app.version.isEmpty ? AppVersion.unknown : app.version, source: "App Store")]
        }
        if context.platform == .tvOS {
            guard let listing = try await StoreService.platformApp(app.id, store: context),
                  let id = listing.externalVersionID, !id.isEmpty else { return [] }
            return [AppVersion(id: id, version: listing.version.isEmpty ? AppVersion.unknown : listing.version, source: "Apple TV")]
        }
        var list = try await versions.thirdParty(app.id, sources: settings.versionSources, force: force)
        list = await reconcileVersionEntries(list, for: app, platform: context.platform, extraNames: [:])
        if let account = apple.activeID {
            let key = "\(account)|\(context.platform.rawValue)|\(context.country)|\(app.id)"
            if let hit = officialVersionCache[key] {
                var names: [String: String] = [:]
                for item in list {
                    names[item.id] = VersionService.preferredVersion(item.version, over: names[item.id] ?? AppVersion.unknown, rejectingID: item.id)
                }
                let reconciled = await reconcileVersionEntries(hit.versions, for: app, platform: context.platform, extraNames: names)
                if reconciled != hit.versions { officialVersionCache[key] = (hit.date, reconciled) }
            }
        }
        return list
    }

    private func cachedOfficialVersions(platform: AppPlatform, appID: String) -> [AppVersion] {
        let countryKey = "|\(platform.rawValue)|\(settings.store.country)|\(appID)"
        if let direct = officialVersionCache.first(where: { $0.key.hasSuffix(countryKey) })?.value.versions {
            return direct
        }
        return officialVersionCache.first(where: {
            $0.key.contains("|\(platform.rawValue)|") && $0.key.hasSuffix("|\(appID)")
        })?.value.versions ?? []
    }

    private func reconcileVersionEntries(
        _ entries: [AppVersion],
        for app: StoreApp,
        platform: AppPlatform,
        extraNames: [String: String]
    ) async -> [AppVersion] {
        guard !entries.isEmpty else { return entries }
        let cachedMeta = await metadataStore.cached(entries.map {
            VersionMetadataStore.key(platform: platform, appID: app.id, versionID: $0.id)
        })
        let storeVersion = VersionService.sanitizedVersion(app.version, rejectingID: app.externalVersionID)
        return entries.enumerated().map { index, entry in
            var updated = entry
            let key = VersionMetadataStore.key(platform: platform, appID: app.id, versionID: entry.id)
            let storeCandidate = entry.id == app.externalVersionID ? storeVersion : AppVersion.unknown
            let meta = cachedMeta[key]
            let cachedCandidate: String = {
                guard let meta else { return "" }
                if (meta.metadataSchema ?? 0) < 2,
                   VersionService.versionPreference(meta.version, rejectingID: entry.id) < 2,
                   VersionService.isLikelyStaleLatestFallback(
                       meta.version, versionID: entry.id, appVersion: app.version,
                       versions: entries, cachedMetadata: cachedMeta,
                       rowIndex: index, rowReleased: meta.released
                   ) {
                    return ""
                }
                if meta.version == AppVersion.unknown, (meta.metadataSchema ?? 0) < VersionMetadata.currentSchema {
                    return ""
                }
                return meta.version
            }()
            let extraRaw = extraNames[entry.id] ?? ""
            let extraCandidate = (VersionService.versionPreference(extraRaw, rejectingID: entry.id) < 2 &&
                VersionService.isLikelyStaleLatestFallback(
                    extraRaw, versionID: entry.id, appVersion: app.version,
                    versions: entries, cachedMetadata: cachedMeta, rowIndex: index
                )) ? "" : extraRaw
            let entryCandidate = (VersionService.versionPreference(entry.version, rejectingID: entry.id) < 2 &&
                VersionService.isLikelyStaleLatestFallback(
                    entry.version, versionID: entry.id, appVersion: app.version,
                    versions: entries, cachedMetadata: cachedMeta, rowIndex: index
                )) ? "" : entry.version
            let metaIsLegacyUnseparated = meta != nil && meta?.bundleShortVersion == nil &&
                (meta?.metadataSchema ?? 0) < VersionMetadata.currentSchema
            updated.version = VersionService.bestVersion(
                metaIsLegacyUnseparated
                    ? [storeCandidate, extraCandidate, entryCandidate, cachedCandidate]
                    : [storeCandidate, cachedCandidate, extraCandidate, entryCandidate],
                rejectingID: entry.id
            )
            return updated
        }
    }

    func clearVersionCaches() async throws {
        try await versions.clearCache()
        try await metadataStore.clearCache()
        officialVersionCache.removeAll()
    }

    /// Every version Apple lists for the active account. Never claims a license.
    private func appleVersions(for app: StoreApp, context: StoreContext, force: Bool) async throws -> [AppVersion] {
        var seen = Set<String>()
        if context.platform == .macOS {
            let offer = try await apple.macPackageOffer(app, useCache: settings.useSignerCache, allowLicenseAcquisition: false)
            let ids = offer.externalVersionIDs.isEmpty ? [offer.versionID] : Array(offer.externalVersionIDs.reversed())
            return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { id in
                AppVersion(id: id, version: id == offer.versionID && !offer.displayVersion.isEmpty ? offer.displayVersion : AppVersion.unknown, source: "Apple")
            }
        }
        let asset = try await apple.asset(appID: app.id, versionID: nil, store: context,
                                          useCache: settings.useSignerCache, allowLicenseAcquisition: false)
        let third = context.platform == .iOS ? (try? await versions.thirdParty(app.id, sources: settings.versionSources, force: force)) ?? [] : []
        var names: [String: String] = [:]
        for item in third {
            names[item.id] = VersionService.preferredVersion(item.version, over: names[item.id] ?? AppVersion.unknown, rejectingID: item.id)
        }
        let ids = asset.externalVersionIDs.isEmpty ? [asset.app.externalVersionID ?? ""] : Array(asset.externalVersionIDs.reversed())
        let filteredIDs = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        let cachedMeta = await metadataStore.cached(filteredIDs.map {
            VersionMetadataStore.key(platform: context.platform, appID: app.id, versionID: $0)
        })
        return filteredIDs.map { id in
            let metaKey = VersionMetadataStore.key(platform: context.platform, appID: app.id, versionID: id)
            let meta = cachedMeta[metaKey]
            let metaIsLegacyUnseparated = meta != nil && meta?.bundleShortVersion == nil &&
                (meta?.metadataSchema ?? 0) < VersionMetadata.currentSchema
            let ticketVersion = id == asset.app.externalVersionID ? asset.app.version : ""
            let storeVersion = id == app.externalVersionID ? app.version : ""
            let thirdPartyVersion = names[id] ?? ""
            let cachedVersion = meta?.version ?? ""
            let known = VersionService.bestVersion(
                metaIsLegacyUnseparated
                    ? [storeVersion, thirdPartyVersion, cachedVersion, ticketVersion]
                    : [storeVersion, cachedVersion, thirdPartyVersion, ticketVersion],
                rejectingID: id
            )
            return AppVersion(id: id, version: known, source: "Apple")
        }
    }

    func cachedVersionMetadata(app: StoreApp, versionIDs: [String]) async -> [String: VersionMetadata] {
        #if DEBUG
        if visualPreview {
            var result: [String: VersionMetadata] = [:]
            for id in versionIDs { result[id] = try? await versionMetadata(app: app, versionID: id, includingIcon: settings.showHistoryIcons) }
            return result
        }
        #endif
        let platform = settings.store.platform
        let keys = Dictionary(versionIDs.map { (VersionMetadataStore.key(platform: platform, appID: app.id, versionID: $0), $0) },
                              uniquingKeysWith: { first, _ in first })
        let found = await metadataStore.cached(Array(keys.keys))
        return Dictionary(found.compactMap { key, value in keys[key].map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Reconciles any cached version list entries when higher-preference metadata arrives.
    func reconcileVersionNumber(platform: AppPlatform, appID: String, versionID: String, version: String, replaceStaleDotless: Bool = false) async {
        let normalized = VersionService.sanitizedVersion(version, rejectingID: versionID)
        let incomingScore = VersionService.versionPreference(normalized, rejectingID: versionID)
        if !replaceStaleDotless && normalized == AppVersion.unknown { return }
        for (cacheKey, var cached) in officialVersionCache where cacheKey.hasSuffix("|\(platform.rawValue)|\(settings.store.country)|\(appID)") || cacheKey.contains("|\(platform.rawValue)|") && cacheKey.hasSuffix("|\(appID)") {
            var changed = false
            for index in cached.versions.indices where cached.versions[index].id == versionID {
                let current = cached.versions[index].version
                let currentScore = VersionService.versionPreference(current, rejectingID: versionID)
                let next: String
                if replaceStaleDotless && currentScore <= 1 && (incomingScore >= currentScore || normalized == AppVersion.unknown) {
                    next = normalized
                } else if normalized != AppVersion.unknown {
                    next = VersionService.preferredVersion(normalized, over: current, rejectingID: versionID)
                } else {
                    continue
                }
                if next != current {
                    cached.versions[index].version = next
                    changed = true
                }
            }
            if changed { officialVersionCache[cacheKey] = cached }
        }
        await versions.reconcile(appID: appID, versionID: versionID, version: normalized, replaceDotless: replaceStaleDotless)
        let metaKey = VersionMetadataStore.key(platform: platform, appID: appID, versionID: versionID)
        await metadataStore.upgradeCachedVersion(metaKey, version: normalized, replaceDotless: replaceStaleDotless)
    }

    /// The version number and date of one version, read from Apple. Lookups
    /// are cached and run one at a time.
    func versionMetadata(app: StoreApp, versionID: String, includingIcon: Bool = true,
                         knownVersion: String? = nil,
                         knownVersions: [AppVersion] = [],
                         onMetadata: (@MainActor @Sendable (VersionMetadata) -> Void)? = nil) async throws -> VersionMetadata {
        #if DEBUG
        if visualPreview {
            let newest = versionID == "123456789"
            let datesPreview = ProcessInfo.processInfo.arguments.contains("--version-dates-preview")
            let age = versionID == "123456787" ? 800 : newest ? 2 : 10
            return VersionMetadata(version: versionID == "123456787" ? "2.0.0" : newest ? "3.2.1" : "3.1.0",
                                   released: datesPreview ? Calendar.current.date(byAdding: .day, value: -age, to: Date()) : Date(timeIntervalSince1970: 1_714_694_400),
                                   packageSize: newest ? 128_000_000 : 96_000_000,
                                   iconAvailable: includingIcon && ProcessInfo.processInfo.arguments.contains("--version-icons-preview") &&
                                       !(ProcessInfo.processInfo.arguments.contains("--version-icon-missing-preview") && !newest))
        }
        #endif
        let platform = settings.store.platform
        let useCache = settings.useSignerCache
        let metadataStore = self.metadataStore
        let key = VersionMetadataStore.key(platform: platform, appID: app.id, versionID: versionID)
        let effectiveVersions = knownVersions.isEmpty ? cachedOfficialVersions(platform: platform, appID: app.id) : knownVersions
        let sanitizedKnown = knownVersion.map { VersionService.sanitizedVersion($0, rejectingID: versionID) } ?? AppVersion.unknown
        let knownWasStaleFallback = VersionService.versionPreference(sanitizedKnown, rejectingID: versionID) < 2 &&
            VersionService.isLikelyStaleLatestFallback(
                sanitizedKnown, versionID: versionID, appVersion: app.version, versions: effectiveVersions
            )
        let safeKnown = knownWasStaleFallback ? AppVersion.unknown : sanitizedKnown
        let baselineKnown = VersionService.bestVersion([
            safeKnown,
            versionID == app.externalVersionID ? app.version : ""
        ], rejectingID: versionID)
        let appVersionSnapshot = app.version
        let allowCachedMeta: @Sendable (VersionMetadata) -> Bool = { candidate in
            let schema = candidate.metadataSchema ?? 0
            if candidate.version == AppVersion.unknown, schema < VersionMetadata.currentSchema {
                return false
            }
            if schema < 2,
               VersionService.versionPreference(candidate.version, rejectingID: versionID) < 2,
               VersionService.isLikelyStaleLatestFallback(
                   candidate.version, versionID: versionID, appVersion: appVersionSnapshot,
                   versions: effectiveVersions, rowReleased: candidate.released
               ) {
                return false
            }
            return true
        }
        let previousCached = await metadataStore.cached(key)
        let previousWasStale = previousCached.map { !allowCachedMeta($0) } ?? false
        let loaded = try await metadataStore.load(
            key,
            requiringPackageSize: platform.supportsIPA,
            requiringIcon: includingIcon && platform.supportsIPA,
            knownVersion: baselineKnown == AppVersion.unknown ? nil : baselineKnown,
            allowCached: allowCachedMeta
        ) { @MainActor [apple] in
            if platform == .macOS {
                // A Mac package cannot be read in part; Apple's ticket names the version.
                let offer = try await apple.macPackageOffer(app, versionID: versionID, useCache: useCache,
                                                            allowLicenseAcquisition: false)
                guard !offer.displayVersion.isEmpty else { throw RemoteZip.Failure.notFound }
                return VersionMetadata(version: VersionService.preferredVersion(offer.displayVersion, over: baselineKnown, rejectingID: versionID),
                                       released: nil, ticketChecked: true, metadataSchema: VersionMetadata.currentSchema)
            }
            let ticket = try await apple.versionTicketDetails(appID: app.id, versionID: versionID, useCache: useCache)
            var ticketVersion = ticket.displayVersion
            if VersionService.isLikelyStaleLatestFallback(
                   ticketVersion, versionID: versionID, appVersion: appVersionSnapshot, versions: effectiveVersions
               ) {
                let buildCandidate = VersionService.sanitizedVersion(ticket.buildVersion, rejectingID: versionID)
                if buildCandidate != AppVersion.unknown,
                   !VersionService.isLikelyStaleLatestFallback(
                       buildCandidate, versionID: versionID, appVersion: appVersionSnapshot, versions: effectiveVersions
                   ) {
                    ticketVersion = buildCandidate
                } else {
                    ticketVersion = ""
                }
            }
            let baselinePref = VersionService.versionPreference(baselineKnown, rejectingID: versionID)
            let ticketPref = VersionService.versionPreference(ticketVersion, rejectingID: versionID)
            let trustedMarketing = baselinePref >= 2 ? baselineKnown : nil
            let preferredForRemoteZip = trustedMarketing ?? ((ticketPref >= baselinePref && !ticketVersion.isEmpty && baselinePref == 0) ? nil : (baselineKnown == AppVersion.unknown ? nil : baselineKnown))
            let previewVersion = trustedMarketing ?? ((ticketPref >= baselinePref && !ticketVersion.isEmpty) ? ticketVersion : baselineKnown)
            if previewVersion != AppVersion.unknown || ticket.fileSize != nil {
                onMetadata?(VersionMetadata(version: previewVersion, released: nil,
                                            packageSize: ticket.fileSize, ticketChecked: true,
                                            metadataSchema: VersionMetadata.currentSchema))
            }
            do {
                let resources = try await RemoteZip.versionResources(
                    HTTPRangeReader(url: ticket.url),
                    includingIcon: includingIcon,
                    preferredVersion: preferredForRemoteZip,
                    onMetadata: { value in await onMetadata?(value) }
                )
                var metadata = resources.metadata
                if let trustedMarketing {
                    metadata.version = trustedMarketing
                } else if metadata.version == AppVersion.unknown && !ticketVersion.isEmpty {
                    metadata.version = ticketVersion
                }
                metadata.ticketChecked = true
                metadata.metadataSchema = VersionMetadata.currentSchema
                if metadata.packageSize == nil { metadata.packageSize = ticket.fileSize }
                if let icon = resources.icon {
                    do { try await metadataStore.saveIcon(icon, key: key) }
                    catch { metadata.iconAvailable = nil }
                }
                return metadata
            } catch RemoteZip.Failure.notFound where previewVersion != AppVersion.unknown || ticket.fileSize != nil,
                    RemoteZip.Failure.unreadable where previewVersion != AppVersion.unknown || ticket.fileSize != nil {
                return VersionMetadata(version: previewVersion, released: nil,
                                       packageSize: ticket.fileSize, iconAvailable: includingIcon ? false : nil,
                                       ticketChecked: true, metadataSchema: VersionMetadata.currentSchema)
            }
        }
        await reconcileVersionNumber(platform: platform, appID: app.id, versionID: versionID,
                                     version: loaded.version, replaceStaleDotless: previousWasStale || knownWasStaleFallback)
        return loaded
    }

    func cachedVersionImage(app: StoreApp, versionID: String) async -> UIImage? {
        #if DEBUG
        if visualPreview {
            let data = await cachedVersionIcon(app: app, versionID: versionID)
            return data.flatMap(UIImage.init(data:))
        }
        #endif
        return await metadataStore.image(VersionMetadataStore.key(
            platform: settings.store.platform, appID: app.id, versionID: versionID))
    }

    func cachedVersionIcon(app: StoreApp, versionID: String) async -> Data? {
        #if DEBUG
        if visualPreview {
            guard ProcessInfo.processInfo.arguments.contains("--version-icons-preview"),
                  !(ProcessInfo.processInfo.arguments.contains("--version-icon-missing-preview") && versionID != "123456789") else { return nil }
            // Explicit preview-only samples, not claimed to be historical store artwork.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120), format: format).pngData { context in
                (versionID == "123456789" ? UIColor.systemOrange : UIColor.systemBlue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
                ("示例" as NSString).draw(at: CGPoint(x: 22, y: 42), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: UIColor.white])
            }
        }
        #endif
        return await metadataStore.icon(VersionMetadataStore.key(
            platform: settings.store.platform, appID: app.id, versionID: versionID))
    }

    func resolvedLatestVersionID(appID: String, platform: AppPlatform) -> String? {
        resolvedLatestVersionIDs["\(platform.rawValue)|\(appID)"]
    }

    func isPreparingDownload(appID: String, platform: AppPlatform, versionID: String? = nil) -> Bool {
        let direct = DownloadTargetKey(appID: appID, platform: platform, versionID: versionID)
        if preparingDownloads.contains(direct) { return true }
        if direct.versionID == nil, let latest = resolvedLatestVersionID(appID: appID, platform: platform) {
            return preparingDownloads.contains(DownloadTargetKey(appID: appID, platform: platform, versionID: latest))
        }
        if let versionID = direct.versionID, versionID == resolvedLatestVersionID(appID: appID, platform: platform) {
            return preparingDownloads.contains(DownloadTargetKey(appID: appID, platform: platform, versionID: nil))
        }
        return false
    }

    func cancelDownloadPreparation(appID: String, platform: AppPlatform, versionID: String? = nil) {
        let direct = DownloadTargetKey(appID: appID, platform: platform, versionID: versionID)
        var keys = [direct]
        if direct.versionID == nil, let latest = resolvedLatestVersionID(appID: appID, platform: platform) {
            keys.append(DownloadTargetKey(appID: appID, platform: platform, versionID: latest))
        } else if let versionID = direct.versionID, versionID == resolvedLatestVersionID(appID: appID, platform: platform) {
            keys.append(DownloadTargetKey(appID: appID, platform: platform, versionID: nil))
        }
        for key in keys {
            prepareTasks.removeValue(forKey: key)?.cancel()
            preparingDownloads.remove(key)
        }
    }

    private func jobMatchesPlatform(_ job: DownloadJob, platform: AppPlatform) -> Bool {
        if platform == .macOS { return job.rawFormat != nil }
        guard job.rawFormat == nil else { return false }
        return (job.updatePlatform ?? .iOS) == platform
    }

    private static func jobPriorityRank(_ status: DownloadStatus) -> Int {
        switch status {
        case .running, .queued, .pausing, .processing, .paused: return 3
        case .completed: return 2
        case .failed: return 1
        }
    }

    func matchingDownloadJob(
        for app: StoreApp,
        platform: AppPlatform,
        versionID: String? = nil,
        treatOutdatedCompletedAsIdle: Bool = true
    ) -> DownloadJob? {
        let candidates = downloads.jobs.filter { $0.app.id == app.id && jobMatchesPlatform($0, platform: platform) }
        guard !candidates.isEmpty else { return nil }
        let explicitExt = versionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetExt = (explicitExt?.isEmpty == false ? explicitExt : nil)
            ?? (app.externalVersionID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? resolvedLatestVersionID(appID: app.id, platform: platform)

        let matched: [DownloadJob]
        if let targetExt {
            matched = candidates.filter { $0.resolvedExternalVersionID == targetExt }
        } else {
            let storeVersion = app.version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !storeVersion.isEmpty && storeVersion != AppVersion.unknown {
                matched = candidates.filter {
                    let jobVersion = $0.userFacingVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                    return jobVersion == storeVersion || ($0.app.externalVersionID == nil && $0.status != .completed)
                }
            } else {
                matched = candidates
            }
        }
        guard let best = matched.max(by: { lhs, rhs in
            Self.jobPriorityRank(lhs.status) < Self.jobPriorityRank(rhs.status)
        }) else {
            return nil
        }
        if treatOutdatedCompletedAsIdle, best.status == .completed,
           explicitExt?.isEmpty != false,
           let key = best.updateKey, availableUpdates[key] != nil {
            return nil
        }
        return best
    }

    func triggerAppStoreAction(
        for app: StoreApp,
        platform: AppPlatform? = nil,
        versionID: String? = nil,
        marketingVersion: String? = nil,
        treatOutdatedCompletedAsIdle: Bool = true,
        onEnqueued: (@MainActor () -> Void)? = nil,
        onRequireVerification: (@MainActor () -> Void)? = nil,
        onRequireReauthentication: (@MainActor (String?) -> Void)? = nil
    ) {
        let targetPlatform = platform ?? settings.store.platform
        if let versionID, !versionID.isEmpty, !versionID.allSatisfy({ $0.isASCII && $0.isNumber }) {
            errorMessage = AppText.text("版本 ID 只能包含数字")
            return
        }
        if isPreparingDownload(appID: app.id, platform: targetPlatform, versionID: versionID) {
            cancelDownloadPreparation(appID: app.id, platform: targetPlatform, versionID: versionID)
            return
        }
        if let job = matchingDownloadJob(for: app, platform: targetPlatform, versionID: versionID,
                                         treatOutdatedCompletedAsIdle: treatOutdatedCompletedAsIdle) {
            switch job.status {
            case .queued, .running:
                downloads.pause(job.id)
                return
            case .pausing, .processing:
                if job.protectedMacPackage == true { downloads.cancelProcessing(job.id) }
                return
            case .paused:
                downloads.resume(job.id)
                return
            case .completed:
                if job.rawFormat == nil {
                    installingJob = job
                } else {
                    selectTab(.downloads)
                }
                return
            case .failed:
                if job.asset != nil {
                    let key = DownloadTargetKey(appID: app.id, platform: targetPlatform, versionID: versionID ?? job.resolvedExternalVersionID)
                    runDownloadPreparation(
                        key: key,
                        onRequireVerification: onRequireVerification,
                        onRequireReauthentication: onRequireReauthentication,
                        retry: {
                            self.triggerAppStoreAction(
                                for: app, platform: targetPlatform, versionID: versionID,
                                marketingVersion: marketingVersion,
                                treatOutdatedCompletedAsIdle: treatOutdatedCompletedAsIdle,
                                onEnqueued: onEnqueued
                            )
                        },
                        operation: {
                            try await SAPSigner.$userInitiated.withValue(true) {
                                try await self.refreshDownload(job, switchToDownloadsTab: false)
                            }
                            onEnqueued?()
                        }
                    )
                    return
                } else {
                    downloads.resume(job.id)
                    return
                }
            }
        }
        let retryAction: @MainActor () -> Void = {
            self.triggerAppStoreAction(
                for: app, platform: targetPlatform, versionID: versionID,
                marketingVersion: marketingVersion,
                treatOutdatedCompletedAsIdle: treatOutdatedCompletedAsIdle,
                onEnqueued: onEnqueued
            )
        }
        guard apple.active != nil else {
            if let onRequireReauthentication {
                onRequireReauthentication(nil)
            } else {
                loginPrompt = LoginPrompt(accountID: nil, retry: retryAction)
            }
            return
        }
        let targetVersionID = versionID?.isEmpty == true ? nil : versionID
        let key = DownloadTargetKey(appID: app.id, platform: targetPlatform, versionID: targetVersionID)
        runDownloadPreparation(
            key: key,
            onRequireVerification: onRequireVerification,
            onRequireReauthentication: onRequireReauthentication,
            retry: retryAction,
            operation: {
                if targetPlatform.supportsIPA {
                    try await self.startDownload(app: app, versionID: targetVersionID, marketingVersion: marketingVersion,
                                                 switchToDownloadsTab: false)
                } else {
                    let offer = try await SAPSigner.$userInitiated.withValue(true) {
                        try await self.apple.macPackageOffer(app, versionID: targetVersionID, useCache: self.settings.useSignerCache)
                    }
                    try Task.checkCancellation()
                    try self.downloads.enqueueOfficialMacPackage(offer, for: app)
                }
                onEnqueued?()
            }
        )
    }

    private func runDownloadPreparation(
        key: DownloadTargetKey,
        onRequireVerification: (@MainActor () -> Void)?,
        onRequireReauthentication: (@MainActor (String?) -> Void)?,
        retry: @escaping @MainActor () -> Void,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard prepareTasks[key] == nil else { return }
        preparingDownloads.insert(key)
        prepareTasks[key] = Task {
            defer {
                preparingDownloads.remove(key)
                prepareTasks.removeValue(forKey: key)
            }
            do {
                try await operation()
            } catch AppleLoginError.verificationRequired {
                if let onRequireVerification { onRequireVerification() }
                else { requestVerification(retry: retry) }
            } catch AppleAuthError.reauthenticationRequired {
                if let onRequireReauthentication { onRequireReauthentication(apple.activeID) }
                else { loginPrompt = LoginPrompt(accountID: apple.activeID, retry: retry) }
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func startDownload(app: StoreApp, versionID: String?, marketingVersion: String? = nil, switchToDownloadsTab: Bool = false) async throws {
        var asset = try await SAPSigner.$userInitiated.withValue(true) {
            try await apple.asset(appID: app.id, versionID: versionID, store: settings.store, useCache: settings.useSignerCache)
        }
        // Apple DownloadDispatch often omits artwork even when the store
        // listing showed it. Do not lose that listing before enqueuing.
        if asset.app.iconURL == nil { asset.app.iconURL = app.iconURL }
        let selectedMarketing = marketingVersion ?? ((versionID == nil || versionID == app.externalVersionID) ? app.version : nil)
        if let selectedMarketing {
            let clean = VersionService.sanitizedVersion(selectedMarketing, rejectingID: asset.app.externalVersionID ?? versionID)
            if clean != AppVersion.unknown && VersionService.versionPreference(clean) >= 2 {
                asset.app.storeMarketingVersion = clean
            }
        }
        try downloads.enqueue(asset)
        if versionID == nil,
           let extID = asset.app.externalVersionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extID.isEmpty {
            resolvedLatestVersionIDs["\(settings.store.platform.rawValue)|\(app.id)"] = extID
        }
        // A delisted app's only artwork may arrive with the download itself.
        if let icon = asset.app.iconURL {
            func patched(_ apps: [StoreApp]) -> [StoreApp] {
                apps.map { var item = $0; if item.id == app.id && item.iconURL == nil { item.iconURL = icon }; return item }
            }
            publishSearchResults(primary: patched(results), secondary: patched(localResults))
        }
        if switchToDownloadsTab { selectTab(.downloads) }
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
        // A kept version holds only until a newer one is downloaded.
        let outgrown = keptVersions.filter { key, kept in newest[key].map { VersionOrder.isNewer($0, than: kept) } ?? false }
        if !outgrown.isEmpty {
            for key in outgrown.keys { keptVersions[key] = nil }
            LocalResources.defaults.set(keptVersions, forKey: "storage_keptVersions")
        }
        var updates: [String: StoreApp] = [:]
        for (key, app) in listings where keptVersions[key] == nil {
            if let current = newest[key], VersionOrder.isNewer(app.version, than: current) { updates[key] = app }
        }
        availableUpdates = updates
        updatesChecked = (Date(), keys)
    }

    /// A newer iPadn release than the running one, when found.
    @Published private(set) var appUpdate: AppRelease?
    @Published private(set) var appUpdateChecking = false
    private(set) var appUpdateDiagnostic = "No update check attempted in this session."

    /// Looks for a newer iPadn release at most every 12 hours unless forced.
    /// Returns whether the check reached GitHub.
    @discardableResult
    func checkAppUpdate(force: Bool = false) async -> Bool {
        #if DEBUG
        if visualPreview { return false }
        #endif
        let key = "storage_appUpdateChecked"
        if !force, let last = LocalResources.defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 12 * 3600 {
            if appUpdate == nil, let data = LocalResources.defaults.data(forKey: "storage_appUpdate") {
                appUpdate = AppUpdateService.newer(try? JSONDecoder().decode(AppRelease.self, from: data))
            }
            return true
        }
        guard !appUpdateChecking else { return false }
        appUpdateChecking = true
        defer { appUpdateChecking = false }
        guard let latest = await AppUpdateService.latest(report: { self.appUpdateDiagnostic = $0 }) else { return false }
        LocalResources.defaults.set(Date(), forKey: key)
        LocalResources.defaults.set(try? JSONEncoder().encode(latest), forKey: "storage_appUpdate")
        appUpdate = AppUpdateService.newer(latest)
        // Installed already: the kept package is no longer needed.
        if appUpdate == nil { AppUpdateService.removeDownloads() }
        return true
    }

    /// Notifies once per new iPadn version.
    func notifyAppUpdate() {
        guard let release = appUpdate else { return }
        let key = "storage_appUpdateNotified"
        guard LocalResources.defaults.string(forKey: key) != release.version else { return }
        LocalResources.defaults.set(release.version, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = AppText.text("iPadn \(release.version) 可以更新了")
        content.body = AppText.text("打开 iPadn，在「设置」中查看更新内容并下载新版本。")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "app-update-" + release.version, content: content, trigger: nil))
    }

    /// Whether each purchase is still on sale in the account's storefront
    /// (false: removed, but the account can still download it). Empty until checked.
    @Published private(set) var ownedListed: [String: Bool] = [:]
    @Published private(set) var checkingListings = false

    /// Looks up every purchase in the account's storefront; returns how many
    /// are no longer on sale, or nil when the lookup failed.
    func checkOwnedListings() async -> Int? {
        guard !owned.isEmpty, !checkingListings else { return nil }
        let accountID = apple.activeID
        let country = watchCountry
        let ids = owned.map(\.id)
        checkingListings = true
        defer { checkingListings = false }
        guard var found = try? await StoreService.lookup(ids: ids, country: country).apps else { return nil }
        // The list lookup can leave out an app now and then: ask again for those.
        let missing = ids.filter { found[$0] == nil }
        if !missing.isEmpty {
            guard let again = try? await StoreService.lookup(ids: missing, country: country).apps else { return nil }
            found.merge(again) { first, _ in first }
        }
        guard apple.activeID == accountID else { return nil }
        ownedListed = Dictionary(uniqueKeysWithValues: ids.map { ($0, found[$0] != nil) })
        return ownedListed.values.filter { !$0 }.count
    }

    /// The purchase list as a CSV file for sharing.
    func exportOwned() throws -> URL {
        let downloaded = Set(downloads.jobs.filter { $0.status == .completed }.map(\.app.id))
        let text = PurchaseExport.csv(owned, listed: ownedListed, downloaded: downloaded)
        let stamp = Date().formatted(.iso8601.year().month().day())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(AppText.text("iPadn-已购项目-\(stamp)") + ".csv")
        // A byte-order mark lets spreadsheet apps read the Chinese text.
        try Data(("\u{FEFF}" + text).utf8).write(to: file, options: .atomic)
        return file
    }

    func keepsVersion(_ job: DownloadJob) -> Bool { job.updateKey.map { keptVersions[$0] == job.storeVersion } ?? false }
    /// Keeps this download's app at its version (no update reminders), or
    /// lets reminders resume.
    func keepVersion(_ keep: Bool, of job: DownloadJob) {
        guard let key = job.updateKey else { return }
        if keep {
            keptVersions[key] = job.storeVersion
            availableUpdates[key] = nil
        } else {
            keptVersions[key] = nil
            Task { await checkForUpdates(force: true) }
        }
        LocalResources.defaults.set(keptVersions, forKey: "storage_keptVersions")
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
        content.title = fresh.count == 1 ? AppText.text("\(fresh.values.first!.name) 有新版本") : AppText.text("\(fresh.count) 个应用有新版本")
        let list = names.joined(separator: AppText.text("、")) + (fresh.count > 3 ? AppText.text(" 等") : "")
        content.body = AppText.text("\(list)。打开 iPadn 下载新版本。")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-" + UUID().uuidString, content: content, trigger: nil))
    }

    /// Downloads the store's current version of a finished download.
    func downloadUpdate(of job: DownloadJob) async throws {
        guard try await enqueueUpdate(of: job) else { return }
        infoMessage = AppText.text("已开始下载新版本")
    }

    /// Whether a download of this app is already on its way.
    /// The newest finished download of each app with a newer store version.
    var updatableJobs: [DownloadJob] {
        var seen = Set<String>()
        return downloads.jobs.filter { job in
            guard job.status == .completed, let key = job.updateKey, availableUpdates[key] != nil else { return false }
            return seen.insert(key).inserted
        }
    }

    private func updateInProgress(_ key: String) -> Bool {
        downloads.jobs.contains { $0.updateKey == key && [.queued, .running, .pausing, .paused, .processing].contains($0.status) }
    }

    /// Adds every available update to the queue. Sign-in and verification
    /// problems stop the batch (they would repeat for every app) and are
    /// thrown; the caller can verify and call again, and apps already added
    /// are skipped then. Other problems are reported per app.
    func downloadAllUpdates(of jobs: [DownloadJob]) async throws {
        #if DEBUG
        if visualPreview { infoMessage = AppText.text("已添加 \(jobs.count) 个下载任务"); return }
        #endif
        var added = 0
        var failures: [String] = []
        defer {
            if added > 0 { infoMessage = AppText.text("已添加 \(added) 个下载任务") }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
        for job in jobs {
            guard let key = job.updateKey, !updateInProgress(key) else { continue }
            do {
                if try await enqueueUpdate(of: job) { added += 1 }
            } catch let error where error is AppleLoginError || error is AppleAuthError || error is CancellationError {
                throw error
            } catch {
                failures.append(AppText.text("\(job.app.name.isEmpty ? job.app.id : job.app.name)：\(error.localizedDescription)"))
                if error is DownloadQueueLimitError { break }
            }
        }
    }

    /// Queues the newer version of a finished download; false when there is none.
    private func enqueueUpdate(of job: DownloadJob) async throws -> Bool {
        guard let key = job.updateKey, let platform = job.updatePlatform, let latest = availableUpdates[key] else { return false }
        guard apple.active != nil else { throw ToolError.message(AppText.text("请先在「账号」中登录 Apple 账号")) }
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
        return true
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
            } catch AppleLoginError.verificationRequired {
                // Verify, then carry on with this app and the rest.
                let remaining = Array(apps[index...])
                requestVerification { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        let result = await self.startDownloads(remaining) { _ in }
                        if result.added > 0 { self.infoMessage = AppText.text("已添加 \(result.added) 个下载任务") }
                        if !result.failures.isEmpty { self.errorMessage = result.failures.joined(separator: "\n") }
                    }
                }
                break
            } catch let error where error is AppleAuthError || error is AppleLoginError {
                failures.append(AppText.text("Apple 账号登录已失效，请在「账号」中重新登录后再试。"))
                break
            } catch {
                let message = error.localizedDescription
                failures.append(AppText.text("\(app.name.isEmpty ? app.id : app.name)：\(message)"))
                if error is DownloadQueueLimitError { break }
            }
            progress(index + 1)
        }
        return (added, failures)
    }

    func refreshDownload(_ job: DownloadJob, switchToDownloadsTab: Bool = true) async throws {
        guard job.status == .failed else { throw ToolError.message(AppText.text("此任务无法重试")) }
        if job.asset == nil, job.rawFormat == "pkg", UInt64(job.app.id) != nil {
            guard apple.active != nil else {
                throw ToolError.message(AppText.text("请先在「账号」中登录 Apple 账号"))
            }
            let offer = try await apple.macPackageOffer(job.app, useCache: settings.useSignerCache)
            try downloads.refreshFailedMacPackage(job.id, offer: offer)
            if switchToDownloadsTab { selectTab(.downloads) }
            return
        }
        guard job.asset != nil else { throw ToolError.message(AppText.text("此任务无法重试")) }
        guard apple.activeID == job.account else { throw ToolError.message(AppText.text("请先切换至原下载账号：\(job.account ?? "")")) }
        let platform: AppPlatform
        switch job.asset?.platform.lowercased() {
        case "appletvos", "tvos", "atv9": platform = .tvOS
        case "ipad": platform = .iPadOS
        default: platform = .iOS
        }
        var asset = try await apple.asset(appID: job.app.id, versionID: job.asset?.app.externalVersionID ?? job.app.externalVersionID,
            store: StoreContext(country: settings.store.country, platform: platform), useCache: settings.useSignerCache)
        if asset.app.storeMarketingVersion == nil {
            asset.app.storeMarketingVersion = job.resolvedMarketingVersion
        }
        try downloads.refreshFailed(job.id, asset: asset)
        if switchToDownloadsTab { selectTab(.downloads) }
    }

    func refreshOwned() async {
        await cacheLoadTask?.value
        guard accountRemoving == nil else { return }
        guard !ownedLoading, let id = apple.activeID else {
            if apple.activeID == nil { errorMessage = AppText.text("请先在账号页登录") }
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
            guard apple.activeID == id, accountRemoving == nil else { return }
            ownedError = nil
            let cached = Dictionary(owned.map { ($0.id, $0.iconURL) }, uniquingKeysWith: { first, _ in first })
            owned = apps.map { app in
                var item = app
                if item.iconURL == nil { item.iconURL = cached[item.id] ?? nil }
                return item
            }
            guard ownedStorageError == nil else { ownedError = ownedStorageError; return }
            var next = ownedByAccount; next[id] = owned
            try await saveCache(next, filename: LocalResources.ownedFilename)
            guard accountRemoving == nil else { return }
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
        guard let account = apple.activeID, ownedStorageError == nil, accountRemoving == nil else { return }
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
                guard apple.activeID == account, settings.store == context, ownedRevision == revision, accountRemoving == nil else { return }
                ownedArtworkAttempted.formUnion(batch)
                if !urls.isEmpty {
                    // Apply the batch in one update so the list re-renders once.
                    var updated = owned
                    for index in updated.indices { if let url = urls[updated[index].id] { updated[index].iconURL = url } }
                    owned = updated
                    ownedByAccount[account] = owned
                    try await saveCache(ownedByAccount, filename: LocalResources.ownedFilename)
                }
                // Keep the public lookup service below its documented request budget.
                if offset + 20 < ids.count { try await Task.sleep(nanoseconds: 3_100_000_000) }
            } catch { return } // Artwork is optional; purchase records remain usable offline.
        }
    }

    func deleteAccount(_ id: String) async throws {
        guard !cacheLoading else { throw ToolError.message(AppText.text("正在载入本地记录，请稍后重试")) }
        guard accountRemoving == nil else { throw ToolError.message(AppText.text("正在移除账号，请稍后重试")) }
        guard ownedStorageError == nil else { throw ToolError.message(ownedStorageError!) }
        accountRemoving = id
        defer { accountRemoving = nil }
        var next = ownedByAccount; next.removeValue(forKey: id)
        try await saveCache(next, filename: LocalResources.ownedFilename)
        do { try apple.remove(id) }
        catch {
            try await saveCache(ownedByAccount, filename: LocalResources.ownedFilename)
            throw error
        }
        ownedByAccount = next
    }

    func receiveExternalURL(_ url: URL) {
        if AppLock.shared.locked && AppLock.method != .unavailable {
            pendingExternalURL = url
            return
        }
        handleURL(url)
    }

    func flushPendingExternalURL() {
        guard !AppLock.shared.locked || AppLock.method == .unavailable,
              let url = pendingExternalURL else { return }
        pendingExternalURL = nil
        handleURL(url)
    }

    func confirmExternalDownload(_ prompt: ExternalDownloadPrompt) {
        externalDownloadPrompt = nil
        do {
            try downloads.enqueueURL(prompt.url)
            selectTab(.downloads)
            infoMessage = AppText.text("已开始下载")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleURL(_ url: URL) {
        if url.isFileURL {
            selectTab(.downloads)
            Task { do { try await downloads.importFile(url) } catch { errorMessage = error.localizedDescription } }
        } else if url.scheme == "ipadn" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []
            if url.host == "open", let value = items.first(where: { $0.name == "tab" })?.value {
                // Widget shortcuts: support semantic TabIDs and legacy 0..3 indices.
                let legacyOrder: [TabID] = [.search, .downloads, .purchased, .accounts]
                if let id = TabID(rawValue: value), tabOrder.contains(id) {
                    selectTab(id)
                } else if let target = Int(value), legacyOrder.indices.contains(target) {
                    selectTab(legacyOrder[target])
                }
                if items.contains(where: { $0.name == "check" && $0.value == "updates" }) {
                    Task { await checkForUpdates(force: true) }
                }
            } else if let id = items.first(where: { $0.name == "id" })?.value { selectTab(.search); search(id) }
            else if let address = items.first(where: { $0.name == "url" })?.value {
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let download = URL(string: trimmed),
                      download.scheme == "https",
                      let host = download.host, !host.isEmpty,
                      !DownloadManager.isLoopbackHost(host),
                      download.user == nil, download.password == nil else {
                    errorMessage = AppText.text("请输入有效的下载链接")
                    return
                }
                externalDownloadPrompt = ExternalDownloadPrompt(url: download)
            }
        } else if url.host == "apps.apple.com" { selectTab(.search); search(url.absoluteString) }
    }

    /// Writes settings, followed apps with their price records, kept
    /// versions, recent searches, full Apple account sessions (including cookies/tokens/passwords),
    /// device GUID, and StoreProof records to a file (optionally password-encrypted with AES-256-GCM).
    func exportBackup(password: String? = nil) throws -> URL {
        let flushedAccounts = apple.flushedAccountsForBackup()
        let sessions = AccountBackupService.sessions(from: flushedAccounts)
        let proofs = StoreProofStore.load().filter { !$0.value.identifier.isEmpty }
        let backup = AppBackup(
            settings: settings,
            favorites: favorites,
            watch: watch,
            keptVersions: keptVersions,
            searchHistory: searchHistory,
            accountSessions: sessions.isEmpty ? nil : sessions,
            preferredActiveAccountID: sessions.isEmpty ? nil : apple.activeID,
            deviceGUID: apple.guid,
            storeProofRecords: proofs.isEmpty ? nil : proofs
        )
        let plainData = try backup.encoded()
        let outputData: Data
        if let password, !password.isEmpty {
            outputData = try BackupCrypto.encrypt(plainData, password: password)
        } else {
            outputData = plainData
        }
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iPadn-Backup-\(day)-\(UUID().uuidString.prefix(8)).json")
        try outputData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    func previewBackup(data: Data) throws -> BackupInspectResult {
        guard data.count <= AccountProfileBackup.maxImportBytes else {
            throw AccountBackupError.fileTooLarge
        }
        if EncryptedBackupEnvelope.isEncryptedEnvelope(data) {
            return .needsPassword(data)
        }
        return .ready(try inspectPlainBackup(data: data, wasEncrypted: false))
    }

    func decryptAndPreviewBackup(data: Data, password: String) throws -> UnifiedBackupPreview {
        let decrypted = try BackupCrypto.decrypt(data, password: password)
        return try inspectPlainBackup(data: decrypted, wasEncrypted: true)
    }

    private func inspectPlainBackup(data: Data, wasEncrypted: Bool) throws -> UnifiedBackupPreview {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (object["schema"] as? String) == AccountProfileBackup.schemaIdentifier {
            let legacyAccounts = try AccountBackupService.preview(data: data, existing: apple.accounts)
            let entries = legacyAccounts.backup.accounts.map(AccountSessionEntry.init(from:))
            let split = AccountBackupService.partition(entries, existing: apple.accounts)
            return UnifiedBackupPreview(
                data: data,
                source: .legacyAccountsOnly,
                created: legacyAccounts.backup.created,
                favoritesCount: 0,
                accountEntries: entries,
                newAccountEntries: split.new,
                existingAccountEntries: split.existing,
                deviceGUID: nil,
                hasStoreProofs: false,
                wasEncrypted: wasEncrypted
            )
        }
        let backup = try AppBackup.decode(data)
        let entries = backup.effectiveAccountEntries
        let split = AccountBackupService.partition(entries, existing: apple.accounts)
        return UnifiedBackupPreview(
            data: data,
            source: .unified,
            created: backup.created,
            favoritesCount: backup.favorites.count,
            accountEntries: entries,
            newAccountEntries: split.new,
            existingAccountEntries: split.existing,
            deviceGUID: backup.deviceGUID,
            hasStoreProofs: !(backup.storeProofRecords?.isEmpty ?? true),
            wasEncrypted: wasEncrypted
        )
    }

    /// Replaces settings, merges followed apps/watches/kept versions/searches, and
    /// restores Apple accounts (with cookies/tokens/passwords when present), device GUID, and StoreProofs.
    func importBackup(
        _ data: Data,
        accountPolicy: AccountBackupConflictPolicy = .skipExisting,
        restoreDeviceIdentity: Bool = true
    ) async throws {
        await cacheLoadTask?.value
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (object["schema"] as? String) == AccountProfileBackup.schemaIdentifier {
            let legacy = try AccountProfileBackup.decode(data)
            let outcome = try apple.importAccountBackup(
                entries: legacy.accounts.map(AccountSessionEntry.init(from:)),
                preferredActiveID: legacy.preferredActiveID,
                policy: accountPolicy,
                restoreDeviceIdentity: false
            )
            infoMessage = Self.accountImportMessage(outcome, includedSettings: false)
            return
        }
        let backup = try AppBackup.decode(data)
        if let storageError = favoritesStorageError {
            throw ToolError.message(storageError)
        }
        let next = AppBackup.merged(backup.favorites, with: favorites)
        let previous = favoriteTask
        await previous?.value
        // Persist favorites on disk before mutating Keychain accounts so disk errors cannot leave half-imported state.
        try await saveCache(next, filename: "favorites.json")

        let entries = backup.effectiveAccountEntries
        let hasDeviceIdentity = restoreDeviceIdentity && (backup.deviceGUID != nil || !(backup.storeProofRecords?.isEmpty ?? true))
        var accountOutcome: AppleService.AccountBackupImportOutcome?
        isImportingBackup = true
        defer { isImportingBackup = false }
        if !entries.isEmpty || hasDeviceIdentity {
            accountOutcome = try apple.importAccountBackup(
                entries: entries,
                preferredActiveID: backup.preferredActiveAccountID,
                deviceGUID: backup.deviceGUID,
                storeProofRecords: backup.storeProofRecords,
                policy: accountPolicy,
                restoreDeviceIdentity: restoreDeviceIdentity
            )
        }
        favorites = next
        let followed = Set(next.map(\.id))
        watch = watch.merging(backup.watch) { _, imported in imported }.filter { followed.contains($0.value.id) }
        persistWatch()
        keptVersions = keptVersions.merging(backup.keptVersions) { _, imported in imported }
        LocalResources.defaults.set(keptVersions, forKey: "storage_keptVersions")
        var seenTerms = Set<String>()
        let mergedHistory = (backup.searchHistory + searchHistory).filter { entry in
            let trimmed = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && seenTerms.insert(trimmed).inserted
        }
        searchHistory = Array(mergedHistory.prefix(50))
        persistHistory()
        var restoredSettings = backup.settings
        if AppLock.method == .unavailable {
            restoredSettings.appLock = false
        }
        settings = restoredSettings
        updateLocalResults()
        if let accountOutcome {
            infoMessage = Self.accountImportMessage(accountOutcome, includedSettings: true)
        } else {
            infoMessage = AppText.text("已导入备份")
        }
        Task {
            await checkWatched(force: true)
            if apple.activeID != nil {
                await refreshOwned()
            }
        }
    }

    private static func accountImportMessage(
        _ outcome: AppleService.AccountBackupImportOutcome,
        includedSettings: Bool
    ) -> String {
        let added = outcome.merge.addedIDs.count
        let updated = outcome.merge.updatedIDs.count
        if includedSettings {
            if outcome.addedNeedsReauthCount > 0 {
                return AppText.text("已导入备份并新增 \(outcome.addedNeedsReauthCount) 个账号配置，请在「账号」页重新登录")
            }
            if added > 0 && updated > 0 {
                return AppText.text("已导入完整备份（新增 \(added) 个、更新 \(updated) 个账号会话）")
            }
            if added > 0 && outcome.restoredSessionCount > 0 {
                return AppText.text("已导入完整备份（恢复 \(added) 个账号会话与 Cookie）")
            }
            if updated > 0 {
                return AppText.text("已导入完整备份并更新 \(updated) 个账号")
            }
            if outcome.restoredDeviceIdentity {
                return AppText.text("已导入完整备份并恢复设备凭证")
            }
            return AppText.text("已导入备份")
        }
        if added > 0 && updated > 0 {
            return AppText.text("已新增 \(added) 个账号、更新 \(updated) 个账号资料，请在「账号」页重新登录")
        }
        if added > 0 {
            return AppText.text("已导入 \(added) 个账号配置，请在「账号」页重新登录")
        }
        if updated > 0 {
            return AppText.text("已更新 \(updated) 个已有账号的资料")
        }
        return AppText.text("所选文件中的账号均已存在，未作更改")
    }

    func exportDiagnostics() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iPadn-Diagnostics.txt")
        try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    /// Copies the diagnostics, for when the share sheet can't open
    /// (inside LiveContainer, for example).
    func copyDiagnostics() {
        UIPasteboard.general.string = diagnosticsText()
        infoMessage = AppText.text("已复制到剪贴板")
    }
    func diagnosticsText() -> String {
        [
            "iPadn " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""), "Platform: \(settings.store.platform.title)", "Region: \(settings.store.country)",
            "Jobs: \(downloads.jobs.count)", "Concurrent limit: \(settings.maxConcurrentDownloads)",
            "Version sources: \(settings.versionSources.filter(\.enabled).count)",
            "Task states: " + downloads.jobs.map { "\($0.id.uuidString.prefix(8)): \($0.status.rawValue)" }.joined(separator: ", "),
            "Installation: " + (settings.nativeInstallation ? "native" : settings.automaticInstallation ? "one-tap" : settings.localInstallation ? "local certificate" : "proxy"),
            "Native installer: " + (NativeInstaller.isAvailable ? "linked" : "not linked") + ", pairing file: " + (NativeInstaller.hasPairingFile ? "yes" : "no"),
            "Runs inside LiveContainer: " + (InstallLog.insideLiveContainer ? "yes" : "no"),
            "Proxy or VPN on: " + (LocalHostRecord.proxyOrVPNActive ? "yes" : "no"),
            "iOS " + UIDevice.current.systemVersion,
            "Last login (metadata only):", apple.loginDiagnostic,
            "Last update check (metadata only):", appUpdateDiagnostic,
            "Recent request failures (metadata only):", RequestFailureLog.text,
            "Installation server log:", InstallLog.shared.text.isEmpty ? "(empty)" : InstallLog.shared.text,
            "Contains no credentials, cookies, Apple account names or download URLs."
        ].joined(separator: "\n")
    }
}


#if DEBUG
extension ToolStore {
    func prepareAccountPreview() {
        apple.prepareAccountPreview()
        owned = PreviewData.apps.enumerated().map { index, app in
            OwnedApp(id: app.id, bundleID: app.bundleID, name: app.name, version: app.version,
                     purchaseDate: Date().addingTimeInterval(-Double(index + 1) * 9 * 86400), iconURL: app.iconURL)
        }
    }
    func prepareArchivePreview() {
        searchText = "Forward"; lastSearchTerm = searchText; hasSearched = true
        updateLocalResults()
    }
    func prepareVisualPreview() {
        visualPreview = true
        cacheLoading = false
        results = []; hasSearched = false; searchText = ""
        if ProcessInfo.processInfo.arguments.contains("--skeleton-preview") {
            searching = true
        }
        favorites = [PreviewData.favorite]
        if ProcessInfo.processInfo.arguments.contains("--updates") {
            for app in PreviewData.updatable {
                var latest = app; latest.version = "99.0"
                availableUpdates["\(AppPlatform.iOS.rawValue)|\(app.id)"] = latest
            }
        }
        let day: TimeInterval = 86400
        var record = WatchRecord(id: PreviewData.favorite.id, country: watchCountry, version: "3.2", price: 18, currency: "CNY",
                                 history: [PricePoint(date: Date().addingTimeInterval(-30 * day), price: 30),
                                           PricePoint(date: Date().addingTimeInterval(-3 * day), price: 18)],
                                 started: Date().addingTimeInterval(-30 * day), checked: Date())
        record.change = .priceDrop(from: 30, to: 18); record.changed = Date().addingTimeInterval(-3 * day)
        watch = [record.key: record]
        let historyTerms = ProcessInfo.processInfo.arguments.contains("--history-wrap-preview")
            ? ["效率工具", "照片编辑", "Apple Music", "@"]
            : (PreviewData.chinese ? ["效率工具", "照片编辑"] : ["Notion", "Spotify"])
        searchHistory = historyTerms.map { SearchHistoryItem(term: $0, count: 1, lastUsed: Date()) }
    }
}
#endif
