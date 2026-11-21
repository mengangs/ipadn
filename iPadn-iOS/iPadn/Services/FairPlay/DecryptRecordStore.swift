import Foundation
import Combine

/// Persistent log of decryption attempts. Metadata only: pruning a record never
/// deletes an IPA, and a record whose file vanished stays visible as such.
@MainActor
final class DecryptRecordStore: ObservableObject {
    static let shared = DecryptRecordStore()

    @Published private(set) var records: [DecryptRecord] = []
    private(set) var cacheRevision: Int = 0

    private let limit = 50
    private var loaded = false
    private let fileManager = FileManager.default
    private let persistQueue = DispatchQueue(label: "iPadn.decrypt-records", qos: .utility)
    private var outputURLCache: [String: URL?] = [:]
    private var sourceURLCache: [String: URL?] = [:]
    private var iconURLCache: [String: URL?] = [:]

    func invalidateFileCaches() {
        outputURLCache.removeAll(keepingCapacity: true)
        sourceURLCache.removeAll(keepingCapacity: true)
        iconURLCache.removeAll(keepingCapacity: true)
        cacheRevision &+= 1
    }

    private var storeURL: URL {
        FairPlayEnvironment.documentsDirectory.appendingPathComponent("fairplay-records.json")
    }

    var outputDirectory: URL {
        FairPlayEnvironment.documentsDirectory.appendingPathComponent("Decrypted", isDirectory: true)
    }

    private var iconDirectory: URL {
        FairPlayEnvironment.documentsDirectory.appendingPathComponent("DecryptIcons", isDirectory: true)
    }

