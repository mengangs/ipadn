import SwiftUI

/// The app's price in each chosen storefront, converted for comparison.
struct RegionPriceView: View {
    @EnvironmentObject private var store: ToolStore
    let app: StoreApp
    @State private var prices: [RegionPrice] = []
    @State private var rates: ExchangeRates?
    @State private var loading = true
    @State private var showSpinner = false
    @State private var editingRegions = false
    static let currencies = ["CNY", "HKD", "TWD", "USD", "JPY", "KRW", "EUR", "GBP", "SGD", "AUD", "CAD", "TRY"]

    private var base: String { store.settings.baseCurrency }
    private var sorted: [RegionPrice] { PriceComparison.sorted(prices, rates: rates) }
    private var cheapest: String? {
        sorted.first { $0.price.map { $0 > 0 } == true && rates?.convert($0.price!, from: $0.currency) != nil }?.country
    }

    var body: some View {
        List {
            Section {
                if prices.isEmpty && loading {
                    ForEach(0..<min(4, max(1, store.settings.priceRegions.count)), id: \.self) { _ in RegionPriceSkeleton() }
                } else if prices.isEmpty {
                    Text("暂时无法读取价格，请下拉重试。").foregroundStyle(.secondary)
                }
                ForEach(sorted) { item in
                    RegionPriceRow(item: item, rates: rates, cheapest: item.country == cheapest)
                }
            } header: {
                HStack {
                    Text("应用价格")
                    Spacer()
                    if showSpinner { ProgressView().controlSize(.small) }
                }
            } footer: { Text(footnote) }
        }
        .navigationTitle("多地区价格")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("换算货币", selection: $store.settings.baseCurrency) {
                        ForEach(Self.currencies, id: \.self) { Text(currencyName($0)).tag($0) }
                    }
                    Button("选择对比地区", systemImage: "globe") { editingRegions = true }
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("比价设置")
            }
        }
        .sheet(isPresented: $editingRegions) {
            NavigationStack { RegionSelectionView(selection: $store.settings.priceRegions) }
        }
        .revealAfterDelay(loading, into: $showSpinner)
        .task(id: store.settings.priceRegions) { await load() }
        .task(id: base) { rates = await ExchangeRates.load(base: base) }
        .refreshable { await load() }
    }

    private var footnote: String {
        var lines = ["按\(currencyName(base))换算，从低到高排列。"]
        if let rates {
            lines.append("汇率为 \(rates.updated.formatted(date: .abbreviated, time: .omitted)) 的参考中间价，实际扣款以发卡银行为准。")
        } else if !loading {
            lines.append("暂时无法获取汇率，仅显示当地价格。")
        }
        if prices.contains(where: { StoreRegions.taxExcluded.contains($0.country) && $0.listing != nil }) {
            lines.append("美国、加拿大的标价不含销售税。")
        }
        return lines.joined(separator: "\n")
    }

    private func currencyName(_ code: String) -> String {
        (Locale(identifier: "zh_CN").localizedString(forCurrencyCode: code) ?? code) + "（\(code)）"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let found = await PriceComparison.regionPrices(appID: app.id, countries: store.settings.priceRegions)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { prices = found }
    }
}

struct RegionPriceRow: View {
    let item: RegionPrice
    let rates: ExchangeRates?
    var cheapest = false
    var body: some View {
        HStack(spacing: 12) {
            Text(StoreRegions.flag(item.country)).font(.title2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(StoreRegions.name(item.country)).font(.body)
                    if cheapest { TagBadge(text: "最低", tint: .green) }
                }
                Text(local).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let converted {
                Text(converted).font(.body.monospacedDigit().weight(.medium))
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var local: String {
        guard item.listing != nil else { return "未在该地区上架" }
        guard let price = item.price else { return "价格未知" }
        let text = WatchService.format(price, currency: item.currency)
        return StoreRegions.taxExcluded.contains(item.country) && price > 0 ? text + "（不含税）" : text
    }
    private var converted: String? {
        guard let price = item.price, price > 0, let rates, item.currency != rates.base,
              let value = rates.convert(price, from: item.currency) else { return nil }
        return "≈ " + WatchService.format(value, currency: rates.base)
    }
}

private struct RegionPriceSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(.tertiarySystemFill)).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 90, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 60, height: 12)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

/// Picks the storefronts to compare; chosen ones first.
struct RegionSelectionView: View {
    @Binding var selection: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var others: [String] {
        StoreRegions.codes.filter { !selection.contains($0) }
            .filter { search.isEmpty || StoreRegions.name($0).localizedCaseInsensitiveContains(search) || $0.localizedCaseInsensitiveContains(search) }
            .sorted { StoreRegions.name($0).localizedStandardCompare(StoreRegions.name($1)) == .orderedAscending }
    }
    var body: some View {
        List {
            if search.isEmpty {
                Section {
                    ForEach(selection, id: \.self) { code in row(code, selected: true) }
                        .onMove { selection.move(fromOffsets: $0, toOffset: $1) }
                } header: { Text("已选 \(selection.count) 个地区") } footer: {
                    Text("关注的应用也会记录这些地区的价格变化。")
                }
            }
            Section(search.isEmpty ? "其他地区" : "搜索结果") {
                ForEach(search.isEmpty ? others : selection.filter { StoreRegions.name($0).localizedCaseInsensitiveContains(search) } + others,
                        id: \.self) { code in row(code, selected: selection.contains(code)) }
            }
        }
        .searchable(text: $search, prompt: "搜索地区")
        .navigationTitle("对比地区")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
    private func row(_ code: String, selected: Bool) -> some View {
        Button {
            if selected {
                guard selection.count > 1 else { return }
                selection.removeAll { $0 == code }
            } else {
                selection.append(code)
            }
        } label: {
            HStack(spacing: 12) {
                Text(StoreRegions.flag(code)).accessibilityHidden(true)
                Text(StoreRegions.name(code)).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
