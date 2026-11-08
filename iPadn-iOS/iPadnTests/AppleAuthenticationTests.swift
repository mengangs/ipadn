import XCTest
@testable import iPadn

@MainActor
final class AppleAuthenticationTests: XCTestCase {
    private let endpoint = URL(string: "https://p99-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/")!

    func testBagEndpointKeepsSelectedPodAndQuery() throws {
        let data = try HTTPClient.encodePlist(["urlBag": ["authenticateAccount":
            "https://p99-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?x=1"]])
        let url = try AppleAuthentication.endpoint(from: data)
        XCTAssertEqual(url.host, "p99-buy.itunes.apple.com")
        XCTAssertEqual(url.path(percentEncoded: true), AppleAuthentication.path + "/")
        XCTAssertEqual(url.query, "x=1")
        XCTAssertEqual(AppleAuthentication.bagURL(guid: "AABBCCDDEEFF").query, "guid=AABBCCDDEEFF")
    }

    func testInvalidConfigurationAndCredentialDestinationsAreRejected() throws {
        for address in ["http://p99-buy.itunes.apple.com" + AppleAuthentication.path,
                        "https://p99-buy.itunes.apple.com.evil.example" + AppleAuthentication.path,
                        "https://user:password@buy.itunes.apple.com" + AppleAuthentication.path,
                        "https://buy.itunes.apple.com:8443" + AppleAuthentication.path,
                        "https://buy.itunes.apple.com" + AppleAuthentication.path + "#fragment",
                        "https://pd.itunes.apple.com" + AppleAuthentication.path,
                        "https://buy.itunes.apple.com" + AppleAuthentication.path + "//",
                        "https://buy.itunes.apple.com" + AppleAuthentication.path + "%2F",
                        "https://buy.itunes.apple.com/unrelated"] {
            let data = try HTTPClient.encodePlist(["urlBag": ["authenticateAccount": address]])
            XCTAssertThrowsError(try AppleAuthentication.endpoint(from: data), address)
        }
        for data in [Data(), Data("<html>unavailable</html>".utf8), try HTTPClient.encodePlist([:])] {
            XCTAssertThrowsError(try AppleAuthentication.endpoint(from: data))
        }
    }

    func testEmptyOrHTMLResponseRetriesSameSignedBody() async throws {
        for invalid in [Data(), Data("<!DOCTYPE html><html>temporary</html>".utf8)] {
            var requests = 0
            var pauses = 0
            let body = Data("signed payload".utf8)
            let headers = ["X-Apple-ActionSignature": "signature"]
            let valid = try HTTPClient.encodePlist(["accountInfo": ["appleId": "test@example.com"]])
            let result = try await AppleAuthentication.authenticate(endpoint: endpoint, body: body, headers: headers,
                send: { url, sentBody, sentHeaders in
                    requests += 1
                    XCTAssertEqual(url, self.endpoint)
                    XCTAssertEqual(sentBody, body)
                    XCTAssertEqual(sentHeaders, headers)
                    return (requests == 1 ? invalid : valid, HTTPURLResponse(url: url,
                        statusCode: requests == 1 && invalid.isEmpty ? 204 : 200, httpVersion: nil, headerFields: nil)!)
                }, pause: { pauses += 1 }, report: { _ in })
            XCTAssertNotNil(result.0["accountInfo"])
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(pauses, 1)
        }
    }

    func testCredentialFailureAndChallengeAreNeverRetried() async throws {
        let responses: [[String: Any]] = [["failureType": "-5000"],
            ["customerMessage": "MZFinance.BadLogin.Configurator_message", "failureType": ""]]
        for raw in responses {
            var requests = 0
            let data = try HTTPClient.encodePlist(raw)
            let result = try await AppleAuthentication.authenticate(endpoint: endpoint, body: Data(), headers: [:],
                send: { url, _, _ in
                    requests += 1
                    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }, pause: { XCTFail("Must not repeat a valid Apple response") }, report: { _ in })
            XCTAssertEqual(requests, 1)
            XCTAssertNotNil(AppleLoginResponse.failure(result.0, submittedCode: false))
        }
    }

    func testRepeatedInvalidResponseIsBoundedAndDiagnosticsExcludeSecrets() async throws {
        var requests = 0
        var reports: [String] = []
        let secret = "test@example.com passwordToken=secret Cookie=secret"
        do {
            _ = try await AppleAuthentication.authenticate(endpoint: endpoint, body: Data(secret.utf8), headers: [:],
                send: { url, _, _ in
                    requests += 1
                    return (Data(("<html>" + secret + "</html>").utf8), HTTPURLResponse(url: url, statusCode: 200,
                        httpVersion: nil, headerFields: ["Set-Cookie": secret, "Content-Type": secret])!)
                }, pause: {}, report: { reports.append($0) })
            XCTFail("Invalid response must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("登录数据"))
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(reports.last?.contains("format=html") == true)
        XCTAssertFalse(reports.joined().contains(secret))
        XCTAssertFalse(AppleAuthentication.errorCode(NSError(domain: secret, code: 1)).contains(secret))
    }

    func testBinaryPlistIsAccepted() async throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["failureType": "2002"], format: .binary, options: 0)
        let result = try await AppleAuthentication.authenticate(endpoint: endpoint, body: Data(), headers: [:],
            send: { url, _, _ in
                (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, pause: { XCTFail("Valid binary plist must not retry") }, report: { _ in })
        XCTAssertEqual(result.0["failureType"] as? String, "2002")
    }

    func testOnlyTransientHTTPFailuresRetry() async throws {
        for status in [403, 404, 503, 429, 401] {
            var requests = 0
            do {
                _ = try await AppleAuthentication.authenticate(endpoint: endpoint, body: Data(), headers: [:],
                    send: { _, _, _ in requests += 1; throw HTTPStatusError(code: status) },
                    pause: {}, report: { _ in })
                XCTFail("HTTP failure must propagate")
            } catch let error as HTTPStatusError { XCTAssertEqual(error.code, status) }
            XCTAssertEqual(requests, [429, 401].contains(status) ? 1 : 2)
        }
    }

    func testCancellationDuringRetryStopsFurtherRequests() async throws {
        var requests = 0
        do {
            _ = try await AppleAuthentication.authenticate(endpoint: endpoint, body: Data(), headers: [:],
                send: { url, _, _ in
                    requests += 1
                    return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
                }, pause: { throw CancellationError() }, report: { _ in })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
        XCTAssertEqual(requests, 1)
    }
}
