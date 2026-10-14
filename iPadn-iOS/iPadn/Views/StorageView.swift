import SwiftUI

/// How much space downloaded packages take, and a quick way to drop the
/// older versions of apps that have a newer download.
struct StorageView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    @State private var sizes: [UUID: Int64] = [:]
    @State private var available: Int64?
    @State private var measuring = true
    @State private var confirmingCleanup = false
    @State private var pendingDelete: DownloadJob?

    private var completed: [DownloadJob] { manager.jobs.filter { $0.status == .completed && manager.fileURL($0) != nil } }
    /// Finished downloads of an app that also has a newer finished download
    /// for the same platform.
    private var olderVersions: [DownloadJob] {
        var newest: [String: DownloadJob] = [:]
        for job in completed {
            let key = job.updateKey ?? "\(job.platformLabel)|\(job.app.id)|\(job.app.bundleID)"
            if let current = newest[key], !VersionOrder.isNewer(job.app.version, than: current.app.version),
               !(job.app.version == current.app.version && job.createdAt > current.createdAt) { continue }
            newest[key] = job
        }
        let kept = Set(newest.values.map(\.id))
        return completed.filter { !kept.contains($0.id) }
    }
    private func total(_ jobs: [DownloadJob]) -> Int64 { jobs.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }

    var body: some View {
        let completed = completed
        let older = olderVersions
        List {
            Section {
                LabeledContent("安装包", value: measuring ? "正在计算…" : "\(completed.count) 个 · \(total(completed).byteLabel)")
                if let available { LabeledContent("设备可用空间", value: available.byteLabel) }
            } footer: {
                Text("安装包保存在 iPadn 中，也可以在「文件」App 的「我的 iPhone › iPadn › Packages」中查看。")
            }
            if !older.isEmpty {
                Section {
                    Button(role: .destructive) { confirmingCleanup = true } label: {
                        LabeledContent("删除旧版本", value: "\(older.count) 个 · \(total(older).byteLabel)")
                    }
                    .accessibilityIdentifier("storage.remove-older")
                } footer: {
                    Text("同一应用有更新的下载时，删除较旧版本的安装包，每个应用保留最新的一个。")
                }
            }
            if !completed.isEmpty {
                Section("按大小") {
                    ForEach(completed.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }) { job in
                        HStack(spacing: 12) {
                            AppIcon(url: job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.app.name.isEmpty ? job.app.bundleID : job.app.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text([job.platformLabel, job.app.version.isEmpty ? "" : "v\(job.app.version)"]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(sizes[job.id].map(\.byteLabel) ?? "…").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { pendingDelete = job } label: { Label("删除", systemImage: "trash") }.tint(.red)
                        }
                    }
                }
            } else if !measuring {
                Section { Text("还没有下载的安装包。").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .toolPage().navigationTitle("存储空间").navigationBarTitleDisplayMode(.inline)
        .task(id: completed.map(\.id)) { await measure(completed) }
        .refreshable { await measure(self.completed) }
        .actionConfirmation(isPresented: $confirmingCleanup, title: "删除 \(older.count) 个旧版本？",
                            message: "将释放 \(total(older).byteLabel)。每个应用保留最新下载的版本。", confirmTitle: "删除旧版本") {
            remove(older)
        }
        .actionConfirmation(isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            title: "删除这个安装包？", message: "下载任务和文件会一并删除。", confirmTitle: "删除") {
            if let job = pendingDelete { remove([job]) }
            pendingDelete = nil
        }
    }

    private func measure(_ jobs: [DownloadJob]) async {
        let files = jobs.compactMap { job in manager.fileURL(job).map { (job.id, $0) } }
        let result = await Task.detached(priority: .utility) { () -> ([UUID: Int64], Int64?) in
            var sizes: [UUID: Int64] = [:]
            for (id, url) in files {
                sizes[id] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let free = (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
            return (sizes, free)
        }.value
        guard !Task.isCancelled else { return }
        sizes = result.0; available = result.1; measuring = false
    }

    private func remove(_ jobs: [DownloadJob]) {
        let freed = total(jobs)
        var failure: Error?
        for job in jobs {
            do { try manager.remove(job.id) } catch { failure = failure ?? error }
        }
        if let failure { store.errorMessage = failure.localizedDescription }
        else { store.infoMessage = "已释放 \(freed.byteLabel)" }
    }
}
