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
