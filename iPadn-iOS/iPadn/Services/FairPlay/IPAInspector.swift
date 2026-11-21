import Foundation
import Compression

/// Reads how an IPA is encrypted without unpacking the whole archive, and
/// without guessing: every Mach-O in `Payload/` (main executable, frameworks,
/// extensions) is inspected, and anything that cannot be read completely stays
/// `unknown` instead of being reported as "not encrypted".
enum IPAInspector {

    static func inspect(url: URL) -> IPADetection {
        guard let archive = ZipDirectory(url: url) else {
            return IPADetection(state: .unknown, note: AppText.text("无法读取 ZIP 目录"))
        }
        if archive.isZip64 {
            return IPADetection(state: .unknown, note: AppText.text("ZIP64 布局，未做部分读取"))
        }
        let candidates = deduplicatedCandidates(in: archive.entries)
        guard !candidates.isEmpty else {
            return IPADetection(state: .unknown, note: AppText.text("没有找到可检查的 Mach-O"))
        }

        var binaries: [BinaryEncryption] = []
        var sawEncrypted = false
        var sawUnknown = false
        var sawPlain = false

        for entry in candidates {
            guard entry.uncompressedSize > 0 else { continue }
            let result = inspect(entry: entry, archive: archive)
            // A data file without extension that turned out not to be Mach-O.
            if result.cryptids.isEmpty && result.state == .plain { continue }
            binaries.append(result)
            switch result.state {
            case .encrypted: sawEncrypted = true
            case .plain: sawPlain = true
            case .unknown: sawUnknown = true
            }
        }

        let state: EncryptionState
        var note: String?
        if sawEncrypted {
            state = .encrypted
        } else if sawUnknown {
            state = .unknown
            note = AppText.text("部分二进制无法完整读取，未做结论")
        } else if sawPlain {
            state = .plain
        } else {
            state = .unknown
            note = AppText.text("没有可用结论")
        }
        return IPADetection(state: state, binaries: binaries, note: note)
    }

    // MARK: - candidates

    #if DEBUG
    /// Diagnostic used by the research lab: explains why a package ended up as
    /// `unknown` (archive readable? candidates found? headers parsed?).
    static func debugReport(url: URL) -> [String] {
        var lines: [String] = ["inspect: \(url.lastPathComponent)"]
        guard let archive = ZipDirectory(url: url) else {
            return lines + ["zip: unreadable"]
        }
        lines.append("zip: entries=\(archive.entries.count) zip64=\(archive.isZip64) size=\(archive.fileSize)")
        let candidates = deduplicatedCandidates(in: archive.entries)
        lines.append("candidates: \(candidates.count)")
        for entry in candidates.prefix(6) {
            guard let reader = archive.reader(for: entry) else {
                lines.append("  \(entry.name): no reader (method \(entry.method))")
                continue
            }
            let ok = reader.ensure(64)
            let head = reader.data.prefix(4).map { String(format: "%02x", $0) }.joined()
            let parsed = ok ? String(describing: parse(reader.data)).prefix(40) : "nil"
            lines.append("  \(entry.name): ensure=\(ok) head=\(head) parse=\(parsed)")
        }
        let result = inspect(url: url)
        lines.append("result: \(result.state.rawValue) note=\(result.note ?? "-") "
            + "enc=\(result.encryptedCount) plain=\(result.plainCount) unknown=\(result.unknownCount)")
        return lines
    }
    #endif

    private static let nonBinaryExtensions: Set<String> = [
        "plist", "strings", "stringsdict", "xcstrings", "nib", "storyboardc", "car",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "svg", "ico",
        "json", "xml", "txt", "md", "html", "css", "js", "otf", "ttf", "ttc",
        "mp3", "m4a", "wav", "caf", "aac", "mp4", "mov", "sinf", "supp", "supf", "scx",
        "mobileprovision", "der", "cer", "crt", "pem", "mom", "omo", "db", "sqlite"
    ]

