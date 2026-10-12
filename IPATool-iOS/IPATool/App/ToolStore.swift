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
    let downloads = DownloadManager()
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
    @Published private(set) var results: [StoreApp] = []
    @Published private(set) var searching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var searchHistory: [SearchHistoryItem] = []
    @Published private(set) var owned: [OwnedApp] = []
    @Published private(set) var ownedLoading = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()
    private var ownedByAccount = LocalResources.load([String: [OwnedApp]].self, filename: LocalResources.ownedFilename) ?? [:]
    private var subscriptions = Set<AnyCancellable>()

    init() {
        if let data = UserDefaults.standard.data(forKey: LocalResources.settings),
           let saved = try? JSONDecoder().decode(ToolSettings.self, from: data) { settings = saved }
        else { settings = ToolSettings() }
        if let data = UserDefaults.standard.data(forKey: LocalResources.searchHistory) {
            searchHistory = (try? JSONDecoder().decode([SearchHistoryItem].self, from: data)) ?? []
        }
        downloads.configure(settings)
        apple.$activeID.sink { [weak self] id in
            guard let self = self else { return }
            self.owned = id.flatMap { self.ownedByAccount[$0] } ?? []
        }.store(in: &subscriptions)
    }

    func search(_ text: String? = nil) {
        if let text = text { searchText = text }
        let input = searchText
        searchTask?.cancel()
        let id = UUID(); searchID = id
        let context = settings.store
        let limit = settings.searchLimit
        searching = true; hasSearched = true; results = []
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
                remember(input)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, searchID == id { errorMessage = error.localizedDescription }
            }
        }
    }
    func cancelSearch() { searchTask?.cancel(); searchID = UUID(); searching = false }

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
        ownedLoading = true
        defer { ownedLoading = false }
        do {
            let apps = try await apple.ownedApps(useCache: settings.useSignerCache)
            guard apple.activeID == id else { return }
            owned = apps; ownedByAccount[id] = apps
            try LocalResources.save(ownedByAccount, filename: LocalResources.ownedFilename)
        } catch { if apple.activeID == id { errorMessage = error.localizedDescription } }
    }
    func deleteAccount(_ id: String) throws {
        try apple.remove(id)
        ownedByAccount.removeValue(forKey: id)
        try LocalResources.save(ownedByAccount, filename: LocalResources.ownedFilename)
    }

    func handleURL(_ url: URL) {
        if url.isFileURL {
            tab = 1
            Task { do { try await downloads.importFile(url) } catch { errorMessage = error.localizedDescription } }
        } else if url.scheme == "ipatool" {
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
            "IPA Tool Native 1.0", "Platform: \(settings.store.platform.title)", "Region: \(settings.store.country)",
            "Jobs: \(downloads.jobs.count)", "Concurrent limit: \(settings.maxConcurrentDownloads)",
            "Version sources: \(settings.versionSources.filter(\.enabled).count)",
            "Task states: " + downloads.jobs.map { "\($0.id.uuidString.prefix(8)): \($0.status.rawValue)" }.joined(separator: ", "),
            "Contains no credentials, cookies, Apple account names or download URLs."
        ].joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IPATool-Diagnostics.txt")
        try details.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
