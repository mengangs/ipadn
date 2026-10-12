import Foundation
import Combine

@MainActor
final class AppleService: ObservableObject {
    @Published private(set) var accounts: [AppleAccount] = []
    @Published private(set) var activeID: String?
    @Published var accountStorageError: String?
    let signer: SAPSigner
    private var loginInProgress = false
    var active: AppleAccount? { accounts.first { $0.id == activeID } }
    var guid: String {
        if let value = LocalResources.defaults.string(forKey: LocalResources.guid) { return value }
        let value = (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
        LocalResources.defaults.set(value, forKey: LocalResources.guid)
        return value
    }

    init(signer: SAPSigner) {
        self.signer = signer
        do { accounts = try KeychainStore.load() } catch { accountStorageError = error.localizedDescription }
        activeID = LocalResources.defaults.string(forKey: LocalResources.activeAccount)
        if !accounts.contains(where: { $0.id == activeID }) { activeID = nil }
    }

    func login(email: String, password: String, code: String, useCache: Bool) async throws {
        if accountStorageError != nil {
            do { accounts = try KeychainStore.load(); accountStorageError = nil }
            catch { accountStorageError = error.localizedDescription; throw error }
        }
        guard !loginInProgress else { throw ToolError.message("另一个账号正在登录，请稍后重试") }
        loginInProgress = true
        defer { loginInProgress = false }
        let initialAccount = activeID
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { throw ToolError.message("请填写 Apple 账号和密码") }
        guard code.isEmpty || (code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber })) else { throw ToolError.message("请输入 6 位数字验证码") }
        let body = try AppleLoginResponse.body(email: email, password: password, code: code, guid: guid)
        let signature = try await signer.sign(body, guid: guid, useCache: useCache)
        let (raw, response) = try await HTTPClient.shared.plist(
            URL(string: "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/")!, body: body,
            headers: ["Content-Type": "application/x-www-form-urlencoded", "X-Apple-ActionSignature": signature])
        if let failure = AppleLoginResponse.failure(raw, submittedCode: !code.isEmpty) { throw failure }
        guard let info = raw["accountInfo"] as? [String: Any], !plistString(info["appleId"]).isEmpty else {
            throw ToolError.message("Apple 未返回完整登录信息，请重试")
        }
        guard !plistString(raw["dsPersonId"]).isEmpty, !plistString(raw["passwordToken"]).isEmpty else {
            throw ToolError.message("Apple 返回的登录凭据不完整，请重新登录")
        }
        let id = plistString(info["appleId"])
        let address = info["address"] as? [String: Any] ?? [:]
        let name = [plistString(address["firstName"]), plistString(address["lastName"])].filter { !$0.isEmpty }.joined(separator: " ")
        let fullStore = response.value(forHTTPHeaderField: "X-Set-Apple-Store-Front") ?? ""
        var cookieHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields { cookieHeaders[String(describing: key)] = String(describing: value) }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: response.url!)
        let cookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let account = AppleAccount(id: id, name: name.isEmpty ? id : name, password: password, cookie: cookie,
                                   dsid: plistString(raw["dsPersonId"]), passwordToken: plistString(raw["passwordToken"]),
                                   storeFront: String(fullStore.split(separator: "-").first ?? ""), fullStoreFront: fullStore)
        let updated = [account] + accounts.filter { $0.id != id }
        try Task.checkCancellation()
        guard activeID == initialAccount else { throw ToolError.message("账号已切换，已停止保存本次登录") }
        try KeychainStore.save(updated)
        accounts = updated; select(id); accountStorageError = nil
    }

    func select(_ id: String?) {
        guard id == nil || accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
        LocalResources.defaults.set(id, forKey: LocalResources.activeAccount)
        signer.clearCache()
    }
    func remove(_ id: String) throws {
        let updated = accounts.filter { $0.id != id }
        try KeychainStore.save(updated)
        accounts = updated
        if activeID == id { select(nil) }
    }
    func verifyCurrentAccount(code: String, expectedID: String, useCache: Bool) async throws {
        guard let account = active, account.id == expectedID else {
            throw ToolError.message("验证期间账号已改变，请重新选择下载账号")
        }
        try await login(email: account.id, password: account.password, code: code, useCache: useCache)
    }

    func refresh(_ account: AppleAccount, useCache: Bool) async throws -> AppleAccount {
        guard activeID == account.id else { throw ToolError.message("账号已切换，请重新执行操作") }
        try await login(email: account.id, password: account.password, code: "", useCache: useCache)
        guard let refreshed = active, refreshed.id == account.id else { throw ToolError.message("刷新登录态失败") }
        return refreshed
    }

    func asset(appID: String, versionID: String?, store: StoreContext, useCache: Bool) async throws -> DownloadAsset {
        guard let identifier = UInt64(appID), identifier > 0,
              appID.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message("App ID 必须是有效的正整数") }
        if let versionID {
            guard let version = UInt64(versionID), version > 0,
                  versionID.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message("版本 ID 必须是有效的正整数") }
        }
        guard store.platform.supportsIPA else {
            throw ToolError.message("原生 Mac App Store 应用不是 iOS IPA，无法使用当前下载方式获取；请在 Mac App Store 下载")
        }
        guard let account = active else { throw ToolError.message("请先在账号页登录 Apple 账号") }
        var targetVersion = versionID
        if store.platform == .tvOS, targetVersion == nil {
            // A tvOS listing may omit externalVersionId. The generic dispatch
            // can still return a build; the IPA family is verified before use.
            targetVersion = try? await StoreService.platformApp(appID, store: store)?.externalVersionID
        }
        var asset = try await fetchAsset(appID: appID, versionID: targetVersion, account: account,
                                         useCache: useCache, fallback: false, refreshed: false, purchased: false)
        let reported = asset.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if store.platform == .tvOS {
            guard reported.isEmpty || ["tvos", "appletvos", "appletv", "atv9"].contains(reported) else {
                throw ToolError.message("Apple 返回的不是 tvOS 版本，已阻止混合下载")
            }
            // Dispatch metadata can omit the platform field. Validate UIDeviceFamily
            // from the actual IPA before reporting this download as completed.
            asset.platform = "appletvos"
        } else {
            guard reported.isEmpty || ["ios", "iphoneos", "ipad"].contains(reported) else {
                throw ToolError.message("Apple 返回的安装包不属于 iOS/iPadOS 平台")
            }
            asset.platform = store.platform == .iPadOS ? "ipad" : "ios"
        }
        return asset
    }

    private func fetchAsset(appID: String, versionID: String?, account: AppleAccount,
                            useCache: Bool, fallback: Bool, refreshed: Bool, purchased: Bool) async throws -> DownloadAsset {
        guard activeID == account.id else { throw ToolError.message("账号已切换，请重新执行下载") }
        let root = fallback ? "https://downloaddispatch.itunes.apple.com/up/backgroundUpdateProduct" :
            "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download"
        var payload: [String: Any] = ["guid": guid, "salableAdamId": NSNumber(value: UInt64(appID) ?? 0), "serialNumber": "0"]
        if let versionID = versionID {
            payload[fallback ? "appExtVrsId" : "externalVersionId"] = versionID
        }
        if !fallback {
            guard !account.dsid.isEmpty else { throw ToolError.message("登录信息缺少 DSID，请重新登录") }
            let kbsync = try await signer.kbsync(guid: guid, dsid: account.dsid, useCache: useCache)
            // Node plist builder in the supplied source emits the returned Base64 as a string.
            payload["kbsync"] = kbsync
        }
        let (raw, _) = try await HTTPClient.shared.plist(URL(string: root + "?guid=" + guid)!,
            body: HTTPClient.encodePlist(payload), headers: authHeaders(account))
        let failure = plistString(raw["failureType"])
        if ["2034", "2042"].contains(failure), !refreshed {
            let refreshedAccount = try await refresh(account, useCache: useCache)
            return try await fetchAsset(appID: appID, versionID: versionID, account: refreshedAccount,
                useCache: useCache, fallback: fallback, refreshed: true, purchased: purchased)
        }
        if failure == "9610", !purchased {
            // A missing license does not mean the login session is expired. Refreshing
            // here always calls authenticate and can trigger an invisible 2FA prompt.
            // Acquire the free license using the current valid account first.
            guard activeID == account.id else { throw ToolError.message("账号已切换，请重新执行下载") }
            try await acquireFreeApp(appID, account: account)
            return try await fetchAsset(appID: appID, versionID: versionID, account: account,
                useCache: useCache, fallback: fallback, refreshed: refreshed, purchased: true)
        }
        if let error = HTTPClient.appleFailure(raw) { throw error }
        guard let song = (raw["songList"] as? [[String: Any]])?.first else {
            if !fallback {
                return try await fetchAsset(appID: appID, versionID: versionID, account: account,
                    useCache: useCache, fallback: true, refreshed: refreshed, purchased: purchased)
            }
            throw ToolError.message("Apple 没有返回该版本的下载信息")
        }
        guard let url = URL(string: plistString(song["URL"])), url.scheme == "https",
              var metadata = song["metadata"] as? [String: Any] else { throw ToolError.message("下载信息缺少 URL 或元数据") }
        guard activeID == account.id else { throw ToolError.message("账号已切换，请重新执行下载") }
        metadata["appleId"] = account.id
        let externalID = plistString(metadata["softwareVersionExternalIdentifier"])
        if let requested = versionID, !externalID.isEmpty, externalID != requested {
            throw ToolError.message("Apple 返回的版本 ID 与请求不一致，已停止下载")
        }
        let artwork = song["artwork-urls"] as? [String: Any]
        let defaultArt = artwork?["default"] as? [String: Any]
        let assetInfo = song["asset-info"] as? [String: Any]
        let app = StoreApp(id: plistString(song["songId"]).isEmpty ? appID : plistString(song["songId"]),
            name: plistString(metadata["bundleDisplayName"]), bundleID: plistString(metadata["softwareVersionBundleId"]),
            version: plistString(metadata["bundleShortVersionString"]), iconURL: StoreService.icon(plistString(defaultArt?["url"])),
            size: (assetInfo?["file-size"] as? NSNumber)?.int64Value ?? 0,
            minimumOS: plistString(metadata["minimumOSVersion"] ?? metadata["minimumOsVersion"]), externalVersionID: externalID)
        let sinfRaw = (song["sinfs"] as? [[String: Any]])?.first?["sinf"]
        let sinf: Data?
        if let data = sinfRaw as? Data { sinf = data }
        else if let string = sinfRaw as? String { sinf = Data(base64Encoded: string, options: .ignoreUnknownCharacters) }
        else { sinf = nil }
        guard let sinf = sinf, !sinf.isEmpty else { throw ToolError.message("下载信息缺少账号授权 sinf，无法生成可用安装包") }
        return DownloadAsset(app: app, url: url, sinf: sinf, metadata: try HTTPClient.encodePlist(metadata),
            externalVersionIDs: (metadata["softwareVersionExternalIdentifiers"] as? [Any] ?? []).map { plistString($0) },
            platform: plistString(metadata["software-platform"]), account: account.id)
    }

    private func acquireFreeApp(_ id: String, account: AppleAccount) async throws {
        let payload: [String: Any] = ["appExtVrsId": "0", "buyWithoutAuthorization": "true", "guid": guid,
            "hasAskedToFulfillPreorder": "true", "hasDoneAgeCheck": "true", "price": "0",
            "pricingParameters": "STDQ", "productType": "C", "salableAdamId": id]
        var headers = authHeaders(account); headers["X-Token"] = account.passwordToken
        let (raw, _) = try await HTTPClient.shared.plist(
            URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!,
            body: HTTPClient.encodePlist(payload), headers: headers)
        if let error = HTTPClient.appleFailure(raw) { throw error }
        guard raw["jingleDocType"] != nil else { throw ToolError.message("未能获取免费应用许可，请先在 App Store 获取后重试") }
    }

    func ownedApps(useCache: Bool) async throws -> [OwnedApp] {
        guard let account = active else { throw ToolError.message("请先登录 Apple 账号") }
        let base = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
        let query = "('com.apple.itunes.extended\\-media\\-kind:131072')"
        let headers = purchaseHeaders(account)
        let (login, _) = try await HTTPClient.shared.request(URL(string: base + "/login")!, method: "POST", headers: headers, appleRedirects: true)
        try DMAP.validate(login)
        guard let session = try DMAP.firstInteger(login, name: "mlid") else { throw ToolError.message("购买记录缺少 session ID") }
        let updateBody = Data("session-id=\(session)&revision-number=(null)&query=\(query)".utf8)
        var updateHeaders = headers
        updateHeaders["X-Apple-ActionSignature"] = try await signer.sign(updateBody, guid: guid, useCache: useCache)
        let (update, _) = try await HTTPClient.shared.request(URL(string: base + "/update")!, method: "POST", body: updateBody, headers: updateHeaders, appleRedirects: true)
        try DMAP.validate(update)
        guard let revision = try DMAP.firstInteger(update, name: "musr") else { throw ToolError.message("购买记录缺少 revision") }
        let payload = DMAP.uint32("mstc", UInt32(Date().timeIntervalSince1970)) + DMAP.uint32("mlid", session) +
            DMAP.tag("mikd", Data([2])) + DMAP.uint32("musr", revision) + DMAP.uint32("mder", 0) +
            DMAP.string("mque", query) + DMAP.tag("aetl")
        let body = DMAP.tag("adsr", payload)
        var itemHeaders = purchaseHeaders(account)
        itemHeaders["Content-Type"] = "application/x-dmap-tagged"
        itemHeaders["X-Apple-ActionSignature"] = try await signer.sign(body, guid: guid, useCache: useCache)
        guard activeID == account.id else { throw ToolError.message("账号已切换，请重新加载购买记录") }
        let (items, _) = try await HTTPClient.shared.request(URL(string: base + "/databases/\(revision)/items")!,
            method: "POST", body: body, headers: itemHeaders, appleRedirects: true)
        try DMAP.validate(items)
        return try DMAP.ownedApps(items)
    }

    private func authHeaders(_ account: AppleAccount) -> [String: String] {
        ["Content-Type": "application/x-www-form-urlencoded", "Cookie": account.cookie,
         "X-Apple-Store-Front": account.storeFront, "X-Dsid": account.dsid, "iCloud-DSID": account.dsid]
    }
    private func purchaseHeaders(_ account: AppleAccount) -> [String: String] {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let iso = ISO8601DateFormatter()
        var headers = authHeaders(account)
        headers.merge(["Accept": "*/*", "Accept-Language": "en-us", "Client-Cloud-DAAP-Request-Reason": "5",
            "Client-Cloud-Purchase-Daap-Version": "1.1/Configurator-2.0", "Client-DAAP-Version": "3.12",
            "Date": date.string(from: now), "X-Apple-I-Client-Time": iso.string(from: now),
            "X-Apple-I-Locale": "en_US", "X-Apple-I-TimeZone": "Local",
            "X-Apple-Store-Front": account.fullStoreFront.isEmpty ? account.storeFront : account.fullStoreFront,
            "X-Apple-TZ": String(TimeZone.current.secondsFromGMT(for: now) / 60), "X-Guid": guid,
            "X-Token": account.passwordToken], uniquingKeysWith: { _, new in new })
        return headers
    }
}


