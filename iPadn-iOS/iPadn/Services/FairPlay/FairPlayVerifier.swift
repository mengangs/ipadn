import Foundation
import ZIPFoundation

/// One decrypted binary, as measured after packing.
struct FairPlayFileReport: Sendable {
    let path: String
    let cryptsize: Int
    let entropy: Double
    let codeWords: Int
    let cryptid: UInt32
    /// True when the slice was encrypted before this run.
    let wasEncrypted: Bool

    var ok: Bool {
        guard cryptid == 0 else { return false }
        guard wasEncrypted else { return true }
        // Real ARM64 code is well below 8 bits/byte and contains RET/PACIBSP
        // landmarks. A header-only "fix" keeps the ciphertext, so both checks
        // fail together. Tiny extension stubs are mostly zero padding, which is
        // why there is no entropy floor: the landmarks are the proof.
        return entropy < 7.5 && codeWords > 0
    }
}

struct FairPlayVerification: Sendable {
    let files: [FairPlayFileReport]
    let machOCount: Int
    let encryptedRemaining: Int
    let failures: [String]
    let totalBytes: Int64

    var isClean: Bool { encryptedRemaining == 0 && failures.isEmpty }

    var summary: String {
        let decrypted = files.filter { $0.wasEncrypted && $0.ok }.count
        var text = "Mach-O \(machOCount) 个，本次解密 \(decrypted) 个，残留加密 \(encryptedRemaining) 个"
        if !failures.isEmpty { text += "，校验失败 \(failures.count) 个" }
        return text
    }
}

/// Post-pack verification: proves the exported IPA contains real decrypted code,
/// not just a cleared `cryptid`.
enum FairPlayVerifier {

