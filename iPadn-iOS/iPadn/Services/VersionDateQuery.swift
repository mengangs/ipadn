import Foundation
import Combine

/// Calendar-day bounds, including the whole end day (also across DST changes).
struct VersionDateRange: Equatable {
    let start: Date
    let endExclusive: Date

    init?(from: Date, through: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: through)
        guard start <= last, let end = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        self.start = start
        self.endExclusive = end
    }

    func contains(_ date: Date) -> Bool { date >= start && date < endExclusive }
}

/// An explicit, cancellable scan: IDs are not chronological date boundaries.
/// Never stop early just because a package date fell outside the interval.
@MainActor final class VersionDateQuery: ObservableObject {
    @Published private(set) var range: VersionDateRange?
    @Published private(set) var matches: [AppVersion] = []
    @Published private(set) var checked = 0
    @Published private(set) var total = 0
    @Published private(set) var unknown = 0
    @Published private(set) var running = false
    @Published private(set) var stoppedForAccount = false
    @Published private(set) var values: [String: VersionMetadata] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var incomplete: Bool { checked < total || unknown > 0 }

    func start(versions: [AppVersion], range: VersionDateRange,
               cached: [String: VersionMetadata], notes: [String: Date],
               fetch: @escaping @MainActor (AppVersion) async throws -> VersionMetadata) {
        clear()
        self.range = range
        var seen = Set<String>()
        let versions = versions.filter { seen.insert($0.id).inserted }
        total = versions.count
        let token = generation
        var dated: [(AppVersion, Date)] = []
        var pending: [AppVersion] = []
        var resolved: [String: VersionMetadata] = [:]
        var inspected = 0
        var unknownDates = 0
        func record(_ version: AppVersion, _ value: VersionMetadata?) {
            let number = value?.version ?? version.version
            if let date = value?.released ?? notes[number] {
                if range.contains(date) { dated.append((version, date)) }
            } else { unknownDates += 1 }
            if let value { resolved[version.id] = value }
            inspected += 1
        }
        func publish() {
            values = resolved
            checked = inspected
            unknown = unknownDates
            matches = dated.sorted { a, b in
                a.1 == b.1 ? a.0.id < b.0.id : a.1 > b.1
            }.map(\.0)
        }
        // Cached hits appear immediately, even if their IDs are late in the list.
        for version in versions {
            if let value = cached[version.id] { record(version, value) }
            else if notes[version.version] != nil { record(version, nil) }
            else { pending.append(version) }
        }
        publish()
        guard !pending.isEmpty else { return }
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { running = false; task = nil } }
            var consecutiveFailures = 0
            for version in pending {
                guard !Task.isCancelled, generation == token else { return }
                do {
                    let value = try await fetch(version)
                    guard !Task.isCancelled, generation == token else { return }
                    consecutiveFailures = 0
                    record(version, value)
                    publish()
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError), generation == token else { return }
                    if error is AppleAuthError || error is AppleLoginError {
                        stoppedForAccount = true
                        return
                    }
                    record(version, nil)
                    publish()
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 { return }
                }
            }
        }
    }

    /// Retain partial results and honest counts on cancel; clear invalidates them.
    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        running = false
    }

    func clear() {
        cancel()
        range = nil; matches = []; values = [:]
        checked = 0; total = 0; unknown = 0; stoppedForAccount = false
    }
}
