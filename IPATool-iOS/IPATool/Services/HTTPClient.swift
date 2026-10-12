import Foundation

final class HTTPClient: NSObject, URLSessionTaskDelegate {
    static let shared = HTTPClient()
    static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil,
                 headers: [String: String] = [:], appleRedirects: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme == "https" else { throw ToolError.message("远程接口必须使用 HTTPS") }
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
                guard next.scheme == "https", let host = next.host else { throw ToolError.message("接口返回了不安全的重定向") }
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
        let messages = ["5002": "Apple 服务发生未知错误", "2040": "已购买的应用已下架",
                        "2059": "应用未购买、已下架或不在账号地区上架", "1010": "应用未在账号地区上架",
                        "2034": "登录会话已过期", "2042": "登录会话为空或已过期",
                        "2019": "不支持直接购买付费应用", "9610": "没有应用许可或 App ID 错误"]
        let detail = plistString(response["customerMessage"])
        return .message("\(detail.isEmpty ? messages[code] ?? "Apple 接口错误" : detail)（\(code)）")
    }
}
