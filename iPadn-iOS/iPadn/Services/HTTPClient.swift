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
    /// Strict ASCII allowlist for Apple plist diagnostic metadata (failureType,
    /// jingleDocType, metrics.dialogId). Kept <= 36 chars so safe metadata
    /// never trips DiagnosticRedactor's 40-char opaque-token filter and
    /// free-form server messages can never be logged.
    static func safeDiagnosticToken(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 36 else { return nil }
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else {
            return nil
        }
        return trimmed
    }
    /// Strict signed integer validation for Apple `failureType` codes shown
    /// on unmapped fallback alerts (e.g. `-128`, `5005`).
    static func safeFailureCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 12 else { return nil }
        let digits = trimmed.hasPrefix("-") ? trimmed.dropFirst() : trimmed[...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return trimmed
    }
    /// Records redacted metadata for HTTP 200 Apple plist business failures
    /// (`failureType`, `jingleDocType`, `metrics.dialogId`, non-zero `status`).
    /// Never records `customerMessage`, URLs, headers, cookies, or account data.
    static func recordAppleFailure(_ url: URL?, response: [String: Any], stage: String? = nil) {
        let code = safeDiagnosticToken(plistString(response["failureType"]))
        let doc = safeDiagnosticToken(plistString(response["jingleDocType"]))
        let metrics = response["metrics"] as? [String: Any]
        let dialogID = metrics.flatMap { safeDiagnosticToken(plistString($0["dialogId"])) }
        let statusVal = (response["status"] as? NSNumber)?.intValue
        let nonZeroStatus = statusVal.flatMap { $0 != 0 ? $0 : nil }
        guard code != nil || doc != nil || dialogID != nil || nonZeroStatus != nil else { return }
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        var parts = [time]
        if let stage, let safeStage = safeDiagnosticToken(stage) { parts.append("stage=" + safeStage) }
        if let host = url?.host { parts.append("host=" + host) }
        if let last = url?.lastPathComponent, endpointName(last) { parts.append("endpoint=" + last) }
        if let code { parts.append("code=" + code) }
        if let doc { parts.append("doc=" + doc) }
        if let dialogID { parts.append("dialog=" + dialogID) }
        if let nonZeroStatus { parts.append("status=\(nonZeroStatus)") }
        let line = parts.joined(separator: "; ")
        entries.withLock { list in list.append(line); if list.count > 20 { list.removeFirst(list.count - 20) } }
    }
    static var text: String { entries.withLock { $0.isEmpty ? "(none)" : $0.joined(separator: "\n") } }
}

final class HTTPClient: Sendable {
    static let shared = HTTPClient()
    static let userAgent = "Configurator/2.21 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    private let session: URLSession
    private let sessionDelegate: SessionDelegate

