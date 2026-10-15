import XCTest
import Security
@testable import iPadn

final class InstallationTests: XCTestCase {
    func testLocalManifestIsRealPlistAndPreservesURLAndUnicode() throws {
        let app = StoreApp(id: "1", name: "应用 & <测试>", bundleID: "test.app", version: "1.2")
        let package = URL(string: "https://127.0.0.1:4567/token/测试.ipa")!
        let manifest = try ManifestBuilder.manifest(app: app, packageURL: package)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: manifest, options: [], format: nil) as? [String: Any])
        let items = try XCTUnwrap(plist["items"] as? [[String: Any]])
        let metadata = try XCTUnwrap(items.first?["metadata"] as? [String: String])
        XCTAssertEqual(metadata["title"], app.name)
        XCTAssertEqual(metadata["bundle-identifier"], app.bundleID)
        // Announced as newer than anything installed, so an older package can replace it.
        XCTAssertEqual(metadata["bundle-version"], ManifestBuilder.overwriteVersion)
        let assets = try XCTUnwrap(items.first?["assets"] as? [[String: String]])
        XCTAssertEqual(assets.first?["url"], package.absoluteString)
        let installer = try ManifestBuilder.systemURL(manifestURL: package)
        XCTAssertEqual(URLComponents(url: installer, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value, package.absoluteString)
        XCTAssertThrowsError(try ManifestBuilder.manifest(app: app, packageURL: URL(string: "http://127.0.0.1/a.ipa")!))
        XCTAssertThrowsError(try ManifestBuilder.localHost("https://example.com/path"))
        XCTAssertThrowsError(try ManifestBuilder.localHost("a.com?token=x"))
        XCTAssertThrowsError(try ManifestBuilder.installURL(app: app, filename: "a.ipa", plistServer: "https://user:password@example.com/a"))
    }
    func testGeneratedCertificateChainMatchesLocalhostAndProfileContainsOnlyPublicCA() throws {
        let first = try LocalInstallationIdentityFactory.create()
        let second = try LocalInstallationIdentityFactory.create()
        XCTAssertNotEqual(first.rootCertificate, second.rootCertificate)
        XCTAssertNotEqual(first.password, second.password)
        let identity = try InstallationCertificate.importPKCS12(first.pkcs12, password: first.password)
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, first.rootCertificate as CFData))
        func trusted(_ host: String) throws -> Bool {
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates(identity.certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
            let value = try XCTUnwrap(trust)
            SecTrustSetAnchorCertificates(value, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(value, true)
            SecTrustSetNetworkFetchAllowed(value, false)
            return SecTrustEvaluateWithError(value, nil)
        }
        XCTAssertTrue(try trusted("127.0.0.1"))
        XCTAssertTrue(try trusted("localhost"))
        XCTAssertTrue(try trusted(ManifestBuilder.defaultLocalHost))
        XCTAssertTrue(try trusted("app.localtest.me"))
        XCTAssertTrue(try trusted("lvh.me"))
        XCTAssertFalse(try trusted("a.b.localtest.me"))
        XCTAssertFalse(try trusted("example.com"))
        XCTAssertThrowsError(try identity.validate(host: "127.0.0.1"))
        let profile = try first.profile()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: profile, options: [], format: nil) as? [String: Any])
        let payloads = try XCTUnwrap(plist["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payloads.first?["PayloadContent"] as? Data, first.rootCertificate)
        XCTAssertNil(profile.range(of: first.pkcs12))
    }
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

    func testPKCS12KeyDerivationMatchesPublishedVectors() {
        func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
        let smeg = Data([0x0A, 0x58, 0xCF, 0x64, 0x53, 0x0D, 0x82, 0x3F])
        XCTAssertEqual(hex(LocalInstallationIdentityFactory.pkcs12KDF(
            sha256: false, id: 1, password: "smeg", salt: smeg, iterations: 1, length: 24)),
            "8AAAE6297B6CB04642AB5B077851284EB7128F1A2A7FBCA3")
        XCTAssertEqual(hex(LocalInstallationIdentityFactory.pkcs12KDF(
            sha256: false, id: 2, password: "smeg", salt: smeg, iterations: 1, length: 8)), "79993DFE048D3B76")
        let queeg = Data([0x05, 0xDE, 0xC9, 0x59, 0xAC, 0xFF, 0x72, 0xF7])
        XCTAssertEqual(hex(LocalInstallationIdentityFactory.pkcs12KDF(
            sha256: false, id: 1, password: "queeg", salt: queeg, iterations: 1000, length: 24)),
            "ED2034E36328830FF09DF1E1A07DD357185DAC0D4F9EB3D4")
    }
    func testInvalidCertificatePasswordAndUntrustedIdentityAreRejected() throws {
        let identity = try fixture()
        XCTAssertThrowsError(try identity.validate(host: "127.0.0.1"))
        XCTAssertThrowsError(try InstallationCertificate.importPKCS12(Data([1, 2, 3]), password: ""))
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "localhost-test-only", withExtension: "p12"))
        XCTAssertThrowsError(try InstallationCertificate.importPKCS12(Data(contentsOf: url), password: "wrong-password"))
    }
    func testLocalHTTPSActuallyServesManifestAndRangedIPA() async throws {
        let material = try LocalInstallationIdentityFactory.create()
        let identity = try InstallationCertificate.importPKCS12(material.pkcs12, password: material.password)
        let server = LoopbackServer(identity: identity.identity)
        try await server.start()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        let bytes = Data((0..<128).map(UInt8.init)); try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fileURL = try server.register(file)
        let manifest = try ManifestBuilder.manifest(app: StoreApp(id: "1", name: "Local", bundleID: "test.local", version: "1.0"), packageURL: fileURL)
        let manifestURL = try server.register(data: manifest, contentType: "application/xml")
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, material.rootCertificate as CFData))
        let delegate = TestCertificateDelegate(certificates: [root])
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (received, response) = try await session.data(from: manifestURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(received, manifest)
        var request = URLRequest(url: fileURL); request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (part, partial) = try await session.data(for: request)
        XCTAssertEqual((partial as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(part, bytes.subdata(in: 10..<20))
        XCTAssertEqual((partial as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 10-19/128")
        request.httpMethod = "HEAD"
        let (head, headResponse) = try await session.data(for: request)
        XCTAssertTrue(head.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "10")
        let (_, unauthorized) = try await session.data(from: URL(string: "/data/anything", relativeTo: manifestURL)!.absoluteURL)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 404)
    }
    /// The exact server a 本机证书 installation starts: identity plus its
    /// chain and the public host, fetched as installd does.
    func testLocalHTTPSWithChainServesManifestLikeAnInstallation() async throws {
        let material = try LocalInstallationIdentityFactory.create()
        let identity = try InstallationCertificate.importPKCS12(material.pkcs12, password: material.password)
        XCTAssertGreaterThan(identity.certificates.count, 1, "the chain carries the local CA")
        let server = LoopbackServer(identity: identity.identity, certificates: identity.certificates, publicHost: "127.0.0.1")
        try await server.start()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try Data((0..<64).map(UInt8.init)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let packageURL = try server.register(file)
        let manifest = try ManifestBuilder.manifest(app: StoreApp(id: "1", name: "Local", bundleID: "test.local", version: "1.0"), packageURL: packageURL)
        let manifestURL = try server.register(data: manifest, contentType: "application/xml")
        XCTAssertEqual(manifestURL.host, "127.0.0.1")
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, material.rootCertificate as CFData))
        let delegate = TestCertificateDelegate(certificates: [root])
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (received, response) = try await session.data(from: manifestURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(received, manifest)
        InstallLog.shared.beginInstallation()
        let (package, packageResponse) = try await session.data(from: packageURL)
        XCTAssertEqual((packageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(package.count, 64)
        XCTAssertTrue(InstallLog.shared.currentProgress.finished)
    }
    func testManifestNamesIconsAndBrowserPageOpensTheInstallLink() throws {
        let app = StoreApp(id: "1", name: "A \"<b>\" & B", bundleID: "test.icons", version: "1.0")
        let package = URL(string: "https://127.0.0.1.sslip.io:4567/t/files/k/a.ipa")!
        let small = URL(string: "https://127.0.0.1.sslip.io:4567/t/data/s")!, large = URL(string: "https://127.0.0.1.sslip.io:4567/t/data/l")!
        let manifest = try ManifestBuilder.manifest(app: app, packageURL: package, images: (small, large))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: manifest, options: [], format: nil) as? [String: Any])
        let assets = try XCTUnwrap((plist["items"] as? [[String: Any]])?.first?["assets"] as? [[String: String]])
        XCTAssertEqual(assets.map { $0["kind"] }, ["software-package", "display-image", "full-size-image"])
        XCTAssertEqual(assets.map { $0["url"] }, [package.absoluteString, small.absoluteString, large.absoluteString])
        let link = URL(string: "itms-services://?action=download-manifest&url=https%3A%2F%2Fa.example%2Fm")!
        let page = ManifestBuilder.browserPage(installURL: link, name: app.name)
        XCTAssertTrue(page.contains("content=\"0;url=itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fa.example%2Fm\""))
        XCTAssertTrue(page.contains("A &quot;&lt;b&gt;&quot; &amp; B"))
        XCTAssertFalse(page.contains("<b>"))
    }
    func testInstallProgressFollowsThePackageTransfer() {
        let log = InstallLog()
        log.beginInstallation()
        XCTAssertFalse(log.currentProgress.started)
        log.servedManifest()
        XCTAssertTrue(log.currentProgress.readManifest)
        log.packageRequested(size: 200)
        log.packageSent(50)
        XCTAssertEqual(log.currentProgress.fraction, 0.25)
        XCTAssertFalse(log.currentProgress.finished)
        log.packageSent(150)
        XCTAssertTrue(log.currentProgress.finished)
        log.beginInstallation()
        XCTAssertEqual(log.currentProgress, InstallLog.Progress())
    }
    func testLocalHostDefaultsToADomainAndOldAddressesMigrate() throws {
        XCTAssertEqual(ToolSettings().localInstallHost, ManifestBuilder.defaultLocalHost)
        for old in ["127.0.0.1", " localhost ", ""] {
            let data = try JSONSerialization.data(withJSONObject: ["localInstallHost": old])
            XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: data).localInstallHost, ManifestBuilder.defaultLocalHost)
        }
        let custom = try JSONSerialization.data(withJSONObject: ["localInstallHost": "install.example.com"])
        XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: custom).localInstallHost, "install.example.com")
        XCTAssertNoThrow(try ManifestBuilder.localHost(ManifestBuilder.defaultLocalHost))
        XCTAssertTrue(ManifestBuilder.addresses(of: "127.0.0.1").contains("127.0.0.1"))
    }
    private func fixture() throws -> InstallationCertificate.Identity {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "localhost-test-only", withExtension: "p12"))
        return try InstallationCertificate.importPKCS12(Data(contentsOf: url), password: "test-only")
    }
}

/// Test-only trust anchor; production uses the system trust store with no overrides.
private final class TestCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let certificates: [SecCertificate]
    init(certificates: [SecCertificate]) { self.certificates = certificates }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        SecTrustSetAnchorCertificates(trust, certificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { print("Test TLS trust failed:", error?.localizedDescription ?? "unknown"); completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
