import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(TestFlightKit)
import TestFlightKit

/// Official TestFlight-inspired App Detail view: full-bleed tinted hero header,
/// centered icon & primary action button, 3-column info strip (Developer / Version /
/// Expiration), collapsible What's New and Description cards, official App Info
/// (devices, download/install size, compatibility, invite link, privacy policy),
/// local package actions (working Share & Decrypt sheets), and beta terms footer.
struct TestFlightDetailView: View {
    let app: TFBetaApp
    @ObservedObject var model: TFHomeModel
    @EnvironmentObject private var store: ToolStore

    @State private var expandWhatsNew = false
    @State private var expandDescription = false
    @State private var showingInstallSheet = false
    @State private var sharedFile: SharedFile?
    @State private var decryptTarget: TFDecryptTarget?
    @State private var decryptError: String?
    @State private var heroCollapsed = false
    @State private var copiedBundleID = false
    @State private var cachedPackageBytes: Int64 = 0
    @State private var quickBuildInfo: QuickBuildInfo?

    private var detail: TFAppDetail? { model.details[app.id] }
    private var rowState: TFRowState { model.rowState(app) }
    private var isInstalled: Bool { model.installedAppIDs.contains(app.id) }
    private var isInstalling: Bool { model.installingAppIDs.contains(app.id) }
    private var iconColors: TFIconColors? { model.iconColors[app.id] ?? detail?.iconAsset?.colors }

    private var displayName: String {
        if let name = detail?.name, !name.isEmpty { return name }
        return app.name
    }

    private var availability: TFAppAvailability {
        detail?.availability ?? .testing
    }

    private var developerName: String {
        if let dev = detail?.developerName, !dev.isEmpty { return TFAppDetail.cleanDeveloperName(dev) }
        if let dev = app.developerName, !dev.isEmpty { return TFAppDetail.cleanDeveloperName(dev) }
        return "—"
    }

    private var shortVersion: String {
        if let v = detail?.shortVersion, !v.isEmpty { return v }
        if let v = app.latestVersion, !v.isEmpty { return v }
        return "—"
    }

    private var hasVersionOrExpiration: Bool {
        shortVersion != "—" || daysRemaining != nil
    }

    private var incompatibleNoticeText: String {
        let platforms = (detail?.incompatiblePlatforms ?? []).joined(separator: " / ")
        if platforms.isEmpty {
            return AppText.text("“\(displayName)”暂不支持在当前设备上测试。")
        }
        return AppText.text("“\(displayName)”只可在 \(platforms) 设备上测试。")
    }

    private var buildSubtitle: String {
        if let b = detail?.buildVersion, !b.isEmpty { return "Build \(b)" }
        if let id = detail?.buildID, !id.isEmpty { return "Build \(id)" }
        return "TestFlight"
    }

    private var daysRemaining: Int? {
        detail?.daysRemaining()
    }

