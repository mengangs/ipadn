import XCTest
@testable import iPadn

final class VersionDateQueryTests: XCTestCase {
    private func day(_ text: String, calendar: Calendar) -> Date {
        let parts = text.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    func testWholeEndDayAndDaylightSavingBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = day("2026-03-08", calendar: calendar)
        let range = try XCTUnwrap(VersionDateRange(from: start, through: start, calendar: calendar))
        XCTAssertEqual(range.endExclusive.timeIntervalSince(range.start), 23 * 3600)
        XCTAssertTrue(range.contains(start))
        XCTAssertTrue(range.contains(range.endExclusive.addingTimeInterval(-0.001)))
        XCTAssertFalse(range.contains(start.addingTimeInterval(-0.001)))
        XCTAssertFalse(range.contains(range.endExclusive))
        XCTAssertNil(VersionDateRange(from: range.endExclusive, through: start, calendar: calendar))
    }

    @MainActor private func waitUntilFinished(_ query: VersionDateQuery) async throws {
        let deadline = Date().addingTimeInterval(3)
        while query.running && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(query.running, "The scan must settle without an unbounded wait")
    }

    @MainActor func testChecksEveryIDIncludingNonMonotonicDatesAndDeduplicates() async throws {
        let query = VersionDateQuery()
        let range = try XCTUnwrap(VersionDateRange(from: Date(), through: Date()))
        let inRange = range.start.addingTimeInterval(3600)
        let versions = ["900", "800", "700", "700"].map { AppVersion(id: $0, version: AppVersion.unknown, source: "test") }
        var calls: [String] = []
        query.start(versions: versions, range: range, cached: [:], notes: [:]) { version in
            calls.append(version.id)
            return VersionMetadata(version: version.id,
                                   released: version.id == "800" ? range.start.addingTimeInterval(-100) : inRange)
        }
        try await waitUntilFinished(query)
        XCTAssertEqual(calls, ["900", "800", "700"], "Out-of-range middle dates cannot justify an early stop")
        XCTAssertEqual(Set(query.matches.map(\.id)), ["900", "700"])
        XCTAssertEqual(query.checked, 3)
        XCTAssertEqual(query.total, 3)
        XCTAssertFalse(query.incomplete)
    }

    @MainActor func testCachedAndPublicDatesAreImmediateAndUnknownIsNotAMatch() throws {
        let query = VersionDateQuery()
        let range = try XCTUnwrap(VersionDateRange(from: Date(), through: Date()))
        let versions = ["1", "2", "3"].map { AppVersion(id: $0, version: $0, source: "test") }
        query.start(versions: versions, range: range,
                    cached: ["1": VersionMetadata(version: "1", released: range.start),
                             "3": VersionMetadata(version: "3", released: nil)],
                    notes: ["2": range.start.addingTimeInterval(60)]) { _ in
            XCTFail("Cached dates and public notes must not make a ticket request")
            throw CancellationError()
        }
        XCTAssertEqual(query.matches.map(\.id), ["2", "1"])
        XCTAssertEqual(query.checked, 3)
        XCTAssertEqual(query.unknown, 1)
        XCTAssertTrue(query.incomplete)
        XCTAssertFalse(query.running)
    }

    @MainActor func testCancelledOldScanCannotOverwriteANewQuery() async throws {
        let query = VersionDateQuery()
        let range = try XCTUnwrap(VersionDateRange(from: Date(), through: Date()))
        let started = expectation(description: "first request is pending")
        var pending: CheckedContinuation<VersionMetadata, Never>?
        query.start(versions: [AppVersion(id: "old", version: "1", source: "test")], range: range,
                    cached: [:], notes: [:]) { _ in
            await withCheckedContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        query.cancel()
        XCTAssertTrue(query.incomplete)
        XCTAssertEqual(query.checked, 0)
        query.start(versions: [AppVersion(id: "new", version: "2", source: "test")], range: range,
                    cached: ["new": VersionMetadata(version: "2", released: range.start)], notes: [:]) { _ in
            XCTFail("New cached query must not fetch")
            throw CancellationError()
        }
        try XCTUnwrap(pending).resume(returning: VersionMetadata(version: "1", released: range.start))
        // Let the cancelled request return; its generation must be rejected.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(query.matches.map(\.id), ["new"])
        XCTAssertEqual(query.checked, 1)
        XCTAssertNil(query.values["old"])
        query.clear()
        XCTAssertNil(query.range)
        XCTAssertTrue(query.matches.isEmpty)
    }

    @MainActor func testNetworkFailureStopsAfterThreeWithoutClaimingCompleteResults() async throws {
        let query = VersionDateQuery()
        let range = try XCTUnwrap(VersionDateRange(from: Date(), through: Date()))
        let versions = (0..<10).map { AppVersion(id: String($0), version: "?", source: "test") }
        var calls = 0
        query.start(versions: versions, range: range, cached: [:], notes: [:]) { _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        try await waitUntilFinished(query)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(query.checked, 3)
        XCTAssertEqual(query.unknown, 3)
        XCTAssertTrue(query.incomplete)
        XCTAssertTrue(query.matches.isEmpty)
    }

    @MainActor func testAccountFailureStopsWithoutPromptingOrRequestingEveryID() async throws {
        let query = VersionDateQuery()
        let range = try XCTUnwrap(VersionDateRange(from: Date(), through: Date()))
        var calls = 0
        query.start(versions: ["1", "2"].map { AppVersion(id: $0, version: "?", source: "test") },
                    range: range, cached: [:], notes: [:]) { _ in
            calls += 1
            throw AppleAuthError.reauthenticationRequired
        }
        try await waitUntilFinished(query)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(query.stoppedForAccount)
        XCTAssertTrue(query.incomplete)
        XCTAssertEqual(query.checked, 0)
    }

    func testCancelledMetadataWaiterDoesNotWaitForUnrelatedNetworkRequest() async throws {
        let store = VersionMetadataStore()
        let gate = VersionQueryTestGate()
        let started = expectation(description: "first metadata request holds the queue")
        let first = Task {
            try await store.load(UUID().uuidString) {
                started.fulfill()
                await gate.wait()
                return VersionMetadata(version: "1", released: nil)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        let cancelled = expectation(description: "cancelled queued request returns before the first finishes")
        let second = Task {
            do {
                _ = try await store.load(UUID().uuidString) {
                    XCTFail("Cancelled offscreen row must not fetch")
                    return VersionMetadata(version: "2", released: nil)
                }
                XCTFail("Cancelled request must throw")
            } catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        second.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        await gate.open()
        _ = try await first.value
        await second.value
    }
}

private actor VersionQueryTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}
