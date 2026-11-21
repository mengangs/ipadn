import Foundation
import Combine

@MainActor
final class AppleService: ObservableObject {
    @Published private(set) var accounts: [AppleAccount] = []
    @Published private(set) var activeID: String?
    @Published var accountStorageError: String?
    let signer: SAPSigner
    private var loginInProgress = false
    private(set) var loginDiagnostic = "No login attempted in this session."
    /// Active signed-in account with valid session credentials.
    /// Imported placeholder profiles without tokens never resolve as `active`.
    var active: AppleAccount? { accounts.first { $0.id == activeID && $0.hasValidSession } }
    var guid: String {
        if let value = LocalResources.defaults.string(forKey: LocalResources.guid) { return value }
        let value = Self.randomGUID()
        LocalResources.defaults.set(value, forKey: LocalResources.guid)
        return value
    }
    nonisolated static func randomGUID() -> String {
        (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }
    /// Replaces the identifier Apple sees for this device (专业模式).
    func setGUID(_ value: String) throws {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard id.count == 12, id.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ToolError.message(AppText.text("设备标识需要是 12 位十六进制字符（0–9、A–F）"))
        }
        objectWillChange.send()
        LocalResources.defaults.set(id, forKey: LocalResources.guid)
    }

    init(signer: SAPSigner) {
        self.signer = signer
        do { accounts = try KeychainStore.load() } catch { accountStorageError = error.localizedDescription }
        activeID = LocalResources.defaults.string(forKey: LocalResources.activeAccount)
        if active?.hasValidSession != true { activeID = nil }
    }

    /// Session cookies updated by store responses, by account, not yet saved.
    private var liveCookies: [String: String] = [:]
    private var commercePods: [String: String] = [:]
    private var cookiesSavedAt = Date.distantPast