    /// Deduplicates central-directory entries by path (keeping the last entry to match
    /// standard ZIP extraction semantics) so patched/resigned IPAs never yield duplicate IDs.
    private static func deduplicatedCandidates(in entries: [ZipEntry]) -> [ZipEntry] {
        var indexByName: [String: Int] = [:]
        var result: [ZipEntry] = []
        for entry in entries where isCandidateBinary(entry.name) {
            if let existing = indexByName[entry.name] {
                result[existing] = entry
            } else {
                indexByName[entry.name] = result.count
                result.append(entry)
            }
        }
        return result
    }

    /// Any extensionless file, `.dylib`, or executable bundle member inside `Payload/`
    /// (excluding known resource extensions and `SC_Info`/`_CodeSignature` metadata).
    private static func isCandidateBinary(_ path: String) -> Bool {
        guard path.hasPrefix("Payload/") else { return false }
        // Directory entries end with "/" and carry no payload; treating them as
        // binaries would mark every package "unknown".
        guard !path.hasSuffix("/") else { return false }
        let parts = path.split(separator: "/")
        guard let last = parts.last else { return false }
        if parts.contains("_CodeSignature") || parts.contains("SC_Info") { return false }
        if parts.contains(where: { $0.hasSuffix(".lproj") || $0.hasSuffix(".bundle") || $0.hasSuffix(".momd") }) {
            return false
        }
        if !last.contains(".") { return true }
        let ext = (String(last) as NSString).pathExtension.lowercased()
        if ext == "dylib" || ext == "so" { return true }
        if nonBinaryExtensions.contains(ext) { return false }
        // Support dotted CFBundleExecutable names directly inside *.app/ or *.appex/ or *.framework/.
        if parts.count >= 3 {
            let parent = parts[parts.count - 2]
            if parent.hasSuffix(".app") || parent.hasSuffix(".appex") || parent.hasSuffix(".framework") {
                return true
            }
        }
        return false
    }

    // MARK: - per binary

    private static func inspect(entry: ZipEntry, archive: ZipDirectory) -> BinaryEncryption {
        guard let reader = archive.reader(for: entry) else {
            return BinaryEncryption(path: entry.name, state: .unknown, cryptids: [])
        }
        guard reader.ensure(64), let outcome = parse(reader.data) else {
            return BinaryEncryption(path: entry.name, state: .unknown, cryptids: [])
        }
        return resolve(outcome, reader: reader, path: entry.name)
    }

    private static func resolve(_ outcome: ParseOutcome, reader: InflatingReader,
                                path: String) -> BinaryEncryption {
        switch outcome {
        case .notMachO:
            return BinaryEncryption(path: path, state: .plain, cryptids: [])
        case .needMore(let bytes):
            guard bytes <= reader.maxReadable, reader.ensure(bytes),
                  let again = parse(reader.data) else {
                return BinaryEncryption(path: path, state: .unknown, cryptids: [])
            }
            return resolve(again, reader: reader, path: path)
        case .thin(let cryptid):
            return BinaryEncryption(path: path,
                                    state: cryptid == 0 ? .plain : .encrypted,
                                    cryptids: [cryptid])
        case .fat(let slices):
            var cryptids: [Int32] = []
            for slice in slices {
                let need = slice.offset + 4096
                guard need <= reader.maxReadable, reader.ensure(need) else {
                    return BinaryEncryption(path: path, state: .unknown, cryptids: cryptids)
                }
                let sliceData = reader.data.subdata(in: slice.offset..<reader.data.count)
                guard let parsed = parse(sliceData) else {
                    return BinaryEncryption(path: path, state: .unknown, cryptids: cryptids)
                }
                switch parsed {
                case .thin(let cryptid):
                    cryptids.append(cryptid)
                case .needMore(let bytes):
                    let absolute = slice.offset + bytes
                    guard absolute <= reader.maxReadable, reader.ensure(absolute) else {
                        return BinaryEncryption(path: path, state: .unknown, cryptids: cryptids)
                    }
                    let more = reader.data.subdata(in: slice.offset..<reader.data.count)
                    guard case .thin(let cryptid)? = parse(more) else {
                        return BinaryEncryption(path: path, state: .unknown, cryptids: cryptids)
                    }
                    cryptids.append(cryptid)
                default:
                    return BinaryEncryption(path: path, state: .unknown, cryptids: cryptids)
                }
            }
            guard !cryptids.isEmpty else {
                return BinaryEncryption(path: path, state: .unknown, cryptids: [])
            }
            return BinaryEncryption(path: path,
                                    state: cryptids.contains { $0 > 0 } ? .encrypted : .plain,
                                    cryptids: cryptids)
        }
    }

