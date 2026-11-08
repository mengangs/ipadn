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

    func testNativeBagEndpointsArePreservedWithoutRewritingPath() throws {
        for native in ["/auth/v1/native", "/auth/v1/native/", "/auth/v1/native/fast", "/auth/v1/native/fast/"] {
            let data = try HTTPClient.encodePlist(["authenticateAccount": "https://auth.itunes.apple.com" + native + "?pod=1"])
            let url = try AppleAuthentication.endpoint(from: data)
            XCTAssertEqual(url.host, "auth.itunes.apple.com")
            XCTAssertEqual(url.path(percentEncoded: true), native)
            XCTAssertEqual(url.query, "pod=1")
            XCTAssertTrue(AppleAuthentication.needsStoreProof(url))
            XCTAssertFalse(AppleAuthentication.needsStoreProof(url, method: "GET"))
        }
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
                        "https://evil-buy.itunes.apple.com" + AppleAuthentication.path,
                        "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish",
                        "https://auth.itunes.apple.com/auth/v1/native/extra",
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

    func testStoreProofAllowlistAndProvisionReplay() async throws {
        let nativeAuth = URL(string: "https://auth.itunes.apple.com/auth/v1/native")!
        let dispatch = URL(string: "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=AABBCCDDEEFF")!
        let buyPod = URL(string: "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!
        let legacyAuth = URL(string: "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/")!
        let untrusted = URL(string: "https://evil-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!

        XCTAssertTrue(AppleAuthentication.needsStoreProof(nativeAuth))
        XCTAssertTrue(AppleAuthentication.needsStoreProof(dispatch))
        XCTAssertTrue(AppleAuthentication.needsStoreProof(buyPod))
        XCTAssertFalse(AppleAuthentication.needsStoreProof(legacyAuth))
        XCTAssertFalse(AppleAuthentication.needsStoreProof(untrusted))

        let challenge = Data("server-challenge".utf8).base64EncodedString()
        var callCount = 0
        var provisionedChallenges: [String] = []
        var resets = 0
        var otpCounter = 0
        let outcome = try await AppleAuthentication.withStoreProof(
            endpoint: nativeAuth,
            baseHeaders: ["X-Apple-ActionSignature": "sig-1"],
            loadProof: {
                otpCounter += 1
                return ["X-Apple-AMD": "otp-\(otpCounter)", "X-Apple-AMD-M": "mid-1"]
            },
            provisionProof: { received in
                provisionedChallenges.append(received)
                return ["X-Apple-AMD": "fresh-otp", "X-Apple-AMD-M": "fresh-mid"]
            },
            resetProof: { resets += 1 },
            execute: { headerProvider in
                callCount += 1
                let sentHeaders = try await headerProvider(nativeAuth)
                XCTAssertEqual(sentHeaders["X-Apple-ActionSignature"], "sig-1")
                if callCount == 1 {
                    XCTAssertEqual(sentHeaders["X-Apple-AMD"], "otp-1")
                    let resp = HTTPURLResponse(url: nativeAuth, statusCode: 200, httpVersion: nil,
                                               headerFields: ["X-Apple-AMD-Action": "RP"])!
                    return (["customerMessage": "AMD-Action::RP"], resp)
                }
                if callCount == 2 {
                    XCTAssertNil(sentHeaders["X-Apple-AMD"])
                    let resp = HTTPURLResponse(url: nativeAuth, statusCode: 200, httpVersion: nil,
                                               headerFields: ["X-Apple-AMD-Action": "SP", "X-Apple-AMD-Data": challenge])!
                    return (["customerMessage": "AMD-Action::SP"], resp)
                }
                XCTAssertEqual(sentHeaders["X-Apple-AMD"], "fresh-otp")
                XCTAssertEqual(sentHeaders["X-Apple-AMD-M"], "fresh-mid")
                let redirectedHeaders = try await headerProvider(nativeAuth)
                XCTAssertEqual(redirectedHeaders["X-Apple-AMD"], "otp-2")
                let resp = HTTPURLResponse(url: nativeAuth, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (["dsPersonId": "123456", "passwordToken": "tok"], resp)
            }
        )
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(provisionedChallenges, [challenge])
        XCTAssertEqual(outcome.0["dsPersonId"] as? String, "123456")

        let malformedResp = HTTPURLResponse(url: nativeAuth, statusCode: 200, httpVersion: nil,
                                            headerFields: ["X-Apple-AMD-Action": "SP", "X-Apple-AMD-Data": "not base64!"])!
        XCTAssertEqual(AppleAuthentication.storeMachineAction(raw: [:], response: malformedResp), .invalidChallenge)
    }

    func testEmptyBodyChallengeAndCorruptStateSelfHealing() async throws {
        let nativeAuth = URL(string: "https://auth.itunes.apple.com/auth/v1/native")!
        let challenge = Data("empty-body-challenge".utf8).base64EncodedString()
        let validSuccess = try PropertyListSerialization.data(
            fromPropertyList: ["dsPersonId": "654321", "passwordToken": "tok-2"],
            format: .xml, options: 0
        )
        var pauses = 0
        var resets = 0
        var wireAttempt = 0
        var logs: [String] = []
        let (decoded, _) = try await AppleAuthentication.withStoreProof(
            endpoint: nativeAuth,
            baseHeaders: ["Content-Type": "application/x-apple-plist", "X-Apple-ActionSignature": "sig-2"],
            loadProof: {
                throw ToolError.message("corrupt state")
            },
            provisionProof: { received in
                XCTAssertEqual(received, challenge)
                XCTAssertEqual(resets, 1, "Corrupt loadProof must reset stored state before provisioning")
                return ["X-Apple-AMD": "prov-otp", "X-Apple-AMD-M": "prov-mid"]
            },
            resetProof: { resets += 1 },
            execute: { headerProvider in
                try await AppleAuthentication.authenticate(
                    endpoint: nativeAuth,
                    body: Data("signed".utf8),
                    makeHeaders: { try await headerProvider(nativeAuth) },
                    send: { url, _, sentHeaders in
                        wireAttempt += 1
                        if wireAttempt == 1 {
                            XCTAssertNil(sentHeaders["X-Apple-AMD"])
                            let challengeResp = HTTPURLResponse(
                                url: url, statusCode: 200, httpVersion: nil,
                                headerFields: ["X-Apple-AMD-Action": "SP", "X-Apple-AMD-Data": challenge]
                            )!
                            return (Data(), challengeResp)
                        }
                        XCTAssertEqual(sentHeaders["X-Apple-AMD"], "prov-otp")
                        XCTAssertEqual(sentHeaders["X-Apple-AMD-M"], "prov-mid")
                        let okResp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                        return (validSuccess, okResp)
                    },
                    pause: { pauses += 1 },
                    report: { logs.append($0) }
                )
            }
        )
        XCTAssertEqual(pauses, 0, "Header-only SP challenge must not waste a sleep/retry before provisioning")
        XCTAssertEqual(wireAttempt, 2)
        XCTAssertEqual(decoded["dsPersonId"] as? String, "654321")

        do {
            _ = try await AppleAuthentication.withStoreProof(
                endpoint: nativeAuth,
                baseHeaders: [:],
                loadProof: { nil },
                provisionProof: { _ in ["X-Apple-AMD": "otp-a", "X-Apple-AMD-M": "mid-a"] },
                resetProof: {},
                execute: { _ in
                    let resp = HTTPURLResponse(
                        url: nativeAuth, statusCode: 200, httpVersion: nil,
                        headerFields: ["X-Apple-AMD-Action": "SP", "X-Apple-AMD-Data": challenge]
                    )!
                    return ([:], resp)
                }
            )
            XCTFail("Repeated SP challenge must throw device verification error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("设备验证未完成"))
        }
    }

    func testHTTPClientRedirectsNormalizationAndHeaderScoping() async throws {
        final class MockProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                do {
                    let (response, data) = try Self.handler!(request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            override func stopLoading() {}
        }

        let client = HTTPClient(protocolClasses: [MockProtocol.self])
        let okPlist = try PropertyListSerialization.data(fromPropertyList: ["ok": "1"], format: .xml, options: 0)

        // 1. Bare buy-pod 301 redirect is normalized to trailing slash and strips X-Apple-AMD when leaving native auth.
        var seenAuthURLs: [String] = []
        var secondHopAMD: String?
        var secondHopSig: String?
        MockProtocol.handler = { req in
            let url = req.url!
            seenAuthURLs.append(url.absoluteString)
            if seenAuthURLs.count == 1 {
                let redirect = HTTPURLResponse(
                    url: url, statusCode: 301, httpVersion: nil,
                    headerFields: ["Location": "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?Pod=25"]
                )!
                return (redirect, Data())
            }
            secondHopAMD = req.value(forHTTPHeaderField: "X-Apple-AMD")
            secondHopSig = req.value(forHTTPHeaderField: "X-Apple-ActionSignature")
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, okPlist)
        }
        let (_, authResp) = try await client.request(
            URL(string: "https://auth.itunes.apple.com/auth/v1/native")!,
            method: "POST", body: Data("payload".utf8),
            headers: ["X-Apple-AMD": "otp-1", "X-Apple-AMD-M": "mid-1", "X-Apple-ActionSignature": "sig"],
            appleRedirects: true, authentication: true
        )
        XCTAssertEqual(authResp.url?.absoluteString, "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/?Pod=25")
        XCTAssertNil(secondHopAMD)
        XCTAssertEqual(secondHopSig, "sig")

        // 2. HTTP 303 on authentication POST is rejected.
        MockProtocol.handler = { req in
            let redirect = HTTPURLResponse(
                url: req.url!, statusCode: 303, httpVersion: nil,
                headerFields: ["Location": "https://auth.itunes.apple.com/auth/v1/native/?Pod=7"]
            )!
            return (redirect, Data())
        }
        do {
            _ = try await client.request(
                URL(string: "https://auth.itunes.apple.com/auth/v1/native")!,
                method: "POST", body: Data("payload".utf8),
                appleRedirects: true, authentication: true
            )
            XCTFail("303 redirect on authentication POST must fail")
        } catch {}

        // 3. DAAP purchase redirect preserves X-Token across *.itunes.apple.com pods.
        var daapSecondHopToken: String?
        var daapHop = 0
        MockProtocol.handler = { req in
            daapHop += 1
            if daapHop == 1 {
                let redirect = HTTPURLResponse(
                    url: req.url!, statusCode: 307, httpVersion: nil,
                    headerFields: ["Location": "https://p42-pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase/login"]
                )!
                return (redirect, Data())
            }
            daapSecondHopToken = req.value(forHTTPHeaderField: "X-Token")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("ok".utf8))
        }
        _ = try await client.request(
            URL(string: "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase/login")!,
            method: "POST", headers: ["X-Token": "keep-token"], appleRedirects: true
        )
        XCTAssertEqual(daapSecondHopToken, "keep-token")

        // 4. HTTPClient.plist returns empty dict on HTTP 200 header-only SP challenge instead of failing plist decode.
        let spChallenge = Data("spim".utf8).base64EncodedString()
        MockProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["X-Apple-AMD-Action": "SP", "X-Apple-AMD-Data": spChallenge]
            )!
            return (resp, Data())
        }
        let (emptyChallengeDict, challengeHTTPResp) = try await client.plist(
            URL(string: "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download")!,
            body: okPlist, headers: [:]
        )
        XCTAssertTrue(emptyChallengeDict.isEmpty)
        XCTAssertEqual(AppleAuthentication.storeMachineAction(raw: emptyChallengeDict, response: challengeHTTPResp), .provision(spChallenge))
    }
}
