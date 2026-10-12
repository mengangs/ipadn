import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @State private var deleting: AppleAccount?
    @State private var signingOut = false
    var body: some View {
        List {
            if let error = apple.accountStorageError { Section { InlineIssue(message: error) } }
            ForEach(apple.accounts) { account in
                Section {
                    Button {
                        guard apple.activeID != account.id else { return }
                        apple.select(account.id); UX.feedback()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.name.isEmpty ? account.id : account.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                if !account.name.isEmpty { Text(account.id).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 8)
                            if account.id == apple.activeID {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).accessibilityLabel("当前账号")
                            }
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityHint(account.id == apple.activeID ? "当前下载账号" : "切换到此账号")
                    .accessibilityIdentifier("account." + account.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("移除") { deleting = account }.tint(.red) }
                } header: {
                    if account.id == apple.accounts.first?.id { Text("Apple 账号") }
                }
            }
            Section {
                NavigationLink { LoginView() } label: { Label("添加账号", systemImage: "plus") }
            } footer: {
                Text(apple.accounts.isEmpty ? "添加账号后可同步已购应用和下载。" : "勾选的是当前下载账号。点按切换，左滑移除。")
            }
            Section { NavigationLink { SettingsView() } label: { Label("设置", systemImage: "gearshape") }.accessibilityIdentifier("accounts.settings") }
            if apple.active != nil {
                Section { Button("退出当前账号", role: .destructive) { signingOut = true } }
            }
        }
        .toolPage().navigationTitle("账号").navigationBarTitleDisplayMode(.inline)
        .actionConfirmation(isPresented: $signingOut, title: "退出当前账号？", message: "账号仍保存在本机，可以随时切换回来。", confirmTitle: "退出账号") { apple.select(nil) }
        .actionConfirmation(isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), title: "移除账号？", message: "清除此账号的本机登录信息与已购记录，保留已下载的文件。", confirmTitle: "移除账号") {
            guard let id = deleting?.id else { return }
            do { try store.deleteAccount(id); store.infoMessage = "已移除账号" } catch { store.errorMessage = error.localizedDescription }
            deleting = nil
        }
    }
}

struct LoginView: View {
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
    private enum Field { case email, password, code }
    var body: some View {
        Form {
            Section {
                TextField("邮箱或手机号", text: $email).textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focus, equals: .email)
                    .disabled(busy || verifying).submitLabel(.next).onSubmit { focus = .password }
                SecureField("账号密码", text: $password).textContentType(.password)
                    .focused($focus, equals: .password).disabled(busy || verifying).submitLabel(.go)
                    .onSubmit { if !email.isEmpty && !password.isEmpty { submit() } }
            } header: { Text("Apple 账号") } footer: {
                Text(verifying ? "请在受信任设备上允许登录，再输入验证码。" : "登录用于同步已购记录与下载授权。")
            }
            if verifying {
                Section {
                    TextField("6 位验证码", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                        .font(.title2.monospacedDigit()).focused($focus, equals: .code).disabled(busy).frame(minHeight: 48).onAppear { focus = .code }
                        .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                    Button("修改账号或密码") { verifying = false; code = ""; failure = nil; focus = .password }.disabled(busy)
                } header: { Text("双重认证") } footer: {
                    Text("验证码仅用于本次登录，不会保存。未收到时，可在 Apple 受信任设备的账号设置中获取验证码。")
                }
            }
            if let failure {
                Section { InlineIssue(message: failure) }
            }
            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if busy { ProgressView() }
                        Text(busy ? "正在验证…" : verifying ? "验证并登录" : "继续登录").fontWeight(.semibold)
                        Spacer()
                    }.padding(.vertical, 6)
                }.buttonStyle(MonochromeButtonStyle()).controlSize(.large).disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || (verifying && code.count != 6))
            } footer: { Text("凭据保存在此设备的钥匙串中。验证期间请保持应用在前台。") }
        }
        .toolPage()
        .navigationTitle("添加账号").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            if busy { ToolbarItem(placement: .topBarTrailing) { Button("取消") { loginTask?.cancel() } } }
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focus = nil } } }
        .onDisappear { loginTask?.cancel() }
    }
    private func submit() {
        guard !busy else { return }
        focus = nil; busy = true; failure = nil
        loginTask = Task {
            defer { busy = false; loginTask = nil }
            do {
                try await apple.login(email: email, password: password, code: verifying ? code : "", useCache: store.settings.useSignerCache)
                password = ""; code = ""; dismiss()
            } catch AppleLoginError.verificationRequired {
                verifying = true; code = ""; focus = .code
            } catch is CancellationError {
                failure = "登录已取消，可以重新尝试。"
            } catch {
                failure = error.localizedDescription
                code = ""
                if verifying { focus = .code }
            }
        }
    }
}

struct ExistingAccountVerificationView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.dismiss) private var dismiss
    let accountID: String
    let onVerified: () -> Void
    @State private var code = ""
    @State private var busy = false
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Apple 要求重新验证当前账号。请在受信任设备上允许登录，输入收到的六位验证码。")
                    Text(accountID).font(.footnote).foregroundStyle(.secondary)
                    TextField("六位验证码", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .onChange(of: code) { _, value in
                            code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        }
                        .accessibilityIdentifier("apple.verification.code")
                } header: {
                    Text("双重认证")
                } footer: {
                    Text("验证码只用于本次验证，不会保存。无需再次填写密码。")
                }
                if let issue { Section { InlineIssue(message: issue) } }
                Section {
                    Button {
                        guard !busy else { return }
                        busy = true; issue = nil
                        Task {
                            defer { busy = false }
                            do {
                                try await apple.verifyCurrentAccount(code: code, expectedID: accountID,
                                                                     useCache: store.settings.useSignerCache)
                                code = ""
                                onVerified()
                                dismiss()
                            } catch is CancellationError {
                                issue = "验证已取消，请重试"
                            } catch {
                                issue = error.localizedDescription
                                code = ""
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() }
                            Text(busy ? "正在验证…" : "验证并继续下载")
                            Spacer()
                        }
                    }
                    .disabled(busy || code.count != 6)
                    .accessibilityIdentifier("apple.verification.submit")
                }
            }
            .navigationTitle("验证 Apple 账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(busy)
                }
            }
        }
    }
}
