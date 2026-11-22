import Foundation
import Combine

/// Drives one "decrypt and export" run for the UI: phases, progress, log tail,
/// cancellation and the verification report of the exported IPA.
@MainActor
final class FairPlayService: ObservableObject {

    enum Phase: String {
        case idle, running, finished, failed, cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step = ""
    @Published private(set) var fraction: Double = 0
    @Published private(set) var detail = ""
    @Published private(set) var lines: [FairPlayLine] = []
    @Published private(set) var resultURL: URL?
    @Published private(set) var verification: FairPlayVerification?
    @Published private(set) var errorText: String?
    /// Structured version of `errorText`: title, reason, advice and a collapsed
    /// technical detail, so the UI never has to parse prose.
    @Published private(set) var failure: DecryptFailure?
    @Published private(set) var sourceName = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var counts: (decrypted: Int, plain: Int, failed: Int) = (0, 0, 0)
    /// Record of the current run, created up-front so the workbench can show it
    /// immediately even before the first progress callback arrives.
    @Published private(set) var activeRecordID: UUID?

    /// Decrypt right after a download finishes (one tap on the row is the
    /// default; this makes it automatic).
    @Published var autoDecryptOnComplete: Bool {
        didSet { UserDefaults.standard.set(autoDecryptOnComplete, forKey: Self.autoKey) }
    }

    private static let autoKey = "fairplay.autoDecrypt"
    private static let logQueue = DispatchQueue(label: "iPadn.fairplay-log", qos: .utility)
    private var cancelFlag = CancelFlag()
    private var task: Task<Void, Never>?
    /// Paths already handled automatically, so a re-render does not restart.
    private(set) var autoHandled: Set<String> = []

    init() {
        autoDecryptOnComplete = UserDefaults.standard.bool(forKey: Self.autoKey)
    }

    var isRunning: Bool { phase == .running }

    var canExport: Bool { resultURL != nil && phase != .running }

    /// Starts a run; ignored while another one is in flight.
    func start(source: URL, displayName: String,
               appName: String? = nil, jobID: UUID? = nil,
               origin: DecryptRecord.Origin = .manual) {
        guard !isRunning else { return }
        reset()
        let logURL = FairPlayEnvironment.documentsDirectory.appendingPathComponent("fairplay-last.log")
        Self.logQueue.async {
            try? FileManager().removeItem(at: logURL)
        }
        phase = .running
        sourceName = displayName
        step = "准备中"
        detail = source.path

        // Record first: the workbench reads records, so it must exist before the
        // first progress tick, not after the run finishes.
        let bytes = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        let record = DecryptRecord(sourceJobID: jobID,
                                   sourceName: source.lastPathComponent,
                                   sourceBytes: bytes,
                                   appName: appName ?? displayName,
                                   isTestFlight: source.path.contains("/TestFlight/") ? true : nil,
                                   state: .running,
                                   origin: origin)
        DecryptRecordStore.shared.upsert(record)
        activeRecordID = record.id

        let flag = CancelFlag()
        cancelFlag = flag
        let started = Date()

        final class LineBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var collected: [FairPlayLine] = []
            func append(_ line: FairPlayLine) {
                lock.lock(); collected.append(line); lock.unlock()
            }
            func snapshot() -> [FairPlayLine] {
                lock.lock(); defer { lock.unlock() }
                return collected
            }
        }
        let logBuffer = LineBuffer()

