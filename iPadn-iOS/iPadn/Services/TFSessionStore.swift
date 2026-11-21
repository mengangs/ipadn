import Foundation
import Security

#if canImport(TestFlightKit)
import TestFlightKit

/// Keychain-backed TestFlight session metadata per DSID (L3 persistence).
///
/// Security & invariant boundaries:
/// - PET is NEVER stored here (short-lived, memory-only).
/// - Store cookies are NEVER duplicated here (sole read point stays `AccountScope.cookies(for:)`).
/// - Stored in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, matching `KeychainStore`.
struct StoredTFSession: Codable, Equatable {
    let dsid: String
    let email: String
    let sessionID: String
    let accountID: String
    let baseHeaders: [String: String]
    let storeFront: String
    let updatedAt: Date

    var amdm: String? {
        baseHeaders["X-Apple-AMD-M"]
    }

    var tfSession: TFSession {
        TFSession(id: sessionID, dsid: dsid, account: accountID, baseHeaders: baseHeaders)
    }
}

/// Persists `TFSession` in Keychain (per DSID) and non-sensitive catalog/detail metadata
/// on disk under `Documents/TestFlight/cache/` so switching accounts or relaunching renders
/// immediately without re-running GSA 2FA.
enum TFSessionStore {
    private static let lastAccountKey = "tf.lastAccountEmail"

    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "iPadn") + (LocalResources.isPreview ? ".preview.tf-sessions" : ".tf-sessions")
    }

    private static let keychainAccount = "tf-sessions-v1"

    // MARK: - Last Viewed Account

    static var lastAccountEmail: String? {
        get { UserDefaults.standard.string(forKey: lastAccountKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastAccountKey) }
    }

    // MARK: - Keychain Sessions (keyed by dsid)

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func loadAll() -> [String: StoredTFSession] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: StoredTFSession].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveAll(_ map: [String: StoredTFSession]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query()
            attributes.forEach { item[$0.key] = $0.value }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func save(session: TFSession, context: TFContext, email: String) {
        guard !session.dsid.isEmpty, !session.id.isEmpty else { return }
        var map = loadAll()
        map[session.dsid] = StoredTFSession(
            dsid: session.dsid,
            email: AppleAccount.normalizedIdentifier(email),
            sessionID: session.id,
            accountID: session.account,
            baseHeaders: session.baseHeaders.isEmpty ? context.headers : session.baseHeaders,
            storeFront: context.storefront,
            updatedAt: Date()
        )
        saveAll(map)
    }

    static func load(dsid: String, email: String = "") -> StoredTFSession? {
        let map = loadAll()
        let cleanDsid = dsid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDsid.isEmpty, let direct = map[cleanDsid] {
            return direct
        }
        let normalized = AppleAccount.normalizedIdentifier(email)
        guard !normalized.isEmpty else { return nil }
        return map.values
            .filter { AppleAccount.normalizedIdentifier($0.email) == normalized }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    static func hasSession(dsid: String, email: String = "") -> Bool {
        load(dsid: dsid, email: email) != nil
    }

    static func delete(dsid: String, email: String = "") {
        var map = loadAll()
        var removedDsids = Set<String>()
        let cleanDsid = dsid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDsid.isEmpty {
            map.removeValue(forKey: cleanDsid)
            removedDsids.insert(cleanDsid)
        }
        let normalized = AppleAccount.normalizedIdentifier(email)
        if !normalized.isEmpty {
            for key in map.keys where AppleAccount.normalizedIdentifier(map[key]?.email ?? "") == normalized {
                map.removeValue(forKey: key)
                removedDsids.insert(key)
            }
        }
        for removed in removedDsids {
            AccountScope.remove(dsid: removed)
            if let file = catalogFile(dsid: removed) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        saveAll(map)
    }

    /// Removes orphaned sessions, cookie jars and catalog caches for accounts that were deleted in `AccountsView`.
    static func prune(keepingAccounts accounts: [AppleAccount]) {
        let keptDsids = Set(accounts.map { $0.dsid.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let keptEmails = Set(accounts.map { AppleAccount.normalizedIdentifier($0.id) }.filter { !$0.isEmpty })
        var map = loadAll()
        let removed = map.filter { dsid, entry in
            !keptDsids.contains(dsid) && !keptEmails.contains(AppleAccount.normalizedIdentifier(entry.email))
        }
        guard !removed.isEmpty else {
            if accounts.isEmpty { AccountScope.clearSharedCookies() }
            return
        }
        for (dsid, _) in removed {
            map.removeValue(forKey: dsid)
            AccountScope.remove(dsid: dsid)
            if let file = catalogFile(dsid: dsid) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        if accounts.isEmpty { AccountScope.clearSharedCookies() }
        saveAll(map)
    }

    // MARK: - Non-Sensitive Disk Cache (Catalog + v3 App Details)

    private static func safeDigits(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return trimmed
    }

    private static func safePathComponent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }),
              !trimmed.contains("..") else { return nil }
        return trimmed
    }

    private static func cacheDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("TestFlight/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func catalogFile(dsid: String) -> URL? {
        guard let safe = safeDigits(dsid) else { return nil }
        return cacheDirectory().appendingPathComponent("catalog-\(safe).json")
    }

    private static func detailFile(appID: String) -> URL? {
        guard let safe = safePathComponent(appID) else { return nil }
        return cacheDirectory().appendingPathComponent("detail-\(safe).json")
    }

    static func saveCatalog(_ apps: [TFBetaApp], dsid: String) {
        guard let file = catalogFile(dsid: dsid), let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func loadCatalog(dsid: String) -> [TFBetaApp] {
        guard let file = catalogFile(dsid: dsid),
              let data = try? Data(contentsOf: file),
              let apps = try? JSONDecoder().decode([TFBetaApp].self, from: data) else {
            return []
        }
        return apps
    }

    static func saveDetail(_ detail: TFAppDetail) {
        guard let file = detailFile(appID: detail.appID), let data = try? JSONEncoder().encode(detail) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func loadDetail(appID: String) -> TFAppDetail? {
        guard let file = detailFile(appID: appID),
              let data = try? Data(contentsOf: file),
              let detail = try? JSONDecoder().decode(TFAppDetail.self, from: data) else {
            return nil
        }
        return detail
    }
}
#endif
