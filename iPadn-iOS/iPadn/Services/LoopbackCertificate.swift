import Foundation
import Security

/// Zero-configuration HTTPS for on-device installation.
///
/// backloop.dev is a public development domain: every name under it resolves
/// to 127.0.0.1, and its publicly trusted certificate and key are published
/// at https://backloop.dev/pack.json for exactly this purpose. Serving the
/// manifest and IPA from the loopback server under that name lets iOS's
/// installer connect with normal system trust, so the user installs no
/// profile and configures no server. The certificate is refreshed whenever
/// it no longer passes system trust (it is renewed upstream every few weeks).
enum LoopbackCertificate {
    static let packURL = URL(string: "https://backloop.dev/pack.json")!

    struct Pack: Codable, Equatable {
        let certificatePEM: String
        let keyPEM: String
        let host: String
    }

    private struct Remote: Decodable {
        struct Info: Decodable { struct Names: Decodable { let commonName: String }; let domains: Names }
        let cert: String
        let ca: String?
        let key: String?
        let key1: String?
        let key2: String?
        let info: Info
    }

    private static var cacheURL: URL { LocalResources.support.appendingPathComponent("loopback-tls.json") }

    /// A trusted identity and the loopback host name it is valid for.
    static func current() async throws -> (InstallationCertificate.Identity, String) {
        if let cached = try? JSONDecoder().decode(Pack.self, from: Data(contentsOf: cacheURL)),
           let identity = try? await usable(cached) {
            return (identity, cached.host)
        }
        let (data, _) = try await HTTPClient.shared.request(packURL)
        let pack = try parse(data)
        let identity: InstallationCertificate.Identity
        do { identity = try await usable(pack) }
        catch { throw ToolError.message("一键安装证书暂不可用（\(error.localizedDescription)）。请稍后重试，或在安装设置中改用本机证书。") }
        try JSONEncoder().encode(pack).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return (identity, pack.host)
    }

    static func parse(_ data: Data) throws -> Pack {
        guard let remote = try? JSONDecoder().decode(Remote.self, from: data) else {
            throw ToolError.message("一键安装证书格式无效，请稍后重试")
        }
        let key = remote.key ?? ((remote.key1 ?? "") + (remote.key2 ?? ""))
        // Leaf first, then the issuing chain without duplicates.
        var chain = remote.cert
        if let ca = remote.ca, !ca.isEmpty {
            let existing = Set(LocalInstallationIdentityFactory.certificates(pem: chain))
            let extra = LocalInstallationIdentityFactory.certificates(pem: ca).filter { !existing.contains($0) }
            if !extra.isEmpty { chain += "\n" + ca }
        }
        let name = remote.info.domains.commonName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = name.hasPrefix("*.") ? "ipadn" + name.dropFirst(1) : name
        guard !key.isEmpty, !LocalInstallationIdentityFactory.certificates(pem: chain).isEmpty,
              (try? ManifestBuilder.localHost(host)) != nil else {
            throw ToolError.message("一键安装证书内容不完整，请稍后重试")
        }
        return Pack(certificatePEM: chain, keyPEM: key, host: host)
    }

    /// Imports the pack as a SecIdentity and requires normal system trust for
    /// its host (so an expired or replaced certificate is fetched again).
    static func usable(_ pack: Pack) async throws -> InstallationCertificate.Identity {
        try await Task.detached(priority: .userInitiated) {
            let certificates = LocalInstallationIdentityFactory.certificates(pem: pack.certificatePEM)
            let keyInfo = try LocalInstallationIdentityFactory.privateKeyInfo(pem: pack.keyPEM)
            let password = UUID().uuidString
            let pfx = try LocalInstallationIdentityFactory.pkcs12(privateKeyInfo: keyInfo,
                                                                   certificates: certificates, password: password)
            let identity = try InstallationCertificate.importPKCS12(pfx, password: password)
            try identity.validate(host: pack.host)
            return identity
        }.value
    }

    /// Some routers and DNS filters block public names that resolve to
    /// 127.0.0.1 ("DNS rebinding protection"); installd would then fail.
    static func resolvesToLoopback(_ host: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                if let address = entry.pointee.ai_addr {
                    if entry.pointee.ai_family == AF_INET {
                        let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                        if UInt32(bigEndian: ipv4) == 0x7f00_0001 { return true }
                    } else if entry.pointee.ai_family == AF_INET6 {
                        let ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                        if withUnsafeBytes(of: ipv6, { Array($0) }) == [UInt8](repeating: 0, count: 15) + [1] { return true }
                    }
                }
                cursor = entry.pointee.ai_next
            }
            return false
        }.value
    }
}
