import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(TestFlightKit)
import TestFlightKit

// MARK: - Local Icon Image Cache (revision-keyed; zero main-thread disk stat in body)

private enum TFIconImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let store = NSCache<NSString, UIImage>()
        store.totalCostLimit = 24 * 1024 * 1024
        return store
    }()

    static func cacheKey(url: URL, side: CGFloat, revision: Int) -> NSString {
        "\(revision)|\(Int(side))|\(url.path)" as NSString
    }

    static func cached(url: URL, side: CGFloat, revision: Int) -> UIImage? {
        cache.object(forKey: cacheKey(url: url, side: side, revision: revision))
    }

    static func load(url: URL, side: CGFloat, revision: Int) async -> UIImage? {
        let key = cacheKey(url: url, side: side, revision: revision)
        if let hit = cache.object(forKey: key) { return hit }
        return await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
            let pixels = side * 3
            let thumb = await image.byPreparingThumbnail(ofSize: CGSize(width: pixels, height: pixels)) ?? image
            let cost = Int(thumb.size.width * thumb.scale * thumb.size.height * thumb.scale * 4)
            cache.setObject(thumb, forKey: key, cost: cost)
            return thumb
        }.value
    }
}

// MARK: - App Icon with `iconAsset.colors` Gradient Placeholder

struct TFAppIconView: View {
    let fileURL: URL?
    let colors: TFIconColors?
    let appName: String
    var size: CGFloat = 64
    var revision: Int = 0

    @State private var loaded: (key: String, image: UIImage)?

    private var currentKey: String {
        guard let fileURL else { return "" }
        return TFIconImageCache.cacheKey(url: fileURL, side: size, revision: revision) as String
    }

    private var currentImage: UIImage? {
        guard let fileURL else { return nil }
        if let loaded, loaded.key == currentKey { return loaded.image }
        return TFIconImageCache.cached(url: fileURL, side: size, revision: revision)
    }

    var body: some View {
        let radius = size * UX.iconCorner
        ZStack {
            if let image = currentImage {
                iconBackdropColor
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
        .task(id: currentKey) {
            guard let fileURL else { return }
            if let hit = TFIconImageCache.cached(url: fileURL, side: size, revision: revision) {
                if loaded?.key != currentKey { loaded = (currentKey, hit) }
                return
            }
            guard let image = await TFIconImageCache.load(url: fileURL, side: size, revision: revision), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                loaded = (currentKey, image)
            }
        }
        .onDisappear { loaded = nil }
    }

    private var placeholderView: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.quaternary)
        }
    }

    private var iconBackdropColor: Color {
        if let bg = colors?.bgHex, let parsed = Self.parseHexColor(bg)?.0 {
            return parsed
        }
        return Color(.secondarySystemGroupedBackground)
    }

    static func heroGradientColors(from colors: TFIconColors?) -> [Color] {
        if let gradient = colors?.gradientHexes, !gradient.isEmpty {
            let parsed = gradient.compactMap(Self.parseHexColor).map(\.0)
            if parsed.count >= 2 { return parsed }
            if let first = parsed.first { return [first, first.opacity(0.75)] }
        }
        if let bg = colors?.bgHex, let single = Self.parseHexColor(bg)?.0 {
            return [single, single.opacity(0.72)]
        }
        return [Color(.sRGB, red: 0.24, green: 0.27, blue: 0.34, opacity: 1),
                Color(.sRGB, red: 0.14, green: 0.16, blue: 0.22, opacity: 1)]
    }

    private static func parseHexColor(_ hex: String) -> (Color, Double)? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6 || cleaned.count == 8, let raw = UInt64(cleaned, radix: 16) else { return nil }
        let r, g, b, a: Double
        if cleaned.count == 6 {
            r = Double((raw >> 16) & 0xFF) / 255.0
            g = Double((raw >> 8) & 0xFF) / 255.0
            b = Double(raw & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((raw >> 24) & 0xFF) / 255.0
            g = Double((raw >> 16) & 0xFF) / 255.0
            b = Double((raw >> 8) & 0xFF) / 255.0
            a = Double(raw & 0xFF) / 255.0
        }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (Color(.sRGB, red: r, green: g, blue: b, opacity: a), luminance)
    }
}

/// Ambient Apple-Music / App-Store style blurred artwork backdrop for TestFlight detail hero.
struct TFHeroAmbientBackground: View {
    let fileURL: URL?
    let colors: TFIconColors?
    var revision: Int = 0

