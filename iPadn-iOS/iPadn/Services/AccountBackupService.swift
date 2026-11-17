import Foundation
#if canImport(CryptoKit) && canImport(CommonCrypto)
import CryptoKit
import CommonCrypto
import Security
#endif

/// Persisted App Store device provisioning record bound to a GUID.
struct StoreProofRecord: Codable, Equatable, Sendable {
    var identifier: String
    var files: [String: String]
    var updatedAt: Date = Date()
}

/// Non-sensitive multi-account profile backup entry (v1/v2 legacy format).
/// Never stores passwords, tokens, cookies, DSID, or device trust state.
struct AccountProfileEntry: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var storeFront: String
    var fullStoreFront: String

    init(id: String, name: String = "", storeFront: String = "", fullStoreFront: String = "") {
        self.id = id
        self.name = name
        self.storeFront = storeFront
        self.fullStoreFront = fullStoreFront
    }

    init(from account: AppleAccount) {
        self.id = account.id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storeFront = account.storeFront.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullStoreFront = account.fullStoreFront.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, storeFront, fullStoreFront
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw AccountBackupError.invalidAccountEntry
        }
        self.id = trimmedID
        self.name = (try container.decodeIfPresent(String.self, forKey: .name) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.storeFront = (try container.decodeIfPresent(String.self, forKey: .storeFront) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullStoreFront = (try container.decodeIfPresent(String.self, forKey: .fullStoreFront) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var placeholderAccount: AppleAccount {
        AppleAccount(
            id: id,
            name: name.isEmpty ? id : name,
            password: "",
            cookie: "",
            dsid: "",
            passwordToken: "",
            storeFront: storeFront,
            fullStoreFront: fullStoreFront
        )
    }
}

/// Full portable Apple account entry including session cookies, tokens, DSID, and password.
/// Also wraps legacy credential-less `AccountProfileEntry` so import/merge follows one code path.
struct AccountSessionEntry: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var password: String
    var cookie: String
    var dsid: String
    var passwordToken: String
    var storeFront: String
    var fullStoreFront: String

    init(
        id: String,
        name: String = "",
        password: String = "",
        cookie: String = "",
        dsid: String = "",
        passwordToken: String = "",
        storeFront: String = "",
        fullStoreFront: String = ""
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        self.cookie = cookie
        self.dsid = dsid.trimmingCharacters(in: .whitespacesAndNewlines)
        self.passwordToken = passwordToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storeFront = storeFront.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullStoreFront = fullStoreFront.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from account: AppleAccount, effectiveCookie: String? = nil) {
        self.init(
            id: account.id,
            name: account.name,
            password: account.password,
            cookie: effectiveCookie ?? account.cookie,
            dsid: account.dsid,
            passwordToken: account.passwordToken,
            storeFront: account.storeFront,
            fullStoreFront: account.fullStoreFront
        )
    }

    init(from profile: AccountProfileEntry) {
        self.init(
            id: profile.id,
            name: profile.name,
            storeFront: profile.storeFront,
            fullStoreFront: profile.fullStoreFront
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, password, cookie, dsid, passwordToken, storeFront, fullStoreFront
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw AccountBackupError.invalidAccountEntry
        }
        self.id = trimmedID
        self.name = (try container.decodeIfPresent(String.self, forKey: .name) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.cookie = try container.decodeIfPresent(String.self, forKey: .cookie) ?? ""
        self.dsid = (try container.decodeIfPresent(String.self, forKey: .dsid) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.passwordToken = (try container.decodeIfPresent(String.self, forKey: .passwordToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.storeFront = (try container.decodeIfPresent(String.self, forKey: .storeFront) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.fullStoreFront = (try container.decodeIfPresent(String.self, forKey: .fullStoreFront) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasValidSession: Bool {
        !dsid.isEmpty && !passwordToken.isEmpty
    }

    var hasCookie: Bool {
        !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAnyCredential: Bool {
        hasValidSession || hasCookie || !password.isEmpty
    }

    var credentialPriority: Int {
        (hasValidSession ? 4 : 0) + (hasCookie ? 2 : 0) + (!password.isEmpty ? 1 : 0)
    }

    var appleAccount: AppleAccount {
        AppleAccount(
            id: id,
            name: name.isEmpty ? id : name,
            password: password,
            cookie: cookie,
            dsid: dsid,
            passwordToken: passwordToken,
            storeFront: storeFront,
            fullStoreFront: fullStoreFront
        )
    }

    var profileEntry: AccountProfileEntry {
        AccountProfileEntry(
            id: id,
            name: name,
            storeFront: storeFront,
            fullStoreFront: fullStoreFront
        )
    }
}

/// Phase 1 non-sensitive Apple ID configuration backup container (kept for v1 decode compatibility).
struct AccountProfileBackup: Codable, Equatable {
    static let schemaIdentifier = "app.ipadn.account-profiles"
    static let currentFormat = 1
    static let supportedKind = "profile"
    static let maxImportBytes = 5 * 1024 * 1024

    var schema: String = Self.schemaIdentifier
    var format: Int = Self.currentFormat
    var kind: String = Self.supportedKind
    var app: String
    var created: Date
    var preferredActiveID: String?
    var accounts: [AccountProfileEntry]

    private enum CodingKeys: String, CodingKey {
        case schema, format, kind, app, created, preferredActiveID, accounts
    }

    init(
        app: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        created: Date = Date(),
        preferredActiveID: String? = nil,
        accounts: [AccountProfileEntry]
    ) {
        self.app = app
        self.created = created
        let trimmedActive = preferredActiveID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredActiveID = trimmedActive?.isEmpty == true ? nil : trimmedActive
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? ""
        self.format = try container.decode(Int.self, forKey: .format)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? Self.supportedKind
        self.app = try container.decodeIfPresent(String.self, forKey: .app) ?? ""
        self.created = try container.decodeIfPresent(Date.self, forKey: .created) ?? Date.distantPast
        let rawActive = try container.decodeIfPresent(String.self, forKey: .preferredActiveID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredActiveID = rawActive?.isEmpty == true ? nil : rawActive
        self.accounts = try container.decode([AccountProfileEntry].self, forKey: .accounts)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> AccountProfileBackup {
        guard data.count <= maxImportBytes else {
            throw AccountBackupError.fileTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountBackupError.invalidFormat
        }
        if object["settings"] != nil && object["favorites"] != nil {
            throw AccountBackupError.wrongBackupKindSettings
        }
        if let kind = object["kind"] as? String, kind != supportedKind {
            if ["encrypted", "vault", "secrets"].contains(kind.lowercased()) {
                throw AccountBackupError.encryptedUnsupported
            }
            throw AccountBackupError.invalidFormat
        }
        if object["sealedBox"] != nil || object["cipher"] != nil {
            throw AccountBackupError.encryptedUnsupported
        }
        guard let schema = object["schema"] as? String, schema == schemaIdentifier,
              let format = object["format"] as? Int else {
            throw AccountBackupError.invalidFormat
        }
        guard format >= 1 else {
            throw AccountBackupError.invalidFormat
        }
        guard format <= currentFormat else {
            throw AccountBackupError.unsupportedVersion
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw: AccountProfileBackup
        do {
            raw = try decoder.decode(AccountProfileBackup.self, from: data)
        } catch let backupError as AccountBackupError {
            throw backupError
        } catch {
            throw AccountBackupError.invalidAccountEntry
        }

        let deduplicated = try AccountBackupService.deduplicatedEntries(from: raw.accounts)
        guard !deduplicated.isEmpty else {
            throw AccountBackupError.emptyAccounts
        }
        return AccountProfileBackup(
            app: raw.app,
            created: raw.created,
            preferredActiveID: raw.preferredActiveID,
            accounts: deduplicated
        )
    }
}

/// Password-protected AES-256-GCM + PBKDF2-HMAC-SHA256 container for full backups.
struct EncryptedBackupEnvelope: Codable, Equatable {
    static let schemaIdentifier = "app.ipadn.encrypted-backup"
    static let currentFormat = 1
    static let supportedKind = "encrypted"
    static let supportedKDF = "pbkdf2-hmac-sha256"
    static let supportedCipher = "aes-256-gcm"
    static let defaultIterations = 210_000
    static let minIterations = 10_000
    static let maxIterations = 2_000_000

    var schema: String = Self.schemaIdentifier
    var format: Int = Self.currentFormat
    var kind: String = Self.supportedKind
    var kdf: String = Self.supportedKDF
    var iterations: Int = Self.defaultIterations
    var salt: String
    var cipher: String = Self.supportedCipher
    var payload: String

    static func isEncryptedEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (object["schema"] as? String) == schemaIdentifier
    }
}

enum BackupCrypto {
    private static let associatedData = Data("app.ipadn.encrypted-backup.v1".utf8)

    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        guard !password.isEmpty else {
            throw AccountBackupError.emptyPassword
        }
        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
            throw AccountBackupError.encryptionFailed
        }
        let key = try deriveKey(password: password, salt: Data(saltBytes), iterations: EncryptedBackupEnvelope.defaultIterations)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
        guard let combined = sealedBox.combined else {
            throw AccountBackupError.encryptionFailed
        }
        let envelope = EncryptedBackupEnvelope(
            salt: Data(saltBytes).base64EncodedString(),
            payload: combined.base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
        #else
        throw AccountBackupError.encryptedUnsupported
        #endif
    }

    static func decrypt(_ envelopeData: Data, password: String) throws -> Data {
        guard envelopeData.count <= AccountProfileBackup.maxImportBytes else {
            throw AccountBackupError.fileTooLarge
        }
        guard !password.isEmpty else {
            throw AccountBackupError.wrongPassword
        }
        let envelope: EncryptedBackupEnvelope
        do {
            envelope = try JSONDecoder().decode(EncryptedBackupEnvelope.self, from: envelopeData)
        } catch {
            throw AccountBackupError.invalidFormat
        }
        guard envelope.schema == EncryptedBackupEnvelope.schemaIdentifier,
              envelope.kind == EncryptedBackupEnvelope.supportedKind else {
            throw AccountBackupError.invalidFormat
        }
        guard envelope.format >= 1, envelope.format <= EncryptedBackupEnvelope.currentFormat else {
            throw AccountBackupError.unsupportedVersion
        }
        guard envelope.kdf == EncryptedBackupEnvelope.supportedKDF,
              envelope.cipher == EncryptedBackupEnvelope.supportedCipher,
              envelope.iterations >= EncryptedBackupEnvelope.minIterations,
              envelope.iterations <= EncryptedBackupEnvelope.maxIterations else {
            throw AccountBackupError.encryptedUnsupported
        }
        guard let saltData = Data(base64Encoded: envelope.salt),
              saltData.count >= 16,
              let combinedData = Data(base64Encoded: envelope.payload) else {
            throw AccountBackupError.invalidFormat
        }
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        let key = try deriveKey(password: password, salt: saltData, iterations: envelope.iterations)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
            return try AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
        } catch {
            throw AccountBackupError.wrongPassword
        }
        #else
        throw AccountBackupError.encryptedUnsupported
        #endif
    }

    #if canImport(CryptoKit) && canImport(CommonCrypto)
    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer { derived.resetBytes(in: 0..<derived.count) }
        let status = passwordData.withUnsafeBytes { passRaw in
            salt.withUnsafeBytes { saltRaw in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passRaw.bindMemory(to: Int8.self).baseAddress,
                    passwordData.count,
                    saltRaw.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw AccountBackupError.encryptionFailed
        }
        return SymmetricKey(data: derived)
    }
    #endif
}

enum AccountBackupConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    /// Default safe mode: add only accounts not present locally; preserve existing accounts completely.
    case skipExisting
    /// Replace existing accounts' credentials/profile with imported data (legacy credential-less backups preserve local credentials).
    case overwriteExisting

    /// Legacy name alias kept for existing callers/tests.
    static let updateProfileKeepingSession: AccountBackupConflictPolicy = .overwriteExisting

    var id: String { rawValue }
}

enum AccountBackupError: LocalizedError, Equatable {
    case emptyExport
    case fileTooLarge
    case invalidFormat
    case wrongBackupKindSettings
    case encryptedUnsupported
    case encryptedPasswordRequired
    case emptyPassword
    case wrongPassword
    case encryptionFailed
    case unsupportedVersion
    case invalidAccountEntry
    case emptyAccounts

    var errorDescription: String? {
        switch self {
        case .emptyExport:
            return AppText.text("目前没有可导出的 Apple 账号。")
        case .fileTooLarge:
            return AppText.text("所选文件过大，请确认它是有效的 iPadn 备份文件。")
        case .invalidFormat:
            return AppText.text("这不是有效的 iPadn 备份文件。")
        case .wrongBackupKindSettings:
            return AppText.text("请前往「设置 › 备份与维护」导入。")
        case .encryptedUnsupported:
            return AppText.text("这个文件使用了当前版本不支持的加密备份格式。")
        case .encryptedPasswordRequired:
            return AppText.text("这个备份已加密，请输入备份密码后导入。")
        case .emptyPassword:
            return AppText.text("请输入备份密码。")
        case .wrongPassword:
            return AppText.text("备份密码不正确，请检查后重试。")
        case .encryptionFailed:
            return AppText.text("无法加密备份文件，请重试。")
        case .unsupportedVersion:
            return AppText.text("这个备份来自更新版本的 iPadn，请先更新 iPadn。")
        case .invalidAccountEntry:
            return AppText.text("备份文件中存在无效的账号标识，已取消导入。")
        case .emptyAccounts:
            return AppText.text("账号备份文件中没有包含任何账号。")
        }
    }
}

enum AccountBackupService {
    struct ImportPreview: Equatable {
        let backup: AccountProfileBackup
        let newEntries: [AccountProfileEntry]
        let existingEntries: [AccountProfileEntry]

        var totalCount: Int { backup.accounts.count }
        var duplicateCount: Int { existingEntries.count }
        var newCount: Int { newEntries.count }
    }

    struct MergeResult {
        let mergedAccounts: [AppleAccount]
        let addedIDs: [String]
        let updatedIDs: [String]
        let skippedIDs: [String]
    }

    static func deduplicatedEntries(from rawEntries: [AccountProfileEntry]) throws -> [AccountProfileEntry] {
        let sessions = rawEntries.map(AccountSessionEntry.init(from:))
        return try deduplicatedSessions(from: sessions).map(\.profileEntry)
    }

    static func deduplicatedSessions(from rawEntries: [AccountSessionEntry]) throws -> [AccountSessionEntry] {
        var deduplicated: [AccountSessionEntry] = []
        var seenIndices: [String: Int] = [:]
        for entry in rawEntries {
            let trimmedID = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else {
                throw AccountBackupError.invalidAccountEntry
            }
            let key = AppleAccount.normalizedIdentifier(trimmedID)
            if let index = seenIndices[key] {
                var current = deduplicated[index]
                if entry.credentialPriority > current.credentialPriority {
                    var promoted = entry
                    if promoted.name.isEmpty { promoted.name = current.name }
                    if promoted.password.isEmpty { promoted.password = current.password }
                    if !promoted.hasCookie { promoted.cookie = current.cookie }
                    if promoted.dsid.isEmpty { promoted.dsid = current.dsid }
                    if promoted.passwordToken.isEmpty { promoted.passwordToken = current.passwordToken }
                    if promoted.storeFront.isEmpty { promoted.storeFront = current.storeFront }
                    if promoted.fullStoreFront.isEmpty { promoted.fullStoreFront = current.fullStoreFront }
                    deduplicated[index] = promoted
                } else {
                    if current.name.isEmpty && !entry.name.isEmpty { current.name = entry.name }
                    if current.password.isEmpty && !entry.password.isEmpty { current.password = entry.password }
                    if !current.hasCookie && entry.hasCookie { current.cookie = entry.cookie }
                    if current.dsid.isEmpty && !entry.dsid.isEmpty { current.dsid = entry.dsid }
                    if current.passwordToken.isEmpty && !entry.passwordToken.isEmpty { current.passwordToken = entry.passwordToken }
                    if current.storeFront.isEmpty && !entry.storeFront.isEmpty { current.storeFront = entry.storeFront }
                    if current.fullStoreFront.isEmpty && !entry.fullStoreFront.isEmpty { current.fullStoreFront = entry.fullStoreFront }
                    deduplicated[index] = current
                }
            } else {
                seenIndices[key] = deduplicated.count
                deduplicated.append(entry)
            }
        }
        return deduplicated
    }

    static func entries(from accounts: [AppleAccount]) -> [AccountProfileEntry] {
        let valid = accounts
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { AccountProfileEntry(from: $0) }
        return (try? deduplicatedEntries(from: valid)) ?? valid
    }

    static func sessions(from accounts: [AppleAccount], liveCookies: [String: String] = [:]) -> [AccountSessionEntry] {
        let valid = accounts
            .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { AccountSessionEntry(from: $0, effectiveCookie: liveCookies[$0.id] ?? $0.cookie) }
        return (try? deduplicatedSessions(from: valid)) ?? valid
    }

    static func makeBackup(from accounts: [AppleAccount], activeID: String?) throws -> AccountProfileBackup {
        let entries = entries(from: accounts)
        guard !entries.isEmpty else {
            throw AccountBackupError.emptyExport
        }
        return AccountProfileBackup(preferredActiveID: activeID, accounts: entries)
    }

    static func partition(_ entries: [AccountProfileEntry], existing: [AppleAccount]) -> (new: [AccountProfileEntry], existing: [AccountProfileEntry]) {
        let result = partition(entries.map(AccountSessionEntry.init(from:)), existing: existing)
        return (result.new.map(\.profileEntry), result.existing.map(\.profileEntry))
    }

    static func partition(_ entries: [AccountSessionEntry], existing: [AppleAccount]) -> (new: [AccountSessionEntry], existing: [AccountSessionEntry]) {
        let existingKeys = Set(existing.map { AppleAccount.normalizedIdentifier($0.id) })
        var newEntries: [AccountSessionEntry] = []
        var existingEntries: [AccountSessionEntry] = []
        for entry in entries {
            if existingKeys.contains(AppleAccount.normalizedIdentifier(entry.id)) {
                existingEntries.append(entry)
            } else {
                newEntries.append(entry)
            }
        }
        return (newEntries, existingEntries)
    }

    static func preview(data: Data, existing: [AppleAccount]) throws -> ImportPreview {
        let backup = try AccountProfileBackup.decode(data)
        let split = partition(backup.accounts, existing: existing)
        return ImportPreview(backup: backup, newEntries: split.new, existingEntries: split.existing)
    }

    static func normalizedDeviceGUID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              trimmed.count == 12,
              trimmed.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        return trimmed
    }

    static func sanitizedStoreProofRecords(_ records: [String: StoreProofRecord]?) -> [String: StoreProofRecord]? {
        guard let records else { return nil }
        var cleaned: [String: StoreProofRecord] = [:]
        for (rawKey, rawRecord) in records {
            let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedDeviceGUID(trimmedKey) != nil else { continue }
            let identifier = rawRecord.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard identifier.count == 16,
                  identifier.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                continue
            }
            var safeFiles: [String: String] = [:]
            for (name, value) in rawRecord.files {
                guard !name.isEmpty,
                      name != ".",
                      name != "..",
                      !name.contains("/"),
                      !name.contains("\\"),
                      !name.contains("\0") else {
                    continue
                }
                safeFiles[name] = value
            }
            cleaned[trimmedKey] = StoreProofRecord(
                identifier: identifier,
                files: safeFiles,
                updatedAt: rawRecord.updatedAt
            )
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    static func merge(
        imported: AccountProfileBackup,
        into existing: [AppleAccount],
        policy: AccountBackupConflictPolicy
    ) -> MergeResult {
        merge(entries: imported.accounts.map(AccountSessionEntry.init(from:)), into: existing, policy: policy)
    }

    static func merge(
        entries: [AccountProfileEntry],
        into existing: [AppleAccount],
        policy: AccountBackupConflictPolicy
    ) -> MergeResult {
        merge(entries: entries.map(AccountSessionEntry.init(from:)), into: existing, policy: policy)
    }

    /// Merges full session entries or legacy profile entries with existing Keychain accounts.
    /// Legacy credential-less entries never overwrite passwords, tokens, cookies, or DSIDs.
    static func merge(
        entries: [AccountSessionEntry],
        into existing: [AppleAccount],
        policy: AccountBackupConflictPolicy
    ) -> MergeResult {
        var result = existing
        var indexByNormalizedID: [String: Int] = [:]
        for (index, account) in result.enumerated() {
            let key = AppleAccount.normalizedIdentifier(account.id)
            if indexByNormalizedID[key] == nil {
                indexByNormalizedID[key] = index
            }
        }

        var addedIDs: [String] = []
        var updatedIDs: [String] = []
        var skippedIDs: [String] = []

        for entry in entries {
            let key = AppleAccount.normalizedIdentifier(entry.id)
            if let existingIndex = indexByNormalizedID[key] {
                switch policy {
                case .skipExisting:
                    skippedIDs.append(result[existingIndex].id)
                case .overwriteExisting:
                    var updated = result[existingIndex]
                    var changed = false
                    if !entry.name.isEmpty, entry.name != updated.name {
                        updated.name = entry.name
                        changed = true
                    }
                    if !entry.storeFront.isEmpty, entry.storeFront != updated.storeFront {
                        updated.storeFront = entry.storeFront
                        changed = true
                    }
                    if !entry.fullStoreFront.isEmpty, entry.fullStoreFront != updated.fullStoreFront {
                        updated.fullStoreFront = entry.fullStoreFront
                        changed = true
                    }
                    if entry.hasAnyCredential {
                        if !entry.password.isEmpty, entry.password != updated.password {
                            updated.password = entry.password
                            changed = true
                        }
                        if entry.hasCookie, entry.cookie != updated.cookie {
                            updated.cookie = entry.cookie
                            changed = true
                        }
                        if !entry.dsid.isEmpty, entry.dsid != updated.dsid {
                            updated.dsid = entry.dsid
                            changed = true
                        }
                        if !entry.passwordToken.isEmpty, entry.passwordToken != updated.passwordToken {
                            updated.passwordToken = entry.passwordToken
                            changed = true
                        }
                    }
                    result[existingIndex] = updated
                    if changed { updatedIDs.append(updated.id) }
                    else { skippedIDs.append(updated.id) }
                }
            } else {
                indexByNormalizedID[key] = result.count
                result.append(entry.appleAccount)
                addedIDs.append(entry.id)
            }
        }

        return MergeResult(
            mergedAccounts: result,
            addedIDs: addedIDs,
            updatedIDs: updatedIDs,
            skippedIDs: skippedIDs
        )
    }
}
