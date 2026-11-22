import ActivityKit
import AVFoundation
import Foundation
import UIKit
@preconcurrency import UserNotifications

/// Creates the pairing file on the device itself (iOS 27 and later): iPadn
/// presents itself as a computer, the user picks it in Settings › Privacy &
/// Security › Developer Mode and types the code iPadn shows. The steps and the
/// code follow the user into Settings on the Lock Screen and Dynamic Island.
@MainActor
final class OnDevicePairing: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Advertised; waiting for the user to pick iPadn in Settings.
        case waiting
        /// The device connected and is starting the exchange.
        case connected
        /// The code to type on the device.
        case code(String)
        case finished
        case failed(String)
    }
    @Published private(set) var phase = Phase.idle

    static var isSupported: Bool {
        if #available(iOS 27.0, *) { return NativeInstaller.pairingIsAvailable }
        return false
    }
    /// The name Settings shows for iPadn.
    nonisolated static let hostName = "iPadn"
    static let serviceType = "_remotepairing-pairable-host._tcp."
    nonisolated static let activityLifetime: TimeInterval = 310

    private var service: NetService?
    // ActivityKit is unavailable on iOS 16.0. Access the handle only in guarded methods.
    private var activity: Any?
    private var activityTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var pairTask: Task<Void, Never>?
    private var activityGeneration = 0
    private var stateGeneration = 0
    private var activityStartedAt = Date.distantPast
    private let keepAlive = BackgroundKeepAlive(name: "iPadn pairing")
    private var running = false
    /// Non-isolated box so `deinit` can immediately release native pairing gate & keep-alive
    /// if the view pops while pairing is still in flight.
    private final class DeinitCleanup: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        private var cancelHook: (@MainActor () -> Void)?
        func arm(_ hook: @escaping @MainActor () -> Void) {
            lock.lock(); active = true; cancelHook = hook; lock.unlock()
        }
        func disarm() {
            lock.lock(); active = false; cancelHook = nil; lock.unlock()
        }
        func triggerIfArmed() {
            lock.lock()
            let wasActive = active
            let hook = cancelHook
            active = false
            cancelHook = nil
            lock.unlock()
            guard wasActive else { return }
            NativeInstaller.cancelPairing()
            if let hook {
                Task { @MainActor in hook() }
            }
        }
    }
    private var backgroundObserver: NSObjectProtocol?
    private let cleanup = DeinitCleanup()

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        cleanup.triggerIfArmed()
    }

    func start() {
        guard !running else { return }
        running = true
        phase = .waiting
        // iPadn must keep answering while Settings is in front; a background
        // task alone ends within seconds, which stops the pairing.
        keepAlive.start()
        if let existingObserver = backgroundObserver {
            NotificationCenter.default.removeObserver(existingObserver)
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, self.phase == .waiting else { return }
                // Pause silent audio right as iPadn leaves the screen (whether via "Open Settings"
                // or manually switching apps) so audiomxd's 5.4s media assertion finishes clearing
                // while the user navigates to Developer Mode, letting the PIN Live Activity pop up immediately.
                self.keepAlive.pauseForHandoff(resumeAfter: 22)
            }
        }
        startActivity()
        let keepAliveRef = keepAlive
        cleanup.arm { [weak self] in
            self?.pairTask?.cancel()
            self?.service?.stop()
            self?.service = nil
            keepAliveRef.stop()
            if #available(iOS 16.2, *) {
                Task {
                    for item in Activity<PairingActivityAttributes>.activities {
                        await item.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
        }
        let liveActivityActive = hasActiveLiveActivity
        if Self.shouldSendFallbackNotification(hasActiveLiveActivity: liveActivityActive) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        InstallLog.shared.add("on-device pairing started (live activity: \(liveActivityActive ? "on" : "off"))")
        pairTask = Task { [weak self] in
            do {
                let data = try await NativeInstaller.pair(name: Self.hostName) { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        let previous = self.eventTask
                        self.eventTask = Task { @MainActor in
                            await previous?.value
                            self.handle(event)
                        }
                    }
                }
                guard let self else { return }
                await self.eventTask?.value
                try NativeInstaller.importPairingFile(data)
                InstallLog.shared.add("on-device pairing finished")
                let hadLiveActivity = hasActiveLiveActivity
                finish(.finished)
                if Self.shouldSendFallbackNotification(hasActiveLiveActivity: hadLiveActivity) {
                    notify(AppText.text("配对完成"), body: AppText.text("回到 iPadn 继续。"))
                }
            } catch is CancellationError {
                self?.finish(.idle)
            } catch {
                InstallLog.shared.add("on-device pairing failed: \(error.localizedDescription)")
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        guard running else { return }
        pairTask?.cancel()
        NativeInstaller.cancelPairing()
    }

    /// Triggered when leaving iPadn for Settings during Step 1 so the Dynamic Island
    /// shows an immediate banner with the Privacy & Security path once backgrounded.
    func notifyHandoffIfWaiting() {
        guard running, phase == .waiting else { return }
        keepAlive.pauseForHandoff(resumeAfter: 22)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.running, self.phase == .waiting else { return }
            self.update(step: 1)
        }
    }

    /// Step 2 (connected, waiting for passcode) updates the Live Activity silently so
    /// ActivityKit's Dynamic Island alert budget stays reserved for Step 3 (the 6-digit PIN).
    nonisolated static func shouldAlertLiveActivity(forStep step: Int) -> Bool {
        step != 2
    }

    static func formattedCode(_ code: String) -> String {
        let digits = Array(code)
        guard digits.count == 6 else { return code }
        return String(digits[0..<3]) + " " + String(digits[3...])
    }

    static func activityStaleDate(forStep step: Int, now: Date = Date()) -> Date? {
        (1...3).contains(step) ? now.addingTimeInterval(activityLifetime) : nil
    }

    static func shouldSendFallbackNotification(hasActiveLiveActivity: Bool) -> Bool {
        !hasActiveLiveActivity
    }

    @available(iOS 16.2, *)
    static func alertConfiguration(step: Int, code: String? = nil, host: String = hostName, message: String? = nil) -> AlertConfiguration? {
        switch step {
        case 1:
            return AlertConfiguration(
                title: LocalizedStringResource("在「设置」中配对 \(host)"),
                body: LocalizedStringResource("点左上角「< 设置」返回 › 隐私与安全性 › 开发者模式 › 选 \(host)"),
                sound: .default
            )
        case 2:
            return AlertConfiguration(
                title: LocalizedStringResource("正在与 \(host) 配对"),
                body: LocalizedStringResource("如有锁屏密码弹窗请先输入，正在等待配对码"),
                sound: .default
            )
        case 3:
            let display = code.map(formattedCode) ?? ""
            return AlertConfiguration(
                title: LocalizedStringResource("iPadn 配对码：\(display)"),
                body: LocalizedStringResource("在「设置」中输入这个配对码"),
                sound: .default
            )
        case 4:
            return AlertConfiguration(
                title: LocalizedStringResource("配对完成"),
                body: LocalizedStringResource("回到 \(host) 继续安装"),
                sound: .default
            )
        case 0:
            let detail = message.flatMap { $0.isEmpty ? nil : $0 } ?? "请回到 \(host) 重试"
            return AlertConfiguration(
                title: LocalizedStringResource("配对未完成"),
                body: LocalizedStringResource(String.LocalizationValue(detail)),
                sound: .default
            )
        default:
            return nil
        }
    }

    private var hasActiveLiveActivity: Bool {
        guard #available(iOS 16.2, *),
              let current = activity as? Activity<PairingActivityAttributes>,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            return false
        }
        return current.activityState == .active
    }

    private func handle(_ event: NativeInstaller.PairingEvent) {
        guard running else { return }
        switch event {
        case .ready(let port, let identifier, let txt):
            advertise(port: port, identifier: identifier, txt: txt)
        case .connected:
            phase = .connected
            if UIApplication.shared.applicationState != .active {
                keepAlive.pauseForHandoff(resumeAfter: 27)
            }
            update(step: 2)
        case .code(let code):
            phase = .code(code)
            if UIApplication.shared.applicationState != .active {
                keepAlive.pauseForHandoff(resumeAfter: 27)
            }
            update(step: 3, code: code)
            if Self.shouldSendFallbackNotification(hasActiveLiveActivity: hasActiveLiveActivity) {
                let display = Self.formattedCode(code)
                notify(AppText.text("iPadn 配对码：\(display)"), body: AppText.text("在「设置」中输入这个配对码。"))
            }
        }
    }

    private func advertise(port: Int, identifier: String, txt: [String: String]) {
        let service = NetService(domain: "local.", type: Self.serviceType, name: identifier, port: Int32(port))
        service.includesPeerToPeer = true
        service.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
        service.publish()
        self.service = service
        InstallLog.shared.add("pairable host advertised on port \(port)")
    }

    private func finish(_ phase: Phase) {
        guard running else { return }
        cleanup.disarm()
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        pairTask = nil
        service?.stop(); service = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ipadn-pairing-code"])
        // Hold a background assertion BEFORE stopping keep-alive so the final
        // Live Activity update/end never drops between keepAlive.stop() and Task scheduling.
        let bg = UIApplication.shared.applicationState != .active ? PairingBackgroundTime(name: "iPadn pairing finish") : nil
        keepAlive.stop()
        running = false
        self.phase = phase
        switch phase {
        case .finished: endActivity(step: 4, message: nil, keepingAlive: bg)
        case .failed(let message): endActivity(step: 0, message: message, keepingAlive: bg)
        default: endActivity(step: nil, message: nil, keepingAlive: bg)
        }
    }

    // MARK: Live Activity

    private func enqueueActivityWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = activityTask
        activityTask = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func startActivity() {
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activityGeneration += 1
        stateGeneration += 1
        let stale = Activity<PairingActivityAttributes>.activities
        let state = PairingActivityAttributes.ContentState(step: 1)
        do {
            let created = try Activity.request(
                attributes: PairingActivityAttributes(hostName: Self.hostName),
                content: ActivityContent(state: state, staleDate: Self.activityStaleDate(forStep: 1))
            )
            activity = created
            activityStartedAt = Date()
            let toEnd = stale.filter { $0.id != created.id }
            if !toEnd.isEmpty {
                enqueueActivityWork {
                    for old in toEnd { await old.end(nil, dismissalPolicy: .immediate) }
                }
            }
        } catch {
            activity = nil
            InstallLog.shared.add("pairing live activity unavailable: \(error.localizedDescription)")
        }
    }

    private func update(step: Int, code: String? = nil) {
        guard #available(iOS 16.2, *), let current = activity as? Activity<PairingActivityAttributes> else { return }
        stateGeneration += 1
        let generation = activityGeneration
        let targetStateGeneration = stateGeneration
        let startedAt = activityStartedAt
        let state = PairingActivityAttributes.ContentState(step: step, code: code)
        let content = ActivityContent(state: state, staleDate: Self.activityStaleDate(forStep: step))
        let alert = Self.shouldAlertLiveActivity(forStep: step) ? Self.alertConfiguration(step: step, code: code) : nil
        let bg = UIApplication.shared.applicationState != .active ? PairingBackgroundTime(name: "iPadn pairing activity update") : nil
        enqueueActivityWork { [weak self] in
            defer { bg?.end() }
            guard let self,
                  self.activityGeneration == generation,
                  self.stateGeneration == targetStateGeneration else { return }
            await self.keepAlive.waitUntilActivityUpdatePermitted(
                activityStartedAt: startedAt,
                allowLaunchGrantBypass: step == 1
            ) { [weak self] in
                guard let self else { return false }
                return self.activityGeneration == generation && self.stateGeneration == targetStateGeneration
            }
            guard self.activityGeneration == generation,
                  self.stateGeneration == targetStateGeneration else { return }
            await current.update(content, alertConfiguration: alert)
            if step == 3, let code {
                let liveState = current.activityState
                InstallLog.shared.add("pairing code live activity updated (state: \(liveState), bg: \(UIApplication.shared.applicationState != .active))")
                if liveState != .active {
                    let display = Self.formattedCode(code)
                    self.notify(AppText.text("iPadn 配对码：\(display)"), body: AppText.text("在「设置」中输入这个配对码。"))
                }
            }
        }
    }

    private func endActivity(step: Int?, message: String?, keepingAlive bg: PairingBackgroundTime? = nil) {
        activityGeneration += 1
        stateGeneration += 1
        let startedAt = activityStartedAt
        guard #available(iOS 16.2, *), let current = activity as? Activity<PairingActivityAttributes> else {
            bg?.end()
            return
        }
        self.activity = nil
        let finishBg = bg ?? (UIApplication.shared.applicationState != .active ? PairingBackgroundTime(name: "iPadn pairing finish") : nil)
        enqueueActivityWork { [weak self] in
            defer { finishBg?.end() }
            if let step {
                if let self {
                    await self.keepAlive.waitUntilActivityUpdatePermitted(activityStartedAt: startedAt)
                }
                let state = PairingActivityAttributes.ContentState(step: step, message: message)
                let content = ActivityContent(state: state, staleDate: Self.activityStaleDate(forStep: step))
                let alert = Self.alertConfiguration(step: step, message: message)
                await current.update(content, alertConfiguration: alert)
                if UIApplication.shared.applicationState != .active {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
                await current.end(content, dismissalPolicy: .after(.now + 6))
            } else {
                await current.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func notify(_ title: String, body: String) {
        // Only useful while the user is away from iPadn.
        guard UIApplication.shared.applicationState != .active else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            content.interruptionLevel = .timeSensitive
            center.add(UNNotificationRequest(identifier: "ipadn-pairing-code", content: content, trigger: nil))
        }
    }
}

@MainActor
private final class PairingBackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid
    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id); id = .invalid
    }
}