    private var inviteLinkURL: URL? {
        guard let raw = detail?.shareURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var privacyURL: URL? {
        guard let raw = detail?.privacyPolicyURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroHeader

                VStack(alignment: .leading, spacing: 20) {
                    if availability == .incompatible {
                        availabilityNoticeCard(incompatibleNoticeText)
                    } else if availability == .previouslyTested {
                        availabilityNoticeCard(AppText.text("开发者已移除你所测试的 Build。"))
                    }

                    if availability != .previouslyTested {
                        infoStripCard
                    }

                    if let whatsNew = detail?.whatsNew, !whatsNew.isEmpty {
                        expandableTextCard(
                            sectionTitle: "测试内容",
                            text: whatsNew,
                            expanded: $expandWhatsNew,
                            prominentHeader: true
                        )
                    }

                    if let description = detail?.description, !description.isEmpty {
                        expandableTextCard(
                            sectionTitle: "App 描述",
                            text: description,
                            expanded: $expandDescription,
                            prominentHeader: false
                        )
                    }

                    if rowState.stage == .done, let packageURL = model.productURL(for: app) {
                        localPackageCard(packageURL: packageURL)
                    }

                    appInfoCard

                    if let terms = detail?.termsOfService, !terms.isEmpty {
                        Text(verbatim: terms)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: Self.topSafeAreaInset)
                Text(verbatim: displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, 72)
                    .frame(height: 44)
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }
            .ignoresSafeArea(edges: .top)
            .opacity(heroCollapsed ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: heroCollapsed)
            .allowsHitTesting(false)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(heroCollapsed ? nil : .dark, for: .navigationBar)
        .toolbar {
            if let inviteLinkURL {
                ToolbarItem(placement: .compatibleTopBarTrailing) {
                    ShareLink(item: inviteLinkURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("分享测试链接"))
                }
            }
        }
        .task(id: app.id) {
            await model.ensureDetailLoaded(for: app)
        }
        .task(id: rowState.output) {
            guard let url = rowState.output else {
                cachedPackageBytes = 0
                quickBuildInfo = nil
                return
            }
            let (size, build) = await Task.detached(priority: .utility) {
                (Int64(url.fileSizeBytes), PackageInfoService.quickBuildInfo(url))
            }.value
            if !Task.isCancelled {
                cachedPackageBytes = size
                quickBuildInfo = build
            }
        }
        .sheet(isPresented: $showingInstallSheet) {
            if let packageURL = model.productURL(for: app) {
                PackageInstallationView(
                    job: model.makeInstallJob(for: app, packageURL: packageURL),
                    packageFileURL: packageURL,
                    packageIconURL: model.iconFiles[app.id],
                    isTestFlight: true,
                    onInstalled: {
                        model.markInstalled(app.id)
                    }
                )
                .sheetNotice()
                .environmentObject(store)
                .environmentObject(store.downloads)
            }
        }
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
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack {
            heroBackground
            VStack(spacing: 16) {
                TFAppIconView(
                    fileURL: model.iconFiles[app.id],
                    colors: iconColors,
                    appName: displayName,
                    size: 108,
                    revision: model.iconRevisions[app.id] ?? 0
                )
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

                VStack(spacing: 6) {
                    Text(verbatim: displayName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    if availability == .testing, let statusLine = heroStatusLine {
                        Text(verbatim: statusLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)

                if availability == .testing {
                    heroPrimaryAction
                        .padding(.horizontal, 36)
                        .padding(.top, 4)
                }
            }
            .padding(.top, 112)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { geo in
                let collapsed = geo.frame(in: .global).maxY < (Self.topSafeAreaInset + 52)
                Color.clear
                    .onAppear { heroCollapsed = collapsed }
                    .compatibleOnChange(of: collapsed) { value in
                        heroCollapsed = value
                    }
            }
        )
    }

    private func availabilityNoticeCard(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var heroBackground: some View {
        TFHeroAmbientBackground(
            fileURL: model.iconFiles[app.id],
            colors: iconColors,
            revision: model.iconRevisions[app.id] ?? 0
        )
    }

    private var heroStatusLine: String? {
        switch rowState.stage {
        case .idle, .resolving, .installing, .downloading, .verifying:
            return nil
        case .paused:
            return AppText.text("已暂停")
        case .done:
            if isInstalling, let note = model.installNotes[app.id] { return note }
            if isInstalled { return AppText.text("已安装") }
            let size = cachedPackageBytes > 0 ? cachedPackageBytes : (detail?.fileSizeBytes ?? 0)
            if size > 0 {
                return "\(byteText(size)) · \(AppText.text("已下载"))"
            }
            return AppText.text("已下载")
        case .failed:
            return rowState.message ?? AppText.text("下载失败")
        }
    }

    @ViewBuilder
    private var heroPrimaryAction: some View {
        switch rowState.stage {
        case .idle:
            heroPillButton(title: AppText.text("获取"), busy: false, enabled: model.isSignedIn) {
                model.start(app)
            }
        case .resolving, .installing:
            heroPillButton(title: AppText.text("取消"), busy: true, enabled: true) {
                model.cancel(app)
            }
        case .downloading:
            heroPillButton(title: AppText.text("暂停"), busy: true, enabled: true) {
                model.pause(app)
            }
        case .paused:
            heroPillButton(title: AppText.text("继续"), busy: false, enabled: true) {
                model.resume(app)
            }
        case .verifying:
            heroPillButton(title: AppText.text("校验安装包…"), busy: true, enabled: false) {}
        case .done:
            heroPillButton(
                title: isInstalling ? AppText.text("正在处理…") : AppText.text("安装"),
                busy: isInstalling,
                enabled: true
            ) {
                showingInstallSheet = true
            }
        case .failed:
            heroPillButton(title: AppText.text("重试"), busy: false, enabled: model.isSignedIn) {
                model.start(app)
            }
        }
    }

    private func heroPillButton(title: String, busy: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        let prominent = enabled && !busy
        return Button {
            UX.tapLight()
            action()
        } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .tint(.white)
                }
                Text(verbatim: title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(prominent ? Color.black : Color.white)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background(
                prominent ? Color.white.opacity(0.94) : Color.white.opacity(enabled ? 0.22 : 0.12),
                in: Capsule()
            )
            .overlay(Capsule().stroke(.white.opacity(prominent ? 0.35 : 0.24), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: title))
    }

    // MARK: - 3-Column Info Strip

    private var infoStripCard: some View {
        HStack(spacing: 0) {
            InfoStripItem(
                caption: "开发者",
                value: developerName,
                symbol: "person.crop.square"
            )
            Divider().frame(height: 44)
            InfoStripItem(
                caption: "版本",
                value: shortVersion,
                detail: buildSubtitle
            )
            Divider().frame(height: 44)
            InfoStripItem(
                caption: "过期时间",
                value: daysRemaining.map(String.init) ?? "—",
                detail: daysRemaining == 0 ? AppText.text("已过期") : (daysRemaining != nil ? AppText.text("天") : " ")
            )
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Expandable Text Card

    private func expandableTextCard(sectionTitle: LocalizedStringKey, text: String,
                                    expanded: Binding<Bool>, prominentHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sectionTitle)
                .font(prominentHeader ? .title3.weight(.bold) : .headline.weight(.semibold))
                .foregroundStyle(prominentHeader ? .primary : .secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(expanded.wrappedValue ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)

                if text.count > 90 || text.components(separatedBy: "\n").count > 3 {
                    HStack {
                        Spacer()
                        Button(expanded.wrappedValue ? "收起" : "更多") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expanded.wrappedValue.toggle()
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - Local Package Quick Actions (Working Share & Decrypt Sheets)

    private func localPackageCard(packageURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本地安装包")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                Button {
                    showingInstallSheet = true
                } label: {
                    HStack {
                        Label("安装与导出", systemImage: "square.and.arrow.down")
                        Spacer()
                        Text(verbatim: byteText(cachedPackageBytes > 0 ? cachedPackageBytes : (detail?.fileSizeBytes ?? 0)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 16)

                NavigationLink {
                    PackageInfoView(file: packageURL)
                } label: {
                    HStack(spacing: 10) {
                        Label("安装包信息", systemImage: "info.circle")
                        Spacer(minLength: 8)
                        if let summary = quickBuildInfo?.compactLabel, !summary.isEmpty {
                            Text(verbatim: summary)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 16)

                Button {
                    UX.tapLight()
                    sharedFile = SharedFile(url: packageURL)
                } label: {
                    HStack {
                        Label("分享安装包", systemImage: "square.and.arrow.up")
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 16)

                Button {
                    UX.tapLight()
                    switch FairPlayPresentation.shared.startStandaloneDecrypt(url: packageURL, displayName: displayName) {
                    case let .started(recordID):
                        decryptTarget = TFDecryptTarget(id: recordID)
                    case let .unavailable(reason):
                        decryptError = reason
                        UX.warning()
                    }
                } label: {
                    HStack {
                        Label("解密导出（可选）", systemImage: "lock.open")
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - App Information Card

    private var appInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App 信息")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                infoRow("开发者", developerName)
                if let bundleID = effectiveBundleID {
                    Divider().padding(.leading, 16)
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = bundleID
                        #endif
                        copiedBundleID = true
                        UX.feedback()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            copiedBundleID = false
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Bundle ID")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(verbatim: bundleID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.trailing)
                            Image(systemName: copiedBundleID ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(copiedBundleID ? .green : .secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let devices = detail?.supportedDevices, !devices.isEmpty {
                    Divider().padding(.leading, 16)
                    infoRow("支持设备", ListFormatter.localizedString(byJoining: devices))
                }
                if let size = detail?.fileSizeBytes, size > 0 {
                    Divider().padding(.leading, 16)
                    infoRow("下载大小", byteText(size))
                }
                if let uncompressed = detail?.fileSizeUncompressedBytes,
                   uncompressed > 0, uncompressed != detail?.fileSizeBytes {
                    Divider().padding(.leading, 16)
                    infoRow("安装大小", byteText(uncompressed))
                }
                if availability != .previouslyTested,
                   let compat = detail?.compatibilityStatement, !compat.isEmpty {
                    Divider().padding(.leading, 16)
                    infoRow("兼容性", compat)
                }
                if let date = detail?.releaseDate {
                    Divider().padding(.leading, 16)
                    infoRow("发布日期", Self.dateFormatter.string(from: date))
                }
                if let inviteLinkURL {
                    Divider().padding(.leading, 16)
                    ShareLink(item: inviteLinkURL) {
                        HStack {
                            Text("公开测试链接")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text("分享")
                                .font(.subheadline)
                            Image(systemName: "square.and.arrow.up")
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                if let privacyURL {
                    Divider().padding(.leading, 16)
                    Link(destination: privacyURL) {
                        HStack {
                            Text("隐私政策")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text("查看")
                                .font(.subheadline)
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var effectiveBundleID: String? {
        if let b = detail?.bundleID, !b.isEmpty { return b }
        if !app.bundleID.isEmpty { return app.bundleID }
        return nil
    }

    private func infoRow(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(monospaced ? .caption.monospaced() : .subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private static var topSafeAreaInset: CGFloat {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 59
        #else
        return 59
        #endif
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

#endif
