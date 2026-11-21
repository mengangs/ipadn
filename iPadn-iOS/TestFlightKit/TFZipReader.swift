import Foundation
import Compression

// TFBundleName 的只读 ZIP 依赖，同为待接线状态；不要单独删除。

/// Read-only ZIP access by name. Products are already on disk, so entries are located
/// through the central directory and inflated on demand instead of extracting the archive.
struct ZipReader {
    let entire: [String]
    private let url: URL
    private let entries: [String: (offset: Int, compressed: Int, size: Int, method: Int)]

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // Locate the end-of-central-directory record within the last 64 KiB.
        let tailLength = min(65_536, Int(size))
        try handle.seek(toOffset: UInt64(Int(size) - tailLength))
        let tail = try handle.read(upToCount: tailLength) ?? Data()
        guard let eocdRange = tail.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards) else {
            throw TFError.malformed("zip: 找不到中央目录")
        }
        let eocd = Int(eocdRange.lowerBound)
        guard eocd + 22 <= tail.count else {
            throw TFError.malformed("zip: 中央目录头截断")
        }
        func u16(_ at: Int) -> Int { Int(tail[at]) | Int(tail[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        let count = u16(eocd + 10)
        var cursor = u32(eocd + 16)
        guard count <= 200_000, cursor >= 0, UInt64(cursor) <= size else {
            throw TFError.malformed("zip: 中央目录偏移无效")
        }
        var map: [String: (Int, Int, Int, Int)] = [:]
        var names: [String] = []
        try handle.seek(toOffset: UInt64(cursor))
        for _ in 0..<count {
            let header = try handle.read(upToCount: 46) ?? Data()
            guard header.count == 46, header[0] == 0x50, header[1] == 0x4b else { break }
            let method = Int(header[10]) | Int(header[11]) << 8
            let compressed = Int(header[20]) | Int(header[21]) << 8 | Int(header[22]) << 16 | Int(header[23]) << 24
            let uncompressed = Int(header[24]) | Int(header[25]) << 8 | Int(header[26]) << 16 | Int(header[27]) << 24
            let nameLength = Int(header[28]) | Int(header[29]) << 8
            let extraLength = Int(header[30]) | Int(header[31]) << 8
            let commentLength = Int(header[32]) | Int(header[33]) << 8
            let localOffset = Int(header[42]) | Int(header[43]) << 8 | Int(header[44]) << 16 | Int(header[45]) << 24
            guard compressed >= 0, uncompressed >= 0, localOffset >= 0 else { break }
            let nameData = try handle.read(upToCount: nameLength) ?? Data()
            let name = String(decoding: nameData, as: UTF8.self)
            map[name] = (localOffset, compressed, uncompressed, method)
            names.append(name)
            cursor += 46 + nameLength + extraLength + commentLength
            guard cursor >= 0, UInt64(cursor) <= size else { break }
            try handle.seek(toOffset: UInt64(cursor))
        }
        self.entries = map
        self.entire = names
    }

    func uncompressedSize(named name: String) -> Int? {
        entries[name]?.size
    }

    func data(named name: String) -> Data? {
        guard let entry = entries[name] else { return nil }
        let maxBytes = 8 << 20
        guard entry.compressed >= 0, entry.compressed <= maxBytes,
              entry.size >= 0, entry.size <= maxBytes else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
              let header = try? handle.read(upToCount: 30), header.count == 30 else { return nil }
        let nameLength = Int(header[26]) | Int(header[27]) << 8
        let extraLength = Int(header[28]) | Int(header[29]) << 8
        guard (try? handle.seek(toOffset: UInt64(entry.offset + 30 + nameLength + extraLength))) != nil,
              let raw = try? handle.read(upToCount: entry.compressed) else { return nil }
        guard entry.method == 0 else { return raw.isEmpty ? nil : raw.inflate(to: entry.size) }
        return raw.count <= maxBytes ? raw : nil
    }
}

private extension Data {
    /// Raw DEFLATE (zip entries carry no zlib header), inflated with the system API.
    func inflate(to size: Int) -> Data? {
        guard size > 0, size <= 8 << 20 else { return nil }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return self.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, size, sourceBase, self.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? output : nil
    }
}
