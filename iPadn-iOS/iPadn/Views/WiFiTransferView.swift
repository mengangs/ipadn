import SwiftUI
import UIKit

/// Lets a computer on the same Wi-Fi download finished packages in a browser.
/// The server runs only while this page is open and iPadn is in front.
struct WiFiTransferView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var server: WiFiTransferServer?
    @State private var address: URL?
    @State private var accesses: [WiFiTransferServer.Access] = []
    @State private var issue: String?
    @State private var stoppedReason: String?
    @State private var lastActivity = Date()
    @State private var starting = false
    private static let idleLimit: TimeInterval = 600

    private var items: [WiFiTransferServer.Item] {
        manager.jobs.compactMap { job in
            guard job.status == .completed, let file = manager.fileURL(job) else { return nil }
            return .init(id: job.id.uuidString, name: job.app.name.isEmpty ? file.deletingPathExtension().lastPathComponent : job.app.name,
                         version: job.app.version, filename: Self.publicName(file.lastPathComponent, id: job.id), file: file,
                         size: ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? job.app.size)
        }
    }

    /// Stored packages start with the task's ID; the computer gets the readable rest.
    static func publicName(_ stored: String, id: UUID) -> String {
        let prefix = id.uuidString + "-"
        return stored.hasPrefix(prefix) ? String(stored.dropFirst(prefix.count)) : stored
    }

    var body: some View {
        Form {
            Section {
                if let address {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("正在传输", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: address.absoluteString)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("transfer.address")
                        HStack(spacing: 12) {
                            Button("拷贝地址", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = address.absoluteString; UX.feedback()
                            }
                            ShareLink(item: address) { Label("分享", systemImage: "square.and.arrow.up") }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                    Button("停止传输", role: .destructive) { stop(nil) }
                } else if starting {
                    HStack(spacing: 10) { ProgressView(); Text("正在开启…").foregroundStyle(.secondary) }
                } else {
                    if let issue { InlineIssue(message: issue) }
                    else if let stoppedReason { Text(stoppedReason).foregroundStyle(.secondary) }
                    Button("开始传输", systemImage: "wifi") { Task { await start() } }
                        .accessibilityIdentifier("transfer.start")
                }
            } footer: {
                Text("在同一 Wi‑Fi 下的电脑浏览器中打开这个地址，即可下载已完成的安装包（\(items.count) 个）。")
            }
            if !accesses.isEmpty {
                Section("访问记录") {
                    ForEach(accesses.reversed()) { access in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: access.filename).lineLimit(1)
                            Text(verbatim: "\(access.client) · \(access.date.formatted(date: .omitted, time: .standard))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Label("只在这个页面打开且 iPadn 在前台时运行；离开页面、切到后台或闲置 10 分钟会自动停止。", systemImage: "clock")
                Label("地址里带有随机密钥，每次开启都不同；多次错误访问会自动停止。", systemImage: "key")
                Label("只能下载已完成的安装包，不能上传或修改；只接受局域网内的设备。", systemImage: "lock")
                Label("传输不加密，请只在信任的网络中使用。", systemImage: "exclamationmark.shield")
            } header: { Text("安全") }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .toolPage().navigationTitle("Wi‑Fi 传输").navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear { stop(nil) }
        .compatibleOnChange(of: scenePhase) { phase in
            if phase == .background, server != nil { stop(AppText.text("iPadn 切到后台，传输已停止。")) }
        }
        .compatibleOnChange(of: items.map(\.id)) { _ in server?.update(items: items) }
        .task(id: address) {
            // Stops after ten minutes without a download.
            while address != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if address != nil, Date().timeIntervalSince(lastActivity) > Self.idleLimit {
                    stop(AppText.text("闲置超过 10 分钟，传输已停止。"))
                }
            }
        }
    }

    private func start() async {
        guard server == nil, !starting else { return }
        issue = nil; stoppedReason = nil
        guard let host = WiFiTransferServer.wifiAddress() else {
            issue = AppText.text("请先连接 Wi‑Fi，电脑也需要在同一网络中。")
            return
        }
        starting = true
        defer { starting = false }
        let next = WiFiTransferServer()
        next.onAccess = { access in
            accesses.append(access); lastActivity = Date()
            if accesses.count > 50 { accesses.removeFirst(accesses.count - 50) }
        }
        next.onStop = { reason in
            if server === next { server = nil; address = nil; stoppedReason = reason }
        }
        do {
            let port = try await next.start(items: items)
            server = next
            address = next.url(host: host, port: port)
            lastActivity = Date()
        } catch {
            next.stop()
            issue = error.localizedDescription
        }
    }

    private func stop(_ reason: String?) {
        guard let current = server else { return }
        server = nil; address = nil; stoppedReason = reason
        current.onStop = nil
        current.stop()
    }
}
