import Foundation
import Combine

/// Persistent log of decryption attempts. Metadata only: pruning a record never
/// deletes an IPA, and a record whose file vanished stays visible as such.
@MainActor
final class DecryptRecordStore: ObservableObject {
    static let shared = DecryptRecordStore()

    @Published private(set) var records: [DecryptRecord] = []

    private let limit = 50
    private var loaded = false
    private let fileManager = FileManager.default

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
        for index in decoded.indices where decoded[index].state == .running {
            decoded[index].state = .interrupted
            decoded[index].failure = DecryptFailure(
                kind: .interrupted,
                title: "任务被中断",
                reason: "解密进行中时应用被关闭，这次任务没有完成。",
                advice: "重新发起一次解密；原 IPA 没有被修改，可以直接复用。",
                details: "interrupted at launch"
            )
            decoded[index].finishedAt = decoded[index].finishedAt ?? Date()
        }
        decoded.sort { $0.startedAt > $1.startedAt }
        records = Array(decoded.prefix(limit))
        persist()
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
        let url = outputDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func sourceURL(for record: DecryptRecord) -> URL? {
        guard let name = Self.safeBasename(record.sourceName) else { return nil }
        let candidates = [
            FairPlayEnvironment.documentsDirectory.appendingPathComponent(name),
            FairPlayEnvironment.documentsDirectory
                .appendingPathComponent("Packages", isDirectory: true)
                .appendingPathComponent(name),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    func iconURL(for record: DecryptRecord) -> URL? {
        guard let name = Self.safeBasename(record.iconName) else { return nil }
        let url = iconDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
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
        persist()
        pruneUnusedIcons()
    }

    func update(id: UUID, _ body: (inout DecryptRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
        persist()
    }

    /// Removes the record only; the IPA on disk is untouched.
    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
        pruneUnusedIcons()
    }

    /// Removes all inactive records while keeping IPA files on disk intact.
    func removeInactive(keeping activeID: UUID?) {
        records.removeAll { $0.id != activeID && $0.state != .running }
        persist()
        pruneUnusedIcons()
    }

    private func pruneUnusedIcons() {
        let keep = Set(records.compactMap(\.iconName))
        guard let entries = try? fileManager.contentsOfDirectory(at: iconDirectory, includingPropertiesForKeys: nil) else { return }
        for url in entries where !keep.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Caches the icon extracted from an IPA so the workbench does not re-read
    /// a 200 MB archive on every appearance.
    func storeIcon(_ data: Data, for recordID: UUID) -> String? {
        let name = "\(recordID.uuidString).png"
        do {
            try fileManager.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
            try data.write(to: iconDirectory.appendingPathComponent(name), options: .atomic)
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
        let temporary = storeURL.appendingPathExtension("tmp")
        do {
            if !fileManager.fileExists(atPath: storeURL.path) {
                // A fresh installation has no destination to replace yet.
                try data.write(to: storeURL, options: .atomic)
                return
            }
            try data.write(to: temporary, options: .atomic)
            _ = try fileManager.replaceItemAt(storeURL, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
        }
    }
}