    static func entropy(_ bytes: Data) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var histogram = [Int](repeating: 0, count: 256)
        bytes.withUnsafeBytes { raw in
            for byte in raw { histogram[Int(byte)] += 1 }
        }
        let total = Double(bytes.count)
        var value = 0.0
        for count in histogram where count > 0 {
            let q = Double(count) / total
            value -= q * log2(q)
        }
        return value
    }

    static func codeWords(_ bytes: Data) -> Int {
        var count = 0
        bytes.withUnsafeBytes { raw in
            var index = 0
            while index + 4 <= raw.count {
                let word = raw.loadUnaligned(fromByteOffset: index, as: UInt32.self)
                if word == 0xd65f03c0 || word == 0xd503237f || word == 0xd65f0fff { count += 1 }
                index += 4
            }
        }
        return count
    }

    struct SliceCryptInfo: Sendable {
        let sliceOffset: Int
        let cryptoff: Int
        let cryptsize: Int
        let cryptid: UInt32
    }

    private static func thinSlice(_ data: Data, at sliceOffset: Int) -> SliceCryptInfo? {
        guard sliceOffset >= 0, sliceOffset + 32 <= data.count else { return nil }
        let header = data.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
            (raw.loadUnaligned(fromByteOffset: sliceOffset, as: UInt32.self),
             raw.loadUnaligned(fromByteOffset: sliceOffset + 16, as: UInt32.self),
             raw.loadUnaligned(fromByteOffset: sliceOffset + 20, as: UInt32.self))
        }
        guard header.0 == 0xfeedfacf else { return nil }
        let ncmds = header.1
        let sizeofcmds = header.2
        guard sizeofcmds > 0, sliceOffset + 32 + Int(sizeofcmds) <= data.count else { return nil }
        var position = sliceOffset + 32
        let end = position + Int(sizeofcmds)
        for _ in 0..<ncmds {
            guard position + 8 <= end else { break }
            let pair = data.withUnsafeBytes { raw -> (UInt32, UInt32) in
                (raw.loadUnaligned(fromByteOffset: position, as: UInt32.self),
                 raw.loadUnaligned(fromByteOffset: position + 4, as: UInt32.self))
            }
            guard pair.1 >= 8, position + Int(pair.1) <= end else { break }
            if pair.0 == 0x21 || pair.0 == 0x2c {
                guard position + 20 <= data.count else { break }
                let values = data.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
                    (raw.loadUnaligned(fromByteOffset: position + 8, as: UInt32.self),
                     raw.loadUnaligned(fromByteOffset: position + 12, as: UInt32.self),
                     raw.loadUnaligned(fromByteOffset: position + 16, as: UInt32.self))
                }
                return SliceCryptInfo(sliceOffset: sliceOffset,
                                      cryptoff: Int(values.0),
                                      cryptsize: Int(values.1),
                                      cryptid: values.2)
            }
            position += Int(pair.1)
        }
        return nil
    }

    static func fat64ArchOffsets(_ data: Data) -> [Int]? {
        guard data.count >= 8 else { return nil }
        let magicBE = data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
        guard magicBE == 0xcafebabe || magicBE == 0xcafebabf else { return nil }
        let is64 = magicBE == 0xcafebabf
        let count = Int(min(data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }, 64))
        let stride = is64 ? 32 : 20
        guard 8 + count * stride <= data.count else { return nil }
        var offsets: [Int] = []
        for i in 0..<count {
            let base = 8 + i * stride
            let cputype = data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: base, as: UInt32.self)) }
            guard (cputype & 0x0100_0000) != 0 else { continue }
            let off: UInt64 = data.withUnsafeBytes {
                if is64 {
                    return UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: base + 8, as: UInt64.self))
                }
                return UInt64(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)))
            }
            if off <= UInt64(Int.max) { offsets.append(Int(off)) }
        }
        return offsets
    }

    /// Reads 64-bit encrypted slices from thin (`0xfeedfacf`) or FAT (`0xcafebabe`/`0xcafebabf`) Mach-O headers.
    static func slices(_ data: Data) -> [SliceCryptInfo] {
        if let offsets = fat64ArchOffsets(data) {
            return offsets.compactMap { thinSlice(data, at: $0) }
        }
        if let single = thinSlice(data, at: 0) {
            return [single]
        }
        return []
    }

    /// Relative path matcher for `FairPlayDecryptor`'s `wasEncrypted` keys (relative to `Payload/<App>.app/`).
    static func matchesRelativePath(_ payloadRelativePath: String, expectedKey key: String) -> Bool {
        if payloadRelativePath == key { return true }
        if let slash = payloadRelativePath.firstIndex(of: "/"),
           payloadRelativePath[..<slash].hasSuffix(".app") {
            let bundleRelative = String(payloadRelativePath[payloadRelativePath.index(after: slash)...])
            if bundleRelative == key { return true }
        }
        return payloadRelativePath.hasSuffix("/" + key)
    }

    private struct EnoughData: Error {}

    /// Reads an entry, stopping once `limit` bytes are in memory. Verification
    /// only needs the header plus the crypt range, so a very large executable
    /// does not have to be materialised completely.
    private static func read(_ archive: Archive, _ entry: Entry, limit: Int) -> Data {
        var data = Data()
        data.reserveCapacity(min(Int(entry.uncompressedSize), max(limit, 64 << 10)))
        do {
            _ = try archive.extract(entry, bufferSize: 1 << 16, skipCRC32: true) { chunk in
                data.append(chunk)
                if data.count >= limit { throw EnoughData() }
            }
        } catch {
            // EnoughData or a truncated entry: what was read is what we check.
        }
        return data
    }

    /// Verifies the packaged IPA entry by entry: every 64-bit Mach-O slice must
    /// have `cryptid == 0`, and every slice that was encrypted before must now
    /// look like real code.
    static func verify(ipa url: URL, wasEncrypted: [String: Int]) throws -> FairPlayVerification {
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            throw ToolError.message("无法打开导出的安装包")
        }
        var files: [FairPlayFileReport] = []
        var remaining = 0
        var failures: [String] = []
        var total: Int64 = 0

        for entry in archive where entry.type == .file {
            guard entry.uncompressedSize >= 32 else { continue }
            // Header first: it tells how much of the file verification needs.
            var head = read(archive, entry, limit: 64 << 10)
            if let offsets = fat64ArchOffsets(head),
               let maxOffset = offsets.max(),
               maxOffset + (64 << 10) > head.count,
               maxOffset < (256 << 20) {
                head = read(archive, entry, limit: min(maxOffset + (64 << 10), 256 << 20))
            }
            let inspectedSlices = slices(head)
            guard !inspectedSlices.isEmpty else { continue }
            let maxNeeded = inspectedSlices.map { $0.sliceOffset + $0.cryptoff + $0.cryptsize }.max() ?? 0
            let needed = min(max(64 << 10, maxNeeded), 256 << 20)
            let data = needed <= head.count ? head : read(archive, entry, limit: needed)
            let relative = entry.path.hasPrefix("Payload/")
                ? String(entry.path.dropFirst("Payload/".count))
                : entry.path
            let expected = wasEncrypted.first { key, _ in
                matchesRelativePath(relative, expectedKey: key)
            }?.value

            var worstCryptID: UInt32 = 0
            var worstEntropy = 0.0
            var minCodeWords = Int.max
            var inspectedSize = 0
            for info in inspectedSlices {
                let start = info.sliceOffset + info.cryptoff
                let size = min(info.cryptsize, max(0, data.count - start))
                let crypt = (start >= 0 && start <= data.count && size > 0)
                    ? data.subdata(in: start..<(start + size))
                    : Data()
                let sliceEntropy = entropy(crypt)
                let sliceWords = codeWords(crypt)
                if info.cryptid != 0 { worstCryptID = info.cryptid }
                if sliceEntropy > worstEntropy { worstEntropy = sliceEntropy }
                if sliceWords < minCodeWords { minCodeWords = sliceWords }
                if size > inspectedSize { inspectedSize = size }
            }
            if minCodeWords == Int.max { minCodeWords = 0 }

            let report = FairPlayFileReport(path: relative,
                                            cryptsize: inspectedSize,
                                            entropy: worstEntropy,
                                            codeWords: minCodeWords,
                                            cryptid: worstCryptID,
                                            wasEncrypted: expected != nil)
            files.append(report)
            total += Int64(entry.uncompressedSize)
            if worstCryptID != 0 { remaining += 1 }
            if !report.ok { failures.append(report.path) }
        }

        return FairPlayVerification(files: files, machOCount: files.count,
                                    encryptedRemaining: remaining, failures: failures,
                                    totalBytes: total)
    }
}
