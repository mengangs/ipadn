import XCTest
import Combine
@testable import iPadn

final class DownloadConcurrencyTests: XCTestCase {
    func testInterruptedRemovalRestoresOnlyUncommittedPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let packages = root.appendingPathComponent("Packages")
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = DownloadJob(app: StoreApp(id: "1", name: "Test"), status: .completed, localFilename: "sample.ipa")
        let aside = root.appendingPathComponent("\(job.id.uuidString).removing.ipa")
        try Data([1, 2, 3]).write(to: aside)
        try DownloadManager.recoverRemovals([job], support: root, packages: packages)
        let restored = packages.appendingPathComponent("sample.ipa")
        XCTAssertEqual(try Data(contentsOf: restored), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        try Data([4]).write(to: aside)
        try DownloadManager.recoverRemovals([job], support: root, packages: packages)
        XCTAssertEqual(try Data(contentsOf: restored), Data([1, 2, 3]), "Recovery must not overwrite an existing package")
        try DownloadManager.recoverRemovals([], support: root, packages: packages)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    }
    @MainActor
    func testSessionLocalIdentifiersCannotUpdateAnotherTransfersProgress() async throws {
        let a = URLSession(configuration: .ephemeral), b = URLSession(configuration: .ephemeral)
        defer { a.invalidateAndCancel(); b.invalidateAndCancel() }
        let url = URL(string: "https://example.com/not-requested.ipa")!
        let old = a.downloadTask(with: url), current = b.downloadTask(with: url)
        XCTAssertEqual(old.taskIdentifier, current.taskIdentifier)
        let job = DownloadJob(app: StoreApp(id: "1", name: "Test"), status: .running)
        old.taskDescription = job.id.uuidString; current.taskDescription = job.id.uuidString
        let manager = DownloadManager(previewJobs: [job], activeTasks: [job.id: current])
        let progress = manager.progress(for: job.id)
        manager.urlSession(a, downloadTask: old, didWriteData: 9, totalBytesWritten: 9, totalBytesExpectedToWrite: 10)
        manager.urlSession(a, task: old, didCompleteWithError: URLError(.networkConnectionLost))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(progress.bytes)
        XCTAssertEqual(manager.jobs.first?.status, .running)
        var invalidations = 0
        let subscription = manager.objectWillChange.sink { invalidations += 1 }
        manager.urlSession(b, downloadTask: current, didWriteData: 3, totalBytesWritten: 3, totalBytesExpectedToWrite: 10)
        for _ in 0..<100 where progress.bytes == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(progress.bytes?.written, 3)
        XCTAssertEqual(invalidations, 0, "Progress should publish only to its row")
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testBatchRemovalRollsBackOnPersistenceFailure() async {
        let jobs = (0..<3).map { DownloadJob(app: StoreApp(id: "\($0)", name: "Test"), status: .paused) }
        let manager = DownloadManager(previewJobs: jobs, saveJobs: { _ in throw ToolError.message("disk full") })
        do { _ = try await manager.removeBatch(Set(jobs.map(\.id))); XCTFail("Write failure was ignored") }
        catch { XCTAssertEqual(manager.jobs.map(\.id), jobs.map(\.id)) }
        XCTAssertTrue(manager.removingIDs.isEmpty)
    }

    @MainActor
    func testBatchRemovalPreservesUnselectedRecords() async throws {
        let jobs = (0..<3).map { DownloadJob(app: StoreApp(id: "\($0)", name: "Test"), status: .paused) }
        let manager = DownloadManager(previewJobs: jobs)
        let count = try await manager.removeBatch([jobs[0].id, jobs[2].id])
        XCTAssertEqual(count, 2)
        XCTAssertEqual(manager.jobs.map(\.id), [jobs[1].id])
        XCTAssertTrue(manager.removingIDs.isEmpty)
    }
}
