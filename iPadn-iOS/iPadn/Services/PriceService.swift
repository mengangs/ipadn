import Foundation

/// App Store storefronts, for price comparison.
enum StoreRegions {
    static let codes = """
    AE AG AI AL AM AO AR AT AU AZ BA BB BD BE BF BG BH BJ BM BN BO BR BS BT BW BY BZ CA CD CG CH CI CL CM CN CO \
    CR CV CY CZ DE DK DM DO DZ EC EE EG ES FI FJ FM FR GA GB GD GE GH GM GR GT GW GY HK HN HR HU ID IE IL IN IQ \
    IS IT JM JO JP KE KG KH KN KR KW KY KZ LA LB LC LK LR LT LU LV LY MA MD ME MG MK ML MM MN MO MR MS MT MU MV \
    MW MX MY MZ NA NE NG NI NL NO NP NR NZ OM PA PE PG PH PK PL PT PW PY QA RO RS RU RW SA SB SC SE SG SI SK SL \
    SN SR ST SV SZ TC TD TH TJ TM TN TO TR TT TW TZ UA UG US UY UZ VC VE VG VN VU XK YE ZA ZM ZW
    """.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    static let defaultComparison = ["CN", "HK", "US", "JP", "KR", "TR", "NG"]

    static func name(_ code: String) -> String {
        Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? code
    }
    static func flag(_ code: String) -> String {
        code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(String.init).joined()
    }
    /// Storefronts whose prices leave out sales tax, which is added at checkout.
    static let taxExcluded: Set<String> = ["US", "CA"]
}

/// Daily reference rates (mid-market, before card fees).
struct ExchangeRates: Codable, Equatable {
    var base: String
    /// Units of each currency per one unit of `base`.
    var rates: [String: Double]
    var updated: Date
    var fetched: Date

    /// `amount` in `currency`, expressed in the base currency.
    func convert(_ amount: Double, from currency: String) -> Double? {
        if currency == base { return amount }
        guard let rate = rates[currency], rate > 0 else { return nil }
        return amount / rate
    }

    static func parse(_ data: Data, base: String, fetched: Date = Date()) -> ExchangeRates? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["result"] as? String) == "success",
              let raw = json["rates"] as? [String: Any] else { return nil }
        var rates: [String: Double] = [:]
        for (code, value) in raw { if let number = value as? NSNumber { rates[code] = number.doubleValue } }
        guard !rates.isEmpty else { return nil }
        let updated = (json["time_last_update_unix"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? fetched
        return ExchangeRates(base: (json["base_code"] as? String) ?? base, rates: rates, updated: updated, fetched: fetched)
    }

    private static let cacheFile = "exchange-rates.json"
    /// Cached rates when recent, else fresh ones; stale cached rates when offline.
    static func load(base: String) async -> ExchangeRates? {
        let stored = try? LocalResources.loadChecked(ExchangeRates.self, filename: cacheFile)
        let cached = stored?.base == base ? stored : nil
        if let cached, Date().timeIntervalSince(cached.fetched) < 12 * 3600 { return cached }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/" + base),
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let fresh = parse(result.0, base: base) else { return cached }
        try? LocalResources.save(fresh, filename: cacheFile)
        return fresh
    }
}

/// One storefront's price for an app.
struct RegionPrice: Identifiable, Equatable {
    var country: String
    var listing: StoreApp?
    var id: String { country }
    var price: Double? { listing?.priceValue }
    var currency: String { listing?.currency ?? "" }
}

enum PriceComparison {
    /// The app's listing in each storefront, a few at a time.
    static func regionPrices(appID: String, countries: [String]) async -> [RegionPrice] {
        var results: [String: RegionPrice] = [:]
        await withTaskGroup(of: RegionPrice?.self) { group in
            var pending = countries.makeIterator()
            for _ in 0..<6 {
                if let country = pending.next() { group.addTask { await regionPrice(appID: appID, country: country) } }
            }
            while let result = await group.next() {
                if let result { results[result.country] = result }
                if let country = pending.next() { group.addTask { await regionPrice(appID: appID, country: country) } }
            }
        }
        return countries.compactMap { results[$0] }
    }

    /// Nil when the request failed, rather than showing "not listed".
    private static func regionPrice(appID: String, country: String) async -> RegionPrice? {
        guard let found = try? await StoreService.lookup(ids: [appID], country: country) else { return nil }
        return RegionPrice(country: country, listing: found.apps[appID])
    }