/// Keeps iPadn running in the background by playing silence mixed with other
/// audio: while the user pairs in Settings, and from a download to its
/// automatic installation. Runs only during those.
@MainActor
final class BackgroundKeepAlive {
    /// audiomxd holds background MediaPlayback assertions for ~5.0s after pause/stop
    /// via CMSMSleep_ExtendPlaybackProcessAssertion; ActivityKit permits background
    /// updates once that assertion invalidates (or within ActivityKit's ~30s launch grant).
    private static let mediaAssertionGraceSeconds: TimeInterval = 5.4
    private static let deliveryWindowSeconds: TimeInterval = 24.0

    private let name: String
    private var player: AVAudioPlayer?
    private var background = UIBackgroundTaskIdentifier.invalid
    private var releasedAt: Date?
    private var resumedInBackground = false
    private var activeSession = false
    private var safetyResumeTask: Task<Void, Never>?

    init(name: String) { self.name = name }

    func start() {
        safetyResumeTask?.cancel(); safetyResumeTask = nil
        releasedAt = nil
        resumedInBackground = false
        activeSession = true
        beginBackgroundTask()
        do {
            let session = AVAudioSession.sharedInstance()
            // Mixing leaves the user's music alone and adds no Now Playing entry.
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            self.player = player
        } catch {
            InstallLog.shared.add("pairing keep-alive unavailable: \(error.localizedDescription)")
        }
    }

