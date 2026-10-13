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
        guard let refreshed = active, refreshed.id == account.id else { throw ToolError.message("登录已过期，请重新登录") }
        return refreshed
    }

    func asset(appID: String, versionID: String?, store: StoreContext, useCache: Bool,
               allowLicenseAcquisition: Bool = true) async throws -> DownloadAsset {
        guard let identifier = UInt64(appID), identifier > 0,
              appID.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message("App ID 只能包含数字") }
        if let versionID {
            guard let version = UInt64(versionID), version > 0,
                  versionID.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ToolError.message("版本 ID 只能包含数字") }
        }
        guard store.platform.supportsIPA else {
            throw ToolError.message("Mac 应用请使用「获取 PKG」下载")
        }
        guard let account = active else { throw ToolError.message("请先登录 Apple 账号") }
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
        var asset = try await fetchAsset(appID: appID, versionID: targetVersion, account: account,
                                         useCache: useCache, fallback: false, refreshed: false, purchased: false,
                                         allowLicenseAcquisition: allowLicenseAcquisition)
        let reported = asset.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if store.platform == .tvOS {
            let tvPlatforms = ["tvos", "appletvos", "appletv", "atv9"]
            if !reported.isEmpty && !tvPlatforms.contains(reported) {
                // The standard dispatch can resolve a shared iOS App ID to its
                // iPhone build. Try Apple's alternate version-aware endpoint once
                // before reporting that no verified tvOS file is available.
                if let alternate = try? await fetchAsset(appID: appID, versionID: targetVersion,
                    account: account, useCache: useCache, fallback: true,
                    refreshed: false, purchased: false,
                    allowLicenseAcquisition: allowLicenseAcquisition),
                   alternate.platform.isEmpty || tvPlatforms.contains(alternate.platform.lowercased()) {
                    asset = alternate
                } else {
                    throw ToolError.message("该应用没有可下载的 Apple TV 版本")
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
                throw ToolError.message("该应用没有所选平台的版本，请切换平台后重试")
            }
            asset.platform = store.platform == .iPadOS ? "ipad" : "ios"
        }
        return asset
    }

    private func fetchAsset(appID: String, versionID: String?, account: AppleAccount,
                            useCache: Bool, fallback: Bool, refreshed: Bool, purchased: Bool,
                             allowLicenseAcquisition: Bool) async throws -> DownloadAsset {
        guard activeID == account.id else { throw ToolError.message("账号已切换，请重新执行下载") }
        let root = fallback ? "https://downloaddispatch.itunes.apple.com/up/backgroundUpdateProduct" :
            "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download"
        var payload: [String: Any] = ["guid": guid, "salableAdamId": NSNumber(value: UInt64(appID) ?? 0), "serialNumber": "0"]
        if let versionID = versionID {
            payload[fallback ? "appExtVrsId" : "externalVersionId"] = versionID
        }
        if !fallback {
            guard !account.dsid.isEmpty else { throw ToolError.message("登录已过期，请重新登录") }
            let kbsync = try await signer.kbsync(guid: guid, dsid: account.dsid, useCache: useCache)
            // Node plist builder in the supplied source emits the returned Base64 as a string.
            payload["kbsync"] = kbsync
        }
        let (raw, _) = try await HTTPClient.shared.plist(URL(string: root + "?guid=" + guid)!,
            body: HTTPClient.encodePlist(payload), headers: authHeaders(account))
        let failure = plistString(raw["failureType"])
        if AppleAuthError.requiresReauthentication(raw) { throw AppleAuthError.reauthenticationRequired }
        // Still expired right after a refresh: only signing in again can help.
        if ["2034", "2042"].contains(failure), refreshed { throw AppleAuthError.reauthenticationRequired }
        if ["2034", "2042"].contains(failure), !refreshed {
            let refreshedAccount: AppleAccount
            do { refreshedAccount = try await refresh(account, useCache: useCache) }
            catch {
                if error is AppleLoginError || error is AppleAuthError || error is CancellationError
                    || (error as NSError).domain == NSURLErrorDomain { throw error }
                // The saved password no longer works (changed or wrong): ask for it.
                throw AppleAuthError.reauthenticationRequired
            }
            return try await fetchAsset(appID: appID, versionID: versionID, account: refreshedAccount,
                useCache: useCache, fallback: fallback, refreshed: true, purchased: purchased,
                allowLicenseAcquisition: allowLicenseAcquisition)
        }
        if Self.shouldAcquireLicense(failure: failure, purchased: purchased,
                                     allowLicenseAcquisition: allowLicenseAcquisition) {
            // A missing license does not mean the login session is expired. Refreshing
            // here always calls authenticate and can trigger an invisible 2FA prompt.
            // Acquire the free license using the current valid account first.
            guard activeID == account.id else { throw ToolError.message("账号已切换，请重新执行下载") }
            try await acquireFreeApp(appID, account: account)
            return try await fetchAsset(appID: appID, versionID: versionID, account: account,
                useCache: useCache, fallback: fallback, refreshed: refreshed, purchased: true,
                allowLicenseAcquisition: allowLicenseAcquisition)
        }
        if let error = HTTPClient.appleFailure(raw) { throw error }
        guard let song = (raw["songList"] as? [[String: Any]])?.first else {
            if !fallback {
                return try await fetchAsset(appID: appID, versionID: versionID, account: account,
                    useCache: useCache, fallback: true, refreshed: refreshed, purchased: purchased,
                    allowLicenseAcquisition: allowLicenseAcquisition)
            }
            throw ToolError.message("Apple 没有返回该版本的下载信息")
        }
        guard let url = URL(string: plistString(song["URL"])), url.scheme == "https",
              var metadata = song["metadata"] as? [String: Any] else { throw ToolError.message("暂时无法下载，请稍后重试") }
        guard activeID == account.id else { throw ToolError.message("账号已切换，请重新执行下载") }
        metadata["appleId"] = account.id
        let externalID = plistString(metadata["softwareVersionExternalIdentifier"])
        if let requested = versionID, !externalID.isEmpty, externalID != requested {
            throw ToolError.message("所选版本暂时无法下载，请换个版本重试")
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
        guard let sinf = sinf, !sinf.isEmpty else { throw ToolError.message("此账号没有该应用的下载授权") }
        return DownloadAsset(app: app, url: url, sinf: sinf, metadata: try HTTPClient.encodePlist(metadata),
            externalVersionIDs: (metadata["softwareVersionExternalIdentifiers"] as? [Any] ?? []).map { plistString($0) },
            platform: plistString(metadata["software-platform"]), account: account.id)
    }

    static func shouldAcquireLicense(failure: String, purchased: Bool,
                                     allowLicenseAcquisition: Bool) -> Bool {
        failure == "9610" && !purchased && allowLicenseAcquisition
    }

    private func acquireFreeApp(_ id: String, account: AppleAccount) async throws {
        let payload: [String: Any] = ["appExtVrsId": "0", "buyWithoutAuthorization": "true", "guid": guid,
            "hasAskedToFulfillPreorder": "true", "hasDoneAgeCheck": "true", "price": "0",
            "pricingParameters": "STDQ", "productType": "C", "salableAdamId": id]
        var headers = authHeaders(account); headers["X-Token"] = account.passwordToken
        let (raw, _) = try await HTTPClient.shared.plist(
            URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!,
            body: HTTPClient.encodePlist(payload), headers: headers)
        // A license acquisition can independently require a new trusted-device
        // approval, even when the previous download token was accepted.
        if AppleAuthError.requiresReauthentication(raw) { throw AppleAuthError.reauthenticationRequired }
        if ["2034", "2042"].contains(plistString(raw["failureType"])) ||
           plistString(raw["customerMessage"]) == "MZFinance.BadLogin.Configurator_message" {
            throw AppleLoginError.verificationRequired
        }
        if let error = HTTPClient.appleFailure(raw) { throw error }
        guard raw["jingleDocType"] != nil else { throw ToolError.message("未能获取免费应用许可，请先在 App Store 获取后重试") }
    }

    // Official Apple Mac App Store authorization preflight.
    // This deliberately does NOT create a download task: Mac Store packages
    // can require StoreAgent/dpInfo processing before they become valid XAR.
    // Exposing the encrypted response as a .pkg would corrupt the export.
    func macPackageOffer(_ app: StoreApp, useCache: Bool) async throws -> MacPackageOffer {
        guard let account = active else { throw ToolError.message("请先登录 Apple 账号") }
        guard let appNumber = UInt64(app.id), appNumber > 0 else {
            throw ToolError.message("请输入有效的 Mac 应用 ID")
        }
        let initialID = account.id
        guard let country = StoreService.country(forStorefront: account.storeFront) else {
            throw ToolError.message("无法识别此账号的商店地区，请重新登录后重试")
        }
        // nil when the app is delisted (no product page): the request then
        // omits externalVersionId and the response must still be macOS.
        let versionID = try await MacStoreOfferService.latestVersionID(
            appID: app.id, bundleID: app.bundleID, country: country)
        try Task.checkCancellation()
        guard activeID == initialID else { throw ToolError.message("账号已切换，请重新获取 Mac 下载信息") }
        let deviceID = guid
        guard let serial = MacPackageOffer.serialNumber(guid: deviceID) else {
            throw ToolError.message("登录已过期，请重新登录")
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
        headers["X-Apple-Store-Front"] = account.fullStoreFront.isEmpty ? account.storeFront : account.fullStoreFront
        headers["X-Token"] = account.passwordToken
        let endpoint = URL(string:
            "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=" + deviceID)!
        let (raw, _) = try await HTTPClient.shared.plist(endpoint,
            body: HTTPClient.encodePlist(payload), headers: headers)
        try Task.checkCancellation()
        guard activeID == initialID else { throw ToolError.message("账号已切换，请重新获取 Mac 下载信息") }
        if AppleAuthError.requiresReauthentication(raw) { throw AppleAuthError.reauthenticationRequired }
        if let error = HTTPClient.appleFailure(raw) { throw error }
        var offer: MacPackageOffer
        do {
            offer = try MacPackageOffer.validate(raw, appID: app.id,
                                                 bundleID: app.bundleID, versionID: versionID)
        } catch where versionID == nil {
            throw ToolError.message("该应用已从商店下架，Apple 没有为此账号提供 Mac 版安装包（可能只购买过 iOS 版本，或该应用没有 Mac 版）。")
        }
        offer.hardwareID = deviceID
        return offer
    }

    func ownedApps(useCache: Bool) async throws -> [OwnedApp] {
        guard let account = active else { throw ToolError.message("请先登录 Apple 账号") }
        let base = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
        let query = "('com.apple.itunes.extended\\-media\\-kind:131072')"
        let headers = purchaseHeaders(account)
        let (login, _) = try await HTTPClient.shared.request(URL(string: base + "/login")!, method: "POST", headers: headers, appleRedirects: true)
        try DMAP.validate(login)
        guard let session = try DMAP.firstInteger(login, name: "mlid") else { throw ToolError.message("暂时无法同步购买记录，请稍后重试") }
        let updateBody = Data("session-id=\(session)&revision-number=(null)&query=\(query)".utf8)
        var updateHeaders = headers
        updateHeaders["X-Apple-ActionSignature"] = try await signer.sign(updateBody, guid: guid, useCache: useCache)
        let (update, _) = try await HTTPClient.shared.request(URL(string: base + "/update")!, method: "POST", body: updateBody, headers: updateHeaders, appleRedirects: true)
        try DMAP.validate(update)
        guard let revision = try DMAP.firstInteger(update, name: "musr") else { throw ToolError.message("暂时无法同步购买记录，请稍后重试") }
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


// Trusted metadata only. The URL is obtained from an authenticated Apple
// response; passwords/tokens/dpInfo are never exposed to the UI or logged.
struct MacPackageOffer {
    let downloadURL: URL
    let versionID: String
    let displayVersion: String
    let protectedByApple: Bool
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
            throw ToolError.message("此账号没有该应用 Mac 版的下载授权")
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
            throw ToolError.message("该应用没有可下载的 Mac 版本")
        }
        guard let text = item["URL"] as? String,
              let url = URL(string: text), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else {
            throw ToolError.message("暂时无法下载 Mac 安装包，请稍后重试")
        }
        func bytes(_ value: Any?) -> Data? {
            if let value = value as? Data { return value.isEmpty ? nil : value }
            if let encoded = value as? String, let data = Data(base64Encoded: encoded), !data.isEmpty { return data }
            return nil
        }
        let sinfs = item["sinfs"] as? [[String: Any]] ?? []
        let dpInfos = sinfs.compactMap { bytes($0["dpInfo"]) }
        if let first = dpInfos.first, dpInfos.contains(where: { $0 != first }) {
            throw ToolError.message("暂时无法下载 Mac 安装包，请稍后重试")
        }
        // An iOS-style sinf without dpInfo is evidence of a mobile package,
        // which contradicts the macOS metadata checked above (as in ipatool).
        guard !sinfs.contains(where: { bytes($0["sinf"]) != nil && bytes($0["dpInfo"]) == nil }) else {
            throw ToolError.message("该应用没有可下载的 Mac 版本")
        }
        return MacPackageOffer(downloadURL: url, versionID: actualVersionID,
                               displayVersion: plistString(metadata["bundleShortVersionString"]),
                               protectedByApple: !dpInfos.isEmpty, dpInfo: dpInfos.first)
    }
}

enum AppleAuthError: LocalizedError {
    case reauthenticationRequired
    static func requiresReauthentication(_ response: [String: Any]) -> Bool {
        plistString(response["failureType"]) == "2002"
    }
    var errorDescription: String? {
        "Apple 账号需要重新登录。请输入当前密码，并根据 Apple 的提示完成验证。"
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
