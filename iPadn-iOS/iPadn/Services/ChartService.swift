import Foundation

/// App Store top charts, from Apple's public RSS feeds.
enum AppChart: String, CaseIterable, Identifiable {
    case free, paid, grossing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return AppText.text("免费榜")
        case .paid: return AppText.text("付费榜")
        case .grossing: return AppText.text("畅销榜")
        }
    }
    var symbol: String {
        switch self {
        case .free: return "arrow.down.app"
        case .paid: return "dollarsign.circle"
        case .grossing: return "chart.line.uptrend.xyaxis"
        }
    }
    /// The feed's name for a platform; Apple TV has no chart feed.
    func feed(_ platform: AppPlatform) -> String? {
        let kind: String
        switch self { case .free: kind = "free"; case .paid: kind = "paid"; case .grossing: kind = "grossing" }
        switch platform {
        case .iOS: return "top\(kind)applications"
        case .iPadOS: return "top\(kind)ipadapplications"
        case .macOS: return "top\(kind)macapps"
        case .tvOS: return nil
        }
    }
}

/// App Store categories offered as chart filters (iPhone and iPad charts).
enum ChartGenre: Int, CaseIterable, Identifiable {
    case all = 0, games = 6014, entertainment = 6016, productivity = 6007, utilities = 6002, photo = 6008,
         social = 6005, music = 6011, education = 6017, health = 6013, finance = 6015
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: return AppText.text("全部")
        case .games: return AppText.text("游戏")
        case .entertainment: return AppText.text("娱乐")
        case .productivity: return AppText.text("效率")
        case .utilities: return AppText.text("工具")
        case .photo: return AppText.text("摄影与录像")
        case .social: return AppText.text("社交")
        case .music: return AppText.text("音乐")
        case .education: return AppText.text("教育")
        case .health: return AppText.text("健康健美")
        case .finance: return AppText.text("财务")
        }
    }
}

enum ChartService {
    /// The ranked App IDs of a chart, best first (at most 100).
    static func ids(_ chart: AppChart, platform: AppPlatform, country: String, genre: ChartGenre = .all) async throws -> [String] {
        guard let feed = chart.feed(platform) else { return [] }
        let genrePart = genre == .all || platform == .macOS ? "" : "/genre=\(genre.rawValue)"
        guard let url = URL(string: "https://itunes.apple.com/\(country.lowercased())/rss/\(feed)/limit=100\(genrePart)/json") else { return [] }
        let (data, _) = try await HTTPClient.shared.request(url, headers: ["Accept": "application/json"])
        return parse(data)
    }

    /// Entry IDs in order; one entry arrives as an object, none as no key.
    static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = json["feed"] as? [String: Any] else { return [] }
        let entries: [[String: Any]]
        if let list = feed["entry"] as? [[String: Any]] { entries = list }
        else if let one = feed["entry"] as? [String: Any] { entries = [one] }
        else { entries = [] }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let id = ((entry["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String,
                  UInt64(id) != nil, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// The chart's apps with their full store listing, in chart order.
    static func apps(_ chart: AppChart, platform: AppPlatform, country: String, genre: ChartGenre = .all) async throws -> [StoreApp] {
        let ids = try await ids(chart, platform: platform, country: country, genre: genre)
        guard !ids.isEmpty else { return [] }
        let found = try await StoreService.lookup(ids: ids, country: country).apps
        return ids.compactMap { found[$0] }
    }
}
