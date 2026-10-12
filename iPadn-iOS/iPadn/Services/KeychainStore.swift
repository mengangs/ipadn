import Foundation
import Security

enum KeychainStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "iPadn") + ".accounts" }
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
            throw ToolError.message("无法读取账号钥匙串（\(status)），请解锁设备后重试")
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
            guard added == errSecSuccess else { throw ToolError.message("无法保存账号钥匙串（\(added)）") }
        } else if status != errSecSuccess {
            throw ToolError.message("无法更新账号钥匙串（\(status)）")
        }
    }
}
