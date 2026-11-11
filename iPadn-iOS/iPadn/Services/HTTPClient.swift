import Foundation

/// Recent failed requests for diagnostics: time, host, endpoint name and
/// status only. No query strings, headers, bodies or account details.
enum RequestFailureLog {
    private static let entries = NSLockedValue<[String]>([])
    static func record(_ url: URL?, status: Int? = nil, error: Error? = nil, stage: String? = nil) {
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        var parts = [time]
        if let stage { parts.append("stage=" + stage) }
        if let host = url?.host { parts.append("host=" + host) }
        if let last = url?.lastPathComponent, endpointName(last) { parts.append("endpoint=" + last) }
        if let status { parts.append("http=\(status)") }
        if let error = error as NSError? { parts.append("error=\(error.domain)#\(error.code)") }
        let line = parts.joined(separator: "; ")
        entries.withLock { list in list.append(line); if list.count > 20 { list.removeFirst(list.count - 20) } }
    }
    /// Apple endpoint names (buyProduct, volumeStoreDownloadProduct); never
    /// file names or tokens.
    static func endpointName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 40 && value.allSatisfy { $0.isLetter && $0.isASCII }
    }
    static var text: String { entries.withLock { $0.isEmpty ? "(none)" : $0.joined(separator: "\n") } }
}

final class HTTPClient: Sendable {
    static let shared = HTTPClient()
    static let userAgent = "Configurator/2.21 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    private let session: URLSession

    init(protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        self.session = URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Failures that say nothing about the request itself: a busy Apple
    /// server or a pooled connection the system dropped while the app was
    /// in the background. Worth one or two quiet retries.
    static func isTransient(_ error: Error) -> Bool {
        if let status = error as? HTTPStatusError { return [408, 429, 500, 502, 503, 504].contains(status.code) }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed].contains(ns.code)
    }

