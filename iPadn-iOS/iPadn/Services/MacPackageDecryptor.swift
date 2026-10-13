import Foundation
import Security

// Swift side of MacPKGBridge (Go + ipatool StoreAgent on the no-JIT Unicorn
// interpreter). Symbols are resolved at runtime: simulator builds and builds
// made without scripts/build_mac_pkg_bridge.sh report the feature unavailable.
enum MacPackageDecryptor {
    enum Stage: Int32 {
        case idle = 0, components, starting, decrypting
        var title: String {
            switch self {
            case .idle: return "准备中"
            case .components: return "正在下载所需组件"
            case .starting: return "准备中"
            case .decrypting: return "正在处理"
            }
        }
    }

    private typealias DecryptFunction = @convention(c) (
        UnsafePointer<CChar>, UnsafePointer<UInt8>, Int32,
        UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int32) -> Int32
    private typealias StatusFunction = @convention(c) (UnsafeMutablePointer<Int64>?) -> Int32
    private typealias CancelFunction = @convention(c) () -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private static let decryptFunction = symbol("iPadnMacPKGDecrypt", as: DecryptFunction.self)
    private static let statusFunction = symbol("iPadnMacPKGStatus", as: StatusFunction.self)
    private static let cancelFunction = symbol("iPadnMacPKGCancel", as: CancelFunction.self)

    static var isAvailable: Bool { decryptFunction != nil && statusFunction != nil && cancelFunction != nil }

    /// Blocking; call from a background task. One package is processed at a
    /// time; concurrent calls wait inside the bridge.
    static func decrypt(hardwareID: String, dpInfo: Data, from source: URL, to destination: URL) throws {
        guard let decryptFunction else {
            throw ToolError.message("当前版本不支持下载此 Mac 安装包")
        }
        guard hardwareID.count == 12, hardwareID.allSatisfy(\.isHexDigit), !dpInfo.isEmpty else {
            throw ToolError.message("下载授权已失效，请重新获取")
        }
        var message = [CChar](repeating: 0, count: 1024)
        let code = dpInfo.withUnsafeBytes { raw -> Int32 in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            return hardwareID.withCString { hardware in
                source.path.withCString { input in
                    destination.path.withCString { output in
                        decryptFunction(hardware, bytes, Int32(dpInfo.count), input, output, &message, Int32(message.count))
                    }
                }
            }
        }
        if code == 1 { throw CancellationError() }
        guard code == 0 else {
            let text = String(cString: message)
            throw ToolError.message(text.isEmpty ? "Mac 安装包处理失败（\(code)）" : text)
        }
    }

    static func status() -> (stage: Stage, bytes: Int64)? {
        guard let statusFunction else { return nil }
        var bytes: Int64 = 0
        let stage = Stage(rawValue: statusFunction(&bytes)) ?? .idle
        return (stage, bytes)
    }

    // The bridge processes one package at a time and reports one global
    // status. Jobs therefore queue here, on a dedicated thread (the call
    // blocks for minutes and must not hold a Swift concurrency thread), and
    // the status belongs only to the job recorded as current.
    private static let queue = DispatchQueue(label: "iPadn.mac-package", qos: .userInitiated)
    private static let lock = NSLock()
    private static var current: UUID?
    private static var cancelled = Set<UUID>()

    /// The job whose package is being processed right now, if any.
    static var currentJob: UUID? { lock.lock(); defer { lock.unlock() }; return current }

    /// Queues the job and waits for its turn; throws CancellationError if it
    /// is cancelled while waiting or while being processed.
    static func process(job: UUID, hardwareID: String, dpInfo: Data, from source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                lock.lock()
                let skip = cancelled.remove(job) != nil
                if !skip { current = job }
                lock.unlock()
                if skip { continuation.resume(throwing: CancellationError()); return }
                defer { lock.lock(); current = nil; cancelled.remove(job); lock.unlock() }
                do {
                    try decrypt(hardwareID: hardwareID, dpInfo: dpInfo, from: source, to: destination)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Cancels a job that is waiting or being processed.
    static func cancel(job: UUID) {
        lock.lock()
        let running = current == job
        if !running { cancelled.insert(job) }
        lock.unlock()
        if running { cancelFunction?() }
    }
}

// dpInfo is account- and device-bound key material for one download. It is
// kept in the keychain (this device only) between the authorized request and
// local processing, never in the download task file, and deleted afterwards.
enum MacPackageSecrets {
    struct Entry: Codable, Equatable {
        let hardwareID: String
        let dpInfo: Data
    }

    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "iPadn") + (LocalResources.isPreview ? ".preview.macpkg" : ".macpkg")
    }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func save(_ entry: Entry, for id: UUID) throws {
        delete(id)
        var item = query(id)
        item[kSecValueData as String] = try JSONEncoder().encode(entry)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ToolError.message("无法保存 Mac 下载授权（\(status)）") }
    }

    static func load(_ id: UUID) throws -> Entry {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            throw ToolError.message("下载授权已失效，请删除任务后重新获取")
        }
        return entry
    }

    static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
