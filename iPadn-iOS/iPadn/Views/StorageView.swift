import SwiftUI

/// How much space downloaded packages take, and a quick way to drop the
/// older versions of apps that have a newer download.
struct StorageView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    #if canImport(TestFlightKit)
    @ObservedObject private var tfProducts = TFProductIndex.shared
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sizes: [String: Int64] = [:]
    @State private var available: Int64?
    @State private var measuring = true
    @State private var confirmingCleanup = false
    @State private var pendingDelete: StorageEntry?
    @State private var deleting = false

    private enum StorageEntry: Identifiable {
        case job(DownloadJob)
        #if canImport(TestFlightKit)
        case tf(TFProductItem)
        #endif

        var id: String {
            switch self {
            case .job(let job): return "job:" + job.id.uuidString
            #if canImport(TestFlightKit)
            case .tf(let item): return "tf:" + item.bundleID
            #endif
            }
        }
    }

    private var completed: [DownloadJob] { manager.jobs.filter { $0.status == .completed && manager.fileURL($0) != nil } }

    private var entries: [StorageEntry] {
        var list: [StorageEntry] = completed.map { .job($0) }
        #if canImport(TestFlightKit)
        for item in tfProducts.items where FileManager.default.fileExists(atPath: item.fileURL.path) {
            list.append(.tf(item))
        }
        #endif
        return list
    }

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
    private func size(of entry: StorageEntry) -> Int64 {
        if let measured = sizes[entry.id] { return measured }
        switch entry {
        case .job: return 0
        #if canImport(TestFlightKit)
        case .tf(let item): return item.fileSize
        #endif
        }
    }
    private func total(_ entries: [StorageEntry]) -> Int64 { entries.reduce(0) { $0 + size(of: $1) } }
    private func totalJobs(_ jobs: [DownloadJob]) -> Int64 { jobs.reduce(0) { $0 + (sizes["job:" + $1.id.uuidString] ?? 0) } }

    var body: some View {
        let allEntries = entries
        let older = olderVersions
        List {
            Section {
                LabeledContent("安装包", value: measuring ? AppText.text("正在计算…") : AppText.text("\(allEntries.count) 个 · \(total(allEntries).byteLabel)"))
                if let available { LabeledContent("设备可用空间", value: available.byteLabel) }
            } footer: {
                Text("安装包保存在 iPadn 中，也可以在「文件」App 的「我的 iPhone › iPadn › Packages」中查看。")
            }
            if !older.isEmpty {
                Section {
                    Button(role: .destructive) { confirmingCleanup = true } label: {
                        LabeledContent("删除旧版本", value: AppText.text("\(older.count) 个 · \(totalJobs(older).byteLabel)"))
                    }
                    .accessibilityIdentifier("storage.remove-older")
                } footer: {
                    Text("同一应用有更新的下载时，删除较旧版本的安装包，每个应用保留最新的一个。")
                }
            }
            if !allEntries.isEmpty {
                Section("按大小") {
                    ForEach(allEntries.sorted { size(of: $0) > size(of: $1) }) { entry in
                        entryRow(entry)
                    }
                }
            } else if !measuring {
                Section { Text("还没有下载的安装包。").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .animation(UX.motion(reduceMotion), value: allEntries.map(\.id))
        .disabled(deleting)
        .overlay { if deleting { ProgressView("正在删除…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .toolPage().navigationTitle("存储空间").navigationBarTitleDisplayMode(.inline)
        .task {
            #if canImport(TestFlightKit)
            tfProducts.refresh()
            #endif
        }
        .task(id: allEntries.map(\.id)) { await measure(allEntries) }
        .refreshable {
            #if canImport(TestFlightKit)
            tfProducts.refresh()
            #endif
            await measure(self.entries)
        }
        .actionConfirmation(isPresented: $confirmingCleanup, title: "删除 \(older.count) 个旧版本？",
                            message: "将释放 \(totalJobs(older).byteLabel)。每个应用保留最新下载的版本。", confirmTitle: "删除旧版本") {
            remove(older)
        }
        .actionConfirmation(isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            title: "删除这个安装包？", message: "下载任务和文件会一并删除。", confirmTitle: "删除") {
            if let entry = pendingDelete { removeEntry(entry) }
            pendingDelete = nil
        }
    }

    @ViewBuilder private func entryRow(_ entry: StorageEntry) -> some View {
        switch entry {
        case .job(let job):
            HStack(spacing: 12) {
                AppIcon(url: job.displayApp(packageIcon: manager.packageIconURL(job)).iconURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.app.name.isEmpty ? job.app.bundleID : job.app.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text([job.platformLabel, job.app.version.isEmpty ? "" : "v\(job.app.version)"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(sizes[entry.id].map(\.byteLabel) ?? "…").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .revealDelete(id: "storage." + entry.id, enabled: !deleting) { pendingDelete = entry }
        #if canImport(TestFlightKit)
        case .tf(let item):
            HStack(spacing: 12) {
                AppIcon(url: item.iconURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        TestFlightIcon(size: 13)
                        if !item.versionBuildLabel.isEmpty {
                            Text(verbatim: item.versionBuildLabel)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                Text((sizes[entry.id] ?? item.fileSize).byteLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .revealDelete(id: "storage." + entry.id, enabled: !deleting) { pendingDelete = entry }
        #endif
        }
    }

    private func measure(_ entries: [StorageEntry]) async {
        let files: [(String, URL)] = entries.compactMap { entry in
            switch entry {
            case .job(let job):
                return manager.fileURL(job).map { (entry.id, $0) }
            #if canImport(TestFlightKit)
            case .tf(let item):
                return (entry.id, item.fileURL)
            #endif
            }
        }
        let result = await Task.detached(priority: .utility) { () -> ([String: Int64], Int64?) in
            var sizes: [String: Int64] = [:]
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

    private func removeEntry(_ entry: StorageEntry) {
        switch entry {
        case .job(let job):
            remove([job])
        #if canImport(TestFlightKit)
        case .tf(let item):
            guard !FairPlayPresentation.shared.protects(url: item.fileURL) else {
                store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
                return
            }
            let freed = size(of: entry)
            guard !deleting else { return }
            deleting = true
            defer { deleting = false }
            TFProductIndex.shared.delete(item)
            sizes.removeValue(forKey: entry.id)
            store.infoMessage = AppText.text("已释放 \(freed.byteLabel)")
        #endif
        }
    }

    private func remove(_ jobs: [DownloadJob]) {
        guard !jobs.contains(where: { FairPlayPresentation.shared.protects($0.id) }) else {
            store.errorMessage = AppText.text("安装包正在解密，请等待处理结束后再删除。")
            return
        }
        let freed = totalJobs(jobs)
        guard !deleting else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await manager.removeBatch(Set(jobs.map(\.id)))
                store.infoMessage = AppText.text("已释放 \(freed.byteLabel)")
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}
