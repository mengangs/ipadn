import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @State private var deleting: AppleAccount?
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 36)).foregroundStyle(.tint)
                    Text(apple.active?.name ?? "管理你的 Apple 账号").font(.title2.bold())
                    Text(apple.active?.id ?? "账号用于获取你有许可的应用安装包。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    NavigationLink { LoginView() } label: { Label("添加账号", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                }.padding(.vertical, 12)
            }
            if let error = apple.accountStorageError { Section { StatusBanner(text: error, symbol: "exclamationmark.triangle") } }
            if !apple.accounts.isEmpty {
                Section("已保存账号") {
                    ForEach(apple.accounts) { account in
                        Button { apple.select(account.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(account.name).font(.headline).foregroundStyle(.primary)
                                    Text(account.id).font(.caption).foregroundStyle(.secondary)
                                    Text("Storefront \(account.storeFront)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if account.id == apple.activeID { Image(systemName: "checkmark.circle.fill") }
                            }.padding(.vertical, 4)
                        }
                        .swipeActions { Button("移除", role: .destructive) { deleting = account } }
                    }
                    if apple.active != nil { Button("退出当前账号") { apple.select(nil) } }
                }
            }
            Section {
                NavigationLink { SettingsView() } label: { Label("设置与扩展", systemImage: "slider.horizontal.3") }
            }
            Section {
                StatusBanner(text: "密码、Cookie 和 Token 保存在此设备的 Keychain 中。移除账号会清除凭据和已购缓存；下载文件单独保留。")
            }.listRowBackground(Color.clear)
        }
        .navigationTitle("账号")
        .confirmationDialog("移除 \(deleting?.id ?? "")？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("移除账号", role: .destructive) {
                guard let id = deleting?.id else { return }
                do { try store.deleteAccount(id) } catch { store.errorMessage = error.localizedDescription }
                deleting = nil
            }
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
    @FocusState private var focus: Field?
    private enum Field { case email, password, code }
    var body: some View {
        Form {
            Section {
                Label(verifying ? "验证你的账号" : "连接 Apple 账号", systemImage: verifying ? "lock.shield" : "person.crop.circle")
                    .font(.title2.bold()).padding(.vertical, 8)
                Text(verifying ? "在受信任设备上允许登录，输入最新验证码继续。" : "登录后可查看已购记录，获取你拥有许可的安装包。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("账号信息") {
                TextField("Apple 账号", text: $email).textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focus, equals: .email)
                    .disabled(busy || verifying).submitLabel(.next).onSubmit { focus = .password }
                SecureField("账号密码", text: $password).textContentType(.password)
                    .focused($focus, equals: .password).disabled(busy || verifying).submitLabel(.go)
                    .onSubmit { if !email.isEmpty && !password.isEmpty { submit() } }
            }
            if verifying {
                Section {
                    TextField("6 位验证码", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                        .font(.title2.monospacedDigit()).focused($focus, equals: .code).disabled(busy)
                        .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                    Button("修改账号或密码") { verifying = false; code = ""; failure = nil; focus = .password }.disabled(busy)
                } header: { Text("双重认证") } footer: {
                    Text("验证码仅用于本次登录，不会保存。未收到时，可在 Apple 受信任设备的账号设置中获取验证码。")
                }
            }
            if let failure {
                Section { Label(failure, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red) }
            }
            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if busy { ProgressView() }
                        Text(busy ? "正在验证…" : verifying ? "验证并登录" : "继续登录").fontWeight(.semibold)
                        Spacer()
                    }.padding(.vertical, 6)
                }.disabled(busy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || (verifying && code.count != 6))
            } footer: { Text("凭据保存在此设备的钥匙串中。验证期间请保持应用在前台。") }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("添加账号").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focus = nil } } }
    }
    private func submit() {
        guard !busy else { return }
        focus = nil; busy = true; failure = nil
        Task {
            defer { busy = false }
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
