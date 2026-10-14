import Foundation

/// The version number and date of one App Store version, read from the
/// package itself (ipatool's get-version-metadata).
struct VersionMetadata: Codable, Hashable, Sendable {
    var version: String
    var released: Date?
}

/// Reads byte ranges of a remote file.
protocol RangeReader: Sendable {
    /// The last `count` bytes and the size of the whole file.
    func tail(_ count: Int) async throws -> (data: Data, size: Int64)
    func read(offset: Int64, count: Int) async throws -> Data
}

struct HTTPRangeReader: RangeReader {
    let url: URL
    /// Largest single range: big enough for the central directory of large
    /// games, small enough that a misbehaving server cannot exhaust memory.
    static let limit = 32 * 1024 * 1024

    func tail(_ count: Int) async throws -> (data: Data, size: Int64) {
        let (data, contentRange) = try await HTTPClient.shared.range(url, "-\(count)", limit: count)
        // "bytes 100-199/200"
        guard let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 else {
            throw RemoteZip.Failure.unreadable
        }
        return (data, total)
    }

    func read(offset: Int64, count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        let (data, _) = try await HTTPClient.shared.range(url, "\(offset)-\(offset + Int64(count) - 1)", limit: count)
        guard data.count == count else { throw RemoteZip.Failure.unreadable }
        return data
    }
}

/// Reads one file out of a remote ZIP (an IPA) with a few range requests
/// instead of downloading the whole package.
enum RemoteZip {
    enum Failure: Error { case unreadable, notFound }

    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int64
        var size: Int64
        var localOffset: Int64
        var modified: Date?
    }

    /// The main app's Info.plist: version number and, as ipatool does, the
    /// release date it records or else the file's timestamp in the archive.
    static func versionMetadata(_ reader: RangeReader) async throws -> VersionMetadata {
        let entries = try await centralDirectory(reader)
        guard let entry = entries.first(where: { isMainInfoPlist($0.name) }) else { throw Failure.notFound }
        let data = try await contents(of: entry, reader: reader)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.unreadable
        }
        let version = plistString(plist["CFBundleShortVersionString"] ?? plist["bundleShortVersionString"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw Failure.unreadable }
        return VersionMetadata(version: version, released: releaseDate(plist["releaseDate"] ?? plist["ReleaseDate"]) ?? entry.modified)
    }

    static func isMainInfoPlist(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
    }

    static func releaseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEEE, MMMM d, yyyy", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func centralDirectory(_ reader: RangeReader) async throws -> [Entry] {
        // End record (22 bytes) plus the longest possible comment.
        let (tail, size) = try await reader.tail(22 + 65_535)
        let tailStart = size - Int64(tail.count)
        guard let end = lastSignature(0x0605_4b50, in: tail), end + 22 <= tail.count else { throw Failure.unreadable }
        var count = Int64(tail.le16(end + 10))
        var directorySize = Int64(tail.le32(end + 12))
        var directoryOffset = Int64(tail.le32(end + 16))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: the locator sits right before the end record.
            let locator = end - 20
            guard locator >= 0, tail.le32(locator) == 0x0706_4b50 else { throw Failure.unreadable }
            let recordOffset = Int64(tail.le64(locator + 8))
            let record: Data
            if recordOffset >= tailStart, recordOffset - tailStart + 56 <= Int64(tail.count) {
                let start = Int(recordOffset - tailStart)
                record = tail.subdata(in: start..<start + 56)
            } else {
                record = try await reader.read(offset: recordOffset, count: 56)
            }
            guard record.le32(0) == 0x0606_4b50 else { throw Failure.unreadable }
            count = Int64(record.le64(32))
            directorySize = Int64(record.le64(40))
            directoryOffset = Int64(record.le64(48))
        }
        guard directorySize > 0, directorySize <= Int64(HTTPRangeReader.limit),
              directoryOffset >= 0, directoryOffset + directorySize <= size else { throw Failure.unreadable }
        let directory: Data
        if directoryOffset >= tailStart {
            let start = Int(directoryOffset - tailStart)
            directory = tail.subdata(in: start..<start + Int(directorySize))
        } else {
            directory = try await reader.read(offset: directoryOffset, count: Int(directorySize))
        }
        return try entries(directory, count: count)
    }

    static func entries(_ data: Data, count: Int64) throws -> [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(Int(min(count, 200_000)))
        var position = 0
        while position + 46 <= data.count, data.le32(position) == 0x0201_4b50 {
            let method = data.le16(position + 10)
            let dosTime = data.le16(position + 12), dosDate = data.le16(position + 14)
            var compressed = Int64(data.le32(position + 20))
            var size = Int64(data.le32(position + 24))
            let nameLength = Int(data.le16(position + 28))
            let extraLength = Int(data.le16(position + 30))
            let commentLength = Int(data.le16(position + 32))
            var offset = Int64(data.le32(position + 42))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= data.count else { throw Failure.unreadable }
            let nameBytes = data.subdata(in: nameStart..<extraStart)
            let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
            var modified = dosDateTime(date: dosDate, time: dosTime)
            var extra = extraStart
            while extra + 4 <= extraStart + extraLength {
                let id = data.le16(extra), length = Int(data.le16(extra + 2))
                let body = extra + 4
                guard body + length <= extraStart + extraLength else { break }
                if id == 0x0001 {
                    // ZIP64 sizes and offset, present only for fields set to 0xFFFFFFFF.
                    var field = body
                    if size == 0xFFFF_FFFF, field + 8 <= body + length { size = Int64(data.le64(field)); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= body + length { compressed = Int64(data.le64(field)); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= body + length { offset = Int64(data.le64(field)) }
                } else if id == 0x5455, length >= 5, data[data.startIndex + body] & 1 != 0 {
                    modified = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: data.le32(body + 1))))
                }
                extra = body + length
            }
            result.append(Entry(name: name, method: method, compressedSize: compressed, size: size,
                                localOffset: offset, modified: modified))
            position = next
        }
        return result
    }

    static func contents(of entry: Entry, reader: RangeReader) async throws -> Data {
        // Info.plist is a few kilobytes; refuse anything implausible.
        guard entry.compressedSize >= 0, entry.compressedSize <= 4 * 1024 * 1024,
              entry.size >= 0, entry.size <= 16 * 1024 * 1024 else { throw Failure.unreadable }
        let guess = 30 + entry.name.utf8.count + 256
        var data = try await reader.read(offset: entry.localOffset, count: guess + Int(entry.compressedSize))
        guard data.count >= 30, data.le32(0) == 0x0403_4b50 else { throw Failure.unreadable }
        let start = 30 + Int(data.le16(26)) + Int(data.le16(28))
        let end = start + Int(entry.compressedSize)
        if end > data.count {
            data += try await reader.read(offset: entry.localOffset + Int64(data.count), count: end - data.count)
        }
        let body = data.subdata(in: start..<end)
        switch entry.method {
        case 0: return body
        case 8:
            // Apple's zlib codec is raw DEFLATE, as ZIP stores it.
            let inflated = try (body as NSData).decompressed(using: .zlib) as Data
            guard inflated.count == entry.size else { throw Failure.unreadable }
            return inflated
        default: throw Failure.unreadable
        }
    }

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        var index = data.count - 22
        while index >= 0 {
            if data.le32(index) == signature { return index }
            index -= 1
        }
        return nil
    }

    /// DOS date and time, read as UTC like ipatool (Go's archive/zip).
    private static func dosDateTime(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var parts = DateComponents()
        parts.year = 1980 + Int(date >> 9); parts.month = Int((date >> 5) & 0xF); parts.day = Int(date & 0x1F)
        parts.hour = Int(time >> 11); parts.minute = Int((time >> 5) & 0x3F); parts.second = Int(time & 0x1F) * 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: parts)
    }
}

