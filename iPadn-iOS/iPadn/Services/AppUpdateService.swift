import Foundation

/// A published iPadn release on GitHub.
struct AppRelease: Codable, Equatable {
    enum Variant: String, CaseIterable, Codable, Identifiable {
        case standard
        case lite
        var id: String { rawValue }
    }

    var version: String
    var notes: String
    var page: URL
    /// Standard unsigned IPA (includes Live Activity / widget extension).
    var package: URL?
    var packageSize: Int64
    /// Lite unsigned IPA (extension stripped, needs only 1 App ID).
    var litePackage: URL?
    var litePackageSize: Int64
    var published: Date?

    init(
        version: String,
        notes: String,
        page: URL,
        package: URL?,
        packageSize: Int64,
        litePackage: URL? = nil,
        litePackageSize: Int64 = 0,
        published: Date?
    ) {
        self.version = version
        self.notes = notes
        self.page = page
        self.package = package
        self.packageSize = packageSize
        self.litePackage = litePackage
        self.litePackageSize = litePackageSize
        self.published = published
    }

    private enum CodingKeys: String, CodingKey {
        case version, notes, page, package, packageSize, litePackage, litePackageSize, published
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        notes = try c.decode(String.self, forKey: .notes)
        page = try c.decode(URL.self, forKey: .page)
        package = try c.decodeIfPresent(URL.self, forKey: .package)
        packageSize = try c.decodeIfPresent(Int64.self, forKey: .packageSize) ?? 0
        litePackage = try c.decodeIfPresent(URL.self, forKey: .litePackage)
        litePackageSize = try c.decodeIfPresent(Int64.self, forKey: .litePackageSize) ?? 0
        published = try c.decodeIfPresent(Date.self, forKey: .published)
    }

    var hasBothVariants: Bool { package != nil && litePackage != nil }
    var hasAnyPackage: Bool { package != nil || litePackage != nil }

    func url(for variant: Variant) -> URL? {
        switch variant {
        case .standard: return package ?? litePackage
        case .lite: return litePackage ?? package
        }
    }

    func size(for variant: Variant) -> Int64 {
        switch variant {
        case .standard: return package != nil ? packageSize : litePackageSize
        case .lite: return litePackage != nil ? litePackageSize : packageSize
        }
    }
}

enum AppUpdateService {
    static let repository = "mengangs/ipadn"
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Detects whether the currently running iPadn bundle embeds the Live Activity extension.
    static var installedVariant: AppRelease.Variant {
        if let plugIns = Bundle.main.builtInPlugInsURL,
           FileManager.default.fileExists(atPath: plugIns.appendingPathComponent("iPadnLiveActivity.appex").path) {
            return .standard
        }
        return .lite
    }

    /// Preferred default variant for `release` based on the running installation.
    static func defaultVariant(for release: AppRelease, preferred: AppRelease.Variant = installedVariant) -> AppRelease.Variant {
        switch preferred {
        case .standard:
            return release.package != nil ? .standard : .lite
        case .lite:
            return release.litePackage != nil ? .lite : .standard
        }
    }

