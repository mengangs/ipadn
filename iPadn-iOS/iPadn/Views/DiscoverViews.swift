import SwiftUI

/// The search page's Discover section: links to the top charts.
struct DiscoverSection: View {
    @EnvironmentObject private var store: ToolStore
    var body: some View {
        if AppChart.free.feed(store.settings.store.platform) != nil {
            Section {
                ForEach(AppChart.allCases) { chart in
                    NavigationLink { ChartView(chart: chart) } label: {
                        Label(chart.title, systemImage: chart.symbol)
                    }
                    .accessibilityIdentifier("discover." + chart.rawValue)
                }
            } header: {
                HStack {
                    Text("发现").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
                    Spacer()
                }
            }
        }
    }
}

/// One top chart in the current storefront and platform.
struct ChartView: View {
    @EnvironmentObject private var store: ToolStore
    @State var chart: AppChart
    @State private var genre = ChartGenre.all
    @State private var apps: [StoreApp] = []
    @State private var loading = true
    @State private var issue: String?
    @State private var getting: StoreApp?

    private var platform: AppPlatform { store.settings.store.platform }
    private var country: String { store.settings.store.country }

    var body: some View {
        List {
            Section {
                Picker("排行榜", selection: $chart) {
                    ForEach(AppChart.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text(verbatim: "\(StoreRegions.flag(country.uppercased())) \(StoreRegions.name(country.uppercased())) · \(platform.title) · \(genre.title)")
            }
            if let issue, apps.isEmpty {
                Section { InlineIssue(message: issue) { Task { await load() } } }
            } else if loading && apps.isEmpty {
                Section { HStack(spacing: 10) { ProgressView(); Text("正在读取排行榜…").foregroundStyle(.secondary) } }
            } else if apps.isEmpty {
                Section { Text("这个排行榜暂时没有内容。").foregroundStyle(.secondary) }
            }
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                Section {
                    NavigationLink { AppDetailView(app: app) } label: {
                        // The rank leads the category line, so the name keeps the full width.
                        AppRow(app: app, subtitle: ["\(index + 1)", app.displayCategory].filter { !$0.isEmpty }.joined(separator: " · ")) {
                            RowCapsule(title: app.isFree ? "获取" : LocalizedStringKey(app.priceLabel)) { getting = app; UX.feedback() }
                                .accessibilityLabel(AppText.text("获取 \(app.name)"))
                        }
                    }
                    .contextMenu {
                        Button(store.isFavorite(app) ? "取消关注" : "关注", systemImage: store.isFavorite(app) ? "bell.slash" : "bell") {
                            store.toggleFavorite(app); UX.feedback()
                        }
                    }
                }
            }
        }
        .toolPage().navigationTitle(chart.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if platform != .macOS {
                ToolbarItem(placement: .compatibleTopBarTrailing) {
                    Menu {
                        Picker("分类", selection: $genre) {
                            ForEach(ChartGenre.allCases) { Text(verbatim: $0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: genre == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(AppText.text("分类：\(genre.title)"))
                }
            }
        }
        .compatibleNavigationDestination(item: $getting) { app in AppDetailView(app: app, autoStart: true) }
        .task(id: "\(chart.rawValue)-\(genre.rawValue)-\(country)-\(platform.rawValue)") { await load() }
    }

    private func load() async {
        loading = true; issue = nil; apps = []
        defer { loading = false }
        do {
            let next = try await ChartService.apps(chart, platform: platform, country: country, genre: genre)
            guard !Task.isCancelled else { return }
            apps = next
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription; apps = [] }
        }
    }
}