    // MARK: - lifecycle

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode([DecryptRecord].self, from: data) else {
            // Keep the broken file for inspection, start clean rather than
            // showing half-decoded data.
            try? fileManager.moveItem(at: storeURL,
                                      to: storeURL.deletingLastPathComponent()
                                          .appendingPathComponent("fairplay-records.corrupt.json"))
            return
        }
        // A run cannot survive the process: never present it as still running.
        var needsPersist = false
        for index in decoded.indices where decoded[index].state == .running {
            decoded[index].state = .interrupted
            decoded[index].failure = DecryptFailure(
                kind: .interrupted,
                title: AppText.text("任务被中断"),
                reason: AppText.text("解密进行中时应用被关闭，这次任务没有完成。"),
                advice: AppText.text("重新发起一次解密；原 IPA 没有被修改，可以直接复用。"),
                details: "interrupted at launch"
            )
            decoded[index].finishedAt = decoded[index].finishedAt ?? Date()
            needsPersist = true
        }
        decoded.sort { $0.startedAt > $1.startedAt }
        if decoded.count > limit { needsPersist = true }
        records = Array(decoded.prefix(limit))
        invalidateFileCaches()
        if needsPersist { persist() }
    }

    // MARK: - queries

    func record(for jobID: UUID) -> DecryptRecord? {
        records.first { $0.sourceJobID == jobID }
    }

    func record(forSourceName name: String, bytes: Int) -> DecryptRecord? {
        records.first { $0.sourceName == name && $0.sourceBytes == bytes }
    }

    func latestFinished(forJobID jobID: UUID) -> DecryptRecord? {
        records.first { $0.sourceJobID == jobID && ($0.state == .finished || $0.state == .plain) }
    }

    private static func safeBasename(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              trimmed != ".",
              trimmed != ".." else { return nil }
        return trimmed
    }

    func outputURL(for record: DecryptRecord) -> URL? {
        guard let name = Self.safeBasename(record.outputName) else { return nil }
        if let cached = outputURLCache[name] { return cached }
        let url = outputDirectory.appendingPathComponent(name)
        let resolved: URL? = fileManager.fileExists(atPath: url.path) ? url : nil
        outputURLCache[name] = resolved
        return resolved
    }

    func sourceURL(for record: DecryptRecord) -> URL? {
        guard let name = Self.safeBasename(record.sourceName) else { return nil }
        let cacheKey = "\(name)|\(record.bundleID ?? "")"
        if let cached = sourceURLCache[cacheKey] { return cached }
        let docs = FairPlayEnvironment.documentsDirectory
        let tfRoot = docs.appendingPathComponent("TestFlight", isDirectory: true)
        let stem = Self.safeBasename((name as NSString).deletingPathExtension)
        let bundle = Self.safeBasename(record.bundleID)
        var candidates: [URL] = [
            docs.appendingPathComponent(name),
            docs.appendingPathComponent("Packages", isDirectory: true)
                .appendingPathComponent(name),
        ]
        for b in [bundle, stem].compactMap({ $0 }) {
            let bundleDir = tfRoot.appendingPathComponent(b, isDirectory: true)
            candidates.append(bundleDir.appendingPathComponent(name))
            if let subdirs = try? fileManager.contentsOfDirectory(
                at: bundleDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for sub in subdirs {
                    candidates.append(sub.appendingPathComponent(name))
                }
            }
        }
        if let hit = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            sourceURLCache[cacheKey] = hit
            return hit
        }
        if let dirs = try? fileManager.contentsOfDirectory(
            at: tfRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in dirs {
                let direct = dir.appendingPathComponent(name)
                if fileManager.fileExists(atPath: direct.path) {
                    sourceURLCache[cacheKey] = direct
                    return direct
                }
                if let subdirs = try? fileManager.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for sub in subdirs {
                        let nested = sub.appendingPathComponent(name)
                        if fileManager.fileExists(atPath: nested.path) {
                            sourceURLCache[cacheKey] = nested
                            return nested
                        }
                    }
                }
            }
        }
        sourceURLCache[cacheKey] = nil
        return nil
    }

    func iconURL(for record: DecryptRecord) -> URL? {
        guard let name = Self.safeBasename(record.iconName) else { return nil }
        if let cached = iconURLCache[name] { return cached }
        let url = iconDirectory.appendingPathComponent(name)
        let resolved: URL? = fileManager.fileExists(atPath: url.path) ? url : nil
        iconURLCache[name] = resolved
        return resolved
    }

    var runningRecord: DecryptRecord? { records.first { $0.state == .running } }

    // MARK: - mutation

    func upsert(_ record: DecryptRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records.sort { $0.startedAt > $1.startedAt }
        if records.count > limit { records = Array(records.prefix(limit)) }
        invalidateFileCaches()
        persist()
        pruneUnusedIcons()
    }

    func update(id: UUID, _ body: (inout DecryptRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
        invalidateFileCaches()
        persist()
    }

    /// Removes the record only; the IPA on disk is untouched.
    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        invalidateFileCaches()
        persist()
        pruneUnusedIcons()
    }

    /// Removes all inactive records while keeping IPA files on disk intact.
    func removeInactive(keeping activeID: UUID?) {
        records.removeAll { $0.id != activeID && $0.state != .running }
        invalidateFileCaches()
        persist()
        pruneUnusedIcons()
    }

    private func pruneUnusedIcons() {
        let keep = Set(records.compactMap(\.iconName))
        let directory = iconDirectory
        persistQueue.async {
            let fm = FileManager()
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for url in entries where !keep.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Caches the icon extracted from an IPA so the workbench does not re-read
    /// a 200 MB archive on every appearance.
    func storeIcon(_ data: Data, for recordID: UUID) -> String? {
        let name = "\(recordID.uuidString).png"
        let target = iconDirectory.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            iconURLCache[name] = target
            return name
        } catch {
            return nil
        }
    }

    // MARK: - persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(records) else { return }
        let destination = storeURL
        let temporary = destination.appendingPathExtension("tmp")
        persistQueue.async {
            let fm = FileManager()
            do {
                if !fm.fileExists(atPath: destination.path) {
                    // A fresh installation has no destination to replace yet.
                    try data.write(to: destination, options: .atomic)
                    return
                }
                try data.write(to: temporary, options: .atomic)
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } catch {
                try? fm.removeItem(at: temporary)
            }
        }
    }
}
