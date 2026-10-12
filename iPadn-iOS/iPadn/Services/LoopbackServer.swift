import Foundation
import Network

struct HTTPByteRange: Equatable {
    let start: UInt64
    let end: UInt64
    var count: UInt64 { end - start + 1 }
    static func parse(_ header: String, size: UInt64) throws -> HTTPByteRange {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { throw ToolError.message("无效的 Range 请求") }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ToolError.message("无效的 Range 请求") }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { throw ToolError.message("无效的 Range 请求") }
            return HTTPByteRange(start: size - min(size, suffix), end: size - 1)
        }
        guard let start = UInt64(parts[0]), start < size,
              parts[1].isEmpty || UInt64(parts[1]) != nil else { throw ToolError.message("Range 超出文件范围") }
        let end = parts[1].isEmpty ? size - 1 : min(UInt64(parts[1])!, size - 1)
        guard end >= start else { throw ToolError.message("Range 超出文件范围") }
        return HTTPByteRange(start: start, end: end)
    }
}

/// Only binds loopback. A random path capability protects runtime, proxy, and registered files.
final class LoopbackServer {
    private let queue = DispatchQueue(label: "iPadn.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var registeredFiles: [String: URL] = [:]
    private var compatibilityFiles: [String: URL] = [:]
    private let port: UInt16?
    private let compatibilityMode: Bool
    private let token = UUID().uuidString
    private(set) var baseURL: URL?
    private let upstreams: Set<String> = [
        "https://s.mzstatic.com/sap/setupCert.plist",
        "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy"
    ]

    init(port: UInt16? = nil, compatibilityMode: Bool = false) {
        self.port = port; self.compatibilityMode = compatibilityMode
    }

    func start() async throws {
        if baseURL != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: self.port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    var completed = false
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard !completed, let port = listener.port else { return }
                            completed = true
                            self.baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/")
                            continuation.resume()
                        case .failed(let error):
                            if !completed { completed = true; continuation.resume(throwing: error) }
                            listener.cancel()
                        case .cancelled:
                            if !completed { completed = true; continuation.resume(throwing: ToolError.message("本地资源服务已停止")) }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { connection in
                        connection.start(queue: self.queue)
                        self.read(connection, accumulated: Data())
                        self.queue.asyncAfter(deadline: .now() + 120) { connection.cancel() }
                    }
                    listener.start(queue: self.queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func register(_ url: URL) throws -> URL {
        guard let baseURL = baseURL, url.isFileURL else { throw ToolError.message("本地文件服务未就绪") }
        let key = UUID().uuidString
        lock.lock(); registeredFiles[key] = url
        if compatibilityMode { compatibilityFiles[url.lastPathComponent] = url }
        lock.unlock()
        return baseURL.appendingPathComponent("files").appendingPathComponent(key).appendingPathComponent(url.lastPathComponent)
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, ended, error in
            if error != nil { connection.cancel(); return }
            var buffer = accumulated; if let data = data { buffer.append(data) }
            guard buffer.count <= 2 * 1024 * 1024 else { self.reply(connection, status: 413); return }
            let separator = Data("\r\n\r\n".utf8)
            if let boundary = buffer.range(of: separator),
               let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let first = (lines.first ?? "").split(separator: " ")
                guard first.count == 3 else { self.reply(connection, status: 400); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil else { self.reply(connection, status: 400); return }
                let contentLength = Int(headers["content-length"] ?? "0") ?? -1
                guard contentLength >= 0, contentLength <= 1024 * 1024 else { self.reply(connection, status: 413); return }
                let start = boundary.upperBound
                if buffer.count - start >= contentLength {
                    self.route(connection, method: String(first[0]), target: String(first[1]),
                               headers: headers, body: Data(buffer[start..<(start + contentLength)]))
                    return
                }
            }
            if ended { connection.cancel() } else { self.read(connection, accumulated: buffer) }
        }
    }

    private func route(_ connection: NWConnection, method: String, target: String, headers: [String: String], body: Data) {
        guard let components = URLComponents(string: "http://localhost" + target) else { reply(connection, status: 400); return }
        if compatibilityMode, ["GET", "HEAD"].contains(method), components.path.split(separator: "/").count == 1 {
            let name = String(components.path.dropFirst())
            lock.lock(); let file = compatibilityFiles[name]; lock.unlock()
            if let file = file {
                sendFile(connection, url: file, range: headers["range"], head: method == "HEAD"); return
            }
        }
        guard components.path.hasPrefix("/\(token)/") else { reply(connection, status: 404); return }
        let path = String(components.path.dropFirst(token.count + 2))
        if method == "OPTIONS" { reply(connection, status: 204); return }
        if path == "proxy" {
            guard let address = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  upstreams.contains(address), let url = URL(string: address),
                  (method == "GET" && address.hasSuffix("setupCert.plist")) ||
                  (method == "POST" && address.hasSuffix("/legacy")) else { reply(connection, status: 403); return }
            Task {
                do {
                    let (data, response) = try await HTTPClient.shared.request(url, method: method,
                        body: method == "POST" ? body : nil,
                        headers: ["Content-Type": "application/x-plist"])
                    self.reply(connection, status: response.statusCode, body: data,
                               contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
                } catch { self.reply(connection, status: 502, body: Data("签名上游请求失败".utf8)) }
            }
            return
        }
        guard method == "GET" || method == "HEAD" else { reply(connection, status: 405); return }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "runtime", !parts[1].contains(".."),
           let root = Bundle.main.url(forResource: "SAPRuntime", withExtension: nil),
           ["index.html", "sap-signer.js", "wasm_exec.js", "unicorn_x86.js", "sap.wasm"].contains(parts[1]) {
            sendFile(connection, url: root.appendingPathComponent(parts[1]), range: headers["range"], head: method == "HEAD")
        } else if parts.count == 3, parts[0] == "files" {
            lock.lock(); let file = registeredFiles[parts[1]]; lock.unlock()
            guard let file = file, file.lastPathComponent == parts[2] else { reply(connection, status: 404); return }
            sendFile(connection, url: file, range: headers["range"], head: method == "HEAD")
        } else { reply(connection, status: 404) }
    }

    private func sendFile(_ connection: NWConnection, url: URL, range: String?, head: Bool) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let selected: HTTPByteRange?
            do { selected = try range.map { try HTTPByteRange.parse($0, size: size) } }
            catch { reply(connection, status: 416, extra: ["Content-Range": "bytes */\(size)"]); return }
            let length = selected?.count ?? size
            var extra = ["Accept-Ranges": "bytes"]
            if let selected = selected { extra["Content-Range"] = "bytes \(selected.start)-\(selected.end)/\(size)" }
            let mime = ["html": "text/html; charset=utf-8", "js": "text/javascript", "wasm": "application/wasm", "ipa": "application/octet-stream"][url.pathExtension] ?? "application/octet-stream"
            let header = responseHeader(status: selected == nil ? 200 : 206, length: length, contentType: mime, extra: extra)
            let file = try FileHandle(forReadingFrom: url)
            try file.seek(toOffset: selected?.start ?? 0)
            connection.send(content: header, completion: .contentProcessed { error in
                if error != nil || head { try? file.close(); connection.cancel(); return }
                self.sendChunk(connection, file: file, remaining: length)
            })
        } catch { reply(connection, status: 404) }
    }
    private func sendChunk(_ connection: NWConnection, file: FileHandle, remaining: UInt64) {
        guard remaining > 0 else { try? file.close(); connection.cancel(); return }
        do {
            let chunk = try file.read(upToCount: Int(min(remaining, 262_144))) ?? Data()
            guard !chunk.isEmpty else { try? file.close(); connection.cancel(); return }
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? file.close(); connection.cancel() }
                else { self.sendChunk(connection, file: file, remaining: remaining - UInt64(chunk.count)) }
            })
        } catch { try? file.close(); connection.cancel() }
    }
    private func responseHeader(status: Int, length: UInt64, contentType: String, extra: [String: String]) -> Data {
        let phrases = [200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 416: "Range Not Satisfiable", 502: "Bad Gateway"]
        var header = "HTTP/1.1 \(status) \(phrases[status] ?? "Error")\r\nContent-Length: \(length)\r\nContent-Type: \(contentType)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        extra.forEach { header += "\($0.key): \($0.value)\r\n" }
        header += "\r\n"
        return Data(header.utf8)
    }
    private func reply(_ connection: NWConnection, status: Int, body: Data = Data(), contentType: String = "text/plain; charset=utf-8", extra: [String: String] = [:]) {
        var data = responseHeader(status: status, length: UInt64(body.count), contentType: contentType, extra: extra)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
