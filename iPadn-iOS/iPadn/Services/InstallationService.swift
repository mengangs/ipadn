import Foundation
import UIKit
import Combine

@MainActor
final class InstallationService: ObservableObject {
    @Published private(set) var isHosting = false
    // Servers of recent installs stay up together: installd may come back to
    // an earlier one (retry, ranged request) after another install starts.
    private var hosted: [LoopbackServer] = []
    private var profileFiles: LoopbackServer?
    /// The server of the latest install link, which also serves its Safari page.
    private weak var installServer: LoopbackServer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func stopHosting() {
        hosted = []; profileFiles = nil; isHosting = false
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func keepHosting(_ server: LoopbackServer) {
        hosted.append(server); installServer = server
        if hosted.count > 3 { hosted.removeFirst(hosted.count - 3) }
        isHosting = true
        keepServingInBackground()
    }
    /// installd fetches the package after iPadn goes to the background; ask
    /// for time to keep serving. Ended inside the handler, as UIKit requires.
    private func keepServingInBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "iPadn installation") { [weak self] in
            MainActor.assumeIsolated { self?.stopHosting() }
        }
    }
    func profileURL(data: Data) async throws -> URL {
        let server = LoopbackServer()
        try await server.start()
        let url = try server.register(data: data, contentType: "application/x-apple-aspen-config")
        profileFiles = server
        keepServingInBackground()
        return url
    }
    /// One-tap installation. installd only requires the *manifest* to be
    /// HTTPS; the package itself may come over plain HTTP. The IPA is served
    /// from this device on 127.0.0.1 and a public manifest generator returns
    /// a manifest pointing at it, so no certificate, profile or server setup
    /// is needed. Only name, bundle ID, version and the local URL leave the
    /// device; the IPA never does.
    func automaticInstallURL(job: DownloadJob, file: URL) async throws -> URL {
        let server = LoopbackServer()
        try await server.start()
        let packageURL = try server.register(file)
        let url = try ManifestBuilder.externalInstallURL(app: job.app, packageURL: packageURL)
        keepHosting(server)
        return url
    }

    func localInstallURL(job: DownloadJob, file: URL, host: String, icon: URL? = nil) async throws -> URL {
        let host = try ManifestBuilder.localHost(host)
        guard let certificate = try InstallationCertificate.load() else {
            throw ToolError.message("请先在安装方式中创建证书")
        }
        do { try await certificate.validateAsync(host: host) }
        catch InstallationCertificate.CheckFailure.outdated where (try? InstallationCertificate.localProfile()) != nil {
            // Made by an earlier iPadn that didn't cover this address.
            throw ToolError.message("证书需要更新。请在「安装设置」中重新创建证书，并安装、信任新的描述文件。")
        }
        // The server listens on 127.0.0.1; any other answer (no network, or a
        // proxy app that answers DNS itself) means the system can't reach it.
        // Fallbacks are used only when the certificate covers them too.
        var candidates = host == ManifestBuilder.defaultLocalHost
            ? ManifestBuilder.fallbackLocalHosts.filter { $0 == host || (try? certificate.validate(host: $0)) != nil }
            : [host]
        // With a proxy or VPN on, public names go through it; ipadn.local is
        // answered on this device and proxy apps leave *.local alone.
        let proxied = LocalHostRecord.proxyOrVPNActive
        let coversLocal = (try? certificate.validate(host: LocalHostRecord.host)) != nil
        InstallLog.shared.add("proxy or VPN: \(proxied ? "on" : "off"), certificate covers ipadn.local: \(coversLocal)")
        if proxied, coversLocal, host == ManifestBuilder.defaultLocalHost, LocalHostRecord.shared.publish() {
            candidates.insert(LocalHostRecord.host, at: 0)
        }
        guard let reachable = await ManifestBuilder.firstLoopbackHost(candidates) else {
            if proxied && !coversLocal && (try? InstallationCertificate.localProfile()) != nil {
                throw ToolError.message("开启代理或 VPN 时安装需要新版证书。请在「安装设置」中重新创建证书，并安装、信任新的描述文件；也可以暂时关闭代理后重试。")
            }
            throw ToolError.message("当前网络下无法连接本机安装服务。如果开启了代理或 VPN，请为 \(host) 添加直连规则，或关闭后重试；也可以改用一键安装。")
        }
        let server = LoopbackServer(identity: certificate.identity, certificates: certificate.certificates, publicHost: reachable)
        try await server.start()
        let packageURL = try server.register(file)
        // The home screen shows these while the app installs.
        var images: (small: URL, large: URL)?
        if let icon = await Self.iconImages(icon) {
            images = try (server.register(data: icon.small, contentType: "image/png"),
                          server.register(data: icon.large, contentType: "image/png"))
        }
        let data = try ManifestBuilder.manifest(app: job.app, packageURL: packageURL, images: images)
        let manifestURL = try server.register(data: data, contentType: "application/xml")
        InstallLog.shared.add("local install link created (host \(reachable), port \(manifestURL.port ?? 0), chain \(certificate.certificates.count))")
        keepHosting(server)
        return try ManifestBuilder.systemURL(manifestURL: manifestURL)
    }

    /// The app icon as the two PNG sizes an install manifest names, or nil
    /// when there is no icon or it can't be loaded quickly.
    private static func iconImages(_ url: URL?) async -> (small: Data, large: Data)? {
        guard let url else { return nil }
        var data: Data?
        if url.isFileURL { data = try? Data(contentsOf: url) }
        else if url.scheme == "https" { data = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)).0 }
        guard let data, let image = UIImage(data: data) else { return nil }
        func png(_ side: CGFloat) -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
        return (png(57), png(512))
    }

    /// A page on this device that opens `installURL`, for installing from
    /// Safari when the install prompt doesn't appear from iPadn itself.
    func browserPage(installURL: URL, app: StoreApp) throws -> URL {
        guard let server = installServer, server.baseURL != nil else {
            throw ToolError.message("安装服务未就绪，请重试")
        }
        let page = Data(ManifestBuilder.browserPage(installURL: installURL, name: app.name.isEmpty ? app.bundleID : app.name).utf8)
        let url = try server.register(data: page, contentType: "text/html; charset=utf-8")
        InstallLog.shared.add("browser install page created")
        return url
    }

    // Original Surge/Loon rules expect http://127.0.0.1:8000/<filename>.
    private let files = LoopbackServer(port: 8000, compatibilityMode: true)

    func installURL(job: DownloadJob, file: URL, plistServer: String) async throws -> URL {
        let url = try ManifestBuilder.installURL(app: job.app, filename: file.lastPathComponent, plistServer: plistServer)
        try await files.start()
        _ = try files.register(file)
        installServer = files
        keepServingInBackground()
        return url
    }

    func localURL(file: URL) async throws -> URL {
        try await files.start()
        let url = try files.register(file)
        keepServingInBackground()
        return url
    }
}