    // MARK: - Mach-O parsing

    private struct FatSlice { let offset: Int; let size: Int }

    private enum ParseOutcome {
        case thin(Int32)
        case fat([FatSlice])
        case needMore(Int)
        case notMachO
    }

    private static let maxLoadCommands = 8 * 1024 * 1024

    private static func parse(_ data: Data) -> ParseOutcome? {
        guard data.count >= 8 else { return nil }
        guard let magicLE = data.le32(0) else { return nil }
        let magicBE = (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16)
            | (UInt32(data[2]) << 8) | UInt32(data[3])

        // Thin, little endian (arm64 / armv7).
        if magicLE == 0xFEEDFACF || magicLE == 0xFEEDFACE {
            let is64 = magicLE == 0xFEEDFACF
            let headerSize = is64 ? 32 : 28
            guard data.count >= headerSize else { return .needMore(headerSize) }
            // mach_header_64: magic, cputype, cpusubtype, filetype, ncmds(16), sizeofcmds(20).
            guard let sizeofcmds = data.le32(20), sizeofcmds <= UInt32(maxLoadCommands - headerSize) else { return nil }
            let needed = headerSize + Int(sizeofcmds)
            if data.count < needed { return .needMore(needed) }
            guard let cryptid = scanLoadCommands(data, total: needed) else { return nil }
            return .thin(cryptid)
        }

        // Fat: the arch table is big endian.
        if magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF {
            let is64 = magicBE == 0xCAFEBABF
            guard data.count >= 8, let count = data.be32(4) else { return nil }
            let stride = is64 ? 32 : 20
            guard count > 0, count <= 32 else { return nil }
            let tableSize = 8 + Int(count) * stride
            guard tableSize <= maxLoadCommands else { return nil }
            if data.count < tableSize { return .needMore(tableSize) }
            var slices: [FatSlice] = []
            for index in 0..<Int(count) {
                let base = 8 + index * stride
                let offset64: UInt64? = is64 ? data.be64(base + 8) : data.be32(base + 8).map(UInt64.init)
                let size64: UInt64? = is64 ? data.be64(base + 16) : data.be32(base + 12).map(UInt64.init)
                guard let offset64, let size64, size64 > 0, offset64 > 0,
                      offset64 <= UInt64(Int.max / 2), size64 <= UInt64(Int.max / 2) else { return nil }
                slices.append(FatSlice(offset: Int(offset64), size: Int(size64)))
            }
            return .fat(slices)
        }

        return .notMachO
    }

