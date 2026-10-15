import SwiftUI
import UIKit

struct AppDetailView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    let app: StoreApp
    /// Start the primary download as soon as the page opens (search "获取").
    var autoStart = false
    @State private var autoStarted = false
    @State private var versions: [AppVersion] = []
    @State private var versionsLoading = false
    @State private var downloadLoading = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var manualID = ""
    @State private var versionSearch = ""
    @State private var versionError: String?
    /// Apple's full list, on unless turned off; remembered across apps.
    @AppStorage("storage_officialVersions") private var official = true
    /// Shown above a public list when Apple's could not be used.
    @State private var versionNote: String?
    /// Version number and date per version ID, read from Apple as rows appear.
    @State private var metadata: [String: VersionMetadata] = [:]
    @State private var metadataLoading = Set<String>()
    @State private var metadataFailures = 0
    @State private var metadataStopped = false
    /// Long histories start with the newest ten versions.
    @State private var showAllVersions = false
    @State private var showLogin = false
    @State private var reauthenticationID: String?
    @State private var retryAfterLoginVersion: String?
    @State private var showVerification = false
    @State private var pendingDownloadVersion: String?
    @State private var retryVersionsAfterVerification = false
    @State private var verifiedForRetry = false
    @State private var showDescription = false
    @State private var reloadID = 0
    @State private var loadedVersionsKey: String?
    @State private var loadedReloadID = 0
    private var versionsKey: String {
        "\(usesApple)-\(reloadID)-\(store.settings.store.country)-\(store.settings.store.platform.rawValue)-\(apple.activeID ?? "")"
    }
    @State private var macWebsite: URL?
    @State private var macInstallers: [MacInstallerService.Installer] = []
    @State private var macLoading = false
    @State private var macOfficialLoading = false
    @State private var macOfficialTask: Task<Void, Never>?
    @State private var enteringMacDownloadURL = false
    @State private var macDownloadURL = ""
    @State private var headerAway = false
    @State private var extras: StoreService.ListingExtras?
    @State private var viewing: StoreService.Screenshot?
    @State private var developerApps: [StoreApp] = []
    /// Listing artwork, else what a download of this app brought along
    /// (delisted apps have no public listing to show).
    private var iconURL: URL? { app.iconURL ?? store.localArtwork(app.id) }
    private var storeURL: URL { URL(string: "https://apps.apple.com/\(store.settings.store.country.lowercased())/app/id\(app.id)")! }
    private var filtered: [AppVersion] {
        versionSearch.isEmpty ? versions : versions.filter {
            displayVersion($0).localizedCaseInsensitiveContains(versionSearch) || $0.id.contains(versionSearch)
        }
    }
    private func displayVersion(_ version: AppVersion) -> String { metadata[version.id]?.version ?? version.version }
    /// Lists from Apple carry only version IDs; each row then reads its own
    /// number and date. Other lists use what is already known.
    /// Apple's list needs a signed-in account; otherwise the public list is shown.
    private var usesApple: Bool { official && apple.active != nil }
    private var readsMetadata: Bool { usesApple && versionNote == nil && !metadataStopped }
    var body: some View {
        List {
            Section {
                header.listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .onScrolledUnderBar { headerAway = $0 }
                infoStrip.listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
            }
            if let shots = extras?.screenshots, !shots.isEmpty {
                Section {
                    // On the page background, edge to edge, as in the App Store.
                    ScreenshotStrip(screenshots: shots, platform: store.settings.store.platform) { viewing = $0 }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                } header: { sectionTitle("预览") }
            }
            versionSection
            if store.settings.store.platform == .macOS { macSection }
            if !app.description.isEmpty {
                Section {
                    Text(app.description).font(.subheadline).lineLimit(showDescription ? nil : 4).textSelection(.enabled)
                    if !showDescription {
                        Button("更多") { withAnimation { showDescription = true } }.font(.subheadline)
                    }
                } header: { sectionTitle("简介") }
            }
            Section {
                if app.isDelisted { LabeledContent("商店状态", value: "已下架") }
                if !app.displayCategory.isEmpty { LabeledContent("类别", value: app.displayCategory) }
                if app.size > 0 { LabeledContent("大小", value: app.size.byteLabel) }
                if !app.minimumOS.isEmpty {
                    LabeledContent("兼容性", value: "\(store.settings.store.platform.title) \(app.minimumOS) 或更高版本")
                }
                if !app.price.isEmpty { LabeledContent("价格", value: app.price) }
                LabeledContent("商店地区", value: store.settings.store.country)
                if !app.bundleID.isEmpty {
                    LabeledContent("Bundle ID") {
                        Text(app.bundleID).font(.footnote.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
                if let developer = extras?.developer, !developer.isEmpty { LabeledContent("开发者", value: developer) }
                if store.settings.store.platform != .macOS {
                    Link(destination: storeURL) { Label("在 App Store 中查看", systemImage: "arrow.up.right.square") }
                }
            } header: { sectionTitle("信息") }
            if !developerApps.isEmpty {
                Section {
                    DeveloperAppsStrip(apps: developerApps)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                } header: { sectionTitle(extras?.developer.isEmpty == false ? "更多来自 \(extras!.developer)" : "同一开发者的其他应用") }
            }
        }
        .toolPage()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // App Store shows the small icon in the bar once the header is gone.
            ToolbarItem(placement: .principal) {
                AppIcon(url: iconURL, size: 30)
                    .opacity(headerAway ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: headerAway)
                    .accessibilityHidden(true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.toggleFavorite(app); UX.feedback() } label: {
                    Image(systemName: store.isFavorite(app) ? "star.fill" : "star")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(store.isFavorite(app) ? "取消收藏" : "收藏应用")
            }
        }
        .alert("下载 Mac 安装包", isPresented: $enteringMacDownloadURL) {
            TextField("https://example.com/App.dmg", text: $macDownloadURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("加入下载") {
                let value = macDownloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: value), MacInstallerService.directPackage(url) else {
                    store.errorMessage = "请输入有效的 HTTPS 下载链接，文件需要是 DMG、PKG 或 ZIP。"
                    return
                }
                enqueueMacInstaller(MacInstallerService.Installer(url: url))
                macDownloadURL = ""
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("输入 DMG、PKG 或 ZIP 安装包的下载链接。")
        }
        .navigationDestination(isPresented: $showLogin) {
            LoginView(initialAccountID: reauthenticationID, onSignedIn: {
                reauthenticationID = nil
                guard let pending = retryAfterLoginVersion else { return }
                retryAfterLoginVersion = nil
                Task { @MainActor in
                    await Task.yield()
                    download(versionID: pending.isEmpty ? nil : pending)
                }
            })
        }
        .sheet(isPresented: $showVerification, onDismiss: {
            guard verifiedForRetry else {
                pendingDownloadVersion = nil
                retryVersionsAfterVerification = false
                return
            }
            verifiedForRetry = false
            if retryVersionsAfterVerification {
                retryVersionsAfterVerification = false
                reloadID += 1
            } else {
                let pending = pendingDownloadVersion
                pendingDownloadVersion = nil
                if let pending { download(versionID: pending.isEmpty ? nil : pending) }
            }
        }) {
            if let accountID = apple.activeID {
                ExistingAccountVerificationView(accountID: accountID, onVerified: {
                    verifiedForRetry = true
                })
                .environmentObject(store)
                .environmentObject(apple)
            }
        }
        .onDisappear { downloadTask?.cancel(); macOfficialTask?.cancel() }
        .task {
            guard autoStart, !autoStarted else { return }
            autoStarted = true
            if apple.active == nil { showLogin = true }
            else if store.settings.store.platform.supportsIPA { download(versionID: app.externalVersionID) }
            else { downloadAppleMacPKG() }
        }
        .task(id: versionsKey) {
            // Coming back to the page (e.g. from the Downloads tab) keeps the
            // loaded list; only a new key or 刷新 fetches again.
            guard versionsKey != loadedVersionsKey else { return }
            let forced = reloadID != loadedReloadID
            // A different region, platform or account lists different versions.
            if !forced { versions = []; showAllVersions = false }
            if await fetchVersions(force: forced) { loadedVersionsKey = versionsKey; loadedReloadID = reloadID }
        }
        .task(id: "\(app.id)-\(store.settings.store.platform.rawValue)-\(store.settings.store.country)") {
            await loadMacInstallers()
        }
        .task(id: "extras-\(app.id)-\(store.settings.store.platform.rawValue)-\(store.settings.store.country)") {
            // Demo data stays offline.
            guard !LocalResources.isPreview else { return }
            let found = try? await StoreService.listingExtras(id: app.id, country: store.settings.store.country,
                                                            platform: store.settings.store.platform)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { extras = found }
            guard let developerID = found?.developerID else { developerApps = []; return }
            let apps = (try? await StoreService.developerApps(developerID, excluding: app.id, country: store.settings.store.country,
                                                             platform: store.settings.store.platform)) ?? []
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { developerApps = apps }
        }
        .fullScreenCover(item: $viewing) { shot in
            ScreenshotViewer(screenshots: extras?.screenshots ?? [shot], selection: shot)
        }
    }
    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
    }

    /// App Store product header: big icon, name, subtitle and the primary capsule.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(url: iconURL, size: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name.isEmpty ? app.bundleID : app.name).font(.title3.weight(.bold))
                    .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                if app.isDelisted {
                    TagBadge(text: "已下架", tint: .orange)
                } else if !app.displayCategory.isEmpty {
                    Text(app.displayCategory).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(app.version.isEmpty ? "版本待查询" : "v\(app.version)")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .layoutPriority(1)
                        .accessibilityIdentifier("app.version")
                    Spacer(minLength: 4)
                    Button { copy(app.id) } label: {
                        HStack(spacing: 4) {
                            Text("ID \(app.id)").monospacedDigit().lineLimit(1)
                            Image(systemName: "doc.on.doc")
                        }.font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("App ID \(app.id)，点按复制")
                    .accessibilityIdentifier("app.copy-id")
                }
                Spacer(minLength: 10)
                HStack(spacing: 12) {
                    primaryButton
                    Spacer(minLength: 0)
                    ShareLink(item: storeURL) { Image(systemName: "square.and.arrow.up").font(.title3) }
                        .buttonStyle(.borderless).accessibilityLabel("分享商店链接")
                }
                if let account = apple.active, store.settings.store.platform.supportsIPA || store.settings.store.platform == .macOS {
                    Text("使用 \(account.id)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let busy = downloadLoading || macOfficialLoading
        if busy {
            HStack(spacing: 10) {
                Button {
                    downloadTask?.cancel(); macOfficialTask?.cancel()
                } label: { ProgressRing(progress: nil) }
                .buttonStyle(.borderless)
                .accessibilityLabel("取消准备下载")
                Text("正在准备…").font(.caption).foregroundStyle(.secondary)
            }
        } else if apple.active == nil {
            RowCapsule(title: "登录", filled: true) { showLogin = true }
        } else if store.settings.store.platform.supportsIPA {
            RowCapsule(title: app.price.isEmpty || app.price == "免费" ? "获取" : "下载", filled: true) {
                download(versionID: app.externalVersionID)
            }
            .accessibilityIdentifier("detail.get")
        } else {
            RowCapsule(title: "获取 PKG", filled: true) { downloadAppleMacPKG() }
                .accessibilityIdentifier("mac.official-pkg")
        }
    }

    /// Info strip under the header. At most four equal cells so it always
    /// fits on one line; everything else is in the 信息 section below.
    private var infoStrip: some View {
        let items = Array(stripItems.prefix(4))
        return HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                items[index]
                if index < items.count - 1 { Divider().frame(height: 40) }
            }
        }
        .padding(.horizontal, 8)
    }

    private var stripItems: [InfoStripItem] {
        let platform = store.settings.store.platform
        var items: [InfoStripItem] = []
        if app.rating > 0 {
            items.append(InfoStripItem(caption: "评分", value: String(format: "%.1f", app.rating),
                                       detail: String(repeating: "★", count: max(0, min(5, Int(app.rating.rounded()))))))
        }
        if app.size > 0 {
            let parts = app.size.byteLabel.components(separatedBy: " ")
            items.append(InfoStripItem(caption: "大小", value: parts.first ?? app.size.byteLabel, detail: parts.count > 1 ? parts.last : nil))
        }
        if !app.minimumOS.isEmpty {
            items.append(InfoStripItem(caption: "兼容性", value: app.minimumOS + "+", detail: platform.title))
        } else {
            items.append(InfoStripItem(caption: "平台", value: platform.title, symbol: platform.symbol))
        }
        if app.isDelisted {
            items.append(InfoStripItem(caption: "状态", value: "已下架", symbol: "archivebox"))
        } else if !app.displayCategory.isEmpty {
            items.append(InfoStripItem(caption: "类别", value: app.displayCategory, symbol: "square.grid.2x2"))
        }
        items.append(InfoStripItem(caption: "地区", value: store.settings.store.country, detail: "商店"))
        return items
    }

    @ViewBuilder private var versionSection: some View {
        Section {
            Toggle("从 Apple 获取完整版本列表", isOn: $official).font(.subheadline)
                .disabled(apple.active == nil)
            if versionsLoading { HStack { ProgressView(); Text("正在查找历史版本…").font(.subheadline).foregroundStyle(.secondary) } }
            if let versionError { InlineIssue(message: versionError) { reloadID += 1 } }
            if let versionNote, !versionsLoading {
                Label(versionNote, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if versions.count > 6 {
                SearchInput(text: $versionSearch, placeholder: "筛选版本号或版本 ID")
            }
            let matches = filtered
            // A search shows every match; otherwise ten until expanded.
            let limit = showAllVersions || !versionSearch.isEmpty ? matches.count : 10
            ForEach(matches.prefix(limit)) { version in
                versionRow(version)
                    .task(id: "\(version.id)-\(readsMetadata)") { await loadMetadata(version) }
            }
            if !versions.isEmpty && matches.isEmpty { Text("没有匹配的版本。").font(.subheadline).foregroundStyle(.secondary) }
            if versionSearch.isEmpty && matches.count > 10 {
                Button {
                    withAnimation(.snappy) { showAllVersions.toggle() }
                } label: {
                    HStack {
                        Text(showAllVersions ? "收起" : "显示全部 \(matches.count) 个版本")
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(showAllVersions ? 180 : 0))
                    }
                    .font(.subheadline.weight(.medium))
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("detail.versions.toggle")
            }
            if versions.isEmpty && !versionsLoading && versionError == nil {
                Text("暂无历史版本").font(.subheadline).foregroundStyle(.secondary)
            }
            DisclosureGroup("手动指定版本 ID") {
                HStack {
                    TextField("内部版本 ID", text: $manualID).keyboardType(.numberPad)
                    RowCapsule(title: "下载", enabled: !manualID.isEmpty && !downloadLoading) { download(versionID: manualID) }
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("版本历史")
                Spacer()
                Button("刷新") { reloadID += 1 }.disabled(versionsLoading).font(.body).textCase(nil)
            }
        }
    }

    private func versionRow(_ version: AppVersion) -> some View {
        let name = displayVersion(version)
        let known = name != "未知版本"
        let reading = !known && metadataLoading.contains(version.id)
        let date = metadata[version.id]?.released?.formatted(.dateTime.year().month().day())
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(known ? "版本 \(name)" : reading ? "版本 0.0.0" : "未知版本")
                    .font(.body.weight(.medium))
                    .redacted(reason: reading ? .placeholder : [])
                Text([date, "版本 ID \(version.id)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .animation(.easeOut(duration: 0.2), value: name)
            Spacer(minLength: 8)
            RowCapsule(title: "下载", enabled: !downloadLoading && !macOfficialLoading) { download(versionID: version.id) }
                .accessibilityLabel(known ? "下载版本 \(name)" : "下载版本 ID \(version.id)")
        }
        .padding(.vertical, 2)
        .contextMenu { Button("复制版本 ID", systemImage: "doc.on.doc") { copy(version.id) } }
    }

    private func loadMetadata(_ version: AppVersion) async {
        guard readsMetadata, metadata[version.id] == nil, !metadataLoading.contains(version.id) else { return }
        metadataLoading.insert(version.id)
        defer { metadataLoading.remove(version.id) }
        do {
            metadata[version.id] = try await store.versionMetadata(app: app, versionID: version.id)
            metadataFailures = 0
        } catch {
            // Scrolled away: not a failure.
            if Task.isCancelled || error is CancellationError { return }
            // Never prompt from a list row; the next download asks to sign in.
            if error is AppleAuthError || error is AppleLoginError { metadataStopped = true; return }
            metadataFailures += 1
            if metadataFailures >= 3 { metadataStopped = true }
        }
    }

    @ViewBuilder private var macSection: some View {
        Section {
            Text(MacPackageDecryptor.isAvailable
                 ? "下载完成后可导出到 Mac 安装。"
                 : "仅支持下载未加密的 Mac 安装包。")
                .font(.footnote).foregroundStyle(.secondary)
            if macLoading { HStack { ProgressView(); Text("正在查找开发者安装包…").font(.subheadline).foregroundStyle(.secondary) } }
            ForEach(macInstallers) { installer in
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installer.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text("来自开发者网站 · " + installer.format.uppercased()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    RowCapsule(title: "下载") { enqueueMacInstaller(installer) }
                        .accessibilityIdentifier("mac.download." + installer.format)
                }
            }
            Button("通过链接下载", systemImage: "link") { enteringMacDownloadURL = true }
                .accessibilityIdentifier("mac.manual-download")
            if let website = macWebsite {
                Link(destination: website) { Label("开发者网站", systemImage: "safari") }
            }
        } header: { sectionTitle("Mac 安装包") }
    }

    private func copy(_ text: String) { UIPasteboard.general.string = text; store.infoMessage = "已复制到剪贴板"; UX.feedback() }
    /// Returns whether the list was loaded. The previous list stays visible
    /// until the new one arrives.
    @discardableResult
    private func fetchVersions(force: Bool) async -> Bool {
        versionsLoading = true; versionError = nil
        defer { versionsLoading = false }
        do {
            var result: [AppVersion]
            do {
                result = try await store.loadVersions(for: app, force: force, official: usesApple)
                versionNote = nil
            } catch is AppleLicenseError {
                // Not got by this account yet: show what is public, and say why.
                result = try await store.loadVersions(for: app, force: force, official: false)
                versionNote = "此账号还没有获取这个应用，下面是公开的版本资料。获取后可查看完整列表。"
            }
            try Task.checkCancellation(); versions = result
            if force { metadataStopped = false; metadataFailures = 0 }
            let cached = await store.cachedVersionMetadata(app: app, versionIDs: result.map(\.id))
            metadata.merge(cached) { current, _ in current }
            return true
        } catch is CancellationError { }
        catch AppleAuthError.reauthenticationRequired {
            if !Task.isCancelled {
                reauthenticationID = apple.activeID
                retryVersionsAfterVerification = false
                showLogin = true
            }
        }
        catch AppleLoginError.verificationRequired {
            if !Task.isCancelled {
                retryVersionsAfterVerification = true
                showVerification = true
            }
        }
        catch {
            if !Task.isCancelled {
                let message = error.localizedDescription
                versionError = message.contains("暂时无法获取历史版本") || error is AppleLicenseError
                    ? message : AppErrorMessage.forSearch(error)
            }
        }
        return false
    }
    private func downloadAppleMacPKG(versionID: String? = nil) {
        guard !macOfficialLoading else { return }
        guard apple.active != nil else {
            showLogin = true
            return
        }
        macOfficialLoading = true
        macOfficialTask = Task {
            defer { macOfficialLoading = false; macOfficialTask = nil }
            do {
                let offer = try await apple.macPackageOffer(app, versionID: versionID, useCache: store.settings.useSignerCache)
                try Task.checkCancellation()
                try store.downloads.enqueueOfficialMacPackage(offer, for: app)
                store.infoMessage = "已开始下载"
                store.tab = 1
                reloadIfLicenseWasMissing()
            } catch AppleAuthError.reauthenticationRequired {
                reauthenticationID = apple.activeID
                showLogin = true
            } catch AppleLoginError.verificationRequired {
                store.errorMessage = "请在「账号」中重新验证 Apple 账号后重试。"
            } catch is CancellationError { }
            catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    /// A download claims a free app's license, so a list that failed for
    /// lack of one can load now.
    private func reloadIfLicenseWasMissing() {
        if versionNote != nil || versionError == AppleLicenseError.notOwned.errorDescription { reloadID += 1 }
    }

    private func enqueueMacInstaller(_ installer: MacInstallerService.Installer) {
        do {
            try store.downloads.enqueueMacInstaller(installer.url, for: app)
            store.tab = 1
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func loadMacInstallers() async {
        guard store.settings.store.platform == .macOS else { return }
        macLoading = true
        macInstallers = []
        defer { macLoading = false }
        var website = app.developerURL
        if website == nil, app.id.allSatisfy({ $0.isNumber }) {
            let query = SearchQuery.appID(app.id, versionID: nil)
            if let matches = try? await StoreService.search(query, store: store.settings.store, limit: 1) {
                website = matches.first(where: { $0.id == app.id })?.developerURL
            }
        }
        guard !Task.isCancelled else { return }
        macWebsite = website
        if let website, let installers = try? await MacInstallerService.find(on: website),
           !Task.isCancelled {
            macInstallers = installers
        }
    }

    private func download(versionID: String?) {
        guard !downloadLoading else { return }
        if let versionID, !versionID.isEmpty, !versionID.allSatisfy({ $0.isASCII && $0.isNumber }) { store.errorMessage = "版本 ID 只能包含数字"; return }
        guard store.settings.store.platform.supportsIPA else {
            downloadAppleMacPKG(versionID: versionID?.isEmpty == true ? nil : versionID)
            return
        }
        guard apple.active != nil else { showLogin = true; return }
        downloadLoading = true
        downloadTask = Task {
            defer { downloadLoading = false; downloadTask = nil }
            do {
                try await store.startDownload(app: app, versionID: versionID?.isEmpty == true ? nil : versionID)
                reloadIfLicenseWasMissing()
            }
            catch AppleLoginError.verificationRequired {
                pendingDownloadVersion = versionID ?? ""
                retryVersionsAfterVerification = false
                showVerification = true
            }
            catch AppleAuthError.reauthenticationRequired {
                reauthenticationID = apple.activeID
                retryAfterLoginVersion = versionID ?? ""
                showLogin = true
            }
            catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

/// App Store style preview strip: screenshots side by side on the page
/// background, snapping to the leading margin, with the next one peeking in.
private struct ScreenshotStrip: View {
    let screenshots: [StoreService.Screenshot]
    let platform: AppPlatform
    var open: (StoreService.Screenshot) -> Void
    /// Loaded images. The size in a screenshot link is only the box Apple
    /// fits the image into, so a landscape game shot can arrive under a
    /// portrait-looking link: lay each one out by the real image.
    @State private var images: [URL: UIImage] = [:]
    private func aspect(_ shot: StoreService.Screenshot) -> Double {
        guard let image = images[shot.url], image.size.height > 0 else { return shot.aspect }
        return image.size.width / image.size.height
    }
    private var ready: Bool { screenshots.allSatisfy { images[$0.url] != nil } || !failed.isEmpty }
    @State private var failed = Set<URL>()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(screenshots) { shot in
                        let ratio = aspect(shot)
                        let portrait = ratio < 1
                        Button { open(shot) } label: {
                            ScreenshotTile(image: images[shot.url], failed: failed.contains(shot.url),
                                           cornerRadius: portrait ? 22 : 14)
                                .aspectRatio(ratio, contentMode: .fit)
                                // Portrait: a bit over half the width; landscape: nearly all of it.
                                .containerRelativeFrame(.horizontal) { length, _ in portrait ? length * 0.62 : length * 0.9 }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("截图")
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .opacity(ready ? 1 : 0.001)
            .overlay { if !ready { ProgressView() } }
            Label(platform.title == "iOS" ? "iPhone" : platform.title == "tvOS" ? "Apple TV" : platform.title, systemImage: platform.symbol)
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
        .animation(.easeOut(duration: 0.2), value: ready)
        .task(id: screenshots.map(\.url)) { await load() }
        .accessibilityIdentifier("detail.screenshots")
    }

    private func load() async {
        await withTaskGroup(of: (URL, UIImage?).self) { group in
            for shot in screenshots where images[shot.url] == nil {
                group.addTask {
                    guard let (data, _) = try? await URLSession.shared.data(from: shot.url) else { return (shot.url, nil) }
                    return (shot.url, UIImage(data: data))
                }
            }
            for await (url, image) in group {
                if let image { images[url] = image } else { failed.insert(url) }
            }
        }
    }
}

private struct ScreenshotTile: View {
    let image: UIImage?
    let failed: Bool
    var cornerRadius: CGFloat
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
                    .overlay { if failed { Image(systemName: "photo").foregroundStyle(.tertiary) } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// Full-screen screenshots, swiped through like Photos.
private struct ScreenshotViewer: View {
    let screenshots: [StoreService.Screenshot]
    @State var selection: StoreService.Screenshot
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(screenshots) { shot in
                    AsyncImage(url: shot.url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else { ProgressView().tint(.white) }
                    }
                    .padding(.horizontal, 12)
                    .tag(shot)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: screenshots.count > 1 ? .always : .never))
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(.ultraThinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("关闭")
        }
        .statusBarHidden()
    }
}

/// Small cards for the developer's other apps, opening their own pages.
private struct DeveloperAppsStrip: View {
    let apps: [StoreApp]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(apps) { app in
                    NavigationLink { AppDetailView(app: app) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            AppIcon(url: app.iconURL, size: 76)
                            Text(app.name).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            if !app.displayCategory.isEmpty {
                                Text(app.displayCategory).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(width: 84, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
        .accessibilityIdentifier("detail.developer-apps")
    }
}
