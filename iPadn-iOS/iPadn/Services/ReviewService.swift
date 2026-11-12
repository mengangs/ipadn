import Foundation

/// One App Store customer review from Apple's public review feed.
struct AppReview: Identifiable, Equatable {
    var id: String
    var author: String
    var title: String
    var body: String
    var rating: Int
    var version: String
    var date: Date?
}

enum ReviewService {
    /// The feed holds at most ten pages of fifty reviews.
    static let lastPage = 10

    /// The most recent reviews in one storefront, newest first.
    static func reviews(appID: String, country: String, page: Int) async throws -> [AppReview] {
        guard UInt64(appID).map({ $0 > 0 }) == true, (1...lastPage).contains(page),
              let url = URL(string: "https://itunes.apple.com/\(country.lowercased())/rss/customerreviews/page=\(page)/id=\(appID)/sortby=mostrecent/json")
        else { return [] }
        let (data, _) = try await HTTPClient.shared.request(url, headers: ["Accept": "application/json"])
        return parse(data)
    }

    /// The feed's entries; one entry arrives as an object, none as no key.
    static func parse(_ data: Data) -> [AppReview] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = json["feed"] as? [String: Any] else { return [] }
        let entries: [[String: Any]]
        if let list = feed["entry"] as? [[String: Any]] { entries = list }
        else if let one = feed["entry"] as? [String: Any] { entries = [one] }
        else { entries = [] }
        func label(_ entry: [String: Any], _ key: String) -> String {
            ((entry[key] as? [String: Any])?["label"] as? String) ?? ""
        }
        let dates = ISO8601DateFormatter()
        return entries.compactMap { entry in
            // A review has a rating; the app's own entry in older feeds does not.
            guard let rating = Int(label(entry, "im:rating")), (1...5).contains(rating) else { return nil }
            let author = (((entry["author"] as? [String: Any])?["name"] as? [String: Any])?["label"] as? String) ?? ""
            let id = label(entry, "id")
            return AppReview(id: id.isEmpty ? UUID().uuidString : id, author: author,
                             title: label(entry, "title"), body: label(entry, "content"),
                             rating: rating, version: label(entry, "im:version"),
                             date: dates.date(from: label(entry, "updated")))
        }
    }
}
