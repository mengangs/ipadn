import SwiftUI

/// Optional-password full backup export sheet including cookies, tokens, passwords, and device identity.
struct BackupExportSheet: View {
    let accountCount: Int
    let signedInCount: Int
    let deviceGUID: String
    let onExport: (String?) throws -> URL
    let onPreparedFile: (URL) -> Void
    let onCancel: () -> Void

    private enum PasswordFocus: Hashable {
        case primary, confirm
    }

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var localError: String?
    @FocusState private var focusedField: PasswordFocus?

    private var passwordsMismatch: Bool {
        !password.isEmpty && !confirmPassword.isEmpty && password != confirmPassword
    }

    private var canSubmit: Bool {
        password.isEmpty || password == confirmPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("应用与设置", value: AppText.text("设置、版本来源、关注与搜索"))
                    LabeledContent("Apple 账号") {
                        Text(accountSummary)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("设备标识") {
                        Text(deviceGUID)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("完整备份内容")
                } footer: {
                    Text("包含设置、版本来源、关注与应用记录、最近搜索、Apple 账号会话（Cookie、令牌与密码）及设备商店凭证；不包含已下载的安装包。")
                }

                Section {
                    SecureField("设置加密密码（留空则明文导出）", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .primary)
                        .onSubmit {
                            if !password.isEmpty { focusedField = .confirm }
                        }
                        .accessibilityIdentifier("settings.backup.export-password")
                    if !password.isEmpty {
                        SecureField("再次输入密码确认", text: $confirmPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                            .submitLabel(.done)
                            .focused($focusedField, equals: .confirm)
                            .accessibilityIdentifier("settings.backup.export-password-confirm")
                    }
                    if passwordsMismatch {
                        Text("两次输入的密码不一致")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let localError {
                        Text(localError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("文件保护（可选）")
                } footer: {
                    Text(password.isEmpty
                         ? "留空将直接导出明文 JSON（含 Cookie、登录令牌与账号密码），请仅保存在安全可信的位置。"
                         : "将使用 AES-256-GCM 加密整个备份文件，导入时需要输入此密码解锁。")
                }
            }
            .navigationTitle("导出备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(password.isEmpty ? "直接导出" : "加密并导出") {
                        localError = nil
                        do {
                            let url = try onExport(password.isEmpty ? nil : password)
                            onPreparedFile(url)
                        } catch {
                            localError = error.localizedDescription
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("settings.backup.export-confirm")
                }
            }
        }
    }

    private var accountSummary: String {
        guard accountCount > 0 else { return AppText.text("无账号") }
        if signedInCount > 0 {
            return AppText.text("\(accountCount) 个（含 \(signedInCount) 个 Cookie 与令牌会话）")
        }
        return AppText.text("\(accountCount) 个（仅账号配置）")
    }
}

/// Password unlock prompt shown when importing an AES-256-GCM encrypted backup file.
struct EncryptedBackupPasswordSheet: View {
    let onUnlock: (String) throws -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("输入备份密码", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .submitLabel(.done)
                        .accessibilityIdentifier("settings.backup.unlock-password")
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("输入解锁密码")
                } footer: {
                    Text("此备份已使用 AES-256-GCM 加密，请输入导出时设置的密码以解密并预览内容。")
                }
            }
            .navigationTitle("解锁加密备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解锁") {
                        errorMessage = nil
                        do {
                            try onUnlock(password)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("settings.backup.unlock-confirm")
                }
            }
        }
    }
}

