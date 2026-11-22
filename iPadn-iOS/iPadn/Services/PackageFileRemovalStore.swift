import Foundation
import Combine

/// Stages non-download package files (standalone imported IPAs, decrypted output IPAs,
/// and unlinked output files) aside for the Undo countdown window before permanently
/// deleting them on disk.
@MainActor
final class PackageFileRemovalStore: ObservableObject {
    static let shared = PackageFileRemovalStore()

    private struct StagedRemoval {
        let token: UUID
        let originalURL: URL
        let canonicalPath: String
        let stagedURL: URL
        let outputRecordID: UUID?
        let previousOutputIdentity: String?
        let created: Date
        var timer: Task<Void, Never>?
    }

    @Published private(set) var recentlyRestoredPaths: Set<String> = []
    @Published private(set) var recentlyRestoredRecordIDs: Set<UUID> = []

    private var pendingRemovals: [UUID: StagedRemoval] = [:]
    private let supportDirectory: URL
    private let expiryLeadSeconds: TimeInterval
    private let canRestoreOutput: @MainActor () -> Bool
    private let readOutputIdentity: @MainActor (UUID) -> String?
    private let writeOutputIdentity: @MainActor (UUID, String?) -> Void
    private let onChanged: @MainActor () -> Void
    nonisolated private static let stagingPrefix = "pkg-removing-"

    init(
        supportDirectory: URL = LocalResources.support,
        expiryLeadSeconds: TimeInterval = UndoNotice.duration + 0.5,
        sweepOnInit: Bool = true,
        canRestoreOutput: @escaping @MainActor () -> Bool = { !FairPlayHub.shared.service.isRunning },
        readOutputIdentity: @escaping @MainActor (UUID) -> String? = { id in
            DecryptRecordStore.shared.records.first(where: { $0.id == id })?.outputIdentity
        },
        writeOutputIdentity: @escaping @MainActor (UUID, String?) -> Void = { id, identity in
            DecryptRecordStore.shared.update(id: id) { $0.outputIdentity = identity }
        },
        onChanged: @escaping @MainActor () -> Void = { FairPlayPresentation.shared.markFilesChanged() }
    ) {
        self.supportDirectory = supportDirectory
        self.expiryLeadSeconds = expiryLeadSeconds
        self.canRestoreOutput = canRestoreOutput
        self.readOutputIdentity = readOutputIdentity
        self.writeOutputIdentity = writeOutputIdentity
        self.onChanged = onChanged
        if sweepOnInit {
            sweepOrphanedRemovals()
        }
    }

    /// Moves a standalone or unlinked IPA file aside for the undo window.
    func removeFileReversibly(at url: URL) throws -> (token: UUID, created: Date)? {
        try stageRemoval(at: url, outputRecordID: nil)
    }

    /// Moves a decrypted output IPA aside for the undo window while marking its
    /// `DecryptRecord.outputIdentity` as `"removed"` so it disappears immediately
    /// from the outputs list and restores cleanly on Undo.
    func removeDecryptOutputReversibly(recordID: UUID, fileURL: URL) throws -> (token: UUID, created: Date)? {
        try stageRemoval(at: fileURL, outputRecordID: recordID)
    }

    private func stageRemoval(at url: URL, outputRecordID: UUID?) throws -> (token: UUID, created: Date)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            if let recordID = outputRecordID {
                writeOutputIdentity(recordID, "removed")
                onChanged()
            }
            return nil
        }

        let canonical = PackageOutputPolicy.canonicalPath(url)
        let previousIdentity = outputRecordID.flatMap { readOutputIdentity($0) }
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let token = UUID()
        let created = Date()
        let ext = url.pathExtension.isEmpty ? "ipa" : url.pathExtension
        let stagedURL = supportDirectory.appendingPathComponent("\(Self.stagingPrefix)\(token.uuidString).\(ext)")
        if fm.fileExists(atPath: stagedURL.path) {
            try? fm.removeItem(at: stagedURL)
        }
        try fm.moveItem(at: url, to: stagedURL)

        if let recordID = outputRecordID {
            writeOutputIdentity(recordID, "removed")
            recentlyRestoredRecordIDs.remove(recordID)
        }
        recentlyRestoredPaths.remove(canonical)

        var entry = StagedRemoval(
            token: token,
            originalURL: url,
            canonicalPath: canonical,
            stagedURL: stagedURL,
            outputRecordID: outputRecordID,
            previousOutputIdentity: previousIdentity,
            created: created,
            timer: nil
        )
        entry.timer = makeExpiryTimer(for: token, delay: expiryLeadSeconds)
        pendingRemovals[token] = entry
        onChanged()
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
        var seen = Set<UUID>()
        let unique = tokens.filter { seen.insert($0).inserted }
        let hasOutput = unique.contains { pendingRemovals[$0]?.outputRecordID != nil }
        if hasOutput && !canRestoreOutput() {
            throw ToolError.message(AppText.text("当前已有解密任务正在进行，请等待完成后再试。"))
        }

        let fm = FileManager.default
        var restoredAny = false
        for token in unique.reversed() {
            guard let entry = pendingRemovals.removeValue(forKey: token) else { continue }
            entry.timer?.cancel()
            guard fm.fileExists(atPath: entry.stagedURL.path) else { continue }

            let parent = entry.originalURL.deletingLastPathComponent()
            if fm.fileExists(atPath: entry.originalURL.path) {
                // Never overwrite a newer file that appeared at the original path.
                let staged = entry.stagedURL
                Task.detached(priority: .utility) { try? FileManager().removeItem(at: staged) }
                continue
            }

            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.moveItem(at: entry.stagedURL, to: entry.originalURL)
            } catch {
                var restoredEntry = entry
                let remaining = max(0.5, entry.created.addingTimeInterval(expiryLeadSeconds).timeIntervalSinceNow)
                restoredEntry.timer = makeExpiryTimer(for: token, delay: remaining)
                pendingRemovals[token] = restoredEntry
                throw error
            }

            if let recordID = entry.outputRecordID {
                let restoredIdentity: String?
                if let prev = entry.previousOutputIdentity {
                    restoredIdentity = PackageOutputPolicy.matches(prev, url: entry.originalURL)
                        ? prev
                        : PackageOutputPolicy.identity(entry.originalURL)
                } else {
                    restoredIdentity = nil
                }
                if readOutputIdentity(recordID) == "removed" {
                    writeOutputIdentity(recordID, restoredIdentity)
                }
                recentlyRestoredRecordIDs.insert(recordID)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1600))
                    self?.recentlyRestoredRecordIDs.remove(recordID)
                }
            }

            let path = entry.canonicalPath
            recentlyRestoredPaths.insert(path)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1600))
                self?.recentlyRestoredPaths.remove(path)
            }
            restoredAny = true
        }

        if restoredAny {
            onChanged()
        }
    }

    func sweepOrphanedRemovals() {
        let activeNames = Set(pendingRemovals.values.map { $0.stagedURL.lastPathComponent })
        let support = supportDirectory
        Task.detached(priority: .utility) {
            Self.sweepOrphanedRemovalsSync(in: support, activeNames: activeNames)
        }
    }

    nonisolated static func sweepOrphanedRemovalsSync(in support: URL, activeNames: Set<String> = []) {
        let fm = FileManager()
        guard let entries = try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(stagingPrefix) && !activeNames.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }

    private func makeExpiryTimer(for token: UUID, delay: TimeInterval) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, let entry = self.pendingRemovals.removeValue(forKey: token) else { return }
            let staged = entry.stagedURL
            Task.detached(priority: .utility) {
                try? FileManager().removeItem(at: staged)
            }
        }
    }
}
