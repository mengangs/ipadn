import XCTest

final class InteractionTests: XCTestCase {
    func testCompletedActionsHaveEqualSizeAndOpenInstallationSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--downloads"]
        app.launch()
        app.buttons["download.filter.menu"].tap()
        app.buttons["download.filter.已完成"].tap()
        let install = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download.install.'")).firstMatch
        let export = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download.export.'")).firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        XCTAssertTrue(export.exists)
        XCTAssertEqual(install.frame.width, export.frame.width, accuracy: 2)
        XCTAssertEqual(install.frame.height, export.frame.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(install.frame.height, 44)
        attach("17-completed-actions", app: app)
        install.tap()
        let settings = app.buttons["installation.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        XCTAssertTrue(app.buttons["installation.certificate"].waitForExistence(timeout: 5))
        attach("18-installation-settings", app: app)
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
        func acknowledgeSystemAlert() {
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 3) { alert.buttons.firstMatch.tap() }
            else if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
        }
        if flat.isSelected {
            dimensional.tap(); acknowledgeSystemAlert()
            let initial = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: dimensional)
            wait(for: [initial], timeout: 12)
        }
        flat.tap(); acknowledgeSystemAlert()
        let switched = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: flat)
        wait(for: [switched], timeout: 12)
        attach("19-system-icon-switch", app: app)
        dimensional.tap(); acknowledgeSystemAlert()
        let restored = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: dimensional)
        wait(for: [restored], timeout: 12)
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
        let submit = app.buttons["search.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertFalse(submit.isEnabled)
        let input = app.textFields["应用名称、App ID 或链接"]
        input.tap(); input.typeText("Test")
        XCTAssertTrue(submit.isEnabled)
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
        XCTAssertTrue(app.buttons["已删除任务"].waitForExistence(timeout: 5))
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
        let pickerCancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
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
