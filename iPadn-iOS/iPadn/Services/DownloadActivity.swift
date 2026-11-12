import ActivityKit
import Combine
import Foundation
import OSLog
import UIKit

private let activityLog = Logger(subsystem: "app.local.iPadn", category: "LiveActivity")

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
            subscription = manager.$jobs.map { _ in () }
                .merge(with: manager.$autoInstalling.map { _ in () }, manager.$autoInstalled.map { _ in () },
                       manager.$autoInstallFailed.map { _ in () })
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
        // Installing automatically after the download: the same activity follows it.
        if active.isEmpty, let install = manager.autoInstalling {
            let state = DownloadActivityAttributes.ContentState(
                phase: 4, name: install.name, count: 1, written: Int64(install.fraction * 1000), expected: 1000,
                updated: Date(), estimatedEnd: nil)
            if let current { send(state, to: current) }
            else if UIApplication.shared.applicationState == .active, ActivityAuthorizationInfo().areActivitiesEnabled {
                activity = try? Activity.request(attributes: DownloadActivityAttributes(),
                                                 content: ActivityContent(state: state, staleDate: Self.staleDate(state)))
                lastSent = state; lastSentAt = Date()
            }
            startTimer()
            return
        }
        // The install did not finish: say so and end with it, rather than stay on "Installing".
        if active.isEmpty, let current, let failed = manager.autoInstallFailed,
           (lastSent as? DownloadActivityAttributes.ContentState)?.phase == 4 || current.content.state.phase == 4 {
            stopTimer()
            activity = nil; lastSent = nil; shownIDs = []
            finish(current, with: DownloadActivityAttributes.ContentState(phase: 6, name: failed, count: 0, written: 0, expected: 0,
                                                                          updated: Date(), estimatedEnd: nil))
            return
        }
        if active.isEmpty, let current, let installed = manager.autoInstalled,
           ((lastSent as? DownloadActivityAttributes.ContentState)?.phase == 4 || current.content.state.phase == 4
            || shownIDs.contains(where: manager.waitsForSilentInstall)) {
            stopTimer()
            activity = nil; lastSent = nil; shownIDs = []
            let done = DownloadActivityAttributes.ContentState(phase: 5, name: installed, count: 0, written: 1000, expected: 1000,
                                                               updated: Date(), estimatedEnd: nil)
            finish(current, with: done)
            return
        }
        // Downloaded and about to install silently: keep the activity for the install.
        if active.isEmpty, activity != nil, shownIDs.contains(where: manager.waitsForSilentInstall) { return }
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
                finish(current, with: done)
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
                                             content: ActivityContent(state: state, staleDate: Self.staleDate(state)))
            lastSent = state; lastSentAt = Date()
        }
        startTimer()
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

    /// Changes of phase, app or count go out at once; progress once a second when it moved.
    @available(iOS 16.2, *)
    private func send(_ state: DownloadActivityAttributes.ContentState, to activity: Activity<DownloadActivityAttributes>) {
        let last = lastSent as? DownloadActivityAttributes.ContentState
        let changed = last == nil || last!.phase != state.phase || last!.name != state.name || last!.count != state.count
        let moved = last == nil || last!.written != state.written || last!.expected != state.expected
        guard changed || (moved && Date().timeIntervalSince(lastSentAt) >= 1) else { return }
        lastSent = state; lastSentAt = Date()
        if changed { activityLog.notice("LA update phase \(state.phase) \(state.name, privacy: .public) bg=\(UIApplication.shared.applicationState != .active)") }
        // Starting to install: the Dynamic Island opens briefly to say so.
        let alert = changed && state.phase == 4 && last?.phase != 4 ? Self.alert(state) : nil
        Task { await activity.update(ActivityContent(state: state, staleDate: Self.staleDate(state)), alertConfiguration: alert) }
    }

    /// Shows the final state (downloaded, installed, not installed) for a
    /// moment, then ends the activity together with the task. The notification
    /// sent at the same time is the alert, so the Dynamic Island doesn't open again.
    @available(iOS 16.2, *)
    private func finish(_ activity: Activity<DownloadActivityAttributes>, with state: DownloadActivityAttributes.ContentState) {
        let task = BackgroundTime()
        activityLog.notice("LA finish phase \(state.phase) bg=\(UIApplication.shared.applicationState != .active)")
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            task.end()
        }
    }

    /// Updates come every few seconds while iPadn runs; much later, it no longer does.
    @available(iOS 16.2, *)
    private static func staleDate(_ state: DownloadActivityAttributes.ContentState) -> Date? {
        [0, 1, 4].contains(state.phase) ? Date().addingTimeInterval(90) : nil
    }

    @available(iOS 16.2, *)
    private static func alert(_ state: DownloadActivityAttributes.ContentState) -> AlertConfiguration {
        let title: LocalizedStringResource = switch state.phase {
        case 2: "下载完成"
        case 4: "正在安装"
        case 6: "安装未完成"
        default: "已安装"
        }
        return AlertConfiguration(title: title, body: LocalizedStringResource(String.LocalizationValue(state.name)), sound: .default)
    }

    private func startTimer() {
        guard activity != nil, timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}


/// A little time in the background to finish what was started.
@MainActor
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid
    init() { id = UIApplication.shared.beginBackgroundTask { [weak self] in self?.end() } }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id); id = .invalid
    }
}
