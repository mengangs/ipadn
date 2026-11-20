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

    @Published private(set) var items: [TFProductItem] = []
    private var refreshTask: Task<Void, Never>?

    private init() {}

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

    /// Deletes a TestFlight IPA on disk and synchronizes `TestFlightHomeView`, `DownloadsView`,
    /// and `PackagesView` immediately.
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
