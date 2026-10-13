import Foundation
import UIKit
import Combine

@MainActor
final class InstallationService: ObservableObject {
    @Published private(set) var isHosting = false
    private var localFiles: LoopbackServer?
    private var profileFiles: LoopbackServer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func stopHosting() {
        localFiles = nil; profileFiles = nil; isHosting = false
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func profileURL(data: Data) async throws -> URL {
        let server = LoopbackServer()
        try await server.start()
        let url = try server.register(data: data, contentType: "application/x-apple-aspen-config")
        profileFiles = server
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "iPadn local certificate") { [weak self] in
                Task { @MainActor in self?.stopHosting() }
            }
        }
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
        stopHosting(); localFiles = server; isHosting = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "iPadn installation") { [weak self] in
            Task { @MainActor in self?.stopHosting() }
        }
        return url
    }

    func localInstallURL(job: DownloadJob, file: URL, host: String) async throws -> URL {
        let host = try ManifestBuilder.localHost(host)
        guard let certificate = try InstallationCertificate.load() else {
            throw ToolError.message("请先在安装方式中创建证书")
        }
        try await certificate.validateAsync(host: host)
        let server = LoopbackServer(identity: certificate.identity, certificates: certificate.certificates, publicHost: host)
        try await server.start()
        let packageURL = try server.register(file)
        let data = try ManifestBuilder.manifest(app: job.app, packageURL: packageURL)
        let manifestURL = try server.register(data: data, contentType: "application/xml")
        stopHosting(); localFiles = server; isHosting = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "iPadn installation") { [weak self] in
            Task { @MainActor in self?.stopHosting() }
        }
        return try ManifestBuilder.systemURL(manifestURL: manifestURL)
    }

    // Original Surge/Loon rules expect http://127.0.0.1:8000/<filename>.
    private let files = LoopbackServer(port: 8000, compatibilityMode: true)

    func installURL(job: DownloadJob, file: URL, plistServer: String) async throws -> URL {
        let url = try ManifestBuilder.installURL(app: job.app, filename: file.lastPathComponent, plistServer: plistServer)
        try await files.start()
        _ = try files.register(file)
        return url
    }

    func localURL(file: URL) async throws -> URL {
        try await files.start()
        return try files.register(file)
    }
}

enum ManifestBuilder {
    static func localHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.utf8.count <= 253, !host.contains(".."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !host.hasPrefix("-"), !host.hasSuffix("-") else {
            throw ToolError.message("请填写有效的服务器地址")
        }
        return host
    }
    static func manifest(app: StoreApp, packageURL: URL) throws -> Data {
        guard !app.bundleID.isEmpty, !app.version.isEmpty, packageURL.scheme == "https",
              packageURL.host != nil, packageURL.user == nil, packageURL.password == nil else {
            throw ToolError.message("无法生成安装链接")
        }
        return try PropertyListSerialization.data(fromPropertyList: ["items": [[
            "assets": [["kind": "software-package", "url": packageURL.absoluteString]],
            "metadata": ["bundle-identifier": app.bundleID, "bundle-version": app.version,
                         "kind": "software", "title": app.name]
        ]]], format: .xml, options: 0)
    }
    static let manifestGenerator = "https://api.palera.in/genPlist"

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
                     ("version", app.version), ("fetchurl", packageURL.absoluteString)]
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
            URLQueryItem(name: "displayVersion", value: app.version), URLQueryItem(name: "fileName", value: filename)
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
