import Foundation

/// Cancellation and pause/resume handle shared between the UI and the transfer in flight.
public final class TFTransferHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var paused = false
    private var pauseContinuation: CheckedContinuation<Void, Error>?
    private var pausedResumeData: Data?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused && !cancelled
    }

    public func pause() {
        lock.lock()
        guard !cancelled, !paused else {
            lock.unlock()
            return
        }
        paused = true
        let task = self.task
        lock.unlock()
        task?.cancel(byProducingResumeData: { [weak self] data in
            guard let self, let data, !data.isEmpty else { return }
            self.storePausedResumeData(data)
        })
    }

    public func resume() {
        lock.lock()
        guard !cancelled, paused else {
            lock.unlock()
            return
        }
        paused = false
        let continuation = pauseContinuation
        pauseContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        paused = false
        pausedResumeData = nil
        let task = self.task
        let continuation = pauseContinuation
        pauseContinuation = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(throwing: TFError.cancelled)
    }

    func attach(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        let paused = self.paused
        lock.unlock()
        if cancelled {
            task.cancel()
        } else if paused {
            task.cancel(byProducingResumeData: { [weak self] data in
                guard let self, let data, !data.isEmpty else { return }
                self.storePausedResumeData(data)
            })
        }
    }

    func storePausedResumeData(_ data: Data) {
        lock.lock()
        if !cancelled {
            pausedResumeData = data
        }
        lock.unlock()
    }

    func takePausedResumeData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let data = pausedResumeData
        pausedResumeData = nil
        return data
    }

    public func waitWhilePaused() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: TFError.cancelled)
                    return
                }
                if !paused {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if let previous = pauseContinuation {
                    previous.resume(throwing: TFError.cancelled)
                }
                pauseContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancel()
        }
    }
}

private struct TFTransferPausedError: Error {
    let resumeData: Data?
}

/// CDN transfer with progress, pause/resume, cancellation and a bounded retry policy.
///
/// Attempt 1 is fresh. On failure the caller re-reads the install metadata: a changed URL
/// means the `accessKey` rotated, so the file is fetched again from scratch; an unchanged
/// URL falls back to `resumeData`. One more full retry is allowed, then the failure is final.
/// User-initiated pauses suspend using `resumeData` without consuming retry attempts.
public enum TFTransfer {

    public struct Outcome {
        public var bytes: Int
        public var attempts: [String]
    }

    public static func download(url: URL, to destination: URL,
                                handle: TFTransferHandle,
                                progress: @escaping @Sendable (Int64, Int64) -> Void,
                                onResume: (@Sendable () -> Void)? = nil,
                                refresh: () async throws -> URL?,
                                log: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        var attempts: [String] = []
        var resumeData: Data?
        var current = url
        var failureCount = 0

        while failureCount < 3 {
            if handle.isCancelled { throw TFError.cancelled }
            if handle.isPaused {
                try await handle.waitWhilePaused()
                if handle.isCancelled { throw TFError.cancelled }
                onResume?()
            }
            let attemptIndex = failureCount + 1
            do {
                let attempt = TFTransferAttempt(handle: handle, progress: progress)
                let (temporary, response) = try await attempt.run(url: current, resume: resumeData)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                defer { try? FileManager.default.removeItem(at: temporary) }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? -1
                attempts.append("#\(attemptIndex) ok " + String(bytes) + " B (HTTP " + String(status)
                                + (resumeData == nil ? ", fresh" : ", resumed") + ")")
                log("cdn: " + attempts.joined(separator: "; "))
                return Outcome(bytes: bytes, attempts: attempts)
            } catch let paused as TFTransferPausedError {
                if handle.isCancelled { throw TFError.cancelled }
                let captured = paused.resumeData ?? handle.takePausedResumeData()
                if let captured, !captured.isEmpty {
                    resumeData = captured
                }
                log("cdn: paused (" + (resumeData == nil ? "no resume data" : "resume data \(resumeData!.count) B") + ")")
                try await handle.waitWhilePaused()
                if handle.isCancelled { throw TFError.cancelled }
                if let late = handle.takePausedResumeData(), !late.isEmpty {
                    resumeData = late
                }
                onResume?()
                continue
            } catch {
                if handle.isCancelled { throw TFError.cancelled }
                if case TFError.cancelled = error { throw TFError.cancelled }
                failureCount += 1
                let failure = error as NSError
                resumeData = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                attempts.append("#\(failureCount) failed " + String(failure.code)
                                + (resumeData == nil ? ", no resume data" : ", resume data ok"))
                log("cdn: attempt " + String(failureCount) + " failed (" + String(failure.code) + ")"
                    + (resumeData == nil ? "" : ", have resume data"))
                if failureCount >= 3 { break }

                var renewed: URL?
                do { renewed = try await refresh() } catch { renewed = nil }
                if let renewed, renewed != current {
                    log("cdn: install refreshed, URL changed (accessKey rotated)")
                    current = renewed
                    resumeData = nil
                }
            }
        }
        throw TFError.networkLost
    }
}

/// One download attempt with `didWriteData` progress, throttled to 4 Hz.
final class TFTransferAttempt: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let handle: TFTransferHandle
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse?), Error>?
    private var session: URLSession?
    private var saved: URL?
    private var response: URLResponse?
    private var failure: Error?
    private var finished = false
    private var lastEmit: CFAbsoluteTime = 0

    init(handle: TFTransferHandle, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.handle = handle
        self.progress = progress
    }

    deinit { session?.invalidateAndCancel() }

    func run(url: URL, resume: Data?) async throws -> (URL, URLResponse?) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            let session = URLSession(configuration: TFNet.configuration(), delegate: self, delegateQueue: nil)
            self.session = session
            let task: URLSessionDownloadTask
            if let resume, !resume.isEmpty {
                task = session.downloadTask(withResumeData: resume)
            } else {
                task = session.downloadTask(with: request)
            }
            handle.attach(task)
            task.resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmit >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastEmit = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        response = downloadTask.response
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            saved = nil
            failure = TFError.http(status: http.statusCode,
                                   path: downloadTask.currentRequest?.url?.path ?? "/cdn",
                                   body: "")
            return
        }
        let copy = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".part")
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.moveItem(at: location, to: copy)
            saved = copy
        } catch {
            try? FileManager.default.removeItem(at: copy)
            saved = nil
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let saved {
                try? FileManager.default.removeItem(at: saved)
                self.saved = nil
            }
            if handle.isPaused && !handle.isCancelled {
                let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                finish(.failure(TFTransferPausedError(resumeData: data)))
            } else if (error as NSError).code == NSURLErrorCancelled || handle.isCancelled {
                finish(.failure(TFError.cancelled))
            } else {
                finish(.failure(error))
            }
            return
        }
        guard let saved else {
            finish(.failure(failure ?? TFError.networkLost))
            return
        }
        finish(.success((saved, response)))
    }

    private func finish(_ result: Result<(URL, URLResponse?), Error>) {
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        switch result {
        case let .success(value): continuation?.resume(returning: value)
        case let .failure(error): continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
