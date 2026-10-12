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
    static func walk(_ data: Data, depth: Int = 0, visitor: (Tag) throws -> Void) throws {
        guard depth <= 16 else { throw ToolError.message("DMAP 嵌套过深") }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw ToolError.message("DMAP 标签被截断") }
            let nameBytes = bytes[offset..<(offset + 4)]
            guard nameBytes.allSatisfy({ (32...126).contains($0) }),
                  let name = String(bytes: nameBytes, encoding: .ascii) else { throw ToolError.message("DMAP 标签名称无效") }
            let length = bytes[(offset + 4)..<(offset + 8)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let start = offset + 8
            guard UInt64(length) <= UInt64(bytes.count - start) else { throw ToolError.message("DMAP 负载被截断") }
            let end = start + Int(length)
            let payload = Data(bytes[start..<end])
            try visitor(Tag(name: name, payload: payload))
            if containers.contains(name) { try walk(payload, depth: depth + 1, visitor: visitor) }
            offset = end
        }
    }
    static func firstInteger(_ data: Data, name: String) throws -> UInt32? {
        var value: UInt32?
        try walk(data) { tag in
            if tag.name == name, value == nil {
                let number = try integer(tag.payload)
                guard number <= UInt32.max else { throw ToolError.message("DMAP 数值超出 uint32") }
                value = UInt32(number)
            }
        }
        return value
    }
    static func validate(_ data: Data) throws {
        if let status = try firstInteger(data, name: "mstt"), status != 200 {
            throw ToolError.message("购买记录接口返回错误：\(status)")
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