    init(protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let delegate = SessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private final class RangeTransfer: @unchecked Sendable {
        let limit: Int
        let lock = NSLock()
        var data = Data()
        var httpResponse: HTTPURLResponse?
        var failure: Error?
        var completed = false
        var cancelled = false
        var continuation: CheckedContinuation<Void, Never>?

        init(limit: Int) {
            self.limit = limit
        }

        func snapshot() -> (response: HTTPURLResponse?, failure: Error?, data: Data) {
            lock.lock()
            defer { lock.unlock() }
            return (httpResponse, failure, data)
        }
    }

    private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var transfers: [Int: RangeTransfer] = [:]

        func attach(_ transfer: RangeTransfer, to task: URLSessionDataTask,
                    continuation: CheckedContinuation<Void, Never>) {
            let alreadyDone: Bool
            lock.lock()
            transfer.lock.lock()
            alreadyDone = transfer.completed || transfer.cancelled
            if alreadyDone {
                transfer.completed = true
            } else {
                transfers[task.taskIdentifier] = transfer
                transfer.continuation = continuation
            }
            transfer.lock.unlock()
            lock.unlock()
            if alreadyDone {
                continuation.resume()
            } else {
                task.resume()
            }
        }

        func cancel(_ transfer: RangeTransfer, task: URLSessionDataTask) {
            let continuation: CheckedContinuation<Void, Never>?
            lock.lock()
            transfers.removeValue(forKey: task.taskIdentifier)
            transfer.lock.lock()
            transfer.cancelled = true
            if transfer.completed {
                continuation = nil
            } else {
                transfer.completed = true
                continuation = transfer.continuation
                transfer.continuation = nil
            }
            transfer.lock.unlock()
            lock.unlock()
            task.cancel()
            continuation?.resume()
        }

        private func transfer(for taskIdentifier: Int) -> RangeTransfer? {
            lock.lock()
            defer { lock.unlock() }
            return transfers[taskIdentifier]
        }

        private func popTransfer(for taskIdentifier: Int) -> RangeTransfer? {
            lock.lock()
            defer { lock.unlock() }
            return transfers.removeValue(forKey: taskIdentifier)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let transfer = transfer(for: dataTask.taskIdentifier) else {
                completionHandler(.allow)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                transfer.lock.lock()
                transfer.failure = ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
                transfer.lock.unlock()
                completionHandler(.cancel)
                return
            }
            transfer.lock.lock()
            transfer.httpResponse = http
            let status = http.statusCode
            if [301, 302, 303, 307, 308].contains(status) {
                transfer.lock.unlock()
                completionHandler(.cancel)
                return
            }
            guard status == 206, http.value(forHTTPHeaderField: "Content-Range") != nil else {
                transfer.failure = HTTPStatusError(code: status)
                transfer.lock.unlock()
                RequestFailureLog.record(http.url, status: status, stage: "range")
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > Int64(transfer.limit) {
                transfer.failure = ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
                transfer.lock.unlock()
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > 0 {
                transfer.data.reserveCapacity(min(transfer.limit, Int(http.expectedContentLength)))
            }
            transfer.lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard let transfer = transfer(for: dataTask.taskIdentifier) else { return }
            transfer.lock.lock()
            if transfer.data.count + chunk.count > transfer.limit {
                transfer.failure = ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
                transfer.lock.unlock()
                dataTask.cancel()
                return
            }
            transfer.data.append(chunk)
            transfer.lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let transfer = popTransfer(for: task.taskIdentifier) else { return }
            transfer.lock.lock()
            if transfer.failure == nil, let error {
                transfer.failure = error
            }
            transfer.completed = true
            let continuation = transfer.continuation
            transfer.continuation = nil
            transfer.lock.unlock()
            continuation?.resume()
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
                 retryTransient: Bool? = nil, timeoutInterval: TimeInterval? = nil,
                 refreshHeaders: ((URL) async throws -> [String: String])? = nil) async throws -> (Data, HTTPURLResponse) {
        let retries = (retryTransient ?? (method == "GET")) ? 2 : 0
        var attempt = 0
        var currentHeaders = headers
        while true {
            do {
                return try await requestOnce(url, method: method, body: body, headers: currentHeaders, appleRedirects: appleRedirects,
                                             authentication: authentication, allowRedirects: allowRedirects,
                                             timeoutInterval: timeoutInterval, refreshHeaders: refreshHeaders)
            } catch {
                guard attempt < retries, Self.isTransient(error), !Task.isCancelled else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                if let refreshHeaders {
                    currentHeaders = try await refreshHeaders(url)
                }
            }
        }
    }

    private func requestOnce(_ url: URL, method: String, body: Data?,
                             headers: [String: String], appleRedirects: Bool,
                             authentication: Bool, allowRedirects: Bool,
                             timeoutInterval: TimeInterval?,
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
            if let timeoutInterval { request.timeoutInterval = timeoutInterval }
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

    /// Executes a single HTTPS request without automatic redirect following or status-code
    /// throwing, so callers that need `Location`, `pod`, or `Set-Cookie` on 302 hops
    /// (such as Apple's commerce purchase history endpoint) can drive redirects directly.
    func rawRequest(_ url: URL, method: String = "GET",
                    headers: [String: String] = [:],
                    timeoutInterval: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw ToolError.message(AppText.text("链接无效"))
        }
        var request = URLRequest(url: url)
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
        }
        return (data, http)
    }

    /// One byte range (`"0-99"` or `"-100"`) and its Content-Range. The body
    /// is streamed in chunks via `URLSessionDataDelegate` so a server that
    /// ignores Range or exceeds `limit` is aborted without byte-by-byte overhead.
    func range(_ url: URL, _ value: String, limit: Int, timeoutInterval: TimeInterval = 15) async throws -> (Data, String) {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ToolError.message(AppText.text("链接无效")) }
        var current = url
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.timeoutInterval = timeoutInterval
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=" + value, forHTTPHeaderField: "Range")
            let transfer = RangeTransfer(limit: limit)
            let task = session.dataTask(with: request)
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    sessionDelegate.attach(transfer, to: task, continuation: continuation)
                }
            } onCancel: {
                sessionDelegate.cancel(transfer, task: task)
            }
            try Task.checkCancellation()
            let (response, failure, body) = transfer.snapshot()
            if let response, [301, 302, 303, 307, 308].contains(response.statusCode) {
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
            if let failure { throw failure }
            guard let response, response.statusCode == 206, let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
                throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
            }
            return (body, contentRange)
        }
        throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
    }

    func json(_ url: URL, timeoutInterval: TimeInterval? = nil, retryTransient: Bool? = nil) async throws -> Any {
        let (data, _) = try await request(url, retryTransient: retryTransient, timeoutInterval: timeoutInterval)
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
        let customerMessage = plistString(response["customerMessage"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if customerMessage == "Your account is disabled." {
            return .message(AppText.text("此 Apple 账号已被停用，请先在 Apple 官网或系统设置中恢复后再试。"))
        }
        if customerMessage == "Your password has changed." {
            return .message(AppText.text("Apple 账号密码已更改，请重新登录。"))
        }
        guard !code.isEmpty else { return nil }
        let messages = [
            "1008": AppText.text("Apple 登录已过期，请重新登录。"),
            "2002": AppText.text("Apple 账号需要重新登录，请检查当前密码。"),
            "5002": AppText.text("Apple 服务暂时不可用，请稍后再试。"),
            "5020": AppText.text("Apple 账号、密码或验证码有误；若确认无误，请先在系统 App Store 检查账号状态后重试。"),
            "2040": AppText.text("该应用目前无法从 Apple 下载。"),
            "-5000": AppText.text("Apple 账号或密码不正确。"),
            "2059": AppText.text("该应用暂时无法下载，请稍后再试。"),
            "1010": AppText.text("该应用尚未在这个账号所属地区上架。"),
            "2034": AppText.text("Apple 登录已过期，请重新登录。"),
            "2042": AppText.text("Apple 登录已过期，请重新登录。"),
            "2019": AppText.text("付费应用请先通过 App Store 正常购买。"),
            "9610": AppText.text("当前账号没有此应用的下载许可。请先在 App Store 获取应用。")
        ]
        if let mapped = messages[code] {
            return .message(mapped)
        }
        // Raw customerMessage often contains internal localization keys,
        // response codes, or English diagnostic text; never show it in the UI.
        // For unmapped failures, surface only a strictly validated numeric code
        // so reports identify the Apple rejection without leaking server text.
        if let numericCode = RequestFailureLog.safeFailureCode(code) {
            return .message(AppText.text("Apple 暂时无法完成该操作，请稍后重试（代码 \(numericCode)）。"))
        }
        return .message(AppText.text("Apple 暂时无法完成该操作，请稍后重试。"))
    }
}
