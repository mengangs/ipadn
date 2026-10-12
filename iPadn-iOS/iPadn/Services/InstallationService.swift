import Foundation

@MainActor
final class InstallationService {
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
    static func installURL(app: StoreApp, filename: String, plistServer: String) throws -> URL {
        guard !app.bundleID.isEmpty, !app.version.isEmpty else {
            throw ToolError.message("安装包缺少 Bundle ID 或版本号")
        }
        guard let remote = URLComponents(string: plistServer.trimmingCharacters(in: .whitespacesAndNewlines)),
              remote.scheme == "https", remote.host != nil, remote.query == nil, remote.fragment == nil else {
            throw ToolError.message("请先在设置中填写自己的 HTTPS 清单服务地址（不含查询参数），或导出到签名工具")
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