    func request(_ url: URL, method: String = "GET", body: Data? = nil,
                 headers: [String: String] = [:], appleRedirects: Bool = false,
                 authentication: Bool = false, allowRedirects: Bool = true,
                 retryTransient: Bool? = nil,
                 refreshHeaders: ((URL) async throws -> [String: String])? = nil) async throws -> (Data, HTTPURLResponse) {
        let retries = (retryTransient ?? (method == "GET")) ? 2 : 0
        var attempt = 0
        while true {
            do {
                return try await requestOnce(url, method: method, body: body, headers: headers, appleRedirects: appleRedirects,
                                             authentication: authentication, allowRedirects: allowRedirects,
                                             refreshHeaders: refreshHeaders)
            } catch {
                guard attempt < retries, Self.isTransient(error), !Task.isCancelled else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
    }

    private func requestOnce(_ url: URL, method: String, body: Data?,
                             headers: [String: String], appleRedirects: Bool,
                             authentication: Bool, allowRedirects: Bool,
                             refreshHeaders: ((URL) async throws -> [String: String])?) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw ToolError.message(AppText.text("链接无效"))
        }
        var current = url
        var activeMethod = method
        var activeBody = body
        var activeHeaders = headers
        let initialHost = url.host?.lowercased()
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.httpMethod = activeMethod; request.httpBody = activeBody
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            activeHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ToolError.message(AppText.text("服务器响应异常，请稍后重试")) }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard allowRedirects else { throw HTTPStatusError(code: response.statusCode) }
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let rawNext = URL(string: location, relativeTo: current)?.absoluteURL,
                      rawNext.scheme?.lowercased() == "https", let host = rawNext.host?.lowercased(),
                      rawNext.user == nil, rawNext.password == nil else {
                    throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
                }
                let next: URL
                if authentication {
                    guard [301, 302, 307, 308].contains(response.statusCode),
                          let normalized = AppleAuthentication.normalizedEndpoint(rawNext) else {
                        throw ToolError.message(AppText.text("Apple 返回的登录地址无效，请稍后重试"))
                    }
                    next = normalized
                } else if appleRedirects {
                    guard host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com") else {
                        throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
                    }
                    next = rawNext
                    if response.statusCode == 303 && activeMethod != "GET" && activeMethod != "HEAD" {
                        activeMethod = "GET"
                        activeBody = nil
                        activeHeaders = activeHeaders.filter { $0.key.lowercased() != "content-type" }
                    }
                } else {
                    guard host == initialHost else { throw ToolError.message(AppText.text("服务器响应异常，请稍后重试")) }
                    next = rawNext
                    if response.statusCode == 303 && activeMethod != "GET" && activeMethod != "HEAD" {
                        activeMethod = "GET"
                        activeBody = nil
                        activeHeaders = activeHeaders.filter { $0.key.lowercased() != "content-type" }
                    }
                }
                if let refreshHeaders {
                    activeHeaders = try await refreshHeaders(next)
                } else if !AppleAuthentication.needsStoreProof(next, method: activeMethod) {
                    activeHeaders = activeHeaders.filter {
                        !["x-apple-amd", "x-apple-amd-m"].contains($0.key.lowercased())
                    }
                }
                current = next
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                RequestFailureLog.record(current, status: response.statusCode)
                throw HTTPStatusError(code: response.statusCode)
            }
            return (data, response)
        }
        throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
    }

    /// One byte range (`"0-99"` or `"-100"`) and its Content-Range. The body
    /// is streamed so a server that ignores Range is dropped before the whole
    /// package is read.
    func range(_ url: URL, _ value: String, limit: Int) async throws -> (Data, String) {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ToolError.message(AppText.text("链接无效")) }
        var current = url
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=" + value, forHTTPHeaderField: "Range")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                bytes.task.cancel(); throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
            }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                bytes.task.cancel()
                // Package downloads may hop between Apple's own CDN hosts.
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL,
                      next.scheme == "https", let host = next.host?.lowercased(), next.user == nil, next.password == nil,
                      host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com") else {
                    throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
                }
                current = next
                continue
            }
            guard response.statusCode == 206, let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
                RequestFailureLog.record(current, status: response.statusCode, stage: "range")
                bytes.task.cancel(); throw HTTPStatusError(code: response.statusCode)
            }
            var data = Data()
            data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { bytes.task.cancel(); throw ToolError.message(AppText.text("服务器响应异常，请稍后重试")) }
            }
            return (data, contentRange)
        }
        throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
    }

    func json(_ url: URL) async throws -> Any {
        let (data, _) = try await request(url)
        return try JSONSerialization.jsonObject(with: data)
    }

    func plist(_ url: URL, body: Data, headers: [String: String], allowRedirects: Bool = true,
               retryTransient: Bool = false,
               refreshHeaders: ((URL) async throws -> [String: String])? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, response) = try await request(url, method: "POST", body: body, headers: headers,
                                                 appleRedirects: allowRedirects, allowRedirects: allowRedirects,
                                                 retryTransient: retryTransient, refreshHeaders: refreshHeaders)
        do {
            let dictionary = try ApplePropertyList.dictionary(data)
            return (dictionary, response)
        } catch {
            if response.statusCode == 200, AppleAuthentication.storeMachineAction(raw: [:], response: response) != nil {
                return ([:], response)
            }
            throw error
        }
    }

    static func encodePlist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    static func appleFailure(_ response: [String: Any]) -> ToolError? {
        let code = plistString(response["failureType"])
        guard !code.isEmpty else { return nil }
        let messages = [
            "2002": AppText.text("Apple 账号需要重新登录，请检查当前密码。"),
            "5002": AppText.text("Apple 服务暂时不可用，请稍后再试。"),
            "2040": AppText.text("该应用目前无法从 Apple 下载。"),
            "-5000": AppText.text("Apple 账号或密码不正确。"),
            "2059": AppText.text("该应用暂时无法下载，请稍后再试。"),
            "1010": AppText.text("该应用尚未在这个账号所属地区上架。"),
            "2034": AppText.text("Apple 登录已过期，请重新登录。"),
            "2042": AppText.text("Apple 登录已过期，请重新登录。"),
            "2019": AppText.text("付费应用请先通过 App Store 正常购买。"),
            "9610": AppText.text("当前账号没有此应用的下载许可。请先在 App Store 获取应用。")
        ]
        // Raw customerMessage often contains internal localization keys,
        // response codes, or English diagnostic text; never show it in the UI.
        return .message(messages[code] ?? AppText.text("Apple 暂时无法完成该操作，请稍后重试。"))
    }
}