private extension Data {
    func le16(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }
    func le32(_ offset: Int) -> UInt32 {
        UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16
    }
    func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
    }
}

/// Version metadata never changes, so lookups are kept on disk. Lookups
/// run one at a time: each one asks Apple for a download ticket.
actor VersionMetadataStore {
    static let filename = "version-metadata.json"
    private var cache = LocalResources.load([String: VersionMetadata].self, filename: VersionMetadataStore.filename) ?? [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static func key(platform: AppPlatform, appID: String, versionID: String) -> String {
        "\(platform.rawValue)|\(appID)|\(versionID)"
    }

    func cached(_ key: String) -> VersionMetadata? { cache[key] }
    func cached(_ keys: [String]) -> [String: VersionMetadata] {
        var found: [String: VersionMetadata] = [:]
        for key in keys { if let value = cache[key] { found[key] = value } }
        return found
    }

    func load(_ key: String, fetch: @Sendable () async throws -> VersionMetadata) async throws -> VersionMetadata {
        if let value = cache[key] { return value }
        await acquire()
        defer { release() }
        // A row scrolled away while waiting: skip its request.
        try Task.checkCancellation()
        if let value = cache[key] { return value }
        let value = try await fetch()
        cache[key] = value
        if cache.count > 5_000 { cache.removeAll(); cache[key] = value }
        try? LocalResources.save(cache, filename: Self.filename)
        return value
    }

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
