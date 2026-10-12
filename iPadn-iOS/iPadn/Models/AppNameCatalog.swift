import Foundation

struct AppNameEntry: Codable {
    let id: String
    let name: String
    let aliases: [String]
    let platform: AppPlatform
    let source: String
    var app: StoreApp { StoreApp(id: id, name: name, price: "") }
}

enum AppNameCatalog {
    static let cacheFile = "app-name-directory.json"
    static func decode(_ data: Data) throws -> [AppNameEntry] {
        guard data.count <= 2_000_000 else { throw ToolError.message("名称目录过大") }
        let entries = try JSONDecoder().decode([AppNameEntry].self, from: data)
        guard entries.count <= 10_000, entries.allSatisfy({
            !$0.id.isEmpty && $0.id.allSatisfy { $0.isASCII && $0.isNumber } &&
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 300 &&
            $0.aliases.count <= 30 && $0.aliases.allSatisfy { $0.count <= 300 }
        }) else { throw ToolError.message("名称目录格式不正确") }
        return entries
    }
    static func bundled() -> [AppNameEntry] {
        guard let url = Bundle.main.url(forResource: "app-name-directory", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }
    static func search(_ text: String, platform: AppPlatform, entries: [AppNameEntry]) -> [StoreApp] {
        let term = AppSearchIndex.normalized(text)
        guard !term.isEmpty else { return [] }
        return AppSearchIndex.unique(entries.filter { entry in
            entry.platform == platform && ([entry.name] + entry.aliases + [entry.id]).contains {
                AppSearchIndex.normalized($0).contains(term)
            }
        }.map(\.app))
    }
    static func updated() async throws -> [AppNameEntry] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://raw.githubusercontent.com/mengangs/ipadn/main/iPadn-iOS/iPadn/Resources/app-name-directory.json")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolError.message("名称目录暂时无法更新") }
        return try decode(data)
    }
}
