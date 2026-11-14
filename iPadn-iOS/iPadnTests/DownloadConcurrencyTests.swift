import XCTest
import Combine
@testable import iPadn

final class DownloadConcurrencyTests: XCTestCase {
    /// Assertions below check the Chinese copy: pin the language instead of
    /// following whatever the simulator is set to. Set `locale:` on the
    /// formatting calls whose numbers or currency symbols are asserted.
    override func setUp() {
        super.setUp()
        AppText.locale = Locale(identifier: "zh-Hans")
    }

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

    @MainActor
    func testSwipeDeletionRetainsFileAndUndoRestoresOrderAndIdentity() async throws {
        LocalResources.ensureDirectoriesExist()
        let filename = "Undo-Test-\(UUID().uuidString).ipa"
        let file = LocalResources.packages.appendingPathComponent(filename)
        let removed = DownloadJob(app: StoreApp(id: "undo", name: "Synthetic"), status: .completed, localFilename: filename)
        let before = DownloadJob(app: StoreApp(id: "before", name: "Before"), status: .paused)
        let after = DownloadJob(app: StoreApp(id: "after", name: "After"), status: .paused)
        let aside = LocalResources.support.appendingPathComponent("\(removed.id.uuidString).removing.ipa")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: aside) }
        try Data([1, 2, 3, 4]).write(to: file)
        let manager = DownloadManager(previewJobs: [before, removed, after])
        let receiptResult = try await manager.removeReversibly(removed.id)
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertEqual(manager.jobs.map(\.id), [before.id, after.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: aside), Data([1, 2, 3, 4]))
        try await manager.undoRemoval(receipt.token)
        try await manager.undoRemoval(receipt.token) // stale/repeated Undo cannot duplicate a job
        XCTAssertEqual(manager.jobs.map(\.id), [before.id, removed.id, after.id])
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3, 4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    }

    @MainActor
    func testExpiredSwipeUndoDoesNotResurrectTask() async throws {
        let job = DownloadJob(app: StoreApp(id: "expired", name: "Synthetic"), status: .paused)
        let manager = DownloadManager(previewJobs: [job])
        let receiptResult = try await manager.removeReversibly(job.id)
        let receipt = try XCTUnwrap(receiptResult)
        manager.extendRemovalUndo([receipt.token], until: .distantPast)
        try await manager.undoRemoval(receipt.token)
        XCTAssertTrue(manager.jobs.isEmpty)
    }

    @MainActor
    func testSwipeDeletionPersistenceFailureDoesNotOfferUndoOrLoseFile() async throws {
        LocalResources.ensureDirectoriesExist()
        let filename = "Undo-Fail-\(UUID().uuidString).ipa"
        let file = LocalResources.packages.appendingPathComponent(filename)
        let job = DownloadJob(app: StoreApp(id: "rollback", name: "Synthetic"), status: .completed, localFilename: filename)
        let aside = LocalResources.support.appendingPathComponent("\(job.id.uuidString).removing.ipa")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: aside) }
        try Data([7, 8]).write(to: file)
        let manager = DownloadManager(previewJobs: [job], saveJobs: { _ in throw ToolError.message("synthetic disk full") })
        do { _ = try await manager.removeReversibly(job.id); XCTFail("Save failure ignored") } catch { }
        XCTAssertEqual(manager.jobs.map(\.id), [job.id])
        XCTAssertEqual(try Data(contentsOf: file), Data([7, 8]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    }

    @MainActor
    func testUndoDoesNotOverwriteNewFileAtOriginalName() async throws {
        LocalResources.ensureDirectoriesExist()
        let filename = "Undo-Collision-\(UUID().uuidString).ipa"
        let file = LocalResources.packages.appendingPathComponent(filename)
        let job = DownloadJob(app: StoreApp(id: "collision", name: "Synthetic"), status: .completed, localFilename: filename)
        let aside = LocalResources.support.appendingPathComponent("\(job.id.uuidString).removing.ipa")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: aside) }
        try Data([1]).write(to: file)
        let manager = DownloadManager(previewJobs: [job])
        let receiptResult = try await manager.removeReversibly(job.id)
        let receipt = try XCTUnwrap(receiptResult)
        try Data([9]).write(to: file)
        do { try await manager.undoRemoval(receipt.token); XCTFail("Existing file overwritten") } catch { }
        XCTAssertTrue(manager.jobs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data([9]))
        XCTAssertEqual(try Data(contentsOf: aside), Data([1]))
    }

    @MainActor
    func testConsecutiveSwipeUndoRestoresOriginalOrder() async throws {
        let jobs = (0..<3).map { DownloadJob(app: StoreApp(id: "undo-\($0)", name: "Synthetic"), status: .paused) }
        let manager = DownloadManager(previewJobs: jobs)
        let firstResult = try await manager.removeReversibly(jobs[0].id)
        let first = try XCTUnwrap(firstResult)
        let secondResult = try await manager.removeReversibly(jobs[1].id)
        let second = try XCTUnwrap(secondResult)
        let deadline = Date().addingTimeInterval(UndoNotice.duration)
        manager.extendRemovalUndo([first.token, second.token], until: deadline)
        try await manager.undoRemoval(second.token)
        try await manager.undoRemoval(first.token)
        XCTAssertEqual(manager.jobs.map(\.id), jobs.map(\.id))
    }

    @MainActor
    func testProcessingDownloadCannotBeSwipedIntoUndoRemoval() async throws {
        let job = DownloadJob(app: StoreApp(id: "processing", name: "Synthetic"), status: .processing)
        let manager = DownloadManager(previewJobs: [job])
        do { _ = try await manager.removeReversibly(job.id); XCTFail("Processing removal accepted") } catch { }
        XCTAssertEqual(manager.jobs.map(\.id), [job.id])
    }

    @MainActor
    func testGroupedUndoClaimsEveryReceiptBeforeSlowSaveAndPublishesOnce() async throws {
        let jobs = (0..<3).map { DownloadJob(app: StoreApp(id: "group-\($0)", name: "Synthetic"), status: .paused) }
        let saves = SaveCounter()
        let manager = DownloadManager(previewJobs: jobs, saveJobs: { _ in saves.save() })
        let firstResult = try await manager.removeReversibly(jobs[0].id)
        let first = try XCTUnwrap(firstResult)
        let secondResult = try await manager.removeReversibly(jobs[1].id)
        let second = try XCTUnwrap(secondResult)
        manager.extendRemovalUndo([first.token, second.token], until: Date().addingTimeInterval(0.1))
        saves.slow = true
        var publications = 0
        let subscription = manager.$jobs.dropFirst().sink { _ in publications += 1 }
        try await manager.undoRemovalGroup([first.token, second.token, first.token])
        XCTAssertEqual(manager.jobs.map(\.id), jobs.map(\.id))
        XCTAssertEqual(publications, 1, "A group must publish one List insertion, not one per receipt")
        XCTAssertTrue(manager.removingIDs.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testGroupedUndoSaveFailureRollsBackEveryFile() async throws {
        LocalResources.ensureDirectoriesExist()
        let jobs = (0..<2).map { index in
            DownloadJob(app: StoreApp(id: "group-file-\(index)", name: "Synthetic"), status: .completed,
                        localFilename: "Undo-Group-\(UUID().uuidString).ipa")
        }
        let originals = jobs.map { LocalResources.packages.appendingPathComponent($0.localFilename!) }
        let asides = jobs.map { LocalResources.support.appendingPathComponent("\($0.id.uuidString).removing.ipa") }
        defer { for file in originals + asides { try? FileManager.default.removeItem(at: file) } }
        for (index, file) in originals.enumerated() { try Data([UInt8(index + 1)]).write(to: file) }
        let saves = SaveCounter()
        let manager = DownloadManager(previewJobs: jobs, saveJobs: { _ in
            if saves.fail { throw ToolError.message("synthetic save failure") }
        })
        let firstResult = try await manager.removeReversibly(jobs[0].id)
        let first = try XCTUnwrap(firstResult)
        let secondResult = try await manager.removeReversibly(jobs[1].id)
        let second = try XCTUnwrap(secondResult)
        saves.fail = true
        do { try await manager.undoRemovalGroup([first.token, second.token]); XCTFail("Save failure ignored") } catch { }
        XCTAssertTrue(manager.jobs.isEmpty)
        XCTAssertTrue(manager.removingIDs.isEmpty)
        for (index, aside) in asides.enumerated() {
            XCTAssertEqual(try Data(contentsOf: aside), Data([UInt8(index + 1)]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: originals[index].path))
        }
        saves.fail = false
        try await manager.undoRemovalGroup([first.token, second.token])
        XCTAssertEqual(manager.jobs.map(\.id), jobs.map(\.id))
    }

    private final class SaveCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _slow = false
        private var _fail = false
        var slow: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _slow }
            set { lock.lock(); _slow = newValue; lock.unlock() }
        }
        var fail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _fail }
            set { lock.lock(); _fail = newValue; lock.unlock() }
        }
        func save() { if slow { Thread.sleep(forTimeInterval: 0.2) } }
    }
}
