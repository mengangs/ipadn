import Foundation
import WebKit
import Combine
import CryptoKit

@MainActor
final class SAPSigner: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isPresented = false
    @Published var webView: WKWebView?
    @Published var title = "正在准备签名"
    let server = LoopbackServer()
    private var navigation: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var pending: Task<String, Error>?
    private var signatureCache: [String: String] = [:]
    private var kbCache: [String: String] = [:]

    func sign(_ data: Data, guid: String, useCache: Bool) async throws -> String {
        let key = guid + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if useCache, let cached = signatureCache[key] { return cached }
        let previous = pending
        let operation = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            self.title = "SAP 签名"
            try await self.prepare(mode: "sign")
            let watchdog = self.watchdog()
            defer { watchdog.cancel(); self.release() }
            guard let web = self.webView, let base = self.server.baseURL else { throw ToolError.message("签名环境未就绪") }
            let result = try await web.callAsyncJavaScript("""
                setSigningStatus('正在准备签名', '正在加载本地签名引擎，请保持应用在前台');
                await sapInitialize(guid, {proxyURL: proxy});
                try {
                    setSigningStatus('正在安全签名', '正在生成请求签名');
                    return await sapSign(body);
                } finally { await sapClose(); }
                """, arguments: ["guid": guid, "proxy": base.appendingPathComponent("proxy").absoluteString,
                                   "body": data.base64EncodedString()], in: nil, contentWorld: .page)
            try Task.checkCancellation()
            guard let signature = result as? String, !signature.isEmpty else { throw ToolError.message("签名引擎返回了空结果") }
            if useCache {
                if self.signatureCache.count >= 128 { self.signatureCache.removeAll() }
                self.signatureCache[key] = signature
            }
            return signature
        }
        pending = operation
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }

    func kbsync(guid: String, dsid: String, useCache: Bool) async throws -> String {
        guard guid.count == 12, guid.allSatisfy(\.isHexDigit), let value = UInt64(dsid), value > 0 else {
            throw ToolError.message("设备标识或 DSID 无效")
        }
        let key = guid + ":" + dsid
        if useCache, let cached = kbCache[key] { return cached }
        let previous = pending
        let operation = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            self.title = "初始化下载"
            try await self.prepare(mode: "kbsync")
            let watchdog = self.watchdog()
            defer { watchdog.cancel(); self.release() }
            guard let web = self.webView else { throw ToolError.message("下载初始化环境未就绪") }
            let result = try await web.callAsyncJavaScript("""
                setSigningStatus('初始化下载，请稍等', '正在准备下载所需数据，请保持应用在前台');
                await loadSapSigner();
                await new Promise(resolve => setTimeout(resolve, 100));
                return await sapGenerateKBSync(guid, dsid);
                """, arguments: ["guid": guid, "dsid": dsid], in: nil, contentWorld: .page)
            try Task.checkCancellation()
            guard let value = result as? String, !value.isEmpty else { throw ToolError.message("下载初始化结果为空") }
            if useCache { self.kbCache[key] = value }
            return value
        }
        pending = operation
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }

    private func prepare(mode: String) async throws {
        try await server.start()
        guard let base = server.baseURL else { throw ToolError.message("无法启动本地签名服务") }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        webView = web; isPresented = true
        var components = URLComponents(url: base.appendingPathComponent("runtime/index.html"), resolvingAgainstBaseURL: false)!
        if mode == "kbsync" { components.fragment = "kbsync" }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                navigation = continuation
                web.load(URLRequest(url: components.url!))
                navigationTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                    self?.finishNavigation(.failure(ToolError.message("加载本地签名页面超时")))
                }
            }
        } catch { release(); throw error }
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        let continuation = navigation; navigation = nil
        navigationTimeout?.cancel(); navigationTimeout = nil
        continuation?.resume(with: result)
    }
    private func watchdog() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
            self?.cancel()
        }
    }
    func cancel() {
        pending?.cancel()
        webView?.loadHTMLString("<html><body>操作已取消</body></html>", baseURL: nil)
        release()
    }
    private func release() {
        finishNavigation(.failure(CancellationError()))
        webView?.stopLoading(); webView?.navigationDelegate = nil
        webView = nil; isPresented = false
    }
    func clearCache() { signatureCache.removeAll(); kbCache.removeAll() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNavigation(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNavigation(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNavigation(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(ToolError.message("签名引擎内存不足或进程退出，请重试")))
    }
}
