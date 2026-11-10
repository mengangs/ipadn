import XCTest

final class InteractionTests: XCTestCase {
    func testAppIDIsAlignedWithVersionInDetailHeader() {
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--detail"]
        app.launch()
        let copyID = app.buttons["app.copy-id"]
        let version = app.descendants(matching: .any)["app.version"].firstMatch
        XCTAssertTrue(copyID.waitForExistence(timeout: 10))
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(version.label.hasPrefix("v3.2"), version.label)
        XCTAssertGreaterThan(copyID.frame.minX, version.frame.maxX)
        XCTAssertEqual(copyID.frame.midY, version.frame.midY, accuracy: 12)
        copyID.tap()
        attach("21-app-id-inline", app: app)
    }

    func testDownloadPlatformBadgeAlignsWithFileSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--downloads"]
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
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--downloads"]
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
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--downloads"]
        app.launch()
        app.buttons["download.filter.menu"].tap()
        app.buttons["download.filter.已完成"].tap()
        let install = app.buttons["安装"].firstMatch
        let share = app.buttons["分享"].firstMatch
        if !install.waitForExistence(timeout: 10) { print(app.debugDescription) }
        XCTAssertTrue(install.exists)
        XCTAssertTrue(share.exists)
        // Compact trailing actions on the task card: 安装 capsule, then share.
        XCTAssertEqual(install.frame.midY, share.frame.midY, accuracy: 4)
        XCTAssertLessThan(install.frame.maxX, share.frame.minX)
        XCTAssertGreaterThanOrEqual(share.frame.height, 44)
        attach("17-completed-actions", app: app)
        install.tap()
        let settings = app.buttons["installation.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
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
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--accounts", "--system-icon-test"]
        app.launch()
        let settings = app.buttons["accounts.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
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
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--accounts"]
        app.launch()
        let settings = app.buttons["accounts.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
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
        app.launchArguments = ["--visual-preview"]
        app.launch()
        // App Store search bar: a capsule field that searches from the
        // keyboard; the clear control appears once something is typed.
        let input = app.textFields["应用名称、App ID 或链接"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["search.submit"].exists)
        XCTAssertFalse(app.buttons["清空输入"].exists)
        input.tap(); input.typeText("Test")
        XCTAssertTrue(app.buttons["清空输入"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["切换或管理账号"].exists)
    }
    func testFiltersAndDeleteConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--downloads"]
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

    func testHistoryAccountSwipeAndImportPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview"]
        app.launch()
        let history = app.buttons["history.效率工具"]
        XCTAssertTrue(history.waitForExistence(timeout: 10)); revealActions(on: history)
        XCTAssertTrue(app.buttons["删除"].firstMatch.waitForExistence(timeout: 5))
        attach("11-history-swipe", app: app)
        // Tapping the displaced card closes its actions without submitting
        // the history query; the row must remain and the operation disappear.
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let closed = NSPredicate(format: "exists == false")
        expectation(for: closed, evaluatedWith: app.buttons["删除"].firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(history.exists)
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
        app.launchArguments = ["--visual-preview", "--accounts"]
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
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.source.")).firstMatch
        for _ in 0..<8 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        XCTAssertTrue(app.textFields["来源名称"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--visual-preview", "--downloads"]
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
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview"]
        app.launch()
        let history = app.buttons["history.效率工具"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        revealActions(on: history)
        app.buttons["删除"].firstMatch.tap()
        let undo = app.buttons["notice.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertFalse(history.exists)
        undo.tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
    }

    func testLargeDownloadListsLaunchAndScroll() {
        let app = XCUIApplication()
        for count in [100, 500, 1000] {
            app.launchArguments = ["--visual-preview", "--downloads", "--stress-records=\(count)"]
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
    }

    private func revealActions(on element: XCUIElement) {
        // A partial swipe deliberately tests the revealed button separately
        // from the full-swipe commit threshold.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