    /// API first, then the public release feed. Diagnostics contain metadata only.
    @MainActor
    static func latest(session: URLSession = .shared, report: (String) -> Void = { _ in }) async -> AppRelease? {
        let sources = [
            ("api", "https://api.github.com/repos/\(repository)/releases/latest", "application/vnd.github+json"),
            ("feed", "https://github.com/\(repository)/releases.atom", "application/atom+xml")
        ]
        var diagnostics: [String] = []
        for (source, address, accept) in sources {
            guard let url = URL(string: address) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue(accept, forHTTPHeaderField: "Accept")
            request.setValue("iPadn/" + currentVersion, forHTTPHeaderField: "User-Agent")
            do {
                let (data, rawResponse) = try await session.data(for: request)
                guard let response = rawResponse as? HTTPURLResponse else {
                    diagnostics.append("source=\(source); error=non-http"); report(diagnostics.joined(separator: "\n")); continue
                }
                var metadata = "source=\(source); http=\(response.statusCode); format=\(ApplePropertyList.format(data)); bytes=\(data.count)"
                if response.statusCode == 429 || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                    metadata += "; rate-limited=true"
                }
                if response.statusCode == 200, let release = source == "api" ? parse(data) : AppReleaseFeed.parse(data) {
                    diagnostics.append(metadata + "; result=valid")
                    report(diagnostics.joined(separator: "\n"))
                    return release
                }
                diagnostics.append(metadata + "; result=unusable")
            } catch is CancellationError {
                diagnostics.append("source=\(source); cancelled"); report(diagnostics.joined(separator: "\n")); return nil
            } catch {
                diagnostics.append("source=\(source); " + AppleAuthentication.errorCode(error))
                if (error as? URLError)?.code == .cancelled { report(diagnostics.joined(separator: "\n")); return nil }
            }
            report(diagnostics.joined(separator: "\n"))
        }
        return nil
    }

    private static func isLiteAssetName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("-lite.") || lower.contains("-lite-")
    }

    static func parse(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.first?.isNumber == true else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let ipas = assets.filter { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
        let standard = ipas.first { !isLiteAssetName($0["name"] as? String ?? "") }
        let lite = ipas.first { isLiteAssetName($0["name"] as? String ?? "") }
        let published = (json["published_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return AppRelease(
            version: version,
            notes: notes(json["body"] as? String ?? ""),
            page: page,
            package: (standard?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            packageSize: (standard?["size"] as? NSNumber)?.int64Value ?? 0,
            litePackage: (lite?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            litePackageSize: (lite?["size"] as? NSNumber)?.int64Value ?? 0,
            published: published
        )
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
    static func packageFile(for release: AppRelease, variant: AppRelease.Variant = .standard) -> URL {
        let suffix = variant == .lite ? "-lite" : ""
        return packageFolder.appendingPathComponent("iPadn-\(release.version)\(suffix).ipa")
    }
    /// The release's package if it was downloaded completely before.
    static func downloadedPackage(for release: AppRelease, variant: AppRelease.Variant = .standard) -> URL? {
        let file = packageFile(for: release, variant: variant)
        let expected = release.size(for: variant)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.int64Value > 0, expected <= 0 || size.int64Value == expected else { return nil }
        return file
    }
    /// Removes kept packages, for example once the update is installed.
    static func removeDownloads() {
        try? FileManager.default.removeItem(at: packageFolder)
    }

    /// Downloads the release's IPA and keeps it in `packageFolder`, pruning older release files.
    static func download(
        _ release: AppRelease,
        variant: AppRelease.Variant = .standard,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let url = release.url(for: variant) else { throw ToolError.message(AppText.text("这个版本没有可下载的安装包")) }
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
                downloader.start(session: session, url: url, continuation: continuation)
            }
        } onCancel: {
            downloader.cancel(session: session)
        }
        var kept = packageFolder
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        // Remove stale packages from earlier versions while keeping sibling variant of current release.
        let versionPrefix = "iPadn-\(release.version)"
        if let existing = try? FileManager.default.contentsOfDirectory(at: kept, includingPropertiesForKeys: nil) {
            for item in existing where !item.lastPathComponent.hasPrefix(versionPrefix) {
                try? FileManager.default.removeItem(at: item)
            }
        }
        // A package that can be downloaded again does not belong in device backups.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? kept.setResourceValues(values)
        let target = packageFile(for: release, variant: variant)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: downloaded, to: target)
        return target
    }

    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let target: URL
        let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var pending: CheckedContinuation<URL, Error>?
        private var cancelled = false
        private var reported = -1
        func start(session: URLSession, url: URL, continuation: CheckedContinuation<URL, Error>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            pending = continuation
            let task = session.downloadTask(with: url)
            lock.unlock()
            task.resume()
        }
        func cancel(session: URLSession) {
            lock.lock()
            cancelled = true
            let waiting = pending
            pending = nil
            lock.unlock()
            session.invalidateAndCancel()
            waiting?.resume(throwing: CancellationError())
        }
        init(target: URL, progress: @escaping @Sendable (Double) -> Void) { self.target = target; self.progress = progress }
        private func finish(_ result: Result<URL, Error>) {
            let waiting: CheckedContinuation<URL, Error>? = lock.withLock { defer { pending = nil }; return pending }
            waiting?.resume(with: result)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
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
                finish(.failure(ToolError.message(AppText.text("下载失败，请稍后重试")))); return
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
    static func trollStoreURL(for release: AppRelease, variant: AppRelease.Variant = .standard) -> URL? {
        guard let package = release.url(for: variant)?.absoluteString,
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
