import Foundation
#if canImport(FairPlayCore)
import FairPlayCore
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One line of the decryption report, shared by the log file and the UI.
struct FairPlayLine: Sendable {
    enum Kind: String, Sendable { case info, phase, ok, warn, fail }
    let kind: Kind
    let text: String
    var rendered: String { "[\(kind.rawValue.uppercased())] \(text)" }
}

/// Where a FairPlay decryption can be staged.
///
/// fairplayd refuses paths inside an app's data container (Documents / Library /
/// tmp) with EPERM/EINVAL, but it does read the shared App Group container, so
/// the staging root has to be a group container. The bundle itself would also be
/// readable, but writing into it breaks the code-signature seal, so it is only
/// used when a run explicitly opts in.
enum FairPlayEnvironment {

    /// App Group identifiers this build may use: an explicit Info.plist value,
    /// then whatever the embedded provisioning profile authorises (so the app is
    /// not tied to one certificate), then the identifiers of the research builds.
    static let groupCandidates: [String] = {
        var values: [String] = []
        if let configured = Bundle.main.object(forInfoDictionaryKey: "FairPlayAppGroup") as? String,
           !configured.isEmpty {
            values.append(configured)
        }
        values.append(contentsOf: profileGroups)
        values.append(contentsOf: [
            "group.b049540b2af108ef.1",
            "group.b049540b2af108ef.2",
            "group.b049540b2af108ef.3",
            "group.b049540b2af108ef.4",
            "group.b049540b2af108ef.5",
        ])
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }()

    /// App Groups granted by the provisioning profile embedded at signing time.
    static var profileGroups: [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                from: raw.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let dictionary = plist as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }

    /// First group container this build is entitled to, if any.
    static func groupContainer() -> URL? {
        #if canImport(Darwin)
        for group in groupCandidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
        #endif
        return nil
    }

    static func groupIdentifier(for url: URL) -> String? {
        #if canImport(Darwin)
        for group in groupCandidates where
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.path == url.path {
            return group
        }
        #endif
        return nil
    }

    /// Bundle-internal staging directory; writing here invalidates the seal.
    static func bundleStaging() -> URL {
        Bundle.main.bundleURL.appendingPathComponent("fpstage", isDirectory: true)
    }

