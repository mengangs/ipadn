import XCTest
import ZIPFoundation
@testable import IPATool

final class CoreTests: XCTestCase {
    func testLoginPayloadUsesSecondAttemptWithCode() throws {
        let first = try AppleLoginResponse.body(email: "test@example.com", password: "password", code: "", guid: "AABBCCDDEEFF")
        let second = try AppleLoginResponse.body(email: "test@example.com", password: "password", code: "123456", guid: "AABBCCDDEEFF")
        let firstBody = try XCTUnwrap(PropertyListSerialization.propertyList(from: first, format: nil) as? [String: String])
        let secondBody = try XCTUnwrap(PropertyListSerialization.propertyList(from: second, format: nil) as? [String: String])
        XCTAssertEqual(firstBody["attempt"], "1")
        XCTAssertEqual(firstBody["password"], "password")
        XCTAssertEqual(secondBody["attempt"], "2")
        XCTAssertEqual(secondBody["password"], "password123456")
        XCTAssertEqual(secondBody["rmp"], "0")
    }

    func testAppleLoginChallengeAndRejection() {
        let challenge: [String: Any] = ["customerMessage": "MZFinance.BadLogin.Configurator_message", "failureType": ""]
        guard case .verificationRequired? = AppleLoginResponse.failure(challenge, submittedCode: false) as? AppleLoginError else {
            return XCTFail("The initial challenge should request a code")
        }
        guard case .verificationRejected? = AppleLoginResponse.failure(challenge, submittedCode: true) as? AppleLoginError else {
            return XCTFail("A rejected code should permit retry")
        }
        XCTAssertNil(AppleLoginResponse.failure(["accountInfo": ["appleId": "test@example.com"]], submittedCode: true))
        XCTAssertNotNil(AppleLoginResponse.failure([:], submittedCode: false))
        XCTAssertFalse(AppleLoginResponse.failure(["customerMessage": "MZFinance.Unknown"], submittedCode: false)!.localizedDescription.contains("MZFinance"))
        XCTAssertTrue(AppleLoginResponse.failure(["failureType": "2034"], submittedCode: false)!.localizedDescription.contains("过期"))
    }

    @MainActor
    func testSignerCancellationBeforeStartAndInvalidIdentity() async {
        let signer = SAPSigner()
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await signer.sign(Data("test".utf8), guid: "AABBCCDDEEFF", useCache: false)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled work must not start") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(signer.isPresented)
        do { _ = try await signer.kbsync(guid: "invalid", dsid: "0", useCache: false); XCTFail("Invalid identity accepted") }
        catch { XCTAssertFalse(signer.isPresented) }
    }