    func login(email: String, password: String, code: String, useCache: Bool) async throws {
        // Someone is waiting on sign-in; it goes ahead of background signing.
        try await SAPSigner.$userInitiated.withValue(true) {
            try await performLogin(email: email, password: password, code: code, useCache: useCache)
        }
    }
    private func performLogin(email: String, password: String, code: String, useCache: Bool) async throws {
        if accountStorageError != nil {
            do { accounts = try KeychainStore.load(); accountStorageError = nil }
            catch {
                loginDiagnostic = "stage=account-storage; " + AppleAuthentication.errorCode(error)
                throw ToolError.message(AppText.text("本机账号记录无法读取，原记录已保留。请在设置中导出诊断信息。"))
            }
        }
        guard !loginInProgress else { throw ToolError.message(AppText.text("另一个账号正在登录，请稍后重试")) }
        loginInProgress = true
        defer { loginInProgress = false }
        let initialAccount = activeID
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { throw ToolError.message(AppText.text("请填写 Apple 账号和密码")) }
        guard code.isEmpty || (code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber })) else { throw ToolError.message(AppText.text("请输入 6 位数字验证码")) }
        var stage = "configuration"
        loginDiagnostic = "stage=configuration"
        let raw: [String: Any]
        let response: HTTPURLResponse
        do {
            let deviceID = guid
            let endpoint = try await AppleAuthentication.configuration(guid: deviceID,
                send: { try await HTTPClient.shared.request($0, headers: ["Accept": "application/xml"]) },
                report: { self.loginDiagnostic = $0 })
            stage = "signing"
            loginDiagnostic = "stage=signing"
            let body = try AppleLoginResponse.body(email: email, password: password, code: code, guid: deviceID)
            let signature = try await signer.sign(body, guid: deviceID, useCache: useCache, cacheSignature: false)
            var headers = ["Content-Type": "application/x-apple-plist",
                           "X-Apple-ActionSignature": signature]
            if let storefront = AppleLoginResponse.phoneNumberStorefront(email) { headers["X-Apple-Store-Front"] = storefront }
            stage = "authentication"
            let result = try await AppleAuthentication.withStoreProof(
                endpoint: endpoint,
                baseHeaders: headers,
                loadProof: { try await self.signer.storeProofHeaders(guid: deviceID, useCache: useCache) },
                provisionProof: { challenge in
                    stage = "store-provisioning"
                    self.loginDiagnostic = "stage=store-provisioning"
                    let provisioned = try await self.signer.provisionStoreProof(challenge: challenge, guid: deviceID, useCache: useCache)
                    stage = "authentication"
                    return provisioned
                },
                resetProof: { self.signer.resetStoreProof(guid: deviceID) },
                execute: { headerProvider in
                    try await AppleAuthentication.authenticate(
                        endpoint: endpoint, body: body,
                        makeHeaders: { try await headerProvider(endpoint) },
                        send: { url, body, headers in
                            try await HTTPClient.shared.request(
                                url, method: "POST", body: body, headers: headers,
                                appleRedirects: true, authentication: true,
                                refreshHeaders: headerProvider
                            )
                        },
                        report: { self.loginDiagnostic = $0 }
                    )
                }
            )
            raw = result.0; response = result.1
        } catch is CancellationError {
            loginDiagnostic = "stage=\(stage); cancelled"
            throw CancellationError()
        } catch {
            if stage == "signing" || stage == "store-provisioning" {
                loginDiagnostic = "stage=\(stage); " + AppleAuthentication.errorCode(error)
            }
            if stage == "configuration" {
                throw ToolError.message(AppText.text("无法获取 Apple 登录配置，请检查网络后重试。仍然失败可在设置中导出诊断信息。"))
            }
            throw error
        }
        if let failure = AppleLoginResponse.failure(raw, submittedCode: !code.isEmpty) {
            if let codeToken = RequestFailureLog.safeDiagnosticToken(plistString(raw["failureType"])) {
                loginDiagnostic += "; code=" + codeToken
            }
            loginDiagnostic += "; result=apple-rejected-or-verification-required"
            if (failure as? AppleLoginError) != .verificationRequired {
                RequestFailureLog.recordAppleFailure(response.url, response: raw, stage: "login")
            }
            throw failure
        }
        var cookieHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields { cookieHeaders[String(describing: key)] = String(describing: value) }
        let cookies = response.url.map { HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: $0) } ?? []
        let cookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        var resolvedDSID = plistString(raw["dsPersonId"])
        if resolvedDSID.isEmpty,
           let headerDSID = response.value(forHTTPHeaderField: "X-Dsid")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !headerDSID.isEmpty, headerDSID.allSatisfy({ $0.isASCII && $0.isNumber }) {
            resolvedDSID = headerDSID
        }
        if resolvedDSID.isEmpty {
            for item in cookies {
                for prefix in ["mz_at0-", "mz_at_ssl-"] where item.name.hasPrefix(prefix) {
                    let candidate = String(item.name.dropFirst(prefix.count))
                    if !candidate.isEmpty, candidate.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        resolvedDSID = candidate; break
                    }
                }
                if !resolvedDSID.isEmpty { break }
            }
        }
        let info = raw["accountInfo"] as? [String: Any] ?? [:]
        let reportedID = plistString(info["appleId"])
        let passwordToken = plistString(raw["passwordToken"])
        let id = reportedID.isEmpty && !resolvedDSID.isEmpty && !passwordToken.isEmpty ? email : reportedID
        guard !id.isEmpty else {
            throw ToolError.message(AppText.text("Apple 未返回完整登录信息，请重试"))
        }
        guard !resolvedDSID.isEmpty, !passwordToken.isEmpty else {
            throw ToolError.message(AppText.text("Apple 返回的登录凭据不完整，请重新登录"))
        }
        let address = info["address"] as? [String: Any] ?? [:]
        let name = [plistString(address["firstName"]), plistString(address["lastName"])].filter { !$0.isEmpty }.joined(separator: " ")
        let normalizedNewID = AppleAccount.normalizedIdentifier(id)
        let existingIndex = accounts.firstIndex { AppleAccount.normalizedIdentifier($0.id) == normalizedNewID }
        let existingAccount = existingIndex.map { accounts[$0] }
        let setStore = response.value(forHTTPHeaderField: "X-Set-Apple-Store-Front")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestStore = response.value(forHTTPHeaderField: "X-Apple-Request-Store-Front")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // `X-Apple-Request-Store-Front` is only an echo of the client hint;
        // preserve a saved/corrected storefront for the same DSID unless Apple
        // explicitly updates it via `X-Set-Apple-Store-Front` (ipatool).
        let existingSameDSID = existingAccount?.dsid == resolvedDSID ? existingAccount : nil
        let fullStore: String
        if !setStore.isEmpty {
            fullStore = setStore
        } else if let saved = existingSameDSID, !saved.fullStoreFront.isEmpty {
            fullStore = saved.fullStoreFront
        } else if let saved = existingSameDSID, !saved.storeFront.isEmpty {
            fullStore = saved.storeFront
        } else {
            fullStore = requestStore
        }
        let resolvedStoreFront = StoreService.storefrontIdentifier(fullStore)
        let capturedPod = Self.capturePod(from: response, current: "")
        if !capturedPod.isEmpty { commercePods[resolvedDSID] = capturedPod }
        let account = AppleAccount(id: id, name: name.isEmpty ? (existingAccount?.name.isEmpty == false ? existingAccount!.name : id) : name,
                                   password: password, cookie: cookie,
                                   dsid: resolvedDSID, passwordToken: passwordToken,
                                   storeFront: resolvedStoreFront, fullStoreFront: fullStore)
        var updated = accounts
        if let existingIndex {
            updated[existingIndex] = account
            // Drop any duplicate alias entries if present.
            updated = updated.enumerated().compactMap { offset, item in
                (offset == existingIndex || AppleAccount.normalizedIdentifier(item.id) != normalizedNewID) ? item : nil
            }
        } else {
            updated.insert(account, at: 0)
        }
        try Task.checkCancellation()
        guard activeID == initialAccount else { throw ToolError.message(AppText.text("账号已切换，已停止保存本次登录")) }
        do { try KeychainStore.save(updated) }
        catch {
            loginDiagnostic += "; stage=account-save; " + AppleAuthentication.errorCode(error)
            throw error
        }
        liveCookies[id] = nil
        if let oldID = existingAccount?.id, oldID != id { liveCookies[oldID] = nil }
        accounts = updated; select(id); accountStorageError = nil
        loginDiagnostic += "; result=signed-in"
    }

    func select(_ id: String?) {
        if let id {
            guard let account = accounts.first(where: { $0.id == id }), account.hasValidSession else { return }
            activeID = account.id
        } else {
            activeID = nil
        }
        LocalResources.defaults.set(activeID, forKey: LocalResources.activeAccount)
        signer.clearCache()
    }
    func remove(_ id: String) throws {
        let updated = accounts.filter { $0.id != id }
        try KeychainStore.save(updated)
        accounts = updated
        if activeID == id { select(nil) }
    }

    /// Snapshot of freshest in-memory cookies for full backup export.
    func flushedAccountsForBackup() -> [AppleAccount] {
        saveLiveCookies()
        guard !liveCookies.isEmpty else { return accounts }
        return accounts.map { account in
            var copy = account
            if let fresh = liveCookies[account.id] { copy.cookie = fresh }
            return copy
        }
    }

    struct AccountBackupImportOutcome {
        let merge: AccountBackupService.MergeResult
        let restoredDeviceIdentity: Bool
        let addedNeedsReauthCount: Int
        let restoredSessionCount: Int
    }

    @discardableResult
    func importAccountBackup(
        entries: [AccountSessionEntry],
        preferredActiveID: String? = nil,
        deviceGUID: String? = nil,
        storeProofRecords: [String: StoreProofRecord]? = nil,
        policy: AccountBackupConflictPolicy = .skipExisting,
        restoreDeviceIdentity: Bool = false
    ) throws -> AccountBackupImportOutcome {
        let hadValidLocalSession = accounts.contains(where: \.hasValidSession)
        let merged = AccountBackupService.merge(entries: entries, into: accounts, policy: policy)
        if !merged.addedIDs.isEmpty || !merged.updatedIDs.isEmpty || merged.mergedAccounts.count != accounts.count {
            try KeychainStore.save(merged.mergedAccounts)
            for id in merged.updatedIDs + merged.addedIDs {
                liveCookies.removeValue(forKey: id)
            }
            accounts = merged.mergedAccounts
        }

        let currentStillValid = activeID.flatMap { id in accounts.first(where: { $0.id == id && $0.hasValidSession }) } != nil
        if !currentStillValid || policy == .overwriteExisting {
            if let preferred = preferredActiveID,
               let match = accounts.first(where: {
                   AppleAccount.normalizedIdentifier($0.id) == AppleAccount.normalizedIdentifier(preferred) && $0.hasValidSession
               }) {
                select(match.id)
            } else if !currentStillValid,
                      let firstValid = accounts.first(where: \.hasValidSession) {
                select(firstValid.id)
            } else if !currentStillValid {
                activeID = nil
                LocalResources.defaults.set(nil, forKey: LocalResources.activeAccount)
            }
        }

        var didRestoreDeviceIdentity = false
        if restoreDeviceIdentity {
            if let importedProofs = storeProofRecords, !importedProofs.isEmpty {
                signer.restoreStoreProofRecords(
                    importedProofs,
                    preferImported: policy == .overwriteExisting || !hadValidLocalSession
                )
                didRestoreDeviceIdentity = true
            }
            if let targetGUID = AccountBackupService.normalizedDeviceGUID(deviceGUID) {
                if targetGUID != guid {
                    try setGUID(targetGUID)
                    signer.clearCache()
                }
                didRestoreDeviceIdentity = true
            }
        }

        accountStorageError = nil
        let touchedKeys = Set((merged.addedIDs + merged.updatedIDs).map(AppleAccount.normalizedIdentifier))
        let touchedAccounts = accounts.filter { touchedKeys.contains(AppleAccount.normalizedIdentifier($0.id)) }
        let needsReauthCount = touchedAccounts.filter(\.needsReauthentication).count
        let sessionCount = touchedAccounts.filter(\.hasValidSession).count
        return AccountBackupImportOutcome(
            merge: merged,
            restoredDeviceIdentity: didRestoreDeviceIdentity,
            addedNeedsReauthCount: needsReauthCount,
            restoredSessionCount: sessionCount
        )
    }

    func importAccountProfiles(
        _ entries: [AccountProfileEntry],
        policy: AccountBackupConflictPolicy = .skipExisting
    ) throws -> AccountBackupService.MergeResult {
        try importAccountBackup(
            entries: entries.map(AccountSessionEntry.init(from:)),
            policy: policy,
            restoreDeviceIdentity: false
        ).merge
    }

    func importAccountProfiles(
        _ backup: AccountProfileBackup,
        policy: AccountBackupConflictPolicy = .skipExisting
    ) throws -> AccountBackupService.MergeResult {
        try importAccountBackup(
            entries: backup.accounts.map(AccountSessionEntry.init(from:)),
            preferredActiveID: backup.preferredActiveID,
            policy: policy,
            restoreDeviceIdentity: false
        ).merge
    }

    private func requireSignedInAccount(missingMessage: String = AppText.text("请先登录 Apple 账号")) throws -> AppleAccount {
        guard let account = active else { throw ToolError.message(missingMessage) }
        guard account.hasValidSession else { throw AppleAuthError.reauthenticationRequired }
        return account
    }
    /// Apple sends a code to trusted devices only when it is asked to sign in
    /// with the password and no code. Store requests that need verification
    /// (claiming an app, a download) never send one, so the code page must ask
    /// first. Returns false when Apple signed in without needing a code.
    func requestVerificationCode(expectedID: String, useCache: Bool) async throws -> Bool {
        try await SAPSigner.$userInitiated.withValue(true) { try await requestCode(expectedID: expectedID, useCache: useCache) }
    }
    private func requestCode(expectedID: String, useCache: Bool) async throws -> Bool {
        guard let account = active, account.id == expectedID else {
            throw ToolError.message(AppText.text("验证期间账号已改变，请重新选择下载账号"))
        }
        guard !account.password.isEmpty else { throw AppleAuthError.reauthenticationRequired }
        do {
            try await login(email: account.id, password: account.password, code: "", useCache: useCache)
            return false
        } catch AppleLoginError.verificationRequired {
            return true
        }
    }

    func verifyCurrentAccount(code: String, expectedID: String, useCache: Bool) async throws {
        guard let account = active, account.id == expectedID else {
            throw ToolError.message(AppText.text("验证期间账号已改变，请重新选择下载账号"))
        }
        try await login(email: account.id, password: account.password, code: code, useCache: useCache)
    }

    func refresh(_ account: AppleAccount, useCache: Bool) async throws -> AppleAccount {
        guard let currentActive = activeID,
              AppleAccount.normalizedIdentifier(currentActive) == AppleAccount.normalizedIdentifier(account.id) else {
            throw ToolError.message(AppText.text("账号已切换，请重新执行操作"))
        }
        guard !account.password.isEmpty else { throw AppleAuthError.reauthenticationRequired }
        try await login(email: account.id, password: account.password, code: "", useCache: useCache)
        guard let refreshed = active,
              AppleAccount.normalizedIdentifier(refreshed.id) == AppleAccount.normalizedIdentifier(account.id),
              refreshed.hasValidSession else {
            throw AppleAuthError.reauthenticationRequired
        }
        return refreshed
    }

    func asset(appID: String, versionID: String?, store: StoreContext, useCache: Bool,
               allowLicenseAcquisition: Bool = true) async throws -> DownloadAsset {
        guard let identifier = UInt64(appID), identifier > 0,
              appID.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message(AppText.text("App ID 只能包含数字")) }
        if let versionID {
            guard let version = UInt64(versionID), version > 0,
                  versionID.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message(AppText.text("版本 ID 只能包含数字")) }
        }
        guard store.platform.supportsIPA else {
            throw ToolError.message(AppText.text("Mac 应用请使用「获取 PKG」下载"))
        }
        let account = try requireSignedInAccount()
        var targetVersion = versionID
        var tvListing: StoreApp?
        if store.platform == .tvOS {
            // Always resolve the Apple TV offer in the authenticated account's
            // storefront. The user's chosen search region may differ.
            var accountStore = store
            if let country = StoreService.country(forStorefront: account.storeFront) {
                accountStore.country = country
            }
            tvListing = try? await StoreService.platformApp(appID, store: accountStore)
            if targetVersion == nil { targetVersion = tvListing?.externalVersionID }
            // Delisted Apple TV purchases may have no public catalog offer.
            // Such requests still undergo strict package validation below.
        }
        var asset: DownloadAsset
        do {
            asset = try await fetchAsset(appID: appID, versionID: targetVersion, account: account,
                                         platform: store.platform,
                                         selectedCountry: allowLicenseAcquisition ? store.country : nil,
                                         useCache: useCache, fallback: false, refreshed: false, purchased: false,
                                         allowLicenseAcquisition: allowLicenseAcquisition)
        } catch let error as ToolError where targetVersion == nil && store.platform.usesIOSStore
                    && error.localizedDescription == Self.noOfferMessage {
            // Apple Arcade games may need the current version named (ipatool).
            guard let country = StoreService.country(forStorefront: account.storeFront),
                  let latest = await StoreService.latestIOSVersionID(appID, bundleID: "", country: country, platform: store.platform)
            else { throw error }
            asset = try await fetchAsset(appID: appID, versionID: latest, account: account,
                                         platform: store.platform,
                                         selectedCountry: allowLicenseAcquisition ? store.country : nil,
                                         useCache: useCache, fallback: false, refreshed: false, purchased: false,
                                         allowLicenseAcquisition: allowLicenseAcquisition)
        }
        let reported = asset.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if store.platform == .tvOS {
            let tvPlatforms = ["tvos", "appletvos", "appletv", "atv9"]
            if !reported.isEmpty && !tvPlatforms.contains(reported) {
                // The standard dispatch can resolve a shared iOS App ID to its
                // iPhone build. Try Apple's alternate version-aware endpoint once
                // before reporting that no verified tvOS file is available.
                if let alternate = try? await fetchAsset(appID: appID, versionID: targetVersion,
                    account: account, platform: store.platform,
                    selectedCountry: allowLicenseAcquisition ? store.country : nil,
                    useCache: useCache, fallback: true,
                    refreshed: false, purchased: false,
                    allowLicenseAcquisition: allowLicenseAcquisition),
                   alternate.platform.isEmpty || tvPlatforms.contains(alternate.platform.lowercased()) {
                    asset = alternate
                } else {
                    throw ToolError.message(AppText.text("该应用没有可下载的 Apple TV 版本"))
                }
            }
            // A missing platform field is not proof of tvOS compatibility.
            // Final IPA validation still requires UIDeviceFamily to include Apple TV.
            asset.platform = "appletvos"
            // The dispatch response carries the shared App ID's iPhone artwork;
            // show the Apple TV icon instead.
            if let icon = tvListing?.iconURL { asset.app.iconURL = icon }
        } else {
            guard reported.isEmpty || ["ios", "iphoneos", "ipad"].contains(reported) else {
                throw ToolError.message(AppText.text("该应用没有所选平台的版本，请切换平台后重试"))
            }
            asset.platform = store.platform == .iPadOS ? "ipad" : "ios"
        }
        return asset
    }

    private func fetchAsset(appID: String, versionID: String?, account: AppleAccount,
                            platform: AppPlatform, selectedCountry: String?,
                            useCache: Bool, fallback: Bool, refreshed: Bool, purchased: Bool,
                            allowLicenseAcquisition: Bool) async throws -> DownloadAsset {
        guard activeID == account.id else { throw ToolError.message(AppText.text("账号已切换，请重新执行下载")) }
        let root = fallback ? "https://downloaddispatch.itunes.apple.com/up/backgroundUpdateProduct" :
            "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download"
        var payload: [String: Any] = ["guid": guid, "salableAdamId": NSNumber(value: UInt64(appID) ?? 0), "serialNumber": "0"]
        if let versionID = versionID {
            payload[fallback ? "appExtVrsId" : "externalVersionId"] = versionID
        }
        if !fallback {
            guard !account.dsid.isEmpty else { throw ToolError.message(AppText.text("登录已过期，请重新登录")) }
            let kbsync = try await signer.kbsync(guid: guid, dsid: account.dsid, useCache: useCache)
            // Node plist builder in the supplied source emits the returned Base64 as a string.
            payload["kbsync"] = kbsync
        }
        let requestURL = URL(string: root + "?guid=" + guid)!
        let (raw, response) = try await storePlist(requestURL,
            body: HTTPClient.encodePlist(payload), headers: authHeaders(account), guid: guid, useCache: useCache)
        let failure = plistString(raw["failureType"])
        let stage = fallback ? "download-fallback" : "download"
        if AppleAuthError.requiresReauthentication(raw) {
            RequestFailureLog.recordAppleFailure(response.url ?? requestURL, response: raw, stage: stage)
            throw AppleAuthError.reauthenticationRequired
        }
        // Still expired right after a refresh: only signing in again can help.
        if Self.isSessionExpiredFailure(failure), refreshed {
            RequestFailureLog.recordAppleFailure(response.url ?? requestURL, response: raw, stage: stage)
            throw AppleAuthError.reauthenticationRequired
        }
        if Self.isSessionExpiredFailure(failure), !refreshed {
            let refreshedAccount: AppleAccount
            do { refreshedAccount = try await refresh(account, useCache: useCache) }
            catch {
                if error is AppleLoginError || error is AppleAuthError || error is CancellationError
                    || error is ToolError || error is HTTPStatusError
                    || (error as NSError).domain == NSURLErrorDomain { throw error }
                // The saved password no longer works (changed or wrong): ask for it.
                throw AppleAuthError.reauthenticationRequired
            }
            return try await fetchAsset(appID: appID, versionID: versionID, account: refreshedAccount,
                platform: platform, selectedCountry: selectedCountry,
                useCache: useCache, fallback: fallback, refreshed: true, purchased: purchased,
                allowLicenseAcquisition: allowLicenseAcquisition)
        }
        if Self.shouldAcquireLicense(failure: failure, purchased: purchased,
                                     allowLicenseAcquisition: allowLicenseAcquisition) {
            // A missing license does not mean the login session is expired. Refreshing
            // here always calls authenticate and can trigger an invisible 2FA prompt.
            // Acquire the free license using the current valid account first.
            guard activeID == account.id else { throw ToolError.message(AppText.text("账号已切换，请重新执行下载")) }
            let updatedAccount = try await acquireFreeApp(appID, account: account, platform: platform,
                                                          selectedCountry: selectedCountry, useCache: useCache)
            return try await fetchAsset(appID: appID, versionID: versionID, account: updatedAccount,
                platform: platform, selectedCountry: selectedCountry,
                useCache: useCache, fallback: fallback, refreshed: refreshed, purchased: true,
                allowLicenseAcquisition: allowLicenseAcquisition)
        }
        // Viewing a version list never claims a license; say what is missing.
        if failure == "9610" && !allowLicenseAcquisition { throw AppleLicenseError.notOwned }
        if allowLicenseAcquisition,
           let regionalError = await diagnoseStorefrontFailure(failure, appID: appID, platform: platform,
                                                               account: account, selectedCountry: selectedCountry) {
            RequestFailureLog.recordAppleFailure(response.url ?? requestURL, response: raw, stage: stage)
            throw regionalError
        }
        if let error = HTTPClient.appleFailure(raw) {
            RequestFailureLog.recordAppleFailure(response.url ?? requestURL, response: raw, stage: stage)
            throw error
        }
        guard let song = (raw["songList"] as? [[String: Any]])?.first else {
            if !fallback {
                return try await fetchAsset(appID: appID, versionID: versionID, account: account,
                    platform: platform, selectedCountry: selectedCountry,
                    useCache: useCache, fallback: true, refreshed: refreshed, purchased: purchased,
                    allowLicenseAcquisition: allowLicenseAcquisition)
            }
            throw ToolError.message(Self.noOfferMessage)
        }
        guard let url = URL(string: plistString(song["URL"])), url.scheme == "https",
              var metadata = song["metadata"] as? [String: Any] else { throw ToolError.message(AppText.text("暂时无法下载，请稍后重试")) }
        guard activeID == account.id else { throw ToolError.message(AppText.text("账号已切换，请重新执行下载")) }
        metadata = Self.purchaseMetadata(metadata, account: account, appID: appID,
                                         purchaseDate: song["purchaseDate"] as? Date ?? Date())
        let externalID = plistString(metadata["softwareVersionExternalIdentifier"])
        if let requested = versionID, !externalID.isEmpty, externalID != requested {
            throw ToolError.message(AppText.text("所选版本暂时无法下载，请换个版本重试"))
        }
        let artwork = song["artwork-urls"] as? [String: Any]
        let defaultArt = artwork?["default"] as? [String: Any]
        let assetInfo = song["asset-info"] as? [String: Any]
        let rawShort = plistString(metadata["bundleShortVersionString"])
        let rawBuild = plistString(metadata["bundleVersion"])
        let resolvedVersion = VersionService.reconcileTicketVersion(shortVersion: rawShort, buildVersion: rawBuild)
        let app = StoreApp(id: plistString(song["songId"]).isEmpty ? appID : plistString(song["songId"]),
            name: plistString(metadata["bundleDisplayName"]), bundleID: plistString(metadata["softwareVersionBundleId"]),
            version: resolvedVersion.isEmpty ? rawShort : resolvedVersion, iconURL: StoreService.icon(plistString(defaultArt?["url"])),
            size: (assetInfo?["file-size"] as? NSNumber)?.int64Value ?? 0,
            minimumOS: plistString(metadata["minimumOSVersion"] ?? metadata["minimumOsVersion"]), externalVersionID: externalID,
            bundleVersion: rawBuild.isEmpty ? nil : rawBuild)
        // The server order is positional: SC_Info/Manifest.plist.SinfPaths
        // uses the same order. Sorting by the opaque `id`, or compacting a
        // missing item, assigns licenses to the wrong extension/framework.
        let sinfs = try Self.mobileSinfs(song["sinfs"] as? [[String: Any]] ?? [])
        let sinf = sinfs[0]
        let encodedMetadata: Data = try (try? PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0))
            ?? HTTPClient.encodePlist(metadata)
        return DownloadAsset(app: app, url: url, sinf: sinf, sinfs: sinfs, metadata: encodedMetadata,
            externalVersionIDs: (metadata["softwareVersionExternalIdentifiers"] as? [Any] ?? []).map { plistString($0) },
            platform: plistString(metadata["software-platform"]), account: account.id)
    }

    struct VersionTicket: Sendable {
        let url: URL
        let displayVersion: String
        let rawShortVersion: String
        let buildVersion: String
        let fileSize: Int64?
    }

    /// Download ticket for one version, used only to read that version's
    /// Info.plist. Unlike a download it never acquires a license or signs in
    /// again, so browsing a version list cannot trigger a verification prompt.
    func versionTicket(appID: String, versionID: String, useCache: Bool) async throws -> URL {
        try await versionTicketDetails(appID: appID, versionID: versionID, useCache: useCache).url
    }

    func versionTicketDetails(appID: String, versionID: String, useCache: Bool) async throws -> VersionTicket {
        guard let account = active, account.hasValidSession else { throw AppleAuthError.reauthenticationRequired }
        guard let app = UInt64(appID), app > 0, UInt64(versionID).map({ $0 > 0 }) == true else {
            throw ToolError.message(AppText.text("版本 ID 只能包含数字"))
        }
        let kbsync = try await signer.kbsync(guid: guid, dsid: account.dsid, useCache: useCache)
        let payload: [String: Any] = ["guid": guid, "salableAdamId": NSNumber(value: app), "serialNumber": "0",
                                      "externalVersionId": versionID, "kbsync": kbsync]
        let endpoint = URL(string: "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=" + guid)!
        let (raw, response) = try await storePlist(
            endpoint,
            body: HTTPClient.encodePlist(payload), headers: authHeaders(account), guid: guid, useCache: useCache)
        let failure = plistString(raw["failureType"])
        if AppleAuthError.requiresReauthentication(raw) || Self.isSessionExpiredFailure(failure) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "version-ticket")
            throw AppleAuthError.reauthenticationRequired
        }
        if failure == "9610" { throw AppleLicenseError.notOwned }
        if let error = HTTPClient.appleFailure(raw) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "version-ticket")
            throw error
        }
        guard let song = (raw["songList"] as? [[String: Any]])?.first,
              let url = URL(string: plistString(song["URL"])), url.scheme == "https",
              let metadata = song["metadata"] as? [String: Any],
              [versionID, ""].contains(plistString(metadata["softwareVersionExternalIdentifier"])) else {
            throw ToolError.message(AppText.text("Apple 没有返回该版本的信息"))
        }
        let sanitizedShort = VersionService.sanitizedVersion(plistString(metadata["bundleShortVersionString"]), rejectingID: versionID)
        let sanitizedBuild = VersionService.sanitizedVersion(plistString(metadata["bundleVersion"]), rejectingID: versionID)
        let rawShortVersion = sanitizedShort == AppVersion.unknown ? "" : sanitizedShort
        let buildVersion = sanitizedBuild == AppVersion.unknown ? "" : sanitizedBuild
        let displayVersion = VersionService.reconcileTicketVersion(shortVersion: rawShortVersion, buildVersion: buildVersion)
        let assetInfo = song["asset-info"] as? [String: Any]
        let fileSize = (assetInfo?["file-size"] as? NSNumber)?.int64Value
        return VersionTicket(url: url,
                             displayVersion: displayVersion,
                             rawShortVersion: rawShortVersion,
                             buildVersion: buildVersion,
                             fileSize: fileSize.flatMap { $0 > 0 ? $0 : nil })
    }

    static var noOfferMessage: String { AppText.text("Apple 没有返回该版本的下载信息") }

    nonisolated static func mobileSinfs(_ records: [[String: Any]]) throws -> [Data] {
        func bytes(_ value: Any?) -> Data? {
            if let value = value as? Data { return value.isEmpty ? nil : value }
            if let encoded = value as? String,
               let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty {
                return data
            }
            return nil
        }
        guard !records.isEmpty else { throw ToolError.message(AppText.text("此账号没有该应用的下载授权")) }
        var result: [Data] = []
        result.reserveCapacity(records.count)
        for record in records {
            guard let data = bytes(record["sinf"]) else {
                // Never shift later records into this record's path.
                throw ToolError.message(AppText.text("应用的多组件下载授权不完整，请重新下载"))
            }
            result.append(data)
        }
        return result
    }

    /// The iTunesMetadata.plist Apple's own clients (iTunes, App Store) write.
    /// installd records the purchaser from `com.apple.iTunesStore.downloadInfo`;
    /// without it App Store does not recognize the installed app as its own,
    /// shows a download button and never offers updates.
    nonisolated static func purchaseMetadata(_ source: [String: Any], account: AppleAccount, appID: String = "",
                                             purchaseDate: Date) -> [String: Any] {
        var metadata = source
        let parts = account.name == account.id ? [] : account.name.split(separator: " ", maxSplits: 1).map(String.init)
        let dsidNum = UInt64(account.dsid).map(NSNumber.init(value:)) ?? NSNumber(value: 0)
        var info: [String: Any] = [
            "AppleID": account.id, "UserName": account.id,
            "DSPersonID": dsidNum, "DownloaderID": dsidNum, "PurchaserID": dsidNum,
            "FamilyID": NSNumber(value: 0)
        ]
        if let first = parts.first { info["FirstName"] = first }
        if parts.count > 1 { info["LastName"] = parts[1] }
        let storeFront = account.fullStoreFront.isEmpty ? account.storeFront : account.fullStoreFront
        if !storeFront.isEmpty { info["AccountStoreFront"] = storeFront }
        let formatter = ISO8601DateFormatter()
        metadata["com.apple.iTunesStore.downloadInfo"] = ["accountInfo": info, "purchaseDate": formatter.string(from: purchaseDate)]
        metadata["appleId"] = account.id
        metadata["apple-id"] = account.id
        metadata["userName"] = account.id
        if dsidNum.uint64Value > 0 {
            metadata["DSPersonID"] = dsidNum
            metadata["downloader-id"] = dsidNum
            metadata["purchaser-id"] = dsidNum
        }
        if let currentItem = metadata["itemId"] {
            if let str = currentItem as? String, let num = UInt64(str) {
                metadata["itemId"] = NSNumber(value: num)
            }
        } else if let idNum = UInt64(appID) {
            metadata["itemId"] = NSNumber(value: idNum)
        }
        if metadata["purchaseDate"] == nil { metadata["purchaseDate"] = purchaseDate }
        return metadata
    }

    static func shouldAcquireLicense(failure: String, purchased: Bool,
                                     allowLicenseAcquisition: Bool) -> Bool {
        failure == "9610" && !purchased && allowLicenseAcquisition
    }

    /// Apple failure codes that indicate an expired/unverified store session
    /// (aligned with ipatool: 2034 password token expired, 2042 sign-in
    /// required, 1008 device verification failed).
    nonisolated static func isSessionExpiredFailure(_ failureType: String) -> Bool {
        ["1008", "2034", "2042"].contains(failureType)
    }

    /// Parses Apple's `MZCommerce.CountryMismatch` (`failureType == "-128"`)
    /// redirect (`https://itunes.apple.com/WebObjects/MZStore.woa/wa/resetAndRedirect?dsf=<id>`)
    /// into a corrected `(storeFront, fullStoreFront)` pair preserving any
    /// language/platform suffix (e.g. `-1,34`). Never follows arbitrary URLs
    /// or infers countries from localized dialog text.
    nonisolated static func purchaseStorefrontCorrection(
        _ response: [String: Any],
        currentFullStoreFront: String,
        currentStoreFront: String
    ) -> (storeFront: String, fullStoreFront: String)? {
        guard plistString(response["failureType"]) == "-128" else { return nil }
        let metrics = response["metrics"] as? [String: Any]
        guard plistString(metrics?["dialogId"]) == "MZCommerce.CountryMismatch" else { return nil }
        let dialog = response["dialog"] as? [String: Any]
        let okAction = dialog?["okButtonAction"] as? [String: Any]
        guard plistString(okAction?["kind"]) == "Goto" else { return nil }
        let rawURL = plistString(okAction?["url"])
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "itunes.apple.com",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == "/WebObjects/MZStore.woa/wa/resetAndRedirect" else {
            return nil
        }
        let dsfItems = (components.queryItems ?? []).filter { $0.name == "dsf" }
        guard dsfItems.count == 1, let identifier = dsfItems.first?.value,
              let number = UInt32(identifier), number > 0, String(number) == identifier else {
            return nil
        }
        let trimmedFull = currentFullStoreFront.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShort = currentStoreFront.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = trimmedFull.isEmpty ? trimmedShort : trimmedFull
        let previous = StoreService.storefrontIdentifier(current)
        guard identifier != previous else { return nil }
        let suffix = current.hasPrefix(previous) ? String(current.dropFirst(previous.count)) : ""
        return (storeFront: identifier, fullStoreFront: identifier + suffix)
    }

    /// Identifies Apple's `buyProductFailure` action requesting acceptance of
    /// updated App Store Terms & Conditions (`termsPage`).
    nonisolated static func isPurchaseTermsAction(_ response: [String: Any]) -> Bool {
        guard plistString(response["jingleDocType"]) == "buyProductFailure" else { return false }
        let action = response["action"] as? [String: Any]
        guard plistString(action?["kind"]) == "Goto" else { return false }
        let rawURL = plistString(action?["url"])
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              AppleAuthentication.isBuyHost(host),
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == "/WebObjects/MZFinance.woa/wa/com.apple.jingle.app.finance.DirectAction/termsPage" else {
            return false
        }
        return true
    }

    private func updateAccountStorefront(id: String, dsid: String,
                                         storeFront: String, fullStoreFront: String) -> AppleAccount? {
        guard let index = accounts.firstIndex(where: { $0.id == id && $0.dsid == dsid }) else { return nil }
        var updated = accounts
        updated[index].storeFront = storeFront
        updated[index].fullStoreFront = fullStoreFront
        accounts = updated
        try? KeychainStore.save(updated)
        return updated[index]
    }

    private func buyProductURL(for account: AppleAccount) -> URL {
        let activeCookie = liveCookies[account.id] ?? account.cookie
        let pod = commercePods[account.dsid] ?? CommercePurchaseHistory.pod(fromCookie: activeCookie) ?? ""
        if !pod.isEmpty, pod.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return URL(string: "https://p\(pod)-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!
        }
        return URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!
    }

    /// `arcade` false first; an iOS app that Apple reports unavailable (2059)
    /// is retried as an Apple Arcade game, as ipatool does.
    @discardableResult
    private func acquireFreeApp(_ id: String, account: AppleAccount, mac: Bool = false, arcade: Bool = false,
                                storefrontRecovered: Bool = false,
                                platform: AppPlatform = .iOS, selectedCountry: String? = nil,
                                useCache: Bool = true) async throws -> AppleAccount {
        let deviceID = guid
        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "buyWithoutAuthorization": "true",
            "guid": deviceID,
            "hasAskedToFulfillPreorder": "true",
            "hasDoneAgeCheck": "true",
            "needDiv": "0",
            "origPage": "Software-\(id)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": arcade ? "GAME" : "STDQ",
            "productType": "C",
            "salableAdamId": id
        ]
        var headers = authHeaders(account)
        headers["Content-Type"] = "application/x-apple-plist"
        let endpoint = buyProductURL(for: account)
        let (raw, response) = try await storePlist(
            endpoint,
            body: HTTPClient.encodePlist(payload), headers: headers, guid: deviceID, useCache: useCache)
        if !storefrontRecovered,
           let correction = Self.purchaseStorefrontCorrection(
                raw,
                currentFullStoreFront: account.fullStoreFront,
                currentStoreFront: account.storeFront
           ) {
            let updatedAccount = updateAccountStorefront(
                id: account.id,
                dsid: account.dsid,
                storeFront: correction.storeFront,
                fullStoreFront: correction.fullStoreFront
            ) ?? AppleAccount(
                id: account.id, name: account.name, password: account.password,
                cookie: account.cookie, dsid: account.dsid, passwordToken: account.passwordToken,
                storeFront: correction.storeFront, fullStoreFront: correction.fullStoreFront
            )
            return try await acquireFreeApp(id, account: updatedAccount, mac: mac, arcade: arcade,
                                            storefrontRecovered: true,
                                            platform: platform, selectedCountry: selectedCountry,
                                            useCache: useCache)
        }
        if Self.isPurchaseTermsAction(raw) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "buy-terms")
            throw ToolError.message(AppText.text("Apple 需要您先同意最新的 App Store 条款与条件，请先在系统 App Store 中同意后再试。"))
        }
        // A license acquisition can independently require a new trusted-device
        // approval, even when the previous download token was accepted.
        if AppleAuthError.requiresReauthentication(raw) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "buy")
            throw AppleAuthError.reauthenticationRequired
        }
        let failure = plistString(raw["failureType"])
        // The account already holds the license (ipatool): nothing to claim.
        if failure == "5002" { return account }
        if plistString(raw["customerMessage"]) == "Subscription Required" {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "buy")
            throw ToolError.message(AppText.text("此应用属于 Apple Arcade，需要此账号订阅 Apple Arcade 后才能下载。"))
        }
        if failure == "2059" && !mac && !arcade {
            return try await acquireFreeApp(id, account: account, mac: mac, arcade: true,
                                            storefrontRecovered: storefrontRecovered,
                                            platform: platform, selectedCountry: selectedCountry,
                                            useCache: useCache)
        }
        if Self.isSessionExpiredFailure(failure) ||
           plistString(raw["customerMessage"]) == "MZFinance.BadLogin.Configurator_message" {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "buy")
            throw AppleLoginError.verificationRequired
        }
        if let regionalError = await diagnoseStorefrontFailure(failure, appID: id, platform: mac ? .macOS : platform,
                                                               account: account, selectedCountry: selectedCountry) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "buy")
            throw regionalError
        }
        if let error = HTTPClient.appleFailure(raw) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "buy")
            throw error
        }
        let docType = plistString(raw["jingleDocType"])
        let statusCode = (raw["status"] as? NSNumber)?.intValue ?? 0
        guard docType == "purchaseSuccess", statusCode == 0 else {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "buy")
            throw ToolError.message(AppText.text("未能获取免费应用许可，请先在 App Store 获取后重试"))
        }
        return account
    }

    // Official Apple Mac App Store authorization preflight.
    // This deliberately does NOT create a download task: Mac Store packages
    // can require StoreAgent/dpInfo processing before they become valid XAR.
    // Exposing the encrypted response as a .pkg would corrupt the export.
    /// `versionID` nil asks for the latest version on the Mac product page.
    /// A free app the account has never got is claimed first, as for iOS,
    /// unless `allowLicenseAcquisition` is false (version lists).
    func macPackageOffer(_ app: StoreApp, versionID requested: String? = nil, useCache: Bool,
                         allowLicenseAcquisition: Bool = true, licenseAcquired: Bool = false,
                         refreshed: Bool = false,
                         selectedCountry: String? = nil) async throws -> MacPackageOffer {
        let account = try requireSignedInAccount()
        guard let appNumber = UInt64(app.id), appNumber > 0 else {
            throw ToolError.message(AppText.text("请输入有效的 Mac 应用 ID"))
        }
        let initialID = account.id
        guard let country = StoreService.country(forStorefront: account.storeFront) else {
            throw ToolError.message(AppText.text("无法识别此账号的商店地区，请重新登录后重试"))
        }
        if let requested, UInt64(requested).map({ $0 > 0 }) != true {
            throw ToolError.message(AppText.text("版本 ID 只能包含数字"))
        }
        // nil when the app is delisted (no product page): the request then
        // omits externalVersionId and the response must still be macOS.
        let versionID: String?
        if let requested { versionID = requested }
        else { versionID = try await MacStoreOfferService.latestVersionID(appID: app.id, bundleID: app.bundleID, country: country) }
        try Task.checkCancellation()
        guard activeID == initialID else { throw ToolError.message(AppText.text("账号已切换，请重新获取 Mac 下载信息")) }
        let deviceID = guid
        guard let serial = MacPackageOffer.serialNumber(guid: deviceID) else {
            throw ToolError.message(AppText.text("登录已过期，请重新登录"))
        }
        let sync = try await signer.kbsync(guid: deviceID, dsid: account.dsid, useCache: useCache)
        // Same ent/download request as ipatool's Mac path: the serial number is
        // derived from the GUID that also seeds kbsync and later the StoreAgent
        // dpInfo session, so all three refer to one hardware identity.
        var payload: [String: Any] = [
            "guid": deviceID, "salableAdamId": String(appNumber),
            "serialNumber": serial, "creditDisplay": "", "kbsync": sync
        ]
        if let versionID { payload["externalVersionId"] = versionID }
        var headers = authHeaders(account)
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
        let macStoreFront = account.fullStoreFront.isEmpty ? account.storeFront : account.fullStoreFront
        if !macStoreFront.isEmpty { headers["X-Apple-Store-Front"] = macStoreFront }
        if !account.passwordToken.isEmpty { headers["X-Token"] = account.passwordToken }
        let endpoint = URL(string:
            "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=" + deviceID)!
        let (raw, response) = try await storePlist(endpoint,
            body: HTTPClient.encodePlist(payload), headers: headers, guid: deviceID, useCache: useCache)
        try Task.checkCancellation()
        guard activeID == initialID else { throw ToolError.message(AppText.text("账号已切换，请重新获取 Mac 下载信息")) }
        if AppleAuthError.requiresReauthentication(raw) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "mac-offer")
            throw AppleAuthError.reauthenticationRequired
        }
        let macFailure = plistString(raw["failureType"])
        if Self.isSessionExpiredFailure(macFailure), refreshed {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "mac-offer")
            throw AppleAuthError.reauthenticationRequired
        }
        if Self.isSessionExpiredFailure(macFailure), !refreshed {
            do { _ = try await refresh(account, useCache: useCache) }
            catch {
                if error is AppleLoginError || error is AppleAuthError || error is CancellationError
                    || error is ToolError || error is HTTPStatusError
                    || (error as NSError).domain == NSURLErrorDomain { throw error }
                throw AppleAuthError.reauthenticationRequired
            }
            return try await macPackageOffer(app, versionID: versionID, useCache: useCache,
                                             allowLicenseAcquisition: allowLicenseAcquisition,
                                             licenseAcquired: licenseAcquired,
                                             refreshed: true,
                                             selectedCountry: selectedCountry)
        }
        if macFailure == "9610" && !licenseAcquired {
            guard allowLicenseAcquisition else { throw AppleLicenseError.notOwned }
            _ = try await acquireFreeApp(app.id, account: account, mac: true,
                                         platform: .macOS, selectedCountry: selectedCountry, useCache: useCache)
            try Task.checkCancellation()
            guard activeID == initialID else { throw ToolError.message(AppText.text("账号已切换，请重新获取 Mac 下载信息")) }
            return try await macPackageOffer(app, versionID: versionID, useCache: useCache,
                                             allowLicenseAcquisition: false, licenseAcquired: true,
                                             refreshed: refreshed,
                                             selectedCountry: selectedCountry)
        }
        if allowLicenseAcquisition,
           let regionalError = await diagnoseStorefrontFailure(macFailure, appID: app.id, platform: .macOS,
                                                               account: account, selectedCountry: selectedCountry) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "mac-offer")
            throw regionalError
        }
        if let error = HTTPClient.appleFailure(raw) {
            RequestFailureLog.recordAppleFailure(response.url ?? endpoint, response: raw, stage: "mac-offer")
            throw error
        }
        var offer: MacPackageOffer
        do {
            offer = try MacPackageOffer.validate(raw, appID: app.id,
                                                 bundleID: app.bundleID, versionID: versionID)
        } catch where versionID == nil {
            throw ToolError.message(AppText.text("该应用已从商店下架，Apple 没有为此账号提供 Mac 版安装包（可能只购买过 iOS 版本，或该应用没有 Mac 版）。"))
        }
        offer.hardwareID = deviceID
        return offer
    }

    private func diagnoseStorefrontFailure(_ code: String, appID: String, platform: AppPlatform,
                                           account: AppleAccount, selectedCountry: String?) async -> Error? {
        guard code == "2059" || code == "1010" else { return nil }
        let accountCountry = StoreService.country(forStorefront: account.storeFront)?.uppercased()
        let storeCountry = selectedCountry?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let accountCountry, let storeCountry, !storeCountry.isEmpty, accountCountry != storeCountry {
            return AppleStorefrontDownloadError(
                reason: .accountRegionMismatch(accountRegion: accountCountry, storeRegion: storeCountry),
                targetCountry: storeCountry
            )
        }
        if let accountCountry,
           (try? await StoreService.platformApp(appID, store: StoreContext(country: accountCountry, platform: platform))) == nil {
            return AppleStorefrontDownloadError(
                reason: .appUnavailableInAccountRegion(accountRegion: accountCountry),
                targetCountry: nil
            )
        }
        if code == "1010", let accountCountry {
            return AppleStorefrontDownloadError(
                reason: .appUnavailableInAccountRegion(accountRegion: accountCountry),
                targetCountry: nil
            )
        }
        return AppleStorefrontDownloadError(
            reason: .temporarilyUnavailable(accountRegion: accountCountry),
            targetCountry: storeCountry
        )
    }

    func ownedApps(useCache: Bool) async throws -> [OwnedApp] {
        let account = try requireSignedInAccount()
        let base = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
        let query = "('com.apple.itunes.extended\\-media\\-kind:131072')"
        let headers = purchaseHeaders(account)
        let (login, _) = try await HTTPClient.shared.request(URL(string: base + "/login")!, method: "POST", headers: headers, appleRedirects: true)
        try DMAP.validate(login)
        guard let session = try DMAP.firstInteger(login, name: "mlid") else { throw ToolError.message(AppText.text("暂时无法同步购买记录，请稍后重试")) }
        let updateBody = Data("session-id=\(session)&revision-number=(null)&query=\(query)".utf8)
        var updateHeaders = headers
        updateHeaders["X-Apple-ActionSignature"] = try await signer.sign(updateBody, guid: guid, useCache: useCache)
        let (update, _) = try await HTTPClient.shared.request(URL(string: base + "/update")!, method: "POST", body: updateBody, headers: updateHeaders, appleRedirects: true)
        try DMAP.validate(update)
        guard let revision = try DMAP.firstInteger(update, name: "musr") else { throw ToolError.message(AppText.text("暂时无法同步购买记录，请稍后重试")) }
        let payload = DMAP.uint32("mstc", UInt32(Date().timeIntervalSince1970)) + DMAP.uint32("mlid", session) +
            DMAP.tag("mikd", Data([2])) + DMAP.uint32("musr", revision) + DMAP.uint32("mder", 0) +
            DMAP.string("mque", query) + DMAP.tag("aetl")
        let body = DMAP.tag("adsr", payload)
        var itemHeaders = purchaseHeaders(account)
        itemHeaders["Content-Type"] = "application/x-dmap-tagged"
        itemHeaders["X-Apple-ActionSignature"] = try await signer.sign(body, guid: guid, useCache: useCache)
        guard activeID == account.id else { throw ToolError.message(AppText.text("账号已切换，请重新加载购买记录")) }
        let (items, _) = try await HTTPClient.shared.request(URL(string: base + "/databases/\(revision)/items")!,
            method: "POST", body: body, headers: itemHeaders, appleRedirects: true)
        // Large accounts return megabytes of tags: parse off the main thread.
        return try await Task.detached(priority: .userInitiated) {
            try DMAP.validate(items)
            return try DMAP.ownedApps(items)
        }.value
    }

    struct CommerceHistoryResult: Sendable {
        let apps: [OwnedApp]
        let complete: Bool
    }

    /// Reads Apple's Commerce Purchase History (`/commerce/account/purchases`) year by year,
    /// returning historical, delisted, and sanctioned apps omitted by `MZPurchaseDaap`.
    func commercePurchaseHistory(
        sinceYear: Int,
        throughYear: Int? = nil,
        useCache: Bool = true,
        allowSessionRefresh: Bool = false,
        onYearProgress: (@Sendable (_ completedYears: Int, _ totalYears: Int) async -> Void)? = nil
    ) async throws -> CommerceHistoryResult {
        var account = try requireSignedInAccount()
        let currentYear = throughYear ?? Calendar(identifier: .gregorian).component(.year, from: Date())
        let startYear = max(2008, min(sinceYear, currentYear))
        let years = Array((startYear...currentYear).reversed())
        guard !years.isEmpty else { return CommerceHistoryResult(apps: [], complete: true) }

        var initialCookie = liveCookies[account.id] ?? account.cookie
        var initialPod = commercePods[account.dsid] ?? CommercePurchaseHistory.pod(fromCookie: initialCookie) ?? ""
        var storeFront = account.fullStoreFront.isEmpty ? account.storeFront : account.fullStoreFront
        var dsid = account.dsid
        var token = account.passwordToken
        var accountID = account.id

        // Run ONLY the initial page of the most recent year first so any 302 pod/cookie
        // handshake (`itspod` + `mzcprh=1`) or 401/403 refresh settles in ~1 round-trip
        // before fanning out remaining pages of the current year AND all older years in parallel.
        let firstYear = years[0]
        let firstPageFetch: CommerceFirstPageOutcome
        do {
            firstPageFetch = try await Self.fetchCommerceYearFirstPage(
                year: firstYear, pod: initialPod, cookie: initialCookie,
                dsid: dsid, storeFront: storeFront, passwordToken: token
            )
        } catch let status as HTTPStatusError where (status.code == 401 || status.code == 403) && allowSessionRefresh && !account.password.isEmpty {
            account = try await refresh(account, useCache: useCache)
            accountID = account.id
            initialCookie = liveCookies[account.id] ?? account.cookie
            initialPod = commercePods[account.dsid] ?? CommercePurchaseHistory.pod(fromCookie: initialCookie) ?? ""
            storeFront = account.fullStoreFront.isEmpty ? account.storeFront : account.fullStoreFront
            dsid = account.dsid
            token = account.passwordToken
            firstPageFetch = try await Self.fetchCommerceYearFirstPage(
                year: firstYear, pod: initialPod, cookie: initialCookie,
                dsid: dsid, storeFront: storeFront, passwordToken: token
            )
        }
        guard activeID == accountID else { throw ToolError.message(AppText.text("账号已切换，请重新加载购买记录")) }
        if !firstPageFetch.pod.isEmpty { commercePods[dsid] = firstPageFetch.pod }
        if firstPageFetch.cookie != initialCookie, !firstPageFetch.cookie.isEmpty {
            liveCookies[accountID] = firstPageFetch.cookie
        }

        var allApps = firstPageFetch.apps
        let firstYearNeedsMore = !firstPageFetch.isComplete && firstPageFetch.newInvoiceCount > 0
        var completed = firstYearNeedsMore ? 0 : 1
        if completed > 0 { await onYearProgress?(completed, years.count) }

        enum YearWork: Sendable {
            case continueYear(year: Int, seenOrderIDs: Set<String>)
            case fullYear(Int)
        }
        var workQueue: [YearWork] = []
        if firstYearNeedsMore {
            workQueue.append(.continueYear(year: firstYear, seenOrderIDs: firstPageFetch.seenOrderIDs))
        }
        for year in years.dropFirst() {
            workQueue.append(.fullYear(year))
        }

        var allComplete = true
        if !workQueue.isEmpty {
            let settledPod = firstPageFetch.pod.isEmpty ? initialPod : firstPageFetch.pod
            let settledCookie = firstPageFetch.cookie.isEmpty ? initialCookie : firstPageFetch.cookie
            let totalYears = years.count
            var latestPod = settledPod
            var latestCookie = settledCookie
            var failedYears = 0
            var lastYearError: Error?

            await withTaskGroup(of: Result<CommerceYearOutcome, Error>.self) { group in
                var nextIndex = 0
                let concurrency = min(6, workQueue.count)
                func enqueue(_ work: YearWork, pod: String, cookie: String) {
                    group.addTask {
                        do {
                            switch work {
                            case .continueYear(let year, let seen):
                                return .success(try await Self.fetchCommerceYearRemainingPages(
                                    year: year, seenOrderIDs: seen, pod: pod, cookie: cookie,
                                    dsid: dsid, storeFront: storeFront, passwordToken: token
                                ))
                            case .fullYear(let year):
                                return .success(try await Self.fetchCommerceYear(
                                    year: year, pod: pod, cookie: cookie,
                                    dsid: dsid, storeFront: storeFront, passwordToken: token
                                ))
                            }
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                while nextIndex < concurrency {
                    enqueue(workQueue[nextIndex], pod: settledPod, cookie: settledCookie)
                    nextIndex += 1
                }
                while let result = await group.next() {
                    if Task.isCancelled || activeID != accountID {
                        group.cancelAll()
                        break
                    }
                    switch result {
                    case .success(let outcome):
                        allApps.append(contentsOf: outcome.apps)
                        if outcome.podChanged, !outcome.pod.isEmpty { latestPod = outcome.pod }
                        if outcome.cookieChanged, !outcome.cookie.isEmpty { latestCookie = outcome.cookie }
                    case .failure(let error):
                        if error is CancellationError {
                            group.cancelAll()
                            break
                        }
                        failedYears += 1
                        lastYearError = error
                    }
                    completed += 1
                    await onYearProgress?(completed, totalYears)
                    if nextIndex < workQueue.count {
                        enqueue(workQueue[nextIndex], pod: latestPod, cookie: latestCookie)
                        nextIndex += 1
                    }
                }
            }
            try Task.checkCancellation()
            guard activeID == accountID else { throw ToolError.message(AppText.text("账号已切换，请重新加载购买记录")) }
            if failedYears == workQueue.count, allApps.isEmpty, let lastYearError {
                throw lastYearError
            }
            allComplete = (failedYears == 0)
            if !latestPod.isEmpty { commercePods[dsid] = latestPod }
            if latestCookie != initialCookie, !latestCookie.isEmpty {
                liveCookies[accountID] = latestCookie
            }
        }
        saveLiveCookies()
        return CommerceHistoryResult(apps: allApps, complete: allComplete)
    }

    private struct CommerceFirstPageOutcome: Sendable {
        let apps: [OwnedApp]
        let isComplete: Bool
        let newInvoiceCount: Int
        let seenOrderIDs: Set<String>
        let pod: String
        let cookie: String
    }

    private struct CommerceYearOutcome: Sendable {
        let apps: [OwnedApp]
        let pod: String
        let cookie: String
        let podChanged: Bool
        let cookieChanged: Bool
    }

    nonisolated private static func commerceURL(pod: String, page: Int?, range: String) -> URL? {
        let host = pod.isEmpty ? "buy.itunes.apple.com" : "p\(pod)-buy.itunes.apple.com"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/commerce/account/purchases"
        var items = [
            URLQueryItem(name: "isDeepLink", value: "false"),
            URLQueryItem(name: "isJsonApiFormat", value: "true")
        ]
        if let page, page > 0 {
            items.append(URLQueryItem(name: "page", value: String(page)))
        }
        items.append(URLQueryItem(name: "range", value: range))
        components.queryItems = items
        return components.url
    }

    nonisolated private static func commerceHeaders(cookie: String, dsid: String, storeFront: String, passwordToken: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": HTTPClient.userAgent,
            "Accept-Language": "en-us",
            "X-Dsid": dsid
        ]
        if !storeFront.isEmpty { headers["X-Apple-Store-Front"] = storeFront }
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        if !passwordToken.isEmpty { headers["X-Token"] = passwordToken }
        return headers
    }

    nonisolated private static func absorbResponseCookies(from response: HTTPURLResponse, into existing: String) -> String {
        guard let url = response.url else { return existing }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields { fields[String(describing: key)] = String(describing: value) }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !received.isEmpty else { return existing }
        return mergedCookie(existing, with: received)
    }

    nonisolated private static func capturePod(from response: HTTPURLResponse, current: String) -> String {
        if let headerPod = response.value(forHTTPHeaderField: "pod")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !headerPod.isEmpty, headerPod.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return headerPod
        }
        if let location = response.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location, relativeTo: response.url)?.absoluteURL,
           let host = url.host,
           let parsed = CommercePurchaseHistory.pod(fromHost: host) {
            return parsed
        }
        if let host = response.url?.host, let parsed = CommercePurchaseHistory.pod(fromHost: host) {
            return parsed
        }
        return current
    }

    nonisolated private static func fetchCommercePage(
        year: Int, page: Int?, pod initialPod: String, cookie initialCookie: String,
        dsid: String, storeFront: String, passwordToken: String
    ) async throws -> (data: Data, pod: String, cookie: String) {
        let range = "\(year)-all"
        var pod = initialPod
        var cookie = initialCookie

        guard var currentURL = commerceURL(pod: pod, page: page, range: range) else {
            throw ToolError.message(AppText.text("链接无效"))
        }

        func sendOnce(_ url: URL) async throws -> (Data, HTTPURLResponse) {
            try await HTTPClient.shared.rawRequest(
                url, method: "GET",
                headers: commerceHeaders(cookie: cookie, dsid: dsid, storeFront: storeFront, passwordToken: passwordToken),
                timeoutInterval: 30
            )
        }

        func send(_ url: URL) async throws -> (Data, HTTPURLResponse) {
            var lastError: Error?
            for attempt in 0..<3 {
                try Task.checkCancellation()
                do {
                    let result = try await sendOnce(url)
                    let code = result.1.statusCode
                    if (code == 429 || (500...599).contains(code)), attempt < 2 {
                        try await Task.sleep(nanoseconds: UInt64(attempt == 0 ? 500_000_000 : 1_500_000_000))
                        continue
                    }
                    return result
                } catch {
                    if error is CancellationError || Task.isCancelled { throw error }
                    lastError = error
                    let nsCode = (error as NSError).code
                    let retryable = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                                     NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(nsCode)
                    guard retryable, attempt < 2 else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(attempt == 0 ? 500_000_000 : 1_500_000_000))
                }
            }
            throw lastError ?? ToolError.message(AppText.text("网络连接失败，请稍后重试"))
        }

        var responsePair: (Data, HTTPURLResponse)
        do {
            responsePair = try await send(currentURL)
            if !pod.isEmpty && (responsePair.1.statusCode == 404 || (500...599).contains(responsePair.1.statusCode)),
               let fallback = commerceURL(pod: "", page: page, range: range) {
                currentURL = fallback
                responsePair = try await send(fallback)
            }
        } catch {
            guard !pod.isEmpty, !Task.isCancelled,
                  let fallback = commerceURL(pod: "", page: page, range: range) else { throw error }
            currentURL = fallback
            responsePair = try await send(fallback)
        }

        var (data, http) = responsePair
        cookie = absorbResponseCookies(from: http, into: cookie)
        pod = capturePod(from: http, current: pod)

        // Follow up to 4 302 hops verbatim so Apple's `mzcprh=1` + `itspod` handshake succeeds.
        for _ in 0..<4 where [301, 302, 303, 307, 308].contains(http.statusCode) {
            try Task.checkCancellation()
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: currentURL)?.absoluteURL,
                  next.scheme?.lowercased() == "https",
                  let host = next.host?.lowercased(),
                  next.user == nil, next.password == nil,
                  host == "itunes.apple.com" || host.hasSuffix(".itunes.apple.com") else {
                throw ToolError.message(AppText.text("服务器响应异常，请稍后重试"))
            }
            currentURL = next
            (data, http) = try await send(next)
            cookie = absorbResponseCookies(from: http, into: cookie)
            pod = capturePod(from: http, current: pod)
        }

        guard (200..<300).contains(http.statusCode) else {
            let cookieNames = cookie.split(separator: ";").compactMap { part -> String? in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let eq = trimmed.firstIndex(of: "=") else { return nil }
                let rawName = String(trimmed[..<eq])
                if let dash = rawName.lastIndex(of: "-") {
                    let suffix = rawName[rawName.index(after: dash)...]
                    if suffix.count >= 5, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        return String(rawName[...dash]) + "…" + String(suffix.suffix(4))
                    }
                }
                return rawName
            }.joined(separator: ",")
            InstallLog.shared.add("commerce-purchases HTTP \(http.statusCode) host=\(currentURL.host ?? "?") pod=\(pod.isEmpty ? "-" : pod) cookies=[\(cookieNames)] bytes=\(data.count)")
            RequestFailureLog.record(currentURL, status: http.statusCode, stage: "commerce-purchases")
            throw HTTPStatusError(code: http.statusCode)
        }
        return (data, pod, cookie)
    }

    nonisolated private static func fetchCommerceYearFirstPage(
        year: Int, pod initialPod: String, cookie initialCookie: String,
        dsid: String, storeFront: String, passwordToken: String
    ) async throws -> CommerceFirstPageOutcome {
        var seenOrderIDs = Set<String>()
        let initial = try await fetchCommercePage(
            year: year, page: nil, pod: initialPod, cookie: initialCookie,
            dsid: dsid, storeFront: storeFront, passwordToken: passwordToken
        )
        let firstPage = try CommercePurchaseHistory.parsePage(initial.data, seenOrderIDs: &seenOrderIDs)
        return CommerceFirstPageOutcome(
            apps: firstPage.apps,
            isComplete: firstPage.isComplete,
            newInvoiceCount: firstPage.newInvoiceCount,
            seenOrderIDs: seenOrderIDs,
            pod: initial.pod,
            cookie: initial.cookie
        )
    }

    nonisolated private static func fetchCommerceYearRemainingPages(
        year: Int, seenOrderIDs initialSeen: Set<String>,
        pod initialPod: String, cookie initialCookie: String,
        dsid: String, storeFront: String, passwordToken: String
    ) async throws -> CommerceYearOutcome {
        var pod = initialPod
        var cookie = initialCookie
        var apps: [OwnedApp] = []
        var seenOrderIDs = initialSeen
        for page in 2...1000 {
            try Task.checkCancellation()
            let fetched = try await fetchCommercePage(
                year: year, page: page, pod: pod, cookie: cookie,
                dsid: dsid, storeFront: storeFront, passwordToken: passwordToken
            )
            pod = fetched.pod
            cookie = fetched.cookie
            let parsed = try CommercePurchaseHistory.parsePage(fetched.data, seenOrderIDs: &seenOrderIDs)
            apps.append(contentsOf: parsed.apps)
            if parsed.isComplete || parsed.newInvoiceCount == 0 { break }
        }
        return CommerceYearOutcome(
            apps: apps, pod: pod, cookie: cookie,
            podChanged: pod != initialPod, cookieChanged: cookie != initialCookie
        )
    }

    nonisolated private static func fetchCommerceYear(
        year: Int, pod initialPod: String, cookie initialCookie: String,
        dsid: String, storeFront: String, passwordToken: String
    ) async throws -> CommerceYearOutcome {
        let first = try await fetchCommerceYearFirstPage(
            year: year, pod: initialPod, cookie: initialCookie,
            dsid: dsid, storeFront: storeFront, passwordToken: passwordToken
        )
        guard !first.isComplete && first.newInvoiceCount > 0 else {
            return CommerceYearOutcome(
                apps: first.apps, pod: first.pod, cookie: first.cookie,
                podChanged: first.pod != initialPod, cookieChanged: first.cookie != initialCookie
            )
        }
        let rest = try await fetchCommerceYearRemainingPages(
            year: year, seenOrderIDs: first.seenOrderIDs, pod: first.pod, cookie: first.cookie,
            dsid: dsid, storeFront: storeFront, passwordToken: passwordToken
        )
        return CommerceYearOutcome(
            apps: first.apps + rest.apps, pod: rest.pod, cookie: rest.cookie,
            podChanged: rest.pod != initialPod, cookieChanged: rest.cookie != initialCookie
        )
    }

    private func storePlist(_ url: URL, body: Data, headers: [String: String], guid: String,
                            useCache: Bool) async throws -> ([String: Any], HTTPURLResponse) {
        let result = try await AppleAuthentication.withStoreProof(
            endpoint: url,
            baseHeaders: headers,
            loadProof: { try await self.signer.storeProofHeaders(guid: guid, useCache: useCache) },
            provisionProof: { challenge in
                try await self.signer.provisionStoreProof(challenge: challenge, guid: guid, useCache: useCache)
            },
            resetProof: { self.signer.resetStoreProof(guid: guid) },
            execute: { headerProvider in
                let initialHeaders = try await headerProvider(url)
                return try await HTTPClient.shared.plist(
                    url, body: body, headers: initialHeaders,
                    retryTransient: true,
                    refreshHeaders: headerProvider
                )
            }
        )
        absorbCookies(from: result.1, dsid: headers["X-Dsid"])
        if let dsid = headers["X-Dsid"], !dsid.isEmpty {
            let capturedPod = Self.capturePod(from: result.1, current: "")
            if !capturedPod.isEmpty { commercePods[dsid] = capturedPod }
        }
        return result
    }

    /// Apple refreshes the session cookies on store responses. Keeping only
    /// the ones from sign-in lets the session go stale, and Apple then asks
    /// to verify the account again for every app claimed.
    private func absorbCookies(from response: HTTPURLResponse, dsid: String?) {
        guard let dsid, !dsid.isEmpty, let url = response.url,
              let account = accounts.first(where: { $0.dsid == dsid }) else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields { fields[String(describing: key)] = String(describing: value) }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !received.isEmpty else { return }
        let current = liveCookies[account.id] ?? account.cookie
        let merged = Self.mergedCookie(current, with: received)
        guard merged != current else { return }
        // Requests use the in-memory value at once. Saving republishes the
        // account list, so it is written at most once a minute.
        liveCookies[account.id] = merged
        guard Date().timeIntervalSince(cookiesSavedAt) > 60 else { return }
        saveLiveCookies()
    }

    /// Writes the session cookies kept in memory to the saved accounts.
    /// Best effort: requests already succeeded with them.
    func saveLiveCookies() {
        guard !liveCookies.isEmpty else { return }
        var updated = accounts
        for index in updated.indices { if let cookie = liveCookies[updated[index].id] { updated[index].cookie = cookie } }
        cookiesSavedAt = Date()
        guard (try? KeychainStore.save(updated)) != nil else { return }
        accounts = updated
        liveCookies.removeAll()
    }

    /// `existing` with `received` applied: new values replace old ones by
    /// name, expired or emptied cookies are dropped, order is kept.
    nonisolated static func mergedCookie(_ existing: String, with received: [HTTPCookie], now: Date = Date()) -> String {
        var names: [String] = []
        var values: [String: String] = [:]
        for part in existing.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
            let name = String(pair[..<equals])
            if values[name] == nil { names.append(name) }
            values[name] = String(pair[pair.index(after: equals)...])
        }
        for cookie in received {
            if cookie.value.isEmpty || (cookie.expiresDate.map { $0 <= now } ?? false) {
                values[cookie.name] = nil
                names.removeAll { $0 == cookie.name }
            } else {
                if values[cookie.name] == nil { names.append(cookie.name) }
                values[cookie.name] = cookie.value
            }
        }
        return names.compactMap { name in values[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
    }

    private func authHeaders(_ account: AppleAccount) -> [String: String] {
        var account = accounts.first { $0.id == account.id && $0.dsid == account.dsid } ?? account
        if let cookie = liveCookies[account.id] { account.cookie = cookie }
        var headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Dsid": account.dsid,
            "iCloud-DSID": account.dsid
        ]
        if !account.cookie.isEmpty { headers["Cookie"] = account.cookie }
        let storeFront = account.fullStoreFront.isEmpty ? account.storeFront : account.fullStoreFront
        if !storeFront.isEmpty { headers["X-Apple-Store-Front"] = storeFront }
        if !account.passwordToken.isEmpty { headers["X-Token"] = account.passwordToken }
        return headers
    }
    private func purchaseHeaders(_ account: AppleAccount) -> [String: String] {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let iso = ISO8601DateFormatter()
        var headers = authHeaders(account)
        let storeFront = account.fullStoreFront.isEmpty ? account.storeFront : account.fullStoreFront
        var extra: [String: String] = [
            "Accept": "*/*", "Accept-Language": "en-us", "Client-Cloud-DAAP-Request-Reason": "5",
            "Client-Cloud-Purchase-Daap-Version": "1.1/Configurator-2.0", "Client-DAAP-Version": "3.12",
            "Date": date.string(from: now), "X-Apple-I-Client-Time": iso.string(from: now),
            "X-Apple-I-Locale": "en_US", "X-Apple-I-TimeZone": "Local",
            "X-Apple-TZ": String(TimeZone.current.secondsFromGMT(for: now) / 60), "X-Guid": guid
        ]
        if !storeFront.isEmpty { extra["X-Apple-Store-Front"] = storeFront }
        if !account.passwordToken.isEmpty { extra["X-Token"] = account.passwordToken }
        headers.merge(extra, uniquingKeysWith: { _, new in new })
        return headers
    }
}


