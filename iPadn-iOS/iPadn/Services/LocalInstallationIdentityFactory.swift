import Foundation
import Security
import CryptoKit
import CommonCrypto

/// Creates a private device-local CA and server identity. Only the public CA is exported.
/// DER encoding follows X.509 / PKCS#12; server keys are kept in the installation keychain.
enum LocalInstallationIdentityFactory {
    struct Material {
        let pkcs12: Data
        let password: String
        let rootCertificate: Data
        let identifier: UUID
        func profile() throws -> Data {
            let root: [String: Any] = [
                "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                "PayloadIdentifier": "app.local.iPadn.installation.root." + identifier.uuidString,
                "PayloadUUID": identifier.uuidString, "PayloadDisplayName": "iPadn 本机安装 CA",
                "PayloadDescription": "仅用于信任此设备上 iPadn 创建的安装服务器。",
                "PayloadCertificateFileName": "iPadn-local-root.cer", "PayloadContent": rootCertificate
            ]
            return try PropertyListSerialization.data(fromPropertyList: [
                "PayloadType": "Configuration", "PayloadVersion": 1,
                "PayloadIdentifier": "app.local.iPadn.installation." + identifier.uuidString,
                "PayloadUUID": UUID().uuidString, "PayloadDisplayName": "iPadn 本机安装证书",
                "PayloadDescription": "由此设备上的 iPadn 创建。安装后在设置中为该 CA 启用完全信任，才能使用本机 HTTPS 安装。",
                "PayloadContent": [root]
            ], format: .xml, options: 0)
        }
    }
    static func create() throws -> Material {
        let ca = try key(), server = try key()
        let caPublic = try publicBytes(ca), serverPublic = try publicBytes(server)
        let identifier = UUID()
        let issuer = name("iPadn Local CA " + String(identifier.uuidString.prefix(8)))
        let subject = name("iPadn Local Installation")
        let now = Date()
        // A small backdating allowance handles clocks changing during setup.
        let caCertificate = try certificate(publicKey: caPublic, signingKey: ca, issuer: issuer, subject: issuer,
            from: now.addingTimeInterval(-300), until: now.addingTimeInterval(3650 * 86400), ca: true,
            authorityKey: caPublic)
        let serverCertificate = try certificate(publicKey: serverPublic, signingKey: ca, issuer: issuer, subject: subject,
            from: now.addingTimeInterval(-300), until: now.addingTimeInterval(365 * 86400), ca: false,
            authorityKey: caPublic)
        let password = UUID().uuidString
        let keyInfo = DER.sequence([DER.integer(Data([0])), rsaAlgorithm, DER.value(0x04, try externalBytes(server))])
        let pfx = try pkcs12(privateKeyInfo: keyInfo, certificates: [serverCertificate, caCertificate], password: password)
        // Check the exact format through Apple's importer before saving anything.
        _ = try InstallationCertificate.importPKCS12(pfx, password: password)
        return Material(pkcs12: pfx, password: password, rootCertificate: caCertificate, identifier: identifier)
    }
    /// PKCS#12 with the PKCS#8 key in a pkcs8ShroudedKeyBag
    /// (pbeWithSHAAnd3-KeyTripleDES-CBC; iOS 26 ignores unencrypted keyBags)
    /// and the certificates in plain cert bags, leaf first.
    static func pkcs12(privateKeyInfo keyInfo: Data, certificates: [Data], password: String) throws -> Data {
        guard let leaf = certificates.first else { throw ToolError.message("证书链为空") }
        let keyID = Data(Insecure.SHA1.hash(data: leaf))
        let attributes = DER.value(0x31, DER.sequence([DER.oid("1.2.840.113549.1.9.21"), DER.value(0x31, DER.value(0x04, keyID))]))
        let keySalt = try random(8), keyIterations = 2048
        let encryptedKey = try tripleDES(keyInfo,
            key: pkcs12KDF(sha256: false, id: 1, password: password, salt: keySalt, iterations: keyIterations, length: 24),
            iv: pkcs12KDF(sha256: false, id: 2, password: password, salt: keySalt, iterations: keyIterations, length: 8))
        let encryptedKeyInfo = DER.sequence([
            DER.sequence([DER.oid("1.2.840.113549.1.12.1.3"),
                          DER.sequence([DER.value(0x04, keySalt), DER.integer(Data([0x08, 0x00]))])]),
            DER.value(0x04, encryptedKey)])
        let keyBag = DER.sequence([DER.oid("1.2.840.113549.1.12.10.1.2"), DER.value(0xa0, encryptedKeyInfo), attributes])
        func certBag(_ certificate: Data, attributes: Data = Data()) -> Data {
            let body = DER.sequence([DER.oid("1.2.840.113549.1.9.22.1"), DER.value(0xa0, DER.value(0x04, certificate))])
            return DER.sequence([DER.oid("1.2.840.113549.1.12.10.1.3"), DER.value(0xa0, body), attributes])
        }
        let bags = [keyBag, certBag(leaf, attributes: attributes)] + certificates.dropFirst().map { certBag($0) }
        func contentInfo(_ data: Data) -> Data {
            DER.sequence([DER.oid("1.2.840.113549.1.7.1"), DER.value(0xa0, DER.value(0x04, data))])
        }
        let safe = DER.sequence([contentInfo(DER.sequence(bags))])
        let salt = try random(32), iterations = 10_000
        let macKey = pkcs12KDF(sha256: true, id: 3, password: password, salt: salt, iterations: iterations, length: 32)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: safe, using: SymmetricKey(data: macKey)))
        let digestInfo = DER.sequence([DER.sequence([DER.oid("2.16.840.1.101.3.4.2.1"), DER.value(0x05, Data())]), DER.value(0x04, mac)])
        let macData = DER.sequence([digestInfo, DER.value(0x04, salt), DER.integer(Data([0x27, 0x10]))])
        return DER.sequence([DER.integer(Data([3])), contentInfo(safe), macData])
    }

    private static func key() throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048] as CFDictionary, &error) else {
            throw ToolError.message("无法创建本机安装密钥：\(error?.takeRetainedValue().localizedDescription ?? "系统错误")")
        }
        return key
    }
    private static func externalBytes(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw ToolError.message("无法编码本机安装密钥")
        }
        return data
    }
    private static func publicBytes(_ key: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw ToolError.message("无法读取安装公钥") }
        return try externalBytes(publicKey)
    }
    private static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ToolError.message("系统随机数生成失败") }
        return data
    }
    private static let rsaAlgorithm = DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.value(0x05, Data())])
    private static let signatureAlgorithm = DER.sequence([DER.oid("1.2.840.113549.1.1.11"), DER.value(0x05, Data())])
    private static func name(_ value: String) -> Data {
        DER.sequence([DER.value(0x31, DER.sequence([DER.oid("2.5.4.3"), DER.value(0x0c, Data(value.utf8))]))])
    }
    private static func time(_ value: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let generalized = Calendar(identifier: .gregorian).component(.year, from: value) >= 2050
        formatter.dateFormat = generalized ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
        return DER.value(generalized ? 0x18 : 0x17, Data(formatter.string(from: value).utf8))
    }
    private static func certificate(publicKey: Data, signingKey: SecKey, issuer: Data, subject: Data,
                                    from: Date, until: Date, ca: Bool, authorityKey: Data) throws -> Data {
        func ext(_ oid: String, _ body: Data, critical: Bool = false) -> Data {
            DER.sequence([DER.oid(oid)] + (critical ? [DER.value(0x01, Data([0xff]))] : []) + [DER.value(0x04, body)])
        }
        var extensions = [
            ext("2.5.29.19", DER.sequence(ca ? [DER.value(0x01, Data([0xff]))] : []), critical: true),
            ext("2.5.29.15", DER.value(0x03, Data(ca ? [1, 0x06] : [5, 0xa0])), critical: true),
            ext("2.5.29.14", DER.value(0x04, Data(Insecure.SHA1.hash(data: publicKey)))),
            ext("2.5.29.35", DER.sequence([DER.value(0x80, Data(Insecure.SHA1.hash(data: authorityKey)))]))
        ]
        if !ca {
            extensions.append(ext("2.5.29.37", DER.sequence([DER.oid("1.3.6.1.5.5.7.3.1")])))
            extensions.append(ext("2.5.29.17", DER.sequence([DER.value(0x87, Data([127, 0, 0, 1]))]
                + ManifestBuilder.localHostNames.map { DER.value(0x82, Data($0.utf8)) })))
        }
        let tbs = DER.sequence([DER.value(0xa0, DER.integer(Data([2]))), DER.integer(try random(16)),
            signatureAlgorithm, issuer, DER.sequence([time(from), time(until)]), subject,
            DER.sequence([rsaAlgorithm, DER.value(0x03, Data([0]) + publicKey)]), DER.value(0xa3, DER.sequence(extensions))])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(signingKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            throw ToolError.message("无法签发本机安装证书")
        }
        return DER.sequence([tbs, signatureAlgorithm, DER.value(0x03, Data([0]) + signature)])
    }
    /// RFC 7292 Appendix B.2 key derivation with SHA-1 or SHA-256 (v = 64);
    /// id 1 = encryption key, 2 = IV, 3 = MAC key.
    static func pkcs12KDF(sha256: Bool, id: UInt8, password: String, salt: Data,
                          iterations: Int, length: Int) -> Data {
        let v = 64
        func digest(_ data: Data) -> Data {
            sha256 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data))
        }
        func expanded(_ bytes: Data) -> [UInt8] {
            guard !bytes.isEmpty else { return [] }
            let source = Array(bytes)
            return (0..<(v * ((source.count + v - 1) / v))).map { source[$0 % source.count] }
        }
        let utf16 = Data((password + "\0").utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] })
        let diversifier = Data(repeating: id, count: v)
        var input = expanded(salt) + expanded(utf16)
        var output = Data()
        while true {
            var block = digest(diversifier + Data(input))
            for _ in 1..<iterations { block = digest(block) }
            output += block
            if output.count >= length { return Data(output.prefix(length)) }
            // I_j = (I_j + B + 1) mod 2^(8v), with B = block repeated to v bytes.
            let bytes = Array(block)
            for start in stride(from: 0, to: input.count, by: v) {
                var carry = 1
                for index in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(input[start + index]) + Int(bytes[index % bytes.count]) + carry
                    input[start + index] = UInt8(sum & 0xff)
                    carry = sum >> 8
                }
            }
        }
    }

    private static func tripleDES(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSize3DES)
        let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithm3DES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySize3DES, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw ToolError.message("无法加密本机安装密钥") }
        return Data(output.prefix(written))
    }
}

private enum DER {
    static func value(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 128 { length.append(UInt8(content.count)) }
        else {
            var count = content.count, bytes: [UInt8] = []
            while count > 0 { bytes.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + content
    }
    static func sequence(_ parts: [Data]) -> Data { value(0x30, parts.reduce(into: Data()) { $0.append($1) }) }
    static func integer(_ input: Data) -> Data {
        var bytes = Array(input)
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if (bytes.first ?? 0) & 0x80 != 0 { bytes.insert(0, at: 0) }
        return value(0x02, Data(bytes))
    }
    static func oid(_ string: String) -> Data {
        let parts = string.split(separator: ".").map { UInt64($0)! }
        var output = Data([UInt8(parts[0] * 40 + parts[1])])
        for part in parts.dropFirst(2) {
            var number = part, bytes = [UInt8(part & 0x7f)]
            number >>= 7
            while number > 0 { bytes.insert(UInt8(number & 0x7f) | 0x80, at: 0); number >>= 7 }
            output.append(contentsOf: bytes)
        }
        return value(0x06, output)
    }
}
