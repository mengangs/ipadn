import Foundation
import ZIPFoundation
import FairPlayCore

/// Progress of one decryption run, for the UI.
struct FairPlayProgress: Sendable {
    let phase: String
    let fraction: Double
    let detail: String
}

/// Collects the C core's per-attempt lines (size, mmap, errno, entropy) via a
/// per-call context pointer so concurrent callers cannot cross-talk logs.
private final class LogCallbackBox {
    let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
}

private let coreLogTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, message in
    guard let ctx, let message else { return }
    let box = Unmanaged<LogCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(String(cString: message))
}

/// On-device FairPlay (App Store DRM) decryption of an IPA.
///
/// stage in an App Group container (fairplayd refuses data containers) →
/// unpack → place SC_Info beside every encrypted Mach-O → per slice
/// mmap(PROT_READ) + mremap_encrypted(cryptid 2) → check pages, entropy and
/// ARM64 landmarks → patch cryptid to 0 → repack → verify the packed IPA.
enum FairPlayDecryptor {

    struct Outcome: Sendable {
        let outputURL: URL
        let decrypted: Int
        let plain: Int
        let failed: Int
        let machO: Int
        let elapsed: TimeInterval
        let partial: Bool
        let verification: FairPlayVerification?
    }

    enum Failure: LocalizedError {
        case noStagingRoot
        case badArchive(String)
        case noPayload
        case notDecryptable(String)
        case packFailed(String)
        case notEnoughSpace(Int64, Int64)
        case cancelled
        case busy

        var errorDescription: String? {
            switch self {
            case .noStagingRoot:
                return "没有可用的暂存目录：签名缺少 App Group 权限（fairplayd 只接受 App Group 容器）"
            case .badArchive(let detail):
                return "安装包解压失败：\(detail)"
            case .noPayload:
                return "安装包里没有 Payload/*.app"
            case .notDecryptable(let detail):
                return "FairPlay 拒绝了主程序：\(detail)"
            case .packFailed(let detail):
                return "重新打包失败：\(detail)"
            case .notEnoughSpace(let free, let needed):
                return "空间不足：可用 \(free) 字节，需要 \(needed) 字节"
            case .cancelled:
                return "已取消"
            case .busy:
                return "已有解密任务在进行"
            }
        }
    }

    private static let activeLock = NSLock()
    private static var activeDecryptCount = 0

    private static func tryAcquireActive() -> Bool {
        activeLock.lock()
        defer { activeLock.unlock() }
        guard activeDecryptCount == 0 else { return false }
        activeDecryptCount += 1
        return true
    }

    private static func releaseActive() {
        activeLock.lock()
        activeDecryptCount = max(0, activeDecryptCount - 1)
        activeLock.unlock()
    }

    /// Removes orphaned `fpwork-*` staging directories left behind by crashes.
    static func cleanupStaleStaging() {
        activeLock.lock()
        let busy = activeDecryptCount > 0
        activeLock.unlock()
        guard !busy else { return }

        let manager = FileManager.default
        let candidates = [FairPlayEnvironment.groupContainer(), FairPlayEnvironment.bundleStaging()].compactMap { $0 }
        for root in candidates {
            guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("fpwork-") {
                try? manager.removeItem(at: item)
            }
        }
    }

    /// Staging root: App Group container first, bundle only when explicitly allowed.
    static func stagingRoot(allowBundle: Bool) -> URL? {
        if let group = FairPlayEnvironment.groupContainer() { return group }
        if allowBundle { return FairPlayEnvironment.bundleStaging() }
        return nil
    }

