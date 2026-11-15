import Foundation
import XCTest
#if canImport(iPadn)
@testable import iPadn
#endif

final class RevealMotionTests: XCTestCase {
    /// Assertions below check the Chinese copy: pin the language instead of
    /// following whatever the simulator is set to. Set `locale:` on the
    /// formatting calls whose numbers or currency symbols are asserted.
    override func setUp() {
        super.setUp()
        AppText.locale = Locale(identifier: "zh-Hans")
    }

    func testIconPlaysOnceAndDoesNotScrubOrRestartWithFingerJitter() {
        var playback = RevealIconPlayback()
        XCTAssertEqual(playback.update(visibility: 0.09, reduced: false), .none)
        XCTAssertEqual(playback.update(visibility: 0.1, reduced: false), .play)
        for visibility in [1.0, 0.5, 0.05, 0.09, 0.11, 1] {
            XCTAssertEqual(playback.update(visibility: visibility, reduced: false), .none)
        }
        XCTAssertEqual(playback.update(visibility: 0.01, reduced: false), .reset)
        XCTAssertEqual(playback.update(visibility: 0, reduced: false), .none)
        XCTAssertEqual(playback.update(visibility: 0.2, reduced: false), .play)
    }

    func testReducedMotionShowsFinalGlyphWithoutStartingAPlaybackLoop() {
        var playback = RevealIconPlayback()
        XCTAssertEqual(playback.update(visibility: 1, reduced: true), .finish)
        XCTAssertEqual(playback.update(visibility: 0.5, reduced: true), .none)
        XCTAssertEqual(playback.update(visibility: 1, reduced: false), .play)
        XCTAssertEqual(playback.update(visibility: 1, reduced: true), .finish)
        XCTAssertEqual(playback.update(visibility: 0, reduced: false), .reset)
    }

    func testInvalidVisibilityResetsSafelyAndOvershootDoesNotReplay() {
        var playback = RevealIconPlayback()
        XCTAssertEqual(playback.update(visibility: .nan, reduced: false), .none)
        XCTAssertEqual(playback.update(visibility: -1, reduced: false), .none)
        XCTAssertEqual(playback.update(visibility: 5, reduced: false), .play)
        XCTAssertEqual(playback.update(visibility: 10, reduced: false), .none)
        XCTAssertEqual(playback.update(visibility: .infinity, reduced: false), .reset)
    }

