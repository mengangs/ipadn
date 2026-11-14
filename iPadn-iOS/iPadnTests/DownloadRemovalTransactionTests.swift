import Foundation
import XCTest
@testable import iPadn

final class DownloadRemovalTransactionTests: XCTestCase {
    private func fixture(_ test: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(root.appendingPathComponent("original.ipa"), root.appendingPathComponent("quarantine.ipa"))
    }

    func testDurableCommitRetainsQuarantineBytesForUndo() throws {
        try fixture { original, aside in
            try Data([1, 2, 3]).write(to: original)
            var saved = false
            try DownloadRemovalTransaction.perform([(original, aside)]) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
                XCTAssertEqual(try Data(contentsOf: aside), Data([1, 2, 3]))
                saved = true
            }
            XCTAssertTrue(saved)
            XCTAssertEqual(try Data(contentsOf: aside), Data([1, 2, 3]))
        }
    }

    func testFailedTaskListSaveRestoresOriginalBytes() throws {
        try fixture { original, aside in
            try Data([4, 5]).write(to: original)
            XCTAssertThrowsError(try DownloadRemovalTransaction.perform([(original, aside)]) {
                throw CocoaError(.fileWriteOutOfSpace)
            })
            XCTAssertEqual(try Data(contentsOf: original), Data([4, 5]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        }
    }

    func testLaterMoveFailureRollsBackEarlierMovesAndDoesNotSave() throws {
        try fixture { original, aside in
            try Data([6]).write(to: original)
            var saved = false
            let missing = original.deletingLastPathComponent().appendingPathComponent("missing.ipa")
            XCTAssertThrowsError(try DownloadRemovalTransaction.perform([(original, aside), (missing, original)]) { saved = true })
            XCTAssertFalse(saved)
            XCTAssertEqual(try Data(contentsOf: original), Data([6]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        }
    }

    func testUndoRestoresQuarantinedBytes() throws {
        try fixture { original, aside in
            try Data([7, 8]).write(to: aside)
            try DownloadRemovalTransaction.perform([(aside, original)]) {
                XCTAssertEqual(try Data(contentsOf: original), Data([7, 8]))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        }
    }

    func testUndoNeverOverwritesNewOriginalFile() throws {
        try fixture { original, aside in
            try Data([1]).write(to: aside)
            try Data([9]).write(to: original)
            var saved = false
            XCTAssertThrowsError(try DownloadRemovalTransaction.perform([(aside, original)]) { saved = true })
            XCTAssertFalse(saved)
            XCTAssertEqual(try Data(contentsOf: aside), Data([1]))
            XCTAssertEqual(try Data(contentsOf: original), Data([9]))
        }
    }

    func testFailedUndoSaveReturnsBytesToQuarantine() throws {
        try fixture { original, aside in
            try Data([2, 4]).write(to: aside)
            XCTAssertThrowsError(try DownloadRemovalTransaction.perform([(aside, original)]) {
                throw CocoaError(.fileWriteOutOfSpace)
            })
            XCTAssertEqual(try Data(contentsOf: aside), Data([2, 4]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        }
    }

    func testTaskWithoutPackageStillRequiresDurableSave() throws {
        var saved = false
        try DownloadRemovalTransaction.perform([]) { saved = true }
        XCTAssertTrue(saved)
        XCTAssertThrowsError(try DownloadRemovalTransaction.perform([]) { throw CocoaError(.fileWriteOutOfSpace) })
    }
}
