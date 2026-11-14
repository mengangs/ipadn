import UIKit
import XCTest
@testable import iPadn

final class RevealDismissOverlayTests: XCTestCase {
    @MainActor
    func testMissingOwnerCannotLeaveWindowWideTouchShield() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let overlay = RevealDismissOverlay()
        overlay.rowFrame = { nil }
        overlay.install(on: host)
        XCTAssertTrue(overlay.isInstalled)
        XCTAssertFalse(overlay.shouldReceivePoint(CGPoint(x: 20, y: 20)))
        XCTAssertFalse(overlay.isInstalled)
    }

    @MainActor
    func testInvalidatedRowReleasesEvenWhenItStillHasAnOldFrame() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let overlay = RevealDismissOverlay()
        overlay.rowFrame = { CGRect(x: 0, y: 200, width: 390, height: 100) }
        overlay.isValid = { false }
        overlay.install(on: host)
        XCTAssertTrue(overlay.isInstalled)
        XCTAssertFalse(overlay.shouldReceivePoint(CGPoint(x: 20, y: 20)))
        XCTAssertFalse(overlay.isInstalled)
    }

    @MainActor
    func testActiveRowPassesThroughWhileOutsideTapIsIntercepted() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let overlay = RevealDismissOverlay()
        overlay.rowFrame = { CGRect(x: 0, y: 200, width: 390, height: 100) }
        overlay.install(on: host)
        XCTAssertFalse(overlay.shouldReceivePoint(CGPoint(x: 20, y: 250)))
        XCTAssertTrue(overlay.shouldReceivePoint(CGPoint(x: 20, y: 20)))
        RevealDismissOverlay.dismissCurrent()
        XCTAssertFalse(overlay.isInstalled)
    }

    @MainActor
    func testNewOverlayCannotLeaveOldShieldAboveTheWindow() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let old = RevealDismissOverlay()
        old.install(on: host)
        let current = RevealDismissOverlay()
        current.install(on: host)
        XCTAssertFalse(old.isInstalled)
        XCTAssertTrue(current.isInstalled)
        RevealDismissOverlay.dismissCurrent()
        XCTAssertFalse(current.isInstalled)
    }

    @MainActor
    func testOutsideDragExceedingTapSlopFailsDismissRecognizer() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let overlay = RevealDismissOverlay()
        var tapped = false
        overlay.onTap = { tapped = true }
        overlay.install(on: host)

        overlay.recognizer.beginTracking(at: CGPoint(x: 100, y: 300))
        overlay.recognizer.updateTracking(at: CGPoint(x: 100, y: 315))
        XCTAssertEqual(overlay.recognizer.lastResolvedState, .failed)
        XCTAssertEqual(overlay.recognizer.finishTracking(at: CGPoint(x: 100, y: 300)), .failed)
        XCTAssertFalse(tapped)

        overlay.recognizer.reset()
        overlay.recognizer.beginTracking(at: CGPoint(x: 100, y: 300))
        overlay.recognizer.finishTracking(at: CGPoint(x: 103, y: 304))
        XCTAssertEqual(overlay.recognizer.lastResolvedState, .ended)
    }

    @MainActor
    func testOutsideDismissAllowsPanAndCrossRowRevealWhileBlockingChildTap() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let child = UIView(frame: CGRect(x: 0, y: 400, width: 390, height: 80))
        host.addSubview(child)

        let overlay = RevealDismissOverlay()
        overlay.install(on: host)

        let scrollPan = UIPanGestureRecognizer()
        child.addGestureRecognizer(scrollPan)
        let otherRowReveal = ItemListRevealTouchGestureRecognizer()
        child.addGestureRecognizer(otherRowReveal)
        let childTap = UITapGestureRecognizer()
        child.addGestureRecognizer(childTap)
        let hostTap = UITapGestureRecognizer()
        host.addGestureRecognizer(hostTap)

        XCTAssertTrue(overlay.gestureRecognizer(overlay.recognizer, shouldRecognizeSimultaneouslyWith: scrollPan))
        XCTAssertTrue(overlay.gestureRecognizer(overlay.recognizer, shouldRecognizeSimultaneouslyWith: otherRowReveal))
        XCTAssertFalse(overlay.gestureRecognizer(overlay.recognizer, shouldRecognizeSimultaneouslyWith: childTap))

        XCTAssertFalse(overlay.gestureRecognizer(overlay.recognizer, shouldBeRequiredToFailBy: scrollPan))
        XCTAssertFalse(overlay.gestureRecognizer(overlay.recognizer, shouldBeRequiredToFailBy: otherRowReveal))
        XCTAssertFalse(overlay.gestureRecognizer(overlay.recognizer, shouldBeRequiredToFailBy: hostTap))
        XCTAssertTrue(overlay.gestureRecognizer(overlay.recognizer, shouldBeRequiredToFailBy: childTap))
    }
}
