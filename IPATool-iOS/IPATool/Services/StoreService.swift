import Foundation

enum StoreService {
    private static func endpoint(_ base: String, items: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw ToolError.message("接口地址错误") }
        components.queryItems = items
        guard let url = components.url else { throw ToolError.message("无法构造接口地址") }
        return url
    }

    static func search(_ query: SearchQuery, store: StoreContext, limit: Int) async throws -> [StoreApp] {
        switch query {
        case .keyword(let text):
            let url = try endpoint("https://itunes.apple.com/search", items: [
                URLQueryItem(name: "term", value: text), URLQueryItem(name: "country", value: store.country),
                URLQueryItem(name: "entity", value: store.platform == .iOS ? "software" : "tvSoftware"),
                URLQueryItem(name: "explicit", value: "no"), URLQueryItem(name: "limit", value: String(limit))
            ])
            let data = try await HTTPClient.shared.json(url) as? [String: Any]
            return (data?["results"] as? [[String: Any]] ?? []).map(mapLookup)
        case .appID(let id, _):
            if store.platform == .tvOS { return try await platformApp(id, store: store).map { [$0] } ?? [] }
            let url = try endpoint("https://itunes.apple.com/lookup", items: [
                URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: store.country)
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
            URLQueryItem(name: "platform", value: store.platform.rawValue), URLQueryItem(name: "cc", value: store.country)
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
                        externalVersionID: version["externalId"].map { plistString($0) })
    }

    static func artwork(_ ids: [String], store: StoreContext) async throws -> [String: URL] {
        let valid = ids.filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        guard !valid.isEmpty else { return [:] }
        let url = try endpoint("https://itunes.apple.com/lookup", items: [
            URLQueryItem(name: "id", value: valid.joined(separator: ",")),
            URLQueryItem(name: "country", value: store.country),
            URLQueryItem(name: "entity", value: store.platform == .iOS ? "software" : "tvSoftware")
        ])
        let response = try await HTTPClient.shared.json(url) as? [String: Any]
        var icons: [String: URL] = [:]
        for raw in response?["results"] as? [[String: Any]] ?? [] {
            let app = mapLookup(raw)
            if let icon = app.iconURL { icons[app.id] = icon }
        }
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
                 minimumOS: plistString(raw["minimumOsVersion"]))
    }

    static func icon(_ value: String) -> URL? {
        guard let url = URL(string: value.replacingOccurrences(of: "{w}", with: "512")
            .replacingOccurrences(of: "{h}", with: "512").replacingOccurrences(of: "{f}", with: "png")
            .replacingOccurrences(of: "{c}", with: "bb")), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

actor VersionService {
    struct Cache: Codable { var savedAt: Date; var versions: [AppVersion] }
    private var cache = LocalResources.load([String: Cache].self, filename: LocalResources.versionsFilename) ?? [:]

    func thirdParty(_ appID: String, sources: [VersionSource], force: Bool = false) async throws -> [AppVersion] {
        guard !appID.isEmpty, appID.allSatisfy(\.isNumber) else { throw ToolError.message("App ID 必须是数字") }
        let enabled = sources.filter(\.enabled)
        guard !enabled.isEmpty else { throw ToolError.message("请在设置中启用至少一个版本来源") }
        let sourceKey = enabled.map { "\($0.urlTemplate)|\($0.containerKey)|\($0.reverse)" }.joined(separator: ";")
        let key = appID + "|" + sourceKey
        if !force, let entry = cache[key], Date().timeIntervalSince(entry.savedAt) < 24 * 3600 { return entry.versions }
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
        cache[key] = Cache(savedAt: Date(), versions: versions)
        try LocalResources.save(cache, filename: LocalResources.versionsFilename)
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
            guard !id.isEmpty, id.allSatisfy(\.isNumber), seen.insert(id).inserted else { return nil }
            let version = plistString(record["bundle_version"])
            return AppVersion(id: id, version: version.isEmpty ? "未知版本" : version, source: source.name)
        }
    }

    func clearCache() throws {
        cache.removeAll()
        try LocalResources.save(cache, filename: LocalResources.versionsFilename)
    }
}