enum ManifestBuilder {
    /// The version the install link announces. iOS only replaces an
    /// installed app when the link names a newer version, so installing an
    /// older (or the same) package over it would silently do nothing. The
    /// package itself is installed as is and the app's data is kept.
    static let overwriteVersion = "99999"
    /// The installer does not open install links whose host is an IP
    /// address or "localhost". These public names resolve to 127.0.0.1, so
    /// the link carries a real domain while the connection stays on this
    /// device. The generated certificate covers all of them.
    /// The install prompt names this host ("ipadn.localtest.me 想要安装…").
    static let defaultLocalHost = "ipadn.localtest.me"
    /// Tried in order when the default is set: the first that resolves to
    /// this device on the current network is used.
    static let fallbackLocalHosts = [defaultLocalHost, "ipadn.lvh.me", "127.0.0.1.sslip.io"]
    static let localHostNames = ["127.0.0.1.sslip.io", "localtest.me", "*.localtest.me", "lvh.me", "*.lvh.me", "localhost", LocalHostRecord.host]
    /// Hosts that earlier versions used; they are replaced by the default.
    static func migratedLocalHost(_ value: String) -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["", "127.0.0.1", "localhost", "127.0.0.1.sslip.io"].contains(host) ? defaultLocalHost : value
    }
    /// The first of `hosts` (in order) that resolves to this device. The
    /// lookups run side by side and give up after `timeout`, so a network
    /// with broken DNS can't hold the install up.
    static func firstLoopbackHost(_ hosts: [String], timeout: TimeInterval = 3) async -> String? {
        guard !hosts.isEmpty else { return nil }
        final class Race: @unchecked Sendable {
            private let lock = NSLock()
            private var answers: [Bool?]
            private var continuation: CheckedContinuation<String?, Never>?
            private let hosts: [String]
            init(_ hosts: [String], _ continuation: CheckedContinuation<String?, Never>) {
                self.hosts = hosts; answers = Array(repeating: nil, count: hosts.count); self.continuation = continuation
            }
            func record(_ index: Int, loopback: Bool) {
                lock.lock(); answers[index] = loopback
                // Decided once every host before the first loopback one has answered.
                let decided = answers.firstIndex { $0 != false }
                if decided == nil { finishLocked(nil) }
                else if let decided, answers[decided] == true { finishLocked(hosts[decided]) }
                lock.unlock()
            }
            func timeOut() {
                lock.lock(); finishLocked(answers.firstIndex { $0 == true }.map { hosts[$0] }); lock.unlock()
            }
            private func finishLocked(_ host: String?) { continuation?.resume(returning: host); continuation = nil }
        }
        return await withCheckedContinuation { continuation in
            let race = Race(hosts, continuation)
            for (index, host) in hosts.enumerated() {
                DispatchQueue.global(qos: .userInitiated).async {
                    let addresses = ManifestBuilder.addresses(of: host)
                    InstallLog.shared.add("\(host) resolves to \(addresses.isEmpty ? "nothing" : addresses.joined(separator: ", "))")
                    race.record(index, loopback: addresses.contains { $0.hasPrefix("127.") })
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { race.timeOut() }
        }
    }
    /// Numeric addresses the system resolves `host` to.
    static func addresses(of host: String) -> [String] {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
        }
        return addresses
    }
    static func localHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.utf8.count <= 253, !host.contains(".."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !host.hasPrefix("-"), !host.hasSuffix("-") else {
            throw ToolError.message("请填写有效的服务器地址")
        }
        return host
    }
    static func manifest(app: StoreApp, packageURL: URL, images: (small: URL, large: URL)? = nil) throws -> Data {
        guard !app.bundleID.isEmpty, !app.version.isEmpty, packageURL.scheme == "https",
              packageURL.host != nil, packageURL.user == nil, packageURL.password == nil else {
            throw ToolError.message("无法生成安装链接")
        }
        var assets = [["kind": "software-package", "url": packageURL.absoluteString]]
        if let images {
            assets.append(["kind": "display-image", "url": images.small.absoluteString])
            assets.append(["kind": "full-size-image", "url": images.large.absoluteString])
        }
        return try PropertyListSerialization.data(fromPropertyList: ["items": [[
            "assets": assets,
            "metadata": ["bundle-identifier": app.bundleID, "bundle-version": overwriteVersion,
                         "kind": "software", "title": app.name]
        ]]], format: .xml, options: 0)
    }
    static let manifestGenerator = "https://api.palera.in/genPlist"

    /// Opens the install link as soon as Safari loads it, with a button in
    /// case Safari asks first.
    static func browserPage(installURL: URL, name: String) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        let link = escape(installURL.absoluteString), title = escape(name)
        return """
        <!doctype html><html lang="zh-Hans"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="refresh" content="0;url=\(link)"><title>安装 \(title)</title>
        <style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,system-ui;background:#f2f2f7;color:#000}
        main{text-align:center;padding:24px;max-width:420px}p{color:#6e6e73;line-height:1.5}
        a{display:inline-block;margin-top:12px;padding:12px 40px;border-radius:999px;background:#007aff;color:#fff;font-weight:600;text-decoration:none}
        @media(prefers-color-scheme:dark){body{background:#000;color:#fff}p{color:#98989d}}</style></head>
        <body><main><h2>\(title)</h2><p>如果没有出现安装提示，请点按下方按钮。确认安装后请回到 iPadn，等待安装完成。</p>
        <a href="\(link)">安装</a></main></body></html>
        """
    }

    /// RFC 3986 unreserved characters only (ASCII), so '&', '=' and non-ASCII
    /// text survive being nested inside another URL's query.
    private static let strictQuery = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func externalInstallURL(app: StoreApp, packageURL: URL) throws -> URL {
        guard !app.bundleID.isEmpty, !app.version.isEmpty else {
            throw ToolError.message("安装包信息不完整，无法安装")
        }
        guard let scheme = packageURL.scheme, ["http", "https"].contains(scheme),
              packageURL.host != nil, packageURL.user == nil, packageURL.password == nil else {
            throw ToolError.message("无法生成安装链接")
        }
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: strictQuery) ?? "" }
        let query = [("bundleid", app.bundleID), ("name", app.name.isEmpty ? app.bundleID : app.name),
                     ("version", overwriteVersion), ("fetchurl", packageURL.absoluteString)]
            .map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        guard let manifest = URL(string: manifestGenerator + "?" + query),
              let url = URL(string: "itms-services://?action=download-manifest&url=" + encode(manifest.absoluteString)) else {
            throw ToolError.message("无法生成安装链接")
        }
        return url
    }

    static func systemURL(manifestURL: URL) throws -> URL {
        guard manifestURL.scheme == "https", manifestURL.host != nil, manifestURL.user == nil, manifestURL.password == nil else {
            throw ToolError.message("清单服务地址需以 https 开头")
        }
        var installer = URLComponents()
        installer.scheme = "itms-services"; installer.host = ""
        installer.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: manifestURL.absoluteString)]
        guard let url = installer.url else { throw ToolError.message("无法生成安装链接") }
        return url
    }

    static func installURL(app: StoreApp, filename: String, plistServer: String) throws -> URL {
        guard !app.bundleID.isEmpty, !app.version.isEmpty else {
            throw ToolError.message("安装包信息不完整，无法安装")
        }
        guard let remote = URLComponents(string: plistServer.trimmingCharacters(in: .whitespacesAndNewlines)),
              remote.scheme == "https", remote.host != nil, remote.user == nil, remote.password == nil, remote.query == nil, remote.fragment == nil else {
            throw ToolError.message("请先在安装方式中填写清单服务地址")
        }
        var metadata = URLComponents()
        metadata.queryItems = [
            URLQueryItem(name: "name", value: app.name), URLQueryItem(name: "bundleId", value: app.bundleID),
            URLQueryItem(name: "displayVersion", value: overwriteVersion), URLQueryItem(name: "fileName", value: filename)
        ]
        // Preserve the original service contract: the entire metadata query is URL-encoded once.
        let query = metadata.percentEncodedQuery ?? ""
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=?+#%")
        let wrapped = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let manifest = (remote.string ?? plistServer) + "?" + wrapped
        var installer = URLComponents()
        installer.scheme = "itms-services"
        installer.host = ""
        installer.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: manifest)]
        guard let url = installer.url else { throw ToolError.message("无法生成安装链接") }
        return url
    }

}
