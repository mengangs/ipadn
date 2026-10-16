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

    /// Where a downloaded package is kept until the update is installed: not
    /// Caches, which iOS may empty when storage runs low.
    static var packageFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AppUpdate", isDirectory: true)
    }
    static func packageFile(for release: AppRelease) -> URL {
        packageFolder.appendingPathComponent("iPadn-\(release.version).ipa")
    }
    /// The release's package if it was downloaded completely before.
    static func downloadedPackage(for release: AppRelease) -> URL? {
        let file = packageFile(for: release)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.int64Value > 0, release.packageSize <= 0 || size.int64Value == release.packageSize else { return nil }
        return file
    }
    /// Removes kept packages, for example once the update is installed.
    static func removeDownloads() {
        try? FileManager.default.removeItem(at: packageFolder)
    }

    /// Downloads the release's IPA and keeps it in `packageFolder`, replacing older versions.
    static func download(_ release: AppRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = release.package else { throw ToolError.message("这个版本没有可下载的安装包") }
        try Task.checkCancellation()
        // Its own folder while downloading; moved into place once complete.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloader = Downloader(target: folder.appendingPathComponent("iPadn.ipa"), progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let downloaded: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
        removeDownloads()
        var kept = packageFolder
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        // A package that can be downloaded again does not belong in device backups.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? kept.setResourceValues(values)
        let target = packageFile(for: release)
        try FileManager.default.moveItem(at: downloaded, to: target)
        return target
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

    /// TrollStore installs an IPA from a link through this URL scheme. Without
    /// TrollStore the system Magnifier app answers it, so offer it only when
    /// TrollStore installed iPadn.
    static func trollStoreURL(for release: AppRelease) -> URL? {
        guard let package = release.package?.absoluteString,
              let encoded = package.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "apple-magnifier://install?url=" + encoded)
    }
    /// TrollStore leaves a marker file next to the bundles it installs.
    static var installedByTrollStore: Bool {
        let container = Bundle.main.bundleURL.deletingLastPathComponent()
        return ["_TrollStore", "_TrollStoreLite"].contains {
            FileManager.default.fileExists(atPath: container.appendingPathComponent($0).path)
        }
    }

    /// A piece of the release notes as the update page shows it.
    enum NoteBlock: Equatable {
        case heading(String), bullet(String), paragraph(String)
    }
    /// The Markdown release notes as headings, bullets and paragraphs. The
    /// title naming the version is left out: the page already shows it.
    static func blocks(_ notes: String, version: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        for raw in notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if text.isEmpty || (blocks.isEmpty && text.hasSuffix(version)) { continue }
                blocks.append(.heading(text))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }
}
