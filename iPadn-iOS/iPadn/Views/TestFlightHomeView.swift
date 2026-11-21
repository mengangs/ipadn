import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(TestFlightKit)
import TestFlightKit

/// One catalog row's download state. Everything the row renders is derived from here, so
/// the view stays declarative and no byte-level progress reaches SwiftUI.
struct TFRowState: Equatable {
    enum Stage: Equatable {
        case idle, resolving, installing, downloading, verifying, done, failed
    }

    var stage: Stage = .idle
    var received: Int64 = 0
    var total: Int64 = 0
    var message: String?
    var output: URL?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(received) / Double(total))
    }

    var isBusy: Bool {
        switch stage {
        case .resolving, .installing, .downloading, .verifying: return true
        default: return false
        }
    }
}

/// Official TestFlight Store-styled page inside iPadn.
///
/// The only entry point is the single row on the account page (`AccountRoute.testFlight`).
/// Accounts, Downloads, and Decrypt pages stay untouched; all protocol invariants stay in
/// `TestFlightKit`, and all installs go through `InstallCoordinator.shared`.
struct TestFlightHomeView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.scenePhase) private var scenePhase
    /// Process-wide model so popping back and re-entering TestFlight is 0ms instant with
    /// zero redundant reload and uninterrupted background downloads.
    @ObservedObject private var model = TFHomeModel.shared

    @State private var searchText = ""
    @State private var showingAccountSheet = false
    @State private var showingDiagnostics = false
    @State private var installingApp: TFBetaApp?
    @State private var pendingSwitchTarget: SwitchTarget?
    @State private var capabilityRefreshTick = 0
    @State private var copiedDirectDomains = false
    @State private var expandIncompatible = true
    @State private var expandPreviouslyTested = true

    private enum SwitchTarget: Equatable {
        case account(TFAccountIdentity)
        case custom
    }

    private var accountStore: TFAccountStore { TFAccountStore(apple: apple) }

    private var selectedAppleAccount: AppleAccount? {
        accountStore.account(for: model.email)
    }

    private var filteredApps: [TFBetaApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.apps }
        return model.apps.filter { app in
            if app.name.localizedCaseInsensitiveContains(query) { return true }
            if app.bundleID.localizedCaseInsensitiveContains(query) { return true }
            if let detail = model.details[app.id] {
                if detail.name.localizedCaseInsensitiveContains(query)
                    || detail.developerName.localizedCaseInsensitiveContains(query)
                    || detail.bundleID.localizedCaseInsensitiveContains(query) {
                    return true
                }
            }
            return false
        }
    }

    private var showsAvatarBadge: Bool {
        model.dsidConflict || model.hasNetworkWarning || model.pageState == .sessionExpired
    }

    var body: some View {
        List {
            if model.dsidConflict {
                Section {
                    InlineIssue(message: AppText.text("检测到账号标识与商店记录不一致，本次 TestFlight 会话已隔离运行，原有账号记录未修改。"))
                }
            }

            if let externalEmail = model.externalActiveSwitchEmail {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.circle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("活跃账号已变更")
                                .font(.subheadline.weight(.semibold))
                            Text(verbatim: TFHomeModel.mask(externalEmail))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("切换账号") {
                            let targetKey = AppleAccount.normalizedIdentifier(externalEmail)
                            if let target = accountStore.accounts.first(where: { AppleAccount.normalizedIdentifier($0.email) == targetKey }) {
                                requestAccountSwitch(.account(target))
                            }
                        }
                        .buttonStyle(CapsuleButtonStyle(filled: false))
                    }
                    .padding(.vertical, 2)
                }
            }

            if model.pageState == .networkBlocked, let diagnosis = model.networkDiagnosis {
                networkBlockedSection(diagnosis)
            }

            if model.pageState == .sessionExpired {
                Section {
                    InlineIssue(message: AppText.text("TestFlight 会话已过期，请重新验证。已下载的本地安装包仍可安装或分享。")) {
                        model.start(storeAccountDsid: selectedAppleAccount?.dsid ?? "")
                    }
                }
            }

            if case let .authFailed(message, failureKind) = model.pageState {
                authFailedSection(message: message, kind: failureKind)
            }

            switch model.pageState {
            case .noAccount:
                noAccountSection
            case .customSignIn:
                customSignInSection
            case .readyToSignIn:
                if !model.apps.isEmpty {
                    catalogSection
                } else {
                    readyCompactSection
                }
            case .authFailed, .networkBlocked:
                if !model.apps.isEmpty {
                    catalogSection
                } else if model.isUsingCustomSignIn {
                    customSignInSection
                }
            case let .authenticating(stageText):
                authenticatingSection(stageText)
            case .catalogReady, .catalogEmpty, .sessionExpired:
                if model.apps.isEmpty {
                    emptyCatalogSection
                } else {
                    catalogSection
                }
            }
        }
        .toolPage()
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 56)
        }
        .navigationTitle("TestFlight")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "搜索")
        .refreshable {
            await model.refreshCatalog(force: true)
        }
        .toolbar {
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                if model.phase == .working {
                    Button("取消") {
                        model.cancelSignIn()
                    }
                    .accessibilityLabel(Text("取消"))
                } else {
                    avatarToolbarButton
                }
            }
        }
        .sheet(isPresented: $showingAccountSheet) {
            TFAccountSheet(
                model: model,
                accountStore: accountStore,
                selectedAppleAccount: selectedAppleAccount,
                onSelectAccount: { identity in
                    requestAccountSwitch(.account(identity))
                },
                onSelectCustomAccount: {
                    requestAccountSwitch(.custom)
                },
                onOpenLogin: {
                    store.accountNav.push(.login)
                },
                onOpenInstallSettings: {
                    store.accountNav.push(.installation)
                }
            )
        }
        .sheet(isPresented: $model.needsCode, onDismiss: {
            if model.phase == .working && !model.isSubmittingCode {
                model.cancelSignIn()
            }
        }) {
            TFVerificationSheet(
                accountDisplay: TFHomeModel.mask(model.email),
                code: $model.code,
                isSubmitting: model.isSubmittingCode,
                onSubmit: { model.submitCode() },
                onCancel: { model.cancelSignIn() }
            )
        }
        .sheet(isPresented: $showingDiagnostics) {
            TFDiagnosticsSheet(model: model)
        }
        .sheet(item: $installingApp) { app in
            if let packageURL = model.productURL(for: app) {
                TFInstallSheet(
                    app: app,
                    packageURL: packageURL,
                    iconURL: model.iconFiles[app.id],
                    iconColors: model.iconColors[app.id],
                    iconRevision: model.iconRevisions[app.id] ?? 0,
                    installation: store.installation,
                    isInstalling: model.installingAppIDs.contains(app.id),
                    isInstalled: model.installedAppIDs.contains(app.id),
                    installNote: model.installNotes[app.id],
                    installFailed: model.installFailedAppIDs.contains(app.id),
                    needsChannelGuide: model.installNeedsChannelAppIDs.contains(app.id),
                    onInstall: { method in
                        model.install(app, method: method, installation: store.installation)
                    },
                    onDelete: {
                        store.removeTFProductWithUndo(for: app)
                        installingApp = nil
                    },
                    onOpenSettings: {
                        store.accountNav.push(.installation)
                    }
                )
            }
        }
        .confirmationDialog("切换账号将取消正在进行的下载？",
                            isPresented: Binding(get: { pendingSwitchTarget != nil },
                                                 set: { if !$0 { pendingSwitchTarget = nil } }),
                            titleVisibility: .visible) {
            Button("取消下载并切换", role: .destructive) {
                if let target = pendingSwitchTarget {
                    pendingSwitchTarget = nil
                    applyAccountSwitch(target)
                }
            }
            Button("取消", role: .cancel) {
                pendingSwitchTarget = nil
            }
        } message: {
            Text("当前有下载任务尚未完成，切换账号会中止任务并清理临时文件。")
        }
        .task {
            model.bootstrapIfNeeded(using: accountStore)
        }
        .compatibleOnChange(of: apple.activeID) { newActiveID in
            model.handleExternalActiveAccountChange(newActiveID: newActiveID, accountStore: accountStore)
        }
        .compatibleOnChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                capabilityRefreshTick += 1
                model.invalidateProductCache()
            }
        }
        .onAppear {
            capabilityRefreshTick += 1
            model.handleExternalActiveAccountChange(newActiveID: apple.activeID, accountStore: accountStore)
        }
    }

    // MARK: - Top-Right Avatar (Tap: Account & Settings Sheet, Long-Press: Native Smooth Pull-Down Menu)

    private var avatarToolbarButton: some View {
        Menu {
            Section("切换账号") {
                ForEach(accountStore.accounts) { item in
                    let isCurrent = AppleAccount.normalizedIdentifier(item.email)
                        == AppleAccount.normalizedIdentifier(model.email)
                    Button {
                        requestAccountSwitch(.account(item))
                    } label: {
                        if isCurrent {
                            Label(item.label, systemImage: "checkmark")
                        } else {
                            Label(item.label, systemImage: "person.crop.circle")
                        }
                    }
                }
            }
            Divider()
            Button {
                showingAccountSheet = true
            } label: {
                Label("账号与设置", systemImage: "gearshape")
            }
            Button {
                store.accountNav.push(.installation)
            } label: {
                Label("安装设置", systemImage: "square.and.arrow.down")
            }
            Button {
                showingDiagnostics = true
            } label: {
                Label("网络与诊断", systemImage: "antenna.radiowaves.left.and.right")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                AccountAvatar(account: selectedAppleAccount, size: 32)
                if showsAvatarBadge {
                    Circle()
                        .fill(.orange)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
        } primaryAction: {
            showingAccountSheet = true
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text("账号与设置"))
        .accessibilityIdentifier("tf.toolbar.account")
    }

    // MARK: - Empty / Minimal Compact States (Login lives in Avatar Sheet)

    private var noAccountSection: some View {
        Section {
            EmptyState(
                title: "连接 TestFlight",
                message: "登录后可浏览当前 Apple 账号参与的测试版 App，并直接下载或安装。",
                symbol: "airplane",
                actionTitle: "登录 Apple 账户",
                action: { store.accountNav.push(.login) }
            )
            Button {
                model.enterCustomSignIn()
            } label: {
                Text("使用其他 Apple 账号临时登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
        }
    }

    private var readyCompactSection: some View {
        Section {
            EmptyState(
                title: "连接 TestFlight",
                message: "将复用当前 iPadn 账号凭据建立持久化会话，验证一次后无需重复登录。",
                symbol: "airplane",
                actionTitle: "验证并连接 TestFlight",
                action: { model.start(storeAccountDsid: selectedAppleAccount?.dsid ?? "") }
            )
        }
    }

    private var customSignInSection: some View {
        Section {
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    TextField("Apple 账号", text: $model.email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                    Divider().padding(.leading, 12)
                    SecureField("密码", text: $model.password)
                        .textContentType(.password)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                }
                .background(Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    model.start(storeAccountDsid: selectedAppleAccount?.dsid ?? "")
                } label: {
                    Text("登录并读取测试列表")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.phase == .working || model.email.trimmingCharacters(in: .whitespaces).isEmpty || model.password.isEmpty)
            }
            .padding(.vertical, 6)
        } footer: {
            Text("验证完成后会话将安全保存在钥匙串中，下次进入或切换账号自动恢复，无需重复登录。")
        }
    }

    // MARK: - Auth Failed (Clean User-Facing Cards; Raw Errors Stay in Diagnostic Log)

    private func authFailedSection(message: String, kind: TFHomeModel.AuthFailureKind) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: kind == .vpnOrProxy503 ? "network.slash" : "exclamationmark.circle")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(authFailureTitle(for: kind))
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if kind == .vpnOrProxy503 {
                    Text(verbatim: "gsa.apple.com · auth.itunes.apple.com · testflight.apple.com")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    if kind != .rateLimited {
                        Button("重试") {
                            model.start(storeAccountDsid: selectedAppleAccount?.dsid ?? "")
                        }
                        .buttonStyle(CapsuleButtonStyle(filled: true))
                    }

                    if kind == .vpnOrProxy503 {
                        Button(copiedDirectDomains ? "已复制域名" : "复制直连域名") {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = "gsa.apple.com\nauth.itunes.apple.com\ntestflight.apple.com"
                            #endif
                            copiedDirectDomains = true
                            UX.feedback()
                        }
                        .buttonStyle(CapsuleButtonStyle(filled: false))
                    }

                    Button("查看日志") {
                        showingDiagnostics = true
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: false))
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        }
    }

    private func authFailureTitle(for kind: TFHomeModel.AuthFailureKind) -> LocalizedStringKey {
        switch kind {
        case .vpnOrProxy503: return "无法连接 Apple 登录服务"
        case .rateLimited: return "登录请求暂时受限"
        case .standard: return "暂时无法完成验证"
        }
    }

    // MARK: - Loading / Authenticating Skeleton

    private func authenticatingSection(_ stageText: String) -> some View {
        Group {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: stageText)
                            .font(.subheadline.weight(.medium))
                        if !model.email.isEmpty {
                            Text(verbatim: TFHomeModel.mask(model.email))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(0..<3, id: \.self) { _ in
                    AppSkeleton()
                }
            } header: {
                Text("正在测试")
            }
        }
    }

    // MARK: - Network Blocked Degraded Banner (Clean Human Hint, Raw Facts in Diagnostics)

    private func networkBlockedSection(_ diagnosis: TFNetDiagnosis) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网络连接受阻")
                            .font(.subheadline.weight(.semibold))
                        Text("当前网络无法连接 Apple 服务，建议暂时关闭 VPN 或代理，或切换为强制直连后重试。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Button("切换为强制直连并重试") {
                        model.setNetworkMode(.direct)
                        model.start(storeAccountDsid: selectedAppleAccount?.dsid ?? "")
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))

                    Button("查看日志") {
                        showingDiagnostics = true
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: false))
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Empty Catalog

    private var emptyCatalogSection: some View {
        Section {
            EmptyState(
                title: "暂无可测试的 App",
                message: "当前 Apple 账号尚未加入任何 TestFlight 测试项目，可尝试刷新或长按右上角头像切换其他账号。",
                symbol: "airplane",
                actionTitle: "刷新",
                action: { Task { await model.refreshCatalog(force: true) } }
            )
        }
    }

    // MARK: - Official TF 3-Bucket Sections (正在测试 / 不兼容 / 以前测试过)

    @ViewBuilder
    private var catalogSection: some View {
        let visible = filteredApps
        if visible.isEmpty {
            Section {
                Text("未找到匹配的测试 App")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        } else {
            let partitioned: (testing: [TFBetaApp], incompatible: [TFBetaApp], previouslyTested: [TFBetaApp]) = {
                var testing: [TFBetaApp] = []
                var incompatible: [TFBetaApp] = []
                var previouslyTested: [TFBetaApp] = []
                for app in visible {
                    switch model.details[app.id]?.availability ?? .testing {
                    case .testing: testing.append(app)
                    case .incompatible: incompatible.append(app)
                    case .previouslyTested: previouslyTested.append(app)
                    }
                }
                return (testing, incompatible, previouslyTested)
            }()
            let testingApps = partitioned.testing
            let incompatibleApps = partitioned.incompatible
            let previouslyTestedApps = partitioned.previouslyTested
            if !testingApps.isEmpty {
                Section {
                    ForEach(testingApps) { app in
                        appRow(app, availability: .testing)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text("正在测试")
                        if model.isRestoringSilently || model.isRefreshingCatalog {
                            ProgressView().controlSize(.small)
                        }
                        if accountStore.accounts.count > 1,
                           let acct = selectedAppleAccount {
                            Spacer()
                            Text(verbatim: acct.name.isEmpty ? TFHomeModel.mask(acct.id) : acct.name)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .textCase(nil)
                        }
                    }
                } footer: {
                    if incompatibleApps.isEmpty && previouslyTestedApps.isEmpty {
                        Text("点按应用可查看测试内容与详情；长按右上角头像可快捷切换账号。")
                    }
                }
            }

            if !incompatibleApps.isEmpty {
                Section {
                    if expandIncompatible {
                        ForEach(incompatibleApps) { app in
                            appRow(app, availability: .incompatible)
                        }
                    }
                } header: {
                    collapsibleHeader(title: "不兼容", expanded: $expandIncompatible)
                }
            }

            if !previouslyTestedApps.isEmpty {
                Section {
                    if expandPreviouslyTested {
                        ForEach(previouslyTestedApps) { app in
                            appRow(app, availability: .previouslyTested)
                        }
                    }
                } header: {
                    collapsibleHeader(title: "以前测试过", expanded: $expandPreviouslyTested)
                } footer: {
                    Text("点按应用可查看详情；长按右上角头像可快捷切换账号。")
                }
            }
        }
    }

    private func collapsibleHeader(title: LocalizedStringKey, expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }

    private func appRow(_ app: TFBetaApp, availability: TFAppAvailability) -> some View {
        let state = model.rowState(app)
        let isInstalled = model.installedAppIDs.contains(app.id)
        let isInstalling = model.installingAppIDs.contains(app.id)
        return NavigationLink {
            TestFlightDetailView(app: app, model: model)
        } label: {
            HStack(spacing: 14) {
                TFAppIconView(
                    fileURL: model.iconFiles[app.id],
                    colors: model.iconColors[app.id] ?? model.details[app.id]?.iconAsset?.colors,
                    appName: model.details[app.id]?.name ?? app.name,
                    size: 60,
                    revision: model.iconRevisions[app.id] ?? 0
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.details[app.id]?.name ?? app.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if availability == .previouslyTested {
                        Text("已移除 Build")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if availability == .incompatible {
                        Text(verbatim: Self.officialSubtitle(app: app, detail: model.details[app.id]))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        rowSubtitleView(app: app, state: state, isInstalled: isInstalled, isInstalling: isInstalling)
                    }
                }

                Spacer(minLength: 8)

                if availability == .testing {
                    rowAccessory(app: app, state: state, isInstalled: isInstalled, isInstalling: isInstalling)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func rowSubtitleView(app: TFBetaApp, state: TFRowState, isInstalled: Bool, isInstalling: Bool) -> some View {
        let detail = model.details[app.id]
        switch state.stage {
        case .idle:
            twoLineOfficialMeta(app: app, detail: detail, isInstalled: false)
        case .resolving:
            Text("读取构建信息…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installing:
            Text("准备下载…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading:
            Text(verbatim: "\(byteText(state.received)) / \(byteText(state.total)) · \(Int(state.fraction * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .verifying:
            Text("校验安装包…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .done:
            VStack(alignment: .leading, spacing: 2) {
                twoLineOfficialMeta(app: app, detail: detail, isInstalled: isInstalled)
                if isInstalling, let note = model.installNotes[app.id] {
                    Text(verbatim: note)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                } else if model.installFailedAppIDs.contains(app.id), let note = model.installNotes[app.id] {
                    Text(verbatim: note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        case .failed:
            Text(verbatim: state.message ?? AppText.text("下载失败"))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func twoLineOfficialMeta(app: TFBetaApp, detail: TFAppDetail?, isInstalled: Bool) -> some View {
        let versionLine = Self.versionLine(app: app, detail: detail)
        let days = detail?.daysRemaining()
        VStack(alignment: .leading, spacing: 2) {
            if !versionLine.isEmpty {
                Text(verbatim: versionLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                if let days {
                    if days == 0 {
                        Text("已过期")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(AppText.text("剩余 \(days) 天"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(days <= 7 ? Color.orange : Color.secondary)
                    }
                } else if versionLine.isEmpty {
                    Text(verbatim: app.developerName ?? "TestFlight")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isInstalled {
                    TagBadge(text: "已安装", tint: .green)
                }
            }
        }
    }

    private static func versionLine(app: TFBetaApp, detail: TFAppDetail?) -> String {
        if let detail, !detail.versionSummary.isEmpty {
            if detail.buildVersion.count > 6, !detail.shortVersion.isEmpty {
                return "v\(detail.shortVersion)"
            }
            return "v\(detail.versionSummary)"
        }
        if let version = app.latestVersion, !version.isEmpty {
            return "v\(version)"
        }
        return ""
    }

    private static func officialSubtitle(app: TFBetaApp, detail: TFAppDetail?, compactBuild: Bool = false) -> String {
        var parts: [String] = []
        if let detail, !detail.versionSummary.isEmpty {
            if (compactBuild && detail.buildVersion.count > 4) || detail.buildVersion.count > 6,
               !detail.shortVersion.isEmpty {
                parts.append(detail.shortVersion)
            } else {
                parts.append(detail.versionSummary)
            }
        } else if let version = app.latestVersion, !version.isEmpty {
            parts.append("v\(version)")
        }
        if let days = detail?.daysRemaining() {
            if days == 0 {
                parts.append(AppText.text("已过期"))
            } else {
                parts.append(AppText.text("\(days) 天"))
            }
        } else if let dev = app.developerName, !dev.isEmpty, parts.isEmpty {
            parts.append(dev)
        }
        return parts.isEmpty ? "TestFlight" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func rowAccessory(app: TFBetaApp, state: TFRowState, isInstalled: Bool, isInstalling: Bool) -> some View {
        let _ = capabilityRefreshTick
        switch state.stage {
        case .idle:
            AppStoreActionButton(
                phase: .capsule(title: AppText.text("获取"), filled: false, enabled: model.isSignedIn),
                insideNavigationLink: true,
                accessibilityLabelText: AppText.text("下载 \(app.name)")
            ) {
                model.start(app)
            }
        case .resolving, .installing:
            AppStoreActionButton(
                phase: .loading,
                insideNavigationLink: true,
                accessibilityLabelText: AppText.text("取消下载 \(app.name)")
            ) {
                model.cancel(app)
            }
        case .downloading:
            AppStoreActionButton(
                phase: .downloading(state.fraction),
                insideNavigationLink: true,
                accessibilityLabelText: AppText.text("取消下载 \(app.name)"),
                accessibilityValueText: "\(Int(state.fraction * 100))%"
            ) {
                model.cancel(app)
            }
        case .verifying:
            AppStoreActionButton(
                phase: .processing,
                insideNavigationLink: true,
                accessibilityLabelText: AppText.text("正在校验 \(app.name)")
            ) {}
        case .done:
            if isInstalling {
                AppStoreActionButton(
                    phase: .processing,
                    insideNavigationLink: true,
                    accessibilityLabelText: AppText.text("正在安装 \(app.name)")
                ) {
                    installingApp = app
                }
            } else {
                AppStoreActionButton(
                    phase: .capsule(title: AppText.text("安装"), filled: !isInstalled, enabled: true),
                    insideNavigationLink: true,
                    accessibilityLabelText: AppText.text("安装 \(app.name)")
                ) {
                    installingApp = app
                }
            }
        case .failed:
            AppStoreActionButton(
                phase: .capsule(title: AppText.text("重试"), filled: false, enabled: model.isSignedIn),
                insideNavigationLink: true,
                accessibilityLabelText: AppText.text("重试下载 \(app.name)")
            ) {
                model.start(app)
            }
        }
    }

    // MARK: - Account Switching (Instant L3 -> L2 -> Controlled Auto-L1)

    private func requestAccountSwitch(_ target: SwitchTarget) {
        if model.hasActiveDownloads {
            pendingSwitchTarget = target
        } else {
            applyAccountSwitch(target)
        }
    }

    private func applyAccountSwitch(_ target: SwitchTarget) {
        copiedDirectDomains = false
        switch target {
        case let .account(identity):
            let account = accountStore.account(for: identity.email)
            model.switchToAccount(
                email: identity.email,
                password: account?.password ?? "",
                storeAccountDsid: account?.dsid ?? ""
            )
        case .custom:
            model.switchToAccount(email: "", password: "", storeAccountDsid: "", custom: true)
        }
        UX.feedback()
    }
}

extension URL {
    var fileSizeBytes: Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }
}

private enum TFByteFormatter {
    private static let lock = NSLock()
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB, .useKB]
        return f
    }()

    static func string(fromByteCount value: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(fromByteCount: max(0, value))
    }
}

/// Human byte text for progress and package size lines.
func byteText(_ value: Int64) -> String {
    TFByteFormatter.string(fromByteCount: value)
}

// MARK: - Shared Process-Wide ViewModel (Zero-Reload Navigation + L3 -> L2 -> Controlled L1)

@MainActor
final class TFHomeModel: ObservableObject {
    static let shared = TFHomeModel()

    enum Phase { case idle, working }

    enum AuthFailureKind: Equatable {
        case standard
        case rateLimited
        case vpnOrProxy503
    }

    enum PageState: Equatable {
        case noAccount
        case customSignIn
        case readyToSignIn
        case authenticating(String)
        case catalogReady
        case catalogEmpty
        case sessionExpired
        case networkBlocked
        case authFailed(String, AuthFailureKind)
    }

    @Published var email = ""
    @Published var password = ""
    @Published var code = ""
    @Published var phase: Phase = .idle
    @Published var pageState: PageState = .readyToSignIn
    @Published var needsCode = false
    @Published var isSubmittingCode = false
    @Published var isRefreshingCatalog = false
    @Published var isRestoringSilently = false
    @Published var lines: [String] = []
    @Published var apps: [TFBetaApp] = []
    @Published var details: [String: TFAppDetail] = [:]
    @Published var probe: TFGSAProbe?
    @Published var dsidTail = ""
    @Published var rows: [String: TFRowState] = [:]
    @Published var networkDiagnosis: TFNetDiagnosis?
    @Published var proxyBypassed = false
    @Published var dnsPathSummary = "-"
    @Published var iconFiles: [String: URL] = [:]
    @Published var iconColors: [String: TFIconColors] = [:]
    @Published var iconRevisions: [String: Int] = [:]
    @Published var installNotes: [String: String] = [:]
    @Published var installingAppIDs: Set<String> = []
    @Published var installedAppIDs: Set<String> = []
    @Published var installFailedAppIDs: Set<String> = []
    @Published var installNeedsChannelAppIDs: Set<String> = []
    @Published var dsidConflict = false
    @Published var externalActiveSwitchEmail: String?
    @Published var networkMode: TFNetworkMode = TFNet.mode
    @Published private(set) var isUsingCustomSignIn = false

    private var runs: [String: TFTransferHandle] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var downloadTokens: [String: UUID] = [:]
    private var detailTask: Task<Void, Never>?
    private var hydrateTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var accountEpoch = 0
    private var session: TFSession?
    private var context: TFContext?
    private var bootstrapped = false
    /// Tracks recent catalog sync per dsid so re-entering or toggling accounts within 5 min is 0ms.
    private var lastSyncedAt: [String: Date] = [:]
    /// Guards automatic first-time sign-in so each account tries at most ONCE per launch (anti-503).
    private var attemptedAutoSignInEmails: Set<String> = []
    private var productsCache: [String: String] = UserDefaults.standard.dictionary(forKey: "tf.products") as? [String: String] ?? [:]
    private var resolvedProductURLs: [String: URL] = [:]
    private var checkedProductBundles: Set<String> = []
    var accountSummary = ""

    private var relay: TFLogin.CodeRelay?
    private var task: Task<Void, Never>?

    private init() {}

    var isSignedIn: Bool {
        session != nil && pageState != .sessionExpired
    }

    var hasActiveDownloads: Bool {
        rows.values.contains(where: \.isBusy)
    }

    var hasNetworkWarning: Bool {
        networkDiagnosis != nil || (probe != nil && probe?.reachable == false)
    }

    func setNetworkMode(_ mode: TFNetworkMode) {
        TFNet.mode = mode
        networkMode = mode
        proxyBypassed = TFNet.didBypassProxy
    }

    // MARK: - Bootstrap & Silent Session Restoration (L3 -> L2 -> Single Auto-L1)

    func bootstrapIfNeeded(using accountStore: TFAccountStore) {
        networkMode = TFNet.mode
        TFSessionStore.prune(keepingAccounts: accountStore.apple.accounts)

        if bootstrapped {
            if (pageState == .noAccount || email.isEmpty),
               let active = accountStore.apple.active ?? accountStore.apple.accounts.first {
                switchToAccount(email: active.id, password: active.password, storeAccountDsid: active.dsid)
                return
            }
            // Already alive in memory: 0ms re-entry with zero redundant reload!
            if !apps.isEmpty { loadProducts() }
            return
        }
        bootstrapped = true

        #if DEBUG
        let wanted = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--tf-account=") }
            .map { String($0.dropFirst("--tf-account=".count)) }
        let picked = wanted.flatMap { needle in
            accountStore.apple.accounts.first { account in
                let local = account.id.split(separator: "@").first.map(String.init) ?? account.id
                return local.localizedCaseInsensitiveContains(needle)
                    || account.id.localizedCaseInsensitiveContains(needle)
            }
        }
        #else
        let picked: AppleAccount? = nil
        #endif
        let remembered = TFSessionStore.lastAccountEmail.flatMap { accountStore.account(for: $0) }
        let roster = accountStore.apple.accounts
            .map { TFHomeModel.mask($0.id) }
            .joined(separator: " ")
        accountSummary = "accounts: " + (roster.isEmpty ? "-" : roster)

        if let account = picked ?? remembered ?? accountStore.apple.active ?? accountStore.apple.accounts.first {
            email = account.id
            password = account.password
            TFSessionStore.lastAccountEmail = account.id
            accountSummary += " | using " + TFHomeModel.mask(account.id)
                + (picked == nil ? " (active)" : " (--tf-account)")
            hydrateAndRestore(email: account.id, storeAccountDsid: account.dsid, allowAutoSignIn: true)
        } else {
            pageState = .noAccount
        }
    }

    func enterCustomSignIn() {
        isUsingCustomSignIn = true
        pageState = .customSignIn
    }

    func handleExternalActiveAccountChange(newActiveID: String?, accountStore: TFAccountStore) {
        guard bootstrapped, let newActiveID, !newActiveID.isEmpty else { return }
        let normalizedNew = AppleAccount.normalizedIdentifier(newActiveID)
        let normalizedCurrent = AppleAccount.normalizedIdentifier(email)
        guard normalizedNew != normalizedCurrent else {
            externalActiveSwitchEmail = nil
            return
        }
        if !hasActiveDownloads && phase == .idle {
            if let account = accountStore.account(for: newActiveID) {
                switchToAccount(email: account.id, password: account.password, storeAccountDsid: account.dsid)
            }
        } else {
            externalActiveSwitchEmail = newActiveID
        }
    }

    func switchToAccount(email newEmail: String, password newPassword: String,
                         storeAccountDsid: String, custom: Bool = false) {
        let previousDsid = session?.dsid
        accountEpoch += 1
        cancelAllDownloads()
        cancelSignIn()
        restoreTask?.cancel()
        restoreTask = nil
        isRestoringSilently = false
        detailTask?.cancel()
        hydrateTask?.cancel()

        session = nil
        context = nil
        apps = []
        details = [:]
        rows = [:]
        iconFiles = [:]
        iconColors = [:]
        iconRevisions = [:]
        installNotes = [:]
        installingAppIDs = []
        installedAppIDs = []
        installFailedAppIDs = []
        installNeedsChannelAppIDs = []
        dsidTail = ""
        dsidConflict = false
        externalActiveSwitchEmail = nil
        networkDiagnosis = nil

        email = newEmail
        password = newPassword
        isUsingCustomSignIn = custom || newEmail.isEmpty
        if custom || newEmail.isEmpty {
            if let previousDsid { AccountScope.writeBack(dsid: previousDsid) }
            AccountScope.clearSharedCookies()
            TFStoreCapture.reset()
            pageState = .customSignIn
            return
        }
        TFSessionStore.lastAccountEmail = newEmail
        hydrateAndRestore(email: newEmail, storeAccountDsid: storeAccountDsid,
                          previousDsid: previousDsid, allowAutoSignIn: true)
    }

    func clearPersistedSession(storeAccountDsid: String) {
        let dsid = session?.dsid ?? storeAccountDsid
        accountEpoch += 1
        TFSessionStore.delete(dsid: dsid, email: email)
        AccountScope.clearSharedCookies()
        TFStoreCapture.reset()
        lastSyncedAt.removeValue(forKey: dsid)
        cancelAllDownloads()
        cancelSignIn()
        restoreTask?.cancel()
        restoreTask = nil
        isRestoringSilently = false
        detailTask?.cancel()
        hydrateTask?.cancel()
        session = nil
        context = nil
        apps = []
        details = [:]
        rows = [:]
        dsidTail = ""
        dsidConflict = false
        pageState = .readyToSignIn
        append("已清除当前账号的 TestFlight 持久会话")
    }

    /// 0ms render from cache -> L3 (Keychain session) -> L2 (AccountScope 10-cookie snapshot)
    /// -> controlled single-attempt auto-L1 when credentials exist and no persisted session yet.
    private func hydrateAndRestore(email: String, storeAccountDsid: String,
                                   previousDsid: String? = nil, allowAutoSignIn: Bool) {
        let stored = TFSessionStore.load(dsid: storeAccountDsid, email: email)
        let targetDsid = stored?.dsid ?? storeAccountDsid

        if !targetDsid.isEmpty {
            let cachedApps = TFSessionStore.loadCatalog(dsid: targetDsid)
            if !cachedApps.isEmpty {
                apps = cachedApps
                dsidTail = String(targetDsid.suffix(4))
                loadProducts()
                hydrateCachedDetailsAndIcons(for: cachedApps)
                pageState = stored != nil ? .catalogReady : .sessionExpired
            } else {
                pageState = .readyToSignIn
            }
        } else {
            pageState = .readyToSignIn
        }

        // If we have a persisted Keychain session, restore silently.
        if let stored {
            let candidateSession = stored.tfSession
            let rebuiltContext: TFContext? = {
                guard let amdm = stored.amdm, !amdm.isEmpty else { return nil }
                return try? TFLogin.restoreContextFromSnapshot(
                    dsid: stored.dsid,
                    currentDsid: previousDsid,
                    amdm: amdm,
                    storeFront: stored.storeFront,
                    log: { line in TFLog.append(line) }
                )
            }()

            // Within 5-minute sync cooldown and cached apps already visible: skip redundant network hit!
            if !apps.isEmpty,
               let syncedAt = lastSyncedAt[stored.dsid],
               Date().timeIntervalSince(syncedAt) < 300 {
                session = candidateSession
                context = rebuiltContext
                pageState = .catalogReady
                // Still backfill any legacy details missing localized/expanded fields.
                scheduleDetailAndIconFetch(for: apps, session: candidateSession, force: false,
                                           log: { line in TFLog.append(line) })
                return
            }

            restoreTask?.cancel()
            isRestoringSilently = true
            let epoch = accountEpoch
            restoreTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    Task { @MainActor in
                        if self.accountEpoch == epoch { self.isRestoringSilently = false }
                    }
                }
                let append: @Sendable (String) -> Void = { line in
                    TFLog.append(line)
                    Task { @MainActor in
                        if self.accountEpoch == epoch { self.push(line) }
                    }
                }
                append("restore: 尝试恢复 dsid …" + String(stored.dsid.suffix(4)))

                // L3: Persisted Keychain TFSession directly.
                do {
                    let catalog = try await TFAPI.catalog(session: candidateSession, log: append)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self.accountEpoch == epoch else { return }
                        self.applyCatalogSuccess(
                            catalog: catalog,
                            session: candidateSession,
                            context: rebuiltContext,
                            storeAccountDsid: storeAccountDsid,
                            log: append
                        )
                    }
                    append("restore: L3 钥匙串会话恢复成功（\(catalog.count) 个 App）")
                    return
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                        return
                    }
                    append("restore: L3 未通过（" + TFLogin.shortDescription(error) + "）")
                    if !isSessionExpiredError(error) {
                        await MainActor.run {
                            guard self.accountEpoch == epoch else { return }
                            self.session = candidateSession
                            self.context = rebuiltContext
                        }
                        return
                    }
                }

                // L2: Mint fresh session from AccountScope 10-cookie snapshot without 2FA.
                if let ctx = rebuiltContext {
                    do {
                        let freshSession = try await TFAPI.authenticate(context: ctx, log: append)
                        let catalog = try await TFAPI.catalog(session: freshSession, log: append)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard self.accountEpoch == epoch else { return }
                            TFSessionStore.save(session: freshSession, context: ctx, email: email)
                            self.applyCatalogSuccess(
                                catalog: catalog,
                                session: freshSession,
                                context: ctx,
                                storeAccountDsid: storeAccountDsid,
                                log: append
                            )
                        }
                        append("restore: L2 10-cookie 无感续期成功（\(catalog.count) 个 App）")
                        return
                    } catch {
                        if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                            return
                        }
                        append("restore: L2 无感续期未通过（" + TFLogin.shortDescription(error) + "）")
                    }
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.accountEpoch == epoch else { return }
                    self.session = nil
                    self.context = nil
                    if allowAutoSignIn {
                        self.triggerControlledAutoSignInIfEligible(storeAccountDsid: storeAccountDsid)
                    } else {
                        self.pageState = self.apps.isEmpty ? .readyToSignIn : .sessionExpired
                    }
                }
            }
            return
        }

        // No persisted Keychain session yet -> automatically start login flow ONCE if credentials exist.
        if allowAutoSignIn {
            triggerControlledAutoSignInIfEligible(storeAccountDsid: storeAccountDsid)
        }
    }

    private func triggerControlledAutoSignInIfEligible(storeAccountDsid: String) {
        let normalized = AppleAccount.normalizedIdentifier(email)
        guard !normalized.isEmpty, !password.isEmpty,
              !attemptedAutoSignInEmails.contains(normalized) else {
            pageState = apps.isEmpty ? .readyToSignIn : .sessionExpired
            return
        }
        attemptedAutoSignInEmails.insert(normalized)
        start(storeAccountDsid: storeAccountDsid)
    }

    private func applyCatalogSuccess(catalog: [TFBetaApp], session: TFSession, context: TFContext?,
                                     storeAccountDsid: String, log: @escaping @Sendable (String) -> Void) {
        let sorted = catalog.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.session = session
        self.context = context
        self.apps = sorted
        self.dsidTail = String(session.dsid.suffix(4))
        self.dsidConflict = TFAccountStore.hasDSIDConflict(storeDsid: storeAccountDsid, petDsid: session.dsid)
        self.proxyBypassed = TFNet.didBypassProxy
        self.phase = .idle
        self.isUsingCustomSignIn = false
        self.pageState = sorted.isEmpty ? .catalogEmpty : .catalogReady
        self.lastSyncedAt[session.dsid] = Date()
        TFSessionStore.saveCatalog(sorted, dsid: session.dsid)
        self.loadProducts()
        self.hydrateCachedDetailsAndIcons(for: sorted)
        self.scheduleDetailAndIconFetch(for: sorted, session: session, force: false, log: log)
    }

    // MARK: - Sign-In (L1: GSA + 2FA)

    func start(storeAccountDsid: String = "") {
        guard phase == .idle else { return }
        restoreTask?.cancel()
        task?.cancel()
        detailTask?.cancel()
        phase = .working
        pageState = .authenticating(AppText.text("检查网络…"))
        needsCode = false
        isSubmittingCode = false
        code = ""
        networkDiagnosis = nil
        dsidConflict = false
        externalActiveSwitchEmail = nil
        TFNet.didBypassProxy = false
        proxyBypassed = false
        lines = []
        probe = nil
        TFLog.reset()
        if !accountSummary.isEmpty {
            TFLog.append(accountSummary)
            lines = [accountSummary]
        }

        let relay = TFLogin.CodeRelay { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .working else { return }
                self.isSubmittingCode = false
                self.needsCode = true
            }
        }
        self.relay = relay
        let email = email.trimmingCharacters(in: .whitespaces)
        let password = password
        let epoch = accountEpoch
        TFSessionStore.lastAccountEmail = email

        task = Task { [weak self] in
            let append: @Sendable (String) -> Void = { line in
                TFLog.append(line)
                Task { @MainActor in
                    guard let self, self.accountEpoch == epoch else { return }
                    self.push(line)
                }
            }
            let gsaDNS = await TFDoh.probe("gsa.apple.com", log: append)
            let tfDNS = await TFDoh.probe("testflight.apple.com", log: append)
            let reachability = await TFGSA.probe(log: append)
            guard !Task.isCancelled else { return }
            let stillActive = await MainActor.run { () -> Bool in
                guard let self, self.accountEpoch == epoch else { return false }
                self.dnsPathSummary = gsaDNS == tfDNS ? gsaDNS : "GSA: \(gsaDNS) · TF: \(tfDNS)"
                self.probe = reachability
                self.pageState = .authenticating(AppText.text("登录 Apple 账号…"))
                return true
            }
            guard stillActive else { return }
            do {
                let context = try await TFLogin.signIn(email: email, password: password,
                                                       relay: relay, log: append)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.accountEpoch == epoch else { return }
                    self.needsCode = false
                    self.isSubmittingCode = false
                    self.pageState = .authenticating(AppText.text("建立 TestFlight 会话…"))
                }
                let session = try await TFAPI.authenticate(context: context, log: append)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.accountEpoch == epoch else { return }
                    self.dsidTail = String(session.dsid.suffix(4))
                    self.dsidConflict = TFAccountStore.hasDSIDConflict(storeDsid: storeAccountDsid, petDsid: session.dsid)
                    self.proxyBypassed = TFNet.didBypassProxy
                    self.pageState = .authenticating(AppText.text("读取测试列表…"))
                }
                let catalog = try await TFAPI.catalog(session: session, log: append)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.accountEpoch == epoch else { return }
                    TFSessionStore.save(session: session, context: context, email: email)
                    self.applyCatalogSuccess(
                        catalog: catalog,
                        session: session,
                        context: context,
                        storeAccountDsid: storeAccountDsid,
                        log: append
                    )
                    self.append("完成：\(catalog.count) 个 App（会话已持久化）")
                }

                #if DEBUG
                if let wanted = await MainActor.run(body: { self?.autoBundle }) {
                    await MainActor.run {
                        guard let self, self.accountEpoch == epoch else { return }
                        let match = self.apps.first { $0.name.localizedCaseInsensitiveContains(wanted) }
                            ?? self.apps.first { $0.id == wanted }
                        if let match { self.start(match) }
                    }
                }
                if let bundle = await MainActor.run(body: { self?.autoInstall }) {
                    await self?.installHook(bundle, append: append)
                }
                #endif
            } catch {
                await MainActor.run {
                    guard let self, self.accountEpoch == epoch else { return }
                    self.handleSignInError(error)
                }
            }
        }
    }

    func cancelSignIn() {
        let activeRelay = relay
        relay = nil
        task?.cancel()
        task = nil
        Task { await activeRelay?.cancel() }
        needsCode = false
        isSubmittingCode = false
        code = ""
        phase = .idle
        if session != nil {
            pageState = apps.isEmpty ? .catalogEmpty : .catalogReady
        } else {
            pageState = apps.isEmpty ? .readyToSignIn : .sessionExpired
        }
    }

    func submitCode() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isSubmittingCode = true
        code = ""
        UX.feedback()
        Task { await relay?.submit(value) }
    }

    func refreshCatalog(force: Bool = true) async {
        guard let session, phase == .idle, !isRefreshingCatalog else { return }
        let epoch = accountEpoch
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        let append: @Sendable (String) -> Void = { line in
            TFLog.append(line)
            Task { @MainActor in
                if self.accountEpoch == epoch { self.push(line) }
            }
        }
        do {
            let catalog = try await TFAPI.catalog(session: session, log: append)
            guard !Task.isCancelled, accountEpoch == epoch else { return }
            let sorted = catalog.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            apps = sorted
            proxyBypassed = TFNet.didBypassProxy
            pageState = sorted.isEmpty ? .catalogEmpty : .catalogReady
            lastSyncedAt[session.dsid] = Date()
            TFSessionStore.saveCatalog(sorted, dsid: session.dsid)
            loadProducts()
            hydrateCachedDetailsAndIcons(for: sorted)
            scheduleDetailAndIconFetch(for: sorted, session: session, force: force, log: append)
            append("刷新完成：\(sorted.count) 个 App")
        } catch {
            guard !Task.isCancelled, accountEpoch == epoch,
                  !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled else { return }
            if isSessionExpiredError(error) {
                pageState = .sessionExpired
            }
            append("刷新失败：" + TFLogin.shortDescription(error))
        }
    }

    // MARK: - v3 Details & Icons

    nonisolated private static func detailNeedsUpgrade(_ detail: TFAppDetail?) -> Bool {
        guard let detail else { return true }
        // Refresh cached details created before 3-bucket availability classification or missing developer fallback.
        if detail.availability == nil { return true }
        if detail.availability == .previouslyTested && detail.developerName.isEmpty { return true }
        if detail.compatibilityStatement == "iPAD ONLY" { return true }
        // If a multi-platform removed app previously cached its macOS icon instead of its iOS icon, refresh once.
        if detail.availability == .previouslyTested,
           let tmpl = detail.iconAsset?.urlTemplate,
           !tmpl.contains("U007e") {
            return true
        }
        return Date().timeIntervalSince(detail.cachedAt) >= 6 * 3600
    }

    func ensureDetailLoaded(for app: TFBetaApp) async {
        if details[app.id] == nil, let cached = TFSessionStore.loadDetail(appID: app.id) {
            details[app.id] = cached
            if let colors = cached.iconAsset?.colors { iconColors[app.id] = colors }
        }
        guard let session else { return }
        if !Self.detailNeedsUpgrade(details[app.id]) {
            return
        }
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let append: @Sendable (String) -> Void = { line in
            TFLog.append(line)
            Task { @MainActor in self.push(line) }
        }
        if let fresh = await TFAPI.appDetailV3(
            appID: app.id,
            fallbackName: app.name,
            fallbackDeveloper: app.developerName,
            isPhone: isPhone,
            session: session,
            log: append
        ) {
            TFSessionStore.saveDetail(fresh)
            let file = await TFIcon.cache(appID: app.id, asset: fresh.iconAsset, force: false, log: append)
            details[app.id] = fresh
            if let colors = fresh.iconAsset?.colors { iconColors[app.id] = colors }
            if let file {
                iconFiles[app.id] = file
                iconRevisions[app.id, default: 0] += 1
            }
        }
    }

    private func hydrateCachedDetailsAndIcons(for list: [TFBetaApp]) {
        hydrateTask?.cancel()
        let productMap = products
        hydrateTask = Task { [weak self] in
            let hydrated = await Task.detached(priority: .userInitiated) {
                () -> (details: [String: TFAppDetail], icons: [String: URL], colors: [String: TFIconColors]) in
                var outDetails: [String: TFAppDetail] = [:]
                var outIcons: [String: URL] = [:]
                var outColors: [String: TFIconColors] = [:]
                for app in list {
                    if Task.isCancelled { break }
                    if var detail = TFSessionStore.loadDetail(appID: app.id) {
                        if Self.applyLocalDisplayOverrides(to: &detail, app: app, productMap: productMap) {
                            TFSessionStore.saveDetail(detail)
                        }
                        outDetails[app.id] = detail
                        if let colors = detail.iconAsset?.colors {
                            outColors[app.id] = colors
                        }
                    }
                    if let file = TFIcon.cached(appID: app.id) {
                        outIcons[app.id] = file
                    }
                    if outColors[app.id] == nil, let colors = TFIcon.cachedAsset(appID: app.id)?.colors {
                        outColors[app.id] = colors
                    }
                }
                return (outDetails, outIcons, outColors)
            }.value
            guard !Task.isCancelled, let self else { return }
            for (id, detail) in hydrated.details { self.details[id] = detail }
            for (id, file) in hydrated.icons { self.iconFiles[id] = file }
            for (id, colors) in hydrated.colors { self.iconColors[id] = colors }
        }
    }

    /// Overlays localized `framework.displayName` / `framework.testNotes` from cached install metadata
    /// (and falls back to a downloaded IPA's localized `CFBundleDisplayName`) without touching storefront/session.
    @discardableResult
    private func applyLocalDisplayOverrides(to detail: inout TFAppDetail, app: TFBetaApp) -> Bool {
        Self.applyLocalDisplayOverrides(to: &detail, app: app, productMap: products)
    }

    @discardableResult
    nonisolated private static func applyLocalDisplayOverrides(to detail: inout TFAppDetail,
                                                               app: TFBetaApp,
                                                               productMap: [String: String]) -> Bool {
        let bundle = !detail.bundleID.isEmpty ? detail.bundleID : (productMap[app.id] ?? app.bundleID)
        guard !bundle.isEmpty else { return false }
        var changed = false
        if let meta = TFAPI.cachedInstallMetadata(bundle: bundle) {
            if let localizedName = meta.displayName, !localizedName.isEmpty, detail.name != localizedName {
                detail.name = localizedName
                changed = true
            }
            if let localizedNotes = meta.testNotes, !localizedNotes.isEmpty, detail.whatsNew != localizedNotes {
                detail.whatsNew = localizedNotes
                changed = true
            }
        } else if let ipa = TFProducts.newest(bundle: bundle)?.ipa,
                  let inspected = try? PackageService.inspect(ipa) {
            let candidate = inspected.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && candidate != bundle && detail.name != candidate {
                detail.name = candidate
                changed = true
            }
        }
        return changed
    }

    private func scheduleDetailAndIconFetch(for list: [TFBetaApp], session: TFSession, force: Bool,
                                            log: @escaping @Sendable (String) -> Void) {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let epoch = accountEpoch
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            var resolvedDetails: [String: TFAppDetail] = [:]
            var needsBulkFetch = force
            for app in list {
                if let cached = TFSessionStore.loadDetail(appID: app.id) {
                    resolvedDetails[app.id] = cached
                    if TFHomeModel.detailNeedsUpgrade(cached) {
                        needsBulkFetch = true
                    }
                } else {
                    needsBulkFetch = true
                }
            }

            if needsBulkFetch {
                let bulk = await TFAPI.allAppDetailsV3(
                    for: list,
                    isPhone: isPhone,
                    session: session,
                    log: log
                )
                if !bulk.isEmpty {
                    for (appID, detail) in bulk {
                        TFSessionStore.saveDetail(detail)
                        resolvedDetails[appID] = detail
                    }
                    await MainActor.run {
                        guard let self, self.accountEpoch == epoch else { return }
                        for (appID, detail) in bulk {
                            self.details[appID] = detail
                            if let colors = detail.iconAsset?.colors {
                                self.iconColors[appID] = colors
                            }
                        }
                    }
                }
            }

            guard !Task.isCancelled else { return }

            let maxConcurrent = 4
            var iterator = list.makeIterator()
            await withTaskGroup(of: (String, TFAppDetail?, URL?).self) { group in
                func enqueueNext() {
                    guard let app = iterator.next() else { return }
                    let currentDetail = resolvedDetails[app.id]
                    group.addTask {
                        var detail = currentDetail
                        if detail == nil || (needsBulkFetch && resolvedDetails.isEmpty) {
                            if let fresh = await TFAPI.appDetailV3(
                                appID: app.id,
                                fallbackName: app.name,
                                fallbackDeveloper: app.developerName,
                                isPhone: isPhone,
                                session: session,
                                log: log
                            ) {
                                TFSessionStore.saveDetail(fresh)
                                detail = fresh
                            }
                        }
                        guard let asset = detail?.iconAsset, asset.urlTemplate != nil else {
                            return (app.id, detail, TFIcon.cached(appID: app.id))
                        }
                        if !force, TFIcon.isCacheFresh(appID: app.id, buildID: detail?.buildID, template: asset.urlTemplate),
                           let existing = TFIcon.cached(appID: app.id) {
                            return (app.id, detail, existing)
                        }
                        let file = await TFIcon.cache(appID: app.id, asset: asset, force: false, log: log)
                        return (app.id, detail, file)
                    }
                }
                for _ in 0..<min(maxConcurrent, list.count) { enqueueNext() }
                var pendingBatch: [(String, TFAppDetail?, URL?)] = []
                var lastFlush = ProcessInfo.processInfo.systemUptime
                func flushBatch() async {
                    guard !pendingBatch.isEmpty else { return }
                    let batch = pendingBatch
                    pendingBatch.removeAll(keepingCapacity: true)
                    lastFlush = ProcessInfo.processInfo.systemUptime
                    await MainActor.run {
                        guard let self, self.accountEpoch == epoch else { return }
                        for (appID, detail, file) in batch {
                            if let detail {
                                self.details[appID] = detail
                                if let colors = detail.iconAsset?.colors { self.iconColors[appID] = colors }
                            }
                            if let file {
                                self.iconFiles[appID] = file
                                self.iconRevisions[appID, default: 0] += 1
                            }
                        }
                    }
                }
                for await (appID, detail, file) in group {
                    if Task.isCancelled { break }
                    pendingBatch.append((appID, detail, file))
                    let now = ProcessInfo.processInfo.systemUptime
                    if pendingBatch.count >= 4 || now - lastFlush >= 0.25 {
                        await flushBatch()
                    }
                    enqueueNext()
                }
                if !Task.isCancelled {
                    await flushBatch()
                }
            }
        }
    }

    // MARK: - Error Classification

    private func handleSignInError(_ error: Error) {
        phase = .idle
        needsCode = false
        isSubmittingCode = false
        proxyBypassed = TFNet.didBypassProxy

        if case TFError.cancelled = error {
            pageState = session == nil ? (apps.isEmpty ? .readyToSignIn : .sessionExpired) : (apps.isEmpty ? .catalogEmpty : .catalogReady)
            return
        }
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
            pageState = session == nil ? (apps.isEmpty ? .readyToSignIn : .sessionExpired) : (apps.isEmpty ? .catalogEmpty : .catalogReady)
            return
        }

        let raw = TFLogin.shortDescription(error)
        TFLog.append("失败：\(raw)")

        let facts = transportFacts()
        if TFNet.looksBlocked(status: nil, error: error, hosts: ["gsa.apple.com", "testflight.apple.com"]),
           !facts.isEmpty {
            networkDiagnosis = TFNetDiagnosis.bothFailed(facts)
            pageState = .networkBlocked
            return
        }

        let lower = raw.lowercased()
        if Self.isMultiPhoneVerificationError(raw) {
            pageState = .authFailed(
                AppText.text("当前暂不支持选择多个受信任号码验证。请在已登录该 Apple 账号的设备上前往「设置 › Apple 账户 › 登录与安全 › 获取验证码」，然后重试。"),
                .standard
            )
            return
        }

        let is503 = lower.contains("503") || lower.contains("rate") || lower.contains("too many")
        let vpnOrProxy = LocalHostRecord.proxyOrVPNActive || probe?.fakeIP != nil
        if is503 && vpnOrProxy {
            pageState = .authFailed(
                AppText.text("检测到代理或 VPN 正在运行，可能会拦截或导致 Apple 登录被拒。建议暂时关闭 VPN，或在代理中将以下 Apple 域名设为直连后重试。"),
                .vpnOrProxy503
            )
            return
        }
        if is503 {
            pageState = .authFailed(
                AppText.text("Apple 暂时拒绝了本次登录请求。若开启了代理或 VPN 建议先关闭后重试；否则请稍等约 30 分钟后再试，避免连续重试。"),
                .rateLimited
            )
            return
        }
        if lower.contains("password") || lower.contains("incorrect") || lower.contains("invalid")
            || lower.contains("bad credentials") || lower.contains("-20101") || lower.contains("-22406") {
            pageState = .authFailed(
                AppText.text("Apple 账号或密码验证未通过，请在右上角头像中检查或更新账号后重试。"),
                .standard
            )
            return
        }
        if lower.contains("401") || lower.contains("403") {
            pageState = .authFailed(
                AppText.text("登录凭据未通过验证，请重新尝试；详细原因已记录在诊断日志中。"),
                .standard
            )
            return
        }
        if vpnOrProxy {
            pageState = .authFailed(
                AppText.text("连接 Apple 服务时出现异常，可能与当前代理或 VPN 有关。建议关闭 VPN 或设为直连后重试，详情可在日志中查看。"),
                .vpnOrProxy503
            )
            return
        }
        pageState = .authFailed(
            AppText.text("连接 Apple 登录服务失败，请检查网络后重试；详细错误已记录在诊断日志中。"),
            .standard
        )
    }

    private func isSessionExpiredError(_ error: Error) -> Bool {
        if case let TFError.http(status, _, _) = error, status == 401 || status == 403 {
            return true
        }
        let text = TFLogin.shortDescription(error)
        return text.contains("[401 ") || text.contains("[403 ")
    }

    /// Distinguishes genuine multi-trusted-phone/SMS 2FA challenges from unrelated errors
    /// whose text happens to contain `"iphone"` (such as `"no usable iphone identity"`).
    nonisolated static func isMultiPhoneVerificationError(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("trusted phone")
            || lower.contains("phone number")
            || lower.contains("trusted number")
            || lower.contains("sms")
            || lower.contains("phoneid")
            || lower.contains("phone_id")
            || (lower.contains("select") && lower.contains("number"))
    }

    // MARK: - Unattended Automation Hooks (Debug Only)

    #if DEBUG
    var autoBundle: String? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--tf-download=") }
            .map { String($0.dropFirst("--tf-download=".count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    var autoInstall: String? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--tf-install=") }
            .map { String($0.dropFirst("--tf-install=".count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    var expectation: (members: Int, encrypted: Int)? {
        guard let value = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--tf-expect=") })
            .map({ String($0.dropFirst("--tf-expect=".count)) }) else { return nil }
        let parts = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    func installHook(_ bundle: String, append: @escaping @Sendable (String) -> Void) async {
        guard let ipa = TFProducts.newest(bundle: bundle)?.ipa else { return }
        do {
            let outcome = try await NativeInstaller.install(package: ipa, bundleID: bundle) { phase in
                append("install: " + String(describing: phase))
            }
            append("install: ok upgraded=" + String(outcome.upgraded))
            let info = try await NativeInstaller.lookup(bundleID: bundle)
            append("lookup: installed=" + String(info.installed)
                   + " signer=" + (info.signer ?? "-")
                   + " storeItemID=" + (info.storeItemID ?? "-")
                   + " manifestInstall=" + String(describing: info.manifestInstall))
            if let schemeURL = URL(string: bundle + ":") {
                let opened = await MainActor.run {
                    UIApplication.shared.canOpenURL(schemeURL)
                }
                if opened {
                    _ = await MainActor.run { UIApplication.shared.open(schemeURL) }
                }
                append("launch: " + (opened ? "opened" : "no url scheme"))
            } else {
                append("launch: invalid bundle scheme")
            }
        } catch {
            append("install: failed " + TFLogin.shortDescription(error))
        }
    }
    #else
    var expectation: (members: Int, encrypted: Int)? { nil }
    #endif

    static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "***" }
        let local = email[email.startIndex..<at]
        let head = String(local.prefix(3))
        return head + "***" + email[at...]
    }

    // MARK: - Row Actions (Download / Cancel / Install / Delete)

    func rowState(_ app: TFBetaApp) -> TFRowState {
        if let state = rows[app.id], state.stage != .idle { return state }
        if let url = productURL(for: app) {
            var state = TFRowState()
            state.stage = .done
            state.output = url
            return state
        }
        return rows[app.id] ?? TFRowState()
    }

    func productURL(for app: TFBetaApp) -> URL? {
        if let bundle = products[app.id], let hit = productURL(appID: app.id, bundle: bundle) {
            return hit
        }
        if let bundle = details[app.id]?.bundleID, !bundle.isEmpty,
           let hit = productURL(appID: app.id, bundle: bundle) {
            remember(appID: app.id, bundle: bundle)
            return hit
        }
        return nil
    }

    func start(_ app: TFBetaApp) {
        guard !(rows[app.id]?.isBusy ?? false) else { return }
        guard let session else {
            rows[app.id] = failed(AppText.text("请先登录后再下载"))
            return
        }
        let append: @Sendable (String) -> Void = { line in
            TFLog.append(line)
            Task { @MainActor in self.push(line) }
        }

        let resolvedContext: TFContext
        if let existing = context {
            resolvedContext = existing
        } else if let amdm = session.baseHeaders["X-Apple-AMD-M"], !amdm.isEmpty,
                  let rebuilt = try? TFLogin.restoreContextFromSnapshot(
                    dsid: session.dsid,
                    amdm: amdm,
                    storeFront: session.baseHeaders["X-Apple-Store-Front"],
                    log: append
                  ) {
            context = rebuilt
            resolvedContext = rebuilt
        } else {
            pageState = .sessionExpired
            rows[app.id] = failed(AppText.text("会话已过期，请重新验证后再下载"))
            return
        }

        let handle = TFTransferHandle()
        let token = UUID()
        runs[app.id] = handle
        downloadTokens[app.id] = token
        var state = TFRowState()
        state.stage = .resolving
        rows[app.id] = state
        installFailedAppIDs.remove(app.id)
        installNeedsChannelAppIDs.remove(app.id)

        let progress: @Sendable (Int64, Int64) -> Void = { received, total in
            Task { @MainActor in
                guard self.downloadTokens[app.id] == token else { return }
                var current = self.rows[app.id] ?? TFRowState()
                guard current.stage == .downloading else { return }
                current.received = received
                current.total = total > 0 ? total : current.total
                self.rows[app.id] = current
            }
        }

        tasks[app.id] = Task { [weak self] in
            guard let self else { return }
            do {
                var bundle = await MainActor.run { self.details[app.id]?.bundleID ?? app.bundleID }
                if bundle.isEmpty {
                    do {
                        bundle = try await TFAPI.publicBundleID(appID: app.id, log: append)
                    } catch {
                        if Task.isCancelled || handle.isCancelled { throw TFError.cancelled }
                        append("lookup 未命中（" + TFLogin.shortDescription(error) + "），改走账号端点")
                    }
                }
                if bundle.isEmpty {
                    bundle = await TFAPI.resolveBundle(appID: app.id, session: session, log: append)
                }
                if Task.isCancelled || handle.isCancelled { throw TFError.cancelled }
                guard !bundle.isEmpty else {
                    throw TFError.malformed("解析不到 \(app.name) 的 bundleId")
                }
                await MainActor.run {
                    guard self.downloadTokens[app.id] == token else { return }
                    self.mark(app.id, stage: .installing)
                    self.remember(appID: app.id, bundle: bundle)
                }

                let hardware = TFIdentity.hardware20()
                let udid = hardware.map { String(format: "%02x", $0) }.joined()
                let envelope = try TFDownload.envelope(dsid: resolvedContext.dsid, headers: resolvedContext.headers,
                                                       storeCookies: resolvedContext.storeCookies, udid: udid)
                let buildID = try await TFAPI.buildID(appID: app.id, session: session, log: append)
                let metadata = try await TFAPI.installMetadata(appID: app.id, buildID: buildID,
                                                               session: session, headers: resolvedContext.headers,
                                                               dsid: resolvedContext.dsid, hardware20: hardware,
                                                               storefront: resolvedContext.storefront, log: append)
                if Task.isCancelled || handle.isCancelled { throw TFError.cancelled }
                let refresh: @Sendable () async -> Data? = {
                    try? await TFAPI.installMetadata(appID: app.id, buildID: buildID,
                                                     session: session, headers: resolvedContext.headers,
                                                     dsid: resolvedContext.dsid, hardware20: hardware,
                                                     storefront: resolvedContext.storefront, log: append)
                }
                await MainActor.run {
                    guard self.downloadTokens[app.id] == token else { return }
                    self.mark(app.id, stage: .downloading)
                }
                let report = try await TFDownload.run(
                    bundle: bundle,
                    context: envelope,
                    hardware20: hardware,
                    identity: resolvedContext.headers,
                    metadata: metadata,
                    expect: self.expectation,
                    buildID: buildID,
                    versionLabel: app.latestVersion,
                    handle: handle,
                    progress: progress,
                    stage: { name in
                        if name == "verifying" {
                            Task { @MainActor in
                                guard self.downloadTokens[app.id] == token else { return }
                                self.mark(app.id, stage: .verifying)
                            }
                        }
                    },
                    refresh: refresh,
                    log: append
                )
                await MainActor.run {
                    guard self.downloadTokens[app.id] == token else { return }
                    var done = TFRowState()
                    done.stage = .done
                    done.output = report.output
                    done.total = Int64(report.outputBytes)
                    done.received = Int64(report.outputBytes)
                    self.rows[app.id] = done
                    let key = bundle.lowercased()
                    self.checkedProductBundles.insert(key)
                    self.resolvedProductURLs[key] = report.output
                    if var detail = self.details[app.id], self.applyLocalDisplayOverrides(to: &detail, app: app) {
                        TFSessionStore.saveDetail(detail)
                        self.details[app.id] = detail
                    }
                    TFProductIndex.shared.refresh()
                    FairPlayPresentation.shared.markFilesChanged()
                    UX.success()
                    self.append("完成：\(report.output.lastPathComponent) \(report.outputBytes) B，成员 \(report.finalMembers)，加密 \(report.encryptedImages)")
                }
            } catch {
                await MainActor.run {
                    guard self.downloadTokens[app.id] == token else { return }
                    let isCancelled: Bool
                    if case TFError.cancelled = error { isCancelled = true }
                    else if error is CancellationError || (error as NSError).code == NSURLErrorCancelled || handle.isCancelled { isCancelled = true }
                    else { isCancelled = false }
                    if isCancelled {
                        self.cleanupTemps(appID: app.id)
                        self.rows[app.id] = TFRowState()
                        self.append("已取消：\(app.name)")
                    } else {
                        self.cleanupTemps(appID: app.id)
                        if self.isSessionExpiredError(error) {
                            self.pageState = .sessionExpired
                        }
                        self.rows[app.id] = self.failed(self.message(for: error))
                        UX.warning()
                        self.append("失败：\(self.message(for: error))")
                    }
                }
            }
            await MainActor.run {
                if self.downloadTokens[app.id] == token {
                    self.runs[app.id] = nil
                    self.tasks[app.id] = nil
                    self.downloadTokens[app.id] = nil
                }
            }
        }
    }

    func cancel(_ app: TFBetaApp) {
        downloadTokens[app.id] = nil
        runs[app.id]?.cancel()
        tasks[app.id]?.cancel()
        runs[app.id] = nil
        tasks[app.id] = nil
        cleanupTemps(appID: app.id)
        rows[app.id] = TFRowState()
        append("已取消：\(app.name)")
    }

    func cancelAllDownloads() {
        downloadTokens.removeAll()
        for (appID, handle) in runs {
            handle.cancel()
            cleanupTemps(appID: appID)
        }
        for (_, t) in tasks { t.cancel() }
        runs.removeAll()
        tasks.removeAll()
    }

    func deleteLocalProduct(_ app: TFBetaApp) {
        if let url = productURL(for: app) {
            try? FileManager.default.removeItem(at: url)
        }
        let bundle = products[app.id] ?? details[app.id]?.bundleID ?? app.bundleID
        if !bundle.isEmpty {
            for product in TFProducts.all(bundle: bundle) {
                try? FileManager.default.removeItem(at: product.ipa)
                try? FileManager.default.removeItem(at: product.directory)
            }
            let key = bundle.lowercased()
            resolvedProductURLs.removeValue(forKey: key)
            checkedProductBundles.insert(key)
        }
        cleanupTemps(appID: app.id)
        rows[app.id] = TFRowState()
        installedAppIDs.remove(app.id)
        installNotes[app.id] = nil
        installFailedAppIDs.remove(app.id)
        installNeedsChannelAppIDs.remove(app.id)
        TFProductIndex.shared.refresh()
        FairPlayPresentation.shared.markFilesChanged()
        append("已删除本地产物：\(app.name)")
    }

    /// Called by `TFProductIndex` when a TestFlight IPA is deleted from DownloadsView or PackagesView,
    /// immediately reverting the corresponding TestFlight row/detail back to "获取".
    func didDeleteProduct(appID: String, bundleID: String) {
        var matchedIDs: Set<String> = [appID]
        let lowerBundle = bundleID.lowercased()
        resolvedProductURLs.removeValue(forKey: lowerBundle)
        checkedProductBundles.insert(lowerBundle)
        for app in apps {
            let b = (products[app.id] ?? details[app.id]?.bundleID ?? app.bundleID).lowercased()
            if b == lowerBundle { matchedIDs.insert(app.id) }
        }
        for (id, b) in products where b.lowercased() == lowerBundle {
            matchedIDs.insert(id)
        }
        for id in matchedIDs {
            rows[id] = TFRowState()
            installedAppIDs.remove(id)
            installNotes[id] = nil
            installFailedAppIDs.remove(id)
            installNeedsChannelAppIDs.remove(id)
        }
    }

    /// Install through the single coordinator entry; `source: .testFlight` is display only.
    /// Note: `.save` share presentation is handled via SwiftUI `ShareSheet` inside `TFInstallSheet`.
    func install(_ app: TFBetaApp, method: InstallMethod, installation: InstallationService?) {
        guard let package = productURL(for: app) else { return }
        let bundle = products[app.id] ?? details[app.id]?.bundleID ?? app.bundleID
        guard !bundle.isEmpty else { return }
        let append: @Sendable (String) -> Void = { line in
            TFLog.append(line)
            Task { @MainActor in self.push(line) }
        }
        if method == .save {
            InstallCoordinator.shared.preferredMethod = .save
            installNotes[app.id] = AppText.text("已保存，可直接分享")
            append("install: save -> share")
            return
        }

        installingAppIDs.insert(app.id)
        installFailedAppIDs.remove(app.id)
        installNeedsChannelAppIDs.remove(app.id)
        installNotes[app.id] = AppText.text("准备安装…")

        Task { [weak self] in
            do {
                let outcome = try await InstallCoordinator.shared.accept(
                    package: package, bundleID: bundle, source: .testFlight,
                    method: method, installation: installation,
                    progress: { note in
                        Task { @MainActor in self?.installNotes[app.id] = note }
                    })
                await MainActor.run {
                    guard let self else { return }
                    self.installingAppIDs.remove(app.id)
                    if outcome.installed {
                        self.installedAppIDs.insert(app.id)
                        self.installNotes[app.id] = AppText.text("已安装")
                        UX.success()
                    } else {
                        self.installNotes[app.id] = AppText.text("安装未完成")
                    }
                    append("install: " + method.rawValue + " -> " + (outcome.installed ? "ok" : "skipped"))
                }
            } catch {
                let installError = error as? InstallFailure
                let text = installError?.message ?? TFLogin.shortDescription(error)
                let needsChannel = installError?.needsNativeChannel ?? false
                await MainActor.run {
                    guard let self else { return }
                    self.installingAppIDs.remove(app.id)
                    self.installFailedAppIDs.insert(app.id)
                    if needsChannel { self.installNeedsChannelAppIDs.insert(app.id) }
                    self.installNotes[app.id] = text
                    UX.warning()
                    append("install: " + method.rawValue + " failed: " + text)
                }
            }
        }
    }

    // MARK: - Helpers

    func transportFacts() -> [String] {
        var facts: [String] = []
        if let probe {
            facts.append("gsa.apple.com · " + (probe.status.map(String.init) ?? AppText.text("无响应"))
                         + " · " + (probe.bytes > 0 ? "\(probe.bytes) B" : "0 B"))
        }
        facts.append("testflight.apple.com · " + AppText.text("未取到响应"))
        return facts
    }

    private func mark(_ appID: String, stage: TFRowState.Stage) {
        var state = rows[appID] ?? TFRowState()
        state.stage = stage
        rows[appID] = state
    }

    private func failed(_ text: String) -> TFRowState {
        var state = TFRowState()
        state.stage = .failed
        state.message = text
        return state
    }

    /// Clean user-facing download errors only; raw technical details stay in `TFLog`.
    private func message(for error: Error) -> String {
        switch error {
        case TFError.cancelled: return AppText.text("已取消")
        case TFError.networkLost: return AppText.text("网络中断，请稍后重试")
        default: break
        }
        let text = TFLogin.shortDescription(error)
        TFLog.append("row-error: " + text)
        if text.contains("没有可用的 iOS build") {
            return AppText.text("此版本暂不支持当前设备")
        }
        if text.contains("解析不到") && text.contains("bundleId") {
            return AppText.text("该测试版本暂不可用，可能已被开发者移除")
        }
        if text.contains("[404 ") || text.contains("不可用或不存在") {
            return AppText.text("该测试版本已不可用或已从 TestFlight 移除")
        }
        if text.contains("install HTTP") || text.contains("元数据形态") {
            return AppText.text("该测试版本暂不可用，请稍后重试")
        }
        if text.contains("validate") || text.contains("成员数") || text.contains("校验")
            || text.contains("下载长度") || text.contains("bundle 与请求") || text.contains("加密 Mach-O") {
            return AppText.text("产物校验失败，已清理")
        }
        if text.contains("-1005") || text.contains("网络连接已中断") || text.contains("timed out") {
            return AppText.text("网络中断，请稍后重试")
        }
        if text.contains("[401 ") || text.contains("[403 ") {
            return AppText.text("会话已过期，请重新验证")
        }
        return AppText.text("下载暂时失败，请重试")
    }

    func cleanupTemps(appID: String) {
        guard let bundle = products[appID] else { return }
        guard let root = TFDownload.directoryURL(bundle: bundle) else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: root.appendingPathComponent(".work", isDirectory: true))
        for suffix in ["-transport.bin", "-base.ipa", "-applezip.ipa"] {
            try? manager.removeItem(at: root.appendingPathComponent(bundle + suffix))
        }
        if let subdirs = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in subdirs {
                try? manager.removeItem(at: dir.appendingPathComponent(".work", isDirectory: true))
            }
        }
    }

    func invalidateProductCache() {
        resolvedProductURLs.removeAll(keepingCapacity: true)
        checkedProductBundles.removeAll(keepingCapacity: true)
    }

    func productURL(appID: String, bundle: String) -> URL? {
        let key = bundle.lowercased()
        if checkedProductBundles.contains(key) {
            return resolvedProductURLs[key]
        }
        let url = TFProducts.newest(bundle: bundle)?.ipa
        checkedProductBundles.insert(key)
        if let url { resolvedProductURLs[key] = url }
        return url
    }

    private var products: [String: String] {
        get { productsCache }
        set {
            productsCache = newValue
            UserDefaults.standard.set(newValue, forKey: "tf.products")
        }
    }

    private func remember(appID: String, bundle: String) {
        guard productsCache[appID] != bundle else { return }
        var map = productsCache
        map[appID] = bundle
        products = map
    }

    func loadProducts() {
        _ = TFProducts.migrateFlatLayout()
        invalidateProductCache()
        var changed = false
        for app in apps {
            let bundle = products[app.id] ?? details[app.id]?.bundleID ?? app.bundleID
            guard !bundle.isEmpty else { continue }
            if let url = productURL(appID: app.id, bundle: bundle) {
                if rows[app.id] == nil || rows[app.id]?.stage == .idle {
                    var state = TFRowState()
                    state.stage = .done
                    state.output = url
                    rows[app.id] = state
                    remember(appID: app.id, bundle: bundle)
                    changed = true
                }
            } else if rows[app.id]?.stage == .done {
                rows[app.id] = TFRowState()
                installedAppIDs.remove(app.id)
                installNotes[app.id] = nil
            }
        }
        TFProductIndex.shared.refresh()
        if changed { append("已下载：\(rows.values.filter { $0.stage == .done }.count) 个产物") }
    }

    private func append(_ line: String) {
        TFLog.append(line)
        push(line)
    }

    private func push(_ line: String) {
        lines.append(TFRedaction.clean(line))
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
    }
}

#endif