    private static func scanLoadCommands(_ data: Data, total: Int) -> Int32? {
        guard let rawCount = data.le32(16) else { return nil }
        let is64 = data.le32(0) == 0xFEEDFACF
        var offset = is64 ? 32 : 28
        var cryptid: Int32 = 0
        for _ in 0..<Int(rawCount) {
            guard offset + 8 <= total, let cmd = data.le32(offset),
                  let size = data.le32(offset + 4) else { return nil }
            let commandSize = Int(size)
            guard commandSize >= 8, (commandSize & 3) == 0, offset <= total - commandSize else { return nil }
            if cmd == 0x2C || cmd == 0x21 {   // LC_ENCRYPTION_INFO_64 / LC_ENCRYPTION_INFO
                let minCmd = cmd == 0x2C ? 24 : 20
                guard commandSize >= minCmd, let value = data.le32(offset + 16) else { return nil }
                let candidate = Int32(bitPattern: value)
                if cryptid == 0 || candidate > 0 {
                    cryptid = candidate
                }
            }
            offset += commandSize
        }
        return cryptid
    }
}

// MARK: - ZIP central directory

struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
}

/// Minimal ZIP reader: central directory only, plus a per-entry reader that
/// inflates just the first few kilobytes of an entry.
struct ZipDirectory {
    let handle: FileHandle
    let entries: [ZipEntry]
    let isZip64: Bool
    let fileSize: UInt64

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else { return nil }
        self.handle = handle
        self.fileSize = size
        guard size > 22 else { return nil }

        let tailLength = Int(min(size, 70_000))
        guard let tail = FileSlices.read(handle, at: size - UInt64(tailLength), count: tailLength) else {
            return nil
        }
        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.le32(index) == 0x06054B50 { eocd = index; break }
            index -= 1
        }
        guard let eocd, eocd + 22 <= tail.count,
              let entryCount = tail.le16(eocd + 10),
              let cdOffset = tail.le32(eocd + 16) else { return nil }

        if cdOffset == 0xFFFF_FFFF || entryCount == 0xFFFF {
            self.isZip64 = true
            self.entries = []
            return
        }
        guard cdOffset != 0, UInt64(cdOffset) < size else {
            self.isZip64 = false
            self.entries = []
            return
        }
        let cdSize = Int(min(size - UInt64(cdOffset), 16 * 1024 * 1024))
        guard let directory = FileSlices.read(handle, at: UInt64(cdOffset), count: cdSize) else { return nil }

        var parsed: [ZipEntry] = []
        var cursor = 0
        for _ in 0..<Int(entryCount) {
            guard cursor + 46 <= directory.count, directory.le32(cursor) == 0x02014B50,
                  let method = directory.le16(cursor + 10),
                  let compressed = directory.le32(cursor + 20),
                  let uncompressed = directory.le32(cursor + 24),
                  let nameLength = directory.le16(cursor + 28),
                  let extraLength = directory.le16(cursor + 30),
                  let commentLength = directory.le16(cursor + 32),
                  let localOffset = directory.le32(cursor + 42) else { break }
            let nameStart = cursor + 46
            guard nameStart + Int(nameLength) <= directory.count else { break }
            let nameData = directory.subdata(in: nameStart..<(nameStart + Int(nameLength)))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            if compressed != 0xFFFF_FFFF && localOffset != 0xFFFF_FFFF {
                parsed.append(ZipEntry(name: name, method: method,
                                       compressedSize: UInt64(compressed),
                                       uncompressedSize: UInt64(uncompressed),
                                       localHeaderOffset: UInt64(localOffset)))
            }
            cursor = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        self.isZip64 = false
        self.entries = parsed
    }

    func reader(for entry: ZipEntry) -> InflatingReader? {
        guard entry.method == 0 || entry.method == 8 else { return nil }
        guard let header = FileSlices.read(handle, at: entry.localHeaderOffset, count: 30),
              header.le32(0) == 0x04034B50,
              let nameLength = header.le16(26),
              let extraLength = header.le16(28) else { return nil }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        guard dataStart < fileSize else { return nil }
        return InflatingReader(handle: handle,
                               dataStart: dataStart,
                               compressedSize: entry.compressedSize,
                               uncompressedSize: entry.uncompressedSize,
                               stored: entry.method == 0)
    }
}

private enum FileSlices {
    static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }
}