enum AppleLoginError: LocalizedError {
    case verificationRequired, verificationRejected
    var errorDescription: String? {
        switch self {
        case .verificationRequired: return "请在受信任设备上允许登录，然后输入收到的 6 位验证码。"
        case .verificationRejected: return "Apple 未接受本次验证。请检查账号密码，并输入最新的 6 位验证码后重试。"
        }
    }
}

enum AppleLoginResponse {
    static func body(email: String, password: String, code: String, guid: String) throws -> Data {
        try HTTPClient.encodePlist(["appleId": email, "attempt": code.isEmpty ? "1" : "2",
            "guid": guid, "password": password + code, "rmp": "0", "why": "signIn"])
    }

    static func failure(_ response: [String: Any], submittedCode: Bool) -> Error? {
        if let failure = HTTPClient.appleFailure(response) { return failure }
        let message = plistString(response["customerMessage"])
        if message == "MZFinance.BadLogin.Configurator_message" {
            return submittedCode ? AppleLoginError.verificationRejected : AppleLoginError.verificationRequired
        }
        if let info = response["accountInfo"] as? [String: Any], !plistString(info["appleId"]).isEmpty { return nil }
        if message.hasPrefix("MZ") { return ToolError.message("Apple 暂时无法完成登录，请稍后重试。") }
        return ToolError.message(message.isEmpty ? "Apple 未返回登录信息，请检查账号后重试。" : message)
    }
}

#if DEBUG
extension AppleService {
    func prepareAccountPreview() {
        accountStorageError = nil
        accounts = [AppleAccount(id: "demo@example.com", name: "示例账号", password: "", cookie: "", dsid: "", passwordToken: "", storeFront: "", fullStoreFront: ""), AppleAccount(id: "second@example.com", name: "另一个账号", password: "", cookie: "", dsid: "", passwordToken: "", storeFront: "", fullStoreFront: "")]
        activeID = accounts.first?.id
    }
}
#endif
