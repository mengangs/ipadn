import ActivityKit
import Combine
import Foundation
import UIKit

/// Keeps the download Live Activity in step with the download list
/// (Settings › Downloads › Live Activity).
@MainActor
final class DownloadActivity {
    static let shared = DownloadActivity()

    private weak var manager: DownloadManager?
    private var enabled = false
    private var activity: Any?
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var lastSent: Any?
    private var lastSentAt = Date.distantPast
    /// The downloads the activity was showing at the last refresh.
    private var shownIDs = Set<UUID>()

    func attach(_ manager: DownloadManager, enabled: Bool) {
        guard #available(iOS 16.2, *), !LocalResources.isPreview else { return }
        self.enabled = enabled
        if self.manager !== manager {
            self.manager = manager
            // One left from an earlier run is picked up rather than duplicated.
            let existing = Activity<DownloadActivityAttributes>.activities
            activity = existing.first
            for old in existing.dropFirst() { Task { await old.end(nil, dismissalPolicy: .immediate) } }
            subscription = manager.$jobs
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        guard #available(iOS 16.2, *), let manager else { return }
        let active = manager.jobs.filter { [.running, .pausing, .queued, .processing].contains($0.status) }
        let current = activity as? Activity<DownloadActivityAttributes>
        guard enabled else {
            stopTimer()
            if let current { activity = nil; Task { await current.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        if active.isEmpty {
            stopTimer()
            guard let current else { return }
            activity = nil
            lastSent = nil
            // Everything it showed finished: say so briefly. Paused, failed or removed: just go.
            let shown = manager.jobs.filter { shownIDs.contains($0.id) }
            let finished = !shown.isEmpty && shown.count == shownIDs.count && shown.allSatisfy { $0.status == .completed }
            shownIDs = []
            if finished {
                var done = current.content.state
                done.phase = 2; done.count = 0; done.written = max(done.written, done.expected)
                done.updated = Date(); done.estimatedEnd = nil
                Task { await current.end(ActivityContent(state: done, staleDate: nil), dismissalPolicy: .after(.now + 600)) }
            } else {
                Task { await current.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        let state = makeState(active, manager: manager)
        shownIDs = Set(active.map(\.id))
        if let current {
            send(state, to: current)
        } else if manager.jobs.contains(where: { $0.status == .running }),
                  UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled {
            // Only the app in front may start one.
            activity = try? Activity.request(attributes: DownloadActivityAttributes(),
                                             content: ActivityContent(state: state, staleDate: nil))
            lastSent = state; lastSentAt = Date()
        }
        if activity != nil, timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    @available(iOS 16.2, *)
    private func makeState(_ active: [DownloadJob], manager: DownloadManager) -> DownloadActivityAttributes.ContentState {
        let running = active.filter { $0.status == .running || $0.status == .pausing }
        var written: Int64 = 0, expected: Int64 = 0, speed = 0.0
        for job in running {
            let bytes = manager.progress(for: job.id).bytes
            written += bytes?.written ?? job.downloaded
            expected += max(bytes?.expected ?? 0, job.expected, job.app.size)
            speed += manager.metrics(for: job.id)?.bytesPerSecond ?? 0
        }
        let phase = !running.isEmpty ? 0 : active.contains { $0.status == .processing } ? 1 : 3
        let lead = running.first ?? active.first { $0.status == .processing } ?? active[0]
        let now = Date()
        let left = Double(max(0, expected - written))
        let end = phase == 0 && speed > 1024 && left > 0 ? now.addingTimeInterval(left / speed) : nil
        return .init(phase: phase, name: lead.app.name, count: active.count,
                     written: written, expected: expected, updated: now, estimatedEnd: end)
    }

    /// Changes of phase, app or count go out at once; progress every few seconds.
    @available(iOS 16.2, *)
    private func send(_ state: DownloadActivityAttributes.ContentState, to activity: Activity<DownloadActivityAttributes>) {
        let last = lastSent as? DownloadActivityAttributes.ContentState
        let changed = last == nil || last!.phase != state.phase || last!.name != state.name || last!.count != state.count
        guard changed || Date().timeIntervalSince(lastSentAt) >= 5 else { return }
        lastSent = state; lastSentAt = Date()
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
