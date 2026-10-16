import SwiftUI
import Charts

extension WatchChange {
    var tint: Color {
        switch self {
        case .free, .priceDrop: return .green
        case .newVersion, .relisted: return .blue
        case .priceRise: return .secondary
        case .delisted: return .orange
        }
    }
}

/// A followed app in the list: current price and version, and the latest change.
struct WatchRow: View {
    @EnvironmentObject private var store: ToolStore
    let app: StoreApp
    var body: some View {
        let record = store.watchRecord(app.id)
        let price = record.flatMap { record in record.price.map { WatchService.format($0, currency: record.currency) } }
        let version = (record?.version).flatMap { $0.isEmpty ? nil : $0 } ?? (app.version.isEmpty ? nil : app.version)
        let subtitle = [price, version.map { "v" + $0 }].compactMap { $0 }.joined(separator: " · ")
        AppRow(app: app, subtitle: subtitle.isEmpty ? nil : subtitle, badge: badge(record))
    }
    private func badge(_ record: WatchRecord?) -> (text: String, tint: Color)? {
        guard let record else { return nil }
        if record.delisted { return app.isDelisted ? nil : (WatchChange.delisted.tag, WatchChange.delisted.tint) }
        return record.recentChange().map { ($0.tag, $0.tint) }
    }
}

/// Price changes recorded since the app was followed.
struct PriceHistorySection: View {
    @EnvironmentObject private var store: ToolStore
    let app: StoreApp
    @State private var country: String?
    /// The account's storefront, then the comparison storefronts with a record.
    private var countries: [String] {
        var list = [store.watchCountry]
        for code in store.settings.priceRegions.map({ $0.uppercased() })
        where !list.contains(code) && store.watch[WatchRecord.key(id: app.id, country: code)]?.price != nil {
            list.append(code)
        }
        return list
    }
    var body: some View {
        let shown = country.flatMap { countries.contains($0) ? $0 : nil } ?? store.watchCountry
        if countries.count > 1 {
            LabeledContent("地区") {
                Picker("地区", selection: Binding(get: { shown }, set: { country = $0 })) {
                    ForEach(countries, id: \.self) { Text(StoreRegions.flag($0) + " " + StoreRegions.name($0)).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
        }
        if let record = store.watch[WatchRecord.key(id: app.id, country: shown)] {
            if record.delisted {
                Text("当前地区已下架，获取过的账号仍可下载。").font(.subheadline).foregroundStyle(.secondary)
            }
            if let price = record.price {
                LabeledContent("当前价格", value: WatchService.format(price, currency: record.currency))
            }
            if record.history.count > 1 {
                if let low = record.history.map(\.price).min() {
                    LabeledContent("关注以来最低", value: WatchService.format(low, currency: record.currency))
                }
                PriceHistoryChart(record: record)
                    .cardRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 20))
            } else {
                Text("从 \(record.started.formatted(date: .abbreviated, time: .omitted)) 开始记录，价格有变化后会在这里显示走势。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if store.watchChecking {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在读取价格…").foregroundStyle(.secondary)
            }
        } else {
            Text("暂时无法读取价格，稍后会自动重试。").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct PriceHistoryChart: View {
    let record: WatchRecord
    var body: some View {
        // Prices hold until the next change: draw steps, extended to today.
        let points = record.history + (record.history.last.map { [PricePoint(date: max(Date(), $0.date), price: $0.price)] } ?? [])
        Chart(Array(points.enumerated()), id: \.offset) { item in
            LineMark(x: .value("日期", item.element.date), y: .value("价格", item.element.price))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(Color.accentColor)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let price = value.as(Double.self) { Text(WatchService.format(price, currency: record.currency)) }
                }
            }
        }
        .frame(height: 160)
        .accessibilityLabel("价格走势")
    }
}
