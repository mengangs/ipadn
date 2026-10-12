import SwiftUI
import Charts

struct SearchView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    private let regions = [("CN", "中国大陆"), ("US", "美国"), ("HK", "香港"), ("TW", "台湾"), ("JP", "日本"), ("GB", "英国"), ("SG", "新加坡"), ("CA", "加拿大"), ("AU", "澳大利亚"), ("KR", "韩国"), ("DE", "德国"), ("FR", "法国")]
    var body: some View {
        List {
            Section {
                HStack {
                    Label("商店", systemImage: "globe.asia.australia")
                    Spacer()
                    Picker("地区", selection: $store.settings.store.country) {
                        ForEach(regions, id: \.0) { code, label in Text(label).tag(code) }
                    }.labelsHidden().pickerStyle(.menu)
                    Picker("平台", selection: $store.settings.store.platform) {
                        ForEach(AppPlatform.allCases) { platform in Text(platform.title).tag(platform) }
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
            if store.searching {
                Section { HStack { ProgressView(); Text("正在查询应用…").foregroundStyle(.secondary) } }
            } else if !store.results.isEmpty {
                Section("找到 \(store.results.count) 个应用") {
                    ForEach(store.results) { app in NavigationLink { AppDetailView(app: app) } label: { AppRow(app: app) } }
                }
            } else if store.hasSearched {
                Section { ContentUnavailableView.search(text: store.searchText) }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "shippingbox.fill").font(.system(size: 34)).foregroundStyle(.tint)
                        Text("你的应用工具箱").font(.title2.bold())
                        Text("搜索应用，查看历史版本，管理自己的安装包。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("支持应用名称、App ID、商店链接，以及「App ID 版本 ID」。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
            }
            if !store.searchHistory.isEmpty {
                Section {
                    ForEach(store.searchHistory.prefix(8)) { item in
                        Button { store.search(item.term) } label: {
                            HStack {
                                Image(systemName: "clock").foregroundStyle(.secondary)
                                Text(item.term).foregroundStyle(.primary).lineLimit(1)
                                Spacer(); Text("\(item.count)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button("删除", role: .destructive) { store.removeHistory(item.term) } }
                    }
                    if store.searchHistory.count > 1 {
                        Chart(Array(store.searchHistory.sorted { $0.count > $1.count }.prefix(5))) { item in
                            BarMark(x: .value("次数", item.count), y: .value("关键词", String(item.term.prefix(12))))
                                .foregroundStyle(Color.accentColor.gradient)
                        }.frame(height: 130).accessibilityLabel("搜索历史频率")
                    }
                } header: {
                    HStack { Text("最近搜索"); Spacer(); Button("清空") { store.clearHistory() }.font(.caption) }
                }
            }
        }
        .navigationTitle("IPA 工具箱")
        .searchable(text: $store.searchText, prompt: "应用名称 / App ID / 商店链接")
        .onSubmit(of: .search) { store.search() }
        .toolbar {
            if store.searching { Button("取消") { store.cancelSearch() } }
            Menu {
                ForEach(apple.accounts) { account in
                    Button { apple.select(account.id) } label: {
                        if account.id == apple.activeID { Label(account.id, systemImage: "checkmark") }
                        else { Text(account.id) }
                    }
                }
                Button("管理账号") { store.tab = 3 }
            } label: { Image(systemName: apple.active == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark") }
                .accessibilityLabel("快速切换账号")
        }
        .onChange(of: store.settings.store) { _, _ in if store.hasSearched { store.search() } }
    }
}
