import Foundation

/// A published iPadn release on GitHub.
struct AppRelease: Codable, Equatable {
    var version: String
    var notes: String
    var page: URL
    /// The unsigned IPA; sign it with the tool used to install iPadn.
    var package: URL?
    var packageSize: Int64
    var published: Date?
}

enum AppUpdateService {
    static let repository = "mengangs/ipadn"
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The latest published release, or nil when GitHub could not be reached.
    static func latest() async -> AppRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iPadn/" + currentVersion, forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(result.0)
    }

    static func parse(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.first?.isNumber == true else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let ipa = assets.first { ($0["name"] as? String)?.hasSuffix(".ipa") == true }
        let published = (json["published_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return AppRelease(version: version, notes: notes(json["body"] as? String ?? ""), page: page,
                          package: (ipa?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                          packageSize: (ipa?["size"] as? NSNumber)?.int64Value ?? 0, published: published)
    }

    /// The release notes for people: without the build's verification line.
    static func notes(_ body: String) -> String {
        body.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("验证：") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A release newer than the running app, if `release` is one.
    static func newer(_ release: AppRelease?, than current: String = currentVersion) -> AppRelease? {
        guard let release, VersionOrder.isNewer(release.version, than: current) else { return nil }
        return release
    }

    /// Downloads the release's IPA to a temporary file named after it.
    static func download(_ release: AppRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = release.package else { throw ToolError.message("这个版本没有可下载的安装包") }
        try Task.checkCancellation()
        // Its own folder, so a second download never replaces a file being shared.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("iPadn-\(release.version).ipa")
        let downloader = Downloader(target: target, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let target: URL
        let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var pending: CheckedContinuation<URL, Error>?
        private var reported = -1
        var continuation: CheckedContinuation<URL, Error>? {
            get { lock.withLock { pending } }
            set { lock.withLock { pending = newValue } }
        }
        init(target: URL, progress: @escaping @Sendable (Double) -> Void) { self.target = target; self.progress = progress }
        private func finish(_ result: Result<URL, Error>) {
            let waiting: CheckedContinuation<URL, Error>? = lock.withLock { defer { pending = nil }; return pending }
            waiting?.resume(with: result)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            // Whole percents only: the screen doesn't need thousands of updates.
            let percent = Int(fraction * 100)
            guard lock.withLock({ () -> Bool in
                guard percent != reported else { return false }
                reported = percent; return true
            }) else { return }
            progress(fraction)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                finish(.failure(ToolError.message("下载失败，请稍后重试"))); return
            }
            // The file is gone once this returns: move it now.
            do {
                try FileManager.default.moveItem(at: location, to: target)
                finish(.success(target))
            } catch { finish(.failure(error)) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }
    }

    /// TrollStore installs an IPA from a link through this URL scheme.
    static func trollStoreURL(for release: AppRelease) -> URL? {
        guard let package = release.package?.absoluteString,
              let encoded = package.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "apple-magnifier://install?url=" + encoded)
    }
}
