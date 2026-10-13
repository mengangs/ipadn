import Foundation
import WebKit
import Combine
import CryptoKit
import UIKit

@MainActor
final class SAPSigner: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published private(set) var isPresented = false
    @Published private(set) var webView: WKWebView?
    @Published private(set) var title = "正在验证请求"
    @Published private(set) var stage = "准备本地环境"
    @Published private(set) var stageIndex = 0
    @Published private(set) var startedAt = Date()
    let server = LoopbackServer()
    private var operationID: UUID?
    private var navigation: CheckedContinuation<Void, Error>?
    private var evaluation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var terminalError: Error?
    private var signatureCache: [String: String] = [:]
    private var kbCache: [String: String] = [:]
    private var cacheRevision = UUID()
    private var reusableWebView: WKWebView?
    private var reusableBase: URL?
    private var idleTimeout: Task<Void, Never>?
    private var memoryObserver: AnyCancellable?

    override init() {
        super.init()
        memoryObserver = Publishers.Merge(
            NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification),
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification))
            .sink { [weak self] _ in
                Task { @MainActor in self?.discardIdleRuntime() }
            }
    }

    func sign(_ data: Data, guid: String, useCache: Bool) async throws -> String {
        let key = guid + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        if useCache, let cached = signatureCache[key] { return cached }
        let revision = cacheRevision
        let result = try await execute(title: "验证请求", script: """
            reportStage(1);
            await sapInitialize(guid, {proxyURL: proxy});
            try { reportStage(2); return await sapSign(body); }
            finally { await sapClose(); }
            """, arguments: ["guid": guid, "body": data.base64EncodedString()], reuseRuntime: useCache)
        if useCache, revision == cacheRevision {
            if signatureCache.count >= 128 { signatureCache.removeAll() }
            signatureCache[key] = result
        }
        return result
    }

    func kbsync(guid: String, dsid: String, useCache: Bool) async throws -> String {
        guard guid.count == 12, guid.allSatisfy(\.isHexDigit), let value = UInt64(dsid), value > 0 else {
            throw ToolError.message("设备标识或账号标识无效，请重新登录")
        }
        try Task.checkCancellation()
        let key = guid + ":" + dsid
        if useCache, let cached = kbCache[key] { return cached }
        let revision = cacheRevision
        let result = try await execute(title: "准备下载", script: """
            reportStage(1);
            await loadSapSigner();
            reportStage(2);
            return await sapGenerateKBSync(guid, dsid);
            """, arguments: ["guid": guid, "dsid": dsid], reuseRuntime: useCache)
        if useCache, revision == cacheRevision { kbCache[key] = result }
        return result
    }

    func execute(title: String, script: String, arguments: [String: Any], timeoutSeconds: UInt64 = 180, reuseRuntime: Bool = true) async throws -> String {
        guard operationID == nil else { throw ToolError.message("另一项验证正在进行，请完成或取消后重试") }
        let id = UUID(); operationID = id; terminalError = nil
        let revision = cacheRevision
        var succeeded = false
        idleTimeout?.cancel(); idleTimeout = nil
        self.title = title; stage = "准备本地环境"; stageIndex = 0; startedAt = Date()
        defer { release(id: id, reuse: reuseRuntime && succeeded && cacheRevision == revision) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await server.start()
            try checkActive(id)
            guard let base = server.baseURL else { throw ToolError.message("暂时无法完成验证，请重试") }
            let web: WKWebView
            let warm = reuseRuntime && reusableBase == base && reusableWebView != nil
            if warm, let saved = reusableWebView { web = saved }
            else {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                web = WKWebView(frame: .zero, configuration: config)
            }
            reusableWebView = nil; reusableBase = nil
            web.configuration.userContentController.add(self, name: "progress")
            web.navigationDelegate = self
            webView = web; isPresented = true
            if !warm {
                armTimeout(id: id, seconds: 45, message: "本地验证环境加载超时，请重试。")
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    navigation = continuation
                    web.load(URLRequest(url: base.appendingPathComponent("runtime/index.html")))
                }
            } else {
                stage = "复用本机验证组件"
            }
            try checkActive(id)
            armTimeout(id: id, seconds: timeoutSeconds, message: "验证已超过 3 分钟，已停止本次操作。请保持应用在前台后重试。")
            var values = arguments
            values["proxy"] = base.appendingPathComponent("proxy").absoluteString
            let result: String = try await withCheckedThrowingContinuation { continuation in
                evaluation = continuation
                web.callAsyncJavaScript(script, arguments: values, in: nil, in: .page) { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.operationID == id, let continuation = self.evaluation else { return }
                        self.evaluation = nil
                        switch result {
                        case .success(let value):
                            if let text = value as? String, !text.isEmpty { continuation.resume(returning: text) }
                            else { continuation.resume(throwing: ToolError.message("验证结果为空，请重试")) }
                        case .failure:
                            continuation.resume(throwing: ToolError.message("验证未完成，请检查网络后重试"))
                        }
                    }
                }
            }
            try checkActive(id)
            succeeded = true
            return result
        } onCancel: { [weak self] in
            Task { @MainActor in self?.stop(id: id, error: CancellationError()) }
        }
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard operationID == id else { throw CancellationError() }
    }
    private func armTimeout(id: UUID, seconds: UInt64, message: String) {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            self?.stop(id: id, error: ToolError.message(message))
        }
    }
    private func finishNavigation(_ result: Result<Void, Error>) {
        let continuation = navigation; navigation = nil
        continuation?.resume(with: result)
    }
    private func stop(id: UUID, error: Error) {
        guard operationID == id else { return }
        terminalError = error
        finishNavigation(.failure(error))
        let continuation = evaluation; evaluation = nil
        continuation?.resume(throwing: error)
        timeout?.cancel()
        webView?.stopLoading()
        webView?.loadHTMLString("<!doctype html><title>Stopped</title>", baseURL: nil)
        isPresented = false
    }
    func cancel() {
        if let id = operationID { stop(id: id, error: CancellationError()) }
    }
    private func release(id: UUID, reuse: Bool) {
        guard operationID == id else { return }
        timeout?.cancel(); timeout = nil
        finishNavigation(.failure(CancellationError()))
        let continuation = evaluation; evaluation = nil
        continuation?.resume(throwing: CancellationError())
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "progress")
        webView?.stopLoading(); webView?.navigationDelegate = nil
        if reuse && UIApplication.shared.applicationState != .background {
            reusableWebView = webView; reusableBase = server.baseURL
            idleTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                self?.discardIdleRuntime()
            }
        } else { reusableWebView = nil; reusableBase = nil }
        webView = nil; isPresented = false; operationID = nil; terminalError = nil
    }
    private func discardIdleRuntime() {
        guard operationID == nil else { return }
        idleTimeout?.cancel(); idleTimeout = nil
        reusableWebView?.stopLoading(); reusableWebView = nil; reusableBase = nil
    }
    func clearCache() { cacheRevision = UUID(); signatureCache.removeAll(); kbCache.removeAll(); discardIdleRuntime() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, operationID != nil, let index = message.body as? Int, (1...2).contains(index) else { return }
        stageIndex = index
        stage = index == 1 ? "加载验证组件" : title == "准备下载" ? "生成下载授权数据" : "生成请求签名"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, terminalError == nil else { return }
        finishNavigation(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }; finishNavigation(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }; finishNavigation(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, let id = operationID else { return }
        stop(id: id, error: ToolError.message("验证意外中断，请重试"))
    }
}
