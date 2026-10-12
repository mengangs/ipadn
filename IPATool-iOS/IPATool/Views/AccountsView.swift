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
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                TextField("Apple 账号", text: $email).textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password).textContentType(.password)
                TextField("双重认证验证码（如需要）", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
            } header: { Text("登录 Apple 账号") } footer: {
                Text("使用原脚本的 Apple 登录协议和本地 SAP 引擎。签名阶段请保持应用在前台；验证码不会保存。")
            }
            if let failure = failure { Section { Text(failure).font(.footnote).foregroundStyle(.red).textSelection(.enabled) } }
            Section {
                Button {
                    busy = true; failure = nil
                    Task {
                        defer { busy = false }
                        do {
                            try await apple.login(email: email, password: password, code: code, useCache: store.settings.useSignerCache)
                            password = ""; code = ""; dismiss()
                        } catch { failure = error.localizedDescription; code = "" }
                    }
                } label: {
                    HStack { Spacer(); if busy { ProgressView() }; Text(busy ? "正在登录…" : "登录并保存"); Spacer() }
                }.disabled(busy || email.isEmpty || password.isEmpty)
            }
        }.navigationTitle("添加账号").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
    }
}
