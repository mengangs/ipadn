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
            Section {
                if let account = apple.active {
                    Label(account.id, systemImage: "person.crop.circle").font(.subheadline)
                    Picker("购买时间", selection: $months) {
                        Text("全部").tag(0); Text("最近 1 个月").tag(1); Text("最近 6 个月").tag(6); Text("最近 1 年").tag(12)
                    }
                } else {
                    ContentUnavailableView("登录后查看已购应用", systemImage: "person.crop.circle", description: Text("支持搜索、时间筛选和历史版本下载。"))
                    Button("前往账号页") { store.tab = 3 }
                }
            }
            if store.ownedLoading { Section { HStack { ProgressView(); Text("正在获取购买记录…").foregroundStyle(.secondary) } } }
            if !filtered.isEmpty {
                Section("\(filtered.count) 个应用") {
                    ForEach(filtered) { app in
                        NavigationLink { AppDetailView(app: app.storeApp) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(app.name.isEmpty ? app.bundleID : app.name).font(.headline)
                                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                                if let date = app.purchaseDate { Text(date, style: .date).font(.caption2).foregroundStyle(.secondary) }
                            }.padding(.vertical, 6)
                        }
                    }
                }
            } else if apple.active != nil, !store.ownedLoading {
                Section { ContentUnavailableView("暂无购买记录", systemImage: "clock.arrow.circlepath", description: Text("点刷新从 Apple 获取记录，或调整筛选条件。")) }
            }
        }
        .navigationTitle("已购应用")
        .searchable(text: $term, prompt: "名称、Bundle ID 或 App ID")
        .toolbar {
            Button { Task { await store.refreshOwned() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(store.ownedLoading || apple.active == nil).accessibilityLabel("刷新购买记录")
        }
        .refreshable { await store.refreshOwned() }
    }
}
