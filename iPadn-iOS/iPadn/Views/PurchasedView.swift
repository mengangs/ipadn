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
    var body: some View {
        List {
            Section {
                PageHeader(title: "已购项目") {
                    Button { Task { await store.refreshOwned() } } label: {
                        Image(systemName: "arrow.clockwise").font(.body.weight(.semibold))
                            .frame(width: 36, height: 36).background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.ownedLoading || apple.active == nil).accessibilityLabel("同步购买记录")
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
                            NavigationLink { AppDetailView(app: app.storeApp) } label: {
                                AppRow(app: app.storeApp, subtitle: app.purchaseDate.map {
                                    "购于 \($0.formatted(.dateTime.year().month(.defaultDigits).day()))"
                                }, badge: badges[app.id]) {
                                    RowCapsule(title: "下载") { getting = app.storeApp; UX.feedback() }
                                        .accessibilityLabel("下载 \(app.name)")
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
    }
}
