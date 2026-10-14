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
    private var filtered: [OwnedApp] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? .distantPast
        let term = query.trimmingCharacters(in: .whitespaces)
        if term.isEmpty && months == 0 { return store.owned }
        return store.owned.filter {
            (months == 0 || ($0.purchaseDate ?? .distantPast) >= cutoff) &&
            (term.isEmpty || $0.id.contains(term) || $0.name.localizedCaseInsensitiveContains(term) || $0.bundleID.localizedCaseInsensitiveContains(term))
        }
    }
    /// Download state per App ID: a newer store version first, then downloaded.
    private var downloadBadges: [String: (text: String, tint: Color)] {
        var badges: [String: (text: String, tint: Color)] = [:]
        for job in manager.jobs where job.status == .completed {
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
    /// Adds the selected apps one after another; the list order is kept.
    private func downloadSelected() {
        let apps = store.owned.filter { selection.contains($0.id) }.map(\.storeApp)
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
                    HStack(spacing: 10) {
                        if apple.active != nil && !store.owned.isEmpty {
                            Button(selecting ? "完成" : "选择") {
                                withAnimation(.snappy) { selecting.toggle(); selection.removeAll() }
                            }
                            .font(.body.weight(.semibold))
                            .buttonStyle(.borderless)
                            .disabled(batchProgress != nil)
                            .accessibilityIdentifier("purchased.select")
                        }
                        Button { Task { await store.refreshOwned() } } label: {
                            Image(systemName: "arrow.clockwise").font(.body.weight(.semibold))
                                .frame(width: 36, height: 36).background(Color(.tertiarySystemFill), in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.ownedLoading || apple.active == nil || selecting).accessibilityLabel("同步购买记录")
                    }
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
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                if let error = store.ownedError { Section { InlineIssue(message: error) { Task { await store.refreshOwned() } } } }
                if store.ownedLoading {
                    Section { HStack { ProgressView(); Text("正在同步购买记录…").font(.subheadline).foregroundStyle(.secondary) } }
                }
                let visible = filtered
                let badges = downloadBadges
                if !visible.isEmpty {
                    Section("\(visible.count) 个项目") {
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
                                        AppRow(app: app.storeApp, subtitle: subtitle, badge: badges[app.id])
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel((selection.contains(app.id) ? "取消选择 " : "选择 ") + app.name)
                            } else {
                                NavigationLink { AppDetailView(app: app.storeApp) } label: {
                                    AppRow(app: app.storeApp, subtitle: subtitle, badge: badges[app.id]) {
                                        RowCapsule(title: "下载") { getting = app.storeApp; UX.feedback() }
                                            .accessibilityLabel("下载 \(app.name)")
                                    }
                                }
                            }
                        }
                    }
                } else if !store.ownedLoading && store.ownedError == nil {
                    Section {
                        if term.isEmpty && months == 0 {
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
        .onChange(of: apple.activeID) { _, _ in selecting = false; selection.removeAll() }
    }
}
