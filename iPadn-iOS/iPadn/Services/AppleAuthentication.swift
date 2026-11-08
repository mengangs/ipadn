import Foundation

/// Authentication-specific response handling. Never retain bodies, arbitrary headers,
/// URLs, or localized error descriptions: these can contain account credentials.
enum AppleAuthentication {
    static let path = "/WebObjects/MZFinance.woa/wa/authenticate"

    static func bagURL(guid: String) -> URL {
        var url = URLComponents(string: "https://init.itunes.apple.com/bag.xml")!
        url.queryItems = [URLQueryItem(name: "guid", value: guid)]
        return url.url!
    }

    static func isEndpoint(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              url.path(percentEncoded: true) == path || url.path(percentEncoded: true) == path + "/" else { return false }
        return host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com")
    }

    static func endpoint(from data: Data) throws -> URL {
        guard let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bag = raw["urlBag"] as? [String: Any],
              let address = bag["authenticateAccount"] as? String,
              let url = URL(string: address), isEndpoint(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ToolError.message("Apple 登录配置无效，请稍后重试")
        }
        // Apple's bare authenticate path can return an unusable response.
        // Keep the bag's host and query; only normalize its trailing slash.
        parts.path = path + "/"
        guard let endpoint = parts.url else { throw ToolError.message("Apple 登录配置无效，请稍后重试") }
        return endpoint
    }

    static func errorCode(_ error: Error) -> String {
        let ns = error as NSError
        // Only known system domains. Custom NSError domains can contain arbitrary text.
        let domains = [NSURLErrorDomain, NSCocoaErrorDomain, "WebKitErrorDomain"]
        return "error=\(domains.contains(ns.domain) ? ns.domain : "application"); code=\(ns.code)"
    }

    enum ResponseKind: String {
        case empty, plist, html, json, other
    }

    static func kind(_ data: Data) -> ResponseKind {
        if data.isEmpty { return .empty }
        if (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil { return .plist }
        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") { return .html }
        if prefix.hasPrefix("{") || prefix.hasPrefix("[") { return .json }
        return .other
    }

    @MainActor
    static func authenticate(endpoint: URL, body: Data, headers: [String: String],
        send: (URL, Data, [String: String]) async throws -> (Data, HTTPURLResponse),
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        report: (String) -> Void) async throws -> ([String: Any], HTTPURLResponse) {
        guard isEndpoint(endpoint) else { throw ToolError.message("Apple 登录地址无效") }
        // A transport retry keeps exactly the same signed payload, including attempt.
        // Never retry a decoded Apple credential error or a 2FA challenge.
        for attempt in 1...2 {
            try Task.checkCancellation()
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await send(endpoint, body, headers)
            } catch {
                let status = (error as? HTTPStatusError)?.code
                report("stage=authentication; request=\(attempt); " + (status.map { "http=\($0)" } ?? errorCode(error)))
                if attempt == 1, let status, status == 403 || status == 404 || (500...599).contains(status) {
                    try await pause(); continue
                }
                throw error
            }
            let format = kind(data)
            report("stage=authentication; request=\(attempt); http=\(response.statusCode); format=\(format.rawValue); bytes=\(data.count)")
            if response.statusCode == 200, format == .plist,
               let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return (raw, response)
            }
            if attempt == 1, response.statusCode == 200 || response.statusCode == 204 {
                try await pause(); continue
            }
            throw ToolError.message("Apple 未返回有效的登录数据，请稍后重试或切换网络。仍然失败可在设置中导出诊断信息。")
        }
        throw ToolError.message("Apple 登录暂时不可用，请稍后重试")
    }
}
