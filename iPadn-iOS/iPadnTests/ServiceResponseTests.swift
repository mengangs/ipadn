import XCTest
@testable import iPadn

@MainActor
final class ServiceResponseTests: XCTestCase {
    /// Reduced from the public Apple response captured on 2026-11-08. Both
    /// the Document/Protocol envelope and the flat bag differ from the old mocks.
    private let bag = Data(#"""
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <Document xmlns="http://www.apple.com/itms/">
    <Protocol>
    <plist version="1.0"><dict>
    <key>authenticateAccount</key><string>https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate</string>
    <key>sign-sap-version</key><integer>200</integer>
    <key>afds-enabled</key><true/>
    <key>ampMusicAPIDomains</key><dict><key>catalog</key><string>amp-api-edge.music.apple.com</string></dict>
    </dict></plist></Protocol></Document>
    """#.utf8)

    func testActualAppleEnvelopeAndFlatBag() throws {
        XCTAssertThrowsError(try PropertyListSerialization.propertyList(from: bag, format: nil), "Reproduces NSCocoaErrorDomain 3840 in 1.7.4")
        let raw = try ApplePropertyList.dictionary(bag)
        XCTAssertEqual(raw["sign-sap-version"] as? Int, 200)
        XCTAssertEqual(raw["afds-enabled"] as? Bool, true)
        XCTAssertNotNil(raw["ampMusicAPIDomains"] as? [String: Any])
        XCTAssertEqual(try AppleAuthentication.endpoint(from: bag).absoluteString,
            "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/")
    }

    func testStandardAndBinaryBagsStillWork() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["urlBag": ["authenticateAccount":
                "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"]], format: format, options: 0)
            XCTAssertEqual(try AppleAuthentication.endpoint(from: data).host, "p25-buy.itunes.apple.com")
        }
    }

    func testWrappedLoginChallengeAndCredentialData() throws {
        let xml = #"<Document xmlns="http://www.apple.com/itms/"><key>customerMessage</key><string>MZFinance.BadLogin.Configurator_message</string><key>failureType</key><string></string></Document>"#
        let raw = try ApplePropertyList.dictionary(Data(xml.utf8))
        guard case .verificationRequired? = AppleLoginResponse.failure(raw, submittedCode: false) as? AppleLoginError else {
            return XCTFail("Document-wrapped 2FA must reach the existing challenge handler")
        }
        let data = Data(#"<Document><Protocol><dict><key>passwordToken</key><string>a&amp;b&lt;c&gt;</string><key>blob</key><data>YWJj</data><key>ids</key><array><integer>42</integer></array></dict></Protocol></Document>"#.utf8)
        let credentials = try ApplePropertyList.dictionary(data)
        XCTAssertEqual(credentials["passwordToken"] as? String, "a&b<c>")
        XCTAssertEqual(credentials["blob"] as? Data, Data("abc".utf8))
        XCTAssertEqual(credentials["ids"] as? [Int], [42])

        XCTAssertEqual(StoreService.storefrontIdentifier("143465,34"), "143465")
        XCTAssertEqual(StoreService.country(forStorefront: "143465,34"), "CN")
        XCTAssertEqual(StoreService.country(forStorefront: "143441-1,29"), "US")

        let amdFailure = AppleLoginResponse.failure(["customerMessage": "AMD-Action::SP"], submittedCode: false)
        XCTAssertNotNil(amdFailure)
        XCTAssertFalse(amdFailure?.localizedDescription.contains("AMD-Action") == true)

        XCTAssertNil(AppleLoginResponse.failure(["dsPersonId": "10001", "passwordToken": "token"], submittedCode: false))
    }

    func testMalformedOrHTMLWrappedResponsesAreRejected() {
        for text in ["<Document><Protocol>", "<html><plist><dict/></plist></html>",
                     "<Document><script>ignored</script><dict/></Document>", "<Document><string>not a dictionary</string></Document>"] {
            XCTAssertThrowsError(try ApplePropertyList.dictionary(Data(text.utf8)))
        }
    }

    func testConfigurationDiagnosticPreservesMetadataAndReason() async throws {
        var reports: [String] = []
        _ = try await AppleAuthentication.configuration(guid: "AABBCCDDEEFF", send: { url in
            (self.bag, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, report: { reports.append($0) })
        XCTAssertTrue(reports.last?.contains("format=apple-document") == true)
        XCTAssertTrue(reports.last?.contains("result=valid") == true)
        reports = []
        do {
            _ = try await AppleAuthentication.configuration(guid: "AABBCCDDEEFF", send: { url in
                (Data("<Document><dict/></Document>".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, report: { reports.append($0) })
            XCTFail("Missing endpoint must fail with an explicit diagnostic")
        } catch { XCTAssertTrue(error is AppleAuthentication.ConfigurationError) }
        XCTAssertTrue(reports.last?.contains("configuration-missingEndpoint") == true)
        XCTAssertFalse(reports.joined().contains("AABBCCDDEEFF"))
    }

    private func feed(_ entries: String) -> Data {
        Data((#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">"# + entries + "</feed>").utf8)
    }
    private func entry(_ version: String, repository: String = "mengangs/ipadn") -> String {
        """
        <entry><id>tag:github.com,2008:Repository/1/v\(version)</id>
        <updated>2026-11-08T10:00:00Z</updated><title>iPadn v\(version)</title>
        <link rel="alternate" type="text/html" href="https://github.com/\(repository)/releases/tag/v\(version)"/>
        <content type="html">&lt;h2&gt;登录修复&lt;/h2&gt;&lt;p&gt;支持 A &amp;amp; B&lt;/p&gt;</content></entry>
        """
    }

    func testFeedChoosesNewestStableReleaseFromThisRepository() throws {
        let data = feed(entry("1.7.3") + entry("2.0.0-beta.1") + entry("9.0.0", repository: "other/project") + entry("1.7.4"))
        let release = try XCTUnwrap(AppReleaseFeed.parse(data))
        XCTAssertEqual(release.version, "1.7.4")
        XCTAssertEqual(release.package?.absoluteString, "https://github.com/mengangs/ipadn/releases/download/v1.7.4/iPadn-1.7.4-unsigned.ipa")
        XCTAssertTrue(release.notes.contains("登录修复"))
        XCTAssertTrue(release.notes.contains("A & B"))
        XCTAssertNotNil(release.published)
        XCTAssertNil(AppUpdateService.newer(release, than: "1.7.4"), "A successful fallback check of the installed release is up-to-date, not a failed check")
        XCTAssertNil(AppReleaseFeed.parse(Data("<html><entry/></html>".utf8)))
        XCTAssertNil(AppReleaseFeed.parse(feed(entry("1.7.4") + "<entry>")))
    }

    func testRateLimitedAPIFallsBackToFeedAndReportsSuccessForInstalledVersion() async throws {
        let data = feed(entry("1.7.4"))
        UpdateResponseProtocol.set { request in
            if request.url?.host == "api.github.com" { return (403, Data(#"{"message":"API rate limit exceeded"}"#.utf8), ["X-RateLimit-Remaining": "0"]) }
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/mengangs/ipadn/releases.atom")
            return (200, data, [:])
        }
        defer { UpdateResponseProtocol.set(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var report = ""
        let result = await AppUpdateService.latest(session: session, report: { report = $0 })
        XCTAssertEqual(result?.version, "1.7.4")
        XCTAssertTrue(report.contains("http=403"))
        XCTAssertTrue(report.contains("rate-limited=true"))
        XCTAssertTrue(report.contains("source=feed; http=200"))
        XCTAssertTrue(report.contains("result=valid"))
    }

    func testBothUpdateSourcesFailWithoutLeakingServerText() async throws {
        let secret = "account@example.com passwordToken=secret"
        UpdateResponseProtocol.set { _ in (503, Data(secret.utf8), [:]) }
        defer { UpdateResponseProtocol.set(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var report = ""
        let result = await AppUpdateService.latest(session: session, report: { report = $0 })
        XCTAssertNil(result)
        XCTAssertTrue(report.contains("source=api; http=503"))
        XCTAssertTrue(report.contains("source=feed; http=503"))
        XCTAssertFalse(report.contains(secret))
    }
}

private final class UpdateResponseProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = (Int, Data, [String: String])
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Response)?
    static func set(_ value: ((URLRequest) -> Response)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, data, headers) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
