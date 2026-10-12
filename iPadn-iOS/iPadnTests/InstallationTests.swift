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
        let assets = try XCTUnwrap(items.first?["assets"] as? [[String: String]])
        XCTAssertEqual(assets.first?["url"], package.absoluteString)
        let installer = try ManifestBuilder.systemURL(manifestURL: package)
        XCTAssertEqual(URLComponents(url: installer, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value, package.absoluteString)
        XCTAssertThrowsError(try ManifestBuilder.manifest(app: app, packageURL: URL(string: "http://127.0.0.1/a.ipa")!))
        XCTAssertThrowsError(try ManifestBuilder.localHost("https://example.com/path"))
        XCTAssertThrowsError(try ManifestBuilder.localHost("a.com?token=x"))
        XCTAssertThrowsError(try ManifestBuilder.installURL(app: app, filename: "a.ipa", plistServer: "https://user:password@example.com/a"))
    }
    func testInvalidCertificatePasswordAndUntrustedIdentityAreRejected() throws {
        let identity = try fixture()
        XCTAssertThrowsError(try identity.validate(host: "127.0.0.1"))
        XCTAssertThrowsError(try InstallationCertificate.importPKCS12(Data([1, 2, 3]), password: ""))
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "localhost-test-only", withExtension: "p12"))
        XCTAssertThrowsError(try InstallationCertificate.importPKCS12(Data(contentsOf: url), password: "wrong-password"))
    }
    func testLocalHTTPSActuallyServesManifestAndRangedIPA() async throws {
        let identity = try fixture()
        let server = LoopbackServer(identity: identity.identity)
        try await server.start()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        let bytes = Data((0..<128).map(UInt8.init)); try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fileURL = try server.register(file)
        let manifest = try ManifestBuilder.manifest(app: StoreApp(id: "1", name: "Local", bundleID: "test.local", version: "1.0"), packageURL: fileURL)
        let manifestURL = try server.register(data: manifest, contentType: "application/xml")
        let delegate = TestCertificateDelegate(certificates: identity.certificates)
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
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