    /// Decrypts `ipaURL` and writes `<name>-decrypted.ipa` into Documents/Decrypted.
    /// Blocking; call from a background task.
    static func decrypt(
        ipaURL: URL,
        allowBundleStaging: Bool = false,
        isCancelled: () -> Bool = { false },
        report: (FairPlayProgress) -> Void = { _ in },
        log: @escaping (FairPlayLine) -> Void
    ) throws -> Outcome {
        guard tryAcquireActive() else {
            throw Failure.busy
        }
        defer { releaseActive() }

        guard let rawRoot = stagingRoot(allowBundle: allowBundleStaging) else {
            throw Failure.noStagingRoot
        }
        let root = rawRoot.resolvingSymlinksInPath()
        let manager = FileManager.default
        let started = Date()
        let stem = ipaURL.deletingPathExtension().lastPathComponent
        let work = root.appendingPathComponent("fpwork-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: work) }
        try manager.createDirectory(at: work, withIntermediateDirectories: true)

        let sourceSize = (try? manager.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0
        if let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            let needed = sourceSize * 3
            if capacity < needed {
                log(FairPlayLine(kind: .fail, text: "空间不足：\(capacity) < \(needed)"))
                throw Failure.notEnoughSpace(capacity, needed)
            }
        }

        // 1. unpack into the App Group container
        report(FairPlayProgress(phase: "解包安装包", fraction: 0, detail: ipaURL.lastPathComponent))
        log(FairPlayLine(kind: .phase, text: "UNPACK \(ipaURL.lastPathComponent) (\(sourceSize) B)"))
        do {
            try manager.unzipItem(at: ipaURL, to: work)
        } catch {
            throw Failure.badArchive(error.localizedDescription)
        }
        if isCancelled() { throw Failure.cancelled }

        let payloadRoot = work.appendingPathComponent("Payload", isDirectory: true)
        let payloadEntries = (try? manager.contentsOfDirectory(atPath: payloadRoot.path)) ?? []
        guard let bundleName = payloadEntries.first(where: { $0.hasSuffix(".app") }) else {
            throw Failure.noPayload
        }
        let appDir = payloadRoot.appendingPathComponent(bundleName, isDirectory: true)
        log(FairPlayLine(kind: .info, text: "payload: \(bundleName)"))

        // 2. inventory + SINF placement
        report(FairPlayProgress(phase: "准备解密", fraction: 0.04, detail: bundleName))
        let inventory = MachOScan.scanTree(appDir)
        var encryptedSlicesByPath: [String: Int] = [:]
        for row in inventory {
            let encrypted = row.slices.filter { $0.cryptid != 0 }
            guard let first = encrypted.first else { continue }
            encryptedSlicesByPath[row.path] = Int(first.cryptsize)
        }
        let replicated = replicateSinf(appDir: appDir, machos: inventory)
        log(FairPlayLine(kind: replicated > 0 ? .info : .warn,
                         text: "SINF placed beside \(replicated) nested binaries"))

        // 3. decrypt every encrypted Mach-O
        let encryptedFiles = inventory.filter { $0.slices.contains { $0.cryptid != 0 } }
        log(FairPlayLine(kind: .phase,
                         text: "DECRYPT \(encryptedFiles.count) encrypted of \(inventory.count) Mach-O"))
        var decrypted = 0, plain = 0, failed = 0
        var lastAttempt: String?
        var firstFailure: String?
        let total = max(encryptedFiles.count, 1)
        for (index, row) in encryptedFiles.enumerated() {
            if isCancelled() { throw Failure.cancelled }
            let url = appDir.appendingPathComponent(row.path)
            report(FairPlayProgress(phase: "正在解密",
                                    fraction: 0.05 + 0.75 * Double(index) / Double(total),
                                    detail: "\(index + 1)/\(encryptedFiles.count) · \(row.path)"))
            let scratch = url.appendingPathExtension("fpdec")
            try? manager.removeItem(at: scratch)
            var attemptLines: [String] = []
            let logBox = LogCallbackBox { line in
                attemptLines.append(line)
                log(FairPlayLine(kind: .info, text: line.trimmingCharacters(in: .whitespaces)))
            }
            let status: Int32 = withExtendedLifetime(logBox) {
                let ctx = Unmanaged.passUnretained(logBox).toOpaque()
                return url.path.withCString { input in
                    scratch.path.withCString { output in
                        fp_decrypt_file(input, output, coreLogTrampoline, ctx)
                    }
                }
            }
            lastAttempt = attemptLines.last
            switch status {
            case 0:
                var replaced = false
                do {
                    _ = try manager.replaceItemAt(url, withItemAt: scratch)
                    replaced = true
                } catch {
                    if (try? manager.removeItem(at: url)) != nil,
                       (try? manager.moveItem(at: scratch, to: url)) != nil {
                        replaced = true
                    }
                }
                if replaced {
                    decrypted += 1
                    log(FairPlayLine(kind: .ok, text: "decrypted \(row.path)"))
                } else {
                    try? manager.removeItem(at: scratch)
                    failed += 1
                    log(FairPlayLine(kind: .fail, text: "replace failed \(row.path)"))
                }
            case 1:
                try? manager.removeItem(at: scratch)
                plain += 1
            default:
                try? manager.removeItem(at: scratch)
                failed += 1
                if firstFailure == nil { firstFailure = lastAttempt }
                let detail = lastAttempt.map { " — \($0)" } ?? ""
                log(FairPlayLine(kind: .fail, text: "FairPlay refused \(row.path)\(detail)"))
            }
        }
        plain += inventory.count - encryptedFiles.count

        // 4. quick on-disk check before packing
        let after = MachOScan.scanTree(appDir)
        let stillEncrypted = after.flatMap(\.slices).filter { $0.cryptid != 0 }.count
        log(FairPlayLine(kind: stillEncrypted == 0 ? .ok : .fail,
                         text: "prepack: \(after.count) Mach-O, \(stillEncrypted) still encrypted"))

        guard decrypted > 0 || (failed == 0 && stillEncrypted == 0) else {
            throw Failure.notDecryptable(diagnose(firstFailure: firstFailure,
                                                 failed: failed, stillEncrypted: stillEncrypted))
        }

        // 5. repack
        report(FairPlayProgress(phase: "重新打包", fraction: 0.82, detail: "\(stem).ipa"))
        log(FairPlayLine(kind: .phase, text: "PACK"))
        let outDir = FairPlayEnvironment.documentsDirectory.appendingPathComponent("Decrypted", isDirectory: true)
        try? manager.createDirectory(at: outDir, withIntermediateDirectories: true)
        let partial = failed > 0 || stillEncrypted > 0
        let suffix = partial ? "-PARTIAL" : "-decrypted"
        let output = outDir.appendingPathComponent("\(stem)\(suffix).ipa")
        let temp = outDir.appendingPathComponent("\(stem)\(suffix).ipa.tmp")
        try? manager.removeItem(at: temp)
        do {
            try pack(directory: work, to: temp)
        } catch {
            try? manager.removeItem(at: temp)
            throw Failure.packFailed(error.localizedDescription)
        }
        try? manager.removeItem(at: output)
        do {
            try manager.moveItem(at: temp, to: output)
        } catch {
            try? manager.removeItem(at: temp)
            throw Failure.packFailed(error.localizedDescription)
        }
        let size = (try? manager.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        log(FairPlayLine(kind: .ok, text: "wrote \(output.lastPathComponent) (\(size) B)"))

        // 6. verify the artefact that is actually exported
        report(FairPlayProgress(phase: "校验产物", fraction: 0.92, detail: "检查 cryptid 与代码熵"))
        var verification: FairPlayVerification?
        do {
            let result = try FairPlayVerifier.verify(ipa: output, wasEncrypted: encryptedSlicesByPath)
            verification = result
            let entropyRange = result.files.filter(\.wasEncrypted).prefix(3)
                .map { String(format: "%.2f", $0.entropy) }.joined(separator: "/")
            log(FairPlayLine(kind: result.isClean ? .ok : .fail,
                             text: "verify: \(result.summary)" + (entropyRange.isEmpty ? "" : " · entropy \(entropyRange)")))
            for failure in result.failures.prefix(8) {
                log(FairPlayLine(kind: .fail, text: "verify failed: \(failure)"))
            }
        } catch {
            log(FairPlayLine(kind: .warn, text: "verify skipped: \(error.localizedDescription)"))
        }

        report(FairPlayProgress(phase: "完成", fraction: 1, detail: output.lastPathComponent))
        return Outcome(outputURL: output, decrypted: decrypted, plain: plain, failed: failed,
                       machO: after.count, elapsed: Date().timeIntervalSince(started),
                       partial: partial || !(verification?.isClean ?? true), verification: verification)
    }

    // MARK: - helpers

    /// Turns the C core's failure line into something the user can act on.
    /// `fairplayd` refuses a binary when this device holds no FairPlay key for
    /// the Apple ID that downloaded the app, which is by far the most common
    /// "decryption failed" for an app that was never installed from the App Store.
    private static func diagnose(firstFailure: String?, failed: Int, stillEncrypted: Int) -> String {
        var text = "\(failed) 个文件失败，\(stillEncrypted) 个切片仍加密"
        guard let raw = firstFailure else { return text }
        let line = raw.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        if lower.contains("not permitted") || lower.contains("permission denied") {
            // The most common cause by far, and the only one the user can fix:
            // the account that downloaded the app was never signed into the
            // system App Store on this device, so fairplayd holds no key.
            text = "这台设备没有该 Apple ID 的解密密钥，系统拒绝了 FairPlay 解密。\n\n"
                + "请用下载这个应用时所用的 Apple ID 登录一次系统「App Store」"
                + "（打开 App Store → 右上角头像 → 登录；或 设置 → 你的名字 → 媒体与购买项目），"
                + "然后回到这里重新解密。\n"
                + "同一个 Apple ID 在这台设备上登录过一次即可，密钥会保存在本机，之后可重复使用。"
            return text
        }
        text += "\n内核返回：\(line)"
        if lower.contains("invalid argument") {
            text += "\n映射参数被拒绝：请确认包内有与二进制同名的 SC_Info/<名称>.sinf。"
        }
        return text
    }

    /// fairplayd resolves the license as `<dir>/SC_Info/<name>.sinf` next to the
    /// binary, so every encrypted Mach-O needs one. A store IPA ships a single
    /// SINF plus `SinfReplicationPaths`; installd would fan it out, here the
    /// replication is done explicitly and then checked against the real tree,
    /// because nested `PlugIns`/`Frameworks` paths often differ from the
    /// manifest's historical `Extensions/...` spelling.
    @discardableResult
    static func replicateSinf(appDir: URL, machos: [(path: String, slices: [MachOScan.SliceInfo])]) -> Int {
        let manager = FileManager.default
        let manifestURL = appDir.appendingPathComponent("SC_Info/Manifest.plist")
        guard let data = try? Data(contentsOf: manifestURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let manifest = plist as? [String: Any],
              let sources = manifest["SinfPaths"] as? [String],
              let first = sources.first else { return 0 }
        let sourceURL = appDir.appendingPathComponent(first)
        guard manager.fileExists(atPath: sourceURL.path) else { return 0 }

        var copied = 0
        for relative in (manifest["SinfReplicationPaths"] as? [String] ?? []) {
            let destination = appDir.appendingPathComponent(relative)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try? manager.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            if (try? manager.copyItem(at: sourceURL, to: destination)) != nil { copied += 1 }
        }

        for macho in machos where macho.slices.contains(where: { $0.cryptid != 0 }) {
            let binary = appDir.appendingPathComponent(macho.path)
            let name = binary.lastPathComponent
            let sinf = binary.deletingLastPathComponent()
                .appendingPathComponent("SC_Info", isDirectory: true)
                .appendingPathComponent("\(name).sinf")
            guard !manager.fileExists(atPath: sinf.path) else { continue }
            try? manager.createDirectory(at: sinf.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            if (try? manager.copyItem(at: sourceURL, to: sinf)) != nil { copied += 1 }
        }
        return copied
    }

    private static func pack(directory: URL, to output: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: output)
        let archive = try Archive(url: output, accessMode: .create)
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: []) else {
            throw Failure.packFailed("cannot enumerate \(directory.lastPathComponent)")
        }
        let basePath = directory.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { continue }
            let itemPath = url.standardizedFileURL.path
            let relative = itemPath.hasPrefix(basePrefix)
                ? String(itemPath.dropFirst(basePrefix.count))
                : url.lastPathComponent
            try archive.addEntry(with: relative, fileURL: url, compressionMethod: .deflate)
        }
    }

    /// IPAs available in the app's Documents directory, newest first.
    static func candidateIPAs() -> [URL] {
        let manager = FileManager.default
        let documents = FairPlayEnvironment.documentsDirectory
        let entries = (try? manager.contentsOfDirectory(at: documents,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
    }
}