// Trusted metadata only. The URL is obtained from an authenticated Apple
// response; passwords/tokens/dpInfo are never exposed to the UI or logged.
struct MacPackageOffer {
    let downloadURL: URL
    let versionID: String
    let displayVersion: String
    let protectedByApple: Bool
    /// Every version Apple lists for this app, oldest first.
    var externalVersionIDs: [String] = []
    /// Account- and device-bound key material for StoreAgent. Kept in memory
    /// only; never persisted with download jobs, logged or shown in the UI.
    var dpInfo: Data? = nil
    /// The GUID whose kbsync authorized this offer; StoreAgent must use it too.
    var hardwareID = ""

    /// ipatool's ent/download serial: a fixed prefix plus the last four bytes
    /// of the six-byte GUID.
    static func serialNumber(guid: String) -> String? {
        guard guid.count == 12, guid.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = [0x54, 0xc8, 0xb0, 0xa9, 0x88]
        var index = guid.index(guid.startIndex, offsetBy: 4)
        while index < guid.endIndex {
            let next = guid.index(index, offsetBy: 2)
            guard let value = UInt8(guid[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }

    /// `versionID` nil accepts whichever version Apple returns (delisted
    /// apps), still requiring macOS metadata and a numeric version ID.
    static func validate(_ raw: [String: Any], appID: String, bundleID: String,
                         versionID: String?) throws -> MacPackageOffer {
        guard let songs = raw["songList"] as? [[String: Any]], songs.count == 1,
              let item = songs.first,
              let metadata = item["metadata"] as? [String: Any] else {
            throw ToolError.message(AppText.text("此账号没有该应用 Mac 版的下载授权"))
        }
        let itemID = plistString(metadata["itemId"] ?? item["songId"])
        let actualVersionID = plistString(metadata["softwareVersionExternalIdentifier"])
        let actualBundleID = plistString(metadata["softwareVersionBundleId"])
        let platform = plistString(metadata["software-platform"]).lowercased()
        let type = plistString(metadata["product-type"]).lowercased()
        // Universal app product-type can still be ios-app. Explicit macOS
        // software-platform is authoritative, never trust the filename.
        guard itemID == appID,
              versionID.map({ actualVersionID == $0 }) ?? (UInt64(actualVersionID).map { $0 > 0 } ?? false),
              !actualBundleID.isEmpty,
              bundleID.isEmpty || actualBundleID == bundleID,
              platform == "macos", type == "mac-os-app" || type == "ios-app" || type.isEmpty else {
            throw ToolError.message(AppText.text("该应用没有可下载的 Mac 版本"))
        }
        guard let text = item["URL"] as? String,
              let url = URL(string: text), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else {
            throw ToolError.message(AppText.text("暂时无法下载 Mac 安装包，请稍后重试"))
        }
        func bytes(_ value: Any?) -> Data? {
            if let value = value as? Data { return value.isEmpty ? nil : value }
            if let encoded = value as? String, let data = Data(base64Encoded: encoded), !data.isEmpty { return data }
            return nil
        }
        let sinfs = item["sinfs"] as? [[String: Any]] ?? []
        let dpInfos = sinfs.compactMap { bytes($0["dpInfo"]) }
        if let first = dpInfos.first, dpInfos.contains(where: { $0 != first }) {
            throw ToolError.message(AppText.text("暂时无法下载 Mac 安装包，请稍后重试"))
        }
        // An iOS-style sinf without dpInfo is evidence of a mobile package,
        // which contradicts the macOS metadata checked above (as in ipatool).
        guard !sinfs.contains(where: { bytes($0["sinf"]) != nil && bytes($0["dpInfo"]) == nil }) else {
            throw ToolError.message(AppText.text("该应用没有可下载的 Mac 版本"))
        }
        return MacPackageOffer(downloadURL: url, versionID: actualVersionID,
                               displayVersion: plistString(metadata["bundleShortVersionString"]),
                               protectedByApple: !dpInfos.isEmpty,
                               externalVersionIDs: (metadata["softwareVersionExternalIdentifiers"] as? [Any] ?? []).map { plistString($0) },
                               dpInfo: dpInfos.first)
    }
}

struct AppleStorefrontDownloadError: LocalizedError, Equatable {
    enum Reason: Equatable {
        case accountRegionMismatch(accountRegion: String, storeRegion: String)
        case appUnavailableInAccountRegion(accountRegion: String)
        case temporarilyUnavailable(accountRegion: String?)
    }

    let reason: Reason
    let targetCountry: String?

    var errorDescription: String? {
        switch reason {
        case .accountRegionMismatch(let accountRegion, let storeRegion):
            let accountLabel = StoreRegions.name(accountRegion)
            let storeLabel = StoreRegions.name(storeRegion)
            return AppText.text("账号地区（\(accountLabel)）与搜索地区（\(storeLabel)）不一致，请切换账号或搜索地区后再试。")
        case .appUnavailableInAccountRegion(let accountRegion):
            let accountLabel = StoreRegions.name(accountRegion)
            return AppText.text("此应用在账号地区（\(accountLabel)）不可用，请更换对应地区账号后再试。")
        case .temporarilyUnavailable:
            return AppText.text("该应用暂时无法下载，请稍后再试或切换对应地区账号。")
        }
    }
}

enum AppleLicenseError: LocalizedError {
    case notOwned
    var errorDescription: String? {
        AppText.text("此账号还没有获取这个应用。先获取一次，之后就能查看完整版本列表。")
    }
}

enum AppleAuthError: LocalizedError {
    case reauthenticationRequired
    static func requiresReauthentication(_ response: [String: Any]) -> Bool {
        plistString(response["failureType"]) == "2002"
            || plistString(response["customerMessage"]).trimmingCharacters(in: .whitespacesAndNewlines) == "Your password has changed."
    }
    var errorDescription: String? {
        AppText.text("Apple 账号需要重新登录。请输入当前密码，并根据 Apple 的提示完成验证。")
    }
}

enum AppleLoginError: LocalizedError {
    case verificationRequired, verificationRejected
    var errorDescription: String? {
        switch self {
        case .verificationRequired: return AppText.text("请在受信任设备上允许登录，然后输入收到的 6 位验证码。")
        case .verificationRejected: return AppText.text("Apple 未接受本次验证。请检查账号密码，并输入最新的 6 位验证码后重试。")
        }
    }
}

enum AppleLoginResponse {
    static func body(email: String, password: String, code: String, guid: String) throws -> Data {
        try HTTPClient.encodePlist(["appleId": email, "attempt": code.isEmpty ? "1" : "2",
            "guid": guid, "password": password + code, "rmp": "0", "why": "signIn"])
    }

    /// Phone-number Apple Accounts in mainland China and India sign in only
    /// when the request names their store (ipatool). The Apple ID itself is
    /// sent unchanged.
    static func phoneNumberStorefront(_ appleID: String) -> String? {
        var number = appleID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        var international = false
        if number.hasPrefix("+") { international = true; number.removeFirst() }
        else if number.hasPrefix("00") { international = true; number.removeFirst(2) }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let china = "143465", india = "143467"
        // Check the full length before removing a country code: a local
        // Indian number can itself start with 91.
        if number.count == 13 && number.hasPrefix("861") { return china }
        if number.count == 12 && number.hasPrefix("91") { number.removeFirst(2) }
        else if international { return nil }
        if number.count == 11 && number.hasPrefix("1") { return china }
        // India also allows a trunk 0 in national numbers.
        if !international && number.count == 11 && number.hasPrefix("0") { number.removeFirst() }
        if number.count == 10, let first = number.first, ("6"..."9").contains(first) { return india }
        return nil
    }

    static func failure(_ response: [String: Any], submittedCode: Bool) -> Error? {
        if let failure = HTTPClient.appleFailure(response) { return failure }
        let message = plistString(response["customerMessage"])
        if message == "MZFinance.BadLogin.Configurator_message" {
            return submittedCode ? AppleLoginError.verificationRejected : AppleLoginError.verificationRequired
        }
        if message.hasPrefix("AMD-Action") {
            return ToolError.message(AppText.text("设备验证未完成，请稍后重试。"))
        }
        if let info = response["accountInfo"] as? [String: Any], !plistString(info["appleId"]).isEmpty { return nil }
        if message.isEmpty, !plistString(response["passwordToken"]).isEmpty { return nil }
        if message.hasPrefix("MZ") { return ToolError.message(AppText.text("Apple 暂时无法完成登录，请稍后重试。")) }
        return ToolError.message(message.isEmpty ? AppText.text("Apple 未返回登录信息，请检查账号后重试。") : message)
    }
}

#if DEBUG
extension AppleService {
    func prepareAccountPreview() {
        accountStorageError = nil
        accounts = [AppleAccount(id: "demo@example.com", name: PreviewData.chinese ? "示例账号" : "Alex Morgan", password: "", cookie: "", dsid: "100000001", passwordToken: "preview-session", storeFront: "", fullStoreFront: ""), AppleAccount(id: "second@example.com", name: PreviewData.chinese ? "另一个账号" : "Sam Lee", password: "", cookie: "", dsid: "100000002", passwordToken: "preview-session", storeFront: "", fullStoreFront: "")]
        activeID = accounts.first?.id
    }
}
#endif
