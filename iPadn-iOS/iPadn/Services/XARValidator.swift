import Foundation
import CryptoKit

// Structural and checksum validation of a XAR archive (the Mac .pkg format),
// equivalent to ipatool's post-decryption check: inflate the table of
// contents, verify its checksum, then verify every file's archived checksum
// against the heap. A transport-encrypted or truncated download fails here.
enum XARValidator {
    struct Report: Equatable {
        let files: Int
        let heapBytes: Int64
    }

    static let headerLength = 28
    static let maxCompressedTOC: UInt64 = 64 * 1024 * 1024
    static let maxUncompressedTOC: UInt64 = 64 * 1024 * 1024

    static func validate(_ url: URL) throws -> Report {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let fileSize = Int64(try file.seekToEnd())
        try file.seek(toOffset: 0)
        let header = try file.read(upToCount: headerLength) ?? Data()
        guard header.count == headerLength, header.prefix(4) == Data("xar!".utf8) else {
            throw failure("不是 XAR 安装包")
        }
        let headerSize = number(header, 4, 2)
        let version = number(header, 6, 2)
        let compressedTOC = number(header, 8, 8)
        let uncompressedTOC = number(header, 16, 8)
        let checksumKind = number(header, 24, 4)
        guard version == 1, headerSize >= UInt64(headerLength), headerSize <= 4096,
              compressedTOC > 2, compressedTOC <= maxCompressedTOC,
              uncompressedTOC > 0, uncompressedTOC <= maxUncompressedTOC,
              headerSize + compressedTOC <= UInt64(fileSize) else {
            throw failure("安装包头部或目录长度无效")
        }
        var headerAlgorithm: String?
        switch checksumKind {
        case 0: headerAlgorithm = nil
        case 1: headerAlgorithm = "sha1"
        case 2: headerAlgorithm = "md5"
        case 3:
            // Named algorithm, NUL-terminated, directly after the fixed header.
            let extra = try file.read(upToCount: Int(headerSize) - headerLength) ?? Data()
            headerAlgorithm = String(decoding: extra.prefix { $0 != 0 }, as: UTF8.self).lowercased()
        default: throw failure("不支持的目录校验方式")
        }

        try file.seek(toOffset: headerSize)
        let compressed = try file.read(upToCount: Int(compressedTOC)) ?? Data()
        guard compressed.count == Int(compressedTOC) else { throw failure("安装包目录不完整") }
        let xml = try inflateZlib(compressed, expectedLength: Int(uncompressedTOC))
        let toc = try TOCParser.parse(xml)
        let heapStart = Int64(headerSize + compressedTOC)
        let heapBytes = fileSize - heapStart

        func range(offset: UInt64, size: UInt64) throws -> UInt64 {
            let (end, overflow) = offset.addingReportingOverflow(size)
            guard !overflow, end <= UInt64(heapBytes) else { throw failure("安装包数据超出文件范围，文件可能不完整") }
            return UInt64(heapStart) + offset
        }

        if let checksum = toc.checksum {
            guard headerAlgorithm == nil || headerAlgorithm == checksum.style else {
                throw failure("安装包目录校验方式不一致")
            }
            guard let length = Digest.length(checksum.style), checksum.size == UInt64(length) else {
                throw failure("不支持的目录校验方式")
            }
            try file.seek(toOffset: try range(offset: checksum.offset, size: checksum.size))
            let stored = try file.read(upToCount: length) ?? Data()
            guard stored == Digest.hash(checksum.style, compressed) else {
                throw failure("安装包目录校验失败，文件可能仍被加密或已损坏")
            }
        } else if headerAlgorithm != nil {
            throw failure("安装包缺少目录校验信息")
        }

        guard !toc.files.isEmpty else { throw failure("安装包中没有文件") }
        for entry in toc.files {
            guard let style = entry.style, let expected = Data(hex: entry.checksum),
                  Digest.length(style) == expected.count else {
                throw failure("安装包文件缺少可验证的校验值")
            }
            try file.seek(toOffset: try range(offset: entry.offset, size: entry.length))
            guard try Digest.stream(style, file: file, count: entry.length) == expected else {
                throw failure("安装包文件校验失败，文件可能仍被加密或已损坏")
            }
        }
        return Report(files: toc.files.count, heapBytes: heapBytes)
    }

    private static func failure(_ text: String) -> ToolError { .message("PKG 校验未通过：" + text) }

