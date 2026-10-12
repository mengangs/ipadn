import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @State private var confirmClear = false
    private let regions = [("CN", "中国大陆"), ("US", "美国"), ("HK", "香港"), ("TW", "台湾"), ("JP", "日本"), ("GB", "英国"), ("SG", "新加坡"), ("CA", "加拿大"), ("AU", "澳大利亚"), ("KR", "韩国"), ("DE", "德国"), ("FR", "法国")]
    var body: some View {
        List {
            Section {
                SearchInput(text: $store.searchText, placeholder: "应用名称、App ID 或链接", submit: { store.search() }, clear: { store.clearSearch() })
                ViewThatFits(in: .horizontal) {
                    HStack { regionPicker; Spacer(minLength: 8); platformPicker }
                    VStack(alignment: .leading) { regionPicker; platformPicker }
                }
            }.listRowSeparator(.hidden)
            if store.searching {
                Section {
                    HStack { ProgressView(); Text("正在查找应用").font(.subheadline); Spacer(); Button("取消") { store.cancelSearch() }.frame(minHeight: 44) }
                    if store.results.isEmpty && store.localResults.isEmpty { AppSkeleton() }
                }
            }
            if let error = store.searchError {
                Section { InlineIssue(message: error) { store.search(store.lastSearchTerm) } }
            }
            if !store.localResults.isEmpty {
                Section {
                    ForEach(store.localResults) { app in
                        NavigationLink { AppDetailView(app: app) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AppRow(app: app)
                                Label("应用记录", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("已购与目录 · \(store.localResults.count)") }
                footer: { Text("包含已购、本机记录与 iPadn 名称目录。目录覆盖有限，下载以 Apple 授权结果为准。") }
            }
            if !store.results.isEmpty {
                Section {
                    ForEach(store.results) { app in
                        NavigationLink { AppDetailView(app: app) } label: { AppRow(app: app) }
                            .contextMenu { Button(store.isFavorite(app) ? "取消收藏" : "收藏应用", systemImage: store.isFavorite(app) ? "star.slash" : "star") { store.toggleFavorite(app); UX.feedback() } }
                    }
                } header: { Text("\(store.lastSearchTerm) · \(store.results.count) 个结果") }
            } else if store.localResults.isEmpty && store.hasSearched && !store.searching && store.searchError == nil {
                Section { EmptyState(title: "没有找到相关应用", message: "试试 App ID、商店链接或其他地区。查找下架应用时，可先在已购页同步记录。", symbol: "magnifyingglass", actionTitle: "重新搜索", action: { store.clearSearch() }) }
            }
            if !store.hasSearched && !store.searching {
                if !store.favorites.isEmpty {
                    ForEach(store.favorites) { app in
                        Section {
                            NavigationLink { AppDetailView(app: app) } label: { AppRow(app: app) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("取消收藏", systemImage: "star.slash") { withAnimation { store.toggleFavorite(app) } }.tint(.gray) }
                        } header: {
                            if app.id == store.favorites.first?.id { Text("收藏 · \(store.favorites.count)") }
                        }
                    }
                }
                if !store.searchHistory.isEmpty {
                    ForEach(Array(store.searchHistory.prefix(8))) { item in
                        Section {
                            Button { store.search(item.term) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock").foregroundStyle(.secondary)
                                    Text(item.term).foregroundStyle(.primary).lineLimit(2)
                                    Spacer(); Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
                                }.frame(minHeight: 38).contentShape(Rectangle())
                            }.accessibilityIdentifier("history.\(item.id)").swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { withAnimation { store.removeHistory(item.term) } } label: { Label("删除", systemImage: "trash") }.tint(.red)
                            }
                        } header: {
                            if item.id == store.searchHistory.first?.id {
                                HStack { Text("最近搜索"); Spacer(); Button("清空") { confirmClear = true }.textCase(nil) }
                            }
                        }
                    }
                }
                Section {
                    Label("支持「App ID 版本 ID」直接查询指定版本", systemImage: "lightbulb")
                        .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
                }.listRowBackground(Color.clear)
            }
        }
        .toolPage().navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(apple.accounts) { account in
                        Button { apple.select(account.id); UX.feedback() } label: {
                            Label(account.id, systemImage: account.id == apple.activeID ? "checkmark.circle.fill" : "person.crop.circle")
                        }
                    }
                    Button("管理账号", systemImage: "person.crop.circle") { store.tab = 3 }
                } label: { Image(systemName: apple.active == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("切换或管理账号")
            }
        }
        .actionConfirmation(isPresented: $confirmClear, title: "清空搜索历史？", confirmTitle: "清空历史") { withAnimation { store.clearHistory() } }
        .task { await store.loadNameCatalog() }
        .task(id: apple.activeID) { await store.ensureOwnedLoaded() }
        .onChange(of: store.settings.store) { _, _ in if store.hasSearched { store.search() } }
        .onChange(of: apple.activeID) { _, _ in if store.hasSearched { store.search() } }
    }
    private var regionPicker: some View {
        Menu {
            Picker("商店地区", selection: $store.settings.store.country) {
                ForEach(regions, id: \.0) { code, label in Text(label).tag(code) }
            }
        } label: { Label(regions.first { $0.0 == store.settings.store.country }?.1 ?? store.settings.store.country, systemImage: "globe.asia.australia").font(.subheadline).frame(minHeight: 44) }
    }
    private var platformPicker: some View {
        Picker("平台", selection: $store.settings.store.platform) {
            ForEach(AppPlatform.allCases) { platform in Text(platform.title).tag(platform) }
        }.pickerStyle(.segmented).frame(maxWidth: 180).accessibilityLabel("应用平台")
    }
}
