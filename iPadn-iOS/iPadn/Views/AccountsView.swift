import SwiftUI

/// App Store-style account page: profile header, accounts, settings.
struct AccountsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleting: AppleAccount?
    @State private var signingOut = false
    @State private var headerAway = false
    var body: some View {
        List {
            Section {
                PageHeader(title: "账号")
                    .onScrolledUnderBar { headerAway = $0 }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if let error = apple.accountStorageError { Section { InlineIssue(message: error) } }
            Section {
                if let account = apple.active {
                    HStack(spacing: 14) {
                        AccountAvatar(account: account, size: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.name.isEmpty ? account.id : account.name).font(.title3.weight(.semibold)).lineLimit(1)
                            Text(account.id).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            if let country = StoreService.country(forStorefront: account.storeFront) {
                                Text("商店地区：\(country)").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }.padding(.vertical, 6)
                } else {
                    NavigationLink { LoginView() } label: {
                        HStack(spacing: 14) {
                            AccountAvatar(account: nil, size: 60)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("登录 Apple 账户").font(.title3.weight(.semibold))
                                Text("同步已购项目并下载你拥有许可的应用").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
            if !apple.accounts.isEmpty {
                Section {
                    ForEach(apple.accounts) { account in
                        Button {
                            guard apple.activeID != account.id else { return }
                            apple.select(account.id); UX.feedback()
                        } label: {
                            HStack(spacing: 12) {
                                AccountAvatar(account: account, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name.isEmpty ? account.id : account.name).foregroundStyle(.primary).lineLimit(1)
                                    if !account.name.isEmpty { Text(account.id).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 8)
                                if account.id == apple.activeID {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                                        .accessibilityLabel("当前账号")
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(RevealRowButtonStyle())
                        .accessibilityHint(account.id == apple.activeID ? AppText.text("当前下载账号") : AppText.text("切换到此账号"))
                        .accessibilityIdentifier("account." + account.id)
                        .disabled(store.accountRemoving != nil)
                        .revealDelete(id: "account." + account.id, enabled: store.accountRemoving == nil,
                                      grouping: account.id == apple.accounts.first?.id ? .first : .middle,
                                      // Text starts after the 20pt margin, 36pt avatar and 12pt gap.
                                      separatorInset: 68, title: "移除") { deleting = account }
                    }
                    NavigationLink { LoginView() } label: { Label("添加账号", systemImage: "plus") }
                } header: { Text("账号") } footer: { Text("点按切换下载账号，侧滑移除。") }
            }
            Section {
                Button { store.tab = 2 } label: { Label("已购项目", systemImage: "bag") }
                Button { store.tab = 1 } label: { Label("下载与安装", systemImage: "arrow.down.circle") }
                if InstalledAppsView.isSupported {
                    NavigationLink { InstalledAppsView() } label: { Label("本机应用", systemImage: "iphone") }
                    NavigationLink { WiFiTransferView() } label: { Label("Wi‑Fi 传输", systemImage: "laptopcomputer.and.arrow.down") }
                        .accessibilityIdentifier("account.wifi-transfer")
                        .accessibilityIdentifier("accounts.installed-apps")
                }
                NavigationLink { SettingsView() } label: { Label("设置", systemImage: "gearshape") }
                    .accessibilityIdentifier("accounts.settings")
            }
            if apple.active != nil {
                Section {
                    Button("退出登录", role: .destructive) { signingOut = true }
                        .frame(maxWidth: .infinity)
                        .confirmationDialog("退出当前账号？", isPresented: $signingOut, titleVisibility: .visible) {
                            Button("退出登录", role: .destructive) { apple.select(nil) }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("账号仍会保留，可随时切换回来。")
                        }
                }
            }
        }
        .animation(UX.motion(reduceMotion), value: apple.accounts.map(\.id))
        .overlay { if store.accountRemoving != nil { ProgressView("正在移除账号…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .toolPage().rootTabBar("账号", headerScrolledAway: headerAway)
        .actionConfirmation(isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), title: "移除账号？", message: removalMessage, confirmTitle: "移除账号") {
            guard let id = deleting?.id else { return }
            Task {
                do { try await store.deleteAccount(id); store.infoMessage = AppText.text("已移除账号") } catch { store.errorMessage = error.localizedDescription }
            }
            deleting = nil
        }
    }

    /// The account ID, then what removing it means for this device.
    private var removalMessage: LocalizedStringKey {
        let id = deleting?.id ?? ""
        return deleting?.id == apple.activeID
            ? "\(id)\n这是当前下载账号，移除后将退出登录。\n已下载的安装包会保留。"
            : "\(id)\n已下载的安装包会保留。"
    }
}

/// Step 2 of Apple sign-in: a dedicated two-factor page with six digit boxes.
/// Submits automatically once six digits are entered.
struct VerificationStep: View {
    let account: String
    @Binding var code: String
    let busy: Bool
    let issue: String?
    var submitTitle = AppText.text("验证")
    /// False while iPadn is still asking Apple to send a code.
    var sent = true
    /// Asks Apple to send a new code; nil hides the button.
    var resend: (() -> Void)? = nil
    let submit: () -> Void
    var changeAccount: (() -> Void)? = nil
    @State private var showingHelp = false
    @State private var resendAvailableAt = Date().addingTimeInterval(30)
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(.tint)
                .padding(.top, 12).accessibilityHidden(true)
            Text("双重认证").font(.title.weight(.bold))
            Text(sent ? "Apple 已向“\(account)”的受信任设备发送登录请求。在设备上点按「允许」后会显示 6 位验证码，请输入以继续。"
                 : "正在请求 Apple 向“\(account)”的受信任设备发送验证码…")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VerificationCodeField(code: $code, disabled: busy) { _ in submit() }
                .padding(.vertical, 6)
            if busy {
                HStack(spacing: 8) { ProgressView(); Text("正在验证…").font(.subheadline).foregroundStyle(.secondary) }
            } else if let issue {
                Text(issue).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: submit) { Text(submitTitle).frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || code.count != 6)
                .accessibilityIdentifier("apple.verification.submit")
            if let resend {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                    Button(wait > 0 ? "重新发送验证码（\(wait) 秒）" : "重新发送验证码") {
                        resendAvailableAt = Date().addingTimeInterval(30)
                        resend()
                    }
                    .font(.subheadline).disabled(busy || !sent || wait > 0)
                    .accessibilityIdentifier("apple.verification.resend")
                }
            }
            Button("没有收到验证码？") { showingHelp = true }.font(.subheadline)
            if let changeAccount {
                Button("修改账号或密码", action: changeAccount).font(.subheadline).disabled(busy)
            }
        }
        .alert("获取验证码", isPresented: $showingHelp) {
            Button("好", role: .cancel) { }
        } message: {
            Text("验证码只会发到登录了这个 Apple 账户的 iPhone、iPad 或 Mac，不会发短信。\n1. 在那台设备上出现「Apple 账户登录请求」时点按「允许」。\n2. 没有出现时，可以在那台设备的「设置 › [你的姓名] › 登录与安全 › 获取验证码」中获取，同样可以用来验证。\n3. 仍然没有收到，点按「重新发送验证码」。频繁请求时 Apple 可能会暂时不发送，请稍候再试。\n\n获取免费应用时也需要验证，是因为 Apple 账户要求免费下载输入密码。可以在登录了该账户的设备上打开「设置 › 媒体与购买项目 › 密码设置」，关闭「免费下载」的「需要密码」（使用面容 ID 购买时没有这个选项）。")
        }
    }
}

/// Step 1 of Apple sign-in, App Store style.
struct LoginView: View {
    let initialAccountID: String?
    let onSignedIn: (() -> Void)?
    init(initialAccountID: String? = nil, onSignedIn: (() -> Void)? = nil) {
        self.initialAccountID = initialAccountID
        self.onSignedIn = onSignedIn
        _email = State(initialValue: initialAccountID ?? "")
    }
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var verifying = false
    @State private var failure: String?
    @State private var loginTask: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field { case email, password }
    private var canSubmit: Bool {
        !busy && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty && (!verifying || code.count == 6)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if verifying {
                    VerificationStep(account: email.trimmingCharacters(in: .whitespacesAndNewlines), code: $code,
                                     busy: busy, issue: failure, submitTitle: AppText.text("验证并登录"), resend: resendCode, submit: submit,
                                     changeAccount: { verifying = false; code = ""; failure = nil; focus = .password })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    credentials.transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.compatibleSnappy, value: verifying)
            .frame(maxWidth: 460).padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            if busy { ToolbarItem(placement: .compatibleTopBarTrailing) { Button("取消") { loginTask?.cancel() } } }
        }
        .onDisappear { loginTask?.cancel() }
    }

    private var credentials: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 64)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(initialAccountID == nil ? "登录 Apple 账户" : "重新登录").font(.title.weight(.bold))
                Text(initialAccountID == nil ? "用于同步已购项目和下载你拥有许可的应用。"
                     : "当前登录已失效，请输入此账号现在使用的密码。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.top, 12)
            VStack(spacing: 0) {
                TextField("邮箱或电话号码", text: $email)
                    .textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .email).submitLabel(.next).onSubmit { focus = .password }
                    .padding(.horizontal, 16).frame(minHeight: 50)
                Divider().padding(.leading, 16)
                SecureField("密码", text: $password).textContentType(.password)
                    .focused($focus, equals: .password).submitLabel(.go)
                    .onSubmit { if canSubmit { submit() } }
                    .padding(.horizontal, 16).frame(minHeight: 50)
            }
            .disabled(busy)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle.fill").font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: submit) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(UX.onAccent) }
                    Text(busy ? "正在登录…" : "继续")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(!canSubmit)
            Label("你的账号信息仅保存在这台设备上。", systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .onAppear { if email.isEmpty { focus = .email } else if password.isEmpty { focus = .password } }
    }

    /// Signing in again without a code makes Apple send a new one.
    private func resendCode() {
        guard !busy else { return }
        busy = true; failure = nil; code = ""
        loginTask = Task {
            defer { busy = false; loginTask = nil }
            do {
                try await apple.login(email: email, password: password, code: "", useCache: store.settings.useSignerCache)
                // Signed in without a code this time.
                password = ""; UX.success(); onSignedIn?(); dismiss()
            } catch AppleLoginError.verificationRequired {
                failure = nil
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil; busy = true; failure = nil
        loginTask = Task {
            defer { busy = false; loginTask = nil }
            do {
                try await apple.login(email: email, password: password, code: verifying ? code : "", useCache: store.settings.useSignerCache)
                password = ""; code = ""; UX.success(); onSignedIn?(); dismiss()
            } catch AppleLoginError.verificationRequired {
                verifying = true; code = ""
            } catch is CancellationError {
                failure = AppText.text("登录已取消，可以重新尝试。")
            } catch {
                failure = error.localizedDescription
                code = ""
            }
        }
    }
}

/// Re-verification of the current account (no password), same two-factor page.
struct ExistingAccountVerificationView: View {
    /// When Apple last signed in without a code here. Asked again soon after,
    /// signing in silently evidently did not satisfy Apple: stop and ask for a code.
    @MainActor private static var lastSilentSignIn: Date?
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.dismiss) private var dismiss
    let accountID: String
    let onVerified: () -> Void
    @State private var code = ""
    @State private var busy = false
    @State private var issue: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VerificationStep(account: accountID, code: $code, busy: busy, issue: issue,
                                 submitTitle: AppText.text("验证并继续"), sent: sent, resend: requestCode, submit: verify)
                    .frame(maxWidth: 460).padding(24).frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
            }
            .task { requestCode() }
        }
    }

    /// Makes Apple send the code this page asks for. If Apple signs in without
    /// one, the action that needed verification simply continues.
    private func requestCode() {
        guard !busy else { return }
        busy = true; issue = nil; sent = false
        Task {
            defer { busy = false }
            do {
                if try await apple.requestVerificationCode(expectedID: accountID, useCache: store.settings.useSignerCache) {
                    sent = true
                } else if let last = Self.lastSilentSignIn, Date().timeIntervalSince(last) < 60 {
                    // Signed in, yet the store still wants verification: only a code helps.
                    Self.lastSilentSignIn = nil
                    sent = true
                    issue = AppText.text("Apple 仍要求验证此账号。请在登录了该账户的设备上打开「设置 › [你的姓名] › 登录与安全 › 获取验证码」，输入显示的验证码。")
                } else {
                    Self.lastSilentSignIn = Date()
                    UX.success(); onVerified(); dismiss()
                }
            } catch is CancellationError {
                issue = AppText.text("请求已取消，可以点按「重新发送验证码」"); sent = true
            } catch {
                issue = error.localizedDescription; sent = true
            }
        }
    }

    private func verify() {
        guard !busy, code.count == 6 else { return }
        busy = true; issue = nil
        Task {
            defer { busy = false }
            do {
                try await apple.verifyCurrentAccount(code: code, expectedID: accountID, useCache: store.settings.useSignerCache)
                code = ""; UX.success()
                onVerified()
                dismiss()
            } catch is CancellationError {
                issue = AppText.text("验证已取消，请重试")
            } catch {
                issue = error.localizedDescription
                code = ""
            }
        }
    }
}
