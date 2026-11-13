import ActivityKit
import AVFoundation
import Foundation
import UIKit
import UserNotifications

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
    static let hostName = "iPadn"
    static let serviceType = "_remotepairing-pairable-host._tcp."

    private var service: NetService?
    // ActivityKit is unavailable on iOS 16.0. Access the handle only in guarded methods.
    private var activity: Any?
    private let keepAlive = BackgroundKeepAlive(name: "iPadn pairing")
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        phase = .waiting
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // iPadn must keep answering while Settings is in front; a background
        // task alone ends within seconds, which stops the pairing.
        keepAlive.start()
        startActivity()
        InstallLog.shared.add("on-device pairing started (live activity: \(activity == nil ? "off" : "on"))")
        Task {
            do {
                let data = try await NativeInstaller.pair(name: Self.hostName) { [weak self] event in
                    Task { @MainActor in self?.handle(event) }
                }
                try NativeInstaller.importPairingFile(data)
                InstallLog.shared.add("on-device pairing finished")
                finish(.finished)
                if activity == nil { notify(AppText.text("配对完成"), body: AppText.text("回到 iPadn 继续。")) }
            } catch is CancellationError {
                finish(.idle)
            } catch {
                InstallLog.shared.add("on-device pairing failed: \(error.localizedDescription)")
                finish(.failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        guard running else { return }
        NativeInstaller.cancelPairing()
    }

    private func handle(_ event: NativeInstaller.PairingEvent) {
        guard running else { return }
        switch event {
        case .ready(let port, let identifier, let txt):
            advertise(port: port, identifier: identifier, txt: txt)
        case .connected:
            phase = .connected
            update(step: 2)
        case .code(let code):
            phase = .code(code)
            update(step: 3, code: code)
            // Also as a notification, for devices without Live Activities.
            notify(AppText.text("iPadn 配对码：\(code)"), body: AppText.text("在「设置」中输入这个配对码。"))
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
        service?.stop(); service = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ipadn-pairing-code"])
        keepAlive.stop()
        running = false
        self.phase = phase
        switch phase {
        case .finished: endActivity(step: 4, message: nil)
        case .failed(let message): endActivity(step: 0, message: message)
        default: endActivity(step: nil, message: nil)
        }
    }

    // MARK: Live Activity

    private func startActivity() {
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A pairing left over from an earlier run is no longer true.
        for old in Activity<PairingActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let state = PairingActivityAttributes.ContentState(step: 1)
        activity = try? Activity.request(attributes: PairingActivityAttributes(hostName: Self.hostName),
                                         content: ActivityContent(state: state, staleDate: nil))
    }

    private func update(step: Int, code: String? = nil) {
        guard #available(iOS 16.2, *), let activity = activity as? Activity<PairingActivityAttributes> else { return }
        let state = PairingActivityAttributes.ContentState(step: step, code: code)
        // An alert expands the Dynamic Island when the code arrives.
        let alert = code.map { AlertConfiguration(title: "iPadn 配对码", body: "\($0)", sound: .default) }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil), alertConfiguration: alert) }
    }

    private func endActivity(step: Int?, message: String?) {
        guard #available(iOS 16.2, *), let activity = activity as? Activity<PairingActivityAttributes> else { return }
        self.activity = nil
        Task {
            if let step {
                let state = PairingActivityAttributes.ContentState(step: step, message: message)
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 8))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func notify(_ title: String, body: String) {
        // Only useful while the user is away from iPadn.
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ipadn-pairing-code", content: content, trigger: nil))
    }
}

/// Keeps iPadn running in the background by playing silence mixed with other
/// audio: while the user pairs in Settings, and from a download to its
/// automatic installation. Runs only during those.
@MainActor
final class BackgroundKeepAlive {
    private let name: String
    private var player: AVAudioPlayer?
    private var background = UIBackgroundTaskIdentifier.invalid

    init(name: String) { self.name = name }

    func start() {
        background = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
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

    func stop() {
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        endBackgroundTask()
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
