#if DEBUG
import Foundation
import UIKit

/// Headless driver for the FairPlay research build. It runs the *same*
/// `FairPlayService` the download page uses, so a headless run exercises the
/// product path (phases, cancellation, verification) without taps.
///
/// Triggers (first match wins):
///   * `--fp-env`    → environment report only;
///   * `--fp-lab`    → decrypt the newest `*.ipa` in Documents;
///   * `--fp-lab=/container/path/app.ipa` → that file;
///   * a marker file `fp-lab.on` in Documents.
///
/// Results: `Documents/Decrypted/<name>-decrypted.ipa` and `Documents/fp-lab.log`.
enum FairPlayLab {

    private static let stateLock = NSLock()
    private static var running = false
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var documents: URL { FairPlayEnvironment.documentsDirectory }
    static var markerURL: URL { documents.appendingPathComponent("fp-lab.on") }
    static var logURL: URL { documents.appendingPathComponent("fp-lab.log") }

    @discardableResult
    static func handleLaunchIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let wantsEnvironment = arguments.contains("--fp-env")
        let inspect = arguments.first(where: { $0.hasPrefix("--fp-inspect=") })
            .map { String($0.dropFirst("--fp-inspect=".count)) }
        let explicit = arguments.first(where: { $0.hasPrefix("--fp-lab=") })
            .map { String($0.dropFirst("--fp-lab=".count)) }
        let wantsLab = arguments.contains("--fp-lab") || explicit != nil
            || FileManager.default.fileExists(atPath: markerURL.path)
        guard wantsEnvironment || wantsLab || inspect != nil else { return false }

        if let inspect {
            let url = URL(fileURLWithPath: inspect)
            Task { await Task.detached { IPAInspector.debugReport(url: url) }.value.forEach { append(FairPlayLine(kind: .info, text: $0)) } }
            return true
        }
        Task { await run(explicitPath: explicit, environmentOnly: wantsEnvironment && !wantsLab) }
        return true
    }

    // MARK: - logging

    static func append(_ line: FairPlayLine) {
        NSLog("[FPLab] %@", line.rendered)
        let text = "\(timestamp()) \(line.rendered)\n"
        guard let data = text.data(using: .utf8) else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) != nil {
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    // MARK: - run

    private static func tryBeginRun() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return false }
        running = true
        try? FileManager.default.removeItem(at: logURL)
        return true
    }

    private static func finishRun() {
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    @MainActor
    static func run(explicitPath: String?, environmentOnly: Bool) async {
        guard tryBeginRun() else { return }

        beginUtilities()
        defer { endUtilities() }

        append(FairPlayLine(kind: .phase, text: "== FairPlay lab =="))
        for line in FairPlayEnvironment.describe() { append(line) }
        if environmentOnly { return }

        let target: URL?
        if let explicitPath, !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: explicitPath)
            target = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            target = FairPlayDecryptor.candidateIPAs().first
        }
        guard let ipa = target else {
            append(FairPlayLine(kind: .fail,
                            text: "no IPA at that path — pass the app-visible absolute path, e.g. " + documents.path + "/<name>.ipa"))
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int64) ?? 0
        append(FairPlayLine(kind: .info, text: "target: \(ipa.path) (\(size) B)"))

        // The product service, not a private path: phases, cancellation and the
        // post-pack verification are the ones users get.
        let service = FairPlayHub.shared.service
        service.start(source: ipa, displayName: ipa.deletingPathExtension().lastPathComponent)

        var mirrored = 0
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(600))
            if service.lines.count > mirrored {
                for line in service.lines[mirrored...] { append(line) }
                mirrored = service.lines.count
            }
            if service.phase != .running { break }
        }
        // Flush whatever arrived after the last poll.
        if service.lines.count > mirrored {
            for line in service.lines[mirrored...] { append(line) }
        }

        switch service.phase {
        case .finished, .failed:
            append(FairPlayLine(kind: service.phase == .finished ? .ok : .fail,
                text: "done: decrypted=\(service.counts.decrypted) plain=\(service.counts.plain) "
                    + "failed=\(service.counts.failed) in \(String(format: "%.1f", service.elapsed))s"))
            if let verification = service.verification {
                append(FairPlayLine(kind: verification.isClean ? .ok : .fail,
                                    text: "verify: \(verification.summary)"))
            } else {
                append(FairPlayLine(kind: .warn, text: "verify: no report"))
            }
            if let output = service.resultURL {
                append(FairPlayLine(kind: .ok, text: "output: \(output.path)"))
            }
            if let error = service.errorText { append(FairPlayLine(kind: .fail, text: error)) }
        case .cancelled:
            append(FairPlayLine(kind: .warn, text: "cancelled"))
        default:
            append(FairPlayLine(kind: .fail, text: "timed out"))
        }
        finishRun()
        try? FileManager.default.removeItem(at: markerURL)
    }

    private static func beginUtilities() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FairPlayLab") {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    private static func endUtilities() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    // MARK: - UI test hooks

    /// Device-test only: stage a completed download and (optionally) open the
    /// decryption sheet, so the real download page can be driven by taps without
    /// an Apple ID download. Never active without `--fp-ui`.
    @discardableResult
    static func handleUITestLaunch(store: ToolStore) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argument = arguments.first(where: { $0.hasPrefix("--fp-ui") }) else { return false }
        let openSheet = argument.contains("=sheet")
        let clean = argument.contains("=clean") || openSheet
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            store.selectTab(.downloads)
            if clean {
                let ids = Set(store.downloads.jobs.map(\.id))
                if !ids.isEmpty { _ = try? await store.downloads.removeBatch(ids) }
            }
            guard let ipa = FairPlayDecryptor.candidateIPAs().first else { return }
            let alreadyImported = store.downloads.jobs.contains {
                $0.status == .completed && $0.app.name == ipa.deletingPathExtension().lastPathComponent
            }
            if !alreadyImported { try? await store.downloads.importFile(ipa) }
            if openSheet {
                FairPlayHub.shared.start(source: ipa,
                                         displayName: ipa.deletingPathExtension().lastPathComponent)
            }
        }
        return true
    }
}

#endif
