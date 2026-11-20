import Foundation

/// Per-account cookie jars, stored as files and swapped on account switch.
///
/// Why not `HTTPCookieStorage.shared` alone: the shared jar is process-wide and keyed by
/// domain, so two Apple accounts overwrite each other, and a context built from it can
/// carry account A's `mz_at_ssl` into account B's request (401 / code 102). The snapshot is
/// written from the auth response's own `Set-Cookie` pairs, never re-read from the shared
/// jar, and `cookies(for:)` is the only read point.
public enum AccountScope {
    private static let lock = NSLock()

    /// Group container when the signing grants one, otherwise the app's own
    /// Application Support (never Documents: a downgraded jar must not sit next to
    /// user-visible files), created with the strongest protection level that still works
    /// before first unlock.
    public static func directory() -> URL {
        if let resolved = SigningCapability.resolved {
            let root = resolved.url.appendingPathComponent("tf-jars", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? setProtection(root)
            if !didLogGroup {
                didLogGroup = true
                TFLog.append("jar: 使用已授权分组 " + resolved.identifier)
            }
            return root
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("tf-jars", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? setProtection(root)
        if !didLogFallback {
            didLogFallback = true
            TFLog.append("jar: 降级到 Application Support（签名无 App Group）")
        }
        return root
    }

    private static func setProtection(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    nonisolated(unsafe) private static var didLogGroup = false
    nonisolated(unsafe) private static var didLogFallback = false

    public static func snapshotURL(dsid: String) -> URL {
        directory().appendingPathComponent(dsid + ".json")
    }

    /// Persists the cookies of one account, taken from the auth response's `Set-Cookie`.
    public static func store(dsid: String, wireCookies: [String: String],
                             log: @escaping @Sendable (String) -> Void) throws {
        let cookies = try StoreContextBuilder.whitelist(wireCookies, dsid: dsid, log: log)
        try StoreContextBuilder.assertSigned(cookies, dsid: dsid)
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONSerialization.data(withJSONObject: cookies, options: [.sortedKeys])
        try data.write(to: snapshotURL(dsid: dsid), options: .atomic)
        log("jar: 写入 …" + String(dsid.suffix(4)) + " 快照 " + String(data.count) + " B（" + String(cookies.count) + " 个 cookie）")
    }

    /// The only read point. Missing snapshot means "this account never logged in here".
    public static func cookies(for dsid: String) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: snapshotURL(dsid: dsid)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return payload
    }

    /// Switch: write the current jar back to its own snapshot, clear the shared jar, then
    /// load the target account's snapshot into it.
    public static func activate(dsid: String, currentDsid: String? = nil,
                                log: @escaping @Sendable (String) -> Void) {
        if let currentDsid, currentDsid != dsid {
            writeBack(dsid: currentDsid)
        }
        clearAppleCookies()
        guard let cookies = cookies(for: dsid) else {
            log("jar: " + String(dsid.suffix(4)) + " 无快照，按全新登录处理")
            return
        }
        load(cookies)
        log("jar: 载入 " + String(dsid.suffix(4)) + " 快照 " + String(cookies.count) + " 个 cookie")
        inventory(log: log)
    }

    /// Snapshot of whatever the shared jar holds right now, for this dsid only.
    public static func writeBack(dsid: String) {
        var cookies: [String: String] = [:]
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("apple.com") {
            let isOurs = cookie.name == "X-Dsid"
                ? cookie.value == dsid
                : TFLogin.cookieBelongs(cookie.name, dsid: dsid)
            if isOurs, !cookie.value.isEmpty { cookies[cookie.name] = cookie.value }
        }
        guard !cookies.isEmpty,
              let filtered = try? StoreContextBuilder.whitelist(cookies, dsid: dsid, log: { _ in }) else { return }
        if let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]) {
            try? data.write(to: snapshotURL(dsid: dsid), options: .atomic)
        }
    }

    static func clearAppleCookies() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.contains("apple.com") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    static func load(_ cookies: [String: String]) {
        for (name, value) in cookies {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: ".apple.com", .path: "/",
                .secure: "TRUE", .expires: Date().addingTimeInterval(86_400),
            ]
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }
    /// Names and sizes only, so a regression can prove the other account's snapshot did not
    /// move. Cookie values never appear.
    public static func inventory(log: @escaping @Sendable (String) -> Void) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory().path) else { return }
        var parts: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let path = directory().appendingPathComponent(name).path
            let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let raw = name.replacingOccurrences(of: ".json", with: "")
            let label = raw.count > 4 ? ("…" + String(raw.suffix(4))) : raw
            parts.append(label + "=" + String(size) + "B")
        }
        log("jar: 快照清单 " + (parts.isEmpty ? "空" : parts.joined(separator: " ")))
    }
}