        task = Task { [weak self] in
            let outcome: Result<FairPlayDecryptor.Outcome, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let value = try FairPlayDecryptor.decrypt(
                            ipaURL: source,
                            allowBundleStaging: false,
                            isCancelled: { flag.isCancelled },
                            report: { progress in
                                Task { @MainActor [weak self] in self?.apply(progress) }
                            },
                            log: { line in
                                logBuffer.append(line)
                                Task { @MainActor [weak self] in self?.append(line) }
                            }
                        )
                        continuation.resume(returning: .success(value))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(started)
            let recordedLines = logBuffer.snapshot()
            if recordedLines.count > self.lines.count {
                self.lines = Array(recordedLines.suffix(400))
            }
            let allLogTexts = recordedLines.map(\.text)
            switch outcome {
            case .success(let value):
                self.resultURL = value.outputURL
                self.verification = value.verification
                self.counts = (value.decrypted, value.plain, value.failed)
                self.fraction = 1
                self.step = "完成"
                self.detail = value.outputURL.lastPathComponent
                let clean = value.verification?.isClean ?? false
                let untouched = value.decrypted == 0 && value.failed == 0
                self.phase = clean && !untouched ? .finished : (untouched ? .finished : .failed)
                if untouched {
                    self.failure = DecryptFailureMapper.alreadyPlain(details: value.verification?.summary)
                } else if !clean {
                    let summary = value.verification?.summary ?? "产物未通过校验"
                    self.failure = value.failed > 0
                        ? DecryptFailureMapper.partial(decrypted: value.decrypted,
                                                       failed: value.failed,
                                                       summary: summary,
                                                       heuristicRejected: value.heuristicRejected)
                        : DecryptFailureMapper.verificationFailure(summary: summary, details: nil)
                    self.errorText = self.failure?.reason
                }
                self.finishRecord(with: value, clean: clean, untouched: untouched)
                self.append(FairPlayLine(kind: clean ? .ok : .warn,
                    text: "done: decrypted=\(value.decrypted) plain=\(value.plain) failed=\(value.failed) "
                        + "machO=\(value.machO) in \(String(format: "%.1f", value.elapsed))s"))
            case .failure(let error):
                if let fpError = error as? FairPlayDecryptor.Failure, case .alreadyPlain = fpError {
                    let mapped = DecryptFailureMapper.alreadyPlain(details: nil)
                    self.phase = .finished
                    self.fraction = 1
                    self.step = "完成"
                    self.failure = mapped
                    if let id = self.activeRecordID {
                        DecryptRecordStore.shared.update(id: id) { record in
                            record.verification = .none
                            record.failure = mapped
                            record.state = .plain
                            record.finishedAt = Date()
                        }
                    }
                    self.append(FairPlayLine(kind: .ok, text: "done: package is already unencrypted (plain)"))
                    return
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let cancelled = flag.isCancelled
                    || (error as? FairPlayDecryptor.Failure).map { if case .cancelled = $0 { return true } else { return false } } == true
                let mapped = DecryptFailureMapper.map(error: error, logLines: allLogTexts)
                if cancelled {
                    self.phase = .cancelled
                    self.step = "已取消"
                } else {
                    self.phase = .failed
                    self.errorText = message
                    self.step = "失败"
                }
                self.failure = mapped
                self.failRecord(reason: mapped, cancelled: cancelled)
                self.append(FairPlayLine(kind: .fail, text: message))
            }
        }
    }

    func cancel() {
        cancelFlag.cancel()
        step = "正在取消…"
    }

    func reset() {
        cancelFlag.cancel()
        task?.cancel()
        task = nil
        cancelFlag = CancelFlag()
        phase = .idle
        step = ""
        fraction = 0
        detail = ""
        lines = []
        resultURL = nil
        verification = nil
        errorText = nil
        failure = nil
        activeRecordID = nil
        elapsed = 0
        counts = (0, 0, 0)
    }

    /// Called when a download row becomes completed and auto mode is on.
    /// The caller is responsible for the 专业模式 gate: switching it off must not
    /// stop a run that is already going, but no new run may start.
    func autoStartIfNeeded(source: URL, displayName: String,
                           appName: String? = nil, jobID: UUID? = nil) {
        guard autoDecryptOnComplete, !isRunning else { return }
        let key = source.path
        guard !autoHandled.contains(key) else { return }
        autoHandled.insert(key)
        start(source: source, displayName: displayName,
              appName: appName, jobID: jobID, origin: .automatic)
    }

    // MARK: - records

    private func finishRecord(with value: FairPlayDecryptor.Outcome, clean: Bool, untouched: Bool) {
        guard let id = activeRecordID else { return }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: value.outputURL.path)[.size] as? NSNumber)?.intValue
        DecryptRecordStore.shared.update(id: id) { record in
            record.outputName = value.outputURL.lastPathComponent
            record.outputBytes = bytes
            record.counts = DecryptCounts(decrypted: value.decrypted, plain: value.plain,
                                          failed: value.failed, machO: value.machO)
            record.verification = untouched ? .none : (clean ? .clean : (value.failed > 0 ? .partial : .failed))
            record.verificationSummary = value.verification?.summary
            record.failure = self.failure
            record.state = untouched ? .plain : (clean ? .finished : .failed)
            record.finishedAt = Date()
        }
    }

    private func failRecord(reason: DecryptFailure, cancelled: Bool) {
        guard let id = activeRecordID else { return }
        DecryptRecordStore.shared.update(id: id) { record in
            record.state = cancelled ? .cancelled : .failed
            record.failure = reason
            record.finishedAt = Date()
        }
    }

    // MARK: - updates

    private func apply(_ progress: FairPlayProgress) {
        guard isRunning else { return }
        if progress.phase != step { step = progress.phase }
        if abs(progress.fraction - fraction) > 0.004 || progress.detail != detail {
            fraction = min(max(progress.fraction, 0), 1)
            detail = progress.detail
        }
    }

    private func append(_ line: FairPlayLine) {
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        // Mirror to a file so a run started by hand can be inspected afterwards
        // without a debugger. Always sanitize and use throwing Swift FileHandle APIs
        // so ENOSPC or file-protection locks never raise an uncatchable NSException.
        let text = DiagnosticRedactor.sanitize(line.rendered) + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let url = FairPlayEnvironment.documentsDirectory.appendingPathComponent("fairplay-last.log")
        Self.logQueue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) != nil {
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
        }
    }
}

/// Locked boolean shared with the worker queue.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func reset() {
        lock.lock(); cancelled = false; lock.unlock()
    }
}
