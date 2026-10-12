import Foundation

enum StoreService {
    private static func endpoint(_ base: String, items: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw ToolError.message("接口地址错误") }
        components.queryItems = items
        guard let url = components.url else { throw ToolError.message("无法构造接口地址") }
        return url
    }

    // Apple sends storefront identifiers such as "143441-1,29". The selected
    // search region can differ from the account's purchase region.
    static func country(forStorefront storefront: String) -> String? {
        let identifier = String(storefront.split(separator: "-").first ?? "")
        return [
            "143441": "US", "143465": "CN", "143463": "HK", "143470": "TW",
            "143462": "JP", "143444": "GB", "143464": "SG", "143455": "CA",
            "143460": "AU", "143466": "KR", "143443": "DE", "143442": "FR"
        ][identifier]
    }

    static func searchCountries(selected: String, accountCountry: String?) -> [String] {
        var countries = [selected.uppercased()]
        if let accountCountry = accountCountry?.uppercased(), !accountCountry.isEmpty,
           !countries.contains(accountCountry) { countries.append(accountCountry) }
        return countries
    }

    static func mergeResults(_ primary: [StoreApp], _ account: [StoreApp], limit: Int) -> [StoreApp] {
        var merged: [StoreApp] = []
        var indices: [String: Int] = [:]
        // Two selected-region results followed by one account-region result
        // keeps the secondary store visible even if the primary fills the limit.
        let regionalIDs = Set(primary.map(\.id))
        let accountOnly = account.filter { !regionalIDs.contains($0.id) }
        var candidates: [StoreApp] = []
        var primaryIndex = 0
        var accountIndex = 0
        while primaryIndex < primary.count || accountIndex < accountOnly.count {
            for _ in 0..<2 where primaryIndex < primary.count {
                candidates.append(primary[primaryIndex]); primaryIndex += 1
            }
            if accountIndex < accountOnly.count {
                candidates.append(accountOnly[accountIndex]); accountIndex += 1
            }
        }
        // Also inspect overlapping results to fill missing artwork.
        candidates.append(contentsOf: account)
        for app in candidates where !app.id.isEmpty {
            if let index = indices[app.id] {
                // An app found in both stores may have missing artwork in one.
                if merged[index].iconURL == nil { merged[index].iconURL = app.iconURL }
            } else {
                indices[app.id] = merged.count
                merged.append(app)
            }
        }
        return Array(merged.prefix(max(0, limit)))
    }

    static func search(_ query: SearchQuery, store: StoreContext, limit: Int,
                       accountCountry: String? = nil) async throws -> [StoreApp] {
        let primary = try await searchInCountry(query, store: store, limit: limit)
        let countries = searchCountries(selected: store.country, accountCountry: accountCountry)
        guard countries.count > 1 else { return primary }
        var accountStore = store
        accountStore.country = countries[1]
        do {
            let alternate = try await searchInCountry(query, store: accountStore, limit: limit)
            return mergeResults(primary, alternate, limit: limit)
        } catch {
            // A secondary regional lookup must not hide otherwise valid results.
            return primary
        }
    }

    private static func searchInCountry(_ query: SearchQuery, store: StoreContext, limit: Int) async throws -> [StoreApp] {
        switch query {
        case .keyword(let text):
            let url = try endpoint("https://itunes.apple.com/search", items: [
                URLQueryItem(name: "term", value: text), URLQueryItem(name: "country", value: store.country),
                URLQueryItem(name: "entity", value: store.platform.searchEntity),
                URLQueryItem(name: "explicit", value: "no"), URLQueryItem(name: "limit", value: String(limit))
            ])
            let data: [String: Any]?
            do { data = try await HTTPClient.shared.json(url) as? [String: Any] }
            catch {
                // Apple's public Search API does not reliably serve tvSoftware.
                // Keep local purchase/name-directory matches available instead.
                if store.platform == .tvOS { return [] }
                throw error
            }
            return (data?["results"] as? [[String: Any]] ?? []).map(mapLookup)
        case .appID(let id, _):
            if store.platform == .tvOS { return try await platformApp(id, store: store).map { [$0] } ?? [] }
            let url = try endpoint("https://itunes.apple.com/lookup", items: [
                URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: store.country),
                URLQueryItem(name: "entity", value: store.platform.searchEntity)
            ])
            let data = try await HTTPClient.shared.json(url) as? [String: Any]
            let apps = (data?["results"] as? [[String: Any]] ?? []).map(mapLookup)
            if !apps.isEmpty { return apps }
            return try await platformApp(id, store: store).map { [$0] } ?? []
        }
    }

    static func platformApp(_ id: String, store: StoreContext) async throws -> StoreApp? {
        let url = try endpoint("https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup", items: [
            URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "p", value: "mdm-lockup"), URLQueryItem(name: "caller", value: "MDM"),
            URLQueryItem(name: "platform", value: store.platform.catalogPlatform), URLQueryItem(name: "cc", value: store.country)
        ])
        let data = try await HTTPClient.shared.json(url) as? [String: Any]
        guard let results = data?["results"] as? [String: Any], let raw = results[id] as? [String: Any] else { return nil }
        let offer = (raw["offers"] as? [[String: Any]])?.first ?? [:]
        let version = offer["version"] as? [String: Any] ?? [:]
        let artwork = raw["artwork"] as? [String: Any] ?? [:]
        let rating = raw["userRating"] as? [String: Any] ?? [:]
        let description = raw["description"] as? [String: Any] ?? [:]
        let size = ((offer["assets"] as? [[String: Any]])?.first?["size"] as? NSNumber)?.int64Value ?? 0
        return StoreApp(id: id, name: plistString(raw["name"]), version: plistString(version["display"]),
                        iconURL: icon(plistString(artwork["url"])), description: plistString(description["standard"]),
                        category: (raw["genreNames"] as? [String] ?? []).joined(separator: " · "), size: size,
                        price: plistString(offer["priceFormatted"]), rating: (rating["value"] as? NSNumber)?.doubleValue ?? 0,
                        minimumOS: plistString(raw["minimumOSVersion"]),
                        externalVersionID: version["externalId"].map { plistString($0) },
                        developerURL: MacInstallerService.safeWebsite(plistString(raw["sellerUrl"] ?? raw["websiteUrl"])))
    }

    static func artworkCountries(selected: String, accountCountry: String?) -> [String] {
        var countries = searchCountries(selected: accountCountry ?? selected, accountCountry: selected)
        if !countries.contains("US") { countries.append("US") }
        return countries
    }

    static func artwork(_ ids: [String], store: StoreContext, accountCountry: String? = nil) async throws -> [String: URL] {
        var missing = Array(Set(ids.filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })).sorted()
        guard !missing.isEmpty else { return [:] }
        var icons: [String: URL] = [:]
        var firstError: Error?
        for country in artworkCountries(selected: store.country, accountCountry: accountCountry) {
            guard !missing.isEmpty else { break }
            do {
                let url = try endpoint("https://itunes.apple.com/lookup", items: [
                    URLQueryItem(name: "id", value: missing.joined(separator: ",")),
                    URLQueryItem(name: "country", value: country),
                    URLQueryItem(name: "entity", value: store.platform.searchEntity)
                ])
                let response = try await HTTPClient.shared.json(url) as? [String: Any]
                for raw in response?["results"] as? [[String: Any]] ?? [] {
                    let app = mapLookup(raw)
                    if let icon = app.iconURL { icons[app.id] = icon }
                }
                missing.removeAll { icons[$0] != nil }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if icons.isEmpty, let firstError { throw firstError }
        return icons
    }

    static func mapLookup(_ raw: [String: Any]) -> StoreApp {
        StoreApp(id: plistString(raw["trackId"]), name: plistString(raw["trackName"] ?? raw["trackCensoredName"]),
                 bundleID: plistString(raw["bundleId"]), version: plistString(raw["version"]),
                 iconURL: icon(plistString(raw["artworkUrl512"] ?? raw["artworkUrl100"])),
                 description: plistString(raw["description"]), category: plistString(raw["primaryGenreName"]),
                 size: Int64(plistString(raw["fileSizeBytes"])) ?? 0,
                 price: plistString(raw["formattedPrice"]).isEmpty ? "免费" : plistString(raw["formattedPrice"]),
                 rating: (raw["averageUserRating"] as? NSNumber)?.doubleValue ?? 0,
                 minimumOS: plistString(raw["minimumOsVersion"]),
                 developerURL: MacInstallerService.safeWebsite(plistString(raw["sellerUrl"])))
    }

    static func icon(_ value: String) -> URL? {
        guard let url = URL(string: value.replacingOccurrences(of: "{w}", with: "512")
            .replacingOccurrences(of: "{h}", with: "512").replacingOccurrences(of: "{f}", with: "png")
            .replacingOccurrences(of: "{c}", with: "bb")), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

// Only direct download links published on a developer website supplied by
// Apple's catalog are offered. Mac App Store does not publish DMG/PKG URLs.
enum MacInstallerService {
    struct Installer: Identifiable, Hashable {
        let url: URL
        var id: String { url.absoluteString }
        var format: String { url.pathExtension.lowercased() }
        var title: String { url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent }
    }

    static func safeWebsite(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !url.isFileURL, !host.lowercased().hasSuffix(".local"),
              host.lowercased() != "localhost",
              !host.hasPrefix("127."), !host.hasPrefix("10."),
              !host.hasPrefix("192.168."), !host.hasPrefix("169.254."),
              !host.hasPrefix("172.16."), !host.hasPrefix("172.17."),
              !host.hasPrefix("172.18."), !host.hasPrefix("172.19."),
              !host.hasPrefix("172.2"), !host.hasPrefix("172.30."), !host.hasPrefix("172.31."),
              !host.contains(":") else { return nil }
        return url
    }

    static func directPackage(_ url: URL) -> Bool {
        guard safeWebsite(url.absoluteString) != nil else { return false }
        return ["dmg", "pkg", "zip"].contains(url.pathExtension.lowercased())
    }

    static func links(in html: String, from website: URL) -> [Installer] {
        guard let regex = try? NSRegularExpression(pattern: #"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]) else { return [] }
        let text = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: text.length))
        var results: [Installer] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let ref = text.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#38;", with: "&")
            guard let url = URL(string: ref, relativeTo: website)?.absoluteURL,
                  directPackage(url), seen.insert(url.absoluteString).inserted else { continue }
            results.append(Installer(url: url))
            if results.count == 12 { break }
        }
        return results
    }

    static func find(on website: URL) async throws -> [Installer] {
        guard safeWebsite(website.absoluteString) != nil else { return [] }
        let (data, response) = try await HTTPClient.shared.request(website)
        guard data.count <= 2 * 1024 * 1024,
              response.mimeType?.lowercased().contains("html") == true,
              let html = String(data: data, encoding: .utf8) else { return [] }
        return links(in: html, from: website)
    }
}

