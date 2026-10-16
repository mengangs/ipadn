import SwiftUI

struct PurchasedView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @EnvironmentObject private var manager: DownloadManager
    @State private var term = ""
    /// `term` after typing pauses: large purchase lists filter once, not per key.
    @State private var query = ""
    @State private var months = 0
    @State private var showLogin = false
    @State private var getting: StoreApp?
    @State private var headerAway = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var batchProgress: (done: Int, total: Int)?
    @State private var showsSyncSpinner = false
    /// Only purchases no longer on sale in the account's storefront.
    @State private var delistedOnly = false
    @State private var share: SharedFile?
    private var filtered: [OwnedApp] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? .distantPast
        let term = query.trimmingCharacters(in: .whitespaces)
        if term.isEmpty && months == 0 && !delistedOnly { return store.owned }
        return store.owned.filter {
            (!delistedOnly || store.ownedListed[$0.id] == false) &&
            (months == 0 || ($0.purchaseDate ?? .distantPast) >= cutoff) &&
            (term.isEmpty || $0.id.contains(term) || $0.name.localizedCaseInsensitiveContains(term) || $0.bundleID.localizedCaseInsensitiveContains(term))
        }
    }
    /// Download state per App ID: a newer store version first, then downloaded.
    private var downloadBadges: [String: (text: String, tint: Color)] {
        var badges: [String: (text: String, tint: Color)] = [:]
        // Purchases are iPhone and iPad apps; a Mac or Apple TV download under
        // a shared App ID is a different package.
        for job in manager.jobs where job.status == .completed && [AppPlatform.iOS, .iPadOS].contains(job.updatePlatform) {
            if let key = job.updateKey, let latest = store.availableUpdates[key] {
                badges[job.app.id] = ("有新版本 \(latest.version)", UX.tint)
            } else if badges[job.app.id] == nil {
                badges[job.app.id] = (job.app.version.isEmpty ? "已下载" : "已下载 \(job.app.version)", .green)
            }
        }
        return badges
    }
    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        UX.feedback()
    }
    private func storeApp(_ app: OwnedApp) -> StoreApp {
        var listing = app.storeApp
        if store.ownedListed[app.id] == false { listing.delisted = true }
        return listing
    }
    private func findDelisted() {
        Task {
            guard let count = await store.checkOwnedListings() else {
                if !store.checkingListings { store.errorMessage = "暂时无法检查商店状态，请稍后重试。" }
                return
            }
            if count == 0 { store.infoMessage = "所有已购应用都还在售"; return }
            withAnimation { delistedOnly = true; term = ""; query = ""; months = 0 }
        }
    }
    private func export() {
        do { share = SharedFile(url: try store.exportOwned()) }
        catch { store.errorMessage = "导出失败：" + error.localizedDescription }
    }
    /// Adds the selected apps one after another; the list order is kept.
    private func downloadSelected() {
        download(store.owned.filter { selection.contains($0.id) }.map(\.storeApp))
    }
    private func download(_ apps: [StoreApp]) {
        guard !apps.isEmpty, batchProgress == nil else { return }
        batchProgress = (0, apps.count)
        Task {
            let result = await store.startDownloads(apps) { done in batchProgress = (done, apps.count) }
            batchProgress = nil
            if result.added > 0 {
                selection.removeAll(); selecting = false
                store.infoMessage = "已添加 \(result.added) 个下载任务"
            }
            if !result.failures.isEmpty { store.errorMessage = result.failures.joined(separator: "\n") }
        }
    }
    var body: some View {
        List {
            Section {
                PageHeader(title: "已购项目") {
                    Menu {
                        Button("找出已下架的应用", systemImage: "archivebox") { findDelisted() }
                            .disabled(store.owned.isEmpty || store.checkingListings)
                        Button("导出为表格", systemImage: "tablecells") { export() }
                            .disabled(store.owned.isEmpty)
                    } label: {
                        ZStack {
                            if store.checkingListings { ProgressView().controlSize(.small) }
                            else { Image(systemName: "ellipsis").font(.body.weight(.semibold)) }
                        }
                        .frame(width: 36, height: 36).background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .disabled(apple.active == nil || selecting)
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("purchased.more")
                    // Syncing shows in this button, not as a row that pushes the list.
                    Button { if !store.ownedLoading { Task { await store.refreshOwned() } } } label: {
                        ZStack {
                            if showsSyncSpinner { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)) }
                        }
                        .frame(width: 36, height: 36).background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(apple.active == nil || selecting)
                    .accessibilityLabel(store.ownedLoading ? "正在同步购买记录" : "同步购买记录")
                    .revealAfterDelay(store.ownedLoading, into: $showsSyncSpinner)
                }
                .onScrolledUnderBar { headerAway = $0 }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if let account = apple.active {
                Section {
                    SearchInput(text: $term, placeholder: "搜索已购项目或 App ID", capsule: true)
                    Picker("购买时间", selection: $months) {
                        Text("全部").tag(0); Text("1 个月").tag(1); Text("6 个月").tag(6); Text("1 年").tag(12)
                    }.pickerStyle(.segmented)
                } footer: {
                    Text("账号：\(account.id)")
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                if let error = store.ownedError { Section { InlineIssue(message: error) { Task { await store.refreshOwned() } } } }
                if delistedOnly {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "archivebox.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已下架但仍可下载").font(.subheadline.weight(.semibold))
                                Text("这些应用已不在商店出售，你的账号仍可下载，建议尽快备份。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("显示全部") { withAnimation { delistedOnly = false } }
                                .font(.subheadline).buttonStyle(.borderless)
                        }
                        let backups = filtered
                        if !backups.isEmpty {
                            Button {
                                download(backups.map(\.storeApp))
                            } label: {
                                Label(batchProgress.map { "正在添加 \($0.done)/\($0.total)" } ?? "全部备份（\(backups.count) 个）",
                                      systemImage: "square.and.arrow.down.on.square")
                                    .fontWeight(.semibold)
                            }
                            .disabled(batchProgress != nil)
                            .accessibilityIdentifier("purchased.backup-all")
                        }
                    }
                }
                let visible = filtered
                if store.ownedLoading && store.owned.isEmpty {
                    Section {
                        HStack { ProgressView(); Text("正在同步购买记录…").font(.subheadline).foregroundStyle(.secondary) }
                        AppSkeleton(); AppSkeleton(); AppSkeleton()
                    }
                }
                let badges = downloadBadges
                if !visible.isEmpty {
                    Section {
                        ForEach(visible) { app in
                            let subtitle = app.purchaseDate.map {
                                "购于 \($0.formatted(.dateTime.year().month(.defaultDigits).day()))"
                            }
                            if selecting {
                                Button { toggle(app.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selection.contains(app.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2)
                                            .foregroundStyle(selection.contains(app.id) ? Color.accentColor : Color.secondary)
                                            .contentTransition(.symbolEffect(.replace))
                                        AppRow(app: storeApp(app), subtitle: subtitle, badge: badges[app.id])
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel((selection.contains(app.id) ? "取消选择 " : "选择 ") + app.name)
                            } else {
                                NavigationLink { AppDetailView(app: storeApp(app)) } label: {
                                    AppRow(app: storeApp(app), subtitle: subtitle, badge: badges[app.id]) {
                                        RowCapsule(title: "下载") { getting = app.storeApp; UX.feedback() }
                                            .accessibilityLabel("下载 \(app.name)")
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(visible.count) 个项目")
                            Spacer()
                            Button(selecting ? "完成" : "选择") {
                                withAnimation(.snappy) { selecting.toggle(); selection.removeAll() }
                            }
                            .font(.body.weight(.semibold))
                            .textCase(nil)
                            .buttonStyle(.borderless)
                            .disabled(batchProgress != nil)
                            .accessibilityIdentifier("purchased.select")
                        }
                    }
                } else if !store.ownedLoading && store.ownedError == nil {
                    Section {
                        if delistedOnly && term.isEmpty && months == 0 {
                            EmptyState(title: "没有已下架的应用", message: "你获取过的应用都还在商店出售。", symbol: "checkmark.seal", actionTitle: "显示全部", action: { delistedOnly = false })
                        } else if term.isEmpty && months == 0 {
                            EmptyState(title: "暂无已购记录", message: "同步后可在这里查找并下载你获取过的应用。", symbol: "clock.arrow.circlepath", actionTitle: "立即同步", action: { Task { await store.refreshOwned() } })
                        } else {
                            EmptyState(title: "没有匹配的应用", message: "换个关键词，或调整时间范围。", symbol: "line.3.horizontal.decrease.circle", actionTitle: "清除筛选", action: { term = ""; query = ""; months = 0 })
                        }
                    }
                }
            } else {
                Section { EmptyState(title: "尚未登录", message: "登录后即可查看你获取过的应用。", symbol: "person.crop.circle.badge.checkmark", actionTitle: "登录账号", action: { showLogin = true }) }
            }
        }
        .navigationDestination(isPresented: $showLogin) { LoginView() }
        .sheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .navigationDestination(item: $getting) { app in AppDetailView(app: app, autoStart: true) }
        .task(id: apple.activeID) { await store.ensureOwnedLoaded() }
        .toolPage()
        .rootTabBar("已购项目", headerScrolledAway: headerAway)
        .task(id: "\(apple.activeID ?? "")|\(store.ownedRevision)") { await store.loadOwnedArtwork() }
        .refreshable { if apple.active != nil { await store.refreshOwned() } }
        .task(id: term) {
            // Clearing is instant; typing waits for a short pause.
            if !term.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            query = term
        }
        .task { await store.checkForUpdates() }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 12) {
                    let visible = filtered
                    let allSelected = !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) }
                    Button(allSelected ? "取消全选" : "全选") {
                        if allSelected { selection.subtract(visible.map(\.id)) } else { selection.formUnion(visible.map(\.id)) }
                    }
                    .disabled(visible.isEmpty || batchProgress != nil)
                    Spacer()
                    if let batchProgress {
                        ProgressView()
                        Text("正在添加 \(batchProgress.done)/\(batchProgress.total)").font(.subheadline.monospacedDigit())
                    } else {
                        Button { downloadSelected() } label: {
                            Text(selection.isEmpty ? "下载所选" : "下载所选（\(selection.count)）").fontWeight(.semibold)
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("purchased.download-selected")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(.regularMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: apple.activeID) { _, _ in selecting = false; selection.removeAll(); delistedOnly = false }
    }
}
