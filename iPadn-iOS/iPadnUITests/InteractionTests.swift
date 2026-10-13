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
        let size = app.staticTexts["download.size.preview-1"].firstMatch
        let badge = app.staticTexts["download.platform.IPA"].firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 10))
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(badge.frame.minX, size.frame.maxX)
        XCTAssertEqual(badge.frame.midY, size.frame.midY, accuracy: 12)
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
        let export = app.buttons["导出"].firstMatch
        if !install.waitForExistence(timeout: 10) { print(app.debugDescription) }
        XCTAssertTrue(install.exists)
        XCTAssertTrue(export.exists)
        XCTAssertEqual(install.frame.width, export.frame.width, accuracy: 2)
        XCTAssertEqual(install.frame.height, export.frame.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(install.frame.height, 44)
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
        app.buttons["accounts.settings"].tap()
        let flat = app.buttons["settings.icon.flat"]
        let dimensional = app.buttons["settings.icon.dimensional"]
        XCTAssertTrue(flat.waitForExistence(timeout: 10))
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
        if flat.isSelected {
            dimensional.tap()
            XCTAssertTrue(waitUntilSelected(dimensional, timeout: 40))
        }
        flat.tap()
        XCTAssertTrue(waitUntilSelected(flat, timeout: 40))
        attach("19-system-icon-switch", app: app)
        dimensional.tap()
        let restored = waitUntilSelected(dimensional, timeout: 40)
        if !restored {
            let status = app.staticTexts["settings.icon.status"]
            print("ICON-DIAG status=\(status.exists ? status.label : "none") enabled=\(dimensional.isEnabled)")
            attach("19b-icon-restore-stalled", app: app)
        }
        XCTAssertTrue(restored)
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
        flat.tap()
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: flat)
        wait(for: [selected], timeout: 5)
        dimensional.tap()
        XCTAssertTrue(dimensional.isSelected)
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
        row.swipeLeft()
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
        row.swipeLeft(); delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let notice = app.buttons["已删除任务"]
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
        XCTAssertTrue(history.waitForExistence(timeout: 10)); history.swipeLeft()
        XCTAssertTrue(app.buttons["删除"].firstMatch.waitForExistence(timeout: 5))
        attach("11-history-swipe", app: app)
        app.terminate()
        app.launchArguments = ["--visual-preview", "--accounts"]
        app.launch()
        let account = app.buttons["account.demo@example.com"]
        XCTAssertTrue(account.waitForExistence(timeout: 10)); account.swipeLeft()
        let remove = app.buttons["移除"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        attach("13-account-swipe", app: app)
        remove.tap()
        XCTAssertTrue(app.buttons["confirmation.cancel"].waitForExistence(timeout: 5))
        app.buttons["confirmation.cancel"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--visual-preview", "--downloads"]
        app.launch()
        let add = app.buttons["downloads.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        XCTAssertTrue(app.buttons["downloads.import"].waitForExistence(timeout: 5))
        app.buttons["downloads.import"].tap()
        let pickerCancel = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
            ["Cancel", "取消", "Close", "关闭"], ["Cancel", "Close"])).firstMatch
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 15))
        attach("15-import-picker", app: app)
        pickerCancel.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }
    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