    private func model() -> ItemListRevealMotion {
        var motion = ItemListRevealMotion()
        var parameters = ItemListRevealMotionParameters()
        parameters.width = 360; parameters.count = 1; parameters.isDestructive = true
        motion.configure(parameters)
        return motion
    }
    func testShortDragReboundsWithoutCommitting() {
        var motion = model()
        motion.begin()
        motion.change(translation: 15, velocity: 0, distanceFromCommitEdge: 200)
        XCTAssertFalse(motion.end(translation: 15, velocity: 0, cancelled: false))
        for _ in 0..<360 { motion.advance(by: 1.0 / 120) }
        XCTAssertEqual(motion.state, .closed)
        XCTAssertEqual(motion.body.value, 0, accuracy: 0.001)
    }
    func testFullDragArmsButCancellationNeverCommits() {
        var motion = model()
        motion.begin()
        motion.change(translation: 350, velocity: 200, distanceFromCommitEdge: 0)
        XCTAssertTrue(motion.isArmed)
        XCTAssertFalse(motion.end(translation: 350, velocity: 200, cancelled: true))
        motion.reset(); motion.begin()
        motion.change(translation: 350, velocity: 200, distanceFromCommitEdge: 0)
        XCTAssertTrue(motion.end(translation: 350, velocity: 200, cancelled: false))
    }
    func testRetreatDisarmsActionAndRegrabPreservesPosition() {
        var motion = model()
        motion.begin()
        motion.change(translation: 350, velocity: 100, distanceFromCommitEdge: 0)
        motion.advance(by: 1.0 / 60)
        motion.change(translation: 80, velocity: -100, distanceFromCommitEdge: 220)
        XCTAssertFalse(motion.isArmed)
        XCTAssertFalse(motion.end(translation: 80, velocity: -100, cancelled: false))
        motion.advance(by: 1.0 / 60)
        let before = motion.body.value
        motion.begin()
        XCTAssertEqual(motion.body.value, before, accuracy: 0.001)
    }
    func testSpringIsStableAt60And120Hz() {
        func position(step: Double) -> Double {
            var spring = ItemListRevealSpring()
            spring.target = 76
            for _ in 0..<Int(1 / step) { spring.advance(by: step) }
            return spring.value
        }
        XCTAssertEqual(position(step: 1.0 / 60), position(step: 1.0 / 120), accuracy: 0.001)
    }
    func testAnalyticSpringPreservesElapsedTimeAcrossDroppedFrames() {
        let intervals = [1.0 / 120, 0.4, 1.0 / 60, 0.35, 0.725]
        for damping in [0.6, 1.0, 1.5] {
            var irregular = ItemListRevealSpring(value: 90, target: 0, damping: damping)
            var singleGap = irregular
            for interval in intervals { irregular.advance(by: interval) }
            singleGap.advance(by: intervals.reduce(0, +))
            XCTAssertEqual(irregular.value, singleGap.value, accuracy: 0.001)
            XCTAssertEqual(irregular.velocity, singleGap.velocity, accuracy: 0.01)
        }
    }
    func testClosingRevealSettlesAfterLongFrameGap() {
        var motion = model()
        motion.settle(to: 76, velocity: 0, animated: false)
        XCTAssertEqual(motion.state, .open)
        motion.settle(to: 0, velocity: 0, animated: true)
        motion.advance(by: 2)
        XCTAssertTrue(motion.isAtRest)
        XCTAssertEqual(motion.state, .closed)
        XCTAssertEqual(motion.body.value, 0)
        XCTAssertTrue(motion.buttonGeometry.allSatisfy { $0.opacity == 0 })
    }
    func testReduceMotionSnapsAndStopsAtRest() {
        var motion = model()
        motion.begin()
        motion.change(translation: 90, velocity: 0, distanceFromCommitEdge: 200, reduceMotion: true)
        _ = motion.end(translation: 90, velocity: 0, cancelled: false, animated: false)
        XCTAssertTrue(motion.isAtRest)
        XCTAssertEqual(motion.state, .open)
    }
    func testFillingExpandsPrimaryButtonAndHidesSecondaryActions() {
        var motion = ItemListRevealMotion()
        var parameters = ItemListRevealMotionParameters()
        parameters.width = 360; parameters.count = 2; parameters.isDestructive = true
        motion.configure(parameters)
        motion.settle(to: 360, velocity: 1400, animated: true, filling: true)
        for _ in 0..<240 { motion.advance(by: 1.0 / 120) }
        XCTAssertEqual(motion.state, .filling)
        XCTAssertEqual(motion.body.value, 360, accuracy: 0.01)
        XCTAssertEqual(motion.buttonGeometry.count, 2)
        XCTAssertEqual(motion.buttonGeometry[0].width, 340, accuracy: 0.01)
        XCTAssertEqual(motion.buttonGeometry[1].opacity, 0, accuracy: 0.01)
    }
    func testMotionWorkFor1000RowsHasMeasurableBaseline() {
        measure {
            for _ in 0..<1000 {
                var motion = model()
                motion.begin()
                motion.change(translation: 90, velocity: 300, distanceFromCommitEdge: 200)
                _ = motion.end(translation: 90, velocity: 300, cancelled: false)
                for _ in 0..<60 { motion.advance(by: 1.0 / 120) }
            }
        }
    }
}

#if os(Linux)
@main
enum RevealMotionTestRunner {
    static func main() {
        XCTMain([testCase([
            ("icon plays once", RevealMotionTests.testIconPlaysOnceAndDoesNotScrubOrRestartWithFingerJitter),
            ("icon reduce motion", RevealMotionTests.testReducedMotionShowsFinalGlyphWithoutStartingAPlaybackLoop),
            ("icon invalid input", RevealMotionTests.testInvalidVisibilityResetsSafelyAndOvershootDoesNotReplay),
            ("short drag", RevealMotionTests.testShortDragReboundsWithoutCommitting),
            ("full drag cancellation", RevealMotionTests.testFullDragArmsButCancellationNeverCommits),
            ("retreat and regrab", RevealMotionTests.testRetreatDisarmsActionAndRegrabPreservesPosition),
            ("60/120 Hz", RevealMotionTests.testSpringIsStableAt60And120Hz),
            ("dropped frames", RevealMotionTests.testAnalyticSpringPreservesElapsedTimeAcrossDroppedFrames),
            ("close after frame gap", RevealMotionTests.testClosingRevealSettlesAfterLongFrameGap),
            ("reduce motion", RevealMotionTests.testReduceMotionSnapsAndStopsAtRest),
            ("filling expands primary", RevealMotionTests.testFillingExpandsPrimaryButtonAndHidesSecondaryActions),
            ("1000 rows baseline", RevealMotionTests.testMotionWorkFor1000RowsHasMeasurableBaseline)
        ])])
    }
}
#endif
