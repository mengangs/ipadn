import Foundation

/// Serial-queue filesystem transaction shared by deletion and Undo. Commit the
/// task list only after every rename succeeds; on failure restore prior paths.
/// The caller retains quarantine files until its Undo deadline, or deletes them
/// after a permanent removal. moveItem intentionally refuses name collisions.
enum DownloadRemovalTransaction {
    typealias Move = (from: URL, to: URL)

    static func perform(_ moves: [Move], save: () throws -> Void) throws {
        var completed: [Move] = []
        do {
            for move in moves {
                try FileManager.default.moveItem(at: move.from, to: move.to)
                completed.append(move)
            }
            try save()
        } catch {
            for move in completed.reversed() {
                try? FileManager.default.moveItem(at: move.to, to: move.from)
            }
            throw error
        }
    }
}
