import XCTest
import UIKit
import ZIPFoundation
@testable import iPadn

final class CoreTests: XCTestCase {
    func testPackageCompletionCannotOverwriteSharedIdentifierPrefixAndHandlesLongNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var completed: [URL] = []
        defer { for file in completed { try? FileManager.default.removeItem(at: file) } }
        func package(name: String, marker: UInt8) throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString + ".ipa")
            let archive = try Archive(url: url, accessMode: .create)
            let files = ["Payload/Test.app/Info.plist": try HTTPClient.encodePlist([
                "CFBundleDisplayName": name, "CFBundleIdentifier": "test.filename", "CFBundleShortVersionString": "1.0"]),
                "Payload/Test.app/marker": Data([marker])]
            for (path, bytes) in files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file)
                try archive.addEntry(with: path, relativeTo: root)
            }
            return url
        }
        let firstID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "11111111-0000-0000-0000-000000000002")!
        let first = try PackageService.finish(staging: package(name: "Collision", marker: 1), id: firstID, asset: nil)
        let firstURL = LocalResources.packages.appendingPathComponent(first.0); completed.append(firstURL)
        let original = try Data(contentsOf: firstURL)
        let second = try PackageService.finish(staging: package(name: "Collision", marker: 2), id: secondID, asset: nil)
        completed.append(LocalResources.packages.appendingPathComponent(second.0))
        XCTAssertNotEqual(first.0, second.0)
        XCTAssertEqual(try Data(contentsOf: firstURL), original)
        XCTAssertThrowsError(try PackageService.finish(staging: package(name: "Collision", marker: 3), id: firstID, asset: nil))
        XCTAssertEqual(try Data(contentsOf: firstURL), original)
        let long = try PackageService.finish(staging: package(name: String(repeating: "应用", count: 80), marker: 4), id: UUID(), asset: nil)
        completed.append(LocalResources.packages.appendingPathComponent(long.0))
        XCTAssertLessThanOrEqual(long.0.utf8.count, 255)
    }
    @MainActor
    func testSignerReusesSuccessfulPageAndClearsItOnCacheReset() async throws {
        let signer = SAPSigner()
        let coldStart = ProcessInfo.processInfo.systemUptime
        let marker = try await signer.execute(title: "首次", script: "await loadSapSigner(); window.runtimeMarker = 'retained-context'; return window.runtimeMarker;", arguments: [:])
        let cold = ProcessInfo.processInfo.systemUptime - coldStart
        let warmStart = ProcessInfo.processInfo.systemUptime
        let reused = try await signer.execute(title: "复用", script: "await loadSapSigner(); return window.runtimeMarker || 'new-context';", arguments: [:])
        let warm = ProcessInfo.processInfo.systemUptime - warmStart
        XCTAssertEqual(reused, marker)
        print("WebKit WASM initialization: cold \(cold)s; warm \(warm)s (no Apple signing request)")
        signer.clearCache()
        let fresh = try await signer.execute(title: "清理后", script: "return window.runtimeMarker || 'new-context';", arguments: [:])
        XCTAssertEqual(fresh, "new-context")
        signer.clearCache()
    }
    @MainActor
    func testPackagedIconChoicesMatchCurrentDevice() throws {
        XCTAssertNil(AppIconService.Choice.dimensional.alternateName)
        XCTAssertEqual(AppIconService.Choice.flat.alternateName, "AppIconFlat")
        // Xcode thins simulator builds to the selected device. Both idioms are
        // checked separately in the unthinned device IPA by verify_ipa.py.
        let key = UIDevice.current.userInterfaceIdiom == .pad ? "CFBundleIcons~ipad" : "CFBundleIcons"
        let icons = try XCTUnwrap(Bundle.main.infoDictionary?[key] as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        let flat = try XCTUnwrap(alternates["AppIconFlat"] as? [String: Any])
        XCTAssertFalse(try XCTUnwrap(flat["CFBundleIconFiles"] as? [String]).isEmpty)
        XCTAssertNotNil(Bundle.main.url(forResource: "AppIconFlat60x60@2x", withExtension: "png"))
        XCTAssertNotNil(UIImage(named: AppIconService.Choice.dimensional.preview))
        XCTAssertNotNil(UIImage(named: AppIconService.Choice.flat.preview))
        XCTAssertTrue(UIApplication.shared.supportsAlternateIcons)
    }
    func testPlatformSearchEntitiesAndIPASupport() {
        XCTAssertEqual(AppPlatform.iOS.searchEntity, "software")
        XCTAssertEqual(AppPlatform.iPadOS.searchEntity, "iPadSoftware")
        XCTAssertEqual(AppPlatform.tvOS.searchEntity, "tvSoftware")
        XCTAssertEqual(AppPlatform.macOS.searchEntity, "desktopSoftware")
        XCTAssertEqual(AppPlatform.iPadOS.catalogPlatform, AppPlatform.iOS.rawValue)
        XCTAssertFalse(AppPlatform.macOS.supportsIPA)
        XCTAssertTrue(AppPlatform.iPadOS.supportsIPA)
        XCTAssertTrue(AppPlatform.tvOS.supportsIPA)
    }

    func testActualIPAFamilyMustMatchRequestedPlatform() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func package(family: Int) throws -> URL {
            let url = root.appendingPathComponent("\(family).ipa")
            let archive = try Archive(url: url, accessMode: .create)
            let contents = [
                "Payload/Target.app/Info.plist": try HTTPClient.encodePlist([
                    "CFBundleIdentifier": "test.platform",
                    "CFBundleDisplayName": "Platform Test",
                    "CFBundleShortVersionString": "1.0",
                    "UIDeviceFamily": [family]
                ]),
                "Payload/Target.app/SC_Info/Target.supp": Data([0])
            ]
            for (path, data) in contents {
                let target = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
                try archive.addEntry(with: path, relativeTo: root)
            }
            return url
        }

        let tvIPA = try package(family: 3)
        let phoneIPA = try package(family: 1)
        XCTAssertEqual(try PackageService.deviceFamilies(tvIPA), Set([3]))
        XCTAssertEqual(try PackageService.deviceFamilies(phoneIPA), Set([1]))
        let metadata = try HTTPClient.encodePlist(["itemId": "1"])
        let app = StoreApp(id: "1", name: "Platform Test", bundleID: "test.platform", version: "1.0")
        let tvAsset = DownloadAsset(app: app, url: URL(string: "https://example.com/file.ipa")!,
                                    sinf: Data([1, 2]), metadata: metadata, externalVersionIDs: [],
                                    platform: "appletvos", account: "example")
        XCTAssertThrowsError(try PackageService.finish(staging: phoneIPA, id: UUID(), asset: tvAsset))
        let iPadAsset = DownloadAsset(app: app, url: URL(string: "https://example.com/file.ipa")!,
                                     sinf: Data([1, 2]), metadata: metadata, externalVersionIDs: [],
                                     platform: "ipad", account: "example")
        XCTAssertThrowsError(try PackageService.finish(staging: phoneIPA, id: UUID(), asset: iPadAsset))
    }

    func testMacDeveloperInstallerLinksAndRawPackagePreservation() throws {
        let website = URL(string: "https://developer.example.org/products/")!
        let html = """
        <a href="/downloads/Sample.dmg?version=2&amp;platform=mac">DMG</a>
        <a href="https://cdn.example.org/installer.pkg">PKG</a>
        <a href="http://example.org/insecure.dmg">Unsafe</a>
        <a href="javascript:alert('x')">Script</a>
        <a href="/downloads/Sample.dmg?version=2&amp;platform=mac">Duplicate</a>
        """
        let links = MacInstallerService.links(in: html, from: website)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.map(\.format), ["dmg", "pkg"])
        XCTAssertEqual(links.first?.url.absoluteString,
                       "https://developer.example.org/downloads/Sample.dmg?version=2&platform=mac")
        XCTAssertNil(MacInstallerService.safeWebsite("http://developer.example.org"))
        XCTAssertNil(MacInstallerService.safeWebsite("https://127.0.0.1/secret.pkg"))
        XCTAssertFalse(MacInstallerService.directPackage(URL(string: "https://example.org/a.ipa")!))

        let app = StoreApp(id: "mac-test", name: "Mac Test", version: "1.0")
        let id = UUID()
        let staging = LocalResources.stagingURL(id)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Data("xar!test-data".utf8).write(to: staging)
        let job = DownloadJob(id: id, app: app, rawFormat: "pkg")
        let (filename, result) = try MacPackageStorage.finish(staging: staging, job: job)
        let finalURL = try XCTUnwrap(LocalResources.packageURL(filename))
        defer { try? FileManager.default.removeItem(at: finalURL) }
        XCTAssertTrue(filename.hasSuffix(".pkg"))
        XCTAssertEqual(result.name, app.name)
        XCTAssertEqual(result.size, Int64(Data("xar!test-data".utf8).count))
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("xar!test-data".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        let invalidID = UUID()
        let invalid = LocalResources.stagingURL(invalidID)
        defer { try? FileManager.default.removeItem(at: invalid) }
        try Data("<html>not a dmg</html>".utf8).write(to: invalid)
        XCTAssertThrowsError(try MacPackageStorage.finish(
            staging: invalid,
            job: DownloadJob(id: invalidID, app: app, rawFormat: "dmg")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
    }

    func testAccountStorefrontRegionsAndCrossRegionSearchMerge() {
        XCTAssertEqual(StoreService.country(forStorefront: "143441-1,29"), "US")
        XCTAssertEqual(StoreService.country(forStorefront: "143465"), "CN")
        XCTAssertEqual(StoreService.country(forStorefront: "143462-1,15"), "JP")
        XCTAssertNil(StoreService.country(forStorefront: "unknown"))
        XCTAssertEqual(StoreService.searchCountries(selected: "CN", accountCountry: "US"), ["CN", "US"])
        XCTAssertEqual(StoreService.searchCountries(selected: "US", accountCountry: "US"), ["US"])
        XCTAssertEqual(StoreService.artworkCountries(selected: "CN", accountCountry: "US"), ["US", "CN"])
        XCTAssertEqual(StoreService.artworkCountries(selected: "JP", accountCountry: "CN"), ["CN", "JP", "US"])

        let regional = (1...4).map { StoreApp(id: String($0), name: "Regional \($0)") }
        let usArtwork = URL(string: "https://example.com/2.png")!
        let account = [
            StoreApp(id: "2", name: "Same app in another region", iconURL: usArtwork),
            StoreApp(id: "100", name: "Only in US"),
            StoreApp(id: "101", name: "Another US app")
        ]
        let results = StoreService.mergeResults(regional, account, limit: 4)
        XCTAssertEqual(results.map(\.id), ["1", "2", "100", "3"])
        XCTAssertEqual(results[1].iconURL, usArtwork)
        XCTAssertEqual(Set(results.map(\.id)).count, results.count)
    }

    func testPartialSettingsPreserveUserChoicesAndBoundInvalidLimits() throws {
        let legacy = Data(#"{"plistServer":"https://example.com/manifest","notifications":false,"maxConcurrentDownloads":99,"maxQueuedDownloads":-1}"#.utf8)
        let settings = try JSONDecoder().decode(ToolSettings.self, from: legacy)
        XCTAssertEqual(settings.plistServer, "https://example.com/manifest")
        XCTAssertFalse(settings.notifications)
        XCTAssertEqual(settings.maxConcurrentDownloads, 6)
        XCTAssertEqual(settings.maxQueuedDownloads, 1)
        XCTAssertEqual(settings.versionSources.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(DownloadJob(app: StoreApp(id: "1", name: "Test"), downloaded: -1, expected: 100).progress, 0)
    }

    func testPackagePathsCannotEscapeOrReferenceDirectories() throws {
        for name in ["", ".", "..", "../outside.ipa", "/outside.ipa", "folder/file.ipa", "folder\\file.ipa"] {
            XCTAssertNil(LocalResources.packageURL(name))
        }
        let name = UUID().uuidString + ".ipa"
        let file = LocalResources.packages.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("test".utf8).write(to: file)
        XCTAssertEqual(LocalResources.packageURL(name), file.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertNil(LocalResources.packageURL(name))
        try FileManager.default.removeItem(at: file)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("private".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertNil(LocalResources.packageURL(name))
    }

    func testAuthorizationArchivePathsRejectTraversal() {
        XCTAssertTrue(PackageService.isSafeArchivePath("Payload/Test.app/SC_Info/Test.sinf"))
        for path in ["/Payload/Test.app", "../Test.sinf", "Payload/../Test.sinf", "Payload//Test.sinf", "Payload\\Test.sinf", "Payload/./Test.sinf"] {
            XCTAssertFalse(PackageService.isSafeArchivePath(path), path)
        }
    }

    func testCorruptMetadataCannotPassInspectionOrIconExtraction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("corrupt.ipa")
        do {
            let archive = try Archive(url: url, accessMode: .create)
            let path = "Payload/Test.app/Info.plist"
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HTTPClient.encodePlist(["CFBundleDisplayName": "Sample", "CFBundleIdentifier": "test.crc"]).write(to: file)
            try archive.addEntry(with: path, relativeTo: root, compressionMethod: .none)
        }
        var bytes = try Data(contentsOf: url)
        let range = try XCTUnwrap(bytes.range(of: Data("Sample".utf8)))
        bytes[range.lowerBound] = Character("T").asciiValue!
        try bytes.write(to: url)
        XCTAssertThrowsError(try PackageService.inspect(url), "A valid plist with an incorrect CRC must be rejected")
        XCTAssertThrowsError(try PackageIconService.png(from: url))
    }

    func testEmptyPurchaseResponseCannotReplaceCachedRecords() {
        XCTAssertThrowsError(try DMAP.validate(Data()))
        XCTAssertThrowsError(try DMAP.validate(DMAP.tag("mlcl")))
        XCTAssertNoThrow(try DMAP.validate(DMAP.tag("mlog", DMAP.uint32("mstt", 200))))
        XCTAssertThrowsError(try DMAP.validate(DMAP.tag("mlog", DMAP.uint32("mstt", 403))))
    }

    @MainActor
    func testFailedAppleRetryKeepsTaskIdentityAndRejectsAccountChange() throws {
        let app = StoreApp(id: "1", name: "Test", version: "1.0")
        let asset = DownloadAsset(app: app, url: URL(string: "https://example.com/new.ipa")!, externalVersionIDs: [], platform: "ios", account: "test@example.com")
        let job = DownloadJob(app: app, asset: asset, status: .failed, error: "expired")
        let manager = DownloadManager(previewJobs: [job])
        var changed = asset; changed.account = "other@example.com"
        XCTAssertThrowsError(try manager.refreshFailed(job.id, asset: changed))
        XCTAssertEqual(manager.jobs.first?.status, .failed)
        try manager.refreshFailed(job.id, asset: asset)
        XCTAssertEqual(manager.jobs.count, 1)
        XCTAssertEqual(manager.jobs.first?.id, job.id)
        XCTAssertEqual(manager.jobs.first?.status, .queued)
        XCTAssertEqual(manager.jobs.first?.sourceURL, asset.url)
        XCTAssertNil(manager.jobs.first?.error)
    }

    @MainActor
    func testFailedPersistenceDoesNotPublishReplacementOrNewTask() {
        let app = StoreApp(id: "1", name: "Test")
        let asset = DownloadAsset(app: app, url: URL(string: "https://example.com/new.ipa")!, externalVersionIDs: [], platform: "ios", account: "test@example.com")
        let job = DownloadJob(app: app, asset: asset, status: .failed, error: "keep this failure")
        let manager = DownloadManager(previewJobs: [job], saveJobs: { _ in throw ToolError.message("disk full") })
        XCTAssertThrowsError(try manager.refreshFailed(job.id, asset: asset))
        XCTAssertEqual(manager.jobs.first?.error, "keep this failure")
        XCTAssertEqual(manager.jobs.first?.status, .failed)
        XCTAssertThrowsError(try manager.enqueueURL(URL(string: "https://example.com/other.ipa")!))
        XCTAssertEqual(manager.jobs.count, 1)
        XCTAssertThrowsError(try manager.enqueueURL(URL(string: "https://user:password@example.com/private.ipa")!))
    }

    @MainActor
    func testUnexpectedCancellationDuringRestoreDoesNotLeaveRunningSlot() async throws {
        let job = DownloadJob(app: StoreApp(id: "1", name: "Test"), status: .running)
        let manager = DownloadManager(previewJobs: [job])
        var settings = ToolSettings(); settings.notifications = false
        manager.configure(settings)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.com/not-requested.ipa")!)
        task.taskDescription = job.id.uuidString
        manager.urlSession(session, task: task, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        for _ in 0..<100 {
            if manager.jobs.first?.status == .failed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(manager.jobs.first?.status, .failed)
    }

    @MainActor
    func testDownloadRedirectCannotDowngradeHTTPS() throws {
        let manager = DownloadManager(previewJobs: [])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.com/file.ipa")!
        let task = session.downloadTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: [:]))
        for address in ["http://example.com/insecure.ipa", "file:///private/file.ipa", "https://user:password@example.com/file.ipa"] {
            manager.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: address)!)) {
                XCTAssertNil($0)
            }
        }
        manager.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://cdn.example.com/file.ipa")!)) {
            XCTAssertEqual($0?.url?.host, "cdn.example.com")
        }
    }

    func testConcurrentLoopbackStartupSharesOneListener() async throws {
        let server = LoopbackServer()
        async let first: Void = server.start()
        async let second: Void = server.start()
        _ = try await (first, second)
        let base = try XCTUnwrap(server.baseURL)
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("runtime/index.html"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(data.isEmpty)
        try await server.start()
        XCTAssertEqual(server.baseURL, base)
    }

    func testArchivedAppNameSearchDoesNotNeedAnAccountOrLiveStoreResult() {
        let removed = StoreApp(id: "100", name: "旧时光相机", bundleID: "example.camera")
        let cached = StoreApp(id: "200", name: "Unpurchased Archive", bundleID: "example.archive")
        let imported = StoreApp(id: "local-file", name: "旧时光相机")
        XCTAssertEqual(AppSearchIndex.search("旧时光", apps: [removed, removed, imported]).map(\.id), ["100"])
        XCTAssertEqual(AppSearchIndex.search("UNPURCHASED", apps: [cached]).map(\.id), ["200"])
        XCTAssertEqual(AppSearchIndex.search("example.camera", apps: [removed]).map(\.id), ["100"])
        XCTAssertTrue(AppSearchIndex.search(" ", apps: [removed]).isEmpty)
        XCTAssertTrue(AppSearchIndex.search("从未记录", apps: [removed]).isEmpty)
    }

    func testDirectoryFindsRemovedAppOnFirstLaunchAndMatchesOldNames() throws {
        let entries = AppNameCatalog.bundled()
        XCTAssertEqual(AppNameCatalog.search("forward", platform: .iOS, entries: entries).map(\.id), ["6503940939"])
        XCTAssertEqual(AppNameCatalog.search("新视界", platform: .iOS, entries: entries).map(\.id), ["6503940939"])
        XCTAssertTrue(AppNameCatalog.search("Forward", platform: .tvOS, entries: entries).isEmpty)
        XCTAssertTrue(AppNameCatalog.search("  ", platform: .iOS, entries: entries).isEmpty)
        let corrupt = Data(#"[{"id":"https://invalid","name":"Invalid","aliases":[],"platform":"itunes","source":""}]"#.utf8)
        XCTAssertThrowsError(try AppNameCatalog.decode(corrupt))
    }

    func testPlaceholderRecordDoesNotHideMatchingCachedName() {
        let placeholder = StoreApp(id: "100", name: "100")
        let metadata = StoreApp(id: "100", name: "Forward - 新视界")
        XCTAssertEqual(AppSearchIndex.search("ＦＯＲＷＡＲＤ", apps: [placeholder, metadata]).map(\.id), ["100"])
        XCTAssertEqual(AppSearchIndex.search("Forward新视界", apps: [placeholder, metadata]).map(\.id), ["100"])
    }

    func testTransferRateUsesNewBytesAndExpiresWhenStalled() {
        var metric = TransferMetrics(bytes: 1_000_000, sampledAt: 100)
        metric.record(bytes: 1_500_000, at: 101)
        XCTAssertEqual(metric.rate(at: 101), 500_000, accuracy: 0.1)
        XCTAssertEqual(metric.remaining(expected: 2_500_000, at: 101), 2)
        XCTAssertNil(metric.remaining(expected: 0, at: 101))
        XCTAssertNil(metric.remaining(expected: 1_500_000, at: 101))
        XCTAssertEqual(metric.rate(at: 106), 0)
        XCTAssertNil(metric.remaining(expected: 2_500_000, at: 106))
        metric.record(bytes: 50_000, at: 107)
        XCTAssertEqual(metric.rate(at: 107), 0, "A restarted transfer must reset its baseline")
        metric.record(bytes: 100_000, at: 108)
        XCTAssertEqual(metric.rate(at: 108), 50_000, accuracy: 0.1)
        metric.record(bytes: 900_000, at: 130)
        XCTAssertEqual(metric.rate(at: 130), 0, "A suspension gap must not produce a stale rate")
    }

    func testPurchasedCacheWithoutArtworkStillDecodes() throws {
        let data = Data(#"{"id":"1","bundleID":"test.app","name":"Test","version":"1.0"}"#.utf8)
        var app = try JSONDecoder().decode(OwnedApp.self, from: data)
        XCTAssertNil(app.iconURL)
        app.iconURL = URL(string: "https://example.com/icon.png")
        let roundTrip = try JSONDecoder().decode(OwnedApp.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(roundTrip.storeApp.iconURL, app.iconURL)
        XCTAssertNil(StoreService.icon(""))
        XCTAssertNil(StoreService.icon("file:///private/icon.png"))
    }

    func testDownloadFiltersSeparateActivePausedAndFailed() {
        for status in [DownloadStatus.queued, .running, .pausing, .processing] { XCTAssertTrue(DownloadFilter.active.includes(status)) }
        for status in [DownloadStatus.paused, .failed, .completed] { XCTAssertFalse(DownloadFilter.active.includes(status)) }
        XCTAssertTrue(DownloadFilter.paused.includes(.paused))
        XCTAssertFalse(DownloadFilter.failed.includes(.paused))
        XCTAssertTrue(DownloadFilter.failed.includes(.failed))
        XCTAssertTrue(DownloadFilter.completed.includes(.completed))
        for status in [DownloadStatus.queued, .running, .pausing, .paused, .processing, .completed, .failed] { XCTAssertTrue(DownloadFilter.all.includes(status)) }
    }

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

    func testPackageIconUsesLargestPrimaryIconAndSeparatesVersions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func image(_ side: Int, color: UIColor) -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(side), height: CGFloat(side)), format: format).pngData { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            }
        }
        func package(_ version: String, color: UIColor) throws -> URL {
            let url = root.appendingPathComponent(version + ".ipa")
            let archive = try Archive(url: url, accessMode: .create)
            let info: [String: Any] = ["CFBundleIdentifier": "same.bundle", "CFBundleShortVersionString": version,
                "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]]
            let files: [String: Data] = [
                "Payload/Main.app/Info.plist": try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
                "Payload/Main.app/AppIcon60x60@2x.png": image(120, color: color),
                "Payload/Main.app/AppIcon60x60@3x.png": image(180, color: color),
                "Payload/Main.app/AlternateIcon.png": image(512, color: .green),
                "Payload/Main.app/PlugIns/Extension.appex/AppIcon.png": image(512, color: .green)
            ]
            for (path, data) in files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
                try archive.addEntry(with: path, relativeTo: root)
            }
            return url
        }
        let old = try package("1.0", color: .red), new = try package("2.0", color: .blue)
        let first = try XCTUnwrap(PackageIconService.png(from: old))
        let second = try XCTUnwrap(PackageIconService.png(from: new))
        XCTAssertEqual(UIImage(data: first)?.cgImage?.width, 180)
        XCTAssertNotEqual(first, second)
        let id1 = UUID(), id2 = UUID()
        defer {
            try? FileManager.default.removeItem(at: PackageIconService.cacheURL(id1))
            try? FileManager.default.removeItem(at: PackageIconService.cacheURL(id2))
        }
        XCTAssertTrue(try PackageIconService.save(from: old, id: id1))
        XCTAssertTrue(try PackageIconService.save(from: new, id: id2))
        XCTAssertNotEqual(try Data(contentsOf: PackageIconService.cacheURL(id1)), try Data(contentsOf: PackageIconService.cacheURL(id2)))
    }

    func testImportCoordinatesCopiesAndValidatesPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("应用.IPA")
        do {
            let archive = try Archive(url: source, accessMode: .create)
            let path = "Payload/Test.app/Info.plist"
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HTTPClient.encodePlist(["CFBundleDisplayName": "导入应用", "CFBundleIdentifier": "test.import", "CFBundleShortVersionString": "1.0"]).write(to: file)
            try archive.addEntry(with: path, relativeTo: root)
        }
        let original = try Data(contentsOf: source)
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: LocalResources.stagingURL(id)) }
        let app = try PackageImportService.prepare(source, id: id)
        XCTAssertEqual(app.bundleID, "test.import")
        XCTAssertEqual(try Data(contentsOf: LocalResources.stagingURL(id)), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let invalid = root.appendingPathComponent("invalid.ipa")
        try Data("not an archive".utf8).write(to: invalid)
        let rejected = UUID()
        XCTAssertThrowsError(try PackageImportService.prepare(invalid, id: rejected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalResources.stagingURL(rejected).path))
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
        XCTAssertNil(try PackageIconService.png(from: url), "A package without an icon must not receive store artwork")
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
