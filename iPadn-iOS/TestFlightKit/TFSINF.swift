import Foundation

// C shims from the apple_auth archive (same symbols the probe links).
@_silgen_name("tf_add_sinf")
private func tf_add_sinf_c(_ ipa: UnsafePointer<CChar>?,
                           _ entry: UnsafePointer<CChar>?,
                           _ data: UnsafePointer<UInt8>?,
                           _ size: UInt32) -> Int32

@_silgen_name("tf_zip_open_read")
private func tf_zip_open_read_c(_ path: UnsafePointer<CChar>?) -> OpaquePointer?

@_silgen_name("tf_zip_close_read")
private func tf_zip_close_read_c(_ handle: OpaquePointer?)

@_silgen_name("tf_zip_count")
private func tf_zip_count_c(_ handle: OpaquePointer?) -> Int32

@_silgen_name("tf_zip_name")
private func tf_zip_name_c(_ handle: OpaquePointer?, _ index: UInt32) -> UnsafePointer<CChar>?

@_silgen_name("tf_zip_read")
private func tf_zip_read_c(_ handle: OpaquePointer?,
                           _ entry: UnsafePointer<CChar>?,
                           _ data: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                           _ size: UnsafeMutablePointer<UInt32>?) -> Int32

@_silgen_name("tf_free")
private func tf_free_c(_ pointer: UnsafeMutableRawPointer?)

@_silgen_name("tf_last_error")
private func tf_last_error_c() -> UnsafePointer<CChar>?

/// Writes `Payload/<App>.app/SC_Info/<name>.sinf` into a finished IPA.
///
/// The blobs come from the install metadata's `sinf` plist; the member names come from
/// the app's own `SC_Info/Manifest.plist` (`SinfPaths`), or from `CFBundleExecutable`
/// when that manifest is absent. The archive rewrite is the linked libzip shim.
public enum TFSINF {

    public struct Report: Sendable {
        public var paths: [String] = []
        public var sizes: [Int] = []
        public var members: Int = 0
    }

    public static func install(metadata: Data, ipa: URL) throws -> Report {
        guard let records = try records(fromMetadata: metadata), !records.isEmpty else {
            return Report()
        }
        var report = Report()
        guard let handle = ipa.path.withCString({ tf_zip_open_read_c($0) }) else {
            throw TFError.malformed("SINF: cannot open \(ipa.lastPathComponent): \(lastError())")
        }
        let names = names(of: handle)
        tf_zip_close_read_c(handle)
        guard let root = appRoot(in: names) else {
            throw TFError.malformed("SINF: no Payload/<App>.app/Info.plist in IPA")
        }
        let paths = try sinfPaths(root: root, names: names, ipa: ipa)
        guard paths.count == records.count else {
            throw TFError.malformed("SINF: \(records.count) records but \(paths.count) manifest paths")
        }
        for (index, record) in records.enumerated() {
            let entry = root + paths[index]
            try validate(entry: entry)
            let size = UInt32(record.count)
            let ok = ipa.path.withCString { ipaPointer in
                entry.withCString { entryPointer in
                    record.withUnsafeBytes { raw in
                        tf_add_sinf_c(ipaPointer, entryPointer,
                                      raw.bindMemory(to: UInt8.self).baseAddress, size)
                    }
                }
            }
            guard ok == 1 else {
                throw TFError.malformed("SINF: add \(entry) failed: \(lastError())")
            }
            report.paths.append(entry)
            report.sizes.append(record.count)
        }
        guard let after = ipa.path.withCString({ tf_zip_open_read_c($0) }) else {
            throw TFError.malformed("SINF: cannot reopen \(ipa.lastPathComponent): \(lastError())")
        }
        report.members = Int(tf_zip_count_c(after))
        tf_zip_close_read_c(after)
        for (index, entry) in report.paths.enumerated() {
            try verify(ipa: ipa, entry: entry, expected: records[index])
        }
        return report
    }