actor VersionService {
    struct Cache: Codable { var savedAt: Date; var versions: [AppVersion] }
    private var cache = LocalResources.load([String: Cache].self, filename: LocalResources.versionsFilename) ?? [:]
    private var cacheRevision = UUID()

    func thirdParty(_ appID: String, sources: [VersionSource], force: Bool = false) async throws -> [AppVersion] {
        guard !appID.isEmpty, appID.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message("App ID 必须是数字") }
        let enabled = sources.filter(\.enabled)
        guard !enabled.isEmpty else { throw ToolError.message("请在设置中启用至少一个版本来源") }
        let sourceKey = enabled.map { "\($0.name)|\($0.urlTemplate)|\($0.containerKey)|\($0.reverse)" }.joined(separator: ";")
        let key = appID + "|" + sourceKey
        if !force, let entry = cache[key], Date().timeIntervalSince(entry.savedAt) < 24 * 3600 { return entry.versions }
        let revision = cacheRevision
        let result = await withTaskGroup(of: Result<[AppVersion], Error>.self, returning: Result<[AppVersion], Error>.self) { group in
            for source in enabled {
                group.addTask {
                    do { return .success(try await Self.fetch(appID, source: source)) }
                    catch { return .failure(error) }
                }
            }
            var failures: [String] = []
            for await item in group {
                switch item {
                case .success(let versions) where !versions.isEmpty: group.cancelAll(); return .success(versions)
                case .success: failures.append("版本来源返回空列表")
                case .failure(let error): failures.append(error.localizedDescription)
                }
            }
            return .failure(ToolError.message(failures.joined(separator: "\n")))
        }
        let versions = try result.get()
        try Task.checkCancellation()
        if revision == cacheRevision {
            cache = cache.filter { Date().timeIntervalSince($0.value.savedAt) < 24 * 3600 }
            if cache.count >= 200 {
                // Also shrink oversized caches created by earlier versions in one pass.
                cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.savedAt > $1.value.savedAt }
                    .prefix(199).map { ($0.key, $0.value) })
            }
            cache[key] = Cache(savedAt: Date(), versions: versions)
            // A disposable cache write failure must not hide a valid server result.
            try? LocalResources.save(cache, filename: LocalResources.versionsFilename)
        }
        return versions
    }

    private static func fetch(_ id: String, source: VersionSource) async throws -> [AppVersion] {
        guard source.urlTemplate.contains("{id}"),
              let url = URL(string: source.urlTemplate.replacingOccurrences(of: "{id}", with: id)), url.scheme == "https" else {
            throw ToolError.message("\(source.name)：需要带 {id} 的 HTTPS 接口地址")
        }
        let object = try await HTTPClient.shared.json(url)
        let value: Any? = source.containerKey.isEmpty ? object : (object as? [String: Any])?[source.containerKey]
        guard let records = value as? [[String: Any]] else { throw ToolError.message("\(source.name)：版本列表格式不兼容") }
        var seen = Set<String>()
        let ordered = source.reverse ? Array(records.reversed()) : records
        return ordered.compactMap { record in
            let id = plistString(record["external_identifier"])
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }), seen.insert(id).inserted else { return nil }
            let version = plistString(record["bundle_version"])
            return AppVersion(id: id, version: version.isEmpty ? "未知版本" : version, source: source.name)
        }
    }

    func clearCache() throws {
        try LocalResources.save([String: Cache](), filename: LocalResources.versionsFilename)
        cacheRevision = UUID(); cache.removeAll()
    }
}
