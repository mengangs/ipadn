import XCTest

final class InteractionTests: XCTestCase {
    func testFiltersFitAndSwipeCardsStayPresentUntilConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--visual-preview", "--downloads"]
        app.launch()
        for title in ["全部", "进行中", "已暂停", "已完成", "失败"] {
            let button = app.buttons["download.filter." + title]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(button.isHittable, "All filters should fit without horizontal scrolling")
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
        }
        let row = app.cells.element(boundBy: 1)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        let delete = app.buttons["删除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        attach("10-download-swipe", app: app)
        XCTAssertTrue(row.exists)
        app.terminate()
        app.launchArguments = ["--visual-preview"]
        app.launch()
        let history = app.buttons["history.效率工具"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.swipeLeft()
        XCTAssertTrue(app.buttons["删除"].firstMatch.waitForExistence(timeout: 5))
        attach("11-history-swipe", app: app)
        XCTAssertTrue(history.exists)
    }
    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
