import XCTest
import UIKit
import ZIPFoundation
import CryptoKit
@testable import iPadn

final class CoreTests: XCTestCase {
    /// Assertions below check the Chinese copy: pin the language instead of
    /// following whatever the simulator is set to. Set `locale:` on the
    /// formatting calls whose numbers or currency symbols are asserted.
    override func setUp() {
        super.setUp()
        AppText.locale = Locale(identifier: "zh-Hans")
    }

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
    func testWatchRecordsVersionPriceAndRemovalChanges() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func listing(_ version: String, _ price: Double, _ currency: String = "CNY") -> StoreApp {
            StoreApp(id: "1", name: "A", version: version, priceValue: price, currency: currency)
        }
        // The first check only records what is there.
        var (record, changes) = WatchService.update(nil, id: "1", country: "cn", listing: listing("1.0", 30), now: start)
        XCTAssertEqual(changes, []); XCTAssertEqual(record.key, "1|CN"); XCTAssertEqual(record.history.count, 1)
        (record, changes) = WatchService.update(record, id: "1", country: "CN", listing: listing("1.1", 18), now: start + 60)
        XCTAssertEqual(Set(changes), [.newVersion("1.1"), .priceDrop(from: 30, to: 18)])
        XCTAssertEqual(record.change, .priceDrop(from: 30, to: 18)); XCTAssertEqual(record.history.map(\.price), [30, 18])
        // An unchanged price adds no point.
        (record, changes) = WatchService.update(record, id: "1", country: "CN", listing: listing("1.1", 18), now: start + 120)
        XCTAssertEqual(changes, []); XCTAssertEqual(record.history.count, 2)
        (record, changes) = WatchService.update(record, id: "1", country: "CN", listing: listing("1.1", 0), now: start + 180)
        XCTAssertEqual(changes, [.free(from: 18)])
        (record, changes) = WatchService.update(record, id: "1", country: "CN", listing: listing("1.1", 6), now: start + 240)
        XCTAssertEqual(changes, [.priceRise(from: 0, to: 6)])
        (record, changes) = WatchService.update(record, id: "1", country: "CN", listing: nil, now: start + 300)
        XCTAssertEqual(changes, [.delisted]); XCTAssertTrue(record.delisted)
        (record, changes) = WatchService.update(record, id: "1", country: "CN", listing: nil, now: start + 360)
        XCTAssertEqual(changes, [], "a removal is reported once")
        (record, changes) = WatchService.update(record, id: "1", country: "CN", listing: listing("1.1", 6), now: start + 420)
        XCTAssertEqual(changes, [.relisted]); XCTAssertFalse(record.delisted)
        // A different currency starts the history over instead of reporting a change.
        (record, changes) = WatchService.update(record, id: "1", country: "CN", listing: listing("1.1", 1, "USD"), now: start + 480)
        XCTAssertEqual(changes, []); XCTAssertEqual(record.history.map(\.price), [1]); XCTAssertEqual(record.currency, "USD")
        // Never seen listed: not a removal.
        XCTAssertEqual(WatchService.update(nil, id: "2", country: "CN", listing: nil, now: start).changes, [])
        XCTAssertNotNil(record.recentChange(now: start + 480))
        XCTAssertNil(record.recentChange(now: start + 8 * 86400))
        let savedLanguage = AppText.locale
        defer { AppText.locale = savedLanguage }
        AppText.locale = Locale(identifier: "zh-Hans")
        XCTAssertEqual(WatchService.format(0, currency: "CNY", locale: Locale(identifier: "zh_CN")), "免费")
        // The word follows the interface language, not the region.
        AppText.locale = Locale(identifier: "en")
        XCTAssertEqual(WatchService.format(0, currency: "CNY", locale: Locale(identifier: "zh_CN")), "Free")
        AppText.locale = Locale(identifier: "zh-Hans")
        XCTAssertTrue(WatchService.format(18, currency: "CNY", locale: Locale(identifier: "zh_CN")).contains("18"))
        XCTAssertTrue(WatchService.format(2.99, currency: "USD", locale: Locale(identifier: "zh_CN")).contains("2.99"))
        XCTAssertNil(WatchService.message(.priceRise(from: 1, to: 2), currency: "CNY"))
        // A target price silences drops that stay above it; free always counts.
        XCTAssertTrue(WatchService.notifies(.priceDrop(from: 30, to: 18), target: nil))
        XCTAssertFalse(WatchService.notifies(.priceDrop(from: 30, to: 18), target: 12))
        XCTAssertTrue(WatchService.notifies(.priceDrop(from: 30, to: 12), target: 12))
        XCTAssertTrue(WatchService.notifies(.free(from: 30), target: 12))
        XCTAssertTrue(WatchService.notifies(.newVersion("2.0"), target: 12))
        var targeted = WatchRecord(id: "9", country: "CN", started: start, checked: start)
        targeted.price = 30; targeted.currency = "CNY"; targeted.target = 12
        XCTAssertEqual(WatchService.update(targeted, id: "9", country: "CN", listing: listing("1.0", 25, "CNY"), now: start + 60).record.target, 12)
        XCTAssertNil(WatchService.update(targeted, id: "9", country: "CN", listing: listing("1.0", 3, "USD"), now: start + 60).record.target,
                     "a new currency makes the old target meaningless")
        XCTAssertEqual(WatchService.message(.newVersion("2.0"), currency: "CNY", locale: Locale(identifier: "zh_CN")), "有新版本 2.0")
        let raw: [String: Any] = ["trackId": 5, "trackName": "P", "price": 4.99, "currency": "USD", "formattedPrice": "$4.99"]
        XCTAssertEqual(StoreService.mapLookup(raw).priceValue, 4.99)
        XCTAssertEqual(StoreService.mapLookup(raw).currency, "USD")
    }

    func testRegionPricesConvertAndSortCheapestFirst() throws {
        let json = #"{"result":"success","base_code":"CNY","time_last_update_unix":1700000000,"rates":{"CNY":1,"USD":0.14,"TRY":4.5,"JPY":21}}"#
        let rates = try XCTUnwrap(ExchangeRates.parse(Data(json.utf8), base: "CNY"))
        XCTAssertEqual(rates.base, "CNY")
        XCTAssertEqual(try XCTUnwrap(rates.convert(1.4, from: "USD")), 10, accuracy: 0.0001)
        XCTAssertEqual(rates.convert(5, from: "CNY"), 5)
        XCTAssertNil(rates.convert(5, from: "XXX"))
        XCTAssertNil(ExchangeRates.parse(Data(#"{"result":"error"}"#.utf8), base: "CNY"))
        func region(_ country: String, _ price: Double?, _ currency: String) -> RegionPrice {
            RegionPrice(country: country, listing: price.map { StoreApp(id: "1", name: "A", priceValue: $0, currency: currency) })
        }
        let prices = [region("US", 2.99, "USD"), region("CN", 18, "CNY"), region("NG", nil, ""), region("XX", 1, "XXX"), region("TR", 49.99, "TRY")]
        XCTAssertEqual(PriceComparison.sorted(prices, rates: rates).map(\.country), ["TR", "CN", "US", "XX", "NG"])
        // Without rates the order stays as chosen, unlisted storefronts last.
        XCTAssertEqual(PriceComparison.sorted(prices, rates: nil).map(\.country), ["US", "CN", "XX", "TR", "NG"])
        XCTAssertTrue(StoreRegions.codes.count > 150)
        XCTAssertTrue(StoreRegions.defaultComparison.allSatisfy { StoreRegions.codes.contains($0) })
        XCTAssertEqual(StoreRegions.flag("cn"), "🇨🇳")
        XCTAssertEqual(StoreRegions.name("TR"), "土耳其")
    }

    func testInAppPurchasesParsedFromProductPageAndGroupedByTier() throws {
        // The shape of apps.apple.com's serialized page data (information section).
        let data = #"{"data":[{"shelves":[{"$kind":"Annotation","title":"Compatibility","items":[{"$kind":"textPair","leadingText":"iPhone","trailingText":"Requires iOS 15.0 or later."}]},"#
            + #"{"$kind":"Annotation","title":"In-App Purchases","summary":"Yes","items":[{"$kind":"textPair","leadingText":"Barrel of Gems (1200)","trailingText":"$4.99"},"#
            + #"{"$kind":"textPair","leadingText":"Super Duolingo","trailingText":"$9.99"},{"$kind":"textPair","leadingText":"Super Duolingo","trailingText":"$83.99"},"#
            + #"{"$kind":"button","action":{"title":"Learn More"}}]},{"$kind":"Annotation","title":"Copyright","summary":"© 2026","items":[]}]}]}"#
        let html = "<html><script type=\"application/json\" id=\"serialized-server-data\">" + data + "</script></html>"
        let items = try XCTUnwrap(InAppPriceService.items(fromPage: html))
        XCTAssertEqual(items.map(\.name), ["Barrel of Gems (1200)", "Super Duolingo", "Super Duolingo"])
        XCTAssertEqual(items.map(\.price), [4.99, 9.99, 83.99])
        XCTAssertNil(InAppPriceService.items(fromPage: "<html>no data</html>"))
        // A purchase listed twice (one per platform) counts once.
        let doubled = html.replacingOccurrences(of: #"{"$kind":"button""#,
                                                with: #"{"$kind":"textPair","leadingText":"Super Duolingo","trailingText":"$9.99"},{"$kind":"button""#)
        XCTAssertEqual(InAppPriceService.items(fromPage: doubled)?.count, 3)
        XCTAssertEqual(InAppPriceService.items(fromPage: html.replacingOccurrences(of: "In-App Purchases\",\"summary\":\"Yes\",\"items\":[", with: "X\",\"items\":[{\"$kind\":\"textPair\",\"leadingText\":\"a\",\"trailingText\":\"many words here\"},"))?.count, 0)

        XCTAssertEqual(InAppPriceService.price("$1,099"), 1099)
        XCTAssertEqual(InAppPriceService.price("1.299,99 €"), 1299.99)
        XCTAssertEqual(InAppPriceService.price("Rp 15.000"), 15000)
        XCTAssertEqual(InAppPriceService.price("199,99 TL"), 199.99)
        XCTAssertEqual(InAppPriceService.price("¥160"), 160)
        XCTAssertEqual(InAppPriceService.price("1 299,00 kr"), 1299)
        XCTAssertTrue(InAppPriceService.looksLikePrice("HK$38.00"))
        XCTAssertFalse(InAppPriceService.looksLikePrice("Requires iOS 15.0 or later."))

        let json = #"{"result":"success","base_code":"CNY","rates":{"CNY":1,"USD":0.14,"TRY":4.5}}"#
        let rates = try XCTUnwrap(ExchangeRates.parse(Data(json.utf8), base: "CNY"))
        let us = [InAppPrice(name: "Super", text: "$9.99", price: 9.99), InAppPrice(name: "Super", text: "$83.99", price: 83.99),
                  InAppPrice(name: "Gems", text: "$4.99", price: 4.99)]
        let tr = [InAppPrice(name: "Gems", text: "99,99 TL", price: 99.99), InAppPrice(name: "Super", text: "1.499,99 TL", price: 1499.99),
                  InAppPrice(name: "Super", text: "149,99 TL", price: 149.99)]
        let groups = InAppPriceService.groups([("US", "USD", us), ("TR", "TRY", tr)], rates: rates)
        XCTAssertEqual(groups.map(\.id), ["Super#0", "Super#1", "Gems#0"])
        XCTAssertEqual(groups[0].tiers, 2)
        // Monthly with monthly: $9.99 ≈ ¥71 against 149.99 TL ≈ ¥33, cheapest first.
        XCTAssertEqual(groups[0].entries.map(\.country), ["TR", "US"])
        XCTAssertEqual(groups[0].entries.first?.item.price, 149.99)
        XCTAssertEqual(groups[1].entries.map(\.item.price), [1499.99, 83.99])

        // English names match across storefronts; the same storefront's page in
        // the system language pairs up item by item for display.
        let english = [InAppPrice(name: "Lifetime access", text: "¥68.00", price: 68), InAppPrice(name: "Monthly", text: "¥15.00", price: 15)]
        let chinese = [InAppPrice(name: "终身解锁", text: "¥68.00", price: 68), InAppPrice(name: "月度订阅", text: "¥15.00", price: 15)]
        XCTAssertEqual(InAppPriceService.nameMap(english: english, localized: chinese), ["Lifetime access": "终身解锁", "Monthly": "月度订阅"])
        XCTAssertEqual(InAppPriceService.nameMap(english: english, localized: chinese.reversed()), [:], "prices must line up")
        XCTAssertEqual(InAppPriceService.nameMap(english: english, localized: Array(chinese.prefix(1))), [:])
        XCTAssertEqual(InAppPriceService.nameMap(english: english, localized: english), [:], "an English page names nothing")
        XCTAssertEqual(InAppPriceService.nameRegions(language: "zh-Hans-CN"), ["CN"])
        XCTAssertEqual(InAppPriceService.nameRegions(language: "zh-Hant-HK").first, "HK")
        XCTAssertEqual(InAppPriceService.nameRegions(language: "ja-CN").first, "JP", "a Japanese interface reads Japanese names, not the CN storefront's")
        XCTAssertEqual(InAppPriceService.nameRegions(language: "pt-PT").first, "PT")
        XCTAssertEqual(InAppPriceService.nameRegions(language: "pt-BR").first, "BR")
        XCTAssertEqual(InAppPriceService.nameRegions(language: "ar-CN").first, "SA")
        XCTAssertEqual(InAppPriceService.nameRegions(language: "it-IT"), ["IT"])
    }

    func testReleaseNotesReadFromVersionHistory() throws {
        // The shape of apps.apple.com's version history (TitledParagraph items).
        let data = #"{"shelves":{"mostRecentVersion":{"items":[{"$kind":"TitledParagraph","text":"Bug fixes.\n","primarySubtitle":"Version 1.2026.272","secondarySubtitle":"Tue Oct 06 2026 18:07:01 GMT+0000 (Coordinated Universal Time)"}]},"#
            + #""history":{"items":[{"$kind":"TitledParagraph","text":"Bug fixes.","primarySubtitle":"Version 1.2026.272"},"#
            + #"{"$kind":"TitledParagraph","text":"新增评分来源","primarySubtitle":"版本 8.3.1","secondarySubtitle":"Mon Sep 01 2025 08:00:00 GMT+0000 (UTC)"},"#
            + #"{"$kind":"TitledParagraph","text":"Not a version","primarySubtitle":"Developer Response"}]}}}"#
        let html = "<script type=\"application/json\" id=\"serialized-server-data\">" + data + "</script>"
        let notes = ReleaseNotesService.parse(html)
        XCTAssertEqual(Set(notes.keys), ["1.2026.272", "8.3.1"])
        XCTAssertEqual(notes["1.2026.272"]?.text, "Bug fixes.")
        XCTAssertEqual(notes["1.2026.272"]?.date, Date(timeIntervalSince1970: 1_791_310_021))
        XCTAssertEqual(notes["8.3.1"]?.text, "新增评分来源")
        XCTAssertEqual(ReleaseNotesService.version(in: "Version 2.0"), "2.0")
        XCTAssertEqual(ReleaseNotesService.version(in: "バージョン4.8"), "4.8")
        XCTAssertNil(ReleaseNotesService.version(in: "What’s New"))
        XCTAssertTrue(ReleaseNotesService.parse("<html></html>").isEmpty)
    }

    func testAppReleaseParsedFromGitHub() throws {
        let json = ###"{"tag_name":"v1.7.0","html_url":"https://github.com/mengangs/ipadn/releases/tag/v1.7.0","draft":false,"prerelease":false,"published_at":"2026-10-16T08:00:00Z","body":"## 1.7.0\n- 关注应用\n\n验证：设备 Release 编译与 IPA 检查通过。","assets":[{"name":"iPadn-1.7.0-unsigned.ipa.sha256","browser_download_url":"https://github.com/x.sha256","size":90},{"name":"iPadn-1.7.0-unsigned.ipa","browser_download_url":"https://github.com/mengangs/ipadn/releases/download/v1.7.0/iPadn-1.7.0-unsigned.ipa","size":52000000}]}"###
        let release = try XCTUnwrap(AppUpdateService.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.7.0")
        XCTAssertEqual(release.notes, "## 1.7.0\n- 关注应用")
        XCTAssertEqual(release.package?.lastPathComponent, "iPadn-1.7.0-unsigned.ipa")
        XCTAssertEqual(release.packageSize, 52_000_000)
        XCTAssertNotNil(release.published)
        XCTAssertEqual(AppUpdateService.newer(release, than: "1.6.0")?.version, "1.7.0")
        XCTAssertNil(AppUpdateService.newer(release, than: "1.7.0"))
        XCTAssertNil(AppUpdateService.newer(release, than: "1.10.0"))
        XCTAssertNil(AppUpdateService.parse(Data(json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8)))
        XCTAssertEqual(AppUpdateService.trollStoreURL(for: release)?.scheme, "apple-magnifier")
        // The test host was not installed by TrollStore, so its button stays hidden.
        XCTAssertFalse(AppUpdateService.installedByTrollStore)

        // When GitHub lists `-lite-unsigned.ipa` alphabetically before `-unsigned.ipa`,
        // `package` must still resolve to Standard while `litePackage` captures Lite.
        let dualJSON = ###"{"tag_name":"v2.2.1","html_url":"https://github.com/mengangs/ipadn/releases/tag/v2.2.1","draft":false,"prerelease":false,"published_at":"2026-11-18T10:00:00Z","body":"## iPadn 2.2.1\n- Fix","assets":[{"name":"build-info.json","browser_download_url":"https://github.com/mengangs/ipadn/releases/download/v2.2.1/build-info.json","size":240},{"name":"iPadn-2.2.1-lite-unsigned.ipa","browser_download_url":"https://github.com/mengangs/ipadn/releases/download/v2.2.1/iPadn-2.2.1-lite-unsigned.ipa","size":49800000},{"name":"iPadn-2.2.1-lite-unsigned.ipa.sha256","browser_download_url":"https://github.com/x-lite.sha256","size":95},{"name":"iPadn-2.2.1-unsigned.ipa","browser_download_url":"https://github.com/mengangs/ipadn/releases/download/v2.2.1/iPadn-2.2.1-unsigned.ipa","size":50742804}]}"###
        let dual = try XCTUnwrap(AppUpdateService.parse(Data(dualJSON.utf8)))
        XCTAssertTrue(dual.hasBothVariants)
        XCTAssertEqual(dual.package?.lastPathComponent, "iPadn-2.2.1-unsigned.ipa")
        XCTAssertEqual(dual.packageSize, 50_742_804)
        XCTAssertEqual(dual.litePackage?.lastPathComponent, "iPadn-2.2.1-lite-unsigned.ipa")
        XCTAssertEqual(dual.litePackageSize, 49_800_000)
        XCTAssertEqual(AppUpdateService.defaultVariant(for: dual, preferred: .standard), .standard)
        XCTAssertEqual(AppUpdateService.defaultVariant(for: dual, preferred: .lite), .lite)
        XCTAssertEqual(AppUpdateService.packageFile(for: dual, variant: .standard).lastPathComponent, "iPadn-2.2.1.ipa")
        XCTAssertEqual(AppUpdateService.packageFile(for: dual, variant: .lite).lastPathComponent, "iPadn-2.2.1-lite.ipa")
        for variant in [AppRelease.Variant.standard, .lite] {
            let updateURL = try XCTUnwrap(AppUpdateService.trollStoreURL(for: dual, variant: variant))
            let components = try XCTUnwrap(URLComponents(url: updateURL, resolvingAgainstBaseURL: false))
            let expected = try XCTUnwrap(variant == .standard ? dual.package : dual.litePackage)
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "url", value: expected.absoluteString)])
        }
    }

    func testReleaseNotesBecomeBlocksWithoutTheVersionTitle() {
        let notes = "## iPadn 1.7.1\n\n适用于 iOS 17。\n\n### 改进\n\n- 外观默认跟随系统\n* 更新提醒\n\n更早版本见 [Releases](https://github.com/mengangs/ipadn/releases)。"
        XCTAssertEqual(AppUpdateService.blocks(notes, version: "1.7.1"), [
            .paragraph("适用于 iOS 17。"), .heading("改进"), .bullet("外观默认跟随系统"), .bullet("更新提醒"),
            .paragraph("更早版本见 [Releases](https://github.com/mengangs/ipadn/releases)。")
        ])
        // A heading that is not the version title is kept.
        XCTAssertEqual(AppUpdateService.blocks("### 新功能\n- A", version: "1.7.1"), [.heading("新功能"), .bullet("A")])
    }

    func testDownloadedUpdatePackageIsKeptOnlyWhenComplete() throws {
        let page = try XCTUnwrap(URL(string: "https://github.com/mengangs/ipadn/releases/tag/v9.9.9"))
        var release = AppRelease(version: "9.9.9", notes: "", page: page, package: page, packageSize: 4, published: nil)
        AppUpdateService.removeDownloads()
        defer { AppUpdateService.removeDownloads() }
        XCTAssertNil(AppUpdateService.downloadedPackage(for: release))
        try FileManager.default.createDirectory(at: AppUpdateService.packageFolder, withIntermediateDirectories: true)
        try Data("ipa!".utf8).write(to: AppUpdateService.packageFile(for: release))
        XCTAssertEqual(AppUpdateService.downloadedPackage(for: release), AppUpdateService.packageFile(for: release))
        release.packageSize = 5
        XCTAssertNil(AppUpdateService.downloadedPackage(for: release))
    }

    func testPurchaseListExportsAsCSV() {
        let apps = [OwnedApp(id: "1", bundleID: "a.b", name: "Notes, \"Pro\"", version: "2.0", purchaseDate: nil, iconURL: nil),
                    OwnedApp(id: "2", bundleID: "c.d", name: "Gone", version: "1.0", purchaseDate: nil, iconURL: nil),
                    OwnedApp(id: "3", bundleID: "e.f", name: "Plain", version: "3.1", purchaseDate: nil, iconURL: nil)]
        let csv = PurchaseExport.csv(apps, listed: ["1": true, "2": false], downloaded: ["2"])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "名称,App ID,Bundle ID,版本,购买日期,商店状态,已下载")
        XCTAssertEqual(lines[1], "\"Notes, \"\"Pro\"\"\",1,a.b,2.0,,在售,否")
        XCTAssertEqual(lines[2], "Gone,2,c.d,1.0,,已下架,是")
        XCTAssertEqual(lines[3], "Plain,3,e.f,3.1,,未检查,否")
        XCTAssertEqual(lines.last, "")
        XCTAssertEqual(PurchaseExport.field("a\nb"), "\"a\nb\"")
    }

    @MainActor
    func testPackagedIconChoicesMatchCurrentDevice() throws {
        typealias Selection = AppIconService.Selection
        XCTAssertNil(Selection(style: .dimensional, theme: .dark).alternateName)
        XCTAssertEqual(AppIconService.systemSelection(for: nil), AppIconService.primary)
        XCTAssertEqual(AppIconService.systemSelection(for: "AppIconDark"), AppIconService.primary)
        XCTAssertEqual(Selection(style: .dimensional, theme: .automatic).alternateName, "AppIconAuto")
        XCTAssertEqual(Selection(style: .flat, theme: .automatic).alternateName, "AppIconFlat")
        XCTAssertEqual(Selection(style: .flat, theme: .light).alternateName, "AppIconFlatLight")
        for style in AppIconService.Choice.allCases {
            for theme in AppIconService.Theme.allCases {
                let selection = Selection(style: style, theme: theme)
                XCTAssertEqual(AppIconService.systemSelection(for: selection.alternateName), selection)
                if let name = selection.alternateName { XCTAssertTrue(AppIconService.bundledAlternateIsAvailable(name), name) }
            }
        }
        XCTAssertEqual(AppIconService.systemChoice(for: nil), .dimensional)
        // After an update the system may report no alternate while the Home
        // Screen still shows one: trust the remembered icon if it is bundled.
        XCTAssertEqual(AppIconService.effectiveSelection(reported: nil, remembered: "AppIconLight", isBundled: { _ in true }),
                       Selection(style: .dimensional, theme: .light))
        XCTAssertEqual(AppIconService.effectiveSelection(reported: nil, remembered: "AppIconLight", isBundled: { _ in false }), AppIconService.primary)
        XCTAssertEqual(AppIconService.effectiveSelection(reported: "AppIconFlat", remembered: "AppIconLight", isBundled: { _ in true }),
                       Selection(style: .flat, theme: .automatic))
        XCTAssertEqual(AppIconService.effectiveSelection(reported: nil, remembered: nil), AppIconService.primary)
        XCTAssertEqual(AppIconService.systemChoice(for: "AppIconFlat"), .flat)
        XCTAssertEqual(AppIconService.systemChoice(for: "some-other-icon"), .dimensional)
        XCTAssertTrue(AppIconService.isTransientIconError(NSError(domain: NSPOSIXErrorDomain, code: 35)))
        XCTAssertFalse(AppIconService.isTransientIconError(NSError(domain: NSCocoaErrorDomain, code: 3072)))
        // Xcode thins simulator builds to the selected device. Both idioms are
        // checked separately in the unthinned device IPA by verify_ipa.py.
        let key = UIDevice.current.userInterfaceIdiom == .pad ? "CFBundleIcons~ipad" : "CFBundleIcons"
        let icons = try XCTUnwrap(Bundle.main.infoDictionary?[key] as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        let flat = try XCTUnwrap(alternates["AppIconFlat"] as? [String: Any])
        XCTAssertFalse(try XCTUnwrap(flat["CFBundleIconFiles"] as? [String]).isEmpty)
        XCTAssertNotNil(Bundle.main.url(forResource: "AppIconFlat60x60@2x", withExtension: "png"))
        XCTAssertTrue(AppIconService.bundledAlternateIsAvailable())
        XCTAssertNotNil(UIImage(named: AppIconService.Choice.dimensional.preview))
        XCTAssertNotNil(UIImage(named: AppIconService.Choice.flat.preview))
        XCTAssertTrue(UIApplication.shared.supportsAlternateIcons)
    }
    func testAppleCredentialError2002RequiresExplicitReauthentication() {
        XCTAssertTrue(AppleAuthError.requiresReauthentication(["failureType": "2002"]))
        XCTAssertFalse(AppleAuthError.requiresReauthentication(["failureType": "9610"]))
        XCTAssertFalse(AppleAuthError.requiresReauthentication(["failureType": "2034"]))
    }

    func testDownloadPlatformLabelsAndFriendlyAppleErrors() throws {
        let app = StoreApp(id: "123", name: "Test")
        let url = URL(string: "https://example.org/download.ipa")!
        let asset = DownloadAsset(app: app, url: url, sinf: nil, metadata: nil,
                                  externalVersionIDs: [], platform: "appletvos", account: "test@example.org")
        XCTAssertEqual(DownloadJob(app: app, asset: asset).platformLabel, "tvOS")
        var modified = asset
        modified.platform = "ipad"
        XCTAssertEqual(DownloadJob(app: app, asset: modified).platformLabel, "iPad")
        modified.platform = "ios"
        XCTAssertEqual(DownloadJob(app: app, asset: modified).platformLabel, "iOS")
        XCTAssertEqual(DownloadJob(app: app, rawFormat: "dmg").platformLabel, "Mac")
        XCTAssertEqual(DownloadJob(app: app).platformLabel, "IPA")
        let message = try XCTUnwrap(HTTPClient.appleFailure([
            "failureType": "2002", "customerMessage": "Your password has changed."
        ])?.localizedDescription)
        XCTAssertTrue(message.contains("重新登录"))
        XCTAssertFalse(message.contains("2002"))
        XCTAssertFalse(message.contains("Your password"))
        let searchError = AppErrorMessage.forSearch(ToolError.message("Your password has changed.(2002)"))
        XCTAssertTrue(searchError.contains("重新登录"))
        XCTAssertFalse(searchError.contains("2002"))
        let mismatch = AppleStorefrontDownloadError(
            reason: .accountRegionMismatch(accountRegion: "US", storeRegion: "CN"),
            targetCountry: "CN"
        )
        let prevLocale = AppText.locale
        defer { AppText.locale = prevLocale }
        AppText.locale = Locale(identifier: "zh-Hans")
        let mismatchZh = mismatch.localizedDescription
        XCTAssertTrue(mismatchZh.contains("美国") || mismatchZh.contains("US"))
        XCTAssertTrue(mismatchZh.contains("中国") || mismatchZh.contains("CN"))
        AppText.locale = Locale(identifier: "en")
        let mismatchEn = mismatch.localizedDescription
        XCTAssertTrue(mismatchEn.lowercased().contains("region"))
    }

    func testTvOSDownloadPreservesAndRestoresArtwork() {
        let storeArtwork = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/tv-app.png")!
        let localArtwork = URL(fileURLWithPath: "/tmp/extracted-icon.png")
        let catalog = StoreApp(id: "1628995509", name: "TV Player",
                               version: "1.0.9", iconURL: storeArtwork)
        let dispatch = StoreApp(id: catalog.id, name: catalog.name, version: catalog.version)
        let asset = DownloadAsset(app: dispatch,
                                  url: URL(string: "https://example.com/package.ipa")!,
                                  externalVersionIDs: [], platform: "appletvos", account: "test")
        let requested = DownloadJob(app: catalog, asset: asset)
        let inspected = StoreApp(id: catalog.id, name: catalog.name, version: catalog.version)
        let completed = requested.completing(with: inspected)
        XCTAssertEqual(completed.iconURL, storeArtwork,
                       "IPA inspection must not discard catalog artwork")
        XCTAssertEqual(DownloadJob(app: completed, asset: asset)
            .displayApp(packageIcon: nil).iconURL, storeArtwork)
        XCTAssertEqual(requested.displayApp(packageIcon: localArtwork).iconURL, localArtwork)

        let lostArtwork = DownloadJob(app: inspected,
                                     asset: DownloadAsset(app: catalog, url: asset.url,
                                                          externalVersionIDs: [], platform: "appletvos",
                                                          account: "test"), status: .completed)
        XCTAssertEqual(lostArtwork.displayApp(packageIcon: nil).iconURL, storeArtwork)
    }

    func testAppleTVListingReplacesSharedIPhoneDetailsAndPackagePlatformIsReadable() {
        let phone = StoreApp(id: "1628995509", name: "TV Player", version: "2.0",
                             iconURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/phone.png"), size: 90_000_000)
        let tv = StoreApp(id: phone.id, name: phone.name, version: "1.0.9",
                          iconURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/tv.png"), size: 30_000_000,
                          externalVersionID: "850000001")
        let merged = StoreService.mergingAppleTVListing(tv, into: phone)
        XCTAssertEqual(merged.iconURL, tv.iconURL)
        XCTAssertEqual(merged.size, 30_000_000)
        XCTAssertEqual(merged.version, "1.0.9")
        XCTAssertEqual(merged.externalVersionID, "850000001")
        XCTAssertEqual(merged.name, "TV Player")
        let unchanged = StoreService.mergingAppleTVListing(StoreApp(id: phone.id, name: ""), into: phone)
        XCTAssertEqual(unchanged.iconURL, phone.iconURL)
        XCTAssertEqual(unchanged.size, phone.size)

        let prevLocale = AppText.locale
        defer { AppText.locale = prevLocale }
        AppText.locale = Locale(identifier: "zh-Hans")
        XCTAssertEqual(PackageService.describePlatforms(families: [3], platforms: ["AppleTVOS"]), "Apple TV")
        let dualZh = PackageService.describePlatforms(families: [2, 1], platforms: ["iPhoneOS"])
        XCTAssertTrue(dualZh.contains("iPhone") && dualZh.contains("iPad"))
        XCTAssertEqual(PackageService.describePlatforms(families: [], platforms: []), "未知")
        AppText.locale = Locale(identifier: "en")
        XCTAssertEqual(PackageService.describePlatforms(families: [2, 1], platforms: ["iPhoneOS"]), "iPhone and iPad")
        XCTAssertEqual(PackageService.describePlatforms(families: [], platforms: []), "Unknown")
    }

    @MainActor
    func testCatalogArtworkCanBecomeLocalPNG() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        let data = renderer.pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let normalized = PackageIconService.normalizedArtwork(data)
        XCTAssertNotNil(normalized)
        XCTAssertNotNil(normalized.flatMap(UIImage.init(data:)))
        XCTAssertNil(PackageIconService.normalizedArtwork(Data("not an image".utf8)))
    }

    func testPlatformSearchEntitiesAndIPASupport() {
        XCTAssertEqual(AppPlatform.iOS.searchEntity, "software")
        XCTAssertEqual(AppPlatform.iPadOS.searchEntity, "iPadSoftware")
        XCTAssertEqual(AppPlatform.tvOS.searchEntity, "software,tvSoftware")
        XCTAssertEqual(AppPlatform.macOS.searchEntity, "macSoftware")
        XCTAssertEqual(AppPlatform.iPadOS.catalogPlatform, AppPlatform.iOS.rawValue)
        XCTAssertFalse(AppPlatform.macOS.supportsIPA)
        XCTAssertTrue(AppPlatform.iPadOS.supportsIPA)
        XCTAssertTrue(AppPlatform.tvOS.supportsIPA)
    }

    func testVersionSourcesMergeWithoutDependingOnResponseOrder() {
        let first = [
            AppVersion(id: "100", version: "未知版本", source: "Timbrd"),
            AppVersion(id: "99", version: "1.0", source: "Timbrd")
        ]
        let second = [
            AppVersion(id: "100", version: "2.0", source: "Bilin"),
            AppVersion(id: "98", version: "0.9", source: "Bilin")
        ]
        let result = VersionService.mergeSourceResults([first, second])
        XCTAssertEqual(result.map(\.id), ["100", "99", "98"])
        XCTAssertEqual(result.first?.version, "2.0")
        XCTAssertEqual(result.first?.source, "Timbrd、Bilin")
        XCTAssertEqual(VersionService.mergeSourceResults([[], second]).count, 2)
        XCTAssertTrue(VersionService.mergeSourceResults([[], []]).isEmpty)
    }

    @MainActor
    func testViewingAppleHistoryNeverRequestsFreeAppLicense() {
        XCTAssertFalse(AppleService.shouldAcquireLicense(
            failure: "9610", purchased: false, allowLicenseAcquisition: false))
        XCTAssertTrue(AppleService.shouldAcquireLicense(
            failure: "9610", purchased: false, allowLicenseAcquisition: true))
        XCTAssertFalse(AppleService.shouldAcquireLicense(
            failure: "9610", purchased: true, allowLicenseAcquisition: true))
        XCTAssertFalse(AppleService.shouldAcquireLicense(
            failure: "2002", purchased: false, allowLicenseAcquisition: true))
    }

    func testTVStoreOfferVersionAndSearchMetadata() {
        XCTAssertEqual(StoreService.platformExternalVersionID(
            version: ["externalId": 892773268],
            buyParams: "salableAdamId=123&appExtVrsId=111"), "892773268")
        XCTAssertEqual(StoreService.platformExternalVersionID(
            version: [:],
            buyParams: "salableAdamId=123&appExtVrsId=892773268"), "892773268")
        XCTAssertNil(StoreService.platformExternalVersionID(version: [:], buyParams: "salableAdamId=123"))
        XCTAssertNil(StoreService.platformExternalVersionID(version: [:], buyParams: "appExtVrsId=0"))
        XCTAssertTrue(StoreService.supportsAppleTV(["supportedDevices": ["AppleTV4K", "iPhone16,1"]]))
        XCTAssertTrue(StoreService.supportsAppleTV(["platforms": ["tvos"]]))
        XCTAssertFalse(StoreService.supportsAppleTV(["supportedDevices": ["iPhone16,1", "iPad14,3"]]))
        XCTAssertFalse(StoreService.supportsAppleTV([:]))
    }

    func testPackageContentsListFoldersAndExtractOneFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("contents.ipa")
        let archive = try Archive(url: url, accessMode: .create)
        let contents = ["Payload/Target.app/Info.plist": Data("<plist/>".utf8),
                        "Payload/Target.app/en.lproj/Main.strings": Data(repeating: 65, count: 4096),
                        "iTunesMetadata.plist": Data("x".utf8)]
        for (path, data) in contents {
            let target = root.appendingPathComponent("src").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            try archive.addEntry(with: path, relativeTo: root.appendingPathComponent("src"), compressionMethod: .deflate)
        }
        let items = try PackageContents.items(url)
        XCTAssertEqual(PackageContents.children(of: "", in: items).map(\.name), ["Payload", "iTunesMetadata.plist"])
        XCTAssertEqual(PackageContents.children(of: "Payload/Target.app", in: items).map(\.name), ["en.lproj", "Info.plist"])
        let strings = try XCTUnwrap(items.first { $0.name == "Main.strings" })
        XCTAssertEqual(strings.size, 4096)
        let extracted = try PackageContents.extract(strings.path, from: url)
        defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: extracted), contents["Payload/Target.app/en.lproj/Main.strings"])
        XCTAssertThrowsError(try PackageContents.extract("Payload/Target.app", from: url))
        XCTAssertThrowsError(try PackageContents.extract("../etc/passwd", from: url))
    }
    func testProModeIsOffByDefaultAndRandomDeviceIDsAreValid() throws {
        XCTAssertFalse(ToolSettings().proMode)
        let data = try JSONSerialization.data(withJSONObject: ["proMode": true])
        XCTAssertTrue(try JSONDecoder().decode(ToolSettings.self, from: data).proMode)
        let id = AppleService.randomGUID()
        XCTAssertEqual(id.count, 12)
        XCTAssertTrue(id.allSatisfy(\.isHexDigit))
        XCTAssertNotNil(MacPackageOffer.serialNumber(guid: id))
    }
    func testActualIPAFamilyMustMatchRequestedPlatform() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func package(family: Int, platform: String = "iPhoneOS") throws -> URL {
            let url = root.appendingPathComponent("\(family)-\(platform).ipa")
            let archive = try Archive(url: url, accessMode: .create)
            let contents = [
                "Payload/Target.app/Info.plist": try HTTPClient.encodePlist([
                    "CFBundleIdentifier": "test.platform",
                    "CFBundleDisplayName": "Platform Test",
                    "CFBundleShortVersionString": "1.0",
                    "UIDeviceFamily": [family],
                    "CFBundleSupportedPlatforms": [platform]
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

        let tvIPA = try package(family: 3, platform: "AppleTVOS")
        let wrongTVIPA = try package(family: 3, platform: "iPhoneOS")
        let phoneIPA = try package(family: 1)
        XCTAssertEqual(try PackageService.deviceFamilies(tvIPA), Set([3]))
        XCTAssertEqual(try PackageService.supportedPlatforms(tvIPA), Set(["AppleTVOS"]))
        XCTAssertEqual(try PackageService.supportedPlatforms(wrongTVIPA), Set(["iPhoneOS"]))
        XCTAssertEqual(try PackageService.deviceFamilies(phoneIPA), Set([1]))
        let metadata = try HTTPClient.encodePlist(["itemId": "1"])
        let app = StoreApp(id: "1", name: "Platform Test", bundleID: "test.platform", version: "1.0")
        let tvAsset = DownloadAsset(app: app, url: URL(string: "https://example.com/file.ipa")!,
                                    sinf: Data([1, 2]), metadata: metadata, externalVersionIDs: [],
                                    platform: "appletvos", account: "example")
        XCTAssertThrowsError(try PackageService.finish(staging: phoneIPA, id: UUID(), asset: tvAsset))
        XCTAssertThrowsError(try PackageService.finish(staging: wrongTVIPA, id: UUID(), asset: tvAsset))
        let iPadAsset = DownloadAsset(app: app, url: URL(string: "https://example.com/file.ipa")!,
                                     sinf: Data([1, 2]), metadata: metadata, externalVersionIDs: [],
                                     platform: "ipad", account: "example")
        XCTAssertThrowsError(try PackageService.finish(staging: phoneIPA, id: UUID(), asset: iPadAsset))
    }

    func testAppleMacPKGOfferRejectsMobileAndIncorrectVersions() throws {
        let metadata: [String: Any] = [
            "itemId": "6503940939",
            "softwareVersionExternalIdentifier": "112233",
            "softwareVersionBundleId": "test.native.mac",
            "bundleShortVersionString": "1.2.3",
            "software-platform": "macos",
            "product-type": "mac-os-app"
        ]
        let url = "https://cdn.example.org/authorized-file"
        func response(_ fields: [String: Any] = [:], sinfs: [[String: Any]] = [],
                      downloadURL: String? = nil) -> [String: Any] {
            var values = metadata
            for (key, value) in fields { values[key] = value }
            return ["songList": [["metadata": values, "URL": downloadURL ?? url, "sinfs": sinfs]]]
        }
        let plain = try MacPackageOffer.validate(response(), appID: "6503940939",
            bundleID: "test.native.mac", versionID: "112233")
        XCTAssertFalse(plain.protectedByApple)
        XCTAssertEqual(plain.displayVersion, "1.2.3")
        XCTAssertEqual(plain.downloadURL.absoluteString, url)
        let protected = try MacPackageOffer.validate(
            response(sinfs: [["dpInfo": Data([1, 2, 3])]]),
            appID: "6503940939", bundleID: "test.native.mac", versionID: "112233")
        XCTAssertTrue(protected.protectedByApple)
        XCTAssertEqual(protected.dpInfo, Data([1, 2, 3]))
        XCTAssertNil(plain.dpInfo)
        XCTAssertThrowsError(try MacPackageOffer.validate(
            response(sinfs: [["sinf": Data([9, 9]), "id": 0]]), appID: "6503940939",
            bundleID: "test.native.mac", versionID: "112233"))
        XCTAssertEqual(MacPackageOffer.serialNumber(guid: "AABBCCDDEEFF"), "VMiwqYjM3e7/")
        XCTAssertNil(MacPackageOffer.serialNumber(guid: "AABBCCDDEE"))
        XCTAssertNil(MacPackageOffer.serialNumber(guid: "AABBCCDDEEFG"))
        XCTAssertThrowsError(try MacPackageOffer.validate(
            response(["software-platform": "iphoneos"]), appID: "6503940939",
            bundleID: "test.native.mac", versionID: "112233"))
        XCTAssertThrowsError(try MacPackageOffer.validate(
            response(["softwareVersionExternalIdentifier": "998877"]),
            appID: "6503940939", bundleID: "test.native.mac", versionID: "112233"))
        XCTAssertThrowsError(try MacPackageOffer.validate(
            response(["softwareVersionBundleId": "other.app"]),
            appID: "6503940939", bundleID: "test.native.mac", versionID: "112233"))
        XCTAssertThrowsError(try MacPackageOffer.validate(
            response(downloadURL: "http://example.org/pkg"),
            appID: "6503940939", bundleID: "test.native.mac", versionID: "112233"))
        XCTAssertThrowsError(try MacPackageOffer.validate(
            response(sinfs: [["dpInfo": Data([1])], ["dpInfo": Data([2])]]),
            appID: "6503940939", bundleID: "test.native.mac", versionID: "112233"))
        // Delisted apps have no product page to read the version from: any
        // numeric version is accepted, but it must still be macOS.
        let delisted = try MacPackageOffer.validate(response(), appID: "6503940939",
            bundleID: "test.native.mac", versionID: nil)
        XCTAssertEqual(delisted.versionID, "112233")
        XCTAssertThrowsError(try MacPackageOffer.validate(
            response(["software-platform": "iphoneos"]), appID: "6503940939",
            bundleID: "test.native.mac", versionID: nil))
        XCTAssertThrowsError(try MacPackageOffer.validate(
            response(["softwareVersionExternalIdentifier": ""]), appID: "6503940939",
            bundleID: "test.native.mac", versionID: nil))
    }

    @MainActor
    func testOfficialMacPKGOnlyEnqueuesUnprotectedAuthorizedOffer() throws {
        let app = StoreApp(id: "6503940939", name: "Native Mac", version: "1")
        let url = URL(string: "https://cdn.example.org/authorized-file")!
        let manager = DownloadManager(previewJobs: [])
        // Simulator builds never link the StoreAgent bridge, so a protected
        // package must be refused instead of being saved as a fake PKG.
        XCTAssertFalse(MacPackageDecryptor.isAvailable)
        let encrypted = MacPackageOffer(downloadURL: url, versionID: "112233",
                                        displayVersion: "1.2.3", protectedByApple: true, dpInfo: Data([1]),
                                        hardwareID: "AABBCCDDEEFF")
        XCTAssertThrowsError(try manager.enqueueOfficialMacPackage(encrypted, for: app))
        XCTAssertTrue(manager.jobs.isEmpty)
        let plain = MacPackageOffer(downloadURL: url, versionID: "112233",
                                    displayVersion: "1.2.3", protectedByApple: false)
        try manager.enqueueOfficialMacPackage(plain, for: app)
        XCTAssertNil(manager.jobs.first?.protectedMacPackage)
        XCTAssertEqual(manager.jobs.count, 1)
        XCTAssertEqual(manager.jobs.first?.rawFormat, "pkg")
        XCTAssertEqual(manager.jobs.first?.platformLabel, "Mac")
        XCTAssertEqual(manager.jobs.first?.app.version, "1.2.3")
        XCTAssertEqual(manager.jobs.first?.sourceURL, url)
    }

    func testMacPKGRejectsTruncatedAndFakeXARHeaders() {
        var header = Data(repeating: 0, count: 28)
        header.replaceSubrange(0..<4, with: Data("xar!".utf8))
        header[5] = 28            // XAR header is 28 bytes
        header[7] = 1             // XAR version 1
        header[15] = 8            // 8-byte compressed TOC
        header[23] = 16           // 16-byte uncompressed TOC
        XCTAssertTrue(MacPackageStorage.plausibleXARHeader(header, fileSize: 100))
        XCTAssertFalse(MacPackageStorage.plausibleXARHeader(header, fileSize: 28))
        var fake = header
        fake[7] = 99
        XCTAssertFalse(MacPackageStorage.plausibleXARHeader(fake, fileSize: 100))
        fake = header
        fake[15] = 120
        XCTAssertFalse(MacPackageStorage.plausibleXARHeader(fake, fileSize: 100))
        fake = header
        fake[0] = 0
        XCTAssertFalse(MacPackageStorage.plausibleXARHeader(fake, fileSize: 100))
        XCTAssertFalse(MacPackageStorage.plausibleXARHeader(Data("xar!".utf8), fileSize: 100))
    }

    // Minimal XAR as written by xar(1): zlib TOC, SHA-1 TOC checksum at heap
    // offset 0, then each file stored uncompressed with an archived checksum.
    static func syntheticXAR(files: [Data], tocChecksum: Data? = nil) -> Data {
        func hex(_ data: Data) -> String {
            Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var heapFiles = Data()
        var entries = ""
        for (index, content) in files.enumerated() {
            entries += """
            <file id="\(index + 1)"><name>file\(index)</name><type>file</type><data>\
            <length>\(content.count)</length><offset>\(20 + heapFiles.count)</offset>\
            <size>\(content.count)</size><encoding style="application/octet-stream"/>\
            <archived-checksum style="sha1">\(hex(content))</archived-checksum>\
            <extracted-checksum style="sha1">\(hex(content))</extracted-checksum></data></file>
            """
            heapFiles += content
        }
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <xar><toc><creation-time>2026-10-13T00:00:00</creation-time>\
        <checksum style="sha1"><offset>0</offset><size>20</size></checksum>\(entries)</toc></xar>
        """.utf8)
        let deflated = try! (xml as NSData).compressed(using: .zlib) as Data
        let adler = XARValidator.adler32(xml)
        var toc = Data([0x78, 0x9c]) + deflated
        toc += Data([UInt8(adler >> 24), UInt8(adler >> 16 & 0xff), UInt8(adler >> 8 & 0xff), UInt8(adler & 0xff)])
        func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var archive = Data("xar!".utf8) + bigEndian(UInt16(28)) + bigEndian(UInt16(1))
        archive += bigEndian(UInt64(toc.count)) + bigEndian(UInt64(xml.count)) + bigEndian(UInt32(1))
        archive += toc
        archive += tocChecksum ?? Data(Insecure.SHA1.hash(data: toc))
        archive += heapFiles
        return archive
    }

    func testXARValidatorVerifiesTOCAndEveryFileChecksum() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ data: Data) throws -> XARValidator.Report {
            let url = root.appendingPathComponent(UUID().uuidString + ".pkg")
            try data.write(to: url)
            return try XARValidator.validate(url)
        }
        let files = [Data("Distribution".utf8), Data(repeating: 0x5a, count: 70_000)]
        let valid = Self.syntheticXAR(files: files)
        XCTAssertEqual(try check(valid).files, 2)
        // Corrupt payload byte (as from a still-encrypted package).
        var corrupted = valid
        corrupted[corrupted.count - 10] ^= 0xff
        XCTAssertThrowsError(try check(corrupted))
        // Wrong stored TOC checksum.
        XCTAssertThrowsError(try check(Self.syntheticXAR(files: files, tocChecksum: Data(repeating: 0, count: 20))))
        // Truncated download.
        XCTAssertThrowsError(try check(valid.prefix(valid.count - 100)))
        // Valid header followed by unreadable (encrypted-looking) TOC bytes.
        var scrambled = valid
        for index in 28..<60 { scrambled[index] ^= 0xa5 }
        XCTAssertThrowsError(try check(scrambled))
        // Archive without any file entries.
        XCTAssertThrowsError(try check(Self.syntheticXAR(files: [])))
        XCTAssertEqual(XARValidator.adler32(Data("Wikipedia".utf8)), 0x11E60398)
    }

    func testAppIDLookupKeepsOnlyTheRequestedApp() {
        let rows: [[String: Any]] = [
            ["trackId": 414478124, "kind": "software", "trackName": "WeChat"],
            ["trackId": 1, "kind": "software", "trackName": "Related"],
            ["artistId": 2, "wrapperType": "artist"]
        ]
        XCTAssertEqual(StoreService.idLookupMatches(rows, id: "414478124", platform: .iOS).count, 1)
        XCTAssertEqual(StoreService.idLookupMatches(rows, id: "414478124", platform: .iPadOS).count, 1)
        XCTAssertTrue(StoreService.idLookupMatches(rows, id: "414478124", platform: .macOS).isEmpty)
        XCTAssertEqual(StoreService.idLookupMatches(
            [["trackId": 6503940939, "kind": "mac-software"]], id: "6503940939", platform: .macOS).count, 1)
    }

    func testNativeMacSearchAndAppStoreOfferExtraction() {
        XCTAssertTrue(StoreService.supportsNativeMac(["kind": "mac-software"]))
        XCTAssertTrue(StoreService.supportsNativeMac(["supportedDevices": ["Mac14,6"]]))
        XCTAssertFalse(StoreService.supportsNativeMac(["kind": "software", "supportedDevices": ["iPhone15,2"]]))
        let html = """
        <html><script type="application/json" id="serialized-server-data">
        {"data":[{"purchaseConfiguration":{"appPlatforms":["mac"],"bundleId":"test.mac.app",
        "buyParams":"salableAdamId=6503940939&appExtVrsId=112233"}},{"purchaseConfiguration":{
        "appPlatforms":["ios"],"bundleId":"test.mac.app",
        "buyParams":"salableAdamId=6503940939&appExtVrsId=998877"}}]}</script></html>
        """
        XCTAssertEqual(MacStoreOfferService.versionID(
            fromHTML: html, appID: "6503940939", bundleID: "test.mac.app"), "112233")
        XCTAssertNil(MacStoreOfferService.versionID(
            fromHTML: html, appID: "6503940939", bundleID: "wrong.bundle"))
        XCTAssertNil(MacStoreOfferService.versionID(
            fromHTML: html, appID: "123", bundleID: "test.mac.app"))
        let conflicting = html.replacingOccurrences(
            of: "\"appPlatforms\":[\"ios\"],\"bundleId\":\"test.mac.app\"",
            with: "\"appPlatforms\":[\"mac\"],\"bundleId\":\"test.mac.app\"")
        XCTAssertNil(MacStoreOfferService.versionID(
            fromHTML: conflicting, appID: "6503940939", bundleID: "test.mac.app"))
        XCTAssertNil(MacStoreOfferService.versionID(
            fromHTML: "<html>unrelated content</html>", appID: "6503940939", bundleID: ""))
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
        let package = Self.syntheticXAR(files: [Data("<installer-gui-script/>".utf8)])
        try package.write(to: staging)
        let job = DownloadJob(id: id, app: app, rawFormat: "pkg")
        let (filename, result) = try MacPackageStorage.finish(staging: staging, job: job)
        let finalURL = try XCTUnwrap(LocalResources.packageURL(filename))
        defer { try? FileManager.default.removeItem(at: finalURL) }
        XCTAssertTrue(filename.hasSuffix(".pkg"))
        XCTAssertEqual(result.name, app.name)
        XCTAssertEqual(result.size, Int64(package.count))
        XCTAssertEqual(try Data(contentsOf: finalURL), package)
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
        XCTAssertEqual(StoreService.country(forStorefront: "143467-19,29"), "IN")
        XCTAssertEqual(StoreService.country(forStorefront: "143503"), "BR")
        XCTAssertNil(StoreService.country(forStorefront: "unknown"))
        XCTAssertEqual(StoreService.searchCountries(selected: "CN", accountCountry: "US"), ["CN", "US"])
        XCTAssertEqual(StoreService.searchCountries(selected: "US", accountCountry: "US"), ["US"])
        XCTAssertEqual(Array(StoreService.artworkCountries(selected: "CN", accountCountry: "US").prefix(3)), ["US", "CN", "HK"])
        XCTAssertEqual(Array(StoreService.artworkCountries(selected: "JP", accountCountry: "CN").prefix(3)), ["CN", "JP", "US"])
        let all = StoreService.artworkCountries(selected: "JP", accountCountry: "CN")
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertTrue(all.contains("FR"))

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
        XCTAssertEqual(settings.versionSources.map(\.name), ["Timbrd", "Bilin", "iosdump"])
        XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(DownloadJob(app: StoreApp(id: "1", name: "Test"), downloaded: -1, expected: 100).progress, 0)
    }

    func testAppleCookiesAreMergedByNameAndExpiredOnesDropped() throws {
        let url = URL(string: "https://buy.itunes.apple.com/")!
        func cookie(_ name: String, _ value: String, expires: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: ".apple.com", .path: "/", .originURL: url]
            if let expires { properties[.expires] = expires }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let now = Date()
        let merged = try AppleService.mergedCookie("mz_at0=old; itspod=7; wosid=a", with: [
            cookie("mz_at0", "new"), cookie("wosid", "x", expires: now.addingTimeInterval(-60)), cookie("hsaccnt", "1")
        ], now: now)
        XCTAssertEqual(merged, "mz_at0=new; itspod=7; hsaccnt=1")
        XCTAssertEqual(AppleService.mergedCookie("a=1", with: [], now: now), "a=1")
        // Values containing "=" survive a round trip.
        XCTAssertEqual(AppleService.mergedCookie("tok=ab==; b=2", with: [], now: now), "tok=ab==; b=2")
    }

    func testUnreadableSystemDownloadsAreRecognized() {
        // "未能打开文件 CFNetworkDownload_….tmp，因为你没有查看它的权限" (#36).
        XCTAssertTrue(DownloadManager.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        XCTAssertTrue(DownloadManager.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        XCTAssertTrue(DownloadManager.isPermissionError(wrapped))
        XCTAssertFalse(DownloadManager.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
        XCTAssertFalse(DownloadManager.isPermissionError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    func testRequestFailuresKeepOnlyEndpointNames() {
        XCTAssertTrue(RequestFailureLog.endpointName("buyProduct"))
        XCTAssertTrue(RequestFailureLog.endpointName("volumeStoreDownloadProduct"))
        XCTAssertFalse(RequestFailureLog.endpointName("mzps2486598912345.signed.dpkg.ipa"))
        XCTAssertFalse(RequestFailureLog.endpointName("1234567"))
        XCTAssertFalse(RequestFailureLog.endpointName(""))
        let saved = AppText.locale
        defer { AppText.locale = saved }
        AppText.locale = Locale(identifier: "en")
        XCTAssertTrue(HTTPStatusError(code: 401).localizedDescription.contains("sign in again"))
    }

    func testBackupRoundTripsAndMergesFollowedApps() throws {
        var settings = ToolSettings()
        settings.searchLimit = 50; settings.baseCurrency = "USD"
        let a = StoreApp(id: "1", name: "A"), b = StoreApp(id: "2", name: "B"), c = StoreApp(id: "3", name: "C")
        var record = WatchRecord(id: "1", country: "US", started: Date(timeIntervalSince1970: 1_700_000_000), checked: Date(timeIntervalSince1970: 1_700_000_100))
        record.price = 4.99; record.currency = "USD"; record.target = 2.99
        var backup = AppBackup(settings: settings, favorites: [a, b], watch: [record.key: record],
                               keptVersions: ["0|1": "1.2"], searchHistory: [SearchHistoryItem(term: "notes", count: 2, lastUsed: Date(timeIntervalSince1970: 1_700_000_000))])
        backup.accountProfiles = [
            AccountProfileEntry(id: "alice@example.com", name: "Alice", storeFront: "143465", fullStoreFront: "143465-19,29")
        ]
        backup.preferredActiveAccountID = "alice@example.com"
        let data = try backup.encoded()
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["passwordToken", "\"cookie\"", "\"password\"", "\"dsid\""] { XCTAssertFalse(text.contains(secret), secret) }
        let restored = try AppBackup.decode(data)
        XCTAssertEqual(restored.settings, settings)
        XCTAssertEqual(restored.favorites.map(\.id), ["1", "2"])
        XCTAssertEqual(restored.watch[record.key]?.target, 2.99)
        XCTAssertEqual(restored.keptVersions, ["0|1": "1.2"])
        XCTAssertEqual(restored.accountProfiles?.count, 1)
        XCTAssertEqual(restored.accountProfiles?.first?.id, "alice@example.com")
        XCTAssertEqual(restored.preferredActiveAccountID, "alice@example.com")
        XCTAssertEqual(AppBackup.merged([a, b], with: [b, c]).map(\.id), ["1", "2", "3"])
        XCTAssertThrowsError(try AppBackup.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try AppBackup.decode(Data("not json".utf8)))
        var future = backup; future.format = AppBackup.currentFormat + 1
        XCTAssertThrowsError(try AppBackup.decode(try future.encoded()))
    }

    func testInstalledAppListIsReadAndGrouped() throws {
        let reply = #"{"ok":true,"apps":[{"installed":true,"bundle_id":"com.netflix.Netflix","name":"Netflix","version":"26.4.0","store_item_id":"363590051","has_purchase_record":true,"manifest_install":false},{"installed":true,"bundle_id":"com.spotify.client","name":"Spotify","version":"9.1.98","store_item_id":"324684580","has_purchase_record":false,"manifest_install":true},{"installed":true,"bundle_id":"com.example.tool","name":null,"version":"1.0"}]}"#
        let apps = try NativeInstaller.listResult(from: Data(reply.utf8))
        XCTAssertEqual(apps.map(\.bundleID), ["com.netflix.Netflix", "com.spotify.client", "com.example.tool"])
        XCTAssertEqual(apps[0].name, "Netflix")
        XCTAssertTrue(apps[0].recognisedByAppStore)
        XCTAssertFalse(apps[1].recognisedByAppStore, "installed from a link: the App Store shows a cloud")
        XCTAssertThrowsError(try NativeInstaller.listResult(from: Data(#"{"ok":false,"stage":"list","message":"timed out"}"#.utf8)))
        var latest = StoreApp(id: "1", name: "A", version: "10.0.10.105")
        XCTAssertFalse(InstalledAppsView.isUpdate(latest, installed: "10.0.10", versionID: nil), "a build number is not an update")
        latest.version = "10.1"
        XCTAssertTrue(InstalledAppsView.isUpdate(latest, installed: "10.0.10", versionID: nil))
        latest.externalVersionID = "888"
        XCTAssertFalse(InstalledAppsView.isUpdate(latest, installed: "10.0.10", versionID: "888"), "same store version")
        XCTAssertFalse(InstalledAppsView.isUpdate(latest, installed: "10.1", versionID: nil))
    }

    @MainActor
    func testInstalledStoreLookupSeparatesMissingFailureAndRecovery() async {
        let listing = StoreApp(id: "1", name: "One", version: "2.0")
        var attempt = 0
        let catalog = InstalledAppCatalog { ids, country in
            XCTAssertEqual(ids, ["1"])
            XCTAssertEqual(country, "US")
            attempt += 1
            switch attempt {
            case 1, 4: return ["1": listing, "99": StoreApp(id: "99", name: "Unrequested")]
            case 2: throw URLError(.notConnectedToInternet)
            default: return [:]
            }
        }
        var installed = NativeInstaller.InstalledApp(installed: true)
        installed.storeItemID = "1"
        await catalog.load(ids: ["1", "1", "0", "bad"], country: "us")
        XCTAssertEqual(catalog.state, .ready)
        XCTAssertEqual(catalog.listing(for: installed), listing)
        XCTAssertNil(catalog.listings["99"])
        await catalog.load(ids: ["1"], country: "US")
        guard case .failed = catalog.state else { return XCTFail("Network errors must not look like a missing listing") }
        XCTAssertNil(catalog.listing(for: installed), "Failed refreshes must not offer stale store updates")
        await catalog.load(ids: ["1"], country: "US")
        XCTAssertEqual(catalog.state, .ready, "A successful empty response is distinct from failure")
        XCTAssertNil(catalog.listing(for: installed))
        await catalog.load(ids: ["1"], country: "US")
        XCTAssertEqual(catalog.listing(for: installed), listing, "Retry can restore store details")
    }

    @MainActor
    func testInstalledStoreLookupDiscardsSupersededRegionResults() async {
        let started = expectation(description: "first region lookup started")
        var pending: CheckedContinuation<[String: StoreApp], Error>?
        let catalog = InstalledAppCatalog { _, country in
            if country == "CN" {
                return try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    started.fulfill()
                }
            }
            return ["1": StoreApp(id: "1", name: "US listing")]
        }
        let older = Task { await catalog.load(ids: ["1"], country: "CN") }
        await fulfillment(of: [started], timeout: 5)
        guard let pending else { older.cancel(); return XCTFail("The first lookup must be waiting before the region changes") }
        await catalog.load(ids: ["1"], country: "US")
        pending.resume(returning: ["1": StoreApp(id: "1", name: "Old CN listing")])
        await older.value
        XCTAssertEqual(catalog.country, "US")
        XCTAssertEqual(catalog.listings["1"]?.name, "US listing")
        XCTAssertEqual(catalog.state, .ready)
    }

    @MainActor
    func testInstalledStoreLookupNoIDAndCancellationDoNotClaimDelisting() async {
        var calls = 0
        let catalog = InstalledAppCatalog { _, _ in
            calls += 1
            throw CancellationError()
        }
        await catalog.load(ids: ["0", "-1", "com.example.tool"], country: "US")
        XCTAssertEqual(calls, 0, "Local-only apps must not send a bogus App ID")
        XCTAssertEqual(catalog.state, .ready)
        await catalog.load(ids: ["1"], country: "US")
        XCTAssertEqual(catalog.state, .idle, "Cancellation is neither a failed query nor a confirmed missing listing")
        var app = NativeInstaller.InstalledApp(installed: true)
        XCTAssertNil(InstalledAppCatalog.storeID(app))
        app.storeItemID = "001"
        XCTAssertEqual(InstalledAppCatalog.storeID(app), "1")
    }

    func testAppLockSettingsDecode() throws {
        XCTAssertFalse(ToolSettings().appLock)
        let saved = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"appLock":true,"appLockDelay":99999}"#.utf8))
        XCTAssertTrue(saved.appLock)
        XCTAssertEqual(saved.appLockDelay, 3600)
        let old = try JSONDecoder().decode(ToolSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.appLock)
        XCTAssertEqual(old.appLockDelay, 0)
    }

    func testReviewFeedParses() {
        let review = #"{"author":{"name":{"label":"Ann"}},"updated":{"label":"2026-11-01T08:30:00-07:00"},"im:rating":{"label":"4"},"im:version":{"label":"2.1"},"id":{"label":"123"},"title":{"label":"Nice"},"content":{"label":"Works well"}}"#
        let appEntry = #"{"im:name":{"label":"Some App"},"id":{"label":"https://apps.apple.com/app/id1"}}"#
        let list = ReviewService.parse(Data(#"{"feed":{"entry":[\#(appEntry),\#(review)]}}"#.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.author, "Ann")
        XCTAssertEqual(list.first?.rating, 4)
        XCTAssertEqual(list.first?.version, "2.1")
        XCTAssertEqual(list.first?.title, "Nice")
        XCTAssertEqual(list.first?.body, "Works well")
        XCTAssertNotNil(list.first?.date)
        XCTAssertEqual(ReviewService.parse(Data(#"{"feed":{"entry":\#(review)}}"#.utf8)).map(\.id), ["123"])
        XCTAssertTrue(ReviewService.parse(Data(#"{"feed":{"author":{}}}"#.utf8)).isEmpty)
        XCTAssertTrue(ReviewService.parse(Data("not json".utf8)).isEmpty)
    }

    func testPackageComparisonListsChanges() {
        var old = PackageInfo()
        old.version = "1.0"; old.build = "10"; old.minimumOS = "15.0"
        old.permissions = [.init(key: "NSCameraUsageDescription", reason: "Scan")]
        old.frameworkNames = ["A.framework", "B.framework"]
        old.urlSchemes = ["demo"]
        var new = old
        new.version = "1.1"; new.build = "11"
        new.permissions.append(.init(key: "NSMicrophoneUsageDescription", reason: "Talk"))
        new.frameworkNames = ["B.framework", "C.framework"]
        let result = PackageComparison.compare(old, new)
        XCTAssertEqual(result.basics.map(\.old), ["1.0", "10"])
        XCTAssertEqual(result.basics.map(\.new), ["1.1", "11"])
        XCTAssertEqual(result.permissions.added.count, 1)
        XCTAssertTrue(result.permissions.removed.isEmpty)
        XCTAssertEqual(result.frameworks.added, ["C.framework"])
        XCTAssertEqual(result.frameworks.removed, ["A.framework"])
        XCTAssertTrue(result.urlSchemes.isEmpty)
        XCTAssertFalse(result.unchanged)
        XCTAssertTrue(PackageComparison.compare(old, old).unchanged)
    }

    func testPackageInfoReadsDeclarations() {
        let info = PackageInfoService.describe([
            "CFBundleDisplayName": "Demo", "CFBundleIdentifier": "com.example.demo",
            "CFBundleShortVersionString": "2.1", "CFBundleVersion": "210", "MinimumOSVersion": "16.0",
            "NSCameraUsageDescription": "Scan codes", "NSLocationWhenInUseUsageDescription": "Nearby stores",
            "NSSomethingNew": "not a permission",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["demo", "demo-auth"]], ["CFBundleURLSchemes": ["demo"]]],
            "UIBackgroundModes": ["remote-notification", "audio"],
        ])
        XCTAssertEqual(info.name, "Demo")
        XCTAssertEqual(info.permissions.map(\.key), ["NSCameraUsageDescription", "NSLocationWhenInUseUsageDescription"])
        XCTAssertEqual(info.permissions.first?.reason, "Scan codes")
        XCTAssertEqual(info.urlSchemes, ["demo", "demo-auth"])
        XCTAssertEqual(info.backgroundModes, ["audio", "remote-notification"])
        XCTAssertTrue(PackageInfoService.isExtensionInfo("PlugIns/Widget.appex/Info.plist"))
        XCTAssertFalse(PackageInfoService.isExtensionInfo("PlugIns/Widget.appex/en.lproj/Info.plist"))
        XCTAssertEqual(PackageInfoService.languages(in: ["en.lproj/Main.strings", "zh-Hans.lproj/x", "Base.lproj/y", "Assets.car"]), ["en", "zh-Hans"])
        XCTAssertNil(PackageInfoService.permissionName("NSSomethingNewUsageDescription"))
        XCTAssertNotNil(PackageInfoService.extensionKind("com.apple.widgetkit-extension"))
        let grouped = PackageInfoService.groupedPermissions([
            .init(key: "NSBluetoothAlwaysUsageDescription", reason: "Speakers"),
            .init(key: "NSBluetoothPeripheralUsageDescription", reason: "Speakers"),
            .init(key: "NSLocationAlwaysUsageDescription", reason: "Nearby"),
            .init(key: "NSLocationAlwaysAndWhenInUseUsageDescription", reason: "Concerts"),
        ])
        XCTAssertEqual(grouped.count, 2, "same-meaning keys share one row")
        XCTAssertEqual(grouped.first { $0.reasons.contains("Speakers") }?.reasons, ["Speakers"])
        XCTAssertEqual(grouped.first { $0.reasons.contains("Nearby") }?.reasons, ["Nearby", "Concerts"])
    }

    func testBlockedMetadataRaisesTheVersionID() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let record: [String: Any] = ["itemId": 477537958, "softwareVersionExternalIdentifier": 894270367, "bundleShortVersionString": "26.1.4"]
        let package = folder.appendingPathComponent("Demo.ipa")
        let archive = try Archive(url: package, accessMode: .create)
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
        try archive.addEntry(with: "iTunesMetadata.plist", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
        let blocked = try XCTUnwrap(NativeInstaller.blockedMetadata(of: package))
        let result = try XCTUnwrap(PropertyListSerialization.propertyList(from: blocked, format: nil) as? [String: Any])
        XCTAssertEqual(result["softwareVersionExternalIdentifier"] as? Int, NativeInstaller.blockedVersionID)
        XCTAssertEqual(result["itemId"] as? Int, 477537958)
        XCTAssertEqual(result["bundleShortVersionString"] as? String, "26.1.4")

        let empty = folder.appendingPathComponent("Empty.ipa")
        let bare = try Archive(url: empty, accessMode: .create)
        try bare.addEntry(with: "Payload/", type: .directory, uncompressedSize: Int64(0)) { _, _ in Data() }
        XCTAssertNil(try NativeInstaller.blockedMetadata(of: empty))

        var app = NativeInstaller.InstalledApp(installed: true)
        app.storeVersionID = String(NativeInstaller.blockedVersionID)
        XCTAssertTrue(app.updatesBlocked)
        app.storeVersionID = "894270367"
        XCTAssertFalse(app.updatesBlocked)
    }

    func testWiFiTransferOnlyAnswersTheLocalNetwork() {
        for address in ["192.168.0.12", "10.1.2.3", "172.16.0.1", "172.31.255.255", "169.254.1.1", "fe80::1", "fd12::3", "::ffff:192.168.1.5"] {
            XCTAssertTrue(WiFiTransferServer.isPrivate(address), address)
        }
        for address in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "2001:db8::1", "::ffff:1.1.1.1", "nonsense"] {
            XCTAssertFalse(WiFiTransferServer.isPrivate(address), address)
        }
        XCTAssertEqual(WiFiTransferServer.escape("<a href=\"x\">&'"), "&lt;a href=&quot;x&quot;&gt;&amp;&#39;")
        XCTAssertEqual(WiFiTransferServer.asciiName("网易云_1.0.ipa"), "____1.0.ipa")
        let id = UUID()
        XCTAssertEqual(WiFiTransferView.publicName(id.uuidString + "-App_1.0.ipa", id: id), "App_1.0.ipa")
        XCTAssertEqual(WiFiTransferView.publicName("Other.ipa", id: id), "Other.ipa")
    }

    func testChartFeedParses() {
        let entry = { (id: String) in #"{"im:name":{"label":"App"},"id":{"label":"https://apps.apple.com/app/id\#(id)","attributes":{"im:id":"\#(id)","im:bundleId":"a.b"}},"category":{"attributes":{"im:id":"6014"}}}"# }
        let list = Data(#"{"feed":{"entry":[\#(entry("111")),\#(entry("222")),\#(entry("111"))]}}"#.utf8)
        XCTAssertEqual(ChartService.parse(list), ["111", "222"])
        XCTAssertEqual(ChartService.parse(Data(#"{"feed":{"entry":\#(entry("333"))}}"#.utf8)), ["333"])
        XCTAssertTrue(ChartService.parse(Data(#"{"feed":{}}"#.utf8)).isEmpty)
        XCTAssertEqual(AppChart.paid.feed(.iPadOS), "toppaidipadapplications")
        XCTAssertNil(AppChart.free.feed(.tvOS))
    }

    func testMacListingOfUniversalAppHidesIPhoneVersion() {
        let universal: [String: Any] = ["trackId": 6747369377, "trackName": "EplayerX", "kind": "software", "version": "1.9.5", "fileSizeBytes": "130503680"]
        let macOnly: [String: Any] = ["trackId": 497799835, "trackName": "Xcode", "kind": "mac-software", "version": "27.2", "fileSizeBytes": "3000000000"]
        XCTAssertEqual(StoreService.mapMacLookup(universal).version, "")
        XCTAssertEqual(StoreService.mapMacLookup(universal).size, 0)
        XCTAssertEqual(StoreService.mapMacLookup(macOnly).version, "27.2")
        XCTAssertEqual(StoreService.mapLookup(universal).version, "1.9.5")
    }

    func testOlderVersionIsRecognisedFromTheVersionList() throws {
        var app = StoreApp(id: "1517062289", name: "bilibili")
        app.externalVersionID = "873726575"
        let asset = DownloadAsset(app: app, url: URL(string: "https://example.com/a.ipa")!,
                                  externalVersionIDs: ["800000000", "873726575", "899000000"], platform: "iphone", account: "a")
        var job = DownloadJob(app: app, asset: asset, status: .completed)
        XCTAssertTrue(job.isOlderVersion)
        job.app.externalVersionID = "899000000"
        XCTAssertFalse(job.isOlderVersion)
        job.asset = nil
        XCTAssertFalse(job.isOlderVersion)
    }

    func testRegionLocalesFindTheirScript() {
        XCTAssertEqual(AppText.text("免费", in: Locale(identifier: "zh_CN")), "免费")
        XCTAssertEqual(AppText.text("免费", in: Locale(identifier: "zh-Hans_CN")), "免费")
        XCTAssertEqual(AppText.text("免费", in: Locale(identifier: "zh_TW")), "免費")
        XCTAssertEqual(AppText.text("免费", in: Locale(identifier: "zh-Hant_HK")), "免費")
        XCTAssertTrue(AppText.sameLanguageAndScript("pt-BR", Locale(identifier: "pt_PT")))
        XCTAssertFalse(AppText.sameLanguageAndScript("zh-Hant", Locale(identifier: "zh_CN")))
    }

    func testGenreNamesFollowTheInterfaceLanguage() {
        let saved = AppText.locale
        defer { AppText.locale = saved }
        AppText.locale = Locale(identifier: "zh-Hans")
        XCTAssertEqual(StoreService.localizedGenre("Productivity"), "效率")
        AppText.locale = Locale(identifier: "ja")
        XCTAssertEqual(StoreService.localizedGenre("Productivity"), "仕事効率化")
        AppText.locale = Locale(identifier: "ko")
        XCTAssertEqual(StoreService.localizedGenre("Photo & Video"), "사진 및 비디오")
        // English is Apple's own name; unknown genres pass through in every language.
        AppText.locale = Locale(identifier: "en")
        XCTAssertEqual(StoreService.localizedGenre("Productivity"), "Productivity")
        AppText.locale = Locale(identifier: "ja")
        XCTAssertEqual(StoreService.localizedGenre("Something New"), "Something New")
    }

    func testVersionSourceTemplatesAcceptBothPlaceholdersAndOnlyHTTPS() {
        XCTAssertEqual(VersionSource.iosDump.url(for: "414478124")?.absoluteString, "https://iosdump.apdoilaan.work/history/414478124")
        let legacy = VersionSource(name: "a", urlTemplate: "https://example.com/v?id={id}", containerKey: "", reverse: true)
        XCTAssertEqual(legacy.url(for: "7")?.absoluteString, "https://example.com/v?id=7")
        XCTAssertNil(VersionSource(name: "b", urlTemplate: "https://example.com/history", containerKey: "", reverse: false).url(for: "7"))
        XCTAssertNil(VersionSource(name: "c", urlTemplate: "http://example.com/{appId}", containerKey: "", reverse: false).url(for: "7"))
    }

    func testIosdumpIsOfferedOnceToSavedSourceLists() throws {
        let saved = Data(#"{"versionSources":[{"id":"6F0C2B1E-0000-4000-8000-000000000001","name":"Mine","urlTemplate":"https://example.com/{id}","containerKey":"data","reverse":false,"enabled":true}]}"#.utf8)
        let migrated = try JSONDecoder().decode(ToolSettings.self, from: saved)
        XCTAssertEqual(migrated.versionSources.map(\.name), ["Mine", "iosdump"])
        // Removing it afterwards is respected.
        var removed = migrated
        removed.versionSources.removeAll { $0.name == "iosdump" }
        let reloaded = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(removed))
        XCTAssertEqual(reloaded.versionSources.map(\.name), ["Mine"])
    }

    func testAppearanceFollowsSystemByDefaultAndReplacesTheSavedDarkDefault() throws {
        XCTAssertEqual(ToolSettings().appearance, "system")
        func decode(_ json: String) throws -> String {
            try JSONDecoder().decode(ToolSettings.self, from: Data(json.utf8)).appearance
        }
        // Saved by 1.7.0, whose default was dark: follow the system.
        XCTAssertEqual(try decode(#"{"appearance":"dark","appUpdateCheck":true}"#), "system")
        // Chosen in an earlier version, or chosen again since 1.7.1: kept.
        XCTAssertEqual(try decode(#"{"appearance":"dark"}"#), "dark")
        XCTAssertEqual(try decode(#"{"appearance":"dark","appUpdateCheck":true,"appearanceSchema":2}"#), "dark")
        XCTAssertEqual(try decode(#"{"appearance":"light","appUpdateCheck":true}"#), "light")
        XCTAssertEqual(try decode(#"{"appearance":"sepia"}"#), "system")
        var dark = ToolSettings(); dark.appearance = "dark"
        XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(dark)).appearance, "dark")
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
    func testUserActionsRunBeforeQueuedBackgroundSigning() async throws {
        let signer = SAPSigner()
        _ = try await signer.execute(title: "准备", script: "return 'ready';", arguments: [:])
        // Holds the runtime until cancelled.
        let blocker = Task { @MainActor in
            try await signer.execute(title: "占用", script: "reportStage(2); return await new Promise(() => {});", arguments: [:], timeoutSeconds: 60)
        }
        for _ in 0..<900 where signer.stageIndex != 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        var order: [String] = []
        let background = Task { @MainActor in
            _ = try await signer.execute(title: "后台", script: "return 'b';", arguments: [:])
            order.append("background")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let user = Task { @MainActor in
            _ = try await SAPSigner.$userInitiated.withValue(true) {
                try await signer.execute(title: "用户", script: "return 'u';", arguments: [:])
            }
            order.append("user")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        signer.cancel()
        _ = try? await blocker.value
        try await user.value
        try await background.value
        XCTAssertEqual(order, ["user", "background"])
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
    func testSignerRetriesStaleRuntimeAfterReleasingOperation() async throws {
        let signer = SAPSigner()
        defer { signer.clearCache() }
        let warm = try await signer.execute(title: "准备", script: "window.staleRuntime = true; return 'ready';", arguments: [:])
        XCTAssertEqual(warm, "ready")
        let retried = try await signer.execute(title: "重试", script: "if (window.staleRuntime) throw new Error('stale runtime'); return 'fresh';", arguments: [:])
        XCTAssertEqual(retried, "fresh")
        XCTAssertFalse(signer.isPresented)
        XCTAssertNil(signer.webView)
        let next = try await signer.execute(title: "再次复用", script: "return 'ready';", arguments: [:])
        XCTAssertEqual(next, "ready")
    }

    @MainActor
    func testSignerWarmTimeoutDoesNotRetryOrLoseTerminalError() async throws {
        let signer = SAPSigner()
        defer { signer.clearCache() }
        _ = try await signer.execute(title: "准备", script: "return 'ready';", arguments: [:])
        do {
            _ = try await signer.execute(title: "测试", script: "return await new Promise(() => {});", arguments: [:], timeoutSeconds: 1)
            XCTFail("Timed-out operation returned success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("已停止")) }
        XCTAssertFalse(signer.isPresented)
        XCTAssertNil(signer.webView)
        let recovered = try await signer.execute(title: "恢复", script: "return 'ready';", arguments: [:])
        XCTAssertEqual(recovered, "ready")
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
        XCTAssertEqual(metadata.queryItems?.first(where: { $0.name == "displayVersion" })?.value, app.version)
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

    func testMacPackageQueueCancelsWaitingJobAndReportsNoCurrentJob() async {
        let job = UUID()
        let source = URL(fileURLWithPath: "/nonexistent.pkg"), output = URL(fileURLWithPath: "/nonexistent.out")
        // Cancelled before its turn: never processed, reported as a cancellation.
        MacPackageDecryptor.cancel(job: job)
        do {
            try await MacPackageDecryptor.process(job: job, hardwareID: "AABBCCDDEEFF", dpInfo: Data([1]), from: source, to: output)
            XCTFail("A cancelled job must not be processed")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertNil(MacPackageDecryptor.currentJob)
        // The cancellation is consumed: the next run of the same job proceeds
        // (and fails here only because the simulator has no bridge).
        for _ in 0..<20 {
            do {
                try await MacPackageDecryptor.process(job: job, hardwareID: "AABBCCDDEEFF", dpInfo: Data([1]), from: source, to: output)
            } catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertNil(MacPackageDecryptor.currentJob)
        }
    }

    func testDMAPFirstIntegerStopsAtFirstMatchOnSlices() throws {
        let data = DMAP.tag("mlog", DMAP.uint32("mstt", 200) + DMAP.uint32("mstt", 500))
        XCTAssertEqual(try DMAP.firstInteger(data, name: "mstt"), 200)
        XCTAssertNoThrow(try DMAP.validate(data))
        XCTAssertNil(try DMAP.firstInteger(data, name: "mlid"))
    }

    func testDMAPDepthLimit() {
        var payload = DMAP.uint32("mlid", 1)
        for _ in 0..<18 { payload = DMAP.tag("mlcl", payload) }
        XCTAssertThrowsError(try DMAP.walk(payload) { _ in })
    }

    func testDirectTranslationIsOptInAndMigratesExistingSettings() throws {
        XCTAssertFalse(ToolSettings().directTranslation)
        for json in ["{}", #"{"appearance":"dark","appearanceSchema":2,"wifiOnlyDownloads":true}"#] {
            XCTAssertFalse(try JSONDecoder().decode(ToolSettings.self, from: Data(json.utf8)).directTranslation)
        }
        for enabled in [false, true] {
            var settings = ToolSettings()
            settings.directTranslation = enabled
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(ToolSettings.self, from: data), settings)
        }
        let saved = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"directTranslation":true}"#.utf8))
        XCTAssertTrue(saved.directTranslation)
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

    func testPackageServiceReplicatesMultipleSinfsFromManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("test.download")
        do {
            let archive = try Archive(url: staging, accessMode: .create)
            let manifest: [String: Any] = [
                "SinfPaths": [
                    "SC_Info/Multi.sinf",
                    "PlugIns/Widget.appex/SC_Info/Widget.sinf"
                ]
            ]
            let files: [String: Data] = [
                "Payload/Multi.app/Info.plist": try HTTPClient.encodePlist(["CFBundleDisplayName": "Multi", "CFBundleIdentifier": "multi.bundle", "CFBundleShortVersionString": "1.0"]),
                "Payload/Multi.app/SC_Info/Manifest.plist": try HTTPClient.encodePlist(manifest),
                "Payload/Multi.app/SC_Info/Multi.v1.supp": Data([9]),
                "Payload/Multi.app/PlugIns/Widget.appex/SC_Info/Widget.v1.supp": Data([8]),
                "Payload/Multi.app/_CodeSignature/CodeResources": Data([7, 6, 5]),
                "iTunesMetadata.plist": try HTTPClient.encodePlist(["itemId": "2"])
            ]
            for (path, data) in files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
                try archive.addEntry(with: path, relativeTo: root)
            }
        }
        let asset = DownloadAsset(
            app: StoreApp(id: "2", name: "Multi", bundleID: "multi.bundle", version: "1.0"),
            url: URL(string: "https://example.com/app")!,
            sinf: Data([1]),
            sinfs: [Data([1, 2]), Data([3, 4])],
            metadata: try HTTPClient.encodePlist(["itemId": "2", "appleId": "test@example.com"]),
            externalVersionIDs: [], platform: "ios", account: "test@example.com"
        )
        let result = try PackageService.finish(staging: staging, id: UUID(), asset: asset)
        let final = LocalResources.packages.appendingPathComponent(result.0)
        defer { try? FileManager.default.removeItem(at: final) }
        let archive = try Archive(url: final, accessMode: .read)
        XCTAssertNotNil(archive["Payload/Multi.app/SC_Info/Multi.sinf"])
        XCTAssertNotNil(archive["Payload/Multi.app/PlugIns/Widget.appex/SC_Info/Widget.sinf"])
        XCTAssertNotNil(archive["Payload/Multi.app/SC_Info/Multi.v1.supp"])
        XCTAssertNotNil(archive["Payload/Multi.app/PlugIns/Widget.appex/SC_Info/Widget.v1.supp"])
        XCTAssertNotNil(archive["Payload/Multi.app/_CodeSignature/CodeResources"])

        var mainPayload = Data()
        _ = try archive.extract(archive["Payload/Multi.app/SC_Info/Multi.sinf"]!, consumer: { mainPayload.append($0) })
        XCTAssertEqual(mainPayload, Data([1, 2]))

        var widgetPayload = Data()
        _ = try archive.extract(archive["Payload/Multi.app/PlugIns/Widget.appex/SC_Info/Widget.sinf"]!, consumer: { widgetPayload.append($0) })
        XCTAssertEqual(widgetPayload, Data([3, 4]))

        var supplemental = Data(), codeResources = Data()
        _ = try archive.extract(archive["Payload/Multi.app/PlugIns/Widget.appex/SC_Info/Widget.v1.supp"]!, consumer: { supplemental.append($0) })
        _ = try archive.extract(archive["Payload/Multi.app/_CodeSignature/CodeResources"]!, consumer: { codeResources.append($0) })
        XCTAssertEqual(supplemental, Data([8]))
        XCTAssertEqual(codeResources, Data([7, 6, 5]))
    }

    func testMultiComponentSinfsKeepServerOrderAndRequireExactSafePaths() throws {
        let serverRecords: [[String: Any]] = [
            ["id": 900, "sinf": Data([1])],
            ["id": 2, "sinf": Data([2]).base64EncodedString()]
        ]
        let sinfs = try AppleService.mobileSinfs(serverRecords)
        XCTAssertEqual(sinfs, [Data([1]), Data([2])], "opaque ids must not reorder positional SINF records")
        let targets = try PackageService.sinfTargets(
            paths: ["SC_Info/Main.sinf", "PlugIns/Widget.appex/SC_Info/Widget.sinf"],
            sinfs: sinfs, bundleFolder: "Multi.app")
        XCTAssertEqual(targets.map(\.path), [
            "Payload/Multi.app/SC_Info/Main.sinf",
            "Payload/Multi.app/PlugIns/Widget.appex/SC_Info/Widget.sinf"
        ])
        XCTAssertEqual(targets.map(\.data), sinfs)
        XCTAssertThrowsError(try PackageService.sinfTargets(
            paths: ["SC_Info/Main.sinf", "PlugIns/Widget.appex/SC_Info/Widget.sinf"],
            sinfs: [Data([1])], bundleFolder: "Multi.app"))
        XCTAssertThrowsError(try PackageService.sinfTargets(
            paths: ["../escape.sinf"], sinfs: [Data([1])], bundleFolder: "Multi.app"))
        XCTAssertThrowsError(try AppleService.mobileSinfs([
            ["id": 1, "sinf": Data([1])], ["id": 2, "dpInfo": Data([2])]
        ]))
    }

    func testPurchaseMetadataRecordsPurchaserLikeAppStore() throws {
        let account = AppleAccount(id: "test@example.com", name: "Test User", password: "", cookie: "", dsid: "123456",
                                   passwordToken: "", storeFront: "143465", fullStoreFront: "143465-19,29")
        let metadata = AppleService.purchaseMetadata(["itemId": NSNumber(value: 1)], account: account,
                                                     purchaseDate: Date(timeIntervalSince1970: 0))
        let info = try XCTUnwrap((metadata["com.apple.iTunesStore.downloadInfo"] as? [String: Any])?["accountInfo"] as? [String: Any])
        XCTAssertEqual((info["DSPersonID"] as? NSNumber)?.uint64Value, 123456)
        XCTAssertEqual((info["PurchaserID"] as? NSNumber)?.uint64Value, 123456)
        XCTAssertEqual((info["DownloaderID"] as? NSNumber)?.uint64Value, 123456)
        XCTAssertEqual((metadata["DSPersonID"] as? NSNumber)?.uint64Value, 123456)
        XCTAssertEqual(info["AppleID"] as? String, "test@example.com")
        XCTAssertEqual(info["FirstName"] as? String, "Test")
        XCTAssertEqual(info["LastName"] as? String, "User")
        XCTAssertEqual(metadata["appleId"] as? String, "test@example.com")
        XCTAssertNoThrow(try HTTPClient.encodePlist(metadata))
    }

    func testTransientStoreFailuresAreRetried() {
        XCTAssertTrue(HTTPClient.isTransient(HTTPStatusError(code: 503)))
        XCTAssertFalse(HTTPClient.isTransient(HTTPStatusError(code: 404)))
        XCTAssertTrue(HTTPClient.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(HTTPClient.isTransient(ToolError.message("x")))
    }

    private struct MemoryRangeReader: RangeReader {
        let data: Data
        func tail(_ count: Int) async throws -> (data: Data, size: Int64) {
            (Data(data.suffix(count)), Int64(data.count))
        }
        func read(offset: Int64, count: Int) async throws -> Data {
            let start = Int(offset)
            guard start >= 0, start + count <= data.count else { throw RemoteZip.Failure.unreadable }
            return data.subdata(in: start..<start + count)
        }
    }

    func testRemoteZipReadsMainInfoPlistFromRanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.ipa")
        let archive = try Archive(url: url, accessMode: .create)
        let files: [(String, Data)] = [
            ("Payload/Test.app/PlugIns/Widget.appex/Info.plist", try HTTPClient.encodePlist(["CFBundleShortVersionString": "9.9"])),
            ("Payload/Test.app/Assets.car", Data((0..<200_000).map { UInt8($0 % 251) })),
            ("Payload/Test.app/Info.plist", try HTTPClient.encodePlist([
                "CFBundleShortVersionString": "4.5.6", "CFBundleIdentifier": "test.remote",
                "releaseDate": "2024-05-03T00:00:00Z"]))
        ]
        for (path, bytes) in files {
            let file = root.appendingPathComponent("src").appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            try archive.addEntry(with: path, relativeTo: root.appendingPathComponent("src"), compressionMethod: .deflate)
        }
        let reader = MemoryRangeReader(data: try Data(contentsOf: url))
        let metadata = try await RemoteZip.versionMetadata(reader)
        XCTAssertEqual(metadata.version, "4.5.6")
        XCTAssertEqual(metadata.packageSize, Int64(reader.data.count), "Use the whole IPA length, not Info.plist's size")
        XCTAssertEqual(metadata.released, ISO8601DateFormatter().date(from: "2024-05-03T00:00:00Z"))

        // Without a recorded date, the archive timestamp is used.
        let plain = root.appendingPathComponent("Plain.ipa")
        let second = try Archive(url: plain, accessMode: .create)
        try second.addEntry(with: "Payload/Plain.app/Info.plist", type: .file, uncompressedSize: Int64(files[2].1.count),
                            compressionMethod: .none, provider: { position, size in
            files[2].1.subdata(in: Int(position)..<Int(position) + size)
        })
        let undated = try await RemoteZip.versionMetadata(MemoryRangeReader(data: try Data(contentsOf: plain)))
        XCTAssertEqual(undated.version, "4.5.6")
        XCTAssertNotNil(undated.released)

        XCTAssertTrue(RemoteZip.isMainInfoPlist("Payload/A.app/Info.plist"))
        XCTAssertFalse(RemoteZip.isMainInfoPlist("Payload/A.app/PlugIns/B.appex/Info.plist"))
        do {
            _ = try await RemoteZip.versionMetadata(MemoryRangeReader(data: Data(repeating: 0, count: 64)))
            XCTFail("A file without a ZIP directory must not produce a version")
        } catch {}
    }

    func testHistoricalIconsComeFromTheirOwnMainPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func package(_ version: String, color: UIColor, includeIcon: Bool) throws -> MemoryRangeReader {
            // The same version is inspected with and without icon reads.
            // Each fixture creation must have its own file, even for the same version.
            let url = root.appendingPathComponent(version + "-" + UUID().uuidString + ".ipa")
            let archive = try Archive(url: url, accessMode: .create)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let png = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 180), format: format).pngData { c in
                color.setFill(); c.fill(CGRect(x: 0, y: 0, width: 180, height: 180))
            }
            var files = [("Payload/Main.app/Info.plist", try HTTPClient.encodePlist([
                "CFBundleShortVersionString": version,
                "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]]])),
                ("Payload/Main.app/Alternate.png", png),
                ("Payload/Main.app/PlugIns/Widget.appex/AppIcon60x60@3x.png", png)]
            if includeIcon { files.append(("Payload/Main.app/AppIcon60x60@3x.png", png)) }
            for (path, bytes) in files {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count),
                                     compressionMethod: .deflate, provider: { position, size in
                    bytes.subdata(in: Int(position)..<Int(position) + size)
                })
            }
            return MemoryRangeReader(data: try Data(contentsOf: url))
        }
        let partial = expectation(description: "version metadata published before icon extraction")
        let old = try await RemoteZip.versionResources(package("1.0", color: .blue, includeIcon: true), onMetadata: { metadata in
            XCTAssertEqual(metadata.version, "1.0")
            XCTAssertNotNil(metadata.packageSize)
            XCTAssertNil(metadata.iconAvailable)
            partial.fulfill()
        })
        await fulfillment(of: [partial], timeout: 3)
        let dateOnly = try await RemoteZip.versionResources(package("1.0", color: .blue, includeIcon: true), includingIcon: false)
        XCTAssertNil(dateOnly.icon)
        XCTAssertNil(dateOnly.metadata.iconAvailable, "Date scans must not mark an uninspected icon unavailable")
        XCTAssertEqual(dateOnly.metadata.version, old.metadata.version)
        let new = try await RemoteZip.versionResources(package("2.0", color: .red, includeIcon: true))
        XCTAssertEqual(old.metadata.version, "1.0")
        XCTAssertEqual(old.metadata.iconAvailable, true)
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(old.icon)))
        XCTAssertNotEqual(old.icon, new.icon, "Different version packages must not share the current store icon")
        let missing = try await RemoteZip.versionResources(package("3.0", color: .green, includeIcon: false))
        XCTAssertEqual(missing.metadata.version, "3.0")
        XCTAssertNotNil(missing.metadata.packageSize)
        XCTAssertEqual(missing.metadata.iconAvailable, false)
        XCTAssertNil(missing.icon, "Never substitute an alternate or extension icon")
    }

    func testVersionIconCacheMigrationAndFileEviction() async throws {
        let store = VersionMetadataStore()
        let key = "icon-migration-" + UUID().uuidString
        let old = VersionMetadata(version: "1.0", packageSize: 123)
        _ = try await store.load(key) { old }
        XCTAssertNil(old.iconAvailable)
        let missing = VersionMetadata(version: "1.0", packageSize: 123, iconAvailable: false)
        let refreshed = try await store.load(key, requiringIcon: true) { missing }
        XCTAssertEqual(refreshed.iconAvailable, false)
        let hit = try await store.load(key, requiringIcon: true) { throw RemoteZip.Failure.unreadable }
        XCTAssertEqual(hit, missing, "A checked missing icon must not request a ticket on every appearance")
        let fileKey = key + "-file"
        let fileURL = VersionMetadataStore.iconURL(fileKey)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let bytes = Data([137, 80, 78, 71])
        try await store.saveIcon(bytes, key: fileKey)
        let available = VersionMetadata(version: "2.0", packageSize: 456, iconAvailable: true)
        _ = try await store.load(fileKey) { available }
        let cached = await store.icon(fileKey)
        XCTAssertEqual(cached, bytes)
        XCTAssertNotEqual(fileURL, VersionMetadataStore.iconURL(key))
        try FileManager.default.removeItem(at: fileURL)
        let evicted = try await store.load(fileKey, requiringIcon: true) { missing }
        XCTAssertEqual(evicted.iconAvailable, false, "Evicted files must be rechecked, not shown as available")

        // Unverified missing-icon entries (failed before reading Info.plist, leaving both
        // released and buildVersion nil) must self-heal when an icon is requested.
        let poisonedKey = key + "-poisoned"
        let poisoned = VersionMetadata(version: "21.45.4", released: nil, packageSize: 275_263_421,
                                       iconAvailable: false, ticketChecked: true,
                                       metadataSchema: VersionMetadata.currentSchema,
                                       bundleShortVersion: "21.45.4", buildVersion: nil)
        _ = try await store.load(poisonedKey, requiringPackageSize: true, requiringIcon: false) { poisoned }
        let healedCalls = LockedCount()
        let healedMeta = VersionMetadata(version: "21.45.4", released: Date(timeIntervalSince1970: 1_714_694_400),
                                         packageSize: 275_263_421, iconAvailable: false, ticketChecked: true,
                                         metadataSchema: VersionMetadata.currentSchema,
                                         bundleShortVersion: "21.45.4", buildVersion: "21.45.4")
        let healed = try await store.load(poisonedKey, requiringPackageSize: true, requiringIcon: true) {
            healedCalls.increment()
            return healedMeta
        }
        XCTAssertEqual(healedCalls.value, 1, "Unverified missing-icon cache entries must retry once")
        XCTAssertEqual(healed.buildVersion, "21.45.4")
        let settledHit = try await store.load(poisonedKey, requiringPackageSize: true, requiringIcon: true) {
            throw RemoteZip.Failure.unreadable
        }
        XCTAssertEqual(settledHit.buildVersion, "21.45.4", "Verified missing-icon entries with Info.plist metadata stay cached")
    }

    func testVersionMetadataSizeCacheMigration() async throws {
        let legacy = try JSONDecoder().decode(VersionMetadata.self, from: Data(#"{"version":"1.2.3"}"#.utf8))
        XCTAssertNil(legacy.packageSize)
        let store = VersionMetadataStore()
        let key = "size-migration-" + UUID().uuidString
        _ = try await store.load(key) { legacy }
        do {
            _ = try await store.load(key, requiringPackageSize: true) { throw RemoteZip.Failure.unreadable }
            XCTFail("A failed size lookup must still report failure")
        } catch RemoteZip.Failure.unreadable {}
        let retained = await store.cached(key)
        XCTAssertEqual(retained, legacy, "A failed refresh must preserve old version/date metadata")
        let updated = VersionMetadata(version: "1.2.3", released: nil, packageSize: 123_456_789)
        let refreshed = try await store.load(key, requiringPackageSize: true) { updated }
        XCTAssertEqual(refreshed, updated)
        let hit = try await store.load(key, requiringPackageSize: true) {
            throw RemoteZip.Failure.unreadable // A complete cache must not make another request.
        }
        XCTAssertEqual(hit.packageSize, 123_456_789)
        let roundTrip = try JSONDecoder().decode(VersionMetadata.self, from: JSONEncoder().encode(hit))
        XCTAssertEqual(roundTrip, hit)

        let macKey = "mac-metadata-" + UUID().uuidString
        _ = try await store.load(macKey) { legacy }
        let macHit = try await store.load(macKey) { throw RemoteZip.Failure.unreadable }
        XCTAssertEqual(macHit, legacy, "Mac metadata without an IPA size remains cacheable")
    }

    func testPhoneNumberLoginsNameTheirStore() {
        XCTAssertEqual(AppleLoginResponse.phoneNumberStorefront("13800138000"), "143465")
        XCTAssertEqual(AppleLoginResponse.phoneNumberStorefront("+86 138-0013-8000"), "143465")
        XCTAssertEqual(AppleLoginResponse.phoneNumberStorefront("008613800138000"), "143465")
        XCTAssertEqual(AppleLoginResponse.phoneNumberStorefront("9876543210"), "143467")
        XCTAssertEqual(AppleLoginResponse.phoneNumberStorefront("+91 98765 43210"), "143467")
        XCTAssertEqual(AppleLoginResponse.phoneNumberStorefront("09876543210"), "143467")
        XCTAssertNil(AppleLoginResponse.phoneNumberStorefront("+1 415 555 0100"))
        XCTAssertNil(AppleLoginResponse.phoneNumberStorefront("user@example.com"))
        XCTAssertNil(AppleLoginResponse.phoneNumberStorefront("12345"))
    }

    func testVersionOrderComparesDottedParts() {
        XCTAssertTrue(VersionOrder.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(VersionOrder.isNewer("2.0.1", than: "2.0"))
        XCTAssertFalse(VersionOrder.isNewer("2.0", than: "2.0.0"))
        XCTAssertFalse(VersionOrder.isNewer("1.9", than: "1.10"))
        XCTAssertTrue(VersionOrder.isNewer("3.0b2", than: "2.9"))
        XCTAssertFalse(VersionOrder.isNewer("", than: "1.0"))
        XCTAssertFalse(VersionOrder.isNewer("beta", than: "1.0"))
    }

    func testDownloadsKnowWhereTheirUpdatesComeFrom() {
        func job(id: String, platform: String?, raw: String? = nil, source: String? = nil) -> DownloadJob {
            var asset: DownloadAsset?
            if let platform {
                asset = DownloadAsset(app: StoreApp(id: id, name: "A", version: "1.0"), url: URL(string: "https://example.com/a.ipa")!,
                                      sinf: Data([1]), metadata: Data(), externalVersionIDs: [], platform: platform, account: "a")
            }
            return DownloadJob(app: StoreApp(id: id, name: "A", version: "1.0"), asset: asset,
                               sourceURL: source.flatMap(URL.init(string:)), rawFormat: raw)
        }
        XCTAssertEqual(job(id: "123", platform: "ios").updatePlatform, .iOS)
        XCTAssertEqual(job(id: "123", platform: "appletvos").updatePlatform, .tvOS)
        XCTAssertEqual(job(id: "123", platform: "ipad").updateKey, "ipad|123")
        XCTAssertEqual(job(id: "123", platform: nil, raw: "pkg", source: "https://osxapps.itunes.apple.com/a.pkg").updatePlatform, .macOS)
        XCTAssertNil(job(id: "123", platform: nil, raw: "dmg", source: "https://developer.example.com/a.dmg").updatePlatform)
        XCTAssertNil(job(id: "com.example.app", platform: "ios").updatePlatform)
        // The store's version wins over the package's own numbering.
        var finished = job(id: "123", platform: "ios")
        finished.app.version = "10.0.21"
        XCTAssertEqual(finished.storeVersion, "1.0")
        XCTAssertEqual(job(id: "123", platform: nil, raw: "pkg", source: "https://osxapps.itunes.apple.com/a.pkg").storeVersion, "1.0")
    }

    func testArcadeCatalogVersionRequiresTheRequestedApp() {
        let data: [String: Any] = ["data": [["id": "123", "type": "apps", "attributes": [
            "deviceFamilies": ["iphone", "ipad"],
            "platformAttributes": ["ios": ["bundleId": "test.arcade", "externalVersionId": 456789]]]]]]
        XCTAssertEqual(StoreService.catalogVersionID(data, id: "123", bundleID: "test.arcade", family: "iphone"), "456789")
        XCTAssertEqual(StoreService.catalogVersionID(data, id: "123", bundleID: "", family: "ipad"), "456789")
        XCTAssertNil(StoreService.catalogVersionID(data, id: "999", bundleID: "", family: "iphone"))
        XCTAssertNil(StoreService.catalogVersionID(data, id: "123", bundleID: "other.app", family: "iphone"))
        XCTAssertNil(StoreService.catalogVersionID(data, id: "123", bundleID: "", family: "appletv"))
    }

    func testScreenshotsFollowPlatformAndAskForSharperRenditions() {
        let row: [String: Any] = [
            "trackId": 1, "artistId": 42, "artistName": "Example Studio",
            "screenshotUrls": ["https://is1-ssl.mzstatic.com/image/thumb/a/392x696bb.jpg"],
            "ipadScreenshotUrls": ["https://is1-ssl.mzstatic.com/image/thumb/b/552x414bb.png"],
            "appletvScreenshotUrls": []]
        let phone = StoreService.listingExtras(row, platform: .iOS)
        XCTAssertEqual(phone.screenshots.first?.url.lastPathComponent, "1392x1392bb.jpg")
        XCTAssertEqual(phone.screenshots.first?.aspect ?? 0, 392.0 / 696.0, accuracy: 0.001)
        XCTAssertEqual(phone.developerID, "42")
        XCTAssertEqual(phone.developer, "Example Studio")
        XCTAssertEqual(StoreService.listingExtras(row, platform: .iPadOS).screenshots.first?.url.lastPathComponent, "1104x1104bb.png")
        XCTAssertTrue(StoreService.listingExtras(row, platform: .tvOS).screenshots.isEmpty)
        // A shared iPhone App ID has no Mac screenshots; iPhone ones are not shown instead.
        XCTAssertTrue(StoreService.listingExtras(row, platform: .macOS).screenshots.isEmpty)
        var mac = row; mac["kind"] = "mac-software"
        XCTAssertEqual(StoreService.listingExtras(mac, platform: .macOS).screenshots.count, 1)
        var phoneOnly = row; phoneOnly["ipadScreenshotUrls"] = []
        XCTAssertTrue(StoreService.listingExtras(phoneOnly, platform: .iPadOS).screenshots.isEmpty)
        XCTAssertEqual(StoreService.screenshot("https://example.com/shot.jpg")?.url.lastPathComponent, "shot.jpg")
        XCTAssertNil(StoreService.screenshot("http://example.com/392x696bb.jpg"))
    }

    func testDeveloperAppsSkipTheDeveloperRowAndTheCurrentApp() {
        let rows: [[String: Any]] = [
            ["wrapperType": "artist", "artistId": 42, "artistName": "Example Studio"],
            ["wrapperType": "software", "trackId": 1, "trackName": "Current"],
            ["wrapperType": "software", "trackId": 2, "trackName": "Second"],
            ["wrapperType": "software", "trackId": 2, "trackName": "Second again"],
            ["wrapperType": "software", "trackId": 3, "trackName": "TV", "supportedDevices": ["AppleTV4K"]]]
        XCTAssertEqual(StoreService.developerApps(rows, excluding: "1", platform: .iOS).map(\.id), ["2", "3"])
        XCTAssertEqual(StoreService.developerApps(rows, excluding: "1", platform: .tvOS).map(\.id), ["3"])
    }

    func testVersionServicePrefersDottedVersionsAndStripsNonVersionText() {
        XCTAssertEqual(VersionService.sanitizedVersion("  14.2.1 "), "14.2.1")
        XCTAssertEqual(VersionService.sanitizedVersion("4800"), "4800", "Numeric integer build strings must not have synthetic dots inserted")
        XCTAssertEqual(VersionService.sanitizedVersion("845839234", rejectingID: "845839234"), AppVersion.unknown)
        XCTAssertEqual(VersionService.sanitizedVersion("3.5.9", rejectingID: "845839234"), "3.5.9")
        XCTAssertEqual(VersionService.sanitizedVersion("aktualisiert"), AppVersion.unknown)
        XCTAssertEqual(VersionService.sanitizedVersion("enthält einige Leistungsverbesserungen"), AppVersion.unknown)
        XCTAssertEqual(VersionService.sanitizedVersion(""), AppVersion.unknown)

        XCTAssertGreaterThan(VersionService.versionPreference("117.0"), VersionService.versionPreference("2817"))
        XCTAssertGreaterThan(VersionService.versionPreference("2817"), VersionService.versionPreference(AppVersion.unknown))

        // Higher-tier dotted version overrides dotless build integer regardless of source order.
        let integerFirst = [
            AppVersion(id: "884016839", version: "2817", source: "iosdump"),
            AppVersion(id: "884016840", version: "4800", source: "iosdump"),
            AppVersion(id: "884016841", version: "aktualisiert", source: "Timbrd")
        ]
        let dottedSecond = [
            AppVersion(id: "884016839", version: "117.0", source: "Timbrd")
        ]
        let merged = VersionService.mergeSourceResults([integerFirst, dottedSecond])
        XCTAssertEqual(merged.map(\.id), ["884016839", "884016840", "884016841"])
        XCTAssertEqual(merged[0].version, "117.0")
        XCTAssertEqual(merged[1].version, "4800", "Fallback dotless integer stays intact when no dotted candidate exists")
        XCTAssertEqual(merged[2].version, AppVersion.unknown)
    }

    func testToolSettingsDecodesShowHistoryIconsWithDefaultTrue() throws {
        let legacy = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"showDiscover":false}"#.utf8))
        XCTAssertTrue(legacy.showHistoryIcons)

        var settings = ToolSettings()
        settings.showHistoryIcons = false
        let roundTrip = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(roundTrip.showHistoryIcons)
    }

    func testVersionMetadataStorePreservesCachedIconWhenLoadingWithoutIcons() async throws {
        let store = VersionMetadataStore()
        let key = "icon-preserve-" + UUID().uuidString
        let fileURL = VersionMetadataStore.iconURL(key)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await store.saveIcon(Data([137, 80, 78, 71]), key: key)
        _ = try await store.load(key, requiringPackageSize: true, requiringIcon: true) {
            VersionMetadata(version: "2.1.0", released: nil, packageSize: 500, iconAvailable: true)
        }
        // Force a metadata refresh without icons (e.g. toggling showHistoryIcons OFF).
        let updated = try await store.load(key, requiringPackageSize: false, requiringIcon: false) {
            VersionMetadata(version: "2.1.0", released: nil, packageSize: 500, iconAvailable: nil)
        }
        XCTAssertEqual(updated.iconAvailable, true)
        let cachedBytes = await store.icon(key)
        XCTAssertEqual(cachedBytes, Data([137, 80, 78, 71]))
    }

    func testDownloadActivityStateCalculationThrottlingAndSpeedDecay() throws {
        if #available(iOS 16.1, *) {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let running = DownloadJob(app: StoreApp(id: "1", name: "App One", version: "1.0", size: 20_000_000),
                                      status: .running, downloaded: 5_000_000, expected: 20_000_000)
            let queued = DownloadJob(app: StoreApp(id: "2", name: "App Two", version: "1.0", size: 10_000_000),
                                     status: .queued, downloaded: 0, expected: 10_000_000)
            let state = DownloadActivity.computeState(
                active: [running, queued],
                progress: { ($0.downloaded, $0.expected) },
                rate: { $0 == running.id ? 2_500_000 : 9_999_999 },
                now: now
            )
            XCTAssertEqual(state.phase, 0)
            XCTAssertEqual(state.count, 2)
            XCTAssertEqual(state.written, 5_000_000, "Only running cohort bytes contribute to phase 0")
            XCTAssertEqual(state.speed, 2_500_000)
            XCTAssertNotNil(state.estimatedEnd)
            XCTAssertEqual(state.estimatedEnd!.timeIntervalSince(now), 6.0, accuracy: 0.05)

            let paused = DownloadActivity.computePausedState(
                paused: [running],
                progress: { _ in (5_000_000, 20_000_000) },
                now: now
            )
            XCTAssertEqual(paused.phase, 7)
            XCTAssertEqual(paused.speed, 0)
            XCTAssertNil(paused.estimatedEnd)

            // Backwards-compatible ContentState decoding without speed key.
            let legacyJSON = #"{"phase":0,"name":"Legacy","count":1,"written":10,"expected":100,"updated":1700000000}"#
            let decoded = try JSONDecoder().decode(DownloadActivityAttributes.ContentState.self, from: Data(legacyJSON.utf8))
            XCTAssertEqual(decoded.speed, 0)

            // Throttle sub-second progress updates while pushing immediate phase/ETA changes.
            var moved = state
            moved.written += 4096
            XCTAssertFalse(DownloadActivity.shouldSend(moved, after: state, elapsed: 0.4))
            XCTAssertTrue(DownloadActivity.shouldSend(moved, after: state, elapsed: 1.0))
            XCTAssertTrue(DownloadActivity.shouldSend(paused, after: state, elapsed: 0.1))

            var faster = state
            faster.speed = 4_000_000
            faster.estimatedEnd = now.addingTimeInterval(3.75)
            XCTAssertFalse(DownloadActivity.shouldSend(faster, after: state, elapsed: 0.5))
            XCTAssertTrue(DownloadActivity.shouldSend(faster, after: state, elapsed: 1.0))
        }
    }

    func testOPlayerVersionPrecedenceAndReconciliationKeepTrustedVersions() async throws {
        // Real-world OPlayer Lite cases: 857150582 ("4.8" vs "4800") and 853114367 ("4.7.2" vs "4720").
        XCTAssertGreaterThan(VersionService.versionPreference("4.8", rejectingID: "857150582"),
                             VersionService.versionPreference("4800", rejectingID: "857150582"))
        XCTAssertGreaterThan(VersionService.versionPreference("4.7.2", rejectingID: "853114367"),
                             VersionService.versionPreference("4720", rejectingID: "853114367"))
        XCTAssertEqual(VersionService.versionPreference("4800."), 1)
        XCTAssertEqual(VersionService.preferredVersion("4800", over: "4.8", rejectingID: "857150582"), "4.8")
        XCTAssertEqual(VersionService.preferredVersion("4.8", over: "4800", rejectingID: "857150582"), "4.8")
        XCTAssertEqual(VersionService.bestVersion(["4720", "未知版本", "4.7.2"], rejectingID: "853114367"), "4.7.2")
        XCTAssertEqual(VersionService.bestVersion(["4100", AppVersion.unknown], rejectingID: "834116228"), "4100",
                       "Dotless versions remain fallback when no dotted version exists")

        // Reading an IPA whose Info.plist carries "4800" must not downgrade Apple's ticket version "4.8".
        let ipa = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-" + UUID().uuidString + ".ipa")
        defer { try? FileManager.default.removeItem(at: ipa) }
        let archive = try Archive(url: ipa, accessMode: .create)
        let plistData = try HTTPClient.encodePlist(["CFBundleShortVersionString": "4800"])
        try archive.addEntry(with: "Payload/OPlayerLite.app/Info.plist", type: .file, uncompressedSize: Int64(plistData.count),
                             compressionMethod: .deflate, provider: { pos, len in plistData.subdata(in: Int(pos)..<Int(pos) + len) })
        let reader = MemoryRangeReader(data: try Data(contentsOf: ipa))

        let raw = try await RemoteZip.versionResources(reader, includingIcon: false)
        XCTAssertEqual(raw.metadata.version, "4800")

        let streamedVersions = LockedList<String>()
        let reconciled = try await RemoteZip.versionResources(reader, includingIcon: false, preferredVersion: "4.8") { partial in
            streamedVersions.append(partial.version)
        }
        XCTAssertEqual(streamedVersions.values, ["4.8"])
        XCTAssertEqual(reconciled.metadata.version, "4.8")

        // A dotless record without ticketChecked re-checks Apple ticket metadata once, then stays cached.
        let store = VersionMetadataStore()
        let key = "oplayer-" + UUID().uuidString
        let unverifiedCalls = LockedCount()
        _ = try await store.load(key, requiringPackageSize: true, requiringIcon: false) {
            unverifiedCalls.increment()
            return VersionMetadata(version: "4800", released: nil, packageSize: 107_223_040, iconAvailable: false, ticketChecked: nil)
        }
        XCTAssertEqual(unverifiedCalls.value, 1)

        // Because ticketChecked was nil and version was dotless, one verification runs and upgrades to "4.8".
        let upgraded = try await store.load(key, requiringPackageSize: true, requiringIcon: false) {
            unverifiedCalls.increment()
            return VersionMetadata(version: "4.8", released: nil, packageSize: 107_223_040, iconAvailable: false, ticketChecked: true)
        }
        XCTAssertEqual(upgraded.version, "4.8")
        XCTAssertEqual(unverifiedCalls.value, 2)

        // Subsequent reads serve the settled "4.8" from cache without another network check.
        let cachedHit = try await store.load(key, requiringPackageSize: true, requiringIcon: false) {
            unverifiedCalls.increment()
            return VersionMetadata(version: "9.9.9", released: nil, packageSize: 1, iconAvailable: false, ticketChecked: true)
        }
        XCTAssertEqual(cachedHit.version, "4.8")
        XCTAssertEqual(unverifiedCalls.value, 2)
    }

    func testToolSettingsDecodesPrioritizeDelistedSearchResultsWithDefaultTrue() throws {
        let defaults = ToolSettings()
        XCTAssertTrue(defaults.prioritizeDelistedSearchResults)

        let legacy = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"searchLimit":50}"#.utf8))
        XCTAssertTrue(legacy.prioritizeDelistedSearchResults)

        var disabled = ToolSettings()
        disabled.prioritizeDelistedSearchResults = false
        let roundTrip = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(disabled))
        XCTAssertFalse(roundTrip.prioritizeDelistedSearchResults)
    }

    func testDelistedSearchPrioritizationPreservesRelevanceAndRejectsFalsePositives() async {
        // 1. Confirmed delisted exact match promotes ahead of live partial matches when enabled.
        var forwardDelisted = StoreApp(id: "6503940939", name: "Forward", price: "")
        forwardDelisted.delisted = true
        let liveRemote = [
            StoreApp(id: "1", name: "Forward Mail", price: ""),
            StoreApp(id: "2", name: "Port Forward Utility", price: "")
        ]
        let promoted = AppSearchRanking.arrange(
            remote: liveRemote,
            local: [forwardDelisted],
            aliasesByID: ["6503940939": ["Forward - AI Media Hub", "新视界"]],
            query: "Forward",
            prioritizeDelisted: true
        )
        XCTAssertEqual(promoted.results.map(\.id), ["6503940939", "1", "2"])
        XCTAssertTrue(promoted.localResults.isEmpty)

        // Turning the switch off restores the original live results order and separate local group.
        let original = AppSearchRanking.arrange(
            remote: liveRemote,
            local: [forwardDelisted],
            aliasesByID: ["6503940939": ["Forward - AI Media Hub", "新视界"]],
            query: "Forward",
            prioritizeDelisted: false
        )
        XCTAssertEqual(original.results.map(\.id), ["1", "2"])
        XCTAssertEqual(original.localResults.map(\.id), ["6503940939"])

        // 2. Weak substring delisted match stays below stronger exact live matches while rising above weak live ones.
        var helperDelisted = StoreApp(id: "9001", name: "WeChat Backup Helper", price: "")
        helperDelisted.delisted = true
        let wechatRemote = [
            StoreApp(id: "414478124", name: "WeChat", price: ""),
            StoreApp(id: "414478125", name: "My WeChat Theme Pack", price: "")
        ]
        let ranked = AppSearchRanking.arrange(
            remote: wechatRemote,
            local: [helperDelisted],
            query: "WeChat",
            prioritizeDelisted: true
        )
        XCTAssertEqual(ranked.results.map(\.id), ["414478124", "9001", "414478125"])

        // 3. Verification rejects region-limited apps and transient request failures as non-delisted.
        let context = StoreContext(country: "CN", platform: .iOS)
        let regionLimitedStatuses = await StoreService.verifyDelistedStatuses(
            ids: ["932747118", "6503940939"],
            store: context,
            accountCountry: "CN"
        ) { _, country in
            if country == "US" {
                return ["932747118": StoreApp(id: "932747118", name: "Shadowrocket", price: "$2.99")]
            }
            return [:]
        }
        XCTAssertEqual(regionLimitedStatuses["932747118"], .listed, "Available in US storefront must never be marked delisted")
        XCTAssertEqual(regionLimitedStatuses["6503940939"], .delisted)

        let errorStatuses = await StoreService.verifyDelistedStatuses(
            ids: ["6503940939"],
            store: context,
            accountCountry: "CN"
        ) { _, country in
            if country == "JP" { throw HTTPStatusError(code: 503) }
            return [:]
        }
        XCTAssertEqual(errorStatuses["6503940939"], .inconclusive, "Persistent HTTP failures must never mark an app delisted")

        // 4. Single-storefront transient failure recovers cleanly on retry without masking delisted matches.
        let jpAttempts = LockedCount()
        let recoveredStatuses = await StoreService.verifyDelistedStatuses(
            ids: ["6503940939"],
            store: context,
            accountCountry: "CN"
        ) { _, country in
            if country == "JP", jpAttempts.next() == 1 { throw HTTPStatusError(code: 503) }
            return [:]
        }
        XCTAssertEqual(jpAttempts.value, 2)
        XCTAssertEqual(recoveredStatuses["6503940939"], .delisted)
    }

    func testPairingBadgeColorsMeetContrastInLightAndDarkModes() throws {
        func relativeLuminance(_ color: UIColor, traits: UITraitCollection, over backdrop: UIColor? = nil) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a))
            if let backdrop, a < 1 {
                var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                XCTAssertTrue(backdrop.resolvedColor(with: traits).getRed(&br, green: &bg, blue: &bb, alpha: &ba))
                r = r * a + br * (1 - a)
                g = g * a + bg * (1 - a)
                b = b * a + bb * (1 - a)
            }
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        let accent = try XCTUnwrap(UIColor(named: "AccentColor", in: Bundle(for: ToolStore.self), compatibleWith: nil) ?? UIColor(named: "AccentColor"))
        let onAccent = UIColor.systemBackground
        let groupedBg = UIColor.secondarySystemGroupedBackground
        let inactiveFill = UIColor.tertiarySystemFill

        for style in [UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let inactiveText = UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.75)
            let activeRatio = contrast(
                relativeLuminance(onAccent, traits: traits),
                relativeLuminance(accent, traits: traits)
            )
            XCTAssertGreaterThanOrEqual(activeRatio, 7.0, "Active pairing step badge must stay high-contrast in style \(style.rawValue)")

            let inactiveBgLum = relativeLuminance(inactiveFill, traits: traits, over: groupedBg)
            let inactiveFgLum = relativeLuminance(inactiveText, traits: traits, over: groupedBg)
            let inactiveRatio = contrast(inactiveFgLum, inactiveBgLum)
            XCTAssertGreaterThanOrEqual(inactiveRatio, 4.5, "Inactive pairing step badge must meet WCAG AA contrast in style \(style.rawValue)")
        }
    }

    func testVersionMetadataStoreUpgradesCachedDotlessEntriesWithKnownVersion() async throws {
        let store = VersionMetadataStore()
        let key48 = "iOS|385907472-" + UUID().uuidString + "|857150582"
        let key472 = "iOS|385907472-" + UUID().uuidString + "|853114367"

        // Seed a dotless settled record (e.g. from an earlier query without knownVersion).
        _ = try await store.load(key48, requiringPackageSize: true, requiringIcon: false) {
            VersionMetadata(version: "4800", released: nil, packageSize: 65_000_000, iconAvailable: false, ticketChecked: true)
        }
        let upgradedHit = try await store.load(key48, requiringPackageSize: true, requiringIcon: false, knownVersion: "4.8") {
            XCTFail("Upgrading settled dotless cache with knownVersion must not re-fetch")
            return VersionMetadata(version: "4800", released: nil, packageSize: 65_000_000)
        }
        XCTAssertEqual(upgradedHit.version, "4.8")
        let cachedAfterHit = await store.cached(key48)
        XCTAssertEqual(cachedAfterHit?.version, "4.8")

        // Version ID must never replace an already resolved version number.
        let preserved = try await store.load(key48, requiringPackageSize: false, requiringIcon: false, knownVersion: "857150582") {
            XCTFail("Version ID fallback must not re-fetch")
            return VersionMetadata(version: "857150582", released: nil)
        }
        XCTAssertEqual(preserved.version, "4.8")

        // When a fetch still returns a dotless build string, knownVersion takes precedence.
        let resolvedFetch = try await store.load(key472, requiringPackageSize: true, requiringIcon: false, knownVersion: "4.7.2") {
            VersionMetadata(version: "4720", released: nil, packageSize: 60_900_000, iconAvailable: false, ticketChecked: true)
        }
        XCTAssertEqual(resolvedFetch.version, "4.7.2")

        try await store.clearCache()
        let cleared48 = await store.cached(key48)
        let cleared472 = await store.cached(key472)
        XCTAssertNil(cleared48)
        XCTAssertNil(cleared472)
    }

    func testReconcileTicketAndRemoteZipCFBundleVersionFallback() async throws {
        // Dotted marketing version must remain preferred over dotless build number.
        XCTAssertEqual(VersionService.reconcileTicketVersion(shortVersion: "2.23.1", buildVersion: "4687"), "2.23.1")
        // Empty CFBundleShortVersionString + dotted CFBundleVersion must recover the dotted build version.
        XCTAssertEqual(VersionService.reconcileTicketVersion(shortVersion: "", buildVersion: "2.0.18"), "2.0.18")
        // Dotless stale ticket short version yields to dotted build version.
        XCTAssertEqual(VersionService.reconcileTicketVersion(shortVersion: "4800", buildVersion: "2.0.18"), "2.0.18")
        // Equal dotless pair preserves short version.
        XCTAssertEqual(VersionService.reconcileTicketVersion(shortVersion: "4600", buildVersion: "4600"), "4600")

        let legacyIpa = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-build-" + UUID().uuidString + ".ipa")
        let dotlessIpa = FileManager.default.temporaryDirectory.appendingPathComponent("dotless-build-" + UUID().uuidString + ".ipa")
        defer {
            try? FileManager.default.removeItem(at: legacyIpa)
            try? FileManager.default.removeItem(at: dotlessIpa)
        }

        let legacyArchive = try Archive(url: legacyIpa, accessMode: .create)
        let legacyPlist = try HTTPClient.encodePlist([
            "CFBundleShortVersionString": "",
            "CFBundleVersion": "2.0.18"
        ])
        try legacyArchive.addEntry(with: "Payload/Legacy.app/Info.plist", type: .file, uncompressedSize: Int64(legacyPlist.count),
                                   compressionMethod: .deflate, provider: { pos, len in legacyPlist.subdata(in: Int(pos)..<Int(pos) + len) })
        let legacyReader = MemoryRangeReader(data: try Data(contentsOf: legacyIpa))
        let legacyResult = try await RemoteZip.versionResources(legacyReader, includingIcon: false, preferredVersion: "4800")
        XCTAssertEqual(legacyResult.metadata.version, "2.0.18")
        XCTAssertEqual(legacyResult.metadata.metadataSchema, VersionMetadata.currentSchema)

        let dotlessArchive = try Archive(url: dotlessIpa, accessMode: .create)
        let dotlessPlist = try HTTPClient.encodePlist(["CFBundleShortVersionString": "4600"])
        try dotlessArchive.addEntry(with: "Payload/Mid.app/Info.plist", type: .file, uncompressedSize: Int64(dotlessPlist.count),
                                    compressionMethod: .deflate, provider: { pos, len in dotlessPlist.subdata(in: Int(pos)..<Int(pos) + len) })
        let dotlessReader = MemoryRangeReader(data: try Data(contentsOf: dotlessIpa))
        let tiedDotless = try await RemoteZip.versionResources(dotlessReader, includingIcon: false, preferredVersion: "4800")
        XCTAssertEqual(tiedDotless.metadata.version, "4600", "IPA Info.plist must beat equal-score dotless ticket fallback")
        let promotedMarketing = try await RemoteZip.versionResources(dotlessReader, includingIcon: false, preferredVersion: "4.6")
        XCTAssertEqual(promotedMarketing.metadata.version, "4.6")
    }

    func testStaleLatestFallbackAndReleaseNotesReconciliation() {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_660_000_000)
        let versions = [
            AppVersion(id: "857150582", version: "4.8", source: "Apple"),
            AppVersion(id: "853114367", version: "4.7.2", source: "Apple"),
            AppVersion(id: "851673782", version: "4600", source: "Apple"),
            AppVersion(id: "839530364", version: "4510", source: "Apple"),
            AppVersion(id: "815711689", version: "2109", source: "Apple"),
            AppVersion(id: "815711688", version: "2109", source: "Apple"),
            AppVersion(id: "812900001", version: "2103", source: "Apple"),
            AppVersion(id: "518812657", version: "2.0.18", source: "Apple")
        ]
        var meta: [String: VersionMetadata] = [
            "857150582": VersionMetadata(version: "4.8", released: base.addingTimeInterval(400 * day)),
            "851673782": VersionMetadata(version: "4600", released: base.addingTimeInterval(200 * day)),
            "839530364": VersionMetadata(version: "4510", released: base.addingTimeInterval(100 * day)),
            "815711689": VersionMetadata(version: "2109", released: base),
            "815711688": VersionMetadata(version: "2109", released: base.addingTimeInterval(-10 * day)),
            "812900001": VersionMetadata(version: "2103", released: base.addingTimeInterval(-150 * day)),
            "518812657": VersionMetadata(version: "2.0.18", released: base.addingTimeInterval(-800 * day))
        ]

        XCTAssertFalse(VersionService.isLikelyStaleLatestFallback(
            "4800", versionID: "857150582", appVersion: "4.8", versions: versions, cachedMetadata: meta, rowIndex: 0
        ))
        XCTAssertTrue(VersionService.isLikelyStaleLatestFallback(
            "4800", versionID: "851673782", appVersion: "4.8", versions: versions, cachedMetadata: meta, rowIndex: 2
        ))
        XCTAssertTrue(VersionService.isLikelyStaleLatestFallback(
            "4800", versionID: "518812657", appVersion: "4.8", versions: versions, cachedMetadata: meta, rowIndex: 7
        ))
        XCTAssertFalse(VersionService.isLikelyStaleLatestFallback(
            "4600", versionID: "851673782", appVersion: "4.8", versions: versions, cachedMetadata: meta, rowIndex: 2
        ))
        XCTAssertFalse(VersionService.isLikelyStaleLatestFallback(
            "2103", versionID: "812900001", appVersion: "4.8", versions: versions, cachedMetadata: meta, rowIndex: 6
        ))

        let notes = [
            ReleaseNote(version: "4.8", date: base.addingTimeInterval(402 * day), text: ""),
            ReleaseNote(version: "4.6", date: base.addingTimeInterval(202 * day), text: ""),
            ReleaseNote(version: "4.5.1", date: base.addingTimeInterval(101 * day), text: ""),
            ReleaseNote(version: "2.1.09", date: base.addingTimeInterval(1 * day), text: "")
        ]

        let updates = Dictionary(
            VersionService.reconcileWithReleaseNotes(
                versions: versions, metadata: meta, notes: notes, appVersion: "4.8"
            ).map { ($0.id, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(updates["851673782"], "4.6")
        XCTAssertEqual(updates["839530364"], "4.5.1")
        XCTAssertEqual(updates["815711689"], "2.1.09")
        XCTAssertEqual(updates["815711688"], "2.1.09")
        XCTAssertNil(updates["812900001"], "Unverified pre-cutoff dotless build absent from release notes must not be guessed")

        // A stale "4800" on an old 2014 row must never be matched to "4.8" release notes.
        XCTAssertNil(VersionService.reconcileSingleWithReleaseNotes(
            versionID: "518812657", rawVersion: "4800", released: meta["518812657"]?.released,
            versions: versions, metadata: meta, notes: notes, appVersion: "4.8", rowIndex: 7
        ))

        // Ambiguous candidates ("1.0" vs "10.0" for "100") must be declined instead of guessing.
        meta["812900001"]?.version = "100"
        let ambiguousVersions = [
            AppVersion(id: "857150582", version: "11.0", source: "Apple"),
            AppVersion(id: "812900001", version: "100", source: "Apple")
        ]
        let ambiguousNotes = [
            ReleaseNote(version: "1.0", date: meta["812900001"]?.released?.addingTimeInterval(day), text: ""),
            ReleaseNote(version: "10.0", date: meta["812900001"]?.released?.addingTimeInterval(2 * day), text: "")
        ]
        XCTAssertNil(VersionService.reconcileSingleWithReleaseNotes(
            versionID: "812900001", rawVersion: "100", released: meta["812900001"]?.released,
            versions: ambiguousVersions, metadata: meta, notes: ambiguousNotes, appVersion: "11.0", rowIndex: 1
        ))
    }

    func testVersionMetadataStoreRepairsLegacyStaleFallbackWithoutWipingValidDotless() async throws {
        let store = VersionMetadataStore()
        try await store.clearCache()
        defer { Task { try? await store.clearCache() } }

        let staleKey = "iOS|app-" + UUID().uuidString + "|518812657"
        let validKey = "iOS|app-" + UUID().uuidString + "|851673782"

        _ = try await store.load(staleKey, requiringPackageSize: true, requiringIcon: false) {
            VersionMetadata(version: "4800", released: nil, packageSize: 12_000_000, iconAvailable: false, ticketChecked: true, metadataSchema: nil)
        }
        _ = try await store.load(validKey, requiringPackageSize: true, requiringIcon: false) {
            VersionMetadata(version: "4600", released: nil, packageSize: 34_000_000, iconAvailable: false, ticketChecked: true, metadataSchema: nil)
        }

        // Poisoned legacy "4800" entry is bypassed when allowCached returns false and replaced cleanly
        // (even if the repaired version has equal or lower score than 4800).
        let staleFetchCount = LockedCount()
        let repaired = try await store.load(
            staleKey, requiringPackageSize: true, requiringIcon: false,
            allowCached: { $0.metadataSchema != nil }
        ) {
            staleFetchCount.increment()
            return VersionMetadata(version: "2103", released: nil, packageSize: 12_000_000, iconAvailable: false,
                                   ticketChecked: true, metadataSchema: VersionMetadata.currentSchema)
        }
        XCTAssertEqual(staleFetchCount.value, 1)
        XCTAssertEqual(repaired.version, "2103")
        XCTAssertEqual(repaired.metadataSchema, VersionMetadata.currentSchema)

        // Valid legacy dotless entry "4600" remains a cache hit without redundant network refetch.
        let validHit = try await store.load(
            validKey, requiringPackageSize: true, requiringIcon: false,
            allowCached: { _ in true }
        ) {
            XCTFail("Valid dotless cached row must not trigger redundant network refetch")
            return VersionMetadata(version: "4600", released: nil)
        }
        XCTAssertEqual(validHit.version, "4600")

        await store.upgradeCachedVersion(validKey, version: "4.6", replaceDotless: true)
        let upgraded = await store.cached(validKey)
        XCTAssertEqual(upgraded?.version, "4.6")
        XCTAssertEqual(upgraded?.metadataSchema, VersionMetadata.currentSchema)

        // Resetting a poisoned dotless cache to AppVersion.unknown must evict it for re-fetch
        // rather than marking "未知版本" as settled and suppressing CFBundleVersion recovery.
        let poisonedKey = "iOS|app-" + UUID().uuidString + "|411752640"
        _ = try await store.load(poisonedKey, requiringPackageSize: true, requiringIcon: false) {
            VersionMetadata(version: "4800", released: nil, packageSize: 29_000_000, iconAvailable: false, ticketChecked: true, metadataSchema: nil)
        }
        await store.upgradeCachedVersion(poisonedKey, version: AppVersion.unknown, replaceDotless: true)
        let recoveredCalls = LockedCount()
        let recovered = try await store.load(poisonedKey, requiringPackageSize: true, requiringIcon: false) {
            recoveredCalls.increment()
            return VersionMetadata(version: "2.0.17", released: nil, packageSize: 29_000_000, iconAvailable: false,
                                   ticketChecked: true, metadataSchema: VersionMetadata.currentSchema)
        }
        XCTAssertEqual(recoveredCalls.value, 1, "Invalidating stale fallback to unknown must trigger fresh fetch")
        XCTAssertEqual(recovered.version, "2.0.17")
        try await store.clearCache()
    }

    func testReconcileWithReleaseNotesHandlesOutOfOrderMergedIDs() {
        let base = Date(timeIntervalSince1970: 1_660_000_000)
        let day: TimeInterval = 86_400

        // Source merging must place a version missing from earlier sources at its anchor position.
        let timbrd = [
            AppVersion(id: "857150582", version: "4.8", source: "Timbrd"),
            AppVersion(id: "853114367", version: "4.7.2", source: "Timbrd"),
            AppVersion(id: "839530364", version: "4510", source: "Timbrd")
        ]
        let iosdump = [
            AppVersion(id: "857150582", version: "4.8", source: "iOSDump"),
            AppVersion(id: "853114367", version: "4.7.2", source: "iOSDump"),
            AppVersion(id: "851673782", version: "4600", source: "iOSDump"),
            AppVersion(id: "839530364", version: "4510", source: "iOSDump")
        ]
        let merged = VersionService.mergeSourceResults([timbrd, iosdump])
        XCTAssertEqual(merged.map(\.id), ["857150582", "853114367", "851673782", "839530364"])

        // Even with an out-of-order newer ID ("851673782") lingering near the bottom of an older cache,
        // "813305138" ("2106") must still reconcile to "2.1.06" from Apple Release Notes.
        let versions = [
            AppVersion(id: "857150582", version: "4.8", source: "Timbrd"),
            AppVersion(id: "815648435", version: "2.1.08", source: "Timbrd"),
            AppVersion(id: "813305138", version: "2106", source: "Timbrd"),
            AppVersion(id: "812900001", version: "2103", source: "Timbrd"),
            AppVersion(id: "851673782", version: "4.6", source: "iOSDump")
        ]
        let meta: [String: VersionMetadata] = [
            "857150582": VersionMetadata(version: "4.8", released: base.addingTimeInterval(400 * day)),
            "815648435": VersionMetadata(version: "2.1.08", released: base.addingTimeInterval(20 * day)),
            "851673782": VersionMetadata(version: "4.6", released: base.addingTimeInterval(250 * day))
        ]
        let notes = [
            ReleaseNote(version: "4.8", date: base.addingTimeInterval(402 * day), text: ""),
            ReleaseNote(version: "4.6", date: base.addingTimeInterval(251 * day), text: ""),
            ReleaseNote(version: "2.1.08", date: base.addingTimeInterval(21 * day), text: ""),
            ReleaseNote(version: "2.1.06", date: base.addingTimeInterval(1 * day), text: "")
        ]
        let updates = Dictionary(
            VersionService.reconcileWithReleaseNotes(versions: versions, metadata: meta, notes: notes, appVersion: "4.8")
                .map { ($0.id, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(updates["813305138"], "2.1.06")
        XCTAssertNil(updates["812900001"])
    }

    func testVersionMetadataSeparatesMarketingAndBundleShortVersions() async throws {
        let store = VersionMetadataStore()
        try await store.clearCache()
        defer { Task { try? await store.clearCache() } }

        let key = "iOS|eplayer-" + UUID().uuidString + "|892622938"
        _ = try await store.load(key, requiringPackageSize: true, requiringIcon: false) {
            VersionMetadata(version: "10.0.22", released: nil, packageSize: 113_000_000, iconAvailable: false, ticketChecked: true, metadataSchema: 3)
        }
        let calls = LockedCount()
        let migrated = try await store.load(key, requiringPackageSize: true, requiringIcon: false, knownVersion: "1.9.5") {
            calls.increment()
            return VersionMetadata(version: "10.0.22", released: nil)
        }
        XCTAssertEqual(calls.value, 0, "Legacy schema should separate stored CFBundleShortVersionString in place")
        XCTAssertEqual(migrated.version, "1.9.5")
        XCTAssertEqual(migrated.bundleShortVersion, "10.0.22")
        XCTAssertEqual(migrated.metadataSchema, VersionMetadata.currentSchema)

        let freshKey = "iOS|eplayer-" + UUID().uuidString + "|889722446"
        let fresh = try await store.load(freshKey, requiringPackageSize: true, requiringIcon: false, knownVersion: "1.9.1") {
            VersionMetadata(version: "10.0.18", released: nil, packageSize: 134_000_000, iconAvailable: false,
                            ticketChecked: true, metadataSchema: VersionMetadata.currentSchema,
                            bundleShortVersion: "10.0.18", buildVersion: "4")
        }
        XCTAssertEqual(fresh.version, "1.9.1")
        XCTAssertEqual(fresh.bundleShortVersion, "10.0.18")
        XCTAssertEqual(fresh.buildVersion, "4")
        try await store.clearCache()
    }

    func testPackageServiceAcceptsHistoricalBundleVersionDispatchAndRejectsMismatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-ver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeIPA(name: String, bundleID: String, short: String, build: String, extID: String? = nil) throws -> URL {
            let ipa = root.appendingPathComponent(name + ".ipa")
            let archive = try Archive(url: ipa, accessMode: .create)
            var info: [String: Any] = [
                "CFBundleDisplayName": name,
                "CFBundleIdentifier": bundleID,
                "CFBundleShortVersionString": short,
                "CFBundleVersion": build,
                "CFBundleExecutable": "App"
            ]
            let infoData = try HTTPClient.encodePlist(info)
            try archive.addEntry(with: "Payload/App.app/Info.plist", type: .file, uncompressedSize: Int64(infoData.count),
                                 compressionMethod: .deflate, provider: { pos, len in infoData.subdata(in: Int(pos)..<Int(pos) + len) })
            let supp = Data([1, 2])
            try archive.addEntry(with: "Payload/App.app/SC_Info/App.supp", type: .file, uncompressedSize: Int64(supp.count),
                                 compressionMethod: .deflate, provider: { pos, len in supp.subdata(in: Int(pos)..<Int(pos) + len) })
            if let extID {
                let metaData = try HTTPClient.encodePlist(["itemId": 385907472, "softwareVersionExternalIdentifier": Int(extID) ?? 0])
                try archive.addEntry(with: "iTunesMetadata.plist", type: .file, uncompressedSize: Int64(metaData.count),
                                     compressionMethod: .deflate, provider: { pos, len in metaData.subdata(in: Int(pos)..<Int(pos) + len) })
            }
            return ipa
        }

        // Apple DownloadDispatch returned stale bundleShortVersionString="4800" with historical bundleVersion="2.0.02".
        let historicalDispatchPlist = try HTTPClient.encodePlist([
            "itemId": 385907472,
            "softwareVersionBundleId": "com.olimsoft.oplayer.lite",
            "bundleShortVersionString": "4800",
            "bundleVersion": "2.0.02",
            "softwareVersionExternalIdentifier": 7752498
        ])
        let reconciledShort = VersionService.reconcileTicketVersion(shortVersion: "4800", buildVersion: "2.0.02")
        XCTAssertEqual(reconciledShort, "2.0.02")
        let dispatchApp = StoreApp(id: "385907472", name: "OPlayer Lite", bundleID: "com.olimsoft.oplayer.lite",
                                   version: reconciledShort, externalVersionID: "7752498", bundleVersion: "2.0.02")
        let historicalAsset = DownloadAsset(app: dispatchApp, url: URL(string: "https://example.com/oplayer.ipa")!,
                                            sinf: Data([1, 2, 3]), metadata: historicalDispatchPlist,
                                            externalVersionIDs: ["7752498", "857150582"], platform: "ios", account: "a@b.com")

        let validHistoricalIPA = try makeIPA(name: "oplayer-2002", bundleID: "com.olimsoft.oplayer.lite", short: "2.0.02", build: "2.0.02")
        let finished = try PackageService.finish(staging: validHistoricalIPA, id: UUID(), asset: historicalAsset)
        let savedURL = LocalResources.packages.appendingPathComponent(finished.0)
        defer { try? FileManager.default.removeItem(at: savedURL) }
        XCTAssertEqual(finished.1.version, "2.0.02")
        XCTAssertEqual(finished.1.externalVersionID, "7752498")

        // A wrong (live 4800/48000 or completely unrelated) IPA must STILL be strictly rejected for 7752498.
        let wrongLiveIPA = try makeIPA(name: "oplayer-4800", bundleID: "com.olimsoft.oplayer.lite", short: "4800", build: "48000")
        XCTAssertThrowsError(try PackageService.finish(staging: wrongLiveIPA, id: UUID(), asset: historicalAsset))

        let wrongVersionIPA = try makeIPA(name: "oplayer-100", bundleID: "com.olimsoft.oplayer.lite", short: "1.0.0", build: "100")
        XCTAssertThrowsError(try PackageService.finish(staging: wrongVersionIPA, id: UUID(), asset: historicalAsset))

        let wrongExtStagingIPA = try makeIPA(name: "oplayer-wrong-ext", bundleID: "com.olimsoft.oplayer.lite", short: "2.0.02", build: "2.0.02", extID: "999999")
        XCTAssertThrowsError(try PackageService.finish(staging: wrongExtStagingIPA, id: UUID(), asset: historicalAsset))

        // EplayerX: Store marketing "1.9.1" preserved alongside Info.plist "10.0.18" / build "4".
        let eplayerMeta = try HTTPClient.encodePlist([
            "itemId": 6747369377,
            "softwareVersionBundleId": "com.snowlee.eplayerx",
            "bundleShortVersionString": "10.0.18",
            "bundleVersion": "4",
            "softwareVersionExternalIdentifier": 889722446
        ])
        let eplayerAssetApp = StoreApp(id: "6747369377", name: "EplayerX", bundleID: "com.snowlee.eplayerx",
                                       version: "10.0.18", externalVersionID: "889722446",
                                       bundleVersion: "4", storeMarketingVersion: "1.9.1")
        let eplayerAsset = DownloadAsset(app: eplayerAssetApp, url: URL(string: "https://example.com/eplayer.ipa")!,
                                         sinf: Data([4, 5]), metadata: eplayerMeta,
                                         externalVersionIDs: ["889722446", "892622938"], platform: "ios", account: "a@b.com")
        let eplayerIPA = try makeIPA(name: "eplayer-1018", bundleID: "com.snowlee.eplayerx", short: "10.0.18", build: "4")
        let eplayerDone = try PackageService.finish(staging: eplayerIPA, id: UUID(), asset: eplayerAsset)
        defer { try? FileManager.default.removeItem(at: LocalResources.packages.appendingPathComponent(eplayerDone.0)) }
        var job = DownloadJob(app: eplayerAsset.app, asset: eplayerAsset, status: .completed)
        job.app = job.completing(with: eplayerDone.1)
        XCTAssertEqual(job.app.version, "10.0.18")
        XCTAssertEqual(job.app.bundleVersion, "4")
        XCTAssertEqual(job.app.storeMarketingVersion, "1.9.1")
        XCTAssertEqual(job.storeVersion, "1.9.1", "Update checks must compare App Store marketing version, not 10.0.18")
        XCTAssertEqual(job.conciseVersionLabel, "v1.9.1")
        XCTAssertEqual(job.resolvedBundleVersion, "4")
        XCTAssertEqual(job.resolvedExternalVersionID, "889722446")
        XCTAssertTrue(VersionOrder.isNewer("1.9.5", than: job.storeVersion))
    }

    func testDownloadJobConciseLabelAndTechnicalDetailsSeparation() {
        let withMarketing = DownloadJob(app: StoreApp(id: "385907472", name: "OPlayer Lite", version: "4800",
                                                      externalVersionID: "857150582", bundleVersion: "4800",
                                                      storeMarketingVersion: "4.8"),
                                        status: .completed)
        XCTAssertEqual(withMarketing.conciseVersionLabel, "v4.8")
        XCTAssertEqual(withMarketing.userFacingVersion, "4.8")
        XCTAssertEqual(withMarketing.resolvedBundleVersion, "4800")
        XCTAssertEqual(withMarketing.resolvedExternalVersionID, "857150582")

        let withoutMarketing = DownloadJob(app: StoreApp(id: "1", name: "Sample", version: "3.8"), status: .completed)
        XCTAssertEqual(withoutMarketing.conciseVersionLabel, "v3.8")

        let unknownVersion = DownloadJob(app: StoreApp(id: "2", name: "Unknown", version: AppVersion.unknown), status: .queued)
        XCTAssertEqual(unknownVersion.conciseVersionLabel, "")
    }

    @MainActor
    func testMatchingDownloadJobAndTargetKey() {
        let older = DownloadJob(
            app: StoreApp(id: "385907472", name: "OPlayer Lite", version: "3800",
                          externalVersionID: "849000001", storeMarketingVersion: "3.8"),
            status: .completed
        )
        let runningLatest = DownloadJob(
            app: StoreApp(id: "385907472", name: "OPlayer Lite", version: "4800",
                          externalVersionID: "857150582", storeMarketingVersion: "4.8"),
            status: .running
        )
        let store = ToolStore(downloadManager: DownloadManager(previewJobs: [runningLatest, older]))
        let searchListing = StoreApp(id: "385907472", name: "OPlayer Lite", version: "4.8")

        XCTAssertEqual(store.matchingDownloadJob(for: searchListing, platform: .iOS)?.id, runningLatest.id)
        XCTAssertEqual(store.matchingDownloadJob(for: searchListing, platform: .iOS, versionID: "849000001")?.id, older.id)
        XCTAssertNil(store.matchingDownloadJob(for: searchListing, platform: .iOS, versionID: "853114367"))
        XCTAssertNil(store.matchingDownloadJob(for: searchListing, platform: .macOS))
        XCTAssertEqual(
            ToolStore.DownloadTargetKey(appID: "385907472", platform: .iOS, versionID: " "),
            ToolStore.DownloadTargetKey(appID: "385907472", platform: .iOS, versionID: nil)
        )
    }

    func testToolSettingsDecodesShowAppScreenshotsWithDefaultTrue() throws {
        let defaults = ToolSettings()
        XCTAssertTrue(defaults.showAppScreenshots)

        let legacy = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"searchLimit":50}"#.utf8))
        XCTAssertTrue(legacy.showAppScreenshots)

        var disabled = ToolSettings()
        disabled.showAppScreenshots = false
        let roundTrip = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(disabled))
        XCTAssertFalse(roundTrip.showAppScreenshots)

        let backup = AppBackup(settings: disabled, favorites: [], watch: [:], keptVersions: [:], searchHistory: [])
        let restored = try AppBackup.decode(try backup.encoded())
        XCTAssertFalse(restored.settings.showAppScreenshots)
        XCTAssertTrue(restored.settings.showAppReviews)
    }

    func testToolSettingsDecodesShowAppReviewsWithDefaultTrue() throws {
        let defaults = ToolSettings()
        XCTAssertTrue(defaults.showAppReviews)

        let legacy = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"searchLimit":50,"showAppScreenshots":false}"#.utf8))
        XCTAssertFalse(legacy.showAppScreenshots)
        XCTAssertTrue(legacy.showAppReviews)

        var configured = ToolSettings()
        configured.showAppScreenshots = true
        configured.showAppReviews = false
        let roundTrip = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(configured))
        XCTAssertTrue(roundTrip.showAppScreenshots)
        XCTAssertFalse(roundTrip.showAppReviews)

        let backup = AppBackup(settings: configured, favorites: [], watch: [:], keptVersions: [:], searchHistory: [])
        let restored = try AppBackup.decode(try backup.encoded())
        XCTAssertTrue(restored.settings.showAppScreenshots)
        XCTAssertFalse(restored.settings.showAppReviews)
    }

    @MainActor
    func testProModeTabReconciliationPreservesAccountsIdentityAndStripsCredentialsRoute() {
        let store = ToolStore(downloadManager: DownloadManager(previewJobs: []))
        store.settings.proMode = false
        store.selectTab(.accounts)
        XCTAssertEqual(store.tabs.id, .accounts)
        XCTAssertEqual(store.tabs.selection, 3)

        store.accountNav.setRoutes([.settings(.root)])
        store.settings.proMode = true
        XCTAssertEqual(store.tabs.id, .accounts)
        XCTAssertEqual(store.tabs.selection, 4)
        XCTAssertEqual(store.accountNav.routes, [.settings(.root)])
        XCTAssertEqual(store.accountNav.path.count, 1)

        store.accountNav.push(.credentials)
        XCTAssertEqual(store.accountNav.path.count, 2)
        store.settings.proMode = false
        XCTAssertEqual(store.tabs.id, .accounts)
        XCTAssertEqual(store.tabs.selection, 3)
        XCTAssertEqual(store.accountNav.routes, [.settings(.root)])
        XCTAssertEqual(store.accountNav.path.count, 1)

        let tempSource = VersionSource(name: "TempSource", urlTemplate: "https://example.com/{id}", containerKey: "data", reverse: false)
        store.settings.versionSources.append(tempSource)
        store.accountNav.push(.versionSource(tempSource.id))
        XCTAssertEqual(store.accountNav.routes, [.settings(.root), .versionSource(tempSource.id)])
        store.settings.versionSources.removeAll { $0.id == tempSource.id }
        XCTAssertEqual(store.accountNav.routes, [.settings(.root)])

        store.settings.proMode = true
        store.selectTab(.packages)
        XCTAssertEqual(store.tabs.id, .packages)
        XCTAssertEqual(store.tabs.selection, 2)
        FairPlayPresentation.shared.navigate(.history)
        let revBefore = FairPlayPresentation.shared.navigationRevision
        FairPlayPresentation.shared.clearPath()
        XCTAssertTrue(FairPlayPresentation.shared.path.isEmpty)
        XCTAssertEqual(FairPlayPresentation.shared.navigationRevision, revBefore,
                       "Clearing path on Pro Mode exit must not bump navigationRevision and trigger an onChange loop")
        store.settings.proMode = false
        XCTAssertEqual(store.tabs.id, .downloads)
        XCTAssertEqual(store.tabs.selection, 1)
    }

    @MainActor
    func testExternalDownloadURLSchemeRequiresConfirmationAndBlocksLoopback() {
        let manager = DownloadManager(previewJobs: [])
        let store = ToolStore(downloadManager: manager)

        store.handleURL(URL(string: "ipadn://download?url=https%3A%2F%2F127.0.0.1%3A9999%2Ftest.ipa")!)
        XCTAssertNil(store.externalDownloadPrompt)
        XCTAssertTrue(manager.jobs.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        store.errorMessage = nil

        store.handleURL(URL(string: "ipadn://download?url=https%3A%2F%2Flocalhost%2Ftest.ipa")!)
        XCTAssertNil(store.externalDownloadPrompt)
        XCTAssertTrue(manager.jobs.isEmpty)
        store.errorMessage = nil

        store.handleURL(URL(string: "ipadn://download?url=https%3A%2F%2Freleases.example.com%2FDemoApp.ipa")!)
        XCTAssertNotNil(store.externalDownloadPrompt)
        XCTAssertTrue(manager.jobs.isEmpty, "External scheme must wait for user confirmation before enqueuing")

        if let prompt = store.externalDownloadPrompt {
            store.confirmExternalDownload(prompt)
        }
        XCTAssertNil(store.externalDownloadPrompt)
        XCTAssertEqual(manager.jobs.count, 1)
        XCTAssertNil(manager.jobs.first?.asset)
        XCTAssertEqual(manager.jobs.first?.sourceURL?.absoluteString, "https://releases.example.com/DemoApp.ipa")
    }

    func testZipContainmentBlocksMultiSlashTraversalAndSinfReplicationBlocksEscape() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zip-contain-" + UUID().uuidString, isDirectory: true)
        let appDir = root.appendingPathComponent("Payload/Demo.app", isDirectory: true)
        let outsideSecret = root.appendingPathComponent("outside-secret.txt")
        try fm.createDirectory(at: appDir.appendingPathComponent("SC_Info", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("TOP-SECRET".utf8).write(to: outsideSecret)

        XCTAssertFalse(FairPlayDecryptor.isSafeZipEntryPath("//../outside-secret.txt"))
        XCTAssertFalse(FairPlayDecryptor.isSafeZipEntryPath("/../outside-secret.txt"))
        XCTAssertFalse(FairPlayDecryptor.isSafeZipEntryPath("Payload/../../outside-secret.txt"))
        XCTAssertTrue(FairPlayDecryptor.isSafeZipEntryPath("Payload/Demo.app/SC_Info/Demo.sinf"))
        XCTAssertTrue(FairPlayDecryptor.isSafeZipEntryPath("Payload/Demo.app/"))
        XCTAssertFalse(FairPlayDecryptor.isSafeRelativeSymlinkTarget("../../outside", fromEntryPath: "Payload/link"))
        XCTAssertTrue(FairPlayDecryptor.isSafeRelativeSymlinkTarget("Versions/A/Foo", fromEntryPath: "Payload/Demo.app/Frameworks/Foo.framework/Foo"))

        // Crafted Manifest.plist attempting to exfiltrate outside-secret.txt or write outside appDir.
        let evilManifest: [String: Any] = [
            "SinfPaths": ["../../outside-secret.txt"],
            "SinfReplicationPaths": ["SC_Info/stolen.sinf"]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: evilManifest, format: .xml, options: 0)
        try plistData.write(to: appDir.appendingPathComponent("SC_Info/Manifest.plist"))
        let copied = FairPlayDecryptor.replicateSinf(appDir: appDir, machos: [])
        XCTAssertEqual(copied, 0)
        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("SC_Info/stolen.sinf").path))
    }

    func testDecryptFailureMapperRecognizesEACCESAndPreservesRedactedAdvice() {
        let error = FairPlayDecryptor.Failure.notDecryptable("1 个文件失败")
        let logLines = ["  slice[0] [--] READ/cryptid2 mremap=-1(Permission denied) mmap=ok pages=0/4"]
        let mapped = DecryptFailureMapper.map(error: error, logLines: logLines)
        XCTAssertEqual(mapped.kind, .fairplayDenied)
        XCTAssertEqual(mapped.errno, EACCES)
        let sanitizedReason = DiagnosticRedactor.sanitize(mapped.reason)
        let sanitizedAdvice = DiagnosticRedactor.sanitize(mapped.advice)
        XCTAssertFalse(sanitizedReason.contains(DiagnosticRedactor.replacement))
        XCTAssertFalse(sanitizedAdvice.contains(DiagnosticRedactor.replacement))
        XCTAssertTrue(sanitizedAdvice.contains("App Store"))
    }

    func testDeduplicationForRegionsSourcesScreenshotsExtensionsAndLiveDelistedFlag() throws {
        let rawJSON = #"""
        {
          "priceRegions": ["us", "JP", "US", "hk", "JP"],
          "baseCurrency": " usd "
        }
        """#
        let decoded = try JSONDecoder().decode(ToolSettings.self, from: Data(rawJSON.utf8))
        XCTAssertEqual(decoded.priceRegions, ["US", "JP", "HK"])
        XCTAssertEqual(decoded.baseCurrency, "USD")

        let row: [String: Any] = [
            "kind": "software",
            "artistId": 12345,
            "artistName": "Demo Corp",
            "screenshotUrls": [
                "https://is1-ssl.mzstatic.com/image/thumb/Screen1/392x696bb.png",
                "https://is1-ssl.mzstatic.com/image/thumb/Screen1/392x696bb.png",
                "https://is1-ssl.mzstatic.com/image/thumb/Screen2/392x696bb.png"
            ]
        ]
        let extras = StoreService.listingExtras(row, platform: .iOS)
        XCTAssertEqual(extras.screenshots.count, 2)

        let extA = PackageInfo.Extension(name: "Blocker", point: "com.apple.Safari.content-blocker", path: "PlugIns/Block1.appex")
        let extB = PackageInfo.Extension(name: "Blocker", point: "com.apple.Safari.content-blocker", path: "PlugIns/Block2.appex")
        XCTAssertNotEqual(extA.id, extB.id)

        var live = StoreApp(id: "414478124", name: "WeChat", bundleID: "com.tencent.xin")
        live.delisted = false
        var staleCached = StoreApp(id: "414478124", name: "WeChat", bundleID: "com.tencent.xin")
        staleCached.delisted = true
        let merged = AppSearchRanking.deduplicatePreservingOrder([live, staleCached])
        XCTAssertEqual(merged.first?.delisted, false, "Explicitly live storefront listing must not be marked delisted by stale cache")
    }

    func testSearchDeduplicatesDuplicateTrackIDsAndBundleIDsAcrossRemoteAndLocal() {
        let iconURL = URL(string: "https://example.com/icon.png")!
        let rawSingleRegion = [
            StoreApp(id: "", name: "Invalid Empty ID"),
            StoreApp(id: "414478124", name: "WeChat", bundleID: "com.tencent.xin", version: ""),
            StoreApp(id: "414478124", name: "WeChat Duplicate", bundleID: "com.tencent.xin", version: "8.0.50", iconURL: iconURL, size: 250_000_000),
            StoreApp(id: "389801252", name: "Instagram", bundleID: "com.burbn.instagram", version: "350.0")
        ]
        let dedupedSingle = StoreService.deduplicatingResults(rawSingleRegion, limit: 30)
        XCTAssertEqual(dedupedSingle.map(\.id), ["414478124", "389801252"])
        XCTAssertEqual(dedupedSingle.first?.iconURL, iconURL)
        XCTAssertEqual(dedupedSingle.first?.version, "8.0.50")
        XCTAssertEqual(dedupedSingle.first?.size, 250_000_000)

        var delistedDupA = StoreApp(id: "6503940939", name: "Forward", bundleID: "com.example.forward", price: "")
        delistedDupA.delisted = true
        let delistedDupB = StoreApp(id: "6503940939", name: "Forward", bundleID: "com.example.forward", iconURL: iconURL, price: "")
        let localSameBundleImported = StoreApp(id: "999999999", name: "WeChat Local Copy", bundleID: "COM.TENCENT.XIN", price: "")
        let localUnique = StoreApp(id: "777777777", name: "WeChat Work", bundleID: "com.tencent.ww", price: "")

        for prioritize in [true, false] {
            let arranged = AppSearchRanking.arrange(
                remote: rawSingleRegion,
                local: [delistedDupA, delistedDupB, localSameBundleImported, localUnique, localUnique],
                query: "WeChat",
                prioritizeDelisted: prioritize
            )
            XCTAssertEqual(arranged.results.count, Set(arranged.results.map(\.id)).count)
            XCTAssertEqual(arranged.localResults.count, Set(arranged.localResults.map(\.id)).count)
            let overlap = Set(arranged.results.map(\.id)).intersection(Set(arranged.localResults.map(\.id)))
            XCTAssertTrue(overlap.isEmpty)
            XCTAssertFalse((arranged.results + arranged.localResults).contains { $0.id == "999999999" })
        }
    }

    func testCommercePurchaseHistoryParsesAppsAndMergesWithDMAP() throws {
        let payload = """
        {
          "data": {
            "attributes": {
              "is-complete": false,
              "purchases": [
                {
                  "order-id": "ORD-100",
                  "invoice-date": "Nov 19, 2026",
                  "items": [
                    { "item-id": "564177498", "item-name": "VKontakte", "kind": "iOS App", "purchase-date": "Nov 19, 2026" },
                    { "item-id": "398465290", "item-title": "Odnoklassniki", "kind": "iOS App" },
                    { "item-id": "999999991", "item-name": "Coins Pack", "kind": "In-App Purchase", "purchase-date": "Nov 19, 2026" },
                    { "item-id": "999999992", "item-name": "Novel", "kind": "Book", "purchase-date": "Nov 19, 2026" }
                  ]
                },
                {
                  "order-id": "ORD-101",
                  "invoice-date": "18 Oct 2024",
                  "items": [
                    { "item-id": 1166343427, "item-name": "RUTUBE", "kind": "iOS App", "purchase-date": "18 Oct 2024" },
                    { "item-id": "414478124", "item-name": "WeChat Commerce", "kind": "Mac App", "purchase-date": "2024-10-18" }
                  ]
                }
              ]
            }
          }
        }
        """
        var seen = Set<String>()
        let first = try CommercePurchaseHistory.parsePage(Data(payload.utf8), seenOrderIDs: &seen)
        XCTAssertFalse(first.isComplete)
        XCTAssertEqual(first.newInvoiceCount, 2)
        XCTAssertEqual(first.apps.map(\.id), ["564177498", "398465290", "1166343427", "414478124"])
        XCTAssertEqual(first.apps.first { $0.id == "398465290" }?.name, "Odnoklassniki")
        XCTAssertNotNil(first.apps.first { $0.id == "564177498" }?.purchaseDate)
        XCTAssertNotNil(first.apps.first { $0.id == "1166343427" }?.purchaseDate)

        // Replayed page with the same order IDs must contribute zero new invoices.
        let replay = try CommercePurchaseHistory.parsePage(Data(payload.utf8), seenOrderIDs: &seen)
        XCTAssertEqual(replay.newInvoiceCount, 0)
        XCTAssertTrue(replay.apps.isEmpty)

        let iconURL = URL(string: "https://example.com/wechat.png")!
        let dmapWeChat = OwnedApp(
            id: "414478124",
            bundleID: "com.tencent.xin",
            name: "WeChat",
            version: "8.0.50",
            purchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            iconURL: nil
        )
        let cachedWeChat = OwnedApp(
            id: "414478124",
            bundleID: "",
            name: "WeChat",
            version: "",
            purchaseDate: nil,
            iconURL: iconURL
        )
        let merged = CommercePurchaseHistory.merge(dmap: [dmapWeChat], commerce: first.apps, cached: [cachedWeChat])
        XCTAssertEqual(merged.count, 4, "Sanctioned/delisted commerce apps must survive merge alongside DMAP records")
        let wechat = try XCTUnwrap(merged.first { $0.id == "414478124" })
        XCTAssertEqual(wechat.bundleID, "com.tencent.xin")
        XCTAssertEqual(wechat.version, "8.0.50")
        XCTAssertEqual(wechat.iconURL, iconURL)
        XCTAssertTrue(merged.contains { $0.id == "564177498" && $0.name == "VKontakte" })
        XCTAssertTrue(merged.contains { $0.id == "1166343427" && $0.name == "RUTUBE" })

        XCTAssertEqual(CommercePurchaseHistory.pod(fromCookie: "foo=1; itspod=52; bar=2"), "52")
        XCTAssertEqual(CommercePurchaseHistory.pod(fromHost: "p52-buy.itunes.apple.com"), "52")
        XCTAssertNil(CommercePurchaseHistory.pod(fromHost: "buy.itunes.apple.com"))
        XCTAssertNotNil(CommercePurchaseHistory.parseDate("2026年11月19日"))
        XCTAssertNotNil(CommercePurchaseHistory.parseDate("Nov. 19, 2026"))
        XCTAssertNotNil(CommercePurchaseHistory.parseDate("2026-11-19 04:12:33 Etc/GMT"))
        XCTAssertNotNil(CommercePurchaseHistory.parseDate("19 нояб. 2026 г."))
    }

    #if canImport(TestFlightKit)
    func testMultiPhoneVerificationClassifierIgnoresIPhoneIdentityError() {
        XCTAssertFalse(TFHomeModel.isMultiPhoneVerificationError("返回内容无法解析：no usable iphone identity"))
        XCTAssertFalse(TFHomeModel.isMultiPhoneVerificationError("no usable iphone identity"))
        XCTAssertTrue(TFHomeModel.isMultiPhoneVerificationError("Multiple trusted phone numbers require SMS selection"))
        XCTAssertTrue(TFHomeModel.isMultiPhoneVerificationError("select a trusted number for verification"))
        XCTAssertTrue(TFHomeModel.isMultiPhoneVerificationError("missing phoneId in challenge"))
    }

    func testTFRedactionScrubsSecretsAndEmails() {
        let raw = "dpInfo=ABCDEFGHIJKLMNOP12345678 sinf=PD94bWwgdmVyc2lvbj0iMS4wIj8+ X-Apple-AMD-M=secretAmdmToken https://cdn.apple.com/a.ipa?accessKey=12345_secret&sig=abc /accounts/12345678/apps user.test@example.com"
        let cleaned = TFRedaction.clean(raw)
        XCTAssertFalse(cleaned.contains("ABCDEFGHIJKLMNOP12345678"))
        XCTAssertFalse(cleaned.contains("PD94bWwgdmVyc2lvbj0iMS4wIj8+"))
        XCTAssertFalse(cleaned.contains("secretAmdmToken"))
        XCTAssertFalse(cleaned.contains("12345_secret"))
        XCTAssertFalse(cleaned.contains("12345678"))
        XCTAssertFalse(cleaned.contains("user.test@example.com"))
    }
    #endif

    func testLoopbackHostBlocksPrivateAndAliasHosts() {
        for blocked in [
            "localhost", "sub.localhost", "127.0.0.1", "10.7.0.1", "192.168.1.5",
            "172.16.0.1", "169.254.169.254", "::1", "[0:0::1]", "[::ffff:7f00:1]",
            "ipadn.localtest.me", "foo.lvh.me", "127.0.0.1.sslip.io", "ipadn.local", "2130706433"
        ] {
            XCTAssertTrue(DownloadManager.isLoopbackHost(blocked), "Expected blocked host: \(blocked)")
        }
        for allowed in ["apps.apple.com", "github.com", "objects.githubusercontent.com", "1.1.1.1"] {
            XCTAssertFalse(DownloadManager.isLoopbackHost(allowed), "Expected allowed host: \(allowed)")
        }
    }

    func testAccountSessionEntryRejectsPathTraversalDSID() {
        let malicious = Data(#"{"id":"user@example.com","dsid":"../evil"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AccountSessionEntry.self, from: malicious))
        let valid = Data(#"{"id":"user@example.com","dsid":"19318358872"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AccountSessionEntry.self, from: valid).dsid, "19318358872")
    }

    func testPackageInfoParsesSDKAndXcodeVersions() {
        XCTAssertEqual(PackageInfoService.formatDTXcode("1620"), "16.2")
        XCTAssertEqual(PackageInfoService.formatDTXcode("1601"), "16.0.1")
        XCTAssertEqual(PackageInfoService.formatDTXcode("2600"), "26.0")
        XCTAssertEqual(PackageInfoService.formatDTXcode("0941"), "9.4.1")
        XCTAssertEqual(PackageInfoService.extractSDKVersion(from: "iphoneos18.2", platformVersion: ""), "18.2")
        XCTAssertEqual(PackageInfoService.extractSDKVersion(from: "iphoneos26.0", platformVersion: "26.0"), "26.0")

        let info = PackageInfoService.describe([
            "CFBundleDisplayName": "Demo",
            "CFBundleIdentifier": "com.example.demo",
            "DTSDKName": "iphoneos18.2",
            "DTPlatformVersion": "18.2",
            "DTSDKBuild": "22C146",
            "DTXcode": "1620",
            "DTXcodeBuild": "16C5032a",
        ])
        XCTAssertEqual(info.formattedSDK, "iOS 18.2 (22C146)")
        XCTAssertEqual(info.formattedXcode, "Xcode 16.2 (16C5032a)")

        // Synthetic 64-bit Mach-O header with LC_BUILD_VERSION (platform=2 iOS, minos=16.0, sdk=26.0)
        var macho = Data(repeating: 0, count: 64)
        func put32(_ offset: Int, _ val: UInt32) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { macho.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        put32(0, 0xFEEDFACF) // MH_MAGIC_64
        put32(16, 1)         // ncmds
        put32(20, 24)        // sizeofcmds
        put32(32, 0x32)      // LC_BUILD_VERSION
        put32(36, 24)        // cmdsize
        put32(40, 2)         // PLATFORM_IOS
        put32(44, 0x00100000) // minos 16.0.0
        put32(48, 0x001A0100) // sdk 26.1.0
        XCTAssertEqual(PackageInfoService.parseMachOSDKVersion(from: macho), "26.1")
    }

    func testAppleSessionExpiryStorefrontCorrectionTermsAndDiagnostics() throws {
        // 1008 (device verification failed) treated as session expiry alongside 2034/2042.
        XCTAssertTrue(AppleService.isSessionExpiredFailure("1008"))
        XCTAssertTrue(AppleService.isSessionExpiredFailure("2034"))
        XCTAssertTrue(AppleService.isSessionExpiredFailure("2042"))
        XCTAssertFalse(AppleService.isSessionExpiredFailure("9610"))
        XCTAssertFalse(AppleService.isSessionExpiredFailure("-128"))

        // Password changed triggers explicit reauthentication regardless of failureType.
        XCTAssertTrue(AppleAuthError.requiresReauthentication([
            "failureType": "5000", "customerMessage": "Your password has changed."
        ]))

        // Friendly mapping + unmapped numeric code exposure without leaking server text.
        let prevLocale = AppText.locale
        defer { AppText.locale = prevLocale }
        AppText.locale = Locale(identifier: "zh-Hans")

        let disabled = try XCTUnwrap(HTTPClient.appleFailure([
            "failureType": "5000", "customerMessage": "Your account is disabled."
        ])?.localizedDescription)
        XCTAssertTrue(disabled.contains("停用"))
        XCTAssertFalse(disabled.contains("Your account"))

        let expired1008 = try XCTUnwrap(HTTPClient.appleFailure([
            "failureType": "1008"
        ])?.localizedDescription)
        XCTAssertTrue(expired1008.contains("过期"))
        XCTAssertFalse(expired1008.contains("1008"))

        let unmappedNumeric = try XCTUnwrap(HTTPClient.appleFailure([
            "failureType": "-128", "customerMessage": "Account Not In This Store"
        ])?.localizedDescription)
        XCTAssertTrue(unmappedNumeric.contains("-128"))
        XCTAssertFalse(unmappedNumeric.contains("Account Not In This Store"))

        let unmappedText = try XCTUnwrap(HTTPClient.appleFailure([
            "failureType": "secret_internal_reason"
        ])?.localizedDescription)
        XCTAssertFalse(unmappedText.contains("secret_internal_reason"))

        // MZCommerce.CountryMismatch (-128) storefront recovery.
        let mismatch: [String: Any] = [
            "failureType": "-128",
            "metrics": ["dialogId": "MZCommerce.CountryMismatch"],
            "dialog": [
                "okButtonAction": [
                    "kind": "Goto",
                    "url": "https://itunes.apple.com/WebObjects/MZStore.woa/wa/resetAndRedirect?dsf=143462"
                ]
            ]
        ]
        let corrected = try XCTUnwrap(AppleService.purchaseStorefrontCorrection(
            mismatch, currentFullStoreFront: "143441-1,34", currentStoreFront: "143441"
        ))
        XCTAssertEqual(corrected.storeFront, "143462")
        XCTAssertEqual(corrected.fullStoreFront, "143462-1,34")

        // Same storefront is a no-op; untrusted host or wrong dialogId is rejected.
        XCTAssertNil(AppleService.purchaseStorefrontCorrection(
            mismatch, currentFullStoreFront: "143462-1,34", currentStoreFront: "143462"
        ))
        var evilMismatch = mismatch
        evilMismatch["dialog"] = ["okButtonAction": [
            "kind": "Goto",
            "url": "https://evil.example.com/WebObjects/MZStore.woa/wa/resetAndRedirect?dsf=143462"
        ]]
        XCTAssertNil(AppleService.purchaseStorefrontCorrection(
            evilMismatch, currentFullStoreFront: "143441-1,34", currentStoreFront: "143441"
        ))

        // App Store terms acceptance detection.
        let termsResponse: [String: Any] = [
            "jingleDocType": "buyProductFailure",
            "action": [
                "kind": "Goto",
                "url": "https://p45-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/com.apple.jingle.app.finance.DirectAction/termsPage"
            ]
        ]
        XCTAssertTrue(AppleService.isPurchaseTermsAction(termsResponse))
        XCTAssertFalse(AppleService.isPurchaseTermsAction([
            "jingleDocType": "buyProductFailure",
            "action": ["kind": "Goto", "url": "https://evil-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/com.apple.jingle.app.finance.DirectAction/termsPage"]
        ]))

        // RequestFailureLog records HTTP 200 Apple failures cleanly without DiagnosticRedactor collision.
        let buyURL = URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!
        RequestFailureLog.recordAppleFailure(buyURL, response: mismatch, stage: "buy")
        let lastLine = RequestFailureLog.text.components(separatedBy: .newlines).last ?? ""
        let sanitized = DiagnosticRedactor.sanitize(lastLine)
        XCTAssertTrue(sanitized.contains("stage=buy"))
        XCTAssertTrue(sanitized.contains("endpoint=buyProduct"))
        XCTAssertTrue(sanitized.contains("code=-128"))
        XCTAssertTrue(sanitized.contains("dialog=MZCommerce.CountryMismatch"))
        XCTAssertFalse(sanitized.contains("[REDACTED]"))
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; storage += 1; return storage }
}

private final class LockedList<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    var values: [Element] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ element: Element) { lock.lock(); storage.append(element); lock.unlock() }
}

