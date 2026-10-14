import Foundation

enum DMAP {
    struct Tag { let name: String; let payload: Data }
    private static let containers: Set<String> = ["adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd"]

    static func tag(_ name: String, _ payload: Data = Data()) -> Data {
        precondition(name.utf8.count == 4 && name.utf8.allSatisfy { (32...126).contains($0) })
        precondition(payload.count <= Int(UInt32.max))
        var data = Data(name.utf8)
        var count = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
    static func uint32(_ name: String, _ value: UInt32) -> Data {
        var number = value.bigEndian
        return withUnsafeBytes(of: &number) { tag(name, Data($0)) }
    }
    static func string(_ name: String, _ value: String) -> Data { tag(name, Data(value.utf8)) }
    static func integer(_ data: Data) throws -> UInt64 {
        guard [1, 4, 8].contains(data.count) else { throw ToolError.message("DMAP 整数长度错误") }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    /// Walks tags without copying: payloads are slices of the original buffer
    /// (purchase lists can be several megabytes with deep nesting).
    static func walk(_ data: Data, depth: Int = 0, visitor: (Tag) throws -> Void) throws {
        guard depth <= 16 else { throw ToolError.message("DMAP 嵌套过深") }
        var offset = data.startIndex
        let end = data.endIndex
        while offset < end {
            guard end - offset >= 8 else { throw ToolError.message("DMAP 标签被截断") }
            let nameBytes = data[offset..<(offset + 4)]
            guard nameBytes.allSatisfy({ (32...126).contains($0) }),
                  let name = String(bytes: nameBytes, encoding: .ascii) else { throw ToolError.message("DMAP 标签名称无效") }
            let length = data[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let start = offset + 8
            guard UInt64(length) <= UInt64(end - start) else { throw ToolError.message("DMAP 负载被截断") }
            let stop = start + Int(length)
            let payload = data[start..<stop]
            try visitor(Tag(name: name, payload: payload))
            if containers.contains(name) { try walk(payload, depth: depth + 1, visitor: visitor) }
            offset = stop
        }
    }
    private struct Found: Error { let value: UInt32 }
    static func firstInteger(_ data: Data, name: String) throws -> UInt32? {
        do {
            try walk(data) { tag in
                guard tag.name == name else { return }
                let number = try integer(tag.payload)
                guard number <= UInt32.max else { throw ToolError.message("DMAP 数值超出 uint32") }
                throw Found(value: UInt32(number)) // stop at the first match
            }
        } catch let found as Found { return found.value }
        return nil
    }
    static func validate(_ data: Data) throws {
        guard let status = try firstInteger(data, name: "mstt") else {
            throw ToolError.message("暂时无法同步购买记录，请稍后重试")
        }
        if status != 200 {
            throw ToolError.message("暂时无法同步购买记录（\(status)），请稍后重试")
        }
    }
    static func ownedApps(_ data: Data) throws -> [OwnedApp] {
        var apps: [OwnedApp] = []; var seen = Set<String>()
        try walk(data) { item in
            guard item.name == "mlit" else { return }
            var app = OwnedApp(id: "", bundleID: "", name: "", version: "")
            try walk(item.payload) { field in
                let text = String(data: field.payload, encoding: .utf8) ?? ""
                switch field.name {
                case "aeSI": app.id = String(try integer(field.payload))
                case "aeBI": app.bundleID = text
                case "aeLN": app.name = text
                case "minm": if app.name.isEmpty { app.name = text }
                case "aePd": app.version = text
                case "asdp": app.purchaseDate = Date(timeIntervalSince1970: Double(try integer(field.payload)))
                default: break
                }
            }
            if !app.id.isEmpty, seen.insert(app.id).inserted { apps.append(app) }
        }
        return apps.sorted { ($0.purchaseDate ?? .distantPast) > ($1.purchaseDate ?? .distantPast) }
    }
}