    /// Reads every member, which makes libzip verify each CRC: a cheap `testzip`.
    public static func verifyArchive(ipa: URL) throws -> Int {
        guard let handle = ipa.path.withCString({ tf_zip_open_read_c($0) }) else {
            throw TFError.malformed("testzip: cannot open \(ipa.lastPathComponent): \(lastError())")
        }
        defer { tf_zip_close_read_c(handle) }
        let count = Int(tf_zip_count_c(handle))
        for name in names(of: handle) {
            var pointer: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            let ok = name.withCString { tf_zip_read_c(handle, $0, &pointer, &size) }
            if let pointer { tf_free_c(pointer) }
            guard ok == 1 else {
                throw TFError.malformed("testzip: \(name) failed CRC: \(lastError())")
            }
        }
        return count
    }

    public static func memberCount(ipa: URL) -> Int {
        guard let handle = ipa.path.withCString({ tf_zip_open_read_c($0) }) else { return -1 }
        defer { tf_zip_close_read_c(handle) }
        return Int(tf_zip_count_c(handle))
    }

    public static func members(ipa: URL) -> [String] {
        guard let handle = ipa.path.withCString({ tf_zip_open_read_c($0) }) else { return [] }
        defer { tf_zip_close_read_c(handle) }
        return names(of: handle)
    }

    /// `CFBundleIdentifier` of the single `Payload/<App>.app` in the archive.
    public static func bundleID(ipa: URL) -> String? {
        for name in members(ipa: ipa) where name.hasPrefix("Payload/") && name.hasSuffix(".app/Info.plist") {
            guard let data = read(ipa: ipa, entry: name),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let value = plist["CFBundleIdentifier"] as? String else { continue }
            return value
        }
        return nil
    }

    /// Counts Mach-O images whose `LC_ENCRYPTION_INFO*` still says encrypted (cryptid != 0).
    /// Only plausible executable members are read; a member larger than `limit` is skipped
    /// and reported, because libzip exposes whole entries only.
    public static func encryptedMachOCount(ipa: URL, limit: Int = 96 << 20,
                                          skipped: inout [String]) -> Int {
        var count = 0
        let directory = try? ZipReader(url: ipa)
        for name in members(ipa: ipa) where isExecutableCandidate(name) {
            if let declared = directory?.uncompressedSize(named: name), declared > limit {
                skipped.append(name)
                continue
            }
            guard let data = read(ipa: ipa, entry: name) else { continue }
            guard data.count <= limit else { skipped.append(name); continue }
            guard let cryptid = cryptid(of: data) else { continue }
            if cryptid != 0 {
                count += 1
                skipped.append("enc:" + name)
            }
        }
        return count
    }

    static func isExecutableCandidate(_ name: String) -> Bool {
        guard name.hasPrefix("Payload/") else { return false }
        guard !name.hasSuffix(".plist"), !name.hasSuffix(".nib"), !name.hasSuffix(".car"),
              !name.hasSuffix(".png"), !name.hasSuffix(".json"), !name.hasSuffix(".strings") else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = parts.last, !last.contains(".") else { return false }
        // Payload/<App>.app/<exe>, Payload/<App>.app/PlugIns/<X>.appex/<exe>,
        // Payload/<App>.app/Frameworks/<Y>.framework/<binary>
        return parts.count == 3 || parts.count == 5
    }