    /// Cheapest first in the base currency; unconvertible prices after
    /// those, then storefronts that don't list the app.
    static func sorted(_ prices: [RegionPrice], rates: ExchangeRates?) -> [RegionPrice] {
        func key(_ item: RegionPrice) -> (Int, Double) {
            guard let price = item.price else { return (2, 0) }
            if let converted = rates?.convert(price, from: item.currency) { return (0, converted) }
            return (1, 0)
        }
        return prices.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka.0 != kb.0 ? ka.0 < kb.0 : ka.1 != kb.1 ? ka.1 < kb.1 : a.offset < b.offset
        }.map(\.element)
    }
}

/// An in-app purchase as an App Store product page lists it.
struct InAppPrice: Hashable {
    var name: String
    /// The page's text, e.g. "$4.99" or "199,99 TL".
    var text: String
    var price: Double?
}

/// The same in-app purchase across storefronts. Items share a name when the
/// app sells several tiers (monthly, yearly): those are told apart by price
/// order, cheapest first.
struct InAppGroup: Identifiable, Equatable {
    struct Entry: Equatable {
        var country: String
        var item: InAppPrice
        var currency: String
    }
    var name: String
    var tier: Int
    var tiers: Int
    var entries: [Entry]
    var id: String { name + "#\(tier)" }
}

enum InAppPriceService {
    /// The in-app purchases a product page lists (Apple shows up to ten),
    /// [] when it lists none, nil when the page could not be read.
    static func fetch(appID: String, country: String) async -> [InAppPrice]? {
        var outcome = await page(appID: appID, country: country)
        if case .failure = outcome {
            // One retry: a busy storefront page often answers the second time.
            try? await Task.sleep(for: .seconds(1))
            outcome = await page(appID: appID, country: country)
        }
        let report: String
        switch outcome {
        case .success(let items): report = "\(items.count) items"
        case .failure(let reason): report = reason.description
        }
        await MainActor.run { diagnostics[appID + "|" + country.uppercased()] = report }
        if case .success(let items) = outcome { return items }
        return nil
    }

    enum PageFailure: Error, CustomStringConvertible {
        case network(String), status(Int), noData(Int), notJSON(Int)
        var description: String {
            switch self {
            case .network(let message): return "network: " + message
            case .status(let code): return "HTTP \(code)"
            case .noData(let bytes): return "no page data (\(bytes) bytes)"
            case .notJSON(let bytes): return "page data unreadable (\(bytes) bytes)"
            }
        }
    }
    /// What each storefront's page gave, for 专业模式 ("7 items", "HTTP 403").
    @MainActor static var diagnostics: [String: String] = [:]