    @State private var loaded: (key: String, image: UIImage)?

    private var currentKey: String {
        guard let fileURL else { return "" }
        return TFIconImageCache.cacheKey(url: fileURL, side: 64, revision: revision) as String
    }

    private var currentImage: UIImage? {
        guard let fileURL else { return nil }
        if let loaded, loaded.key == currentKey { return loaded.image }
        return TFIconImageCache.cached(url: fileURL, side: 64, revision: revision)
    }

    var body: some View {
        let baseColors = TFAppIconView.heroGradientColors(from: colors)
        Color.clear
            .background {
                ZStack {
                    LinearGradient(colors: baseColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let image = currentImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(1.35)
                            .saturation(1.25)
                            .blur(radius: 44)
                            .opacity(0.75)
                    }
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.36),
                            Color.black.opacity(0.48),
                            Color.black.opacity(0.64),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .clipped()
            .task(id: currentKey) {
            guard let fileURL else { return }
            if let hit = TFIconImageCache.cached(url: fileURL, side: 64, revision: revision) {
                if loaded?.key != currentKey { loaded = (currentKey, hit) }
                return
            }
            guard let image = await TFIconImageCache.load(url: fileURL, side: 64, revision: revision), !Task.isCancelled else { return }
            loaded = (currentKey, image)
        }
    }
}

// MARK: - 2FA Verification Sheet

struct TFVerificationSheet: View {
    let accountDisplay: String
    let channel: TFLogin.VerificationChannel
    @Binding var code: String
    let isSubmitting: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private var isSMS: Bool {
        if case .sms = channel { return true }
        return false
    }

    private var promptText: String {
        switch channel {
        case .trustedDevice:
            return AppText.text("Apple 已向 \(accountDisplay) 的受信任设备发送登录请求，请在设备上点按「允许」并输入 6 位验证码。")
        case let .sms(phoneDisplay):
            if let phoneDisplay, !phoneDisplay.isEmpty {
                return AppText.text("Apple 已向 \(phoneDisplay) 发送 6 位短信验证码，请等待本次最新短信送达后输入。")
            }
            return AppText.text("Apple 已向 \(accountDisplay) 的受信任手机号发送 6 位短信验证码，请等待本次最新短信送达后输入。")
        }
    }

    private var tipText: String {
        if isSMS {
            return AppText.text("请勿填入之前收到的旧短信验证码；如暂未收到短信，可稍候几秒或取消后重新尝试。")
        }
        return AppText.text("若未收到受信任设备弹窗，请在已登录该账号的设备上前往「设置 › Apple 账户 › 登录与安全 › 获取验证码」，输入显示的 6 位验证码即可。")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: isSMS ? "message.badge.filled.fill" : "lock.shield.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                        .padding(.top, 8)
                        .accessibilityHidden(true)

                    Text("双重认证")
                        .font(.title2.weight(.bold))

                    Text(verbatim: promptText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    VerificationCodeField(code: $code, disabled: isSubmitting) { _ in
                        onSubmit()
                    }
                    .padding(.vertical, 6)

                    if isSubmitting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在验证…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        onSubmit()
                    } label: {
                        Text("提交验证码")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isSubmitting || code.count != 6)
                    .accessibilityLabel(Text("提交验证码"))
                    .accessibilityIdentifier("tf.verification.submit")

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        Text(verbatim: tipText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .accessibilityLabel(Text("取消"))
                }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Multi-Phone SMS Selection Sheet

struct TFPhoneSelectionSheet: View {
    let accountDisplay: String
    let phones: [TFLogin.TrustedPhone]
    let onSelect: (TFLogin.TrustedPhone) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(phones) { phone in
                        Button {
                            onSelect(phone)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "message.fill")
                                    .foregroundStyle(.tint)
                                    .frame(width: 24)
                                Text(verbatim: phone.displayNumber.isEmpty ? "#\(phone.id)" : phone.displayNumber)
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("选择受信任手机号")
                } footer: {
                    Text("Apple 将向所选号码为 \(accountDisplay) 发送 6 位短信验证码。")
                }
            }
            .toolPage()
            .navigationTitle("短信验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .accessibilityLabel(Text("取消"))
                }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Native Channel Setup Guide Card

struct TFNativeChannelGuideCard: View {
    let reason: String?
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void
    let onShareFallback: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("需先连接本机通道")
                        .font(.subheadline.weight(.semibold))
                    if let reason, !reason.isEmpty {
                        Text(verbatim: reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                stepLine(1, "确认手机已开启 Wi-Fi")
                stepLine(2, "点按下方「前往本机安装设置」完成连接准备")
                stepLine(3, "开启本机通道后返回此页，点按「重新检测」即可安装")
            }
            .padding(.leading, 2)

            HStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Text("前往本机安装设置")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CapsuleButtonStyle(filled: true))
                .accessibilityLabel(Text("前往本机安装设置"))
                .accessibilityIdentifier("tf.native.guide.settings")

                Button(action: onRecheck) {
                    Text("重新检测")
                }
                .buttonStyle(CapsuleButtonStyle(filled: false))
                .accessibilityLabel(Text("重新检测"))
            }

            if let onShareFallback {
                Button(action: onShareFallback) {
                    Label("先保存或分享安装包", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("先保存或分享安装包"))
            }
        }
        .padding(.vertical, 6)
    }

