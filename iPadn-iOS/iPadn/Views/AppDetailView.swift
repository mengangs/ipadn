import SwiftUI
import UIKit

struct AppDetailView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    let app: StoreApp
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
    @State private var enteringMacDownloadURL = false
    @State private var macDownloadURL = ""
    private var storeURL: URL { URL(string: "https://apps.apple.com/\(store.settings.store.country.lowercased())/app/id\(app.id)")! }
    private var filtered: [AppVersion] {
        versionSearch.isEmpty ? versions : versions.filter { $0.version.localizedCaseInsensitiveContains(versionSearch) || $0.id.contains(versionSearch) }
    }
    @ViewBuilder private var appMetadata: some View {
        if app.size > 0 { Text(app.size.byteLabel) }
        if app.rating > 0 { Label(String(format: "%.1f", app.rating), systemImage: "star") }
        if !app.minimumOS.isEmpty { Text("\(store.settings.store.platform.title) \(app.minimumOS)+") }
    }
    var body: some View {
        List {
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) { AppIcon(url: app.iconURL, size: 64); appHeading }
                    VStack(alignment: .leading, spacing: 16) { AppIcon(url: app.iconURL, size: 64); appHeading }
                }.padding(.vertical, 6)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { appMetadata }
                    VStack(alignment: .leading, spacing: 6) { appMetadata }
                }.font(.footnote).foregroundStyle(.secondary)
            }.listRowSeparator(.hidden)
            if store.settings.store.platform.supportsIPA {
            Section {
                Toggle("从 Apple 获取版本", isOn: $official).font(.subheadline)
                    .disabled(apple.active == nil || store.settings.store.platform == .tvOS)
                if apple.active == nil {
                    Button("登录后查询 Apple 版本", systemImage: "person.crop.circle") { showLogin = true }
                }
                if versionsLoading { HStack { ProgressView(); Text("正在查找历史版本…").foregroundStyle(.secondary) } }
                if let versionError { InlineIssue(message: versionError) { reloadID += 1 } }
                if !versions.isEmpty {
                    SearchInput(text: $versionSearch, placeholder: "筛选版本号或版本 ID")
                    ForEach(filtered.prefix(100)) { version in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(version.version).font(.headline)
                                Text(version.source).font(.caption).foregroundStyle(.secondary)
                                Text(version.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            Button { download(versionID: version.id) } label: { Image(systemName: "arrow.down.circle.fill").font(.title2).frame(width: 48, height: 48) }
                                .buttonStyle(.borderless).disabled(downloadLoading).accessibilityLabel("下载版本 \(version.version)")
                        }.padding(.vertical, 6)
                            .contextMenu { Button("复制版本 ID") { copy(version.id) } }
                    }
                    if filtered.isEmpty { Text("没有匹配版本，请修改筛选条件。").font(.subheadline).foregroundStyle(.secondary) }
                    if filtered.count > 100 { Text("已显示前 100 项，输入版本号可继续查找。").font(.caption).foregroundStyle(.secondary) }
                } else if !versionsLoading && versionError == nil {
                    Text("暂无历史版本，可刷新或手动输入版本 ID。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                DisclosureGroup("手动指定版本") {
                    TextField("内部版本 ID（数字）", text: $manualID).keyboardType(.numberPad)
                    Button("下载此版本", systemImage: "arrow.down.circle") { download(versionID: manualID) }
                        .disabled(manualID.isEmpty || downloadLoading)
                }
            } header: {
                HStack { Text("历史版本 · \(versions.count)"); Spacer(); Button("刷新") { reloadID += 1 }.disabled(versionsLoading).textCase(nil) }
            } footer: { Text("版本可用性取决于商店地区及账号许可。") }
            } else {
                Section("Mac 安装包") {
                    if macLoading { ProgressView("查找开发者安装包…") }
                    ForEach(macInstallers) { installer in
                        Button {
                            enqueueMacInstaller(installer)
                        } label: {
                            HStack {
                                Label(installer.format.uppercased() + " · " + installer.title, systemImage: "arrow.down.to.line")
                                    .lineLimit(2)
                                Spacer()
                            }.frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("mac.download." + installer.format)
                    }
                    Button("通过链接下载 DMG / PKG / ZIP", systemImage: "link") {
                        enteringMacDownloadURL = true
                    }
                    .accessibilityIdentifier("mac.manual-download")
                    if let website = macWebsite {
                        Link("开发者网站", destination: website)
                    }
                }
            }
            Section("应用信息") {
                Button { copy(app.id) } label: {
                    HStack {
                        Text("App ID").foregroundStyle(.primary)
                        Spacer()
                        Text(app.id).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("App ID \(app.id)，点按复制")
                .accessibilityIdentifier("app.copy-id")
                if !app.bundleID.isEmpty { Text(app.bundleID).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if store.settings.store.platform != .macOS {
                    Link(destination: storeURL) { Label("在 App Store 查看", systemImage: "arrow.up.right.square") }
                }
            }
            if !app.description.isEmpty {
                Section("应用介绍") {
                    Text(app.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(showDescription ? nil : 5).textSelection(.enabled)
                    Button(showDescription ? "收起介绍" : "展开介绍") { showDescription.toggle() }
                }
            }
        }
        .toolPage().navigationTitle("应用详情").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if store.settings.store.platform.supportsIPA {
                Button { download(versionID: app.externalVersionID) } label: {
                    HStack(spacing: 10) {
                        if downloadLoading { ProgressView().tint(UX.onAccent) }
                        Label(downloadLoading ? "正在准备下载…" : apple.active == nil ? "登录后下载" : "下载当前版本", systemImage: apple.active == nil ? "person.crop.circle" : "arrow.down.circle.fill")
                    }.font(.headline).frame(maxWidth: .infinity).frame(minHeight: 44)
                }.buttonStyle(MonochromeButtonStyle()).controlSize(.large).disabled(downloadLoading)
                if downloadLoading { Button("取消准备下载") { downloadTask?.cancel() }.frame(minHeight: 44) }
                Text(apple.active.map { "使用账号 \($0.id)" } ?? "登录后获取你拥有许可的应用")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    if let installer = macInstallers.first {
                        Button {
                            enqueueMacInstaller(installer)
                        } label: {
                            Label("下载 Mac " + installer.format.uppercased(), systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(MonochromeButtonStyle())
                    } else {
                        Button { enteringMacDownloadURL = true } label: {
                            Label("通过链接下载 Mac 安装包", systemImage: "link")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(MonochromeButtonStyle())
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 680).frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .toolbar {
            Button { store.toggleFavorite(app); UX.feedback() } label: { Image(systemName: store.isFavorite(app) ? "star.fill" : "star").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel(store.isFavorite(app) ? "取消收藏" : "收藏应用")
            ShareLink(item: storeURL) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享商店链接")
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
        .onDisappear { downloadTask?.cancel() }
        .task(id: "\(official)-\(reloadID)-\(store.settings.store.country)-\(store.settings.store.platform.rawValue)-\(apple.activeID ?? "")") { await fetchVersions(force: reloadID > 0) }
        .task(id: "\(app.id)-\(store.settings.store.platform.rawValue)-\(store.settings.store.country)") {
            await loadMacInstallers()
        }
    }
    private var appHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app.name.isEmpty ? app.bundleID : app.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            if !app.category.isEmpty { Text(app.category).font(.subheadline).foregroundStyle(.secondary) }
            Text(app.version.isEmpty ? "版本待查询" : "v\(app.version)").font(.subheadline.monospacedDigit()).foregroundStyle(.tint)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        catch { if !Task.isCancelled { versionError = AppErrorMessage.forSearch(error) } }
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