    /// Pauses silent audio during active device-connected -> PIN handoff while keeping
    /// a finite UIBackgroundTask alive, so Live Activity updates deliver immediately
    /// without blocking on audiomxd's 5s MediaPlayback cooldown at every step.
    func pauseForHandoff(resumeAfter seconds: TimeInterval = 22) {
        guard activeSession else { return }
        safetyResumeTask?.cancel()
        beginBackgroundTask()
        if let player, player.isPlaying {
            let session = AVAudioSession.sharedInstance()
            player.pause()
            try? session.setCategory(.ambient)
            try? session.setActive(false, options: [])
            if releasedAt == nil { releasedAt = Date() }
        }
        safetyResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.resumeIfPaused()
        }
    }

    func stop() {
        activeSession = false
        resumedInBackground = false
        safetyResumeTask?.cancel(); safetyResumeTask = nil
        let wasPlaying = player?.isPlaying == true
        player?.stop(); player = nil
        if wasPlaying {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            releasedAt = Date()
        }
        endBackgroundTask()
    }

    nonisolated static func mediaAssertionWaitSeconds(
        releasedAt: Date?,
        activityStartedAt: Date,
        allowLaunchGrantBypass: Bool,
        resumedInBackground: Bool,
        now: Date = Date()
    ) -> TimeInterval {
        guard let releasedAt else { return 0 }
        if allowLaunchGrantBypass, !resumedInBackground,
           now.timeIntervalSince(activityStartedAt) < deliveryWindowSeconds {
            return 0
        }
        return max(0, mediaAssertionGraceSeconds - now.timeIntervalSince(releasedAt))
    }

    func waitUntilActivityUpdatePermitted(
        activityStartedAt: Date,
        allowLaunchGrantBypass: Bool = false,
        shouldContinue: () -> Bool = { true }
    ) async {
        guard UIApplication.shared.applicationState != .active else { return }
        if player?.isPlaying == true {
            pauseForHandoff()
        }
        guard let releasedAt else { return }
        while shouldContinue() {
            let remaining = Self.mediaAssertionWaitSeconds(
                releasedAt: releasedAt,
                activityStartedAt: activityStartedAt,
                allowLaunchGrantBypass: allowLaunchGrantBypass,
                resumedInBackground: resumedInBackground
            )
            if remaining <= 0 { break }
            let slice = min(0.1, remaining)
            try? await Task.sleep(nanoseconds: UInt64((slice * 1_000_000_000).rounded(.up)))
        }
    }

    private func resumeIfPaused() {
        guard activeSession, let player, !player.isPlaying else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            player.play()
            releasedAt = nil
            if UIApplication.shared.applicationState != .active {
                resumedInBackground = true
            }
        } catch {
            InstallLog.shared.add("pairing keep-alive resume failed: \(error.localizedDescription)")
        }
        endBackgroundTask()
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        background = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.resumeIfPaused()
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
    }

    /// One second of 8 kHz, 16-bit mono silence as a WAV file.
    private static let silence: Data = {
        let rate: UInt32 = 8000, samples: UInt32 = 8000
        let bytes = samples * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }()
}
