import Foundation

enum StoreService {
    private static func endpoint(_ base: String, items: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw ToolError.message(AppText.text("接口地址错误")) }
        components.queryItems = items
        guard let url = components.url else { throw ToolError.message(AppText.text("无法构造接口地址")) }
        return url
    }

    // Apple sends storefront identifiers such as "143441-1,29" or "143465,34".
    // The selected search region can differ from the account's purchase region.
    static func storefrontIdentifier(_ storefront: String) -> String {
        String(storefront.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func country(forStorefront storefront: String) -> String? {
        let identifier = storefrontIdentifier(storefront)
        return storefrontCountries[identifier]
    }

    // Storefront ID -> ISO country, from ipatool's storefront table (MIT).
    private static let storefrontCountries: [String: String] = [
        "143441": "US", "143442": "FR", "143443": "DE", "143444": "GB", "143445": "AT", "143446": "BE",
        "143447": "FI", "143448": "GR", "143449": "IE", "143450": "IT", "143451": "LU", "143452": "NL",
        "143453": "PT", "143454": "ES", "143455": "CA", "143456": "SE", "143457": "NO", "143458": "DK",
        "143459": "CH", "143460": "AU", "143461": "NZ", "143462": "JP", "143463": "HK", "143464": "SG",
        "143465": "CN", "143466": "KR", "143467": "IN", "143468": "MX", "143469": "RU", "143470": "TW",
        "143471": "VN", "143472": "ZA", "143473": "MY", "143474": "PH", "143475": "TH", "143476": "ID",
        "143477": "PK", "143478": "PL", "143479": "SA", "143480": "TR", "143481": "AE", "143482": "HU",
        "143483": "CL", "143484": "NP", "143485": "PA", "143486": "LK", "143487": "RO", "143488": "MV",
        "143489": "CZ", "143490": "BD", "143491": "IL", "143492": "UA", "143493": "KW", "143494": "HR",
        "143495": "CR", "143496": "SK", "143497": "LB", "143498": "QA", "143499": "SI", "143500": "RS",
        "143501": "CO", "143502": "VE", "143503": "BR", "143504": "GT", "143505": "AR", "143506": "SV",
        "143507": "PE", "143508": "DO", "143509": "EC", "143510": "HN", "143511": "JM", "143512": "NI",
        "143513": "PY", "143514": "UY", "143515": "MO", "143516": "EG", "143517": "KZ", "143518": "EE",
        "143519": "LV", "143520": "LT", "143521": "MT", "143522": "LI", "143523": "MD", "143524": "AM",
        "143525": "BW", "143526": "BG", "143527": "CI", "143528": "JO", "143529": "KE", "143530": "MK",
        "143531": "MG", "143532": "ML", "143533": "MU", "143534": "NE", "143535": "SN", "143536": "TN",
        "143537": "UG", "143538": "AI", "143539": "BS", "143540": "AG", "143541": "BB", "143542": "BM",
        "143543": "VG", "143544": "KY", "143545": "DM", "143546": "GD", "143547": "MS", "143548": "KN",
        "143549": "LC", "143550": "VC", "143551": "TT", "143552": "TC", "143553": "GY", "143554": "SR",
        "143555": "BZ", "143556": "BO", "143557": "CY", "143558": "IS", "143559": "BH", "143560": "BN",
        "143561": "NG", "143562": "OM", "143563": "DZ", "143564": "AO", "143565": "BY", "143566": "UZ",
        "143568": "AZ", "143571": "YE", "143572": "TZ", "143573": "GH", "143575": "AL", "143592": "MN",
        "143615": "GE", "143617": "IQ"
    ]

    static func searchCountries(selected: String, accountCountry: String?) -> [String] {
        var countries = [selected.uppercased()]
        if let accountCountry = accountCountry?.uppercased(), !accountCountry.isEmpty,
           !countries.contains(accountCountry) { countries.append(accountCountry) }
        return countries
    }

    static func deduplicatingResults(_ apps: [StoreApp], limit: Int? = nil) -> [StoreApp] {
        let unique = AppSearchRanking.deduplicatePreservingOrder(apps)
        guard let limit else { return unique }
        return Array(unique.prefix(max(0, limit)))
    }

    static func mergeResults(_ primary: [StoreApp], _ account: [StoreApp], limit: Int) -> [StoreApp] {
        let uniquePrimary = deduplicatingResults(primary)
        let uniqueAccount = deduplicatingResults(account)
        // Two selected-region results followed by one account-region result
        // keeps the secondary store visible even if the primary fills the limit.
        let regionalIDs = Set(uniquePrimary.map(\.id))
        let regionalBundles = Set(uniquePrimary.compactMap { app -> String? in
            let key = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return key.isEmpty ? nil : key
        })
        let accountOnly = uniqueAccount.filter { app in
            guard !regionalIDs.contains(app.id) else { return false }
            let bundleKey = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return bundleKey.isEmpty || !regionalBundles.contains(bundleKey)
        }
        var candidates: [StoreApp] = []
        var primaryIndex = 0
        var accountIndex = 0
        while primaryIndex < uniquePrimary.count || accountIndex < accountOnly.count {
            for _ in 0..<2 where primaryIndex < uniquePrimary.count {
                candidates.append(uniquePrimary[primaryIndex]); primaryIndex += 1
            }
            if accountIndex < accountOnly.count {
                candidates.append(accountOnly[accountIndex]); accountIndex += 1
            }
        }
        // Also inspect overlapping results to fill missing artwork.
        candidates.append(contentsOf: uniqueAccount)
        return deduplicatingResults(candidates, limit: limit)
    }

    /// Storefronts tried, in order, when an App ID is not listed in the
    /// selected or account region (apps are often region-limited).
    static let fallbackCountries = ["US", "CN", "HK", "TW", "JP", "GB", "SG", "CA", "AU", "KR", "DE", "FR"]

    static func search(_ query: SearchQuery, store: StoreContext, limit: Int,
                       accountCountry: String? = nil) async throws -> [StoreApp] {
        if case .appID = query {
            var tried = Set<String>()
            var firstError: Error?
            var answered = false
            for country in searchCountries(selected: store.country, accountCountry: accountCountry) + fallbackCountries
            where tried.insert(country).inserted {
                try Task.checkCancellation()
                var regional = store
                regional.country = country
                do {
                    let apps = try await searchInCountry(query, store: regional, limit: limit)
                    answered = true
                    if !apps.isEmpty { return apps }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if firstError == nil { firstError = error }
                    // Offline: every other region would fail the same way, slowly.
                    if (error as NSError).domain == NSURLErrorDomain { break }
                }
            }
            // "Not found anywhere" only when the stores actually answered;
            // otherwise report the error instead of calling the app delisted.
            if !answered, let firstError { throw firstError }
            return []
        }
        let primary = deduplicatingResults(try await searchInCountry(query, store: store, limit: limit), limit: limit)
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
            func searchEntities(_ entities: String) async throws -> [[String: Any]] {
                let url = try endpoint("https://itunes.apple.com/search", items: [
                    URLQueryItem(name: "term", value: text), URLQueryItem(name: "country", value: store.country),
                    URLQueryItem(name: "entity", value: entities),
                    URLQueryItem(name: "explicit", value: "no"), URLQueryItem(name: "limit", value: String(limit))
                ])
                let data = try await HTTPClient.shared.json(url) as? [String: Any]
                return data?["results"] as? [[String: Any]] ?? []
            }
            if store.platform == .macOS {
                // macSoftware is the native Mac App Store catalog. Exclude
                // unrelated mobile-only results before showing Mac installers.
                return deduplicatingResults(
                    try await searchEntities(store.platform.searchEntity)
                        .filter(Self.supportsNativeMac).map(mapMacLookup),
                    limit: limit
                )
            }
            guard store.platform == .tvOS else {
                return deduplicatingResults(
                    try await searchEntities(store.platform.searchEntity).map(mapLookup),
                    limit: limit
                )
            }
            // Apple TV has a distinct store offer. Search the combined catalogs,
            // then require explicit AppleTV device metadata rather than labeling
            // every iPhone match as an Apple TV result.
            var rows: [[String: Any]] = []
            do { rows = try await searchEntities("software,tvSoftware") }
            catch {
                // The tvSoftware entity is unreliable on some storefronts.
                rows = (try? await searchEntities("software")) ?? []
            }
            let candidates = deduplicatingResults(rows.filter(Self.supportsAppleTV).map(mapLookup), limit: limit)
            return deduplicatingResults(await withAppleTVListings(candidates, store: store), limit: limit)
        case .appID(let id, _):
            if store.platform == .tvOS { return try await platformApp(id, store: store).map { [$0] } ?? [] }
            // No "entity" here: on an ID lookup it requests *related* items
            // (and is rejected for some catalogs), which broke App ID search.
            let url = try endpoint("https://itunes.apple.com/lookup", items: [
                URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: store.country)
            ])
            let rows = (try await HTTPClient.shared.json(url) as? [String: Any])?["results"] as? [[String: Any]] ?? []
            let apps = Self.idLookupMatches(rows, id: id, platform: store.platform)
                .map(store.platform == .macOS ? mapMacLookup : mapLookup)
            if !apps.isEmpty { return apps }
            return try await platformApp(id, store: store).map { [$0] } ?? []
        }
    }

    /// The iTunes search API describes a shared (universal purchase) App ID
    /// with its iPhone artwork, size and version. Replace those with the
    /// Apple TV offer so tvOS results show what will actually be downloaded.
    static func withAppleTVListings(_ apps: [StoreApp], store: StoreContext) async -> [StoreApp] {
        let listings = await withTaskGroup(of: (String, StoreApp?).self) { group in
            for app in apps.prefix(20) {
                group.addTask { (app.id, try? await platformApp(app.id, store: store)) }
            }
            var found: [String: StoreApp] = [:]
            for await (id, listing) in group { if let listing { found[id] = listing } }
            return found
        }
        return apps.map { app in
            guard let tv = listings[app.id] else { return app }
            return mergingAppleTVListing(tv, into: app)
        }
    }

    static func mergingAppleTVListing(_ tv: StoreApp, into app: StoreApp) -> StoreApp {
        var merged = app
        if let icon = tv.iconURL { merged.iconURL = icon }
        if tv.size > 0 { merged.size = tv.size }
        if !tv.version.isEmpty { merged.version = tv.version }
        if !tv.minimumOS.isEmpty { merged.minimumOS = tv.minimumOS }
        if let id = tv.externalVersionID, !id.isEmpty { merged.externalVersionID = id }
        return merged
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
        let latestID = Self.platformExternalVersionID(version: version, buyParams: plistString(offer["buyParams"]))
        let artwork = raw["artwork"] as? [String: Any] ?? [:]
        let rating = raw["userRating"] as? [String: Any] ?? [:]
        let description = raw["description"] as? [String: Any] ?? [:]
        let size = ((offer["assets"] as? [[String: Any]])?.first?["size"] as? NSNumber)?.int64Value ?? 0
        return StoreApp(id: id, name: plistString(raw["name"]), version: plistString(version["display"]),
                        iconURL: icon(plistString(artwork["url"])), description: plistString(description["standard"]),
                        category: (raw["genreNames"] as? [String] ?? []).map(localizedGenre).joined(separator: " · "), size: size,
                        price: plistString(offer["priceFormatted"]), rating: (rating["value"] as? NSNumber)?.doubleValue ?? 0,
                        minimumOS: plistString(raw["minimumOSVersion"]),
                        externalVersionID: latestID,
                        developerURL: MacInstallerService.safeWebsite(plistString(raw["sellerUrl"] ?? raw["websiteUrl"])))
    }

    /// The current iPhone or iPad version ID (ipatool): the MDM catalogs
    /// first, then the App Store catalog API, which also lists Apple Arcade
    /// games that no MDM catalog carries.
    static func latestIOSVersionID(_ id: String, bundleID: String, country: String, platform: AppPlatform) async -> String? {
        guard UInt64(id).map({ $0 > 0 }) == true else { return nil }
        for catalog in ["enterprisestore", "iphone", "ipad"] {
            guard let url = try? endpoint("https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup", items: [
                URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "p", value: "mdm-lockup"), URLQueryItem(name: "caller", value: "MDM"),
                URLQueryItem(name: "platform", value: catalog), URLQueryItem(name: "cc", value: country.lowercased()),
                URLQueryItem(name: "l", value: "en")
            ]), let data = try? await HTTPClient.shared.json(url) as? [String: Any],
            let raw = (data["results"] as? [String: Any])?[id] as? [String: Any],
            let offer = (raw["offers"] as? [[String: Any]])?.first else { continue }
            if let version = platformExternalVersionID(version: offer["version"] as? [String: Any] ?? [:],
                                                       buyParams: plistString(offer["buyParams"])) { return version }
        }
        let family = platform == .iPadOS ? "ipad" : "iphone"
        guard let url = URL(string: "https://apps.apple.com/api/apps/v1/catalog/\(country.lowercased())/apps/\(id)?platform=\(family)"),
              let data = try? await HTTPClient.shared.json(url) as? [String: Any] else { return nil }
        return catalogVersionID(data, id: id, bundleID: bundleID, family: family)
    }

    static func catalogVersionID(_ data: [String: Any], id: String, bundleID: String, family: String) -> String? {
        guard let items = data["data"] as? [[String: Any]], items.count == 1, let item = items.first,
              plistString(item["id"]) == id, plistString(item["type"]) == "apps",
              let attributes = item["attributes"] as? [String: Any],
              (attributes["deviceFamilies"] as? [String] ?? []).contains(family),
              let ios = (attributes["platformAttributes"] as? [String: Any])?["ios"] as? [String: Any],
              bundleID.isEmpty || plistString(ios["bundleId"]) == bundleID else { return nil }
        let version = plistString(ios["externalVersionId"])
        return UInt64(version).map { $0 > 0 } == true ? version : nil
    }

    static func platformExternalVersionID(version: [String: Any], buyParams: String) -> String? {
        let provided = plistString(version["externalId"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = UInt64(provided), number > 0 { return provided }
        guard let items = URLComponents(string: "https://example.invalid/?" + buyParams)?
            .queryItems, let value = items.first(where: { $0.name == "appExtVrsId" })?.value,
            let number = UInt64(value), number > 0 else { return nil }
        return value
    }

    static func idLookupMatches(_ rows: [[String: Any]], id: String, platform: AppPlatform) -> [[String: Any]] {
        rows.filter { plistString($0["trackId"]) == id }
            .filter { platform != .macOS || supportsNativeMac($0) }
    }

    static func supportsNativeMac(_ raw: [String: Any]) -> Bool {
        if plistString(raw["kind"]).lowercased() == "mac-software" { return true }
        let platforms = raw["platforms"] as? [String] ?? []
        if platforms.contains(where: { ["macos", "mac"].contains($0.lowercased()) }) { return true }
        let devices = raw["supportedDevices"] as? [String] ?? []
        return devices.contains(where: { $0.lowercased().hasPrefix("mac") })
    }

    static func supportsAppleTV(_ raw: [String: Any]) -> Bool {
        let devices = raw["supportedDevices"] as? [String] ?? []
        if devices.contains(where: { $0.lowercased().hasPrefix("appletv") }) { return true }
        let platforms = raw["platforms"] as? [String] ?? []
        return platforms.contains(where: { ["appletv", "tvos"].contains($0.lowercased()) }) ||
            plistString(raw["kind"]).lowercased() == "tv-software"
    }

    static func artworkCountries(selected: String, accountCountry: String?) -> [String] {
        var countries = searchCountries(selected: accountCountry ?? selected, accountCountry: selected)
        // Artwork is public: look in other storefronts when the app is not
        // listed in the account's or selected region.
        for country in fallbackCountries where !countries.contains(country) { countries.append(country) }
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
                    URLQueryItem(name: "country", value: country)
                ])
                let response = try await HTTPClient.shared.json(url) as? [String: Any]
                for raw in response?["results"] as? [[String: Any]] ?? [] {
                    let app = mapLookup(raw)
                    if missing.contains(app.id), let icon = app.iconURL { icons[app.id] = icon }
                }
                missing.removeAll { icons[$0] != nil }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        guard !icons.isEmpty || firstError == nil else {
            if let firstError { throw firstError }
            return [:]
        }
        if icons.isEmpty, let firstError { throw firstError }
        return icons
    }

    /// Current listings for many App IDs at once: the lookup API takes a list.
    /// `nativeMac` names the IDs whose listing is a Mac app.
    static func lookup(
        ids: [String],
        country: String,
        timeoutInterval: TimeInterval? = nil,
        retryTransient: Bool? = nil
    ) async throws -> (apps: [String: StoreApp], nativeMac: Set<String>) {
        let ids = ids.filter { UInt64($0).map { $0 > 0 } == true }
        let chunks = stride(from: 0, to: ids.count, by: 100).map { Array(ids[$0..<min($0 + 100, ids.count)]) }
        var found: [String: StoreApp] = [:]
        var nativeMac = Set<String>()
        // Large purchase lists: a few chunks at a time instead of one after another.
        try await withThrowingTaskGroup(of: [(app: StoreApp, mac: Bool)].self) { group in
            var pending = chunks.makeIterator()
            for _ in 0..<4 {
                if let chunk = pending.next() {
                    group.addTask { try await lookupChunk(chunk, country: country, timeoutInterval: timeoutInterval, retryTransient: retryTransient) }
                }
            }
            while let rows = try await group.next() {
                for row in rows {
                    found[row.app.id] = row.app
                    if row.mac { nativeMac.insert(row.app.id) }
                }
                if let chunk = pending.next() {
                    group.addTask { try await lookupChunk(chunk, country: country, timeoutInterval: timeoutInterval, retryTransient: retryTransient) }
                }
            }
        }
        return (found, nativeMac)
    }

    enum DelistedVerification: Equatable, Sendable {
        case listed
        case delisted
        case inconclusive
    }

    /// Verifies across storefronts whether candidate IDs are genuinely delisted.
    /// Returns `.listed` as soon as any checked storefront lists the ID (preventing
    /// region-limited apps from being misclassified), `.delisted` only when every
    /// checked storefront answers cleanly without errors and omits the ID, and
    /// `.inconclusive` on cancellation or unrecovered request failure.
    static func verifyDelistedStatuses(
        ids: [String],
        store: StoreContext,
        accountCountry: String?,
        fetcher: (@Sendable ([String], String) async throws -> [String: StoreApp])? = nil
    ) async -> [String: DelistedVerification] {
        let validIDs = Array(Set(ids.filter { UInt64($0).map { $0 > 0 } == true })).sorted()
        guard !validIDs.isEmpty else { return [:] }
        var seenCountry = Set<String>()
        let countries = (searchCountries(selected: store.country, accountCountry: accountCountry) + fallbackCountries)
            .filter { seenCountry.insert($0).inserted }
        var remaining = Set(validIDs)
        var statuses: [String: DelistedVerification] = [:]
        var hadFailure = false
        let runLookup: @Sendable ([String], String) async throws -> [String: StoreApp] = fetcher ?? { batch, country in
            if batch.count <= 100 {
                var apps: [String: StoreApp] = [:]
                for row in try await lookupChunk(batch, country: country, timeoutInterval: 4, retryTransient: false) {
                    apps[row.app.id] = row.app
                }
                return apps
            }
            return try await lookup(ids: batch, country: country, timeoutInterval: 4, retryTransient: false).apps
        }

        // Probe storefronts sequentially without nested task-group cancellation so
        // unresolved local IDs never spawn competing futures on cooperative threads.
        var failedOnFirstPass: [String] = []
        for country in countries {
            guard !remaining.isEmpty, !Task.isCancelled else { break }
            do {
                let found = try await runLookup(Array(remaining), country)
                for id in found.keys where remaining.remove(id) != nil {
                    statuses[id] = .listed
                }
            } catch {
                if Task.isCancelled { break }
                failedOnFirstPass.append(country)
            }
        }
        if !remaining.isEmpty, !failedOnFirstPass.isEmpty, !Task.isCancelled {
            for country in failedOnFirstPass {
                guard !remaining.isEmpty, !Task.isCancelled else { break }
                do {
                    let found = try await runLookup(Array(remaining), country)
                    for id in found.keys where remaining.remove(id) != nil {
                        statuses[id] = .listed
                    }
                } catch {
                    if !Task.isCancelled { hadFailure = true }
                }
            }
        }
        if !remaining.isEmpty, fetcher == nil, store.platform == .tvOS, !Task.isCancelled {
            // Pure Apple TV listings are omitted by default iTunes lookup unless entity=tvSoftware is queried.
            if let tvURL = try? endpoint("https://itunes.apple.com/lookup", items: [
                URLQueryItem(name: "id", value: Array(remaining).joined(separator: ",")),
                URLQueryItem(name: "country", value: store.country),
                URLQueryItem(name: "entity", value: "tvSoftware")
            ]), let tvRows = (try? await HTTPClient.shared.json(tvURL, timeoutInterval: 4, retryTransient: false) as? [String: Any])?["results"] as? [[String: Any]] {
                for row in tvRows {
                    let id = plistString(row["trackId"])
                    if remaining.remove(id) != nil {
                        statuses[id] = .listed
                    }
                }
            }
        }
        for id in remaining {
            statuses[id] = (!hadFailure && !Task.isCancelled) ? .delisted : .inconclusive
        }
        return statuses
    }

    private static func lookupChunk(
        _ chunk: [String],
        country: String,
        timeoutInterval: TimeInterval? = nil,
        retryTransient: Bool? = nil
    ) async throws -> [(app: StoreApp, mac: Bool)] {
        let url = try endpoint("https://itunes.apple.com/lookup", items: [
            URLQueryItem(name: "id", value: chunk.joined(separator: ",")), URLQueryItem(name: "country", value: country)
        ])
        let rows = (try await HTTPClient.shared.json(url, timeoutInterval: timeoutInterval, retryTransient: retryTransient) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            let app = mapLookup(row)
            guard chunk.contains(app.id) else { return nil }
            return (app, plistString(row["kind"]).lowercased() == "mac-software")
        }
    }

    struct Screenshot: Hashable, Identifiable {
        var url: URL
        /// Width over height, from the size in the file name.
        var aspect: Double
        var id: URL { url }
    }

    /// Store page extras the detail page shows: screenshots for the chosen
    /// platform and the developer behind the app.
    struct ListingExtras {
        var screenshots: [Screenshot] = []
        var developerID: String?
        var developer = ""
    }

    static func listingExtras(id: String, country: String, platform: AppPlatform) async throws -> ListingExtras? {
        guard UInt64(id).map({ $0 > 0 }) == true else { return nil }
        let url = try endpoint("https://itunes.apple.com/lookup", items: [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: country)
        ])
        let rows = (try await HTTPClient.shared.json(url) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        guard let row = rows.first(where: { plistString($0["trackId"]) == id }) else { return nil }
        return listingExtras(row, platform: platform)
    }

    static func listingExtras(_ row: [String: Any], platform: AppPlatform) -> ListingExtras {
        func shots(_ key: String) -> [String] { row[key] as? [String] ?? [] }
        // Only the chosen device's own screenshots: never stand in another
        // device's. A Mac listing's screenshots are Mac screenshots only when
        // the row is the Mac app itself, not a shared iPhone App ID.
        let preferred: [String]
        switch platform {
        case .iOS: preferred = shots("screenshotUrls")
        case .iPadOS: preferred = shots("ipadScreenshotUrls")
        case .tvOS: preferred = shots("appletvScreenshotUrls")
        case .macOS: preferred = plistString(row["kind"]).lowercased() == "mac-software" ? shots("screenshotUrls") : []
        }
        let developerID = plistString(row["artistId"])
        var seenShotURLs = Set<URL>()
        let uniqueShots = preferred.compactMap(screenshot).filter { seenShotURLs.insert($0.url).inserted }
        return ListingExtras(screenshots: Array(uniqueShots.prefix(10)),
                             developerID: developerID.isEmpty ? nil : developerID,
                             developer: plistString(row["artistName"] ?? row["sellerName"]))
    }

    /// Other apps from the same developer for the chosen platform.
    static func developerApps(_ developerID: String, excluding id: String, country: String,
                              platform: AppPlatform) async throws -> [StoreApp] {
        guard UInt64(developerID).map({ $0 > 0 }) == true else { return [] }
        let entity = platform == .macOS ? "macSoftware" : platform == .iPadOS ? "iPadSoftware" : "software"
        let url = try endpoint("https://itunes.apple.com/lookup", items: [
            URLQueryItem(name: "id", value: developerID), URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "country", value: country), URLQueryItem(name: "limit", value: "30")
        ])
        let rows = (try await HTTPClient.shared.json(url) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return developerApps(rows, excluding: id, platform: platform)
    }

    static func developerApps(_ rows: [[String: Any]], excluding id: String, platform: AppPlatform) -> [StoreApp] {
        // The first row describes the developer, not an app.
        var seen = Set([id])
        return rows.filter { plistString($0["wrapperType"]) == "software" }
            .filter { platform != .tvOS || supportsAppleTV($0) }
            .filter { platform != .macOS || supportsNativeMac($0) }
            .map(mapLookup)
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .prefix(20).map { $0 }
    }

    /// Lookup screenshots link a small rendition such as `392x696bb.jpg`:
    /// a box the image is fitted into, whatever its orientation. Ask for a
    /// square box twice as large so portrait and landscape shots both come
    /// back sharp; the real orientation is read from the loaded image.
    static func screenshot(_ value: String) -> Screenshot? {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        let name = url.lastPathComponent
        let parts = name.split(separator: ".", maxSplits: 1)
        let size = parts.first.map { $0.split(separator: "x") } ?? []
        guard size.count == 2, let width = Int(size[0]),
              let height = Int(size[1].prefix { $0.isNumber }), width > 0, height > 0 else {
            return Screenshot(url: url, aspect: 9.0 / 19.5)
        }
        let suffix = size[1].drop { $0.isNumber }
        let side = min(2000, max(width, height) * 2)
        let larger = "\(side)x\(side)\(suffix)" + (parts.count > 1 ? "." + parts[1] : "")
        return Screenshot(url: url.deletingLastPathComponent().appendingPathComponent(larger),
                          aspect: Double(width) / Double(height))
    }

    /// A Mac listing. For an app sold for iPhone and Mac together the lookup
    /// reports the iPhone version and size ("kind" software); only a Mac-only
    /// app ("mac-software") carries its Mac version. The Mac version then
    /// comes from Apple's download offer instead of showing the iPhone one.
    static func mapMacLookup(_ raw: [String: Any]) -> StoreApp {
        var app = mapLookup(raw)
        if plistString(raw["kind"]) != "mac-software" { app.version = ""; app.size = 0 }
        return app
    }

    static func mapLookup(_ raw: [String: Any]) -> StoreApp {
        StoreApp(id: plistString(raw["trackId"]), name: plistString(raw["trackName"] ?? raw["trackCensoredName"]),
                 bundleID: plistString(raw["bundleId"]), version: plistString(raw["version"]),
                 iconURL: icon(plistString(raw["artworkUrl512"] ?? raw["artworkUrl100"])),
                 description: plistString(raw["description"]), category: localizedGenre(plistString(raw["primaryGenreName"])),
                 size: Int64(plistString(raw["fileSizeBytes"])) ?? 0,
                 price: plistString(raw["formattedPrice"]),
                 priceValue: (raw["price"] as? NSNumber)?.doubleValue,
                 currency: plistString(raw["currency"]).isEmpty ? nil : plistString(raw["currency"]),
                 rating: (raw["averageUserRating"] as? NSNumber)?.doubleValue ?? 0,
                 minimumOS: plistString(raw["minimumOsVersion"]),
                 developerURL: MacInstallerService.safeWebsite(plistString(raw["sellerUrl"])))
    }

    /// The lookup APIs return English genre names in every storefront.
    static func localizedGenre(_ name: String) -> String {
        let names = [
            "Books": "图书", "Business": "商务", "Developer Tools": "开发者工具", "Education": "教育",
            "Entertainment": "娱乐", "Finance": "财务", "Food & Drink": "美食佳饮", "Games": "游戏",
            "Graphics & Design": "图形和设计", "Health & Fitness": "健康健美", "Lifestyle": "生活",
            "Kids": "儿童", "Magazines & Newspapers": "报刊杂志", "Medical": "医疗", "Music": "音乐",
            "Navigation": "导航", "News": "新闻", "Photo & Video": "摄影与录像", "Productivity": "效率",
            "Reference": "参考资料", "Shopping": "购物", "Social Networking": "社交", "Sports": "体育",
            "Travel": "旅游", "Utilities": "工具", "Weather": "天气", "Stickers": "贴纸",
            "Video": "视频", "Graphics and Design": "图形和设计"
        ]
        // Apple's name is already right for English. Otherwise the Chinese name
        // is the catalog key, translated into the interface language there.
        guard AppText.locale.language.languageCode?.identifier != "en", let key = names[name] else { return name }
        return AppText.text(String.LocalizationValue(key))
    }

    static func icon(_ value: String) -> URL? {
        guard let url = URL(string: value.replacingOccurrences(of: "{w}", with: "512")
            .replacingOccurrences(of: "{h}", with: "512").replacingOccurrences(of: "{f}", with: "png")
            .replacingOccurrences(of: "{c}", with: "bb")), url.scheme == "https", url.host != nil else { return nil }
        return sharpArtwork(url)
    }

    /// Apple's CDN serves any size from the same path; some responses (the
    /// download dispatch, older lookups) link a 100 px rendition. Ask for 512 px.
    static func sharpArtwork(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host.hasSuffix(".mzstatic.com"),
              url.path.contains("/image/thumb/") else { return url }
        let last = url.lastPathComponent
        guard last.range(of: #"^\d+x\d+[a-z]*(-\d+)?\.(jpg|jpeg|png|webp)$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let size = Int(last.prefix { $0.isNumber }), size < 512 else { return url }
        return url.deletingLastPathComponent().appendingPathComponent("512x512bb.png")
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

// Preflight for native Mac App Store packages. Apple's iOS MDM catalog may
// return the iOS offer for a universal app even if the requested platform is
// macOS. This parser only resolves a Mac *offer*, not a downloadable .pkg.
// Store packages require a separate, device-compatible processing pipeline.
enum MacStoreOfferService {
    static func versionID(fromHTML html: String, appID: String, bundleID: String) -> String? {
        let markers = ["id=\"serialized-server-data\"", "id='serialized-server-data'"]
        guard let marker = markers.compactMap({ html.range(of: $0) }).first,
              html[..<marker.lowerBound].range(of: "<script", options: .backwards) != nil,
              let start = html[marker.upperBound...].firstIndex(of: ">"),
              let closing = html[html.index(after: start)...].range(of: "</script>") else { return nil }
        let json = Data(html[html.index(after: start)..<closing.lowerBound].utf8)
        guard json.count < 3 * 1024 * 1024,
              let data = try? JSONSerialization.jsonObject(with: json) else { return nil }

        var ids = Set<String>()
        var visited = 0
        func visit(_ value: Any, depth: Int) {
            visited += 1
            guard depth < 40, visited < 50_000 else { return }
            if let object = value as? [String: Any] {
                if let offer = object["purchaseConfiguration"] as? [String: Any] {
                    let platforms = offer["appPlatforms"] as? [String] ?? []
                    let bundle = plistString(offer["bundleId"])
                    let params = plistString(offer["buyParams"])
                    let query = URLComponents(string: "https://example.invalid/?" + params)?.queryItems ?? []
                    let values = Dictionary(query.map { ($0.name, $0.value ?? "") },
                                            uniquingKeysWith: { first, _ in first })
                    let version = values["appExtVrsId"] ?? ""
                    if platforms.contains("mac"), values["salableAdamId"] == appID,
                       bundleID.isEmpty || bundle == bundleID,
                       let number = UInt64(version), number > 0 {
                        ids.insert(version)
                    }
                }
                for child in object.values { visit(child, depth: depth + 1) }
            } else if let items = value as? [Any] {
                for item in items { visit(item, depth: depth + 1) }
            }
        }
        visit(data, depth: 0)
        return ids.count == 1 ? ids.first : nil
    }

    static func latestVersionID(appID: String, bundleID: String, country: String) async throws -> String? {
        guard let appNumber = UInt64(appID), appNumber > 0,
              country.count == 2, country.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let url = URL(string: "https://apps.apple.com/\(country.lowercased())/app/id\(appNumber)?platform=mac")!
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await HTTPClient.shared.request(url) }
        // A delisted app has no product page; the caller then lets Apple
        // pick the latest Mac version the account is entitled to.
        catch let error as HTTPStatusError where error.code == 404 { return nil }
        guard data.count <= 3 * 1024 * 1024,
              response.mimeType?.lowercased().contains("html") == true,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return versionID(fromHTML: html, appID: appID, bundleID: bundleID)
    }
}

actor VersionService {
    struct Cache: Codable {
        var savedAt: Date
        var versions: [AppVersion]
        var complete: Bool? = nil
    }
    private var cache = LocalResources.load([String: Cache].self, filename: LocalResources.versionsFilename) ?? [:]
    private var cacheRevision = UUID()

    private static func cacheKey(appID: String, enabledSources: [VersionSource]) -> String {
        let sourceKey = enabledSources.map { "\($0.name)|\($0.urlTemplate)|\($0.containerKey)|\($0.reverse)" }.joined(separator: ";")
        return "v3|" + appID + "|" + sourceKey
    }

    func cachedVersionMap(appID: String, sources: [VersionSource]) -> [String: String] {
        let key = Self.cacheKey(appID: appID, enabledSources: sources.filter(\.enabled))
        guard let versions = cache[key]?.versions else { return [:] }
        var map: [String: String] = [:]
        for item in versions {
            map[item.id] = Self.preferredVersion(item.version, over: map[item.id] ?? AppVersion.unknown, rejectingID: item.id)
        }
        return map
    }

    func thirdParty(_ appID: String, sources: [VersionSource], force: Bool = false) async throws -> [AppVersion] {
        guard !appID.isEmpty, appID.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message(AppText.text("App ID 必须是数字")) }
        let enabled = sources.filter(\.enabled)
        guard !enabled.isEmpty else { throw ToolError.message(AppText.text("请在设置中启用至少一个版本来源")) }
        let key = Self.cacheKey(appID: appID, enabledSources: enabled)
        if !force, let entry = cache[key] {
            let ttl: TimeInterval = entry.complete == false ? 10 * 60 : 24 * 3600
            if Date().timeIntervalSince(entry.savedAt) < ttl { return entry.versions }
        }
        let revision = cacheRevision
        // Complete every enabled query. Taking the first provider to respond
        // makes the version list depend on network timing and hides unique IDs.
        let (sourceResults, allSucceeded) = await withTaskGroup(
            of: (Int, Result<[AppVersion], Error>).self,
            returning: ([[AppVersion]], Bool).self
        ) { group in
            for (index, source) in enabled.enumerated() {
                group.addTask {
                    do { return (index, .success(try await Self.fetch(appID, source: source))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var lists = Array(repeating: [AppVersion](), count: enabled.count)
            var complete = true
            for await (index, result) in group {
                switch result {
                case .success(let versions): lists[index] = versions
                case .failure: complete = false
                }
            }
            return (lists, complete)
        }
        try Task.checkCancellation()
        let versions = Self.mergeSourceResults(sourceResults)
        guard !versions.isEmpty else {
            // The previous successful records remain useful if both third-party
            // services are temporarily unavailable. Label them as cached.
            if let old = cache[key], Date().timeIntervalSince(old.savedAt) < 7 * 86400 {
                return old.versions.map {
                    var item = $0
                    item.source += AppText.text("（缓存）")
                    return item
                }
            }
            throw VersionListUnavailableError()
        }
        if revision == cacheRevision {
            cache = cache.filter { $0.key.hasPrefix("v3|") && Date().timeIntervalSince($0.value.savedAt) < 7 * 86400 }
            if cache.count >= 200 {
                // Also shrink oversized caches created by earlier versions in one pass.
                cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.savedAt > $1.value.savedAt }
                    .prefix(199).map { ($0.key, $0.value) })
            }
            cache[key] = Cache(savedAt: Date(), versions: versions, complete: allSucceeded)
            // A disposable cache write failure must not hide a valid server result.
            try? LocalResources.save(cache, filename: LocalResources.versionsFilename)
        }
        return versions
    }

    /// Upgrades cached third-party version strings in place when a trustworthy
    /// storefront or Apple source resolves a higher-preference version number.
    func reconcile(appID: String, versionID: String, version: String, replaceDotless: Bool = false) {
        let normalized = Self.sanitizedVersion(version, rejectingID: versionID)
        let incomingScore = Self.versionPreference(normalized, rejectingID: versionID)
        var changed = false
        for (key, var entry) in cache where key.hasPrefix("v3|\(appID)|") {
            var updated = false
            for index in entry.versions.indices where entry.versions[index].id == versionID {
                let current = entry.versions[index].version
                let currentScore = Self.versionPreference(current, rejectingID: versionID)
                let better: String
                if replaceDotless && currentScore <= 1 && (incomingScore >= currentScore || normalized == AppVersion.unknown) {
                    better = normalized
                } else if normalized != AppVersion.unknown {
                    better = Self.preferredVersion(normalized, over: current, rejectingID: versionID)
                } else {
                    continue
                }
                if better != current {
                    entry.versions[index].version = better
                    updated = true
                }
            }
            if updated {
                cache[key] = entry
                changed = true
            }
        }
        if changed {
            try? LocalResources.save(cache, filename: LocalResources.versionsFilename)
        }
    }

    static func sanitizedVersion(_ raw: String, rejectingID: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != AppVersion.unknown else { return AppVersion.unknown }
        if let rejectingID, !rejectingID.isEmpty, trimmed == rejectingID { return AppVersion.unknown }
        // Ignore scraper text fragments accidentally placed in bundle_version
        // (e.g. "aktualisiert"). Do not synthesize dots for pure integers like "4800".
        guard !trimmed.contains(where: \.isWhitespace),
              trimmed.contains(where: { $0.isASCII && $0.isNumber }) else {
            return AppVersion.unknown
        }
        return trimmed
    }

    static func versionPreference(_ raw: String, rejectingID: String? = nil) -> Int {
        let value = sanitizedVersion(raw, rejectingID: rejectingID)
        guard value != AppVersion.unknown else { return 0 }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let numericSegments = parts.filter { $0.contains(where: { $0.isASCII && $0.isNumber }) }.count
        return parts.count >= 2 && numericSegments >= 2 ? 2 : 1
    }

    static func preferredVersion(_ candidate: String, over current: String, rejectingID: String? = nil) -> String {
        let next = sanitizedVersion(candidate, rejectingID: rejectingID)
        let existing = sanitizedVersion(current, rejectingID: rejectingID)
        let nextScore = versionPreference(next, rejectingID: rejectingID)
        let currentScore = versionPreference(existing, rejectingID: rejectingID)
        if nextScore > currentScore { return next }
        return existing != AppVersion.unknown ? existing : next
    }

    static func bestVersion(_ candidates: [String], rejectingID: String? = nil) -> String {
        candidates.reduce(AppVersion.unknown) { current, candidate in
            preferredVersion(candidate, over: current, rejectingID: rejectingID)
        }
    }

    static func reconcileTicketVersion(shortVersion: String, buildVersion: String) -> String {
        let cleanShort = sanitizedVersion(shortVersion)
        let cleanBuild = sanitizedVersion(buildVersion)
        let short = cleanShort == AppVersion.unknown ? "" : cleanShort
        let build = cleanBuild == AppVersion.unknown ? "" : cleanBuild
        if versionPreference(short) >= 2 { return short }
        if versionPreference(build) >= 2 { return build }
        return !short.isEmpty ? short : build
    }

    /// Precision rank for matching a compact build string (e.g. `"4600"`, `"2109"`)
    /// to an official App Store marketing version (`"4.6"`, `"2.1.09"`).
    enum MarketingMatchPrecision: Int, Comparable {
        case padded = 1
        case zeroExtended = 2
        case exact = 3

        static func < (lhs: MarketingMatchPrecision, rhs: MarketingMatchPrecision) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private static func isASCIIDigitToken(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func marketingSegments(_ version: String) -> [String]? {
        let trimmed = sanitizedVersion(version)
        guard trimmed != AppVersion.unknown else { return nil }
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2, segments.allSatisfy(isASCIIDigitToken) else { return nil }
        return segments
    }

    static func compatibleMarketingPrecision(_ dottedVersion: String, buildRaw: String) -> MarketingMatchPrecision? {
        let build = sanitizedVersion(buildRaw)
        guard build != AppVersion.unknown,
              versionPreference(build) == 1,
              isASCIIDigitToken(build),
              let segments = marketingSegments(dottedVersion) else { return nil }
        let joined = segments.joined()
        if build == joined { return .exact }
        if build.hasPrefix(joined) {
            let suffix = build.dropFirst(joined.count)
            if !suffix.isEmpty && suffix.count <= 2 && suffix.allSatisfy({ $0 == "0" }) {
                return .zeroExtended
            }
        }
        let padded = segments.enumerated().map { item in
            item.offset == 0 ? item.element : (item.element.count == 1 ? "0" + item.element : item.element)
        }.joined()
        if padded != joined {
            if build == padded { return .padded }
            if build.hasPrefix(padded) {
                let suffix = build.dropFirst(padded.count)
                if !suffix.isEmpty && suffix.count <= 2 && suffix.allSatisfy({ $0 == "0" }) {
                    return .padded
                }
            }
        }
        return nil
    }

    static func matchesReleaseVersion(_ candidate: String, reference: String) -> Bool {
        let a = sanitizedVersion(candidate)
        let b = sanitizedVersion(reference)
        guard a != AppVersion.unknown, b != AppVersion.unknown else { return false }
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        if versionPreference(b) >= 2 && versionPreference(a) == 1 {
            return compatibleMarketingPrecision(b, buildRaw: a) != nil
        }
        if versionPreference(a) >= 2 && versionPreference(b) == 1 {
            return compatibleMarketingPrecision(a, buildRaw: b) != nil
        }
        return false
    }

    /// Detects when Apple's DownloadDispatch returned the app's current live version
    /// (for example `"4800"`) for a historical build whose older position already precedes
    /// strictly distinct newer releases.
    static func isLikelyStaleLatestFallback(
        _ candidate: String,
        versionID: String,
        appVersion: String,
        versions: [AppVersion],
        cachedMetadata: [String: VersionMetadata] = [:],
        rowIndex: Int? = nil,
        rowReleased: Date? = nil,
        latestReleased: Date? = nil
    ) -> Bool {
        guard !versions.isEmpty,
              let index = rowIndex ?? versions.firstIndex(where: { $0.id == versionID }),
              index > 0,
              versions.first?.id != versionID else { return false }
        let clean = sanitizedVersion(candidate, rejectingID: versionID)
        guard clean != AppVersion.unknown else { return false }

        let latestReferences = [
            appVersion,
            versions[0].version,
            cachedMetadata[versions[0].id]?.version ?? ""
        ].compactMap { ref -> String? in
            let sanitized = sanitizedVersion(ref, rejectingID: versions[0].id)
            return sanitized == AppVersion.unknown ? nil : sanitized
        }
        guard latestReferences.contains(where: { matchesReleaseVersion(clean, reference: $0) }) else {
            return false
        }

        let hasDistinctNewerVersion = versions[1..<index].contains { entry in
            let known = bestVersion([
                cachedMetadata[entry.id]?.version ?? "",
                entry.version
            ], rejectingID: entry.id)
            guard known != AppVersion.unknown else { return false }
            return !matchesReleaseVersion(known, reference: clean)
                && !latestReferences.contains(where: { matchesReleaseVersion(known, reference: $0) })
        }
        if hasDistinctNewerVersion { return true }

        if let rowReleased,
           let latestReleased = latestReleased ?? cachedMetadata[versions[0].id]?.released,
           latestReleased.timeIntervalSince(rowReleased) > 180 * 86400,
           index >= 3 {
            return true
        }
        return false
    }

    static func reconcileSingleWithReleaseNotes(
        versionID: String,
        rawVersion: String,
        released: Date?,
        versions: [AppVersion],
        metadata: [String: VersionMetadata],
        notes: [ReleaseNote],
        appVersion: String,
        rowIndex: Int? = nil
    ) -> String? {
        guard !notes.isEmpty,
              let index = rowIndex ?? versions.firstIndex(where: { $0.id == versionID }) else { return nil }
        let clean = sanitizedVersion(rawVersion, rejectingID: versionID)
        guard clean != AppVersion.unknown,
              versionPreference(clean) < 2,
              !isLikelyStaleLatestFallback(clean, versionID: versionID, appVersion: appVersion,
                                            versions: versions, cachedMetadata: metadata,
                                            rowIndex: index, rowReleased: released) else {
            return nil
        }

        let structuralMatches = notes.compactMap { note -> (note: ReleaseNote, precision: MarketingMatchPrecision)? in
            guard let precision = compatibleMarketingPrecision(note.version, buildRaw: clean) else { return nil }
            return (note, precision)
        }
        guard !structuralMatches.isEmpty else { return nil }

        let uniqueWinner: ([ (note: ReleaseNote, precision: MarketingMatchPrecision) ]) -> ReleaseNote? = { pool in
            let distinctVersions = Set(pool.map { sanitizedVersion($0.note.version) })
            guard distinctVersions.count == 1 else { return nil }
            return pool.max(by: { $0.precision < $1.precision })?.note
        }

        if let released {
            let datedMatches = structuralMatches.filter { item in
                guard let noteDate = item.note.date else { return false }
                let delta = noteDate.timeIntervalSince(released)
                return delta >= -5 * 86400 && delta <= 60 * 86400
            }
            if !datedMatches.isEmpty {
                return uniqueWinner(datedMatches)?.version
            }
            // If notes carry dates and none matched the IPA's package date window, do not guess.
            if structuralMatches.contains(where: { $0.note.date != nil }) {
                return nil
            }
        }

        guard let winner = uniqueWinner(structuralMatches) else { return nil }
        guard let winnerDate = winner.date else {
            return structuralMatches.count == 1 ? winner.version : nil
        }

        let noteDatesByVersion = Dictionary(
            notes.compactMap { note -> (String, Date)? in
                let key = sanitizedVersion(note.version)
                guard key != AppVersion.unknown, let date = note.date else { return nil }
                return (key, date)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let myNumericID = UInt64(versionID)
        let newerRowDate = versions[0..<index].reversed().compactMap { entry -> Date? in
            if let myNumericID, let otherID = UInt64(entry.id), otherID < myNumericID { return nil }
            if let metaDate = metadata[entry.id]?.released { return metaDate }
            let known = bestVersion([metadata[entry.id]?.version ?? "", entry.version], rejectingID: entry.id)
            return noteDatesByVersion[known]
        }.first
        let olderRowDate = versions[(index + 1)...].compactMap { entry -> Date? in
            if let myNumericID, let otherID = UInt64(entry.id), otherID > myNumericID { return nil }
            if let metaDate = metadata[entry.id]?.released { return metaDate }
            let known = bestVersion([metadata[entry.id]?.version ?? "", entry.version], rejectingID: entry.id)
            return noteDatesByVersion[known]
        }.first

        if let newerRowDate, winnerDate > newerRowDate.addingTimeInterval(45 * 86400) { return nil }
        if let olderRowDate, winnerDate < olderRowDate.addingTimeInterval(-10 * 86400) { return nil }
        return winner.version
    }

    static func reconcileWithReleaseNotes(
        versions: [AppVersion],
        metadata: [String: VersionMetadata],
        notes: [ReleaseNote],
        appVersion: String
    ) -> [(id: String, version: String)] {
        guard !versions.isEmpty, !notes.isEmpty else { return [] }
        var updates: [(id: String, version: String)] = []
        for (index, entry) in versions.enumerated() {
            let current = bestVersion([metadata[entry.id]?.version ?? "", entry.version], rejectingID: entry.id)
            guard let resolved = reconcileSingleWithReleaseNotes(
                versionID: entry.id,
                rawVersion: current,
                released: metadata[entry.id]?.released,
                versions: versions,
                metadata: metadata,
                notes: notes,
                appVersion: appVersion,
                rowIndex: index
            ) else { continue }
            if resolved != entry.version || (metadata[entry.id] != nil && metadata[entry.id]?.version != resolved) {
                updates.append((entry.id, resolved))
            }
        }
        return updates
    }

    static func mergeSourceResults(_ sources: [[AppVersion]]) -> [AppVersion] {
        var result: [AppVersion] = []
        var indices: [String: Int] = [:]
        // Preserve the configured source priority, inserting a version missing from
        // earlier sources before its next shared anchor when one follows in order.
        for source in sources {
            let validSource: [AppVersion] = source.compactMap { rawVersion in
                guard !rawVersion.id.isEmpty else { return nil }
                var version = rawVersion
                version.version = sanitizedVersion(version.version, rejectingID: version.id)
                return version
            }
            var nextKnownAnchor: [String?] = Array(repeating: nil, count: validSource.count)
            var trailingAnchor: String?
            for idx in validSource.indices.reversed() {
                nextKnownAnchor[idx] = trailingAnchor
                let id = validSource[idx].id
                if indices[id] != nil { trailingAnchor = id }
            }
            var insertCursor = 0
            for (pos, version) in validSource.enumerated() {
                if let index = indices[version.id] {
                    result[index].version = preferredVersion(version.version, over: result[index].version, rejectingID: version.id)
                    if !result[index].source.components(separatedBy: "、").contains(version.source) {
                        result[index].source += AppText.text("、") + version.source
                    }
                    insertCursor = max(insertCursor, index + 1)
                } else if let anchorID = nextKnownAnchor[pos],
                          let anchorIndex = indices[anchorID],
                          anchorIndex >= insertCursor {
                    result.insert(version, at: anchorIndex)
                    for i in anchorIndex..<result.count {
                        indices[result[i].id] = i
                    }
                    insertCursor = anchorIndex + 1
                } else {
                    indices[version.id] = result.count
                    result.append(version)
                    insertCursor = result.count
                }
            }
        }
        return Array(result.prefix(2000))
    }

    /// The result of checking one source against a well-known app.
    struct SourceCheck: Equatable, Sendable {
        let versions: Int
        let seconds: Double
    }
    /// An app every source tracks, so an empty answer means the source is broken.
    static let probeAppID = "414478124"
    /// Asks `source` for a well-known app's history, as a real lookup would.
    static func check(_ source: VersionSource) async throws -> SourceCheck {
        let start = Date()
        let versions = try await fetch(probeAppID, source: source)
        guard !versions.isEmpty else { throw ToolError.message(AppText.text("返回的版本列表为空")) }
        return SourceCheck(versions: versions.count, seconds: Date().timeIntervalSince(start))
    }

    static func fetch(_ id: String, source: VersionSource) async throws -> [AppVersion] {
        guard let url = source.url(for: id) else {
            throw ToolError.message(AppText.text("\(source.name)：接口地址无效"))
        }
        let object = try await HTTPClient.shared.json(url)
        let value: Any? = source.containerKey.isEmpty ? object : (object as? [String: Any])?[source.containerKey]
        guard let records = value as? [[String: Any]] else { throw ToolError.message(AppText.text("\(source.name)：暂时无法读取版本列表")) }
        var seen = Set<String>()
        let ordered = source.reverse ? Array(records.suffix(2000).reversed()) : Array(records.prefix(2000))
        return ordered.compactMap { record in
            let id = plistString(record["external_identifier"])
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }), seen.insert(id).inserted else { return nil }
            let version = sanitizedVersion(plistString(record["bundle_version"]), rejectingID: id)
            return AppVersion(id: id, version: version, source: source.name)
        }
    }

    func clearCache() throws {
        try LocalResources.save([String: Cache](), filename: LocalResources.versionsFilename)
        cacheRevision = UUID(); cache.removeAll()
    }
}