    private func stepLine(_ index: Int, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index).")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(key)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Decrypt Modal Sheet (Reuses Existing DecryptDetailView Without Touching Decrypt Page)

struct TFDecryptTarget: Identifiable {
    let id: UUID
}

struct TFDecryptModalSheet: View {
    let recordID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DecryptDetailView(recordID: recordID)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
                .navigationDestination(for: PackageRoute.self) { route in
                    switch route {
                    case let .log(id):
                        DecryptLogView(recordID: id)
                    case .help:
                        DecryptHelpView()
                    default:
                        EmptyView()
                    }
                }
        }
    }
}

// MARK: - Install & Export Sheet (Single Coordinator Entry, Hides Unavailable OTA)

struct TFInstallSheet: View {
    let app: TFBetaApp
    let packageURL: URL
    let iconURL: URL?
    let iconColors: TFIconColors?
    let iconRevision: Int
    let installation: InstallationService?
    let isInstalling: Bool
    let isInstalled: Bool
    let installNote: String?
    let installFailed: Bool
    let needsChannelGuide: Bool
    let onInstall: (InstallMethod) -> Void
    let onDelete: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMethod: InstallMethod = .native
    @State private var capabilityRevision = 0
    @State private var confirmingDelete = false
    @State private var sharedFile: SharedFile?
    @State private var decryptTarget: TFDecryptTarget?
    @State private var decryptError: String?

    private var nativeCap: InstallCapability {
        _ = capabilityRevision
        return InstallCoordinator.shared.capability(for: .native, package: packageURL, installation: installation)
    }

    private var otaCap: InstallCapability {
        _ = capabilityRevision
        return InstallCoordinator.shared.capability(for: .overTheAir, package: packageURL, installation: installation)
    }

    /// Hide OTA when no signed sibling exists so TF users never hit a permanently disabled row.
    private var visibleMethods: [InstallMethod] {
        var list: [InstallMethod] = [.native]
        if otaCap.available { list.append(.overTheAir) }
        list.append(.save)
        return list
    }

    private var canExecuteSelected: Bool {
        guard !isInstalling else { return false }
        switch selectedMethod {
        case .native: return nativeCap.available
        case .overTheAir: return otaCap.available
        case .save: return true
        }
    }

    private var showChannelGuide: Bool {
        !nativeCap.available || needsChannelGuide
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        TFAppIconView(fileURL: iconURL, colors: iconColors, appName: app.name, size: 56, revision: iconRevision)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: app.name)
                                .font(.headline)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                if let version = app.latestVersion, !version.isEmpty {
                                    Text(verbatim: "v\(version)")
                                }
                                Text(verbatim: byteText(Int64(packageURL.fileSizeBytes)))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                TagBadge(text: "TestFlight", tint: .secondary)
                                if isInstalled {
                                    TagBadge(text: "已安装", tint: .green)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(visibleMethods) { method in
                        methodRow(method)
                    }
                } header: {
                    Text("安装方式")
                } footer: {
                    Text("选择一次后会自动记住；TestFlight 安装包自带有效签名，原生安装无需解密或自签。")
                }

