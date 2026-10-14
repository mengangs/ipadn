import XCTest
@testable import iPadn

final class InstallationTests: XCTestCase {
    func testOneTapInstallLinkNestsManifestAndLocalPackageURL() throws {
        let app = StoreApp(id: "1", name: "应用 & Test", bundleID: "test.app", version: "1.2")
        let package = URL(string: "http://127.0.0.1:5123/token/files/key/%E5%BA%94%E7%94%A8.ipa")!
        let link = try ManifestBuilder.externalInstallURL(app: app, packageURL: package)
        XCTAssertEqual(link.scheme, "itms-services")
        let outer = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        XCTAssertEqual(outer.queryItems?.first(where: { $0.name == "action" })?.value, "download-manifest")
        XCTAssertEqual(outer.queryItems?.count, 2, "the manifest URL must not leak into separate parameters")
        let manifest = try XCTUnwrap(URL(string: try XCTUnwrap(outer.queryItems?.first(where: { $0.name == "url" })?.value)))
        XCTAssertEqual(manifest.scheme, "https")
        let inner = try XCTUnwrap(URLComponents(url: manifest, resolvingAgainstBaseURL: false)).queryItems ?? []
        XCTAssertEqual(inner.first(where: { $0.name == "fetchurl" })?.value, package.absoluteString)
        XCTAssertEqual(inner.first(where: { $0.name == "name" })?.value, app.name)
        XCTAssertEqual(inner.first(where: { $0.name == "bundleid" })?.value, "test.app")
        XCTAssertEqual(inner.first(where: { $0.name == "version" })?.value, ManifestBuilder.overwriteVersion)
        XCTAssertThrowsError(try ManifestBuilder.externalInstallURL(
            app: StoreApp(id: "2", name: "x"), packageURL: package))
    }

    func testProxyInstallLinkRequiresHTTPSManifestService() throws {
        let app = StoreApp(id: "1", name: "应用 & <测试>", bundleID: "test.app", version: "1.2")
        let link = try ManifestBuilder.installURL(app: app, filename: "a.ipa", plistServer: "https://example.com/plist")
        XCTAssertEqual(link.scheme, "itms-services")
        let manifest = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value)
        XCTAssertTrue(manifest.hasPrefix("https://example.com/plist?"))
        XCTAssertThrowsError(try ManifestBuilder.installURL(app: app, filename: "a.ipa", plistServer: "http://example.com/a"))
        XCTAssertThrowsError(try ManifestBuilder.installURL(app: app, filename: "a.ipa", plistServer: "https://user:password@example.com/a"))
    }
    /// The one-tap install serves the package from this device over plain
    /// HTTP; installd asks for ranges and HEAD.
    func testLocalServerServesRangedPackage() async throws {
        let server = LoopbackServer()
        try await server.start()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        let bytes = Data((0..<128).map(UInt8.init)); try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fileURL = try server.register(file)
        XCTAssertEqual(fileURL.scheme, "http")
        XCTAssertEqual(fileURL.host, "127.0.0.1")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (whole, response) = try await session.data(from: fileURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(whole, bytes)
        var request = URLRequest(url: fileURL); request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (part, partial) = try await session.data(for: request)
        XCTAssertEqual((partial as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(part, bytes.subdata(in: 10..<20))
        XCTAssertEqual((partial as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/128")
        request.httpMethod = "HEAD"
        let (head, headResponse) = try await session.data(for: request)
        XCTAssertTrue(head.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "10")
        let (_, unauthorized) = try await session.data(from: URL(string: "/data/anything", relativeTo: fileURL)!.absoluteURL)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 404)
    }

    func testOldDeviceCertificateSettingsFallBackToOneTap() throws {
        let legacy = Data(#"{"automaticInstallation": false, "localInstallation": true, "plistServer": ""}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(ToolSettings.self, from: legacy).automaticInstallation)
        let proxy = Data(#"{"automaticInstallation": false, "localInstallation": false, "plistServer": "https://example.com/p"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ToolSettings.self, from: proxy).automaticInstallation)
    }
}
