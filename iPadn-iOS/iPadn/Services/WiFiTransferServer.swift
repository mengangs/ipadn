import Foundation
import Network
import Security

/// Serves finished packages to a computer on the same Wi-Fi, read-only, only
/// while the Wi-Fi Transfer page is open. The address carries a random
/// 128-bit key; anything else gets a bare 404, and too many wrong guesses
/// stop the server. Only private-network clients are answered.
final class WiFiTransferServer: @unchecked Sendable {
    struct Item: Sendable {
        var id: String
        var name: String
        var version: String
        var filename: String
        var file: URL
        var size: Int64
    }
    struct Access: Sendable, Identifiable {
        var id = UUID()
        var client: String
        var filename: String
        var date: Date
    }

    private let queue = DispatchQueue(label: "iPadn.wifi-transfer")
    private var listener: NWListener?
    private let key: String
    private var items: [Item] = []
    private var misses = 0
    private static let missLimit = 20
    private static let chunk = 256 * 1024
    /// Called on the main actor: a file was requested, or the server stopped.
    var onAccess: (@MainActor (Access) -> Void)?
    var onStop: (@MainActor (String?) -> Void)?

    init() {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        key = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts listening on every interface and returns the port.
    func start(items: [Item]) async throws -> UInt16 {
        self.items = items
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed, let port = listener.port?.rawValue else { return }
                    resumed = true; continuation.resume(returning: port)
                case .failed(let error):
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                    else { self?.stop(reason: error.localizedDescription) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func update(items: [Item]) { queue.async { self.items = items } }

    func stop(reason: String? = nil) {
        queue.async {
            guard let listener = self.listener else { return }
            self.listener = nil
            listener.cancel()
            let stop = self.onStop
            Task { @MainActor in stop?(reason) }
        }
    }

    func url(host: String, port: UInt16) -> URL? {
        URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)/\(key)/")
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard let client = Self.clientAddress(connection.endpoint), Self.isPrivate(client) else {
            connection.cancel(); return
        }
        connection.start(queue: queue)
        read(connection, client: client, buffer: Data())
        // A client that never finishes its request is dropped.
        queue.asyncAfter(deadline: .now() + 30) { if connection.state != .cancelled { connection.cancel() } }
    }

    private func read(_ connection: NWConnection, client: String, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.route(connection, client: client, head: head)
            } else if error != nil || complete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.read(connection, client: client, buffer: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, client: String, head: String) {
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return reply(connection, status: 400) }
        let method = String(parts[0]), target = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        guard method == "GET" || method == "HEAD" else { return reply(connection, status: 405) }
        let segments = target.split(separator: "/").map(String.init)
        guard segments.first == key else {
            misses += 1
            if misses >= Self.missLimit { stop(reason: AppText.text("收到太多错误请求，已停止传输。")) }
            return reply(connection, status: 404)
        }
        if segments.count == 1 {
            let page = Data(html().utf8)
            return reply(connection, status: 200, body: method == "HEAD" ? Data() : page, length: page.count,
                         contentType: "text/html; charset=utf-8")
        }
        guard segments.count == 3, segments[1] == "f", let item = items.first(where: { $0.id == segments[2] }),
              let handle = try? FileHandle(forReadingFrom: item.file) else { return reply(connection, status: 404) }
        let size = (try? FileManager.default.attributesOfItem(atPath: item.file.path)[.size] as? NSNumber)?.int64Value ?? item.size
        let disposition = "attachment; filename=\"\(Self.asciiName(item.filename))\"; filename*=UTF-8''\(item.filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "package.ipa")"
        let header = responseHeader(status: 200, length: Int(size), contentType: "application/octet-stream",
                                    extra: ["Content-Disposition": disposition])
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, method == "GET" else { try? handle.close(); connection.cancel(); return }
            let access = Access(client: client, filename: item.filename, date: Date())
            let report = self.onAccess
            Task { @MainActor in report?(access) }
            self.sendChunks(connection, handle: handle)
        })
    }

    private func sendChunks(_ connection: NWConnection, handle: FileHandle) {
        let data = (try? handle.read(upToCount: Self.chunk)) ?? Data()
        if data.isEmpty {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, self.listener != nil else { try? handle.close(); connection.cancel(); return }
            self.sendChunks(connection, handle: handle)
        })
    }

    private func reply(_ connection: NWConnection, status: Int, body: Data = Data(), length: Int? = nil,
                       contentType: String = "text/plain; charset=utf-8") {
        var data = responseHeader(status: status, length: length ?? body.count, contentType: contentType, extra: [:])
        data.append(body)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func responseHeader(status: Int, length: Int, contentType: String, extra: [String: String]) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        var lines = ["HTTP/1.1 \(status) \(reason)", "Content-Type: \(contentType)", "Content-Length: \(length)",
                     "Connection: close", "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
                     "Referrer-Policy: no-referrer"]
        for (name, value) in extra { lines.append("\(name): \(value)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    // MARK: Page

    private func html() -> String {
        let rows = items.map { item in
            "<tr><td><a href=\"/\(key)/f/\(Self.escape(item.id))\">\(Self.escape(item.name))</a><div class=s>\(Self.escape(item.filename))</div></td>"
                + "<td>\(Self.escape(item.version))</td><td class=r>\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))</td></tr>"
        }.joined()
        let empty = items.isEmpty ? "<p>\(Self.escape(AppText.text("没有已完成的安装包。")))</p>" : ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="robots" content="noindex"><title>iPadn</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;max-width:860px;margin:32px auto;padding:0 16px;color:#111}
        h1{font-size:22px}table{width:100%;border-collapse:collapse}td{padding:10px 6px;border-bottom:1px solid #ddd;vertical-align:top}
        a{color:#0a66d8;text-decoration:none;font-weight:600}.s{color:#777;font-size:12px;margin-top:2px}.r{text-align:right;white-space:nowrap}
        @media(prefers-color-scheme:dark){body{background:#111;color:#eee}td{border-color:#333}a{color:#5aa2ff}}</style></head>
        <body><h1>iPadn</h1><p>\(Self.escape(AppText.text("点按名称下载安装包。关闭 iPadn 的传输页面后，这个地址会失效。")))</p>\(empty)<table>\(rows)</table></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func asciiName(_ name: String) -> String {
        let ascii = name.unicodeScalars.map { $0.isASCII && $0.value >= 32 && $0 != "\"" && $0 != "\\" ? String($0) : "_" }.joined()
        return ascii.isEmpty ? "package.ipa" : ascii
    }

    // MARK: Addresses

    static func clientAddress(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)".split(separator: "%").first.map(String.init)
        case .ipv6(let address): return "\(address)".split(separator: "%").first.map(String.init)
        default: return nil
        }
    }

    /// Private, link-local or unique-local addresses: the same home or office network.
    static func isPrivate(_ address: String) -> Bool {
        let lower = address.lowercased()
        if lower.hasPrefix("::ffff:") { return isPrivate(String(lower.dropFirst(7))) }
        if lower.contains(":") { return lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") }
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }

    /// The device's IPv4 address on Wi-Fi (en0), if connected.
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
