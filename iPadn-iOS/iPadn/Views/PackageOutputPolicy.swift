import Foundation

/// Presentation-side file safety, deliberately independent of the decryptor.
enum PackageOutputPolicy {
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    static func unlinkedOutputs(in directory: URL, knownOutputs: [URL], fileManager: FileManager = .default) -> [URL] {
        unlinkedOutputs(in: directory, knownOutputPaths: Set(knownOutputs.map(canonicalPath)), fileManager: fileManager)
    }
    static func unlinkedOutputs(in directory: URL, knownOutputPaths: Set<String>, fileManager: FileManager = .default) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == "ipa" && !knownOutputPaths.contains(canonicalPath($0)) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func candidates(source: URL, directory: URL) -> [URL] {
        let stem = source.deletingPathExtension().lastPathComponent
        return ["-decrypted.ipa", "-PARTIAL.ipa"].map { directory.appendingPathComponent(stem + $0) }
    }
    static func existing(source: URL, directory: URL) -> [URL] {
        candidates(source: source, directory: directory).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func identity(_ url: URL) -> String {
        // Construct a fresh file URL so Darwin Foundation never returns stale
        // cached size/mtime values after a file at the same URL is replaced.
        #if canImport(Darwin)
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        #else
        let fresh = URL(fileURLWithPath: url.path)
        #endif
        let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        return "\(fresh.lastPathComponent)#\(values?.fileSize ?? -1)#\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)#\(String(describing: values?.fileResourceIdentifier))"
    }
    static func matches(_ saved: String, url: URL) -> Bool {
        let current = identity(url)
        // First UI checkpoint included a sandbox path. Accept its portable
        // suffix, never use a changing app-container UUID as file identity.
        return saved == current || saved.hasSuffix("/" + current)
    }
}