    static var mremapSymbolResolved: Bool {
        #if canImport(Darwin)
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        return dlsym(handle, "mremap_encrypted") != nil
        #else
        return false
        #endif
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func isWritable(_ url: URL) -> Bool {
        let probe = url.appendingPathComponent(".fp-probe-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Human-readable environment report; contains no account material.
    static func describe() -> [FairPlayLine] {
        var lines: [FairPlayLine] = []
        lines.append(FairPlayLine(kind: .info, text: "iOS \(systemVersion) / \(deviceModel())"))
        lines.append(FairPlayLine(kind: .info,
            text: "mremap_encrypted: \(mremapSymbolResolved ? "dyld symbol" : "raw syscall 489")"))
        if let group = groupContainer() {
            lines.append(FairPlayLine(kind: .ok,
                text: "App Group \(groupIdentifier(for: group) ?? "?") at \(group.path)"))
            lines.append(FairPlayLine(kind: .info, text: "group writable: \(isWritable(group) ? "yes" : "no")"))
        } else {
            lines.append(FairPlayLine(kind: .fail,
                text: "no App Group container (profile lacks com.apple.security.application-groups?)"))
        }
        lines.append(FairPlayLine(kind: .info, text: "data container: \(NSHomeDirectory())"))
        lines.append(FairPlayLine(kind: .info,
            text: "Documents writable: \(isWritable(documentsDirectory) ? "yes" : "no")"))
        lines.append(FairPlayLine(kind: .info,
            text: "bundle writable: \(isWritable(Bundle.main.bundleURL) ? "yes" : "no")"))
        return lines
    }
}

/// Reads LC_ENCRYPTION_INFO(_64) out of a file on disk.
enum MachOScan {

    struct SliceInfo: Sendable, CustomStringConvertible {
        let cputype: UInt32
        let cryptoff: UInt32
        let cryptsize: UInt32
        let cryptid: UInt32
        var description: String {
            "cpu=0x\(String(cputype, radix: 16)) cryptoff=0x\(String(cryptoff, radix: 16)) "
                + "cryptsize=0x\(String(cryptsize, radix: 16)) cryptid=\(cryptid)"
        }
    }

    private static let magic64: UInt32 = 0xfeedfacf
    private static let fatMagic: UInt32 = 0xbebafeca       // FAT_CIGAM read little-endian
    private static let fatMagic64: UInt32 = 0xbfbafeca     // FAT_CIGAM_64 read little-endian
    private static let lcEncryptionInfo: UInt32 = 0x21
    private static let lcEncryptionInfo64: UInt32 = 0x2c

    /// Slices of one Mach-O file (FAT containers are walked, arm64 only).
    static func slices(of url: URL) -> [SliceInfo] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return [] }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        switch magic {
        case magic64:
            return thinSlices(handle: handle, offset: 0)
        case fatMagic, fatMagic64:
            return fatSlices(handle: handle, is64: magic == fatMagic64, head: head)
        default:
            return []
        }
    }

    private static func fatSlices(handle: FileHandle, is64: Bool, head: Data) -> [SliceInfo] {
        let count = UInt32(bigEndian: head.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        })
        guard count > 0, count <= 64 else { return [] }
        var result: [SliceInfo] = []
        for _ in 0..<Int(count) {
            let size = is64 ? 32 : 20
            guard let data = try? handle.read(upToCount: size), data.count == size else { break }
            let cputype = UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let offset: UInt64
            if is64 {
                offset = UInt64(bigEndian: data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                })
            } else {
                offset = UInt64(UInt32(bigEndian: data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
                }))
            }
            if cputype & 0x0100_0000 != 0 {
                result.append(contentsOf: thinSlices(handle: handle, offset: offset))
            }
        }
        return result
    }

    private static func thinSlices(handle: FileHandle, offset: UInt64) -> [SliceInfo] {
        guard (try? handle.seek(toOffset: offset)) != nil else { return [] }
        guard let header = try? handle.read(upToCount: 32), header.count == 32 else { return [] }
        let fields = header.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32, UInt32) in
            (raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self),   // magic
             raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self),   // cputype
             raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self),  // ncmds
             raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self))  // sizeofcmds
        }
        guard fields.0 == magic64 else { return [] }
        let cputype = fields.1
        let ncmds = fields.2
        let sizeofcmds = fields.3
        guard sizeofcmds > 0, sizeofcmds < 16 << 20,
              let commands = try? handle.read(upToCount: Int(sizeofcmds)),
              commands.count == Int(sizeofcmds) else { return [] }

        var result: [SliceInfo] = []
        var position = 0
        for _ in 0..<ncmds {
            guard position + 8 <= commands.count else { break }
            let pair = commands.withUnsafeBytes { raw -> (UInt32, UInt32) in
                (raw.loadUnaligned(fromByteOffset: position, as: UInt32.self),
                 raw.loadUnaligned(fromByteOffset: position + 4, as: UInt32.self))
            }
            let cmd = pair.0
            let cmdsize = pair.1
            guard cmdsize >= 8, position + Int(cmdsize) <= commands.count else { break }
            if cmd == lcEncryptionInfo || cmd == lcEncryptionInfo64, position + 20 <= commands.count {
                let values = commands.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
                    (raw.loadUnaligned(fromByteOffset: position + 8, as: UInt32.self),
                     raw.loadUnaligned(fromByteOffset: position + 12, as: UInt32.self),
                     raw.loadUnaligned(fromByteOffset: position + 16, as: UInt32.self))
                }
                result.append(SliceInfo(cputype: cputype, cryptoff: values.0,
                                        cryptsize: values.1, cryptid: values.2))
            }
            position += Int(cmdsize)
        }
        return result
    }

    /// Every Mach-O below `root` with the cryptid of each slice.
    static func scanTree(_ root: URL) -> [(path: String, slices: [SliceInfo])] {
        var rows: [(String, [SliceInfo])] = []
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: root.path) else { return [] }
        while let rawRelative = walker.nextObject() as? String {
            let components = rawRelative.split(separator: "/", omittingEmptySubsequences: true)
            let isHidden = components.contains { $0.hasPrefix(".") }
            if let type = walker.fileAttributes?[.type] as? FileAttributeType {
                if isHidden {
                    if type == .typeDirectory { walker.skipDescendants() }
                    continue
                }
                guard type == .typeRegular else { continue }
            } else {
                if isHidden { continue }
                let candidate = root.appendingPathComponent(rawRelative)
                let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            }
            let relative = components.joined(separator: "/")
            guard !relative.isEmpty else { continue }
            let fileURL = root.appendingPathComponent(relative)
            let fileSlices = slices(of: fileURL)
            guard !fileSlices.isEmpty else { continue }
            rows.append((relative, fileSlices))
        }
        return rows.sorted { $0.0 < $1.0 }
    }
}