/// Confirmation and conflict-handling sheet for unified full/legacy app and Apple ID backups.
struct UnifiedBackupImportSheet: View {
    let preview: UnifiedBackupPreview
    let existingAccounts: [AppleAccount]
    @Binding var policy: AccountBackupConflictPolicy
    @Binding var restoreDeviceIdentity: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("备份内容", value: summaryText)
                    if !preview.accountEntries.isEmpty {
                        LabeledContent("包含账号数", value: "\(preview.accountEntries.count)")
                        LabeledContent("会话凭据", value: credentialSummaryText)
                    }
                    if preview.wasEncrypted {
                        LabeledContent("文件加密", value: AppText.text("AES-256-GCM 已解密"))
                    }
                    if let guid = preview.deviceGUID {
                        LabeledContent("备份设备标识") {
                            Text(guid)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if preview.createdDate != nil {
                        LabeledContent("导出时间") {
                            Text(preview.created.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("文件信息")
                } footer: {
                    Text(footerText)
                }

                if preview.deviceGUID != nil || preview.hasStoreProofs {
                    Section {
                        Toggle("恢复设备标识（GUID）与商店凭证", isOn: $restoreDeviceIdentity)
                            .accessibilityIdentifier("settings.backup.restore-device-identity")
                    } header: {
                        Text("设备与会话一致性")
                    } footer: {
                        Text("建议保持开启。恢复后可直接使用备份中的 Cookie 与令牌下载或获取版本列表，无需逐个重新登录。")
                    }
                }

                if preview.duplicateAccountCount > 0 {
                    Section {
                        Picker("重复账号处理", selection: $policy) {
                            Text("仅新增缺失账号（保留本机已有会话）").tag(AccountBackupConflictPolicy.skipExisting)
                            Text(preview.includesSensitiveCredentials
                                 ? "使用备份覆盖已有账号（含 Cookie 与令牌）"
                                 : "更新已有账号名称与地区（保留本机凭据）")
                            .tag(AccountBackupConflictPolicy.overwriteExisting)
                        }
                        .pickerStyle(.inline)
                        .accessibilityIdentifier("settings.backup.conflict-policy")
                    } header: {
                        Text("发现 \(preview.duplicateAccountCount) 个本机已存在账号")
                    } footer: {
                        Text(preview.includesSensitiveCredentials
                             ? "选择仅新增时不会覆盖本机已登录账号；选择覆盖将使用备份中的 Cookie、令牌与密码替换已有账号。"
                             : "导入的旧版非敏感备份不会清除或覆盖本机已登录账号的密码、令牌或会话状态。")
                    }
                }

                if !preview.accountEntries.isEmpty {
                    Section {
                        ForEach(preview.accountEntries) { entry in
                            let isExisting = existingAccounts.contains(where: {
                                AppleAccount.normalizedIdentifier($0.id) == AppleAccount.normalizedIdentifier(entry.id)
                            })
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name.isEmpty ? entry.id : entry.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(entry.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        if let country = StoreService.country(forStorefront: entry.storeFront) {
                                            Text("商店地区：\(country)")
                                        }
                                        Text(entry.hasValidSession
                                             ? (entry.hasCookie ? "含 Cookie · 令牌已就绪" : "含令牌 · 会话已就绪")
                                             : "无凭据 · 需重新登录")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 8)
                                TagBadge(
                                    text: isExisting ? "已存在" : "新增",
                                    tint: isExisting ? .secondary : UX.tint
                                )
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("账号列表")
                    }
                }
            }
            .navigationTitle("导入备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入", action: onConfirm)
                        .accessibilityIdentifier("settings.backup.confirm")
                }
            }
        }
    }

    private var summaryText: String {
        switch (preview.includesSettingsAndFollowed, preview.accountEntries.isEmpty) {
        case (true, false):
            return AppText.text("设置、关注与 \(preview.accountEntries.count) 个账号")
        case (true, true):
            return AppText.text("设置、版本来源与关注")
        case (false, _):
            return AppText.text("仅账号配置（不含密码/令牌）")
        }
    }

    private var credentialSummaryText: String {
        if preview.credentialReadyCount > 0 {
            return AppText.text("含 Cookie 与会话令牌（\(preview.credentialReadyCount)/\(preview.accountEntries.count)）")
        }
        return AppText.text("仅账号配置（无 Cookie/令牌）")
    }

    private var footerText: String {
        if !preview.includesSettingsAndFollowed {
            return AppText.text("导入的账号在本机需要前往「账号」页输入密码完成登录后才可用于下载或同步已购项目。")
        }
        if preview.includesSensitiveCredentials {
            return AppText.text("当前设置会被备份中的设置替换，关注的应用会合并；带会话的账号将连同 Cookie 与登录令牌直接恢复，已下载的安装包不受影响。")
        }
        return AppText.text("当前设置会被备份中的设置替换，关注的应用会合并；账号配置仅含标识与地区（不含密码/令牌/Cookie），导入的新账号需在「账号」页重新登录后才可下载。已下载的安装包不受影响。")
    }
}

private extension UnifiedBackupPreview {
    var createdDate: Date? {
        created > Date(timeIntervalSince1970: 946_684_800) ? created : nil
    }
}
