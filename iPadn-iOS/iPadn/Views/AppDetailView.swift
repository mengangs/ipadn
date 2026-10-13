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
    @State private var official = false
    @State private var showLogin = false
    @State private var reauthenticationID: String?
    @State private var retryAfterLoginVersion: String?
    @State private var showVerification = false
    @State private var pendingDownloadVersion: String?
    @State private var retryVersionsAfterVerification = false
    @State private var verifiedForRetry = false
    @State private var showDescription = false
    @State private var reloadID = 0
    @State private var macWebsite: URL?
    @State private var macInstallers: [MacInstallerService.Installer] = []
    @State private var macLoading = false
    @State private var macOfficialLoading = false
    @State private var macOfficialTask: Task<Void, Never>?
    @State private var enteringMacDownloadURL = false
    @State private var macDownloadURL = ""
    @State private var headerAway = false
    /// Listing artwork, else what a download of this app brought along
    /// (delisted apps have no public listing to show).
    private var iconURL: URL? { app.iconURL ?? store.localArtwork(app.id) }
    private var storeURL: URL { URL(string: "https://apps.apple.com/\(store.settings.store.country.lowercased())/app/id\(app.id)")! }
    private var filtered: [AppVersion] {
        versionSearch.isEmpty ? versions : versions.filter { $0.version.localizedCaseInsensitiveContains(versionSearch) || $0.id.contains(versionSearch) }
    }
    var body: some View {
        List {
            Section {
                header.listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .onScrolledUnderBar { headerAway = $0 }
                infoStrip.listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
            }
            if store.settings.store.platform.supportsIPA { versionSection } else { macSection }
            if !app.description.isEmpty {
                Section {
                    Text(app.description).font(.subheadline).lineLimit(showDescription ? nil : 4).textSelection(.enabled)
                    if !showDescription {
                        Button("更多") { withAnimation { showDescription = true } }.font(.subheadline)
                    }
                } header: { sectionTitle("简介") }
            }
            Section {
                if !app.category.isEmpty { LabeledContent("类别", value: app.category) }
                if app.size > 0 { LabeledContent("大小", value: app.size.byteLabel) }
                if !app.minimumOS.isEmpty {
                    LabeledContent("兼容性", value: "\(store.settings.store.platform.title) \(app.minimumOS) 或更高版本")
                }
                if !app.price.isEmpty { LabeledContent("价格", value: app.price) }
                if !app.bundleID.isEmpty {
                    LabeledContent("Bundle ID") {
                        Text(app.bundleID).font(.footnote.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
                if store.settings.store.platform != .macOS {
                    Link(destination: storeURL) { Label("在 App Store 中查看", systemImage: "arrow.up.right.square") }
                }
            } header: { sectionTitle("信息") }
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
                    Image(systemName: store.isFavorite(app) ? "star.fill" : "star").frame(minWidth: 44, minHeight: 44)
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
            Text("粘贴开发者提供的安装包直链。下载后可通过下载页导出到 Mac。")
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
        .task(id: "\(official)-\(reloadID)-\(store.settings.store.country)-\(store.settings.store.platform.rawValue)-\(apple.activeID ?? "")") { await fetchVersions(force: reloadID > 0) }
        .task(id: "\(app.id)-\(store.settings.store.platform.rawValue)-\(store.settings.store.country)") {
            await loadMacInstallers()
        }
    }
    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
    }

    /// App Store product header: big icon, name, subtitle and the primary capsule.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(url: iconURL, size: 118)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name.isEmpty ? app.bundleID : app.name).font(.title3.weight(.bold))
                    .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                if !app.category.isEmpty { Text(app.category).font(.subheadline).foregroundStyle(.secondary) }
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
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
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

    /// Horizontal info strip under the header, as on App Store product pages.
    private var infoStrip: some View {
        let items = stripItems
        // Spread the cells across the row when they fit; scroll otherwise.
        return ViewThatFits(in: .horizontal) {
            stripRow(items, stretch: true).padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                stripRow(items, stretch: false).padding(.horizontal, 12)
            }
        }
    }

    private func stripRow(_ items: [InfoStripItem], stretch: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                items[index].frame(maxWidth: stretch ? .infinity : nil)
                if index < items.count - 1 { Divider().frame(height: 36) }
            }
        }
    }

    private var stripItems: [InfoStripItem] {
        var items: [InfoStripItem] = []
        if app.rating > 0 { items.append(InfoStripItem(caption: "评分", value: String(format: "%.1f", app.rating), detail: String(repeating: "★", count: max(0, min(5, Int(app.rating.rounded())))))) }
        if app.size > 0 { items.append(InfoStripItem(caption: "大小", value: app.size.byteLabel.components(separatedBy: " ").first ?? app.size.byteLabel, detail: app.size.byteLabel.components(separatedBy: " ").last)) }
        items.append(InfoStripItem(caption: "平台", value: store.settings.store.platform.title, symbol: store.settings.store.platform.symbol))
        if !app.minimumOS.isEmpty { items.append(InfoStripItem(caption: "系统要求", value: app.minimumOS + "+", detail: store.settings.store.platform.title)) }
        if !app.category.isEmpty { items.append(InfoStripItem(caption: "类别", value: app.category, symbol: "square.grid.2x2")) }
        items.append(InfoStripItem(caption: "地区", value: store.settings.store.country, detail: "商店"))
        return items
    }

    @ViewBuilder private var versionSection: some View {
        Section {
            Toggle("从 Apple 获取版本列表", isOn: $official).font(.subheadline)
                .disabled(apple.active == nil || store.settings.store.platform == .tvOS)
            if versionsLoading { HStack { ProgressView(); Text("正在查找历史版本…").font(.subheadline).foregroundStyle(.secondary) } }
            if let versionError { InlineIssue(message: versionError) { reloadID += 1 } }
            if versions.count > 6 {
                SearchInput(text: $versionSearch, placeholder: "筛选版本号或版本 ID")
            }
            ForEach(filtered.prefix(100)) { version in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("版本 \(version.version)").font(.body.weight(.medium))
                        Text("\(version.id) · \(version.source)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    RowCapsule(title: "下载", enabled: !downloadLoading) { download(versionID: version.id) }
                        .accessibilityLabel("下载版本 \(version.version)")
                }
                .padding(.vertical, 2)
                .contextMenu { Button("复制版本 ID", systemImage: "doc.on.doc") { copy(version.id) } }
            }
            if !versions.isEmpty && filtered.isEmpty { Text("没有匹配的版本。").font(.subheadline).foregroundStyle(.secondary) }
            if filtered.count > 100 { Text("已显示前 100 个版本，输入版本号可继续查找。").font(.caption).foregroundStyle(.secondary) }
            if versions.isEmpty && !versionsLoading && versionError == nil {
                Text("暂无历史版本，可刷新或手动输入版本 ID。").font(.subheadline).foregroundStyle(.secondary)
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
        } footer: { Text("版本可用性取决于商店地区与账号许可。") }
    }

    @ViewBuilder private var macSection: some View {
        Section {
            Text(MacPackageDecryptor.isAvailable
                 ? "使用当前 Apple 账号的购买授权下载，在本机完成 Apple 安装包处理并校验后可导出到 Mac。首次处理需从 Apple 下载约 47 MB 组件，处理大型安装包耗时较长。"
                 : "此版本未包含 Mac 安装包处理组件，只能保存 Apple 直接提供的未加密 PKG。")
                .font(.footnote).foregroundStyle(.secondary)
            if macLoading { HStack { ProgressView(); Text("正在查找开发者安装包…").font(.subheadline).foregroundStyle(.secondary) } }
            ForEach(macInstallers) { installer in
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installer.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text("开发者官网 · " + installer.format.uppercased()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    RowCapsule(title: "下载") { enqueueMacInstaller(installer) }
                        .accessibilityIdentifier("mac.download." + installer.format)
                }
            }
            Button("通过链接下载 DMG / PKG / ZIP", systemImage: "link") { enteringMacDownloadURL = true }
                .accessibilityIdentifier("mac.manual-download")
            if let website = macWebsite {
                Link(destination: website) { Label("开发者网站", systemImage: "safari") }
            }
        } header: { sectionTitle("Mac 安装包") }
    }

    private func copy(_ text: String) { UIPasteboard.general.string = text; store.infoMessage = "已复制到剪贴板"; UX.feedback() }
    private func fetchVersions(force: Bool) async {
        versionsLoading = true; versionError = nil; versions = []
        defer { if !Task.isCancelled { versionsLoading = false } }
        do {
            let result = try await store.loadVersions(for: app, force: force, official: official)
            try Task.checkCancellation(); versions = result
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
                versionError = message.contains("历史版本来源暂不可用") ? message : AppErrorMessage.forSearch(error)
            }
        }
    }
    private func downloadAppleMacPKG() {
        guard !macOfficialLoading else { return }
        guard apple.active != nil else {
            showLogin = true
            return
        }
        macOfficialLoading = true
        macOfficialTask = Task {
            defer { macOfficialLoading = false; macOfficialTask = nil }
            do {
                let offer = try await apple.macPackageOffer(app, useCache: store.settings.useSignerCache)
                try Task.checkCancellation()
                try store.downloads.enqueueOfficialMacPackage(offer, for: app)
                store.infoMessage = offer.protectedByApple
                    ? "Mac PKG 已加入下载任务。下载后会在本机处理并校验，完成后可导出。"
                    : "Mac PKG 已加入下载任务，完成校验后可导出。"
                store.tab = 1
            } catch AppleAuthError.reauthenticationRequired {
                reauthenticationID = apple.activeID
                showLogin = true
            } catch AppleLoginError.verificationRequired {
                store.errorMessage = "Apple 账号需要重新验证，请在账号页完成验证后重试。"
            } catch is CancellationError { }
            catch {
                store.errorMessage = error.localizedDescription
            }
        }
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
        guard store.settings.store.platform.supportsIPA else {
            store.errorMessage = "原生 Mac 应用需要在 Mac App Store 下载，不能导出为 IPA"
            return
        }
        guard apple.active != nil else { showLogin = true; return }
        if let versionID, !versionID.isEmpty, !versionID.allSatisfy({ $0.isASCII && $0.isNumber }) { store.errorMessage = "版本 ID 必须是数字"; return }
        downloadLoading = true
        downloadTask = Task {
            defer { downloadLoading = false; downloadTask = nil }
            do { try await store.startDownload(app: app, versionID: versionID?.isEmpty == true ? nil : versionID) }
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
