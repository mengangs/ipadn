import Foundation

/// Cancellation handle shared between the UI and the transfer in flight.
public final class TFTransferHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func attach(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { task.cancel() }
    }
}

/// CDN transfer with progress, cancellation and a bounded retry policy.
///
/// Attempt 1 is fresh. On failure the caller re-reads the install metadata: a changed URL
/// means the `accessKey` rotated, so the file is fetched again from scratch; an unchanged
/// URL falls back to `resumeData`. One more full retry is allowed, then the failure is final.
public enum TFTransfer {

    public struct Outcome {
        public var bytes: Int
        public var attempts: [String]
    }

    public static func download(url: URL, to destination: URL,
                                handle: TFTransferHandle,
                                progress: @escaping @Sendable (Int64, Int64) -> Void,
                                refresh: () async throws -> URL?,
                                log: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        var attempts: [String] = []
        var resumeData: Data?
        var current = url

        for index in 1...3 {
            if handle.isCancelled { throw TFError.cancelled }
            do {
                let attempt = TFTransferAttempt(handle: handle, progress: progress)
                let (temporary, response) = try await attempt.run(url: current,
                                                                  resume: index == 1 ? nil : resumeData)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? -1
                attempts.append("#\(index) ok " + String(bytes) + " B (HTTP " + String(status)
                                + (index == 1 ? ", fresh" : ", resumed") + ")")
                log("cdn: " + attempts.joined(separator: "; "))
                return Outcome(bytes: bytes, attempts: attempts)
            } catch {
                if handle.isCancelled { throw TFError.cancelled }
                if case TFError.cancelled = error { throw TFError.cancelled }
                let failure = error as NSError
                resumeData = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                attempts.append("#\(index) failed " + String(failure.code)
                                + (resumeData == nil ? ", no resume data" : ", resume data ok"))
                log("cdn: attempt " + String(index) + " failed (" + String(failure.code) + ")"
                    + (resumeData == nil ? "" : ", have resume data"))
                if index == 3 { break }

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
        let copy = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".part")
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.moveItem(at: location, to: copy)
            saved = copy
        } catch {
            saved = nil
            failure = error
        }
        response = downloadTask.response
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled || handle.isCancelled {
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
