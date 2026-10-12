import Foundation
import Security

/// Installation TLS material is separate from Apple accounts and never stored in preferences.
enum InstallationCertificate {
    private struct Stored: Codable { let data: Data; let password: String }
    struct Identity {
        let identity: SecIdentity
        let certificates: [SecCertificate]
        let name: String
        func validate(host: String) throws {
            var trust: SecTrust?
            let policy = SecPolicyCreateSSL(true, host as CFString)
            guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
                  let trust else { throw ToolError.message("无法检查安装证书") }
            SecTrustSetNetworkFetchAllowed(trust, false)
            var error: CFError?
            guard SecTrustEvaluateWithError(trust, &error) else {
                throw ToolError.message("安装证书未通过系统信任检查：\(error?.localizedDescription ?? "证书不受信任")。请确认未过期、包含服务地址，并已在系统中信任签发它的 CA。")
            }
        }
    }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "iPadn") + (LocalResources.isPreview ? ".preview.installation" : ".installation"),
         kSecAttrAccount as String: "local-tls"]
    }
    static func importPKCS12(_ data: Data, password: String) throws -> Identity {
        guard data.count <= 2 * 1024 * 1024 else { throw ToolError.message("证书文件超过 2 MB") }
        var result: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]], let item = items.first,
              let value = item[kSecImportItemIdentity as String], CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw ToolError.message("无法导入 SSL 证书（\(status)），请检查密码和 P12/PFX 文件是否包含服务器私钥。")
        }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw ToolError.message("SSL 证书缺少服务器证书")
        }
        let chain = item[kSecImportItemCertChain as String] as? [SecCertificate] ?? [certificate]
        return Identity(identity: identity, certificates: chain, name: SecCertificateCopySubjectSummary(certificate) as String? ?? "本地安装证书")
    }
    static func load() throws -> Identity? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ToolError.message("无法读取安装证书（\(status)），请解锁设备后重试") }
        let saved = try JSONDecoder().decode(Stored.self, from: data)
        return try importPKCS12(saved.data, password: saved.password)
    }
    static func save(data: Data, password: String) throws {
        _ = try importPKCS12(data, password: password)
        let encoded = try JSONEncoder().encode(Stored(data: data, password: password))
        let attributes: [String: Any] = [kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ToolError.message("无法保存安装证书（\(added)）") }
        } else if status != errSecSuccess { throw ToolError.message("无法更新安装证书（\(status)）") }
    }
}
