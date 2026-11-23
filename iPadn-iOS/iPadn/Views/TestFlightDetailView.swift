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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var selectedPlatformID: String?

    private var detail: TFAppDetail? { model.details[app.id] }
    private var downloadableBuilds: [TFPlatformBuild] {
        detail?.downloadablePlatformBuilds ?? []
    }
    private var selectedBuild: TFPlatformBuild? {
        if let id = selectedPlatformID,
           let match = downloadableBuilds.first(where: { $0.id == id }) {
            return match
        }
        return downloadableBuilds.first
    }
    private var isSelectedBuildNative: Bool {
        selectedBuild?.isNativeToPhone ?? (availability == .testing)
    }
    private var canDownloadSelected: Bool {
        if let selectedBuild { return selectedBuild.supportsIPADownload }
        return availability == .testing
    }
    private var rowState: TFRowState { model.rowState(app, build: selectedBuild) }
    private var activePackageURL: URL? {
        rowState.output ?? model.productURL(for: app, buildID: selectedBuild?.buildID)
    }
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
        if let v = selectedBuild?.shortVersion, !v.isEmpty { return v }
        if let v = detail?.shortVersion, !v.isEmpty { return v }
        if let v = app.latestVersion, !v.isEmpty { return v }
        return "—"
    }

    private var hasVersionOrExpiration: Bool {
        shortVersion != "—" || daysRemaining != nil
    }

    private var incompatibleNoticeText: String {
        if let build = selectedBuild, !build.isNativeToPhone {
            return AppText.text("“\(displayName)”的 \(build.displayName) 测试版可下载 IPA 后分享、导出或解密，无法在当前设备上直接安装。")
        }
        let platforms = (detail?.incompatiblePlatforms ?? []).joined(separator: " / ")
        if platforms.isEmpty {
            return AppText.text("“\(displayName)”暂不支持在当前设备上测试。")
        }
        return AppText.text("“\(displayName)”只可在 \(platforms) 设备上测试。")
    }

    private var buildSubtitle: String {
        if let b = selectedBuild?.buildVersion, !b.isEmpty { return "Build \(b)" }
        if let id = selectedBuild?.buildID, !id.isEmpty { return "Build \(id)" }
        if let b = detail?.buildVersion, !b.isEmpty { return "Build \(b)" }
        if let id = detail?.buildID, !id.isEmpty { return "Build \(id)" }
        return "TestFlight"
    }

    private var daysRemaining: Int? {
        selectedBuild?.daysRemaining() ?? detail?.daysRemaining()
    }

    private var effectiveWhatsNew: String? {
        if let notes = selectedBuild?.whatsNew, !notes.isEmpty { return notes }
        return detail?.whatsNew
    }

    private var effectiveFileSizeBytes: Int64? {
        selectedBuild?.fileSizeBytes ?? detail?.fileSizeBytes
    }

    private var effectiveUncompressedBytes: Int64? {
        selectedBuild?.fileSizeUncompressedBytes ?? detail?.fileSizeUncompressedBytes
    }

    private var effectiveCompatibility: String? {
        selectedBuild?.compatibilityStatement ?? detail?.compatibilityStatement
    }

    private var effectiveReleaseDate: Date? {
        selectedBuild?.releaseDate ?? detail?.releaseDate
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
                    if availability == .incompatible || (!isSelectedBuildNative && canDownloadSelected) {
                        availabilityNoticeCard(incompatibleNoticeText)
                    } else if availability == .previouslyTested {
                        availabilityNoticeCard(AppText.text("开发者已移除你所测试的 Build。"))
                    }

                    if availability != .previouslyTested {
                        infoStripCard
                    }

                    if let whatsNew = effectiveWhatsNew, !whatsNew.isEmpty {
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

                    if rowState.stage == .done, let packageURL = activePackageURL {
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
            #if canImport(UIKit)
            .background(TFHeroChromeConfigurator(heroCollapsed: heroCollapsed))
            #endif
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(heroCollapsed ? .automatic : .hidden, for: .navigationBar)
        .toolbarColorScheme(heroCollapsed ? nil : .dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(verbatim: displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(heroCollapsed ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: heroCollapsed)
                    .accessibilityHidden(!heroCollapsed)
            }
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
            if let packageURL = activePackageURL {
                PackageInstallationView(
                    job: model.makeInstallJob(for: app, packageURL: packageURL),
                    packageFileURL: packageURL,
                    packageIconURL: model.iconFiles[app.id],
                    isTestFlight: true
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

                    if canDownloadSelected, let statusLine = heroStatusLine {
                        Text(verbatim: statusLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                            .id(statusLine)
                            .transition(.statusSwap(reduceMotion: reduceMotion))
                    }
                }
                .padding(.horizontal, 24)
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: heroStatusLine)

                if downloadableBuilds.count > 1 {
                    heroPlatformPicker
                }

                if canDownloadSelected {
                    heroPrimaryAction
                        .padding(.horizontal, 36)
                        .padding(.top, 4)
                }
            }
            .padding(.top, 112)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .compatibleOnGeometryChange(for: Bool.self) { geo in
            geo.frame(in: .global).maxY < (Self.topSafeAreaInset + 52)
        } action: { collapsed in
            if heroCollapsed != collapsed {
                heroCollapsed = collapsed
            }
        }
    }

    private var heroPlatformPicker: some View {
        HStack(spacing: 6) {
            ForEach(downloadableBuilds) { build in
                let active = (selectedBuild?.id == build.id)
                Button {
                    guard selectedPlatformID != build.id else { return }
                    UX.feedback()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        selectedPlatformID = build.id
                    }
                } label: {
                    Text(verbatim: build.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(active ? Color.black : Color.white.opacity(0.88))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(active ? Color.white.opacity(0.92) : Color.white.opacity(0.16))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(.horizontal, 24)
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
            let size = cachedPackageBytes > 0 ? cachedPackageBytes : (effectiveFileSizeBytes ?? 0)
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
        let idleTitle: String = {
            if let build = selectedBuild, !build.isNativeToPhone {
                return AppText.text("获取 \(build.displayName) 版")
            }
            return AppText.text("获取")
        }()
        let doneTitle: String = {
            if !isSelectedBuildNative {
                return AppText.text("分享安装包")
            }
            return isInstalling ? AppText.text("正在处理…") : AppText.text("安装")
        }()
        let config: (title: String, busy: Bool, progress: Double?, enabled: Bool) = {
            switch rowState.stage {
            case .idle:
                return (idleTitle, false, nil, model.isSignedIn)
            case .resolving, .installing:
                return (AppText.text("取消"), true, nil, true)
            case .downloading:
                return (
                    AppText.text("暂停"),
                    rowState.total <= 0,
                    rowState.total > 0 ? rowState.fraction : nil,
                    true
                )
            case .paused:
                return (AppText.text("继续"), false, nil, true)
            case .verifying:
                return (AppText.text("校验安装包…"), true, nil, false)
            case .done:
                return (doneTitle, isSelectedBuildNative && isInstalling, nil, true)
            case .failed:
                return (AppText.text("重试"), false, nil, model.isSignedIn)
            }
        }()
        heroPillButton(
            title: config.title,
            busy: config.busy,
            progress: config.progress,
            enabled: config.enabled
        ) {
            switch rowState.stage {
            case .idle, .failed:
                model.start(app, build: selectedBuild)
            case .resolving, .installing:
                model.cancel(app)
            case .downloading:
                model.pause(app)
            case .paused:
                model.resume(app)
            case .verifying:
                break
            case .done:
                if isSelectedBuildNative {
                    showingInstallSheet = true
                } else if let packageURL = activePackageURL {
                    sharedFile = SharedFile(url: packageURL)
                }
            }
        }
    }

    private func heroPillButton(title: String, busy: Bool, progress: Double? = nil, enabled: Bool, action: @escaping () -> Void) -> some View {
        let prominent = enabled && !busy && progress == nil
        let hasProgress = progress != nil
        return Button {
            UX.tapLight()
            action()
        } label: {
            HStack(spacing: 8) {
                if let progress {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.28), lineWidth: 2.4)
                        Circle()
                            .trim(from: 0, to: max(0.02, min(1, progress)))
                            .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
                        RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                            .fill(.white)
                            .frame(width: 7, height: 7)
                    }
                    .frame(width: 22, height: 22)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.72).combined(with: .opacity))
                } else if busy {
                    ProgressView()
                        .tint(.white)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.72).combined(with: .opacity))
                }
                Text(verbatim: title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(prominent ? Color.black : Color.white)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(prominent ? Color.white.opacity(0.94) : Color.white.opacity(enabled ? 0.22 : 0.12))
                    if let progress {
                        GeometryReader { geo in
                            Capsule()
                                .fill(.white.opacity(0.18))
                                .frame(width: max(0, geo.size.width * min(1, max(0, progress))))
                                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
                        }
                        .clipShape(Capsule())
                        .transition(.opacity)
                    }
                }
            }
            .overlay(Capsule().stroke(.white.opacity(prominent ? 0.35 : 0.24), lineWidth: 0.5))
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: prominent)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: busy)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: hasProgress)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: title)
        }
        .buttonStyle(PillButtonPressStyle(scale: 0.96, opacity: 0.86))
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
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
                if isSelectedBuildNative {
                    Button {
                        showingInstallSheet = true
                    } label: {
                        HStack {
                            Label("安装与导出", systemImage: "square.and.arrow.down")
                            Spacer()
                            Text(verbatim: byteText(cachedPackageBytes > 0 ? cachedPackageBytes : (effectiveFileSizeBytes ?? 0)))
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
                }

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
                if let size = effectiveFileSizeBytes, size > 0 {
                    Divider().padding(.leading, 16)
                    infoRow("下载大小", byteText(size))
                }
                if let uncompressed = effectiveUncompressedBytes,
                   uncompressed > 0, uncompressed != effectiveFileSizeBytes {
                    Divider().padding(.leading, 16)
                    infoRow("安装大小", byteText(uncompressed))
                }
                if availability != .previouslyTested,
                   let compat = effectiveCompatibility, !compat.isEmpty {
                    Divider().padding(.leading, 16)
                    infoRow("兼容性", compat)
                }
                if let date = effectiveReleaseDate {
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

#if canImport(UIKit)
/// Suppresses iOS 26's light-tinted top `UIScrollEdgeEffect` over the full-bleed dark
/// TestFlight hero header and switches `UINavigationBar.barStyle` so status bar text
/// stays crisp white over the dark hero, restoring defaults on scroll or dismissal.
private struct TFHeroChromeConfigurator: UIViewRepresentable {
    let heroCollapsed: Bool

    final class Coordinator {
        weak var scrollView: UIScrollView?
        weak var navBar: UINavigationBar?
        weak var navController: UINavigationController?
        var savedBarStyle: UIBarStyle?

        func apply(collapsed: Bool, from view: UIView) {
            if scrollView == nil {
                var current: UIView? = view.superview
                while let node = current {
                    if let sv = node as? UIScrollView {
                        scrollView = sv
                        break
                    }
                    current = node.superview
                }
            }
            if navController == nil {
                var responder: UIResponder? = view.next
                while let next = responder {
                    if let vc = next as? UIViewController {
                        navController = (vc as? UINavigationController) ?? vc.navigationController
                        navBar = navController?.navigationBar
                        break
                    }
                    responder = next.next
                }
            }
            if #available(iOS 26.0, *), let sv = scrollView {
                let edgeSelector = NSSelectorFromString("topEdgeEffect")
                if sv.responds(to: edgeSelector),
                   let effect = sv.value(forKey: "topEdgeEffect") as? NSObject,
                   effect.responds(to: NSSelectorFromString("setHidden:")) {
                    effect.setValue(!collapsed, forKey: "hidden")
                }
            }
            if let navBar {
                if savedBarStyle == nil { savedBarStyle = navBar.barStyle }
                let target: UIBarStyle = collapsed ? (savedBarStyle ?? .default) : .black
                if navBar.barStyle != target {
                    navBar.barStyle = target
                    navController?.setNeedsStatusBarAppearanceUpdate()
                }
            }
        }

        func restore() {
            if #available(iOS 26.0, *), let sv = scrollView {
                let edgeSelector = NSSelectorFromString("topEdgeEffect")
                if sv.responds(to: edgeSelector),
                   let effect = sv.value(forKey: "topEdgeEffect") as? NSObject,
                   effect.responds(to: NSSelectorFromString("setHidden:")) {
                    effect.setValue(false, forKey: "hidden")
                }
            }
            if let navBar, let saved = savedBarStyle, navBar.barStyle != saved {
                navBar.barStyle = saved
                navController?.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    final class AnchorView: UIView {
        var onWindowChange: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindowChange?() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        let collapsed = heroCollapsed
        uiView.onWindowChange = { [weak coordinator = context.coordinator, weak uiView] in
            guard let coordinator, let uiView else { return }
            DispatchQueue.main.async {
                coordinator.apply(collapsed: collapsed, from: uiView)
            }
        }
        DispatchQueue.main.async {
            context.coordinator.apply(collapsed: collapsed, from: uiView)
        }
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        uiView.onWindowChange = nil
        coordinator.restore()
    }
}
#endif

#endif
