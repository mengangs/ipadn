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
    func testReduceMotionSnapsAndStopsAtRest() {
        var motion = model()
        motion.begin()
        motion.change(translation: 90, velocity: 0, distanceFromCommitEdge: 200, reduceMotion: true)
        _ = motion.end(translation: 90, velocity: 0, cancelled: false, animated: false)
        XCTAssertTrue(motion.isAtRest)
        XCTAssertEqual(motion.state, .open)
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
            ("short drag", RevealMotionTests.testShortDragReboundsWithoutCommitting),
            ("full drag cancellation", RevealMotionTests.testFullDragArmsButCancellationNeverCommits),
            ("retreat and regrab", RevealMotionTests.testRetreatDisarmsActionAndRegrabPreservesPosition),
            ("60/120 Hz", RevealMotionTests.testSpringIsStableAt60And120Hz),
            ("reduce motion", RevealMotionTests.testReduceMotionSnapsAndStopsAtRest),
            ("1000 rows baseline", RevealMotionTests.testMotionWorkFor1000RowsHasMeasurableBaseline)
        ])])
    }
}
#endif
