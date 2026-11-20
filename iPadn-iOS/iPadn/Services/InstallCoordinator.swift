import Foundation

/// Where a package came from. Display only: the install decision never branches on it.
enum PackageSource: String, CaseIterable {
    case appStore, testFlight, local

    var label: String {
        switch self {
        case .appStore: return "App Store"
        case .testFlight: return "TestFlight"
        case .local: return AppText.text("本地")
        }
    }
}

/// How to deliver a package. The user picks once and the choice is remembered.
enum InstallMethod: String, CaseIterable, Identifiable {
    case native, overTheAir, save

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return AppText.text("原生安装")
        case .overTheAir: return AppText.text("OTA 安装")
        case .save: return AppText.text("仅保存 / 分享")
        }
    }
}

struct InstallCapability: Equatable {
    enum UnavailableKind: Equatable {
        case missingPackage
        case needsNativeChannel
        case needsSignedPackage
        case serviceNotReady
    }

    var available: Bool
    /// Plain-language reason, shown next to a disabled option. No protocol jargon.
    var reason: String?
    var unavailableKind: UnavailableKind? = nil
}

struct InstallOutcome {
    var upgraded: Bool
    var installed: Bool
    var signedOrOTA: Bool
}

/// The single install entry for every package, whatever produced it.
///
/// `accept` does not look at `PackageSource`; the source is only displayed. The method
/// decides behaviour, and an unavailable method explains itself instead of failing deep
/// inside the installer.
@MainActor
final class InstallCoordinator {
    static let shared = InstallCoordinator()

    private let methodKey = "install.method"

    var preferredMethod: InstallMethod {
        get { InstallMethod(rawValue: UserDefaults.standard.string(forKey: methodKey) ?? "") ?? .native }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: methodKey) }
    }

    /// Capability check before any call into the installer: a disabled option must not
    /// produce an error the user cannot act on.
    func capability(for method: InstallMethod, package: URL,
                    installation: InstallationService? = nil) -> InstallCapability {
        switch method {
        case .native:
            guard FileManager.default.fileExists(atPath: package.path) else {
                return InstallCapability(available: false,
                                         reason: AppText.text("找不到安装包"),
                                         unavailableKind: .missingPackage)
            }
            guard NativeInstaller.hasPairingFile else {
                return InstallCapability(available: false,
                                         reason: AppText.text("需要先在「安装设置」里连接本机通道，并保持 Wi-Fi 开启"),
                                         unavailableKind: .needsNativeChannel)
            }
            return InstallCapability(available: true, reason: nil, unavailableKind: nil)
        case .overTheAir:
            let signed = Self.signedSibling(of: package)
            guard FileManager.default.fileExists(atPath: signed.path) else {
                return InstallCapability(available: false,
                                         reason: AppText.text("OTA 需要已签名（或已解密并签名）的安装包"),
                                         unavailableKind: .needsSignedPackage)
            }
            guard installation != nil else {
                return InstallCapability(available: false,
                                         reason: AppText.text("安装服务尚未就绪"),
                                         unavailableKind: .serviceNotReady)
            }
            return InstallCapability(available: true, reason: nil, unavailableKind: nil)
        case .save:
            return InstallCapability(available: true, reason: nil, unavailableKind: nil)
        }
    }

    /// One entry point. `source` is carried for display and bookkeeping only.
    func accept(package: URL, bundleID: String, source: PackageSource,
                method: InstallMethod, installation: InstallationService? = nil,
                progress: @escaping @Sendable (String) -> Void) async throws -> InstallOutcome {
        preferredMethod = method
        let capability = capability(for: method, package: package, installation: installation)
        guard capability.available else {
            throw InstallFailure(message: capability.reason ?? AppText.text("当前不可用"),
                                 retryable: false,
                                 needsNativeChannel: capability.unavailableKind == .needsNativeChannel)
        }

        switch method {
        case .native:
            do {
                let outcome = try await NativeInstaller.install(package: package, bundleID: bundleID) { phase in
                    progress(Self.text(for: phase))
                }
                let installed = outcome.after?.installed ?? true
                return InstallOutcome(upgraded: outcome.upgraded, installed: installed, signedOrOTA: false)
            } catch {
                throw Self.failure(from: error, package: package)
            }
        case .overTheAir:
            guard let installation else {
                throw InstallFailure(message: AppText.text("安装服务尚未就绪"), retryable: true)
            }
            let signed = Self.signedSibling(of: package)
            do {
                _ = try await installation.localURL(file: signed)
                return InstallOutcome(upgraded: false, installed: true, signedOrOTA: true)
            } catch {
                throw Self.failure(from: error, package: package)
            }
        case .save:
            return InstallOutcome(upgraded: false, installed: false, signedOrOTA: false)
        }
    }

    nonisolated static func signedSibling(of package: URL) -> URL {
        package.deletingLastPathComponent()
            .appendingPathComponent(package.deletingPathExtension().lastPathComponent + "-signed.ipa")
    }

    // MARK: text

    nonisolated private static func text(for phase: NativeInstaller.Phase) -> String {
        switch phase {
        case .connecting: return AppText.text("连接本机通道…")
        case let .uploading(value): return AppText.text("传输安装包 \(Int(value * 100))%")
        case let .installing(value): return AppText.text("安装中 \(Int(value * 100))%")
        }
    }

    /// Rewrites an installer error into a stage-labelled, actionable sentence and keeps the
    /// package path so the user knows the file is still there.
    nonisolated private static func failure(from error: Error, package: URL) -> InstallFailure {
        let raw = error.localizedDescription
        let stage: String
        let retryable: Bool
        var needsChannel = false
        if raw.contains("连接本机安装服务") || raw.contains("LocalDevVPN") || raw.lowercased().contains("tunnel") || raw.lowercased().contains("pair") {
            stage = AppText.text("未能连接本机安装通道。请在「安装设置」里连接通道后重试")
            retryable = true
            needsChannel = true
        } else if raw.contains("上传") || raw.lowercased().contains("upload") {
            stage = AppText.text("安装包传输中断")
            retryable = true
        } else if raw.contains("安装") || raw.lowercased().contains("install") {
            stage = AppText.text("安装阶段失败")
            retryable = true
        } else {
            stage = AppText.text("安装失败")
            retryable = true
        }
        let kept = "\n" + AppText.text("安装包已保存在本地，可重试或改为分享。")
        return InstallFailure(message: stage + kept, retryable: retryable, needsNativeChannel: needsChannel)
    }
}

struct InstallFailure: LocalizedError {
    let message: String
    let retryable: Bool
    var needsNativeChannel: Bool = false
    var errorDescription: String? { message }
}