    private static func number(_ data: Data, _ offset: Int, _ length: Int) -> UInt64 {
        data[data.startIndex + offset ..< data.startIndex + offset + length].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    // XAR stores the TOC as a zlib stream (2-byte header, raw DEFLATE body,
    // big-endian Adler-32 trailer); Foundation's .zlib handles the body only.
    static func inflateZlib(_ data: Data, expectedLength: Int) throws -> Data {
        guard data.count > 6 else { throw failure("安装包目录不完整") }
        let cmf = data[data.startIndex], flags = data[data.startIndex + 1]
        guard cmf & 0x0f == 8, (UInt16(cmf) << 8 | UInt16(flags)) % 31 == 0, flags & 0x20 == 0 else {
            throw failure("安装包目录不是有效的压缩数据")
        }
        let raw = Data(data.dropFirst(2).dropLast(4))
        let trailer = data.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data,
              inflated.count == expectedLength, adler32(inflated) == trailer else {
            throw failure("安装包目录解压失败或长度不符")
        }
        return inflated
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            // 5552 is the largest block that cannot overflow before reduction.
            var index = 0
            while index < buffer.count {
                let end = min(index + 5552, buffer.count)
                for byte in buffer[index..<end] { a &+= UInt32(byte); b &+= a }
                a %= 65521; b %= 65521
                index = end
            }
        }
        return b << 16 | a
    }

    enum Digest {
        static func length(_ style: String) -> Int? {
            ["sha1": 20, "md5": 16, "sha256": 32, "sha512": 64][style]
        }
        static func hash(_ style: String, _ data: Data) -> Data {
            switch style {
            case "md5": return Data(Insecure.MD5.hash(data: data))
            case "sha256": return Data(SHA256.hash(data: data))
            case "sha512": return Data(SHA512.hash(data: data))
            default: return Data(Insecure.SHA1.hash(data: data))
            }
        }
        static func stream(_ style: String, file: FileHandle, count: UInt64) throws -> Data {
            var md5 = Insecure.MD5(), sha1 = Insecure.SHA1(), sha256 = SHA256(), sha512 = SHA512()
            var remaining = count
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try autoreleasepool { () -> Data in
                    try file.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
                }
                guard !chunk.isEmpty else { throw failure("安装包数据不完整") }
                switch style {
                case "md5": md5.update(data: chunk)
                case "sha256": sha256.update(data: chunk)
                case "sha512": sha512.update(data: chunk)
                default: sha1.update(data: chunk)
                }
                remaining -= UInt64(chunk.count)
            }
            switch style {
            case "md5": return Data(md5.finalize())
            case "sha256": return Data(sha256.finalize())
            case "sha512": return Data(sha512.finalize())
            default: return Data(sha1.finalize())
            }
        }
    }

    struct TOC {
        struct Checksum { let style: String; let offset: UInt64; let size: UInt64 }
        struct Entry { let offset: UInt64; let length: UInt64; let style: String?; let checksum: String }
        var checksum: Checksum?
        var files: [Entry] = []
    }

    private final class TOCParser: NSObject, XMLParserDelegate {
        private var toc = TOC()
        private var path: [String] = []
        private var text = ""
        private var checksumStyle: String?
        private var checksumOffset: UInt64?
        private var checksumSize: UInt64?
        // Per <data> element of a file.
        private var inData = false
        private var dataOffset: UInt64?
        private var dataLength: UInt64?
        private var archivedStyle: String?
        private var archivedChecksum = ""
        private var error: Error?

        static func parse(_ xml: Data) throws -> TOC {
            let delegate = TOCParser()
            let parser = XMLParser(data: xml)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(), delegate.error == nil else {
                throw delegate.error ?? failure("安装包目录格式错误")
            }
            return delegate.toc
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "checksum", path == ["xar", "toc"] {
                checksumStyle = attributes["style"]?.lowercased()
            } else if name == "data", path.last == "file" {
                inData = true
                dataOffset = nil; dataLength = nil; archivedStyle = nil; archivedChecksum = ""
            } else if name == "archived-checksum", inData {
                archivedStyle = attributes["style"]?.lowercased()
            }
            path.append(name)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            path.removeLast()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.last
            if parent == "checksum", path.count == 3, path.prefix(2) == ["xar", "toc"] {
                if name == "offset" { checksumOffset = UInt64(value) }
                if name == "size" { checksumSize = UInt64(value) }
            } else if name == "checksum", path == ["xar", "toc"] {
                guard let style = checksumStyle, let offset = checksumOffset, let size = checksumSize else {
                    fail(parser); return
                }
                toc.checksum = .init(style: style, offset: offset, size: size)
            } else if inData, parent == "data" {
                switch name {
                case "offset": dataOffset = UInt64(value)
                // <length> is the archived byte count in the heap; <size> is
                // the extracted size and does not describe heap bytes.
                case "length": dataLength = UInt64(value)
                case "archived-checksum": archivedChecksum = value
                default: break
                }
            } else if name == "data", inData {
                inData = false
                guard let offset = dataOffset, let length = dataLength else { fail(parser); return }
                toc.files.append(.init(offset: offset, length: length, style: archivedStyle, checksum: archivedChecksum))
            }
            text = ""
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if error == nil { error = failure("安装包目录格式错误") }
        }

        private func fail(_ parser: XMLParser) {
            error = failure("安装包目录缺少必要字段")
            parser.abortParsing()
        }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        self.init(bytes)
    }
}