/// Sequential reader over one ZIP entry that inflates only as much as asked for.
final class InflatingReader {
    let maxReadable: Int
    private let handle: FileHandle
    private let dataStart: UInt64
    private let compressedSize: UInt64
    private let stored: Bool
    private var consumed: UInt64 = 0
    private var stream: UnsafeMutablePointer<compression_stream>?
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputCapacity = 64 * 1024
    private var finished = false
    private(set) var data = Data()

    init(handle: FileHandle, dataStart: UInt64, compressedSize: UInt64,
         uncompressedSize: UInt64, stored: Bool) {
        self.handle = handle
        self.dataStart = dataStart
        self.compressedSize = compressedSize
        self.stored = stored
        self.maxReadable = Int(min(uncompressedSize, 32 * 1024 * 1024))
        self.inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
    }

    deinit {
        if let stream {
            compression_stream_destroy(stream)
            stream.deallocate()
        }
        inputBuffer.deallocate()
    }

    /// Ensures at least `count` decompressed bytes are buffered. Returns false
    /// when the entry ends first (the caller must then treat it as unknown).
    @discardableResult
    func ensure(_ count: Int) -> Bool {
        if data.count >= count { return true }
        let target = min(count, maxReadable)
        guard target > 0 else { return false }
        return stored ? readStored(target) : inflate(target)
    }

    private func readStored(_ target: Int) -> Bool {
        let remaining = compressedSize - consumed
        guard remaining > 0 else { return data.count >= target }
        let want = min(UInt64(target - data.count), remaining)
        guard let chunk = FileSlices.read(handle, at: dataStart + consumed, count: Int(want)) else {
            return false
        }
        consumed += UInt64(chunk.count)
        data.append(chunk)
        return data.count >= target
    }

    private func inflate(_ target: Int) -> Bool {
        if stream == nil {
            let pointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            guard compression_stream_init(pointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                    == COMPRESSION_STATUS_OK else {
                pointer.deallocate()
                return false
            }
            stream = pointer
        }
        guard let stream else { return false }

        while data.count < target && !finished {
            if stream.pointee.src_size == 0 {
                let remaining = compressedSize - consumed
                guard remaining > 0 else { break }
                let want = Int(min(remaining, UInt64(inputCapacity)))
                guard let chunk = FileSlices.read(handle, at: dataStart + consumed, count: want),
                      !chunk.isEmpty else { break }
                consumed += UInt64(chunk.count)
                chunk.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        inputBuffer.update(from: base.assumingMemoryBound(to: UInt8.self),
                                           count: chunk.count)
                    }
                }
                stream.pointee.src_ptr = UnsafePointer<UInt8>(inputBuffer)
                stream.pointee.src_size = chunk.count
            }

            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            let srcBefore = stream.pointee.src_size
            let flags: Int32 = consumed >= compressedSize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let produced = buffer.withUnsafeMutableBufferPointer { out -> Int in
                stream.pointee.dst_ptr = out.baseAddress!
                stream.pointee.dst_size = out.count
                let status = compression_stream_process(stream, flags)
                if status == COMPRESSION_STATUS_END || status == COMPRESSION_STATUS_ERROR {
                    finished = true
                }
                return out.count - stream.pointee.dst_size
            }
            if produced > 0 { data.append(contentsOf: buffer[0..<produced]) }
            if produced == 0 && stream.pointee.src_size == srcBefore {
                // Truncated or stalled deflate stream made zero forward progress; stop spinning.
                finished = true
                break
            }
            if produced == 0 && stream.pointee.src_size == 0 && consumed >= compressedSize {
                break
            }
        }
        return data.count >= target
    }
}

// MARK: - little/big endian helpers

private extension Data {
    func le16(_ offset: Int) -> UInt16? {
        guard offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func le32(_ offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func be32(_ offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func be64(_ offset: Int) -> UInt64? {
        guard offset + 8 <= count, let hi = be32(offset), let lo = be32(offset + 4) else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }
}
