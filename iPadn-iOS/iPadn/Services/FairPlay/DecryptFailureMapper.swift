import Foundation

/// Turns whatever the decryptor threw into a structured, actionable failure.
/// Only the phenomenon is stated as fact; account mismatch, family sharing and
/// untested system versions stay explicitly "suspected".
enum DecryptFailureMapper {

    static func map(error: Error, logLines: [String]) -> DecryptFailure {
        let details = technicalDetail(logLines)
        let errno = lastErrno(logLines)

        guard let failure = error as? FairPlayDecryptor.Failure else {
            return DecryptFailure(kind: .unknown,
                                  title: "解密失败",
                                  reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                  advice: "展开技术详情查看原因；如果反复出现，重试或重新下载该 IPA。",
                                  isCertain: false,
                                  details: details,
                                  errno: errno)
        }

        switch failure {
        case .cancelled:
            return DecryptFailure(kind: .cancelled,
                                  title: "已取消",
                                  reason: "这次解密被手动取消了，原始 IPA 没有被修改。",
                                  advice: "需要时重新发起一次即可。",
                                  details: details,
                                  errno: errno)

        case .busy:
            return DecryptFailure(kind: .taskConflict,
                                  title: "已有任务在运行",
                                  reason: "同一时间只运行一个解密任务，避免重复读写同一个包。",
                                  advice: "等当前任务结束后再开始，或在「应用包」里查看进度。",
                                  details: details,
                                  errno: errno)

        case .noStagingRoot:
            return DecryptFailure(kind: .appGroupUnavailable,
                                  title: "签名缺少共享容器",
                                  reason: "系统 FairPlay 只接受 App Group 容器里的包，当前签名没有可用容器。",
                                  advice: "换用带 App Group 权限的签名重新安装 iPadn 后再试。",
                                  details: details,
                                  errno: errno)

        case .badArchive(let detail):
            return DecryptFailure(kind: .ipaCorrupt,
                                  title: "安装包无法解压",
                                  reason: "ZIP 结构损坏或不完整：\(detail)",
                                  advice: "重新下载这个 IPA，确认下载完成后重试。",
                                  details: details,
                                  errno: errno)

        case .noPayload:
            return DecryptFailure(kind: .ipaCorrupt,
                                  title: "安装包里没有应用",
                                  reason: "压缩包内缺少 Payload/*.app，可能不是 IPA 或已被改坏。",
                                  advice: "换一个完整的原始 IPA 再试。",
                                  details: details,
                                  errno: errno)

        case .packFailed(let detail):
            return DecryptFailure(kind: .packFailed,
                                  title: "重新打包失败",
                                  reason: "解密完成后写回 IPA 时出错：\(detail)",
                                  advice: "确认剩余空间充足后重试；若持续失败，展开技术详情反馈。",
                                  details: details,
                                  errno: errno)

        case .notEnoughSpace(let free, let needed):
            return DecryptFailure(kind: .storageFull,
                                  title: "存储空间不足",
                                  reason: "可用 \(free.byteLabel)，这次解密大约需要 \(needed.byteLabel)。",
                                  advice: "清理空间后重试；解密过程会在 App 容器里临时占用一个 IPA 大小。",
                                  details: details,
                                  errno: errno)

        case .notDecryptable(let detail):
            if let errno, errno == EPERM {
                return DecryptFailure(
                    kind: .fairplayDenied,
                    title: "系统拒绝了解密请求",
                    reason: "fairplayd 对这次请求返回了 EPERM（Operation not permitted）。"
                        + "常见原因有三种：当前设备没有下载该应用所用 Apple ID 的解密授权；"
                        + "IPA 的下载账号与系统 App Store 当前授权账号不一致；"
                        + "这个应用来自家庭共享或其他账号的购买记录。",
                    advice: "用下载该应用时所用的 Apple ID 在系统 App Store 登录一次（App Store → 头像 → 登录），"
                        + "回到这里重新解密。如果已登录仍被拒绝，请核对下载账号是否直接拥有该应用。",
                    isCertain: false,
                    details: details,
                    errno: errno)
            }
            if let errno, errno == EINVAL {
                return DecryptFailure(kind: .unsupportedBinary,
                                      title: "这个二进制无法解密",
                                      reason: "内核拒绝了映射参数（EINVAL），该二进制可能不是受支持的加密布局。",
                                      advice: "确认包内每个 Mach-O 都有同名的 SC_Info 授权文件；必要时反馈这个样本。",
                                      details: details,
                                      errno: errno)
            }
            return DecryptFailure(kind: .unknown,
                                  title: "解密没有完成",
                                  reason: detail.isEmpty ? "所有加密二进制都被系统拒绝。" : detail,
                                  advice: "展开技术详情查看内核返回码与失败文件，然后重试。",
                                  isCertain: false,
                                  details: details,
                                  errno: errno)
        }
    }

    /// Called when every binary decrypted but the produced IPA failed its own
    /// post-pack verification: the artifact exists but must not be called good.
    static func verificationFailure(summary: String, details: String?) -> DecryptFailure {
        DecryptFailure(kind: .verifyFailed,
                       title: "产物校验未通过",
                       reason: "解密流程结束，但复查产物时发现仍有加密残留或读取失败：\(summary)",
                       advice: "展开技术详情确认残留文件；建议重新下载原始 IPA 后重试。",
                       isCertain: true,
                       details: details,
                       errno: nil)
    }

    static func partial(decrypted: Int, failed: Int, summary: String?) -> DecryptFailure {
        DecryptFailure(kind: .partial,
                       title: "部分成功",
                       reason: "\(decrypted) 个二进制已解密，\(failed) 个失败，产物里仍有加密内容。",
                       advice: "这次产物可能无法直接安装使用；重试，或换一个完整的原始 IPA。",
                       isCertain: true,
                       details: summary,
                       errno: nil)
    }

    static func alreadyPlain(details: String?) -> DecryptFailure {
        DecryptFailure(kind: .alreadyPlain,
                       title: "这个 IPA 无需解密",
                       reason: "检查到包内所有 Mach-O 都没有加密（cryptid = 0）。",
                       advice: "可以直接使用或导出这个 IPA。",
                       isCertain: true,
                       details: details,
                       errno: nil)
    }

    // MARK: - log helpers

    private static func technicalDetail(_ lines: [String]) -> String? {
        let failures = lines.filter { $0.lowercased().contains("mremap=") }
        guard !failures.isEmpty else { return lines.last }
        return failures.suffix(6).joined(separator: "\n")
    }

    /// Reads the errno back out of the core's `mremap=-1(Operation not permitted)`
    /// line, so the UI can distinguish EPERM from EINVAL without re-running.
    private static func lastErrno(_ lines: [String]) -> Int32? {
        for line in lines.reversed() where line.contains("mremap=-1") {
            let lower = line.lowercased()
            if lower.contains("not permitted") { return EPERM }
            if lower.contains("invalid argument") { return EINVAL }
            if lower.contains("no space") { return ENOSPC }
        }
        return nil
    }
}
