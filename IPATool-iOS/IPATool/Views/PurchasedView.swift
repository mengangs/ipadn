import SwiftUI

struct PurchasedView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @State private var term = ""
    @State private var months = 0
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
                    HStack(spacing: 14) {
                        AccountAvatar(account: account)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("你的应用资料库").font(.headline)
                            Text(account.id).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.padding(.vertical, 8)
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
                            EmptyState(title: "同步你的已购应用", message: "从 Apple 获取记录，之后可在这里查找和下载历史版本。", symbol: "clock.arrow.circlepath", actionTitle: "立即同步", action: { Task { await store.refreshOwned() } })
                        } else {
                            EmptyState(title: "没有匹配的应用", message: "换个关键词，或清除时间筛选。", symbol: "line.3.horizontal.decrease.circle", actionTitle: "清除筛选", action: { term = ""; months = 0 })
                        }
                    }
                }
            } else {
                Section { EmptyState(title: "你的已购应用，都在这里", message: "连接 Apple 账号后，同步购买记录，查找需要的版本。", symbol: "person.crop.circle.badge.checkmark", actionTitle: "连接账号", action: { store.tab = 3 }) }
            }
        }
        .toolPage().navigationTitle("已购").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { Task { await store.refreshOwned() } } label: { Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44) }
                .disabled(store.ownedLoading || apple.active == nil).accessibilityLabel("同步购买记录")
        }
        .task(id: "\(apple.activeID ?? "")|\(store.ownedRevision)|\(store.settings.store.country)|\(store.settings.store.platform.rawValue)") { await store.loadOwnedArtwork() }
        .refreshable { if apple.active != nil { await store.refreshOwned() } }
    }
}
