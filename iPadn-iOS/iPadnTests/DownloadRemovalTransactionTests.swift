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

    @MainActor
    func testPackageFileRemovalStagesAndRestoresStandaloneFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let file = root.appendingPathComponent("Standalone.ipa")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("standalone-ipa".utf8).write(to: file)
        var changes = 0
        let store = PackageFileRemovalStore(
            supportDirectory: support,
            expiryLeadSeconds: 60,
            sweepOnInit: false,
            onChanged: { changes += 1 }
        )

        let receipt = try XCTUnwrap(try store.removeFileReversibly(at: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(changes, 1)

        try store.undoRemovalGroup([receipt.token])
        XCTAssertEqual(try Data(contentsOf: file), Data("standalone-ipa".utf8))
        XCTAssertTrue(store.recentlyRestoredPaths.contains(PackageOutputPolicy.canonicalPath(file)))
        XCTAssertEqual(changes, 2)
    }

    @MainActor
    func testPackageFileRemovalStagesAndRestoresDecryptOutputIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let output = root.appendingPathComponent("App-decrypted.ipa")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("decrypted-output".utf8).write(to: output)
        let recordID = UUID()
        let originalIdentity = PackageOutputPolicy.identity(output)
        var identities: [UUID: String?] = [recordID: originalIdentity]
        var running = false
        let store = PackageFileRemovalStore(
            supportDirectory: support,
            expiryLeadSeconds: 60,
            sweepOnInit: false,
            canRestoreOutput: { !running },
            readOutputIdentity: { identities[$0] ?? nil },
            writeOutputIdentity: { identities[$0] = $1 },
            onChanged: {}
        )

        let receipt = try XCTUnwrap(try store.removeDecryptOutputReversibly(recordID: recordID, fileURL: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(identities[recordID] ?? nil, "removed")

        running = true
        XCTAssertThrowsError(try store.undoRemovalGroup([receipt.token]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(identities[recordID] ?? nil, "removed")

        running = false
        try store.undoRemovalGroup([receipt.token])
        XCTAssertEqual(try Data(contentsOf: output), Data("decrypted-output".utf8))
        let restoredIdentity = try XCTUnwrap(identities[recordID] ?? nil)
        XCTAssertTrue(PackageOutputPolicy.matches(restoredIdentity, url: output))
        XCTAssertTrue(store.recentlyRestoredRecordIDs.contains(recordID))
    }

    @MainActor
    func testPackageFileRemovalUndoNeverOverwritesReplacementAndSweepsOrphans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let file = root.appendingPathComponent("Orphan.ipa")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = support.appendingPathComponent("pkg-removing-stale.ipa")
        let keep = support.appendingPathComponent("unrelated.ipa")
        try Data("stale".utf8).write(to: stale)
        try Data("keep".utf8).write(to: keep)
        PackageFileRemovalStore.sweepOrphanedRemovalsSync(in: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))

        try Data("old-bytes".utf8).write(to: file)
        let store = PackageFileRemovalStore(
            supportDirectory: support,
            expiryLeadSeconds: 60,
            sweepOnInit: false,
            onChanged: {}
        )
        let receipt = try XCTUnwrap(try store.removeFileReversibly(at: file))
        try Data("new-bytes".utf8).write(to: file)
        try store.undoRemovalGroup([receipt.token])
        XCTAssertEqual(try Data(contentsOf: file), Data("new-bytes".utf8))
    }
}
