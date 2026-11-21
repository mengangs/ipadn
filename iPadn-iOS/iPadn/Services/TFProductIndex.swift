import Foundation
import Combine

#if canImport(TestFlightKit)
import TestFlightKit

/// One locally downloaded TestFlight IPA indexed directly from `Documents/TestFlight/<bundle>/<bundle>.ipa`.
/// Read-only projection for DownloadsView & PackagesView — never creates a `DownloadJob` or duplicates files.
struct TFProductItem: Identifiable, Equatable {
    var id: String { bundleID }
    let appID: String
    let bundleID: String
    let displayName: String
    let shortVersion: String
    let buildVersion: String
    let fileURL: URL
    let fileSize: Int64
    let modifiedAt: Date
    let iconURL: URL?
    let iconColors: TFIconColors?

    var versionBuildLabel: String {
        let short = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty && !build.isEmpty {
            return "v\(short) (\(build))"
        }
        if !short.isEmpty { return "v\(short)" }
        if !build.isEmpty { return "Build \(build)" }
        return ""
    }

    /// Compact label for narrow rows (e.g. DownloadsView): drops long build numbers when
    /// combined version+build exceeds 10 characters so file size never truncates on the right.
    var compactVersionLabel: String {
        let short = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty && !build.isEmpty {
            let full = "v\(short) (\(build))"
            return full.count <= 10 ? full : "v\(short)"
        }
        if !short.isEmpty { return "v\(short)" }
        if !build.isEmpty { return "Build \(build)" }
        return ""
    }

    var betaApp: TFBetaApp {
        TFBetaApp(
            id: appID,
            name: displayName,
            bundleID: bundleID,
            latestVersion: shortVersion.isEmpty ? nil : shortVersion,
            buildCount: 1,
            developerName: nil
        )
    }
}

/// Read-only index of downloaded TestFlight products on disk (`Documents/TestFlight/*/*.ipa`).
/// Keeps `DownloadsView`, `PackagesView`, and `TestFlightHomeView` synchronized without touching
/// `DownloadManager`'s `DownloadJob` model.
@MainActor
final class TFProductIndex: ObservableObject {
    static let shared = TFProductIndex()

    private struct StagedRemoval {
        let token: UUID
        let item: TFProductItem
        let originalDir: URL
        let stagedDir: URL
        let created: Date
        var timer: Task<Void, Never>?
    }

    @Published private(set) var items: [TFProductItem] = []
    @Published private(set) var recentlyRestoredBundleIDs: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var pendingRemovals: [UUID: StagedRemoval] = [:]
    private static let stagingPrefix = "tf-removing-"

    private init() {
        sweepOrphanedRemovals()
    }

    func item(forFile url: URL) -> TFProductItem? {
        let canonical = PackageOutputPolicy.canonicalPath(url)
        return items.first { PackageOutputPolicy.canonicalPath($0.fileURL) == canonical }
    }

