import Foundation
import UIKit

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
        case unsupportedOS
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
            guard NativeInstaller.isSystemVersionSupported else {
                return InstallCapability(available: false,
                                         reason: AppText.text("原生安装需要 iOS 17.4 及以上系统"),
                                         unavailableKind: .unsupportedOS)
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.failure(from: error, package: package)
            }
        case .overTheAir:
            guard let installation else {
                throw InstallFailure(message: AppText.text("安装服务尚未就绪"), retryable: true)
            }
            let signed = Self.signedSibling(of: package)
            do {
                let name = signed.deletingPathExtension().lastPathComponent
                let job = DownloadJob(app: StoreApp(id: bundleID, name: name, bundleID: bundleID, version: ""), status: .completed)
                let installURL = try await installation.automaticInstallURL(job: job, file: signed)
                let opened = await UIApplication.shared.open(installURL)
                guard opened else {
                    throw InstallFailure(message: AppText.text("安装失败") + "\n" + AppText.text("安装包已保存在本地，可重试或改为分享。"),
                                         retryable: true)
                }
                return InstallOutcome(upgraded: false, installed: true, signedOrOTA: true)
            } catch let failure as InstallFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
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
        let stage: String
        let retryable = true
        var needsChannel = false
        if let native = error as? NativeInstaller.Failure {
            switch native.stage {
            case "connect", "pairing_file", "pairing", "tunnel":
                stage = AppText.text("未能连接本机安装通道。请在「安装设置」里连接通道后重试")
                needsChannel = true
            case "upload":
                stage = AppText.text("安装包传输中断")
            case "install":
                stage = AppText.text("安装阶段失败")
            default:
                stage = AppText.text("安装失败")
            }
        } else {
            let raw = error.localizedDescription
            let lower = raw.lowercased()
            if raw.contains("连接本机安装服务") || raw.contains("LocalDevVPN") || lower.contains("tunnel") || lower.contains("pair") {
                stage = AppText.text("未能连接本机安装通道。请在「安装设置」里连接通道后重试")
                needsChannel = true
            } else if raw.contains("上传") || lower.contains("upload") {
                stage = AppText.text("安装包传输中断")
            } else if raw.contains("安装") || lower.contains("install") {
                stage = AppText.text("安装阶段失败")
            } else {
                stage = AppText.text("安装失败")
            }
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
