import SwiftUI

/// One review: stars, title, when and for which version, and the text.
struct ReviewRow: View {
    let review: AppReview
    var lineLimit: Int? = 4
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= review.rating ? "star.fill" : "star")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Text(verbatim: [review.date?.formatted(date: .abbreviated, time: .omitted) ?? "", review.author]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppText.text("\(review.rating) 星"))
            if !review.title.isEmpty { Text(verbatim: review.title).font(.subheadline.weight(.semibold)) }
            Text(verbatim: review.body).font(.subheadline).foregroundStyle(.primary)
                .lineLimit(lineLimit).fixedSize(horizontal: false, vertical: true)
            if !review.version.isEmpty {
                Text("版本 \(review.version)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}

/// The detail page's card: the three newest reviews and a link to the rest.
struct ReviewsCard: View {
    @EnvironmentObject private var store: ToolStore
    let app: StoreApp
    @State private var reviews: [AppReview] = []
    @State private var loaded = false

    var body: some View {
        CardSection {
            if !loaded {
                HStack(spacing: 10) { ProgressView(); Text("正在读取评论…").font(.subheadline).foregroundStyle(.secondary) }
            } else if reviews.isEmpty {
                Text("这个地区暂时没有评论。").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(reviews.prefix(3)) { ReviewRow(review: $0, lineLimit: 4) }
            }
            NavigationLink { ReviewsView(app: app, country: store.settings.store.country) } label: {
                HStack {
                    Label("全部评论", systemImage: "text.bubble")
                    Spacer()
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.reviews")
        } header: {
            Text("评论").font(.title3.weight(.bold)).foregroundStyle(.primary).textCase(nil)
        }
        .task(id: app.id + store.settings.store.country) {
            loaded = false
            reviews = (try? await ReviewService.reviews(appID: app.id, country: store.settings.store.country, page: 1)) ?? []
            loaded = true
        }
    }
}

/// All recent reviews in one storefront, fifty at a time.
struct ReviewsView: View {
    @EnvironmentObject private var store: ToolStore
    let app: StoreApp
    @State var country: String
    @State private var reviews: [AppReview] = []
    @State private var page = 0
    @State private var finished = false
    @State private var loading = false
    @State private var issue: String?
    @State private var rating = 0

    private var regions: [String] {
        var list = [store.settings.store.country.uppercased()]
        for code in store.settings.priceRegions.map({ $0.uppercased() }) where !list.contains(code) { list.append(code) }
        if !list.contains(country.uppercased()) { list.insert(country.uppercased(), at: 0) }
        return list
    }

    var body: some View {
        let shown = rating == 0 ? reviews : reviews.filter { $0.rating == rating }
        List {
            Section {
                Picker("评分", selection: $rating) {
                    Text("全部").tag(0)
                    ForEach((1...5).reversed(), id: \.self) { Text(verbatim: "\($0) ★").tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if let issue, reviews.isEmpty {
                Section { InlineIssue(message: issue) { Task { await loadMore() } } }
            }
            ForEach(shown) { review in Section { ReviewRow(review: review, lineLimit: nil) } }
            if !finished {
                Section {
                    Button { Task { await loadMore() } } label: {
                        HStack { Spacer(); if loading { ProgressView() } else { Text("加载更多") }; Spacer() }
                    }
                    .disabled(loading)
                    .onAppear { if reviews.isEmpty { Task { await loadMore() } } }
                }
            } else if reviews.isEmpty {
                Section { Text("这个地区暂时没有评论。").foregroundStyle(.secondary) }
            }
        }
        .toolPage().navigationTitle("评论").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Menu {
                    ForEach(regions, id: \.self) { code in
                        Button { switchTo(code) } label: {
                            if code == country.uppercased() { Label(StoreRegions.flag(code) + " " + StoreRegions.name(code), systemImage: "checkmark") }
                            else { Text(StoreRegions.flag(code) + " " + StoreRegions.name(code)) }
                        }
                    }
                } label: {
                    Text(verbatim: StoreRegions.flag(country.uppercased())).font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(AppText.text("评论地区：\(StoreRegions.name(country.uppercased()))"))
            }
        }
    }

    private func switchTo(_ code: String) {
        guard code != country.uppercased() else { return }
        country = code; reviews = []; page = 0; finished = false; issue = nil
        Task { await loadMore() }
    }

    private func loadMore() async {
        guard !loading, !finished else { return }
        loading = true
        defer { loading = false }
        let next = page + 1
        let requested = country
        do {
            let batch = try await ReviewService.reviews(appID: app.id, country: requested, page: next)
            guard requested == country else { return }
            let known = Set(reviews.map(\.id))
            reviews += batch.filter { !known.contains($0.id) }
            page = next
            finished = batch.isEmpty || next >= ReviewService.lastPage
            issue = nil
        } catch { issue = error.localizedDescription }
    }
}
