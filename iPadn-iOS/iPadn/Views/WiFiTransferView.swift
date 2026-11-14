import SwiftUI
import UIKit

/// Lets a computer on the same Wi-Fi download finished packages in a browser.
/// The server runs while this page is open. In the background it keeps going
/// as long as iOS allows; when iOS suspends iPadn it restarts on return, at
/// the same address, so an address sent from another app keeps working.
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
    /// The address of this page visit: kept across a suspension, new when
    /// the page is opened again.
    @State private var sessionKey: String?
    @State private var sessionPort: UInt16?
    @State private var background: UIBackgroundTaskIdentifier = .invalid
    /// iOS ended the background time: start again when iPadn is back.
    @State private var resumeOnReturn = false
    private static let idleLimit: TimeInterval = 600

    private var completedJobFiles: [(job: DownloadJob, file: URL)] {
        manager.jobs.compactMap { job in
            guard job.status == .completed, let file = manager.fileURL(job) else { return nil }
            return (job, file)
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
                Text("在同一 Wi‑Fi 下的电脑浏览器中打开这个地址，即可下载已完成的安装包（\(completedJobFiles.count) 个）。")
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
                Label("只在这个页面打开时运行。切到后台后会在系统允许的时间内继续运行，被系统暂停后回到 iPadn 会在原地址自动恢复；离开页面或闲置 10 分钟会停止。", systemImage: "clock")
                Label("地址里带有随机密钥，每次开启都不同；多次错误访问会自动停止。", systemImage: "key")
                Label("只能下载已完成的安装包，不能上传或修改；只接受局域网内的设备。", systemImage: "lock")
                Label("传输不加密，请只在信任的网络中使用。", systemImage: "exclamationmark.shield")
            } header: { Text("安全") }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .toolPage().navigationTitle("Wi‑Fi 传输").navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear { stop(nil, forget: true) }
        .compatibleOnChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                guard server != nil, background == .invalid else { return }
                // Keep serving while iOS allows, e.g. while the address is sent from another app.
                background = UIApplication.shared.beginBackgroundTask(withName: "iPadn Wi-Fi transfer") {
                    resumeOnReturn = server != nil
                    stop(nil)
                    endBackgroundTime()
                }
            case .active:
                endBackgroundTime()
                if resumeOnReturn { resumeOnReturn = false; Task { await start() } }
            default: break
            }
        }
        .compatibleOnChange(of: completedJobFiles.map { $0.job.id }) { _ in
            guard let running = server else { return }
            let entries = completedJobFiles
            Task {
                let snapshot = await Task.detached(priority: .utility) { Self.items(for: entries) }.value
                running.update(items: snapshot)
            }
        }
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
        starting = true
        defer { starting = false }
        let host = await Task.detached(priority: .userInitiated) { WiFiTransferServer.wifiAddress() }.value
        guard !Task.isCancelled else { return }
        guard let host else {
            issue = AppText.text("请先连接 Wi‑Fi，电脑也需要在同一网络中。")
            return
        }
        let entries = completedJobFiles
        let items = await Task.detached(priority: .userInitiated) {
            Self.items(for: entries)
        }.value
        guard !Task.isCancelled else { return }
        let next = WiFiTransferServer(key: sessionKey)
        next.onAccess = { access in
            accesses.append(access); lastActivity = Date()
            if accesses.count > 50 { accesses.removeFirst(accesses.count - 50) }
        }
        next.onStop = { reason in
            if server === next { server = nil; address = nil; stoppedReason = reason }
        }
        do {
            var reused: UInt16?
            if let previous = sessionPort {
                // After a suspension the old listener can hold the port a moment longer.
                for attempt in 0..<3 where reused == nil && !Task.isCancelled {
                    if attempt > 0 { try? await Task.sleep(for: .milliseconds(120)) }
                    reused = try? await next.start(items: items, port: previous)
                }
            }
            guard !Task.isCancelled else { next.stop(); return }
            // Still taken: same key, new port.
            let port: UInt16
            if let reused { port = reused } else { port = try await next.start(items: items) }
            sessionKey = next.key; sessionPort = port
            server = next
            address = next.url(host: host, port: port)
            lastActivity = Date()
        } catch {
            next.stop()
            issue = error.localizedDescription
        }
    }

    nonisolated private static func items(for entries: [(job: DownloadJob, file: URL)]) -> [WiFiTransferServer.Item] {
        entries.map { job, file in
            .init(id: job.id.uuidString, name: job.app.name.isEmpty ? file.deletingPathExtension().lastPathComponent : job.app.name,
                  version: job.app.version, filename: Self.publicName(file.lastPathComponent, id: job.id), file: file,
                  size: ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? job.app.size)
        }
    }

    private func endBackgroundTime() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    /// `forget` drops the address: the next start gets a new key and port.
    private func stop(_ reason: String?, forget: Bool = false) {
        if forget { sessionKey = nil; sessionPort = nil; resumeOnReturn = false; endBackgroundTime() }
        guard let current = server else { return }
        server = nil; address = nil; stoppedReason = reason
        current.onStop = nil
        current.stop()
    }
}
