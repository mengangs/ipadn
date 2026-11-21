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
                                  title: AppText.text("解密失败"),
                                  reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                  advice: AppText.text("展开技术详情查看原因；如果反复出现，重试或重新下载该 IPA。"),
                                  isCertain: false,
                                  details: details,
                                  errno: errno)
        }

        switch failure {
        case .cancelled:
            return DecryptFailure(kind: .cancelled,
                                  title: AppText.text("已取消"),
                                  reason: AppText.text("这次解密被手动取消了，原始 IPA 没有被修改。"),
                                  advice: AppText.text("需要时重新发起一次即可。"),
                                  details: details,
                                  errno: errno)

        case .busy:
            return DecryptFailure(kind: .taskConflict,
                                  title: AppText.text("已有任务在运行"),
                                  reason: AppText.text("同一时间只运行一个解密任务，避免重复读写同一个包。"),
                                  advice: AppText.text("等当前任务结束后再开始，或在「应用包」里查看进度。"),
                                  details: details,
                                  errno: errno)

        case .noStagingRoot:
            return DecryptFailure(kind: .appGroupUnavailable,
                                  title: AppText.text("解密不可用：签名缺少 App Group"),
                                  reason: AppText.text("系统 FairPlay 只读取共享容器里的安装包，当前签名没有可用的共享容器。"),
                                  advice: AppText.text("请用包含 App Group 权限的签名重新安装 iPadn 后再试；免费账号或 AltStore 重签无法提供这项能力。"),
                                  details: details,
                                  errno: errno)

        case .badArchive(let detail):
            return DecryptFailure(kind: .ipaCorrupt,
                                  title: AppText.text("安装包无法解压"),
                                  reason: AppText.text("ZIP 结构损坏或不完整：\(detail)"),
                                  advice: AppText.text("重新下载这个 IPA，确认下载完成后重试。"),
                                  details: details,
                                  errno: errno)

        case .noPayload:
            return DecryptFailure(kind: .ipaCorrupt,
                                  title: AppText.text("安装包里没有应用"),
                                  reason: AppText.text("压缩包内缺少 Payload/*.app，可能不是 IPA 或已被改坏。"),
                                  advice: AppText.text("换一个完整的原始 IPA 再试。"),
                                  details: details,
                                  errno: errno)

        case .alreadyPlain:
            return alreadyPlain(details: details)

        case .packFailed(let detail):
            return DecryptFailure(kind: .packFailed,
                                  title: AppText.text("重新打包失败"),
                                  reason: AppText.text("解密完成后写回 IPA 时出错：\(detail)"),
                                  advice: AppText.text("确认剩余空间充足后重试；若持续失败，展开技术详情反馈。"),
                                  details: details,
                                  errno: errno)

        case .notEnoughSpace(let free, let needed):
            return DecryptFailure(kind: .storageFull,
                                  title: AppText.text("存储空间不足"),
                                  reason: AppText.text("可用 \(free.byteLabel)，这次解密大约需要 \(needed.byteLabel)。"),
                                  advice: AppText.text("清理空间后重试；解密过程会在 App 容器里临时占用一个 IPA 大小。"),
                                  details: details,
                                  errno: errno)

        case .notDecryptable(let detail):
            if let errno, errno == ENOMEM {
                // The kernel could not build a FairPlay context for this licence.
                // Nothing here proves anything about the signed-in account, so the
                // text stays neutral and the advice avoids the App Store detour.
                return DecryptFailure(
                    kind: .fairplayDenied,
                    title: AppText.text("系统无法为该授权建立解密上下文"),
                    reason: AppText.text("内核在请求 FairPlay 解密时返回了 ENOMEM（无法分配内存）。这不等于账号或授权有问题，也不能据此判断该 IPA 不可解。"),
                    advice: AppText.text("稍后重试一次；若持续出现，请保留这个 IPA 与日志反馈，以便按样本分析。"),
                    isCertain: false,
                    details: details,
                    errno: errno)
            }
            if let errno, errno == EPERM || errno == EACCES {
                let codeLabel = errno == EACCES ? "EACCES (Permission denied)" : "EPERM (Operation not permitted)"
                return DecryptFailure(
                    kind: .fairplayDenied,
                    title: AppText.text("系统拒绝了解密请求"),
                    reason: AppText.text("fairplayd 对这次请求返回了 \(codeLabel)。常见原因有三种：当前设备没有下载该应用所用 Apple 账号的解密授权；IPA 的下载账号与系统 App Store 当前授权账号不一致；这个应用来自家庭共享或其他账号的购买记录。"),
                    advice: AppText.text("用下载该应用时所用的 Apple 账号在系统 App Store 登录一次（App Store → 头像 → 登录），回到这里重新解密。如果已登录仍被拒绝，请核对下载账号是否直接拥有该应用。"),
                    isCertain: false,
                    details: details,
                    errno: errno)
            }
            if let errno, errno == EINVAL {
                return DecryptFailure(kind: .unsupportedBinary,
                                      title: AppText.text("这个二进制无法解密"),
                                      reason: AppText.text("内核拒绝了映射参数（EINVAL），该二进制可能不是受支持的加密布局。"),
                                      advice: AppText.text("确认包内每个 Mach-O 都有同名的 SC_Info 授权文件；必要时反馈这个样本。"),
                                      details: details,
                                      errno: errno)
            }
            return DecryptFailure(kind: .unknown,
                                  title: AppText.text("解密没有完成"),
                                  reason: detail.isEmpty ? AppText.text("所有加密二进制都被系统拒绝。") : detail,
                                  advice: AppText.text("展开技术详情查看内核返回码与失败文件，然后重试。"),
                                  isCertain: false,
                                  details: details,
                                  errno: errno)
        }
    }

    /// Called when every binary decrypted but the produced IPA failed its own
    /// post-pack verification: the artifact exists but must not be called good.
    static func verificationFailure(summary: String, details: String?) -> DecryptFailure {
        DecryptFailure(kind: .verifyFailed,
                       title: AppText.text("产物校验未通过"),
                       reason: AppText.text("解密流程结束，但复查产物时发现仍有加密残留或读取失败：\(summary)"),
                       advice: AppText.text("展开技术详情确认残留文件；建议重新下载原始 IPA 后重试。"),
                       isCertain: true,
                       details: details,
                       errno: nil)
    }

    /// Some files were decrypted, others were not. `heuristicRejected` separates
    /// "the kernel refused" from "we decrypted it and then said no", which are
    /// very different stories for the user.
    static func partial(decrypted: Int, failed: Int, summary: String?,
                        heuristicRejected: Int = 0) -> DecryptFailure {
        var reason = AppText.text("\(decrypted) 个二进制已解密，\(failed) 个失败，产物里仍有加密内容。")
        var advice = AppText.text("这次产物可能无法直接安装使用；重试，或换一个完整的原始 IPA。")
        if heuristicRejected > 0 {
            reason += AppText.text("其中 \(heuristicRejected) 个是系统已成功解密、但判定未通过的切片（mremap 返回成功、每页都读回、内容已改变）。")
            advice = AppText.text("这部分不是 FairPlay 拒绝；请展开技术详情，按 verdict new=/legacy= 两栏对比后再决定是否反馈。")
        }
        return DecryptFailure(kind: .partial,
                              title: AppText.text("部分成功"),
                              reason: reason,
                              advice: advice,
                              isCertain: true,
                              details: summary,
                              errno: nil)
    }

    static func alreadyPlain(details: String?) -> DecryptFailure {
        DecryptFailure(kind: .alreadyPlain,
                       title: AppText.text("这个 IPA 无需解密"),
                       reason: AppText.text("检查到包内所有 Mach-O 都没有加密（cryptid = 0）。"),
                       advice: AppText.text("可以直接使用或导出这个 IPA。"),
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

    /// Reads the errno only out of the `mremap=-1(...)` parenthesis.
    ///
    /// The same log line also reports the `mmap=` errno, and the fallback modes
    /// (`READ|EXEC/cryptid1`) fail for their own reasons: taking either as the
    /// verdict is how ENOMEM used to be shown as "no decryption key for this
    /// Apple ID". Main path (`…cid2…`) wins; the exec fallback is only used when
    /// the main path never reported an errno.
    private static func lastErrno(_ lines: [String]) -> Int32? {
        var main: Int32?
        var fallback: Int32?
        for line in lines where line.contains("mremap=-1(") {
            guard let code = errnoInsideMremap(line) else { continue }
            if line.contains("cid2") && !line.contains("EXEC") {
                main = code
            } else {
                fallback = code
            }
        }
        return main ?? fallback
    }

    private static func errnoInsideMremap(_ line: String) -> Int32? {
        guard let open = line.range(of: "mremap=-1(")?.upperBound,
              let close = line[open...].firstIndex(of: ")") else { return nil }
        let text = line[open..<close].lowercased()
        if text.contains("not permitted") { return EPERM }
        if text.contains("permission denied") { return EACCES }
        if text.contains("invalid argument") { return EINVAL }
        if text.contains("cannot allocate memory") { return ENOMEM }
        if text.contains("no space") { return ENOSPC }
        return nil
    }
}