                if showChannelGuide {
                    Section {
                        TFNativeChannelGuideCard(
                            reason: nativeCap.reason,
                            onOpenSettings: {
                                dismiss()
                                onOpenSettings()
                            },
                            onRecheck: {
                                capabilityRevision += 1
                                syncDefaultSelection()
                                UX.feedback()
                            },
                            onShareFallback: selectedMethod == .save ? nil : {
                                selectedMethod = .save
                                triggerShare()
                            }
                        )
                    }
                }

                if let installNote, !installNote.isEmpty {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            if isInstalling {
                                ProgressView()
                            } else {
                                Image(systemName: installFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(installFailed ? .orange : .green)
                            }
                            Text(verbatim: installNote)
                                .font(.subheadline)
                                .foregroundStyle(installFailed ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    Button {
                        if selectedMethod == .save {
                            triggerShare()
                        } else {
                            onInstall(selectedMethod)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isInstalling { ProgressView().tint(UX.onAccent) }
                            Text(verbatim: isInstalling ? AppText.text("正在处理…") : selectedMethod.label)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canExecuteSelected)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                    .accessibilityLabel(Text(verbatim: selectedMethod.label))
                    .accessibilityIdentifier("tf.install.confirm")
                }

                Section {
                    Button {
                        triggerShare()
                    } label: {
                        Label("分享安装包", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isInstalling)
                    .accessibilityLabel(Text("分享安装包"))

                    Button {
                        startDecrypt()
                    } label: {
                        Label("解密导出（可选）", systemImage: "lock.open")
                    }
                    .disabled(isInstalling)
                    .accessibilityLabel(Text("解密导出（可选）"))

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("删除本地安装包", systemImage: "trash")
                    }
                    .disabled(isInstalling)
                    .accessibilityLabel(Text("删除本地安装包"))
                } header: {
                    Text("更多操作")
                } footer: {
                    Text("直接安装无需解密；仅在需要脱壳 IPA 文件时使用「解密导出」。")
                }
            }
            .toolPage()
            .navigationTitle("安装与导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(isInstalling)
                }
            }
            .interactiveDismissDisabled(isInstalling)
            .onAppear { syncDefaultSelection() }
            .sheet(item: $sharedFile) { item in
                ShareSheet(items: [item.url])
            }
            .sheet(item: $decryptTarget) { target in
                TFDecryptModalSheet(recordID: target.id)
            }
            .alert("无法启动解密", isPresented: Binding(get: { decryptError != nil }, set: { if !$0 { decryptError = nil } })) {
                Button("好", role: .cancel) { decryptError = nil }
            } message: {
                Text(verbatim: decryptError ?? "")
            }
            .actionConfirmation(isPresented: $confirmingDelete, title: "删除本地安装包？", message: "仅删除本机缓存的安装包文件，之后可随时重新下载。", confirmTitle: "删除本地安装包") {
                onDelete()
                dismiss()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func triggerShare() {
        UX.tapLight()
        onInstall(.save)
        sharedFile = SharedFile(url: packageURL)
    }

    private func startDecrypt() {
        UX.tapLight()
        switch FairPlayPresentation.shared.startStandaloneDecrypt(url: packageURL, displayName: app.name) {
        case let .started(recordID):
            decryptTarget = TFDecryptTarget(id: recordID)
        case let .unavailable(reason):
            decryptError = reason
            UX.warning()
        }
    }

    private func methodRow(_ method: InstallMethod) -> some View {
        let capability: InstallCapability = {
            switch method {
            case .native: return nativeCap
            case .overTheAir: return otaCap
            case .save: return InstallCapability(available: true, reason: nil)
            }
        }()
        let subtitle: LocalizedStringKey = {
            switch method {
            case .native: return "直接安装到本机，无需自签或解密"
            case .overTheAir: return "使用同目录已签名安装包通过本机服务安装"
            case .save: return "保留安装包并通过系统面板分享或导出"
            }
        }()
        return Button {
            guard capability.available else { return }
            selectedMethod = method
            UX.feedback()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: method.label)
                        .font(.body)
                        .foregroundStyle(capability.available ? .primary : .secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !capability.available, let reason = capability.reason {
                        Text(verbatim: reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                if selectedMethod == method && capability.available {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!capability.available || isInstalling)
        .accessibilityLabel(Text(verbatim: method.label))
    }

    private func syncDefaultSelection() {
        let preferred = InstallCoordinator.shared.preferredMethod
        if preferred == .native && nativeCap.available {
            selectedMethod = .native
        } else if preferred == .overTheAir && otaCap.available {
            selectedMethod = .overTheAir
        } else if preferred == .save {
            selectedMethod = .save
        } else if nativeCap.available {
            selectedMethod = .native
        } else {
            selectedMethod = .save
        }
    }
}

// MARK: - Top-Right Avatar Account & Settings Sheet (Official TF Store Style)

struct TFAccountSheet: View {
    @ObservedObject var model: TFHomeModel
    let accountStore: TFAccountStore
    let selectedAppleAccount: AppleAccount?
    let onSelectAccount: (TFAccountIdentity) -> Void
    let onSelectCustomAccount: () -> Void
    let onOpenLogin: () -> Void
    let onOpenInstallSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    private var statusDotColor: Color {
        if model.isSignedIn { return .green }
        if model.pageState == .sessionExpired || model.dsidConflict { return .orange }
        return Color.secondary.opacity(0.45)
    }

    private var statusDotAccessibilityLabel: Text {
        if model.isSignedIn { return Text("已连接") }
        if model.pageState == .sessionExpired { return Text("会话已过期") }
        return Text("待验证")
    }

    var body: some View {
        NavigationStack {
            List {
                // Current TestFlight Account Summary (clean minimal dot, no raw DSID/tag clutter)
                Section {
                    HStack(spacing: 14) {
                        AccountAvatar(account: selectedAppleAccount, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(verbatim: selectedAppleAccount.map { $0.name.isEmpty ? $0.id : $0.name }
                                     ?? (model.email.isEmpty ? "TestFlight" : model.email))
                                    .font(.headline)
                                    .lineLimit(1)
                                Circle()
                                    .fill(statusDotColor)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel(statusDotAccessibilityLabel)
                            }
                            if !model.email.isEmpty {
                                Text(verbatim: model.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if model.dsidConflict {
                        InlineIssue(message: AppText.text("检测到账号标识与商店记录不一致，本次 TestFlight 会话已隔离运行，原有账号记录未修改。"))
                    }
                }

                // Switch Account (clean Apple-native rows, no "已保存会话" badge clutter)
                Section {
                    ForEach(accountStore.accounts) { item in
                        let isCurrent = AppleAccount.normalizedIdentifier(item.email)
                            == AppleAccount.normalizedIdentifier(model.email)
                        Button {
                            dismiss()
                            onSelectAccount(item)
                        } label: {
                            HStack(spacing: 12) {
                                AccountAvatar(account: accountStore.account(for: item.email), size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.label)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !item.displayName.isEmpty {
                                        Text(verbatim: item.email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                if isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: item.label))
                    }

                    Button {
                        dismiss()
                        onOpenLogin()
                    } label: {
                        Label("添加 Apple 账号", systemImage: "plus")
                    }

                    Button {
                        dismiss()
                        onSelectCustomAccount()
                    } label: {
                        Label("使用其他 Apple 账号", systemImage: "person.badge.key")
                    }
                } header: {
                    Text("切换账号")
                } footer: {
                    Text("共用 iPadn 账号密码；已授权过的账号切换时会自动恢复 TestFlight 会话，无需每次手动登录。")
                }

                // Settings & Diagnostics
                Section("设置与诊断") {
                    Button {
                        dismiss()
                        onOpenInstallSettings()
                    } label: {
                        HStack {
                            Label("安装设置", systemImage: "square.and.arrow.down")
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        TFDiagnosticsContent(model: model, dismissSheet: { dismiss() })
                    } label: {
                        HStack {
                            Label("网络与诊断", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if model.hasNetworkWarning {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    if model.isSignedIn {
                        Button {
                            dismiss()
                            Task { await model.refreshCatalog() }
                        } label: {
                            Label("刷新列表", systemImage: "arrow.clockwise")
                        }
                    }

                    if !model.email.isEmpty && !model.password.isEmpty {
                        Button {
                            dismiss()
                            model.start(storeAccountDsid: selectedAppleAccount?.dsid ?? "")
                        } label: {
                            Label("重新验证当前账号", systemImage: "lock.rotation")
                        }
                    }
                }

                if model.isSignedIn || TFSessionStore.hasSession(dsid: selectedAppleAccount?.dsid ?? "", email: model.email) {
                    Section {
                        Button("清除当前 TestFlight 会话", role: .destructive) {
                            confirmingSignOut = true
                        }
                        .frame(maxWidth: .infinity)
                    } footer: {
                        Text("仅清除本账号保存的 TestFlight 会话，不会退出 iPadn 商店账号。")
                    }
                }
            }
            .toolPage()
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .actionConfirmation(isPresented: $confirmingSignOut, title: "清除当前 TestFlight 会话？", message: "下次使用此账号访问 TestFlight 时需要重新验证；已下载的安装包会保留。", confirmTitle: "清除会话") {
                model.clearPersistedSession(storeAccountDsid: selectedAppleAccount?.dsid ?? "")
                dismiss()
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Network & Diagnostics Sheet & Embedded Content

struct TFDiagnosticsSheet: View {
    @ObservedObject var model: TFHomeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TFDiagnosticsContent(model: model, dismissSheet: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TFDiagnosticsContent: View {
    @ObservedObject var model: TFHomeModel
    let dismissSheet: () -> Void
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Picker("TF 网络模式", selection: Binding(
                    get: { model.networkMode },
                    set: { model.setNetworkMode($0) }
                )) {
                    ForEach(TFNetworkMode.allCases) { mode in
                        Text(verbatim: Self.localizedModeLabel(mode)).tag(mode)
                    }
                }
                if model.proxyBypassed {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        Text("本次会话已自动改用直连")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("网络")
            } footer: {
                Text("默认跟随系统；代理不可用时自动尝试直连一次。")
            }

            if let diagnosis = model.networkDiagnosis {
                Section("网络异常说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: AppText.text("无法连接 Apple 服务（gsa / testflight）。请检查代理规则是否拦截 *.apple.com，或在设置中把 TF 网络模式改为「强制直连」"))
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(diagnosis.facts, id: \.self) { fact in
                            Text(verbatim: fact)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Button("切换为强制直连并重试") {
                            model.setNetworkMode(.direct)
                            dismissSheet()
                            model.start()
                        }
                        .buttonStyle(CapsuleButtonStyle(filled: true))
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let probe = model.probe {
                Section("网络预检") {
                    if !model.dsidTail.isEmpty {
                        diagRow("DSID", "…" + model.dsidTail)
                    }
                    diagRow("DNS 路径", Self.localizedDNSPath(model.dnsPathSummary))
                    diagRow("HTTP", probe.status.map { "\($0) · \(probe.bytes) B" } ?? (probe.failure ?? AppText.text("无响应")))
                    diagRow("fake-IP", probe.fakeIP != nil ? AppText.text("命中代理假地址") : AppText.text("未命中"))
                    diagRow("判定", Self.localizedVerdict(probe))
                    if !probe.reachable {
                        Text(verbatim: AppText.text("GSA 不可达：疑似代理/VPN 拦截，请关闭手机上的 VPN 或在代理里放行 gsa.apple.com。"))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !model.lines.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.lines.suffix(20).enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                    Button {
                        #if canImport(UIKit)
                        let text = model.lines.joined(separator: "\n")
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true])
                        #endif
                        copied = true
                        UX.feedback()
                    } label: {
                        Label(copied ? "已复制脱敏日志" : "复制脱敏日志", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } header: {
                    Text("诊断日志")
                } footer: {
                    Text("日志已脱敏，不含密码、cookie、会话 ID 或代理凭据。")
                }
            }
        }
        .toolPage()
        .navigationTitle("网络与诊断")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func localizedModeLabel(_ mode: TFNetworkMode) -> String {
        switch mode {
        case .auto: return AppText.text("跟随系统")
        case .direct: return AppText.text("强制直连")
        case .proxy: return AppText.text("强制代理")
        }
    }

    private static func localizedDNSPath(_ raw: String) -> String {
        raw.replacingOccurrences(of: "系统 DNS", with: AppText.text("系统 DNS"))
    }

    private static func localizedVerdict(_ probe: TFGSAProbe) -> String {
        if probe.fakeIP != nil {
            return AppText.text("被代理接管（命中 fake-IP）")
        }
        if probe.reachable {
            return probe.status == 404
                ? AppText.text("网络正常；裸 GET 404 属正常（需要 Store UA）")
                : AppText.text("网络正常")
        }
        if probe.status == nil {
            let reason = probe.failure ?? AppText.text("连接失败")
            return AppText.text("无 HTTP 响应（\(reason)）")
        }
        return AppText.text("网络异常")
    }
}

#endif