    /// The product page as a desktop browser gets it, following redirects.
    static func page(appID: String, country: String) async -> Result<[InAppPrice], PageFailure> {
        // English in every storefront (Apple picks its closest English page),
        // so the same purchase has the same name everywhere.
        guard let url = URL(string: "https://apps.apple.com/\(country.lowercased())/app/id\(appID)?l=en-US") else { return .failure(.status(0)) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(browserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let data: Data
        do {
            let (body, response) = try await pageSession.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return .failure(.status(code)) }
            data = body
        } catch { return .failure(.network((error as NSError).localizedDescription)) }
        let html = String(decoding: data, as: UTF8.self)
        guard html.contains("serialized-server-data") else { return .failure(.noData(data.count)) }
        guard let items = items(fromPage: html) else { return .failure(.notJSON(data.count)) }
        return .success(items)
    }
    private static let pageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    /// Several storefronts, a few pages at a time, kept for an hour.
    @MainActor
    static func fetch(appID: String, countries: [String]) async -> [String: [InAppPrice]] {
        var results: [String: [InAppPrice]] = [:]
        var missing: [String] = []
        for country in countries {
            if let cached = cache[appID + "|" + country], Date().timeIntervalSince(cached.date) < 3600 { results[country] = cached.items }
            else { missing.append(country) }
        }
        await withTaskGroup(of: (String, [InAppPrice]?).self) { group in
            var pending = missing.makeIterator()
            for _ in 0..<3 {
                if let country = pending.next() { group.addTask { (country, await fetch(appID: appID, country: country)) } }
            }
            while let result = await group.next() {
                let (country, items) = result
                if let items { results[country] = items; cache[appID + "|" + country] = (Date(), items) }
                if let country = pending.next() { group.addTask { (country, await fetch(appID: appID, country: country)) } }
            }
        }
        return results
    }
    @MainActor private static var cache: [String: (date: Date, items: [InAppPrice])] = [:]

    // The desktop page carries the information section with in-app purchases.
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func items(fromPage html: String) -> [InAppPrice]? {
        guard let marker = html.range(of: "id=\"serialized-server-data\""),
              let open = html[marker.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</script>", range: html.index(after: open)..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[html.index(after: open)..<close.lowerBound].utf8))
        else { return nil }
        // The information section is a list of annotations; the in-app
        // purchase one pairs item names with prices. Its title depends on the
        // page language, so it is recognised by its contents.
        var best: [InAppPrice] = []
        func visit(_ value: Any, depth: Int) {
            guard depth < 40 else { return }
            if let dict = value as? [String: Any] {
                if dict["$kind"] as? String == "Annotation", let entries = dict["items"] as? [[String: Any]] {
                    let pairs = entries.filter { $0["$kind"] as? String == "textPair" }
                    let found = pairs.compactMap { pair -> InAppPrice? in
                        guard let name = pair["leadingText"] as? String, let text = pair["trailingText"] as? String,
                              looksLikePrice(text) else { return nil }
                        return InAppPrice(name: name, text: text, price: price(text))
                    }
                    if !pairs.isEmpty, found.count == pairs.count, found.count > best.count { best = found }
                }
                for child in dict.values { visit(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { visit(child, depth: depth + 1) }
            }
        }
        visit(json, depth: 0)
        // Some apps list the same purchase twice (one per platform).
        var seen = Set<InAppPrice>()
        return best.filter { seen.insert($0).inserted }
    }

    /// A short amount with at most a currency sign or code around it.
    static func looksLikePrice(_ text: String) -> Bool {
        guard text.count <= 24, text.contains(where: \.isNumber) else { return false }
        let ignored: Set<Character> = [".", ",", "'", " ", "\u{00A0}", "\u{202F}"]
        let rest = text.filter { !$0.isNumber && !ignored.contains($0) }
        return rest.count <= 4
    }

    /// The number in a formatted price, whatever the separators:
    /// "$1,099" → 1099, "1.299,99 €" → 1299.99, "Rp 15.000" → 15000.
    static func price(_ text: String) -> Double? {
        let digits = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard !digits.isEmpty else { return nil }
        let separators = digits.enumerated().filter { $0.element == "." || $0.element == "," }
        var normalized = digits
        if let last = separators.last {
            let decimals = digits.count - last.offset - 1
            let lastIsDecimal: Bool
            if Set(separators.map(\.element)).count > 1 { lastIsDecimal = true }
            else { lastIsDecimal = separators.count == 1 && decimals != 3 }
            var chars = Array(digits)
            for (offset, _) in separators { chars[offset] = offset == last.offset && lastIsDecimal ? "." : "_" }
            normalized = String(chars.filter { $0 != "_" })
        }
        return Double(normalized)
    }

    /// Groups each storefront's items into comparable purchases, in the order
    /// the first storefront lists them, cheapest storefront first in each.
    static func groups(_ regions: [(country: String, currency: String, items: [InAppPrice])],
                       rates: ExchangeRates?) -> [InAppGroup] {
        var order: [String] = []
        var groups: [String: InAppGroup] = [:]
        for region in regions {
            let byName = Dictionary(grouping: region.items, by: \.name)
            for item in region.items where byName[item.name]?.first == item {
                let tiers = (byName[item.name] ?? []).sorted { ($0.price ?? .infinity) < ($1.price ?? .infinity) }
                for (tier, tierItem) in tiers.enumerated() {
                    let key = item.name + "#\(tier)"
                    if groups[key] == nil {
                        order.append(key)
                        groups[key] = InAppGroup(name: item.name, tier: tier, tiers: tiers.count, entries: [])
                    }
                    groups[key]!.tiers = max(groups[key]!.tiers, tiers.count)
                    groups[key]!.entries.append(.init(country: region.country, item: tierItem, currency: region.currency))
                }
            }
        }
        return order.compactMap { key in
            guard var group = groups[key] else { return nil }
            group.entries = group.entries.enumerated().sorted { a, b in
                let ca = a.element.item.price.flatMap { rates?.convert($0, from: a.element.currency) }
                let cb = b.element.item.price.flatMap { rates?.convert($0, from: b.element.currency) }
                switch (ca, cb) {
                case let (x?, y?): return x != y ? x < y : a.offset < b.offset
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
            return group
        }
    }
}