    func refresh() {
        refreshTask?.cancel()
        let productMap = UserDefaults.standard.dictionary(forKey: "tf.products") as? [String: String] ?? [:]
        refreshTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) { () -> [TFProductItem] in
                Self.scanOnDisk(productMap: productMap)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.items = scanned
        }
    }

    /// Moves a TestFlight product directory aside for the undo window so the user can restore
    /// it immediately via `UndoNotice`, then permanently removes it once the window expires.
    func removeReversibly(_ item: TFProductItem) throws -> (token: UUID, created: Date)? {
        guard let bundleRoot = TFDownload.directoryURL(bundle: item.bundleID) else {
            delete(item)
            return nil
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundleRoot.path) else {
            delete(item)
            return nil
        }
        // Clean transient scratch files inside the bundle folder before staging.
        try? fm.removeItem(at: bundleRoot.appendingPathComponent(".work", isDirectory: true))
        for suffix in ["-transport.bin", "-base.ipa", "-applezip.ipa"] {
            try? fm.removeItem(at: bundleRoot.appendingPathComponent(item.bundleID + suffix))
        }
        LocalResources.ensureDirectoriesExist()
        let token = UUID()
        let created = Date()
        let stagedDir = LocalResources.support.appendingPathComponent(Self.stagingPrefix + token.uuidString, isDirectory: true)
        if fm.fileExists(atPath: stagedDir.path) {
            try? fm.removeItem(at: stagedDir)
        }
        try fm.moveItem(at: bundleRoot, to: stagedDir)

        items.removeAll { $0.bundleID == item.bundleID }
        recentlyRestoredBundleIDs.remove(item.bundleID)
        TFHomeModel.shared.didDeleteProduct(appID: item.appID, bundleID: item.bundleID)
        FairPlayPresentation.shared.markFilesChanged()

        var entry = StagedRemoval(
            token: token,
            item: item,
            originalDir: bundleRoot,
            stagedDir: stagedDir,
            created: created,
            timer: nil
        )
        entry.timer = makeExpiryTimer(for: token, delay: UndoNotice.duration + 0.5)
        pendingRemovals[token] = entry
        return (token, created)
    }

    func extendRemovalUndo(_ tokens: [UUID], until deadline: Date) {
        let delay = max(0.5, deadline.timeIntervalSinceNow + 0.5)
        for token in tokens {
            guard var entry = pendingRemovals[token] else { continue }
            entry.timer?.cancel()
            entry.timer = makeExpiryTimer(for: token, delay: delay)
            pendingRemovals[token] = entry
        }
    }

    func undoRemovalGroup(_ tokens: [UUID]) throws {
        var restoredAny = false
        for token in tokens.reversed() {
            guard let entry = pendingRemovals.removeValue(forKey: token) else { continue }
            entry.timer?.cancel()
            let fm = FileManager.default
            guard fm.fileExists(atPath: entry.stagedDir.path) else { continue }
            let parent = entry.originalDir.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: entry.originalDir.path) {
                // If a fresh download replaced it, keep the newer download and discard staged copy.
                let staged = entry.stagedDir
                Task.detached(priority: .utility) { try? FileManager().removeItem(at: staged) }
                continue
            }
            try fm.moveItem(at: entry.stagedDir, to: entry.originalDir)
            if !items.contains(where: { $0.bundleID == entry.item.bundleID }) {
                items.append(entry.item)
            }
            let bundleID = entry.item.bundleID
            recentlyRestoredBundleIDs.insert(bundleID)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1600))
                self?.recentlyRestoredBundleIDs.remove(bundleID)
            }
            restoredAny = true
        }
        if restoredAny {
            items.sort { $0.modifiedAt > $1.modifiedAt }
            TFHomeModel.shared.loadProducts()
            FairPlayPresentation.shared.markFilesChanged()
            refresh()
        }
    }

    private func makeExpiryTimer(for token: UUID, delay: TimeInterval) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, let entry = self.pendingRemovals.removeValue(forKey: token) else { return }
            let staged = entry.stagedDir
            Task.detached(priority: .utility) {
                try? FileManager().removeItem(at: staged)
            }
        }
    }

    private func sweepOrphanedRemovals() {
        let activeNames = Set(pendingRemovals.keys.map { Self.stagingPrefix + $0.uuidString })
        let support = LocalResources.support
        Task.detached(priority: .utility) {
            let fm = FileManager()
            guard let entries = try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil) else { return }
            for url in entries where url.lastPathComponent.hasPrefix(Self.stagingPrefix) && !activeNames.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Permanently deletes a TestFlight IPA on disk and synchronizes `TestFlightHomeView`,
    /// `DownloadsView`, and `PackagesView` immediately.
    func delete(_ item: TFProductItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        let buildDir = item.fileURL.deletingLastPathComponent()
        if buildDir.lastPathComponent != item.bundleID {
            try? FileManager.default.removeItem(at: buildDir)
        }
        // Also remove any other remaining build directories for this bundle so deletion is complete.
        for product in TFProducts.all(bundle: item.bundleID) {
            try? FileManager.default.removeItem(at: product.ipa)
            try? FileManager.default.removeItem(at: product.directory)
        }
        if let bundleRoot = try? TFDownload.directory(bundle: item.bundleID) {
            try? FileManager.default.removeItem(at: bundleRoot.appendingPathComponent(".work", isDirectory: true))
            for suffix in [".ipa", "-transport.bin", "-base.ipa", "-applezip.ipa"] {
                try? FileManager.default.removeItem(at: bundleRoot.appendingPathComponent(item.bundleID + suffix))
            }
        }
        items.removeAll { $0.bundleID == item.bundleID }
        TFHomeModel.shared.didDeleteProduct(appID: item.appID, bundleID: item.bundleID)
        FairPlayPresentation.shared.markFilesChanged()
        refresh()
    }

    nonisolated private static func scanOnDisk(productMap: [String: String]) -> [TFProductItem] {
        _ = TFProducts.migrateFlatLayout()
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let tfRoot = docs.appendingPathComponent("TestFlight", isDirectory: true)
        guard let folders = try? fm.contentsOfDirectory(
            at: tfRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Reverse map bundleID -> appID from UserDefaults("tf.products") and cached v3 details.
        var bundleToAppID: [String: String] = [:]
        for (appID, bundle) in productMap where !bundle.isEmpty {
            bundleToAppID[bundle.lowercased()] = appID
        }
        var detailsByBundle: [String: TFAppDetail] = [:]
        let cacheDir = tfRoot.appendingPathComponent("cache", isDirectory: true)
        if let cacheFiles = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in cacheFiles where file.lastPathComponent.hasPrefix("detail-") && file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let detail = try? JSONDecoder().decode(TFAppDetail.self, from: data),
                   !detail.bundleID.isEmpty {
                    let key = detail.bundleID.lowercased()
                    detailsByBundle[key] = detail
                    if bundleToAppID[key] == nil {
                        bundleToAppID[key] = detail.appID
                    }
                }
            }
        }

        let skipDirs: Set<String> = ["cache", "debug", "icons"]
        var found: [TFProductItem] = []

        for folder in folders {
            let bundle = folder.lastPathComponent
            if skipDirs.contains(bundle.lowercased()) { continue }
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let flatIPA = folder.appendingPathComponent(bundle + ".ipa")
            guard let ipa = TFProducts.newest(bundle: bundle)?.ipa
                ?? (fm.fileExists(atPath: flatIPA.path) ? flatIPA : nil) else { continue }

            let attrs = try? fm.attributesOfItem(atPath: ipa.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast

            let key = bundle.lowercased()
            let detail = detailsByBundle[key]
            let appID = bundleToAppID[key] ?? detail?.appID ?? bundle
            let installMeta = TFAPI.cachedInstallMetadata(bundle: bundle)
            let inspected = try? PackageService.inspect(ipa)

            // Priority: installMetadata framework.displayName -> IPA localized CFBundleDisplayName -> v3 detail.name -> bundle
            let displayName: String = {
                if let fwName = installMeta?.displayName, !fwName.isEmpty { return fwName }
                if let ipaName = inspected?.name, !ipaName.isEmpty, ipaName != bundle { return ipaName }
                if let detailName = detail?.name, !detailName.isEmpty { return detailName }
                return inspected?.name ?? bundle
            }()

            let shortVersion = installMeta?.shortVersion
                ?? (inspected?.version.isEmpty == false ? inspected?.version : nil)
                ?? (detail?.shortVersion.isEmpty == false ? detail?.shortVersion : nil)
                ?? ""

            let buildVersion = installMeta?.buildVersion
                ?? (inspected?.bundleVersion?.isEmpty == false ? inspected?.bundleVersion : nil)
                ?? (detail?.buildVersion.isEmpty == false ? detail?.buildVersion : nil)
                ?? ""

            let iconURL = TFIcon.cached(appID: appID)
            let iconColors = detail?.iconAsset?.colors ?? TFIcon.cachedAsset(appID: appID)?.colors

            found.append(TFProductItem(
                appID: appID,
                bundleID: bundle,
                displayName: displayName,
                shortVersion: shortVersion,
                buildVersion: buildVersion,
                fileURL: ipa,
                fileSize: size,
                modifiedAt: modified,
                iconURL: iconURL,
                iconColors: iconColors
            ))
        }

        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
#endif
