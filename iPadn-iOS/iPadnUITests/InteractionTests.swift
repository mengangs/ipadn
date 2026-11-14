import XCTest
import UIKit

final class InteractionTests: XCTestCase {
    /// The assertions here read Chinese copy, so the app runs in Chinese even
    /// when the simulator is set to another language. Each launch also replaces
    /// the feature flags, so a relaunch doesn't inherit an earlier `--accounts`.
    private static let languageArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    private static func launchableApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = languageArguments
        return app
    }

    /// Settings are grouped into pages; opens one from the first screen.
    private func openSettingsPage(_ name: String, in app: XCUIApplication) {
        let link = app.buttons["settings.page." + name]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
    }

    func testAppIDIsAlignedWithVersionInDetailHeader() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--detail"]
        app.launch()
        let copyID = app.buttons["app.copy-id"]
        let version = app.descendants(matching: .any)["app.version"].firstMatch
        XCTAssertTrue(copyID.waitForExistence(timeout: 10))
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(version.label.hasPrefix("v26.5"), version.label) // PreviewData.favorite
        XCTAssertGreaterThan(copyID.frame.minX, version.frame.maxX)
        XCTAssertEqual(copyID.frame.midY, version.frame.midY, accuracy: 12)
        copyID.tap()
        attach("21-app-id-inline", app: app)
    }

    func testVersionHistoryShowsAnIconOnEachRowWithoutOpeningDetails() throws {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--detail", "--version-icons-preview"]
        app.launch()
        let first = app.descendants(matching: .any)["detail.version.icon.123456789"].firstMatch
        let second = app.descendants(matching: .any)["detail.version.icon.123456788"].firstMatch
        for _ in 0..<4 { if second.exists && second.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        let image = app.screenshot()
        let a = try screenshotPixel(image, at: CGPoint(x: first.frame.midX, y: first.frame.minY + 8), appFrame: app.frame)
        let b = try screenshotPixel(image, at: CGPoint(x: second.frame.midX, y: second.frame.minY + 8), appFrame: app.frame)
        XCTAssertNotEqual(Array(a.prefix(3)), Array(b.prefix(3)), "Each row must render its own cached image")
        XCTAssertTrue(app.buttons["detail.versions.refresh"].exists)
        attach("history-version-icons-inline", app: app)
    }

    func testMissingHistoricalIconNeverUsesCurrentStoreArtwork() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--detail", "--version-icons-preview", "--version-icon-missing-preview"]
        app.launch()
        let missing = app.descendants(matching: .any)["detail.version.icon-missing.123456788"].firstMatch
        for _ in 0..<4 { if missing.exists && missing.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        XCTAssertEqual(missing.label, "未获取该版本图标")
        XCTAssertFalse(app.descendants(matching: .any)["detail.version.icon.123456788"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["detail.version.size.123456788"].exists)
        attach("history-version-icon-unavailable", app: app)
    }

    func testVersionHistoryDateRangeIncludesMatchesAndClearRestoresAllVersions() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--detail", "--version-dates-preview"]
        app.launch()
        let controls = app.buttons["按日期范围筛选"]
        for _ in 0..<4 { if controls.exists && controls.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        controls.tap()
        let search = app.buttons["detail.versions.date.search"]
        for _ in 0..<3 { if search.exists && search.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isEnabled)
        search.tap()
        let progress = app.staticTexts["detail.versions.date.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "已检查 3 / 3 个版本，找到 2 个")
        // The whole filter, its actions and the live result state stay one panel.
        attach("history-date-range-panel", app: app)
        // Collapse the controls to bring both result rows into one viewport.
        controls.tap()
        let included = app.staticTexts["detail.version.number.123456788"]
        for _ in 0..<3 { if included.exists && included.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(included.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["detail.version.number.123456787"].exists)
        attach("history-date-range-results", app: app)
        for _ in 0..<4 { if controls.isHittable { break }; app.swipeDown() }
        controls.tap()
        let clear = app.buttons["detail.versions.date.clear"]
        for _ in 0..<3 { if clear.exists && clear.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        controls.tap()
        let restored = app.staticTexts["detail.version.number.123456787"]
        for _ in 0..<4 { if restored.exists && restored.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertFalse(progress.exists)
    }

    func testVersionHistoryShowsEachPackagesOwnSize() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--detail"]
        app.launch()
        let newest = app.staticTexts["detail.version.size.123456789"]
        let older = app.staticTexts["detail.version.size.123456788"]
        // The screenshot strip may put the history below the first viewport.
        for _ in 0..<4 {
            if older.exists && older.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        XCTAssertTrue(older.waitForExistence(timeout: 5))
        XCTAssertTrue(newest.label.contains("128"), newest.label)
        XCTAssertTrue(older.label.contains("96"), older.label)
        XCTAssertNotEqual(newest.label, older.label, "Old versions must not reuse the latest listing's size")
        attach("version-history-package-sizes", app: app)
    }

    func testVersionHistoryNativeMenuCopiesTheSelectedVersionID() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--detail"]
        app.launch()
        let version = app.staticTexts["detail.version.number.123456788"]
        for _ in 0..<4 {
            if version.exists && version.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        version.press(forDuration: 0.8)
        let copyID = app.buttons["detail.version.copy-id.123456788"]
        let copyNumber = app.buttons["detail.version.copy-number.123456788"]
        XCTAssertTrue(copyID.waitForExistence(timeout: 5))
        XCTAssertTrue(copyNumber.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: copyID)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        version.press(forDuration: 0.8)
        XCTAssertTrue(copyID.waitForExistence(timeout: 5))
        copyID.tap()
        app.buttons["手动指定版本 ID"].tap()
        let field = app.textFields["内部版本 ID"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 0.8)
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "粘贴")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        XCTAssertEqual(field.value as? String, "123456788", "Copy the selected old version, not the latest one")
    }

    func testVersionHistorySeparatesFactsAtLargeTextSizes() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--detail", "--large-text"]
        app.launch()
        let size = app.staticTexts["detail.version.size.123456789"]
        for _ in 0..<4 {
            if size.exists && size.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(size.waitForExistence(timeout: 10))
        let date = app.staticTexts["detail.version.date.123456789"]
        let identifier = app.staticTexts["detail.version.id.123456789"]
        XCTAssertTrue(date.exists)
        XCTAssertTrue(identifier.exists)
        XCTAssertGreaterThanOrEqual(size.frame.minY, date.frame.maxY - 1)
        XCTAssertGreaterThanOrEqual(identifier.frame.minY, size.frame.maxY - 1)
        attach("version-history-large-text", app: app)
    }

    func testDownloadPlatformBadgeAlignsWithFileSize() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads"]
        app.launch()
        let size = app.descendants(matching: .any)["download.size.preview-1"].firstMatch
        let icon = app.descendants(matching: .any)["download.platform.IPA"].firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 10))
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        // The platform glyph leads the version and size line.
        XCTAssertLessThan(icon.frame.maxX, size.frame.minX)
        XCTAssertEqual(icon.frame.midY, size.frame.midY, accuracy: 12)
        attach("22-download-platform-inline", app: app)
    }

    func testDownloadEditModeAllowsSelectingAndDeletingTasks() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads"]
        app.launch()
        let edit = app.buttons["downloads.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()

        let deleteSelected = app.buttons["downloads.delete-selected"]
        XCTAssertTrue(deleteSelected.waitForExistence(timeout: 5))
        XCTAssertFalse(deleteSelected.isEnabled)
        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "download.select.")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        XCTAssertTrue(deleteSelected.isEnabled)
        XCTAssertTrue(app.staticTexts["已选 1 项"].exists)
        edit.tap()
        XCTAssertFalse(deleteSelected.exists)
    }

    func testCompletedActionsHaveEqualSizeAndOpenInstallationSettings() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads"]
        app.launch()
        app.buttons["download.filter.menu"].tap()
        app.buttons["download.filter.已完成"].tap()
        let install = app.buttons["安装"].firstMatch
        if !install.waitForExistence(timeout: 10) { print(app.debugDescription) }
        XCTAssertTrue(install.exists)
        // Share lives in the row's swipe actions now; the card keeps only 安装.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "download.export.")).firstMatch.exists)
        attach("17-completed-actions", app: app)
        install.tap()
        let settings = app.buttons["installation.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        let help = app.descendants(matching: .any)["installation.help"].firstMatch
        for _ in 0..<3 where !help.isHittable { app.swipeUp() }
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        for _ in 0..<3 where !app.buttons["本机证书"].isHittable { app.swipeDown() }
        // One-tap installation is the default; the device-certificate mode is advanced.
        let localMode = app.buttons["本机证书"]
        XCTAssertTrue(localMode.waitForExistence(timeout: 5)); localMode.tap()
        XCTAssertTrue(app.buttons["installation.certificate"].waitForExistence(timeout: 5))
        attach("18-installation-settings", app: app)
        let create = app.buttons["installation.create-certificate"]
        if !create.isHittable { app.swipeUp() }
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        XCTAssertTrue(app.buttons["installation.local-profile"].waitForExistence(timeout: 20))
        attach("20-local-certificate-created", app: app)
    }
    func testSystemActuallyChangesAlternateIconAndRestoresDefault() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--accounts", "--system-icon-test"]
        app.launch()
        let settings = app.buttons["accounts.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        openSettingsPage("appearance", in: app)
        let flat = app.buttons["settings.icon.flat"]
        let dimensional = app.buttons["settings.icon.dimensional"]
        if !flat.isHittable { app.swipeUp() }
        XCTAssertTrue(flat.waitForExistence(timeout: 15))
        if !flat.isHittable { app.swipeUp() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // iOS confirms each icon change with an alert, and the completion
        // handler only fires once it is dismissed. A throttled (EAGAIN)
        // request is retried by the app and raises its own alert later, so
        // keep dismissing alerts for the whole wait, as a user would.
        func waitUntilSelected(_ button: XCUIElement, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if button.value as? String == "已选中" && button.isEnabled { return true }
                if springboard.alerts.firstMatch.exists { springboard.alerts.firstMatch.buttons.firstMatch.tap() }
                else if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            return button.value as? String == "已选中"
        }
        #if !targetEnvironment(simulator)
        if flat.isSelected {
            dimensional.tap()
            XCTAssertTrue(waitUntilSelected(dimensional, timeout: 40))
        }
        #endif
        if !flat.isSelected { flat.tap() }
        XCTAssertTrue(waitUntilSelected(flat, timeout: 40))
        attach("19-system-icon-switch", app: app)
        // Switch back in a later session, as a person would after seeing the
        // new icon: SpringBoard refuses a second change while the first one's
        // confirmation is still on screen.
        app.terminate()
        app.launch()
        let settingsAgain = app.buttons["accounts.settings"]
        XCTAssertTrue(settingsAgain.waitForExistence(timeout: 15))
        settingsAgain.tap()
        openSettingsPage("appearance", in: app)
        if !dimensional.isHittable { app.swipeUp() }
        XCTAssertTrue(dimensional.waitForExistence(timeout: 15))
        if !dimensional.isHittable { app.swipeUp() }
        XCTAssertEqual(flat.value as? String, "已选中", "The system kept the alternate icon across launches")
        #if targetEnvironment(simulator)
        // The iOS 26 simulator never completes setAlternateIconName(nil); restoring
        // the primary icon is verified on a device (confirmed working there).
        #else
        dimensional.tap()
        // The app retries a throttled change for about a minute.
        let restored = waitUntilSelected(dimensional, timeout: 90)
        if !restored {
            let status = app.staticTexts["settings.icon.status"]
            print("ICON-DIAG status=\(status.exists ? status.label : "none") enabled=\(dimensional.isEnabled)")
            print("ICON-DIAG springboard=\(springboard.debugDescription.prefix(3000))")
            attach("19b-icon-restore-stalled", app: app)
        }
        XCTAssertTrue(restored)
        #endif
    }

    func testIconSelectionAndSearchSubmitControl() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--accounts"]
        app.launch()
        let settings = app.buttons["accounts.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        openSettingsPage("appearance", in: app)
        let dimensional = app.buttons["settings.icon.dimensional"]
        let flat = app.buttons["settings.icon.flat"]
        if !flat.isHittable { app.swipeUp() }
        XCTAssertTrue(flat.waitForExistence(timeout: 5))
        XCTAssertTrue(dimensional.isSelected)
        // The change is applied asynchronously; a row that did not take the tap gets a second one.
        func choose(_ button: XCUIElement) -> Bool {
            // The row's value is what VoiceOver reads; the waitUntilSelected check above uses it too.
            let selected = NSPredicate(format: "value == '已选中' AND isEnabled == true")
            for _ in 0..<2 {
                // The swipe that brought 扁平 into view can leave 立体 under the
                // navigation bar, where a tap lands on the bar instead (isHittable
                // still reports true there), so keep the row clear of both bars.
                let nav = app.navigationBars.firstMatch, tabs = app.tabBars.firstMatch
                let top = nav.exists ? nav.frame.maxY : 120
                let bottom = tabs.exists ? tabs.frame.minY : app.frame.maxY - 100
                for _ in 0..<3 where button.frame.minY < top || button.frame.maxY > bottom {
                    if button.frame.minY < top { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
                }
                button.tap()
                if XCTWaiter().wait(for: [expectation(for: selected, evaluatedWith: button)], timeout: 5) == .completed {
                    return true
                }
            }
            for row in [dimensional, flat] {
                print("ICON-DIAG \(row.identifier) value=\(row.value ?? "nil") selected=\(row.isSelected) enabled=\(row.isEnabled) hittable=\(row.isHittable) frame=\(row.frame)")
            }
            print("ICON-DIAG alerts=\(app.alerts.count) status=\(app.staticTexts["settings.icon.status"].exists)")
            return false
        }
        XCTAssertTrue(choose(flat))
        XCTAssertTrue(choose(dimensional))
        print("ICON-DIAG restored dimensional selected=\(dimensional.isSelected) flat selected=\(flat.isSelected)")
        attach("16-icon-settings", app: app)
        app.terminate()
        app.launchArguments = Self.languageArguments + ["--visual-preview"]
        app.launch()
        // App Store search bar: a capsule field that searches from the
        // keyboard; the clear control appears once something is typed.
        let input = app.textFields["应用名称、App ID 或链接"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["search.submit"].exists)
        XCTAssertFalse(app.buttons["清空输入"].exists)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<3 {
            input.tap()
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: input)], timeout: 2) == .completed {
                break
            }
        }
        input.typeText("Test")
        XCTAssertTrue(app.buttons["清空输入"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["切换或管理账号"].exists)
    }
    func testFiltersAndDeleteConfirmation() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads"]
        app.launch()
        let menu = app.buttons["download.filter.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        for title in ["全部", "进行中", "已暂停", "已完成", "失败"] {
            menu.tap()
            let button = app.buttons["download.filter." + title]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            button.tap()
        }
        menu.tap(); app.buttons["download.filter.全部"].tap()
        let row = app.descendants(matching: .any)["download.task.preview-2.paused"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        revealActions(on: row)
        let delete = app.buttons["删除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        attach("10-download-swipe", app: app)
        delete.tap()
        let cancel = app.buttons["confirmation.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let confirm = app.buttons["confirmation.confirm"]
        XCTAssertGreaterThan(confirm.frame.minY, app.frame.height * 0.5)
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        XCTAssertLessThanOrEqual(app.staticTexts["confirmation.message"].frame.maxY, confirm.frame.minY)
        attach("12-delete-confirmation", app: app)
        cancel.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        revealActions(on: row); delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let notice = app.staticTexts["已删除 1 项任务与文件"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertLessThan(notice.frame.midY, app.frame.midY, "操作提示应该位于上方，不遮挡底部操作")
        attach("14-task-toast", app: app)
        XCTAssertFalse(row.exists)
    }

    func testWrappedSearchChipsRetainTheirOwnRoundedEdges() throws {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--history-wrap-preview"]
        app.launch()
        let first = app.buttons["history.效率工具"]
        let lower = app.buttons["history.Apple Music"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(lower.waitForExistence(timeout: 5))
        let upperFrame = first.frame, lowerFrame = lower.frame
        XCTAssertGreaterThan(lowerFrame.minY, upperFrame.maxY, "The fixture must wrap to exercise both grouped-cell corners")
        let screenshot = app.screenshot()
        for (frame, fraction) in [(upperFrame, CGFloat(0.22)), (lowerFrame, CGFloat(0.78))] {
            // Just inside each capsule arc, but outside the old cell mask.
            // The neighboring transparent inset supplies the page color.
            let inside = try screenshotPixel(screenshot, at: CGPoint(x: frame.minX + 4, y: frame.minY + frame.height * fraction), appFrame: app.frame)
            let page = try screenshotPixel(screenshot, at: CGPoint(x: frame.minX - 4, y: frame.midY), appFrame: app.frame)
            let gain = zip(inside.prefix(3), page.prefix(3)).reduce(0) { $0 + Int($1.0) - Int($1.1) }
            XCTAssertGreaterThan(gain, 15, "Both left-hand capsule arcs must remain visible, not cut by the list cell")
        }
        attach("search-wrapped-capsule-edges", app: app)
    }

    func testInstalledAppWithoutStoreListingStillOpensLocalDetails() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--installed", "--installed-missing-preview"]
        app.launch()
        let row = app.buttons["installed.app.notion.id"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let bundleID = app.descendants(matching: .any)["installed.field.bundle-id"].firstMatch
        XCTAssertTrue(bundleID.waitForExistence(timeout: 5))
        XCTAssertEqual(bundleID.value as? String, "notion.id")
        let version = app.descendants(matching: .any)["installed.field.version"].firstMatch
        XCTAssertTrue(version.exists)
        XCTAssertEqual(version.value as? String, "1.7.353")
        XCTAssertTrue(app.staticTexts["当前地区未查到商店资料"].exists)
        XCTAssertTrue(app.staticTexts["未查到资料不代表应用已下架，也不影响查看本机信息。"].exists)
        XCTAssertTrue(app.buttons["installed.lookup.retry"].exists)
        attach("installed-missing-store-local-info", app: app)
    }

    func testInstalledAppStoreFailureCanRetryWithoutLosingLocalDetails() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--installed", "--installed-failed-preview"]
        app.launch()
        let row = app.buttons["installed.app.com.netflix.Netflix"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts["商店查询失败"].waitForExistence(timeout: 5))
        let bundleID = app.descendants(matching: .any)["installed.field.bundle-id"].firstMatch
        XCTAssertTrue(bundleID.exists)
        XCTAssertEqual(bundleID.value as? String, "com.netflix.Netflix")
        XCTAssertFalse(app.staticTexts["当前地区未查到商店资料"].exists)
        app.buttons["installed.lookup.retry"].tap()
        let details = app.buttons["installed.store-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertTrue(bundleID.exists, "Regrouping must not pop the local details page")
        XCTAssertEqual(bundleID.value as? String, "com.netflix.Netflix")
        details.tap()
        XCTAssertTrue(app.buttons["app.copy-id"].waitForExistence(timeout: 10))
        attach("installed-store-retry-restores-details", app: app)
    }

    func testInstalledAppWithoutStoreIDStillOpensLocalDetails() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--installed"]
        app.launch()
        let row = app.buttons["installed.app.com.example.tool"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            if row.isHittable { break }
            app.swipeUp()
        }
        row.tap()
        let bundleID = app.descendants(matching: .any)["installed.field.bundle-id"].firstMatch
        XCTAssertTrue(bundleID.waitForExistence(timeout: 5))
        XCTAssertEqual(bundleID.value as? String, "com.example.tool")
        XCTAssertTrue(app.staticTexts["installed.lookup.no-id"].exists)
        XCTAssertFalse(app.buttons["installed.lookup.retry"].exists)
        attach("installed-local-only-info", app: app)
    }

    func testInstalledAppsUsesNeutralRecognitionHeading() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--installed"]
        app.launch()
        let heading = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "App Store 未识别的应用")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "App Store 不认的应用")).firstMatch.exists)
        attach("installed-app-recognition-heading", app: app)
    }

    func testHistoryAndFavoriteActions() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview"]
        app.launch()
        // Recent searches are chips; a long press offers Delete.
        let history = app.buttons["history.效率工具"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["删除"].firstMatch.waitForExistence(timeout: 5))
        attach("11-history-menu", app: app)
        // Dismissing the menu leaves the chip and runs no search.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let closed = NSPredicate(format: "exists == false")
        expectation(for: closed, evaluatedWith: app.buttons["删除"].firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        let favorite = app.buttons["favorite.preview-app"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        revealActions(on: favorite)
        XCTAssertTrue(app.buttons["取消关注"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["app.copy-id"].exists, "Swiping a favorite must not navigate")
        favorite.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: closed, evaluatedWith: app.buttons["取消关注"].firstMatch)
        waitForExpectations(timeout: 5)
        favorite.tap()
        // The preview starts signed out, so the primary control is Login,
        // not detail.get. Copy ID is present in either authentication state.
        XCTAssertTrue(app.buttons["app.copy-id"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testAccountSwipeAndSourceSettings() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--accounts"]
        app.launch()
        let account = app.buttons["account.demo@example.com"]
        XCTAssertTrue(account.waitForExistence(timeout: 10)); revealActions(on: account)
        let remove = app.buttons["移除"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        attach("13-account-swipe", app: app)
        remove.tap()
        XCTAssertTrue(app.buttons["confirmation.cancel"].waitForExistence(timeout: 5))
        app.buttons["confirmation.cancel"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        app.buttons["accounts.settings"].tap()
        openSettingsPage("sources", in: app)
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.source.")).firstMatch
        for _ in 0..<8 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        XCTAssertTrue(app.textFields["来源名称"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testDownloadImportPickerCanBeCancelled() {
        // The Files UI starts in a separate process. Keep its cold-start
        // budget independent of the history and account/settings scenarios;
        // all assertions stay covered under the same 120-second test cap.
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads"]
        app.launch()
        let add = app.buttons["downloads.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        XCTAssertTrue(app.buttons["downloads.import"].waitForExistence(timeout: 5))
        app.buttons["downloads.import"].tap()
        let pickerCancel = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
            ["Cancel", "取消", "Close", "关闭"], ["Cancel", "Close"])).firstMatch
        // The Files picker runs in its own process and has taken over 11 s to appear on CI runners.
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 45))
        attach("15-import-picker", app: app)
        pickerCancel.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }
    func testHistoryDeletionCanBeUndone() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview"]
        app.launch()
        let history = app.buttons["history.效率工具"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["删除"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["删除"].firstMatch.tap()
        // Undo expires after five seconds. Snapshotting the whole history
        // before tapping can consume that window on a busy simulator.
        // tap() already resolves/waits for the button; restoration is checked
        // afterwards, without changing the app's real expiry duration.
        app.buttons["notice.undo"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
    }

    func testCompactNoticeAndAccessibleConfirmation() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--notice-preview"]
        app.launch()
        let notice = app.buttons["notice.banner"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(notice.frame.height, 44)
        XCTAssertLessThanOrEqual(notice.frame.height, 48)
        XCTAssertLessThanOrEqual(notice.frame.width, 320)
        attach("23-compact-notice", app: app)
        // The padded edge must dismiss too, beyond the text's ink bounds.
        notice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: notice)
        waitForExpectations(timeout: 5)
        app.terminate()

        // The largest supported Dynamic Type size must wrap and scroll,
        // while both destructive and cancel controls stay reachable.
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads", "--largest-text", "--dark"]
        app.launch()
        let edit = app.buttons["downloads.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "download.select.")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 5)); task.tap()
        app.buttons["downloads.delete-selected"].tap()
        let popup = app.scrollViews["confirmation.scroll"]
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(popup.frame.minX, 0)
        XCTAssertLessThanOrEqual(popup.frame.maxX, app.frame.maxX)
        XCTAssertEqual(app.staticTexts["confirmation.message"].label, "已下载的安装包也会一并删除。")
        let confirm = app.buttons["confirmation.confirm"], cancel = app.buttons["confirmation.cancel"]
        for _ in 0..<4 where !cancel.isHittable { popup.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        XCTAssertLessThanOrEqual(confirm.frame.maxY, cancel.frame.minY)
        attach("24-accessible-confirmation", app: app)
        cancel.tap()
        XCTAssertTrue(app.staticTexts["已选 1 项"].waitForExistence(timeout: 5), "Cancel must preserve the selected task")
    }

    // Keep every list size under its own unchanged per-test watchdog.
    func testDownloadList100RowsLaunchesAndScrolls() { checkDownloadList(count: 100) }
    func testDownloadList500RowsLaunchesAndScrolls() { checkDownloadList(count: 500) }
    func testDownloadList1000RowsLaunchesAndScrolls() { checkDownloadList(count: 1000) }

    private func checkDownloadList(count: Int) {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads", "--stress-records=\(count)"]
        let started = Date()
        app.launch()
        XCTAssertTrue(app.buttons["downloads.edit"].waitForExistence(timeout: 15))
        print("PERF downloads rows=\(count) launch-to-controls=\(Date().timeIntervalSince(started))s")
        let first = app.descendants(matching: .any)["download.task.stress-0.paused"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertFalse(first.isHittable, "The list must actually scroll, not just accept the gesture")
        app.swipeDown()
        XCTAssertTrue(app.buttons["downloads.edit"].exists)
        attach("stress-\(count)", app: app)
        app.terminate()
    }

    func testDownloadCompletionOffersInstallAndCompletedRowsDoNotReplay() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads", "--completion-preview"]
        app.launch()
        let pause = app.buttons["暂停"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap() // Preview-only: running -> processing -> completed; no real download.
        let install = app.buttons["download.install.preview-1"]
        XCTAssertTrue(install.waitForExistence(timeout: 8), "The completion check must give way to Install")
        XCTAssertFalse(pause.exists)
        XCTAssertTrue(app.descendants(matching: .any)["download.task.preview-1.completed"].firstMatch.exists)
        attach("completion-offers-install", app: app)
        app.terminate()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads"]
        app.launch()
        XCTAssertTrue(app.buttons["download.install.1232780281"].waitForExistence(timeout: 10), "Previously completed rows must offer Install without replaying the celebration")
    }

    func testTabReselectScrollsToTopWithoutResettingOnTabSwitch() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads", "--stress-records=100"]
        app.launch()
        let first = app.descendants(matching: .any)["download.task.stress-0.paused"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertFalse(first.isHittable)
        let tabs = app.tabBars.firstMatch
        tabs.buttons["搜索"].tap()
        tabs.buttons["下载"].tap()
        XCTAssertFalse(first.isHittable, "Returning to Downloads must retain its scroll position")
        tabs.buttons["下载"].tap()
        let backAtTop = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [backAtTop], timeout: 5), .completed, "Reselecting Downloads must scroll to the first task")
    }

    func testDownloadSwipeSurfaceScreenshotsInBothDirections() throws {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads"]
        app.launch()
        let row = app.descendants(matching: .any)["download.task.preview-2.paused"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // Just outside the resting cell, but INSIDE the translated card after
        // a right swipe. A native inset-grouped cell mask used to leave this
        // pixel as page background, truncating the moving surface early.
        let probe = CGPoint(x: app.frame.maxX - 3, y: row.frame.minY + 3)
        let resting = try screenshotPixel(app.screenshot(), at: probe, appFrame: app.frame)
        revealActions(on: row)
        let delete = app.buttons["删除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        attach("download-card-surface-left", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: delete)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        // Both edges are captured: the moving surface must keep its own
        // rounded corners, rather than being clipped to the resting row.
        attach("download-card-surface-right", app: app)
        let translated = try screenshotPixel(app.screenshot(), at: probe, appFrame: app.frame)
        let brightnessGain = zip(translated.prefix(3), resting.prefix(3)).reduce(0) { $0 + Int($1.0) - Int($1.1) }
        XCTAssertGreaterThan(brightnessGain, 20, "The white card must extend beyond the resting cell's right boundary")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let closedAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: delete)
        XCTAssertEqual(XCTWaiter.wait(for: [closedAgain], timeout: 5), .completed)
        let restored = try screenshotPixel(app.screenshot(), at: probe, appFrame: app.frame)
        for (before, after) in zip(resting, restored) {
            XCTAssertLessThanOrEqual(abs(Int(before) - Int(after)), 2, "Closing must restore the resting card and page margin")
        }
    }

    /// Normalize to RGBA, independent of simulator pixel format and scale.
    private func screenshotPixel(_ screenshot: XCUIScreenshot, at point: CGPoint, appFrame: CGRect) throws -> [UInt8] {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let sx = CGFloat(image.width) / appFrame.width, sy = CGFloat(image.height) / appFrame.height
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: ((point.x - appFrame.minX) * sx).rounded(.down),
                                                           y: ((point.y - appFrame.minY) * sy).rounded(.down), width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                 bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }

    func testNativeTaskMenuDismissesAndOpensDetails() {
        let app = Self.launchableApp()
        app.launchArguments = Self.languageArguments + ["--visual-preview", "--downloads", "--stress-records=100"]
        app.launch()
        let first = app.descendants(matching: .any)["download.task.stress-0.paused"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.7)
        let details = app.buttons["任务详情"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["任务详情"].exists, "Long press must not also tap the row")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: details)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        first.press(forDuration: 0.7)
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        XCTAssertTrue(app.navigationBars["任务详情"].waitForExistence(timeout: 5))
    }

    private func revealActions(on element: XCUIElement) {
        // A partial swipe deliberately tests the revealed button separately
        // from the full-swipe commit threshold.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
    }

    /// iPhone Duo: screenshots of the main screens on whichever display the
    /// simulator shows, with its size in the name. Runs only on that simulator.
    func testDuoLayoutScreens() throws {
        let device = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(device.localizedCaseInsensitiveContains("Duo"), "Only on the iPhone Duo simulator")
        let screens: [(name: String, arguments: [String])] = [
            ("search", []), ("downloads", ["--downloads"]), ("purchased", ["--purchased"]),
            ("accounts", ["--accounts"]), ("detail", ["--detail"]),
        ]
        for screen in screens {
            let app = Self.launchableApp()
            app.launchArguments = Self.languageArguments + ["--visual-preview"] + screen.arguments
            app.launch()
            _ = app.windows.firstMatch.waitForExistence(timeout: 10)
            sleep(2)
            let size = app.windows.firstMatch.frame.size
            attach("duo-\(screen.name)-\(Int(size.width))x\(Int(size.height))", app: app)
            app.terminate()
        }
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
