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
    private var finishingActivity: Any?
    private var finishingTask: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var lastSent: Any?
    private var lastSentAt = Date.distantPast
    private var refreshScheduled = false
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
                .merge(with: manager.$autoInstalling.map { _ in () },
                       manager.$autoInstalled.map { _ in () },
                       manager.$autoInstallFailed.map { _ in () },
                       manager.$waitingForWiFi.map { _ in () })
                .sink { [weak self] _ in self?.scheduleRefresh() }
        }
        refresh()
    }

    func sync() {
        guard #available(iOS 16.2, *), !LocalResources.isPreview else { return }
        refresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // @Published fires on willSet; scheduling onto the next main turn reads
        // committed state immediately without 300ms debounce lag.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func adoptFinishingActivity() {
        guard #available(iOS 16.2, *), activity == nil, let pending = finishingActivity as? Activity<DownloadActivityAttributes> else {
            finishingTask?.cancel(); finishingTask = nil; finishingActivity = nil
            return
        }
        finishingTask?.cancel(); finishingTask = nil; finishingActivity = nil
        if pending.activityState == .active { activity = pending }
    }

    private func endFinishingImmediately() {
        guard #available(iOS 16.2, *) else { return }
        finishingTask?.cancel(); finishingTask = nil
        if let pending = finishingActivity as? Activity<DownloadActivityAttributes> {
            finishingActivity = nil
            Task { await pending.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func refresh() {
        guard #available(iOS 16.2, *), let manager else { return }
        let active = manager.jobs.filter { [.running, .pausing, .queued, .processing].contains($0.status) }
        if !enabled {
            stopTimer()
            endFinishingImmediately()
            lastSent = nil; shownIDs = []
            if let current = activity as? Activity<DownloadActivityAttributes> {
                activity = nil
                Task { await current.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        if !active.isEmpty || manager.autoInstalling != nil { adoptFinishingActivity() }
        let current = activity as? Activity<DownloadActivityAttributes>

        // Installing automatically after the download: the same activity follows it.
        if active.isEmpty, let install = manager.autoInstalling {
            let state = DownloadActivityAttributes.ContentState(
                phase: 4, name: install.name, count: 1, written: Int64(install.fraction * 1000), expected: 1000,
                updated: Date(), estimatedEnd: nil, speed: 0)
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
                                                                          updated: Date(), estimatedEnd: nil, speed: 0))
            return
        }
        if active.isEmpty, let current, let installed = manager.autoInstalled,
           ((lastSent as? DownloadActivityAttributes.ContentState)?.phase == 4 || current.content.state.phase == 4
            || shownIDs.contains(where: manager.waitsForSilentInstall)) {
            stopTimer()
            activity = nil; lastSent = nil; shownIDs = []
            let done = DownloadActivityAttributes.ContentState(phase: 5, name: installed, count: 0, written: 1000, expected: 1000,
                                                               updated: Date(), estimatedEnd: nil, speed: 0)
            finish(current, with: done)
            return
        }
        // Downloaded and about to install silently: keep the activity for the install.
        if active.isEmpty, activity != nil, shownIDs.contains(where: manager.waitsForSilentInstall) {
            stopTimer()
            return
        }
        if active.isEmpty {
            stopTimer()
            guard let current else { shownIDs = []; return }
            let shown = manager.jobs.filter { shownIDs.contains($0.id) }
            let paused = shown.filter { $0.status == .paused }
            if !paused.isEmpty {
                // Keep the activity alive in paused phase so resuming (even in background) updates smoothly.
                let pausedState = Self.computePausedState(paused: paused, progress: { id in
                    let bytes = manager.progress(for: id).bytes
                    let job = paused.first { $0.id == id }
                    return (bytes?.written ?? job?.downloaded ?? 0, max(bytes?.expected ?? 0, job?.expected ?? 0, job?.app.size ?? 0))
                }, now: Date())
                send(pausedState, to: current)
                return
            }
            activity = nil
            lastSent = nil
            shownIDs = []
            let finished = !shown.isEmpty && shown.allSatisfy { $0.status == .completed }
            if finished {
                var done = current.content.state
                done.phase = 2; done.count = 0; done.written = max(done.written, done.expected)
                done.updated = Date(); done.estimatedEnd = nil; done.speed = 0
                finish(current, with: done)
            } else if let failedJob = shown.first(where: { $0.status == .failed }) {
                let failState = DownloadActivityAttributes.ContentState(
                    phase: 8, name: failedJob.app.name, count: shown.filter { $0.status == .failed }.count,
                    written: 0, expected: 0, updated: Date(), estimatedEnd: nil, speed: 0)
                finish(current, with: failState)
            } else {
                Task { await current.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let state = Self.computeState(active: active, progress: { job in
            let bytes = manager.progress(for: job.id).bytes
            return (bytes?.written ?? job.downloaded, max(bytes?.expected ?? 0, job.expected, job.app.size))
        }, rate: { id in
            manager.metrics(for: id)?.rate(at: uptime) ?? 0
        }, now: now)
        shownIDs = Set(active.map(\.id))
        if let current {
            send(state, to: current)
        } else if manager.jobs.contains(where: { $0.status == .running }),
                  UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled {
            // Only the app in front may start one.
            activity = try? Activity.request(attributes: DownloadActivityAttributes(),
                                             content: ActivityContent(state: state, staleDate: Self.staleDate(state)))
            lastSent = state; lastSentAt = now
        }
        if state.phase == 7 { stopTimer() } else { startTimer() }
    }

    @available(iOS 16.1, *)
    nonisolated static func computeState(
        active: [DownloadJob],
        progress: (DownloadJob) -> (written: Int64, expected: Int64),
        rate: (UUID) -> Double,
        now: Date = Date()
    ) -> DownloadActivityAttributes.ContentState {
        let running = active.filter { $0.status == .running }
        let processing = active.filter { $0.status == .processing }
        let queued = active.filter { $0.status == .queued }
        let pausing = active.filter { $0.status == .pausing }
        let phase: Int
        let cohort: [DownloadJob]
        if !running.isEmpty {
            phase = 0; cohort = running
        } else if !processing.isEmpty {
            phase = 1; cohort = processing
        } else if !queued.isEmpty {
            phase = 3; cohort = queued
        } else {
            phase = 7; cohort = pausing
        }
        var written: Int64 = 0, expected: Int64 = 0, speed = 0.0
        for job in cohort {
            let p = progress(job)
            written += p.written
            expected += p.expected
            if phase == 0 { speed += rate(job.id) }
        }
        let lead = cohort[0]
        let left = Double(max(0, expected - written))
        let end = phase == 0 && speed > 1024 && left > 0 ? now.addingTimeInterval(left / speed) : nil
        let speedBytes = phase == 0 && speed > 0 ? Int64(min(speed.rounded(), Double(Int64.max / 2))) : 0
        return .init(phase: phase, name: lead.app.name, count: active.count,
                     written: written, expected: expected, updated: now, estimatedEnd: end, speed: speedBytes)
    }

    @available(iOS 16.1, *)
    @available(iOS 16.1, *)
    nonisolated static func computePausedState(
        paused: [DownloadJob],
        progress: (UUID) -> (written: Int64, expected: Int64),
        now: Date = Date()
    ) -> DownloadActivityAttributes.ContentState {
        var written: Int64 = 0, expected: Int64 = 0
        for job in paused {
            let p = progress(job.id)
            written += p.written
            expected += p.expected
        }
        return .init(phase: 7, name: paused[0].app.name, count: paused.count,
                     written: written, expected: expected, updated: now, estimatedEnd: nil, speed: 0)
    }

    @available(iOS 16.1, *)
    nonisolated static func shouldSend(
        _ state: DownloadActivityAttributes.ContentState,
        after last: DownloadActivityAttributes.ContentState?,
        elapsed: TimeInterval
    ) -> Bool {
        guard let last else { return true }
        let changed = last.phase != state.phase
            || last.name != state.name
            || last.count != state.count
            || (last.estimatedEnd == nil) != (state.estimatedEnd == nil)
        if changed { return true }
        guard elapsed >= 1 else { return false }
        let moved = last.written != state.written || last.expected != state.expected
        if moved { return true }
        if let prevEnd = last.estimatedEnd, let nextEnd = state.estimatedEnd,
           abs(nextEnd.timeIntervalSince(prevEnd)) >= 3 {
            return true
        }
        if abs(state.speed - last.speed) >= max(32_768, last.speed / 4) {
            return true
        }
        return false
    }

    /// Changes of phase, app, count or ETA availability go out at once; progress once a second.
    @available(iOS 16.2, *)
    private func send(_ state: DownloadActivityAttributes.ContentState, to activity: Activity<DownloadActivityAttributes>) {
        let last = lastSent as? DownloadActivityAttributes.ContentState
        let now = Date()
        guard Self.shouldSend(state, after: last, elapsed: now.timeIntervalSince(lastSentAt)) else { return }
        let phaseChanged = last == nil || last!.phase != state.phase || last!.name != state.name || last!.count != state.count
        lastSent = state; lastSentAt = now
        if phaseChanged { activityLog.notice("LA update phase \(state.phase) \(state.name, privacy: .public) bg=\(UIApplication.shared.applicationState != .active)") }
        // Starting to install: the Dynamic Island opens briefly to say so.
        let alert = phaseChanged && state.phase == 4 && last?.phase != 4 ? Self.alert(state) : nil
        Task { await activity.update(ActivityContent(state: state, staleDate: Self.staleDate(state)), alertConfiguration: alert) }
    }

    /// Shows the final state (downloaded, installed, failed) for a
    /// moment, then ends the activity together with the task.
    @available(iOS 16.2, *)
    private func finish(_ activity: Activity<DownloadActivityAttributes>, with state: DownloadActivityAttributes.ContentState) {
        finishingTask?.cancel()
        finishingActivity = activity
        let task = BackgroundTime()
        activityLog.notice("LA finish phase \(state.phase) bg=\(UIApplication.shared.applicationState != .active)")
        finishingTask = Task { [weak self] in
            defer { task.end() }
            await activity.update(ActivityContent(state: state, staleDate: nil))
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            if (self?.finishingActivity as? Activity<DownloadActivityAttributes>)?.id == activity.id {
                self?.finishingActivity = nil
                self?.finishingTask = nil
            }
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
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
        case 8: "下载失败"
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