    /// Minimal Mach-O reader: returns the cryptid of the first LC_ENCRYPTION_INFO* command.
    static func cryptid(of data: Data) -> Int32? {
        guard data.count > 32 else { return nil }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let is64: Bool
        switch magic {
        case 0xFEEDFACF: is64 = true
        case 0xFEEDFACE: is64 = false
        default: return nil
        }
        let headerSize = is64 ? 32 : 28
        guard data.count >= headerSize else { return nil }
        let ncmds: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        var offset = headerSize
        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else { return nil }
            let cmd: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            let size: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
            let commandSize = Int(size)
            guard commandSize >= 8 else { return nil }
            if cmd == 0x21 || cmd == 0x2C {
                // encryption_info_command(_64): cmd(0), cmdsize(4), cryptoff(8), cryptsize(12), cryptid(16).
                if offset + 20 <= data.count {
                    return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: Int32.self) }
                }
                return nil
            }
            offset += commandSize
        }
        return nil
    }

    // MARK: metadata

    private static func records(fromMetadata metadata: Data) throws -> [Data]? {
        guard let root = try? JSONSerialization.jsonObject(with: metadata) else { return nil }
        // `sinf` is not top level: it lives at `data.sinf`, and `packages.full.sinf` carries a
        // copy. Search for the first string that parses as a `sinfs` plist.
        var candidates: [String] = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                for (key, value) in dictionary {
                    if key == "sinf", let text = value as? String, !text.isEmpty {
                        candidates.append(text)
                    }
                    walk(value)
                }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        guard !candidates.isEmpty else { return nil }

        var lastError: Error?
        for text in candidates {
            do {
                let parsed = try parse(text)
                if !parsed.isEmpty { return parsed }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private static func parse(_ text: String) throws -> [Data] {
        let trimmed = text.drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
        var plistBytes: Data
        if trimmed.hasPrefix("<") {
            plistBytes = Data(trimmed.utf8)
        } else {
            guard let decoded = Data(base64Encoded: text) else { return [] }
            plistBytes = decoded
        }
        let parsed = try PropertyListSerialization.propertyList(from: plistBytes, options: [], format: nil)
        var array: [Any]?
        if let dictionary = parsed as? [String: Any] {
            array = dictionary["sinfs"] as? [Any]
        } else {
            array = parsed as? [Any]
        }
        guard let array, !array.isEmpty else { return [] }
        var records: [Data] = []
        for element in array {
            guard let dictionary = element as? [String: Any],
                  let blob = dictionary["sinf"] as? Data, !blob.isEmpty else {
                throw TFError.malformed("SINF: invalid record in metadata sinf plist")
            }
            records.append(blob)
        }
        return records
    }

    // MARK: archive inspection

    private static func names(of handle: OpaquePointer) -> [String] {
        let count = Int(tf_zip_count_c(handle))
        guard count > 0 else { return [] }
        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            if let pointer = tf_zip_name_c(handle, UInt32(index)) {
                result.append(String(cString: pointer))
            }
        }
        return result
    }

    private static func appRoot(in names: [String]) -> String? {
        let candidates = names.filter {
            $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist") &&
                $0.split(separator: "/").count == 3
        }
        guard candidates.count == 1, let name = candidates.first else { return nil }
        return String(name.dropLast("Info.plist".count))
    }

    private static func sinfPaths(root: String, names: [String], ipa: URL) throws -> [String] {
        let manifest = root + "SC_Info/Manifest.plist"
        if names.contains(manifest) {
            guard let data = read(ipa: ipa, entry: manifest) else {
                throw TFError.malformed("SINF: cannot read \(manifest)")
            }
            let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dictionary = parsed as? [String: Any],
                  let paths = dictionary["SinfPaths"] as? [String], !paths.isEmpty else {
                throw TFError.malformed("SINF: \(manifest) has no SinfPaths")
            }
            return paths
        }
        let infoPath = root + "Info.plist"
        guard let data = read(ipa: ipa, entry: infoPath),
              let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let executable = parsed["CFBundleExecutable"] as? String, !executable.isEmpty else {
            throw TFError.malformed("SINF: cannot derive the executable name")
        }
        return ["SC_Info/\(executable).sinf"]
    }

    private static func read(ipa: URL, entry: String) -> Data? {
        guard let handle = ipa.path.withCString({ tf_zip_open_read_c($0) }) else { return nil }
        defer { tf_zip_close_read_c(handle) }
        var pointer: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        let ok = entry.withCString { tf_zip_read_c(handle, $0, &pointer, &size) }
        guard ok == 1, let pointer else { return nil }
        defer { tf_free_c(pointer) }
        return Data(bytes: pointer, count: Int(size))
    }

    private static func validate(entry: String) throws {
        guard !entry.hasPrefix("/"), entry.hasSuffix(".sinf"),
              !entry.contains(".."), !entry.contains("\0"), !entry.contains("//"),
              entry.contains("/SC_Info/") else {
            throw TFError.malformed("SINF: unsafe member path \(entry)")
        }
    }

    private static func verify(ipa: URL, entry: String, expected: Data) throws {
        guard let data = read(ipa: ipa, entry: entry), data == expected else {
            throw TFError.malformed("SINF: verification of \(entry) failed")
        }
    }

    private static func lastError() -> String {
        guard let pointer = tf_last_error_c() else { return "unknown error" }
        return String(cString: pointer)
    }
}
