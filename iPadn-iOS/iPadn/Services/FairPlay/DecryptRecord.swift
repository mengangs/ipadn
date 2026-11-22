import Foundation

/// How much of an IPA is encrypted. `unknown` is a real answer: a partial read,
/// an odd ZIP layout or a binary whose load commands do not fit in the bytes we
/// can safely read must never be reported as "not encrypted".
enum EncryptionState: String, Codable, Sendable {
    case encrypted, plain, unknown
}

struct BinaryEncryption: Codable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let state: EncryptionState
    /// One entry per slice (`cryptid` as found in LC_ENCRYPTION_INFO[_64]).
    let cryptids: [Int32]
}

struct IPADetection: Codable, Sendable {
    var state: EncryptionState = .unknown
    var binaries: [BinaryEncryption] = []
    var note: String?
    var checkedAt = Date()

    var encryptedCount: Int { binaries.filter { $0.state == .encrypted }.count }
    var plainCount: Int { binaries.filter { $0.state == .plain }.count }
    var unknownCount: Int { binaries.filter { $0.state == .unknown }.count }
}

enum DecryptRecordState: String, Codable, Sendable {
    case running, finished, failed, cancelled, interrupted, plain
}

enum DecryptVerificationResult: String, Codable, Sendable {
    case clean, partial, failed, none
}

struct DecryptCounts: Codable, Sendable, Equatable {
    var decrypted = 0
    var plain = 0
    var failed = 0
    var machO = 0
}

/// Structured failure: a title, a plain-language reason, one actionable next
/// step, and technical details that stay collapsed unless asked for.
struct DecryptFailure: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case fairplayDenied
        case accountMismatchSuspected
        case familySharingSuspected
        case sinfMissing
        case sinfUnreadable
        case sinfMismatchSuspected
        case ipaCorrupt
        case ipaIncomplete
        case appGroupUnavailable
        case unsupportedBinary
        case unsupportedSystem
        case storageFull
        case writeFailed
        case packFailed
        case sourceVanished
        case exportFailed
        case cancelled
        case interrupted
        case alreadyPlain
        case partial
        case verifyFailed
        case taskConflict
        case unknown
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var reason: String
    var advice: String
    /// False when the cause can only be suspected (account mismatch, family
    /// sharing, untested system version): the UI prefixes such text with "可能".
    var isCertain: Bool = true
    var details: String?
    var errno: Int32?
}

/// One decryption attempt, persisted so the workbench survives relaunches.
/// Only metadata lives here: never an Apple ID, password, token or SINF payload.
struct DecryptRecord: Codable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable {
        case manual, automatic, imported
    }

    var id = UUID()
    var sourceJobID: UUID?
    var sourceName: String
    var sourceBytes: Int
    var appName: String
    var bundleID: String?
    var version: String?
    /// File name inside Documents/DecryptIcons.
    var iconName: String?
    /// File name inside Documents/Decrypted.
    var outputName: String?
    var outputBytes: Int?
    /// UI provenance only: prevents an old attempt claiming a subsequently
    /// replaced file. Optional for checkpoint-era record compatibility.
    var outputIdentity: String?
    /// True when the source IPA came from a TestFlight download so decrypted
    /// outputs and history retain the TestFlight indicator even after removing
    /// the original IPA.
    var isTestFlight: Bool? = nil
    var state: DecryptRecordState = .running
    var counts = DecryptCounts()
    var verification: DecryptVerificationResult = .none
    var verificationSummary: String?
    var detection: IPADetection?
    var failure: DecryptFailure?
    var origin: Origin = .manual
    var startedAt = Date()
    var finishedAt: Date?

    /// Correlates a download job / imported file with the record even when the
    /// job id changed (re-import of the same file).
    var fingerprint: String { "\(sourceName)#\(sourceBytes)" }

    var isTerminal: Bool {
        switch state {
        case .running: return false
        default: return true
        }
    }

    var statusText: String {
        switch state {
        case .running: return "解密中"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        case .plain: return "无需解密"
        }
    }
}
