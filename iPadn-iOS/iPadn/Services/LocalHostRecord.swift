import Foundation
import CFNetwork
import dnssd

/// Makes `ipadn.local` answer 127.0.0.1 for programs on this device only.
///
/// With a proxy or VPN on, a public name such as ipadn.localtest.me is sent
/// through the proxy (or answered with a stand-in address), so the installer
/// never reaches this device. Proxy apps leave `*.local` alone, and a
/// local-only multicast DNS record never leaves the device, so the installer
/// connects straight to the server on 127.0.0.1.
final class LocalHostRecord: @unchecked Sendable {
    static let shared = LocalHostRecord()
    static let host = "ipadn.local"
    private let queue = DispatchQueue(label: "iPadn.local-host-record")
    private var connection: DNSServiceRef?
    private var record: DNSRecordRef?

    /// Registers the record if needed; false when the system refused it.
    func publish() -> Bool {
        queue.sync {
            if connection != nil { return true }
            var connection: DNSServiceRef?
            guard DNSServiceCreateConnection(&connection) == DNSServiceErrorType(kDNSServiceErr_NoError), let connection else {
                return false
            }
            var record: DNSRecordRef?
            let address: [UInt8] = [127, 0, 0, 1]
            let status = address.withUnsafeBytes { bytes in
                DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsShared),
                                         UInt32.max, // kDNSServiceInterfaceIndexLocalOnly: this device only
                                         Self.host + ".", UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                         UInt16(bytes.count), bytes.baseAddress, 60,
                                         { _, _, _, error, _ in
                                             if error != DNSServiceErrorType(kDNSServiceErr_NoError) {
                                                 InstallLog.shared.add("ipadn.local record error \(error)")
                                             }
                                         }, nil)
            }
            guard status == DNSServiceErrorType(kDNSServiceErr_NoError) else {
                InstallLog.shared.add("ipadn.local record not registered (\(status))")
                DNSServiceRefDeallocate(connection)
                return false
            }
            DNSServiceSetDispatchQueue(connection, queue)
            self.connection = connection; self.record = record
            InstallLog.shared.add("ipadn.local record registered")
            return true
        }
    }

    /// Whether traffic may be going through a proxy or VPN app right now.
    static var proxyOrVPNActive: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        if (settings["HTTPEnable"] as? Int) == 1 || (settings["HTTPSEnable"] as? Int) == 1 || (settings["ProxyAutoConfigEnable"] as? Int) == 1 {
            return true
        }
        let scoped = (settings["__SCOPED__"] as? [String: Any]).map { Array($0.keys) } ?? []
        return scoped.contains { name in ["utun", "tun", "tap", "ppp", "ipsec"].contains { name.hasPrefix($0) } }
    }
}
