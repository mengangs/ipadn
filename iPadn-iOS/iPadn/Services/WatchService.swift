import Foundation

/// A storefront price from the moment it was first seen.
struct PricePoint: Codable, Hashable {
    var date: Date
    var price: Double
}

/// Something about a followed app that changed between two checks.
enum WatchChange: Codable, Hashable {
    case newVersion(String)
    case priceDrop(from: Double, to: Double)
    case free(from: Double)
    case priceRise(from: Double, to: Double)
    case delisted
    case relisted

    /// Higher is more worth showing when one check finds several changes.
    var rank: Int {
        switch self {
        case .free: return 5
        case .priceDrop: return 4
        case .delisted: return 3
        case .newVersion: return 2
        case .relisted: return 1
        case .priceRise: return 0
        }
    }
    /// A short tag for lists.
    var tag: String {
        switch self {
        case .newVersion: return "新版本"
        case .priceDrop: return "降价"
        case .free: return "限免"
        case .priceRise: return "涨价"
        case .delisted: return "已下架"
        case .relisted: return "重新上架"
        }
    }
}

/// What iPadn last saw of a followed app in one storefront.
struct WatchRecord: Codable, Equatable {
    var id: String
    var country: String
    var version = ""
    var price: Double?
    var currency = ""
    var delisted = false
    var history: [PricePoint] = []
    var started: Date
    var checked: Date
    /// The most notable change of the latest check that found one.
    var change: WatchChange?
    var changed: Date?

    var key: String { Self.key(id: id, country: country) }
    static func key(id: String, country: String) -> String { id + "|" + country.uppercased() }
    var listed: Bool { !version.isEmpty || price != nil }
    /// A change from the last week, for the list.
    func recentChange(now: Date = Date()) -> WatchChange? {
        guard let change, let changed, now.timeIntervalSince(changed) < 7 * 86400 else { return nil }
        return change
    }
}

enum WatchService {
    static let historyLimit = 400

    /// Folds a fresh lookup into the record. A nil listing means the
    /// storefront no longer lists the app; it only counts as a removal once
    /// the app was seen listed there.
    static func update(_ record: WatchRecord?, id: String, country: String, listing: StoreApp?,
                       now: Date = Date()) -> (record: WatchRecord, changes: [WatchChange]) {
        var next = record ?? WatchRecord(id: id, country: country.uppercased(), started: now, checked: now)
        next.checked = now
        var changes: [WatchChange] = []
        if let listing {
            if record?.delisted == true { changes.append(.relisted) }
            next.delisted = false
            if let old = record?.version, VersionOrder.isNewer(listing.version, than: old) {
                changes.append(.newVersion(listing.version))
            }
            if !listing.version.isEmpty { next.version = listing.version }
            if let price = listing.priceValue, price >= 0 {
                let currency = listing.currency ?? next.currency
                if !next.currency.isEmpty, currency != next.currency {
                    // The storefront changed currency: earlier prices no longer compare.
                    next.history = []; next.price = nil
                }
                if let old = next.price, !same(old, price) {
                    changes.append(price == 0 ? .free(from: old) : price < old ? .priceDrop(from: old, to: price)
                                   : .priceRise(from: old, to: price))
                }
                if next.history.last.map({ !same($0.price, price) }) ?? true {
                    next.history.append(PricePoint(date: now, price: price))
                    next.history = Array(next.history.suffix(historyLimit))
                }
                next.price = price
                next.currency = currency
            }
        } else if record?.listed == true, record?.delisted == false {
            next.delisted = true
            changes.append(.delisted)
        }
        if let notable = changes.max(by: { $0.rank < $1.rank }) {
            next.change = notable; next.changed = now
        }
        return (next, changes)
    }

    private static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_1 }

    /// "免费" for zero, else the amount in its currency ("¥18", "$2.99").
    static func format(_ price: Double, currency: String) -> String {
        if price == 0 { return "免费" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        if !currency.isEmpty { formatter.currencyCode = currency }
        formatter.minimumFractionDigits = price.rounded() == price ? 0 : 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
    }

    /// A sentence for a notification, or nil when the change is not worth one.
    static func message(_ change: WatchChange, currency: String) -> String? {
        switch change {
        case .newVersion(let version): return "有新版本 \(version)"
        case .priceDrop(let from, let to): return "降价：\(format(from, currency: currency)) → \(format(to, currency: currency))"
        case .free(let from): return "限免：原价 \(format(from, currency: currency))，现在免费"
        case .delisted: return "已从 App Store 下架，获取过的账号仍可下载，建议尽快备份"
        case .relisted: return "已重新上架"
        case .priceRise: return nil
        }
    }
}

enum PurchaseExport {
    /// One row per purchase: name, IDs, version, purchase date, store status, downloaded.
    static func csv(_ apps: [OwnedApp], listed: [String: Bool], downloaded: Set<String>) -> String {
        var rows = [["名称", "App ID", "Bundle ID", "版本", "购买日期", "商店状态", "已下载"]]
        let date = Date.FormatStyle().year().month(.twoDigits).day(.twoDigits)
        for app in apps {
            let status = listed[app.id].map { $0 ? "在售" : "已下架" } ?? "未检查"
            rows.append([app.name, app.id, app.bundleID, app.version, app.purchaseDate.map { $0.formatted(date) } ?? "",
                         status, downloaded.contains(app.id) ? "是" : "否"])
        }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Quoted when it holds a comma, quote or line break; quotes doubled.
    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
