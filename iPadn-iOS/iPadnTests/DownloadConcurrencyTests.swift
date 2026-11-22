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

    @MainActor
    func testCancelAutoInstallStopsQueuedAndRespectsIrreversibleStage() {
        let job = DownloadJob(app: StoreApp(id: "auto-1", name: "Auto App", version: "1.0"), status: .completed)
        let manager = DownloadManager(previewJobs: [job])
        XCTAssertEqual(manager.cancelAutoInstall(job.id), .idle)

        manager.pendingAutoInstalls = [job.id]
        XCTAssertEqual(manager.cancelAutoInstall(job.id), .cancelled)
        XCTAssertTrue(manager.pendingAutoInstalls.isEmpty)

        manager.setAutoInstallingForTesting(.init(id: job.id, name: "Auto App 1.0", fraction: 0.4, canCancel: true))
        XCTAssertEqual(manager.cancelAutoInstall(job.id), .cancelled)

        manager.setAutoInstallingForTesting(.init(id: job.id, name: "Auto App 1.0", fraction: 0.85, canCancel: false))
        XCTAssertEqual(manager.cancelAutoInstall(job.id), .irreversible)
        XCTAssertNotNil(manager.autoInstallNotice)
        XCTAssertThrowsError(try manager.remove(job.id))
        XCTAssertEqual(manager.jobs.count, 1, "Task in irreversible system install stage must not be deleted")
        manager.setAutoInstallingForTesting(nil)
    }

    @MainActor
    func testAutoInstallLiveActivityStagesDistinguishIndeterminateAndTransfer() {
        if #available(iOS 16.1, *) {
            let jobID = UUID()
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            let connecting = DownloadManager.AutoInstallProgress(id: jobID, name: "Sample 1.0", fraction: 0, canCancel: true, stage: .connecting)
            let connectingState = DownloadActivity.autoInstallState(for: connecting, now: now)
            XCTAssertFalse(connecting.hasProgress)
            XCTAssertEqual(connectingState.phase, 4)
            XCTAssertEqual(connectingState.expected, 0, "Connecting stage must report indeterminate instead of 0%")
            XCTAssertEqual(connectingState.speed, 0)

            let preTransferUpload = DownloadManager.AutoInstallProgress(id: jobID, name: "Sample 1.0", fraction: 0, canCancel: true, stage: .uploading)
            let preTransferState = DownloadActivity.autoInstallState(for: preTransferUpload, now: now)
            XCTAssertFalse(preTransferUpload.hasProgress)
            XCTAssertEqual(preTransferState.expected, 0, "Zero-fraction uploading must stay indeterminate until transfer bytes move")
            XCTAssertEqual(preTransferState.speed, 1)
            XCTAssertTrue(DownloadActivity.shouldSend(preTransferState, after: connectingState, elapsed: 0.05))

            let activeUpload = DownloadManager.AutoInstallProgress(id: jobID, name: "Sample 1.0", fraction: 0.4, canCancel: true, stage: .uploading)
            let activeUploadState = DownloadActivity.autoInstallState(for: activeUpload, now: now)
            XCTAssertTrue(activeUpload.hasProgress)
            XCTAssertEqual(activeUploadState.expected, 1000)
            XCTAssertEqual(activeUploadState.written, 400)
            XCTAssertEqual(activeUploadState.speed, 1)
            XCTAssertTrue(DownloadActivity.shouldSend(activeUploadState, after: preTransferState, elapsed: 0.05),
                          "Transition from indeterminate to determinate progress must push immediately")

            let installing = DownloadManager.AutoInstallProgress(id: jobID, name: "Sample 1.0", fraction: 0, canCancel: false, stage: .installing)
            let installingState = DownloadActivity.autoInstallState(for: installing, now: now)
            XCTAssertEqual(installingState.expected, 1000)
            XCTAssertEqual(installingState.written, 700, "System install stage must keep at least 70% progress floor")
            XCTAssertEqual(installingState.speed, 2)
            XCTAssertTrue(DownloadActivity.shouldSend(installingState, after: activeUploadState, elapsed: 0.05))
        }
    }

    func testDownloadActivityUnifiesRegularAndTestFlightSnapshots() {
        if #available(iOS 16.2, *) {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let tfRunning = DownloadActivity.ActivityTaskSnapshot(
                key: "tf:12345",
                name: "TestFlight Beta",
                phase: .running,
                written: 50_000_000,
                expected: 100_000_000,
                speed: 5_000_000,
                waitsForSilentInstall: false
            )
            let single = DownloadActivity.computeSnapshotState(active: [tfRunning], now: now)
            XCTAssertEqual(single.phase, 0)
            XCTAssertEqual(single.name, "TestFlight Beta")
            XCTAssertEqual(single.count, 1)
            XCTAssertEqual(single.written, 50_000_000)
            XCTAssertEqual(single.expected, 100_000_000)
            XCTAssertEqual(single.speed, 5_000_000)
            XCTAssertNotNil(single.estimatedEnd)

            let tfPaused = DownloadActivity.ActivityTaskSnapshot(
                key: "tf:12345",
                name: "TestFlight Beta",
                phase: .paused,
                written: 50_000_000,
                expected: 100_000_000,
                speed: 0,
                waitsForSilentInstall: false
            )
            let pausedState = DownloadActivity.computePausedSnapshotState(paused: [tfPaused], now: now)
            XCTAssertEqual(pausedState.phase, 7)
            XCTAssertEqual(pausedState.name, "TestFlight Beta")
            XCTAssertEqual(pausedState.written, 50_000_000)
            XCTAssertEqual(pausedState.expected, 100_000_000)
        }
    }

    @MainActor
    func testInterruptedAutoInstallRecoveryClearsInFlightAndWaitingLoop() {
        let job = DownloadJob(app: StoreApp(id: "auto-crash-1", name: "Crash Guard App", version: "2.0"), status: .completed)
        let manager = DownloadManager(previewJobs: [job])
        let prevWaiting = LocalResources.defaults.stringArray(forKey: "autoInstallWaiting")
        let prevInFlight = LocalResources.defaults.string(forKey: "autoInstallInFlight")
        defer {
            if let prevWaiting { LocalResources.defaults.set(prevWaiting, forKey: "autoInstallWaiting") }
            else { LocalResources.defaults.removeObject(forKey: "autoInstallWaiting") }
            if let prevInFlight { LocalResources.defaults.set(prevInFlight, forKey: "autoInstallInFlight") }
            else { LocalResources.defaults.removeObject(forKey: "autoInstallInFlight") }
        }

        manager.setWaitingAutoInstallForTesting(job.id, waiting: true)
        manager.setInFlightAutoInstallForTesting(job.id)
        manager.recoverInterruptedAutoInstallForTesting()

        XCTAssertNil(LocalResources.defaults.string(forKey: "autoInstallInFlight"))
        XCTAssertFalse((LocalResources.defaults.stringArray(forKey: "autoInstallWaiting") ?? []).contains(job.id.uuidString),
                       "Interrupted auto-install ID must be removed from waiting queue so relaunch does not loop-crash")
        XCTAssertEqual(manager.autoInstallFailed, "Crash Guard App 2.0")
        XCTAssertNotNil(manager.autoInstallNotice)
    }

    @MainActor
    func testEnqueueDeduplicatesByExternalVersionIDNotStaleDispatchVersion() throws {
        LocalResources.ensureDirectoriesExist()
        let url = URL(string: "https://example.com/oplayer.ipa")!
        let assetA = DownloadAsset(
            app: StoreApp(id: "385907472", name: "OPlayer Lite", bundleID: "com.olimsoft.oplayer.lite",
                          version: "4800", externalVersionID: "7100658"),
            url: url, sinf: Data([1]), metadata: Data(), externalVersionIDs: ["7100658", "7752498", "857150582"],
            platform: "ios", account: "user@example.com"
        )
        let assetB = DownloadAsset(
            app: StoreApp(id: "385907472", name: "OPlayer Lite", bundleID: "com.olimsoft.oplayer.lite",
                          version: "4800", externalVersionID: "7752498"),
            url: url, sinf: Data([1]), metadata: Data(), externalVersionIDs: ["7100658", "7752498", "857150582"],
            platform: "ios", account: "user@example.com"
        )
        let manager = DownloadManager(previewJobs: [
            DownloadJob(app: assetA.app, asset: assetA, sourceURL: url, status: .paused)
        ])
        XCTAssertNoThrow(try manager.enqueue(assetB), "Different externalVersionID must not collide even if dispatch short version matches")
        XCTAssertEqual(manager.jobs.count, 2)
        XCTAssertThrowsError(try manager.enqueue(assetB), "Same externalVersionID must still deduplicate")

        // Persisted failed job with stale "4800" and metadata bundleVersion="2.0.02" reconciles cleanly and blocks wrong-ID retry.
        let legacyPlist = try HTTPClient.encodePlist([
            "itemId": 385907472,
            "softwareVersionBundleId": "com.olimsoft.oplayer.lite",
            "bundleShortVersionString": "4800",
            "bundleVersion": "2.0.02",
            "softwareVersionExternalIdentifier": 7752498
        ])
        let failedLegacyAsset = DownloadAsset(
            app: StoreApp(id: "385907472", name: "OPlayer Lite", bundleID: "com.olimsoft.oplayer.lite",
                          version: "4800", externalVersionID: "7752498"),
            url: url, sinf: Data([1]), metadata: legacyPlist, externalVersionIDs: [], platform: "ios", account: "user@example.com"
        )
        var failedJob = DownloadJob(app: failedLegacyAsset.app, asset: failedLegacyAsset, sourceURL: url, status: .failed, error: "mismatch")
        failedJob.reconcileDispatchVersionFromMetadata()
        XCTAssertEqual(failedJob.app.version, "2.0.02")
        XCTAssertEqual(failedJob.app.bundleVersion, "2.0.02")

        let retryManager = DownloadManager(previewJobs: [failedJob])
        let wrongRetry = DownloadAsset(
            app: StoreApp(id: "385907472", name: "OPlayer Lite", bundleID: "com.olimsoft.oplayer.lite",
                          version: "4800", externalVersionID: "857150582"),
            url: url, sinf: Data([1]), metadata: Data(), externalVersionIDs: [], platform: "ios", account: "user@example.com"
        )
        XCTAssertThrowsError(try retryManager.refreshFailed(failedJob.id, asset: wrongRetry))
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
