import SwiftUI

/// App Store-style search: large title, search bar, filter chips, recent
/// searches as suggestions, and result rows with a "获取" capsule.
struct SearchView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @State private var confirmClear = false
    @State private var getting: StoreApp?
    private let regions = [("CN", "中国大陆"), ("US", "美国"), ("HK", "香港"), ("TW", "台湾"), ("JP", "日本"), ("GB", "英国"), ("SG", "新加坡"), ("CA", "加拿大"), ("AU", "澳大利亚"), ("KR", "韩国"), ("DE", "德国"), ("FR", "法国")]
    var body: some View {
        List {
            Section {
                SearchInput(text: $store.searchText, placeholder: "应用名称、App ID 或链接", submit: { store.search() }, clear: { store.clearSearch() })
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { regionPicker; platformPicker }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16))
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)

            if store.searching {
                Section {
                    HStack { ProgressView(); Text("正在搜索…").font(.subheadline).foregroundStyle(.secondary); Spacer(); Button("取消") { store.cancelSearch() } }
                    if store.results.isEmpty && store.localResults.isEmpty { AppSkeleton(); AppSkeleton() }
                }
            }
            if let error = store.searchError {
                Section { InlineIssue(message: error) { store.search(store.lastSearchTerm) } }
            }
            if !store.results.isEmpty {
                Section {
                    ForEach(store.results) { app in resultRow(app, note: app.tvOSCandidate == true ? "Apple TV 兼容性待确认" : nil) }
                } header: { Text("\(store.results.count) 个结果") }
            }
            if !store.localResults.isEmpty {
                Section {
                    ForEach(store.localResults) { app in resultRow(app, note: "已购或目录记录") }
                } header: { Text("已购与目录") }
            }
            if store.results.isEmpty && store.localResults.isEmpty && store.hasSearched && !store.searching && store.searchError == nil {
                Section {
                    EmptyState(title: "无结果", message: "“\(store.lastSearchTerm)”没有匹配的应用。试试 App ID、App Store 链接或其他地区。",
                               symbol: "magnifyingglass", actionTitle: "清除搜索", action: { store.clearSearch() })
                }.listRowBackground(Color.clear)
            }
            if !store.hasSearched && !store.searching {
                suggestions
            }
        }
        .toolPage()
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $getting) { app in AppDetailView(app: app, autoStart: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { AccountMenuButton() }
        }
        .actionConfirmation(isPresented: $confirmClear, title: "清除最近搜索？", confirmTitle: "清除") { withAnimation { store.clearHistory() } }
        .task { await store.loadNameCatalog() }
        .task(id: apple.activeID) { await store.ensureOwnedLoaded() }
        .onChange(of: store.settings.store) { _, _ in if store.hasSearched { store.search() } }
        .onChange(of: apple.activeID) { _, _ in if store.hasSearched { store.search() } }
    }

    private func resultRow(_ app: StoreApp, note: String?) -> some View {
        NavigationLink { AppDetailView(app: app) } label: {
            AppRow(app: app, subtitle: note.map { [app.category, $0].filter { !$0.isEmpty }.joined(separator: " · ") }) {
                RowCapsule(title: "获取") { getting = app; UX.feedback() }
                    .accessibilityLabel("获取 \(app.name)")
            }
        }
        .contextMenu {
            Button(store.isFavorite(app) ? "取消收藏" : "收藏", systemImage: store.isFavorite(app) ? "star.slash" : "star") {
                store.toggleFavorite(app); UX.feedback()
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        if !store.searchHistory.isEmpty {
            ForEach(Array(store.searchHistory.prefix(8))) { item in
                Section {
                    Button { store.search(item.term) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            Text(item.term).foregroundStyle(.primary).lineLimit(1)
                            Spacer()
                        }.frame(minHeight: 36).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("history.\(item.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { withAnimation { store.removeHistory(item.term) } } label: { Label("删除", systemImage: "trash") }.tint(.red)
                    }
                } header: {
                    if item.id == store.searchHistory.first?.id {
                        HStack {
                            Text("最近搜索").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                            Spacer()
                            Button("清除") { confirmClear = true }.font(.body).textCase(nil)
                        }
                    }
                }
            }
        }
        if !store.favorites.isEmpty {
            Section {
                ForEach(store.favorites) { app in
                    NavigationLink { AppDetailView(app: app) } label: { AppRow(app: app) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("取消收藏", systemImage: "star.slash") { withAnimation { store.toggleFavorite(app) } }.tint(.gray)
                        }
                }
            } header: {
                Text("收藏").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
            }
        }
        Section {
            Label("输入「App ID 版本 ID」可直接定位指定版本", systemImage: "lightbulb")
                .font(.footnote).foregroundStyle(.secondary)
        }.listRowBackground(Color.clear)
    }

    private func chip(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold))
            Text(title).font(.subheadline.weight(.medium))
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).frame(minHeight: 32)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
    }
    private var regionPicker: some View {
        Menu {
            Picker("商店地区", selection: $store.settings.store.country) {
                ForEach(regions, id: \.0) { code, label in Text(label).tag(code) }
            }
        } label: { chip(regions.first { $0.0 == store.settings.store.country }?.1 ?? store.settings.store.country, symbol: "globe") }
        .accessibilityLabel("商店地区")
    }
    private var platformPicker: some View {
        Menu {
            Picker("应用平台", selection: $store.settings.store.platform) {
                ForEach(AppPlatform.allCases) { platform in Text(platform.title).tag(platform) }
            }
        } label: { chip(store.settings.store.platform.title, symbol: "apps.iphone") }
        .accessibilityLabel("应用平台：\(store.settings.store.platform.title)")
    }
}

/// App Store's top-right account button: avatar with a quick account switcher.
struct AccountMenuButton: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    var body: some View {
        Menu {
            if !apple.accounts.isEmpty {
                Section("切换账号") {
                    ForEach(apple.accounts) { account in
                        Button { apple.select(account.id); UX.feedback() } label: {
                            Label(account.id, systemImage: account.id == apple.activeID ? "checkmark.circle.fill" : "person.crop.circle")
                        }
                    }
                }
            }
            Button("账号与设置", systemImage: "person.crop.circle") { store.tab = 3 }
        } label: {
            AccountAvatar(account: apple.active, size: 32).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("切换或管理账号")
    }
}

struct AccountAvatar: View {
    let account: AppleAccount?
    var size: CGFloat = 32
    private var initials: String {
        guard let account else { return "" }
        let source = account.name.isEmpty ? account.id : account.name
        return String(source.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
    var body: some View {
        ZStack {
            Circle().fill(account == nil ? AnyShapeStyle(Color(.tertiarySystemFill))
                          : AnyShapeStyle(LinearGradient(colors: [Color(.systemGray2), Color(.systemGray)], startPoint: .top, endPoint: .bottom)))
            if account == nil {
                Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(.secondary)
            } else {
                Text(initials).font(.system(size: size * 0.45, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
