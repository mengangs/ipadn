import SwiftUI

struct PurchasedView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @State private var term = ""
    @State private var months = 0
    @State private var showLogin = false
    private var filtered: [OwnedApp] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? .distantPast
        return store.owned.filter {
            (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.bundleID.localizedCaseInsensitiveContains(term) || $0.id.contains(term)) &&
            (months == 0 || ($0.purchaseDate ?? .distantPast) >= cutoff)
        }
    }
    var body: some View {
        List {
            if let account = apple.active {
                Section {
                    Menu {
                        ForEach(apple.accounts) { item in
                            Button { apple.select(item.id) } label: {
                                Label(item.id, systemImage: item.id == apple.activeID ? "checkmark" : "person")
                            }
                        }
                    } label: {
                        HStack { Text(account.id).lineLimit(1); Spacer(); Image(systemName: "chevron.up.chevron.down") }
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    SearchInput(text: $term, placeholder: "搜索已购名称或 App ID")
                    Picker("购买时间", selection: $months) {
                        Text("全部时间").tag(0); Text("最近 1 个月").tag(1); Text("最近 6 个月").tag(6); Text("最近 1 年").tag(12)
                    }
                }.listRowSeparator(.hidden)
                if let error = store.ownedError { Section { InlineIssue(message: error) { Task { await store.refreshOwned() } } } }
                if store.ownedLoading {
                    Section { HStack { ProgressView(); Text("正在同步购买记录…").font(.subheadline).foregroundStyle(.secondary) } }
                }
                if !filtered.isEmpty {
                    Section("\(filtered.count) 个应用") {
                        ForEach(filtered) { app in
                            NavigationLink { AppDetailView(app: app.storeApp) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    AppRow(app: app.storeApp)
                                    if let date = app.purchaseDate { Text("购于 \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                                }.padding(.vertical, 3)
                            }
                        }
                    }
                } else if !store.ownedLoading && store.ownedError == nil {
                    Section {
                        if term.isEmpty && months == 0 {
                            EmptyState(title: "暂无已购记录", message: "从 Apple 获取记录，之后可在这里查找和下载历史版本。", symbol: "clock.arrow.circlepath", actionTitle: "立即同步", action: { Task { await store.refreshOwned() } })
                        } else {
                            EmptyState(title: "没有匹配的应用", message: "换个关键词，或清除时间筛选。", symbol: "line.3.horizontal.decrease.circle", actionTitle: "清除筛选", action: { term = ""; months = 0 })
                        }
                    }
                }
            } else {
                Section { EmptyState(title: "尚未登录", message: "登录后可同步此账号的购买记录。", symbol: "person.crop.circle.badge.checkmark", actionTitle: "登录账号", action: { showLogin = true }) }
            }
        }
        .navigationDestination(isPresented: $showLogin) { LoginView() }
        .task(id: apple.activeID) { await store.ensureOwnedLoaded() }
        .toolPage().navigationTitle("已购").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { Task { await store.refreshOwned() } } label: { Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44) }
                .disabled(store.ownedLoading || apple.active == nil).accessibilityLabel("同步购买记录")
        }
        .task(id: "\(apple.activeID ?? "")|\(store.ownedRevision)|\(store.settings.store.country)|\(store.settings.store.platform.rawValue)") { await store.loadOwnedArtwork() }
        .refreshable { if apple.active != nil { await store.refreshOwned() } }
    }
}