    @MainActor
    func testSignerCancelResumesPendingJavaScript() async throws {
        let signer = SAPSigner()
        // A fresh CI simulator can take longer than ten seconds to launch WebKit.
        // Warm it through a real evaluation, then test cancellation of a live promise.
        let ready = try await signer.execute(title: "准备", script: "return 'ready';", arguments: [:])
        XCTAssertEqual(ready, "ready")
        let work = Task { @MainActor in
            try await signer.execute(title: "测试", script: "reportStage(2); window.pendingTest = new Promise(() => {}); return await window.pendingTest;", arguments: [:], timeoutSeconds: 60)
        }
        for _ in 0..<900 {
            if signer.stageIndex == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(signer.stageIndex, 2, "JavaScript should reach the pending operation")
        signer.cancel()
        do { _ = try await work.value; XCTFail("Cancelled operation returned success") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(signer.isPresented)
        XCTAssertNil(signer.webView)
        let retry = try await signer.execute(title: "重试", script: "return 'ready';", arguments: [:])
        XCTAssertEqual(retry, "ready")
    }

    @MainActor
    func testSignerTimeoutResumesPendingJavaScript() async {
        let signer = SAPSigner()
        do {
            _ = try await signer.execute(title: "测试", script: "window.pendingTest = new Promise(() => {}); return await window.pendingTest;", arguments: [:], timeoutSeconds: 1)
            XCTFail("Timed-out operation returned success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已停止")) }
        XCTAssertFalse(signer.isPresented)
        XCTAssertNil(signer.webView)
    }

    func testSearchInputs() throws {
        XCTAssertEqual(try SearchQuery.parse("微信"), .keyword("微信"))
        XCTAssertEqual(try SearchQuery.parse(" 414478124 "), .appID("414478124", versionID: nil))
        XCTAssertEqual(try SearchQuery.parse("414478124 123456789"), .appID("414478124", versionID: "123456789"))
        XCTAssertEqual(try SearchQuery.parse("https://apps.apple.com/cn/app/wechat/id414478124?l=en"), .appID("414478124", versionID: nil))
        XCTAssertThrowsError(try SearchQuery.parse("  "))
        XCTAssertThrowsError(try SearchQuery.parse("https://apps.apple.com/cn/app/no-id"))
    }

    func testSearchEncodingAndPriceMapping() {
        let app = StoreService.mapLookup(["trackId": NSNumber(value: 414478124), "trackName": "微信",
            "bundleId": "com.tencent.xin", "fileSizeBytes": "1048576", "averageUserRating": 4.5, "version": "1.0", "formattedPrice": "免费"])
        XCTAssertEqual(app.id, "414478124")
        XCTAssertEqual(app.bundleID, "com.tencent.xin")
        XCTAssertEqual(app.size, 1_048_576)
        XCTAssertEqual(app.rating, 4.5)
    }

    func testRangeRequests() throws {
        XCTAssertEqual(try HTTPByteRange.parse("bytes=2-5", size: 10), HTTPByteRange(start: 2, end: 5))
        XCTAssertEqual(try HTTPByteRange.parse("bytes=2-", size: 10), HTTPByteRange(start: 2, end: 9))
        XCTAssertEqual(try HTTPByteRange.parse("bytes=-3", size: 10), HTTPByteRange(start: 7, end: 9))
        XCTAssertEqual(try HTTPByteRange.parse("bytes=0-999", size: 10).count, 10)
        XCTAssertThrowsError(try HTTPByteRange.parse("bytes=10-", size: 10))
        XCTAssertThrowsError(try HTTPByteRange.parse("bytes=5-2", size: 10))
        XCTAssertThrowsError(try HTTPByteRange.parse("bytes=0-1,4-5", size: 10))
        XCTAssertThrowsError(try HTTPByteRange.parse("bytes=-0", size: 10))
    }

    func testManifestPreservesUnicodeAndNestedParameters() throws {
        let app = StoreApp(id: "1", name: "应用 & Test", bundleID: "test.bundle", version: "1.0")
        let url = try ManifestBuilder.installURL(app: app, filename: "1234-应用_1.0.ipa", plistServer: "https://example.com/manifest")
        XCTAssertTrue(url.absoluteString.hasPrefix("itms-services://?"))
        let outer = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(outer.queryItems?.first(where: { $0.name == "action" })?.value, "download-manifest")
        let manifest = outer.queryItems!.first(where: { $0.name == "url" })!.value!
        let remote = URLComponents(string: manifest)!
        let decoded = remote.percentEncodedQuery!.removingPercentEncoding!
        let metadata = URLComponents(string: "https://localhost/?" + decoded)!
        XCTAssertEqual(metadata.queryItems?.first(where: { $0.name == "name" })?.value, app.name)
        XCTAssertEqual(metadata.queryItems?.first(where: { $0.name == "fileName" })?.value, "1234-应用_1.0.ipa")
        XCTAssertThrowsError(try ManifestBuilder.installURL(app: app, filename: "a.ipa", plistServer: "http://example.com/manifest"))
    }

    func testDMAPUint64AndMalformedData() throws {
        XCTAssertEqual(try DMAP.integer(Data([255, 255, 255, 255, 255, 255, 255, 255])), UInt64.max)
        XCTAssertEqual(try DMAP.firstInteger(DMAP.tag("mlog", DMAP.uint32("mlid", 1234)), name: "mlid"), 1234)
        XCTAssertThrowsError(try DMAP.walk(Data([1, 2, 3])) { _ in })
        XCTAssertThrowsError(try DMAP.walk(Data("mlit".utf8) + Data([0, 0, 0, 100])) { _ in })
        XCTAssertThrowsError(try DMAP.validate(DMAP.tag("mlog", DMAP.uint32("mstt", 403))))
    }

    func testOwnedAppParseAndDeduplication() throws {
        let app = DMAP.tag("mlit", DMAP.uint32("aeSI", 414478124) + DMAP.string("aeBI", "com.tencent.xin") +
            DMAP.string("aeLN", "微信") + DMAP.string("aePd", "8.0") + DMAP.uint32("asdp", 1_700_000_000))
        let result = try DMAP.ownedApps(DMAP.tag("adbs", DMAP.tag("mlcl", app + app)))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "414478124")
        XCTAssertEqual(result[0].name, "微信")
        XCTAssertEqual(result[0].purchaseDate, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testDMAPDepthLimit() {
        var payload = DMAP.uint32("mlid", 1)
        for _ in 0..<18 { payload = DMAP.tag("mlcl", payload) }
        XCTAssertThrowsError(try DMAP.walk(payload) { _ in })
    }

    func testJobAndSettingsPersistenceRoundTrip() throws {
        let app = StoreApp(id: "1", name: "Test", bundleID: "test.bundle", version: "1.0")
        let job = DownloadJob(app: app, status: .paused, downloaded: 20, expected: 100)
        let result = try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(result.id, job.id)
        XCTAssertEqual(result.status, .paused)
        XCTAssertEqual(result.progress, 0.2, accuracy: 0.001)
        let settings = ToolSettings()
        XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testPackageInspectionUsesMainBundleNotExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.ipa")
        let archive = try Archive(url: url, accessMode: .create)
        let main: [String: Any] = ["CFBundleDisplayName": "测试应用", "CFBundleIdentifier": "test.main", "CFBundleShortVersionString": "2.0"]
        let plist = try PropertyListSerialization.data(fromPropertyList: main, format: .binary, options: 0)
        let path = "Payload/Test.app/Info.plist"
        let disk = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: disk)
        try archive.addEntry(with: path, relativeTo: root)
        let app = try PackageService.inspect(url)
        XCTAssertEqual(app.name, "测试应用")
        XCTAssertEqual(app.bundleID, "test.main")
        XCTAssertEqual(app.version, "2.0")
        XCTAssertEqual(PackageService.safeName("a/b:c"), "a_b_c")
    }

    func testPackageAuthorizationReplacesMetadataAndSinf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("test.download")
        do {
            let archive = try Archive(url: staging, accessMode: .create)
            let files: [String: Data] = [
                "Payload/Test.app/Info.plist": try HTTPClient.encodePlist(["CFBundleDisplayName": "Test", "CFBundleIdentifier": "test.bundle", "CFBundleShortVersionString": "1.0"]),
                "Payload/Test.app/SC_Info/Test.v123.supp": Data([0]),
                "iTunesMetadata.plist": try HTTPClient.encodePlist(["itemId": "1"])
            ]
            for (path, data) in files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
                try archive.addEntry(with: path, relativeTo: root)
            }
        }
        let asset = DownloadAsset(app: StoreApp(id: "1", name: "Test", bundleID: "test.bundle", version: "1.0"),
            url: URL(string: "https://example.com/app")!, sinf: Data([1, 2, 3]),
            metadata: try HTTPClient.encodePlist(["itemId": "1", "appleId": "test@example.com"]), externalVersionIDs: [], platform: "ios", account: "test@example.com")
        let result = try PackageService.finish(staging: staging, id: UUID(), asset: asset)
        let final = LocalResources.packages.appendingPathComponent(result.0)
        defer { try? FileManager.default.removeItem(at: final) }
        let archive = try Archive(url: final, accessMode: .read)
        XCTAssertNotNil(archive["Payload/Test.app/SC_Info/Test.sinf"])
        var payload = Data()
        _ = try archive.extract(archive["Payload/Test.app/SC_Info/Test.sinf"]!, consumer: { payload.append($0) })
        XCTAssertEqual(payload, Data([1, 2, 3]))
    }
}
