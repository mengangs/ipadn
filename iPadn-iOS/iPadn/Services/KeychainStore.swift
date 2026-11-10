import Foundation
import Security

enum KeychainStore {
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "iPadn") + (LocalResources.isPreview ? ".preview.accounts" : ".accounts")
    }
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: LocalResources.accounts]
    }
    static func load() throws -> [AppleAccount] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ToolError.message(AppText.text("无法读取账号钥匙串（\(status)），请解锁设备后重试"))
        }
        return try JSONDecoder().decode([AppleAccount].self, from: data)
    }
    static func save(_ accounts: [AppleAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(); attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ToolError.message(AppText.text("无法保存账号钥匙串（\(added)）")) }
        } else if status != errSecSuccess {
            throw ToolError.message(AppText.text("无法更新账号钥匙串（\(status)）"))
        }
    }
}

struct StoreProofRecord: Codable, Equatable, Sendable {
    var identifier: String
    var files: [String: String]
    var updatedAt: Date = Date()
}

enum StoreProofStore {
    private static let maxEntries = 8
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "iPadn") + (LocalResources.isPreview ? ".preview.storeproof" : ".storeproof")
    }
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "store-proof-v1"]
    }
    static func load() -> [String: StoreProofRecord] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: StoreProofRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }
    static func save(_ records: [String: StoreProofRecord]) {
        let trimmed: [String: StoreProofRecord]
        if records.count > maxEntries {
            let kept = records.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maxEntries)
            trimmed = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        } else {
            trimmed = records
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(); attributes.forEach { item[$0.key] = $0.value }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}
