import Foundation

final class HTTPClient: Sendable {
    static let shared = HTTPClient()
    static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil,
                 headers: [String: String] = [:], appleRedirects: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ToolError.message("远程接口必须使用 HTTPS，不能包含账号密码") }
        var current = url
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.httpMethod = method; request.httpBody = body
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ToolError.message("接口响应格式错误") }
            if [301, 302, 303, 307, 308].contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: current)?.absoluteURL {
                guard next.scheme == "https", let host = next.host,
                      next.user == nil, next.password == nil else { throw ToolError.message("接口返回了不安全的重定向") }
                if appleRedirects {
                    guard host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com") else {
                        throw ToolError.message("Apple 接口重定向到了非 Apple 地址，已停止请求")
                    }
                } else {
                    guard next.host == url.host else { throw ToolError.message("接口重定向到其他域名，请更新接口设置") }
                }
                current = next
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ToolError.message("网络请求失败：HTTP \(response.statusCode)")
            }
            return (data, response)
        }
        throw ToolError.message("接口重定向次数过多")
    }

    func json(_ url: URL) async throws -> Any {
        let (data, _) = try await request(url)
        return try JSONSerialization.jsonObject(with: data)
    }

    func plist(_ url: URL, body: Data, headers: [String: String]) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, response) = try await request(url, method: "POST", body: body, headers: headers, appleRedirects: true)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToolError.message("Apple 接口没有返回有效的 plist")
        }
        return (dictionary, response)
    }

    static func encodePlist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    static func appleFailure(_ response: [String: Any]) -> ToolError? {
        let code = plistString(response["failureType"])
        guard !code.isEmpty else { return nil }
        let messages = [
            "2002": "Apple 账号需要重新登录，请检查当前密码。",
            "5002": "Apple 服务暂时不可用，请稍后再试。",
            "2040": "该应用目前无法从 Apple 下载。",
            "2059": "账号没有此应用的下载许可，或该应用不在账号所在地区上架。",
            "1010": "该应用尚未在这个账号所属地区上架。",
            "2034": "Apple 登录已过期，请重新登录。",
            "2042": "Apple 登录已过期，请重新登录。",
            "2019": "付费应用请先通过 App Store 正常购买。",
            "9610": "当前账号没有此应用的下载许可。请先在 App Store 获取应用。"
        ]
        // Raw customerMessage often contains internal localization keys,
        // response codes, or English diagnostic text; never show it in the UI.
        return .message(messages[code] ?? "Apple 暂时无法完成该操作，请稍后重试。")
    }
}
