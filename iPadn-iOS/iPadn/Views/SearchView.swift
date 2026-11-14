import SwiftUI

/// App Store-style search: title with the account avatar on one line, a
/// capsule search bar under it, filter chips, recent
/// searches as suggestions, and result rows with a "获取" capsule.
struct SearchView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClear = false
    @State private var getting: StoreApp?
    @State private var viewingFavorite: StoreApp?
    @State private var headerAway = false
    @State private var searchCardWidth: CGFloat = 0
    @State private var recentHeaderWidth: CGFloat = 0
    @State private var recentFooterWidth: CGFloat = 0
    /// The common storefronts, in this order; names follow the interface language.
    private static let regions = ["CN", "US", "HK", "TW", "JP", "GB", "SG", "CA", "AU", "KR", "DE", "FR"]
    var body: some View {
        List {
            Section {
                PageHeader(title: "搜索") { AccountMenuButton() }
                    .onScrolledUnderBar { headerAway = $0 }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 2, trailing: 12))
                SearchInput(text: $store.searchText, placeholder: "应用名称、App ID 或链接", capsule: true,
                            submit: { store.search() }, clear: { store.clearSearch() })
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { searchCardWidth = $0 }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { regionPicker; platformPicker }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)

            // Placeholders where the results will appear, so they replace the
            // loading rows instead of pushing everything down.
            if store.searching {
                Section {
                    HStack { ProgressView(); Text("正在搜索…").font(.subheadline).foregroundStyle(.secondary); Spacer(); Button("取消") { store.cancelSearch() } }
                    if store.results.isEmpty { AppSkeleton(); AppSkeleton() }
                }
            }
            if let error = store.searchError {
                Section { InlineIssue(message: error) { store.search(store.lastSearchTerm) } }
            }
            if !store.results.isEmpty {
                Section {
                    ForEach(store.results) { app in resultRow(app, note: app.tvOSCandidate == true ? AppText.text("可能支持 Apple TV") : nil) }
                } header: { Text("\(store.results.count) 个结果") }
            }
            if !store.localResults.isEmpty {
                Section {
                    ForEach(store.localResults) { app in resultRow(app, note: nil) }
                } header: { Text("更多结果") }
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
        .animation(UX.motion(reduceMotion), value: store.searchHistory.map(\.id))
        .animation(UX.motion(reduceMotion), value: store.favorites.map(\.id))
        .toolPage()
        .rootTabBar("搜索", headerScrolledAway: headerAway)
        .compatibleNavigationDestination(item: $getting) { app in AppDetailView(app: app, autoStart: true) }
        .compatibleNavigationDestination(item: $viewingFavorite) { app in AppDetailView(app: app) }
        .task { await store.loadNameCatalog() }
        .task { await store.checkWatched() }
        .task(id: apple.activeID) { await store.ensureOwnedLoaded() }
    }

    private func resultRow(_ app: StoreApp, note: String?) -> some View {
        NavigationLink { AppDetailView(app: app) } label: {
            AppRow(app: app, subtitle: note.map { [app.displayCategory, $0].filter { !$0.isEmpty }.joined(separator: " · ") }) {
                RowCapsule(title: "获取", insideNavigationLink: true) { getting = app }
                    .accessibilityLabel("获取 \(app.name)")
            }
        }
        .contextMenu {
            Button(store.isFavorite(app) ? "取消关注" : "关注", systemImage: store.isFavorite(app) ? "bell.slash" : "bell") {
                store.toggleFavorite(app); UX.feedback()
            }
        }
    }

    private var recentHeaderOutset: CGFloat {
        guard searchCardWidth > recentHeaderWidth, recentHeaderWidth > 0 else { return 0 }
        return (searchCardWidth - recentHeaderWidth) / 2
    }

    private var recentFooterOutset: CGFloat {
        guard searchCardWidth > recentFooterWidth, recentFooterWidth > 0 else { return 0 }
        return (searchCardWidth - recentFooterWidth) / 2
    }

    @ViewBuilder private var suggestions: some View {
        if !store.searchHistory.isEmpty {
            // Short terms as chips that wrap, rather than one wide row each.
            Section {
                ChipFlow(spacing: 8) {
                    ForEach(Array(store.searchHistory.prefix(12))) { item in
                        // Tap searches; a long press lifts just this chip with a Delete menu.
                        MenuChip(title: item.term, symbol: "magnifyingglass", identifier: "history.\(item.id)",
                                 deleteTitle: AppText.text("删除")) {
                            store.search(item.term)
                        } onDelete: {
                            withAnimation { store.removeHistory(item.term) }
                        }
                    }
                }
                .listRowBackground(Color.clear)
                // Flush with the SearchInput outer edges (leading/trailing = 0).
                // Vertical 7pt margin keeps every 38pt capsule (r = 19pt) inside
                // the transparent cell's corner mask without clipping its ends.
                .listRowInsets(EdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 0))
            } header: {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { recentHeaderWidth = $0 }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("最近搜索").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("清除") { confirmClear = true }
                            .font(.body)
                            .textCase(nil)
                            .fixedSize()
                            .confirmationDialog("清除最近搜索？", isPresented: $confirmClear, titleVisibility: .visible) {
                                Button("清除", role: .destructive) { withAnimation(UX.motion(reduceMotion)) { store.clearHistory() } }
                                Button("取消", role: .cancel) {}
                            }
                    }
                    .padding(.horizontal, -recentHeaderOutset)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { recentFooterWidth = $0 }
                    Text("长按可删除单条记录。")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, -recentFooterOutset)
                }
            }
        }
        if !store.favorites.isEmpty {
            Section {
                ForEach(store.favorites) { app in
                    Button { viewingFavorite = app } label: {
                        HStack {
                            WatchRow(app: app)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }
                        .buttonStyle(RevealRowButtonStyle())
                        .accessibilityIdentifier("favorite." + app.id)
                        .revealDelete(id: "favorite." + app.id, title: "取消关注", fills: true) { withAnimation { store.toggleFavorite(app) } }
                }
            } header: {
                HStack {
                    Text("关注").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                    Spacer()
                    if store.watchChecking { ProgressView().controlSize(.small) }
                }
            }
        }
        // The charts come after what the user searched and follows.
        DiscoverSection()
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
                ForEach(Self.regions, id: \.self) { code in Text(StoreRegions.name(code)).tag(code) }
            }
        } label: { chip(StoreRegions.name(store.settings.store.country), symbol: "globe") }
        .accessibilityLabel("商店地区")
    }
    private var platformPicker: some View {
        Menu {
            Picker("应用平台", selection: $store.settings.store.platform) {
                ForEach(AppPlatform.allCases) { platform in Label(platform.title, systemImage: platform.symbol).tag(platform) }
            }
        } label: { chip(store.settings.store.platform.title, symbol: store.settings.store.platform.symbol) }
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
