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
                return try await searchEntities(store.platform.searchEntity)
                    .filter(Self.supportsNativeMac).map(mapLookup)
            }
            guard store.platform == .tvOS else {
                return try await searchEntities(store.platform.searchEntity).map(mapLookup)
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
            return await withAppleTVListings(rows.filter(Self.supportsAppleTV).map(mapLookup), store: store)
        case .appID(let id, _):
            if store.platform == .tvOS { return try await platformApp(id, store: store).map { [$0] } ?? [] }
            // No "entity" here: on an ID lookup it requests *related* items
            // (and is rejected for some catalogs), which broke App ID search.
            let url = try endpoint("https://itunes.apple.com/lookup", items: [
                URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: store.country)
            ])
            let rows = (try await HTTPClient.shared.json(url) as? [String: Any])?["results"] as? [[String: Any]] ?? []
            let apps = Self.idLookupMatches(rows, id: id, platform: store.platform).map(mapLookup)
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
        if icons.isEmpty, let firstError { throw firstError }
        return icons
    }

    /// Current listings for many App IDs at once: the lookup API takes a list.
    /// `nativeMac` names the IDs whose listing is a Mac app.
    static func lookup(ids: [String], country: String) async throws -> (apps: [String: StoreApp], nativeMac: Set<String>) {
        let ids = ids.filter { UInt64($0).map { $0 > 0 } == true }
        let chunks = stride(from: 0, to: ids.count, by: 100).map { Array(ids[$0..<min($0 + 100, ids.count)]) }
        var found: [String: StoreApp] = [:]
        var nativeMac = Set<String>()
        // Large purchase lists: a few chunks at a time instead of one after another.
        try await withThrowingTaskGroup(of: [(app: StoreApp, mac: Bool)].self) { group in
            var pending = chunks.makeIterator()
            for _ in 0..<4 {
                if let chunk = pending.next() { group.addTask { try await lookupChunk(chunk, country: country) } }
            }
            while let rows = try await group.next() {
                for row in rows {
                    found[row.app.id] = row.app
                    if row.mac { nativeMac.insert(row.app.id) }
                }
                if let chunk = pending.next() { group.addTask { try await lookupChunk(chunk, country: country) } }
            }
        }
        return (found, nativeMac)
    }

    private static func lookupChunk(_ chunk: [String], country: String) async throws -> [(app: StoreApp, mac: Bool)] {
        let url = try endpoint("https://itunes.apple.com/lookup", items: [
            URLQueryItem(name: "id", value: chunk.joined(separator: ",")), URLQueryItem(name: "country", value: country)
        ])
        let rows = (try await HTTPClient.shared.json(url) as? [String: Any])?["results"] as? [[String: Any]] ?? []
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
        return ListingExtras(screenshots: preferred.prefix(10).compactMap(screenshot),
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

    static func mapLookup(_ raw: [String: Any]) -> StoreApp {
        StoreApp(id: plistString(raw["trackId"]), name: plistString(raw["trackName"] ?? raw["trackCensoredName"]),
                 bundleID: plistString(raw["bundleId"]), version: plistString(raw["version"]),
                 iconURL: icon(plistString(raw["artworkUrl512"] ?? raw["artworkUrl100"])),
                 description: plistString(raw["description"]), category: localizedGenre(plistString(raw["primaryGenreName"])),
                 size: Int64(plistString(raw["fileSizeBytes"])) ?? 0,
                 price: plistString(raw["formattedPrice"]).isEmpty ? "免费" : plistString(raw["formattedPrice"]),
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
        return names[name] ?? name
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
        // Complete every enabled query. Taking the first provider to respond
        // makes the version list depend on network timing and hides unique IDs.
        let sourceResults = await withTaskGroup(
            of: (Int, Result<[AppVersion], Error>).self,
            returning: [[AppVersion]].self
        ) { group in
            for (index, source) in enabled.enumerated() {
                group.addTask {
                    do { return (index, .success(try await Self.fetch(appID, source: source))) }
                    catch { return (index, .failure(error)) }
                }
            }
            var lists = Array(repeating: [AppVersion](), count: enabled.count)
            for await (index, result) in group {
                if case .success(let versions) = result { lists[index] = versions }
            }
            return lists
        }
        try Task.checkCancellation()
        let versions = Self.mergeSourceResults(sourceResults)
        guard !versions.isEmpty else {
            // The previous successful records remain useful if both third-party
            // services are temporarily unavailable. Label them as cached.
            if let old = cache[key], Date().timeIntervalSince(old.savedAt) < 7 * 86400 {
                return old.versions.map {
                    var item = $0
                    item.source += "（缓存）"
                    return item
                }
            }
            throw ToolError.message("暂时无法获取历史版本，可打开「从 Apple 获取完整版本列表」或手动输入版本 ID")
        }
        if revision == cacheRevision {
            cache = cache.filter { Date().timeIntervalSince($0.value.savedAt) < 7 * 86400 }
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

    static func mergeSourceResults(_ sources: [[AppVersion]]) -> [AppVersion] {
        var result: [AppVersion] = []
        var indices: [String: Int] = [:]
        // Preserve the configured source priority and the order returned by
        // each source. The API does not provide comparable release timestamps.
        for source in sources {
            for version in source where !version.id.isEmpty {
                if let index = indices[version.id] {
                    if result[index].version == "未知版本" && version.version != "未知版本" {
                        result[index].version = version.version
                    }
                    if !result[index].source.components(separatedBy: "、").contains(version.source) {
                        result[index].source += "、" + version.source
                    }
                } else {
                    indices[version.id] = result.count
                    result.append(version)
                }
            }
        }
        return Array(result.prefix(2000))
    }

    private static func fetch(_ id: String, source: VersionSource) async throws -> [AppVersion] {
        guard source.urlTemplate.contains("{id}"),
              let url = URL(string: source.urlTemplate.replacingOccurrences(of: "{id}", with: id)), url.scheme == "https" else {
            throw ToolError.message("\(source.name)：接口地址无效")
        }
        let object = try await HTTPClient.shared.json(url)
        let value: Any? = source.containerKey.isEmpty ? object : (object as? [String: Any])?[source.containerKey]
        guard let records = value as? [[String: Any]] else { throw ToolError.message("\(source.name)：暂时无法读取版本列表") }
        var seen = Set<String>()
        let ordered = source.reverse ? Array(records.suffix(2000).reversed()) : Array(records.prefix(2000))
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
