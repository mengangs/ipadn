import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen shortcuts into iPadn. It shows no app data, so
/// it needs nothing shared with the app (no App Group).
struct ShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.local.iPadn.shortcuts", provider: ShortcutsProvider()) { _ in
            ShortcutsWidgetView()
        }
        .configurationDisplayName("iPadn")
        .description(String(localized: "快速打开搜索、下载、已购和更新检查。"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

struct ShortcutsProvider: TimelineProvider {
    struct Entry: TimelineEntry { var date = Date() }
    func placeholder(in context: Context) -> Entry { Entry() }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry()], policy: .never))
    }
}

private enum Shortcut: CaseIterable {
    case search, downloads, purchased, updates
    var title: String {
        switch self {
        case .search: return String(localized: "搜索")
        case .downloads: return String(localized: "下载")
        case .purchased: return String(localized: "已购")
        case .updates: return String(localized: "检查更新")
        }
    }
    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle"
        case .purchased: return "bag"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
    var url: URL {
        switch self {
        case .search: return URL(string: "ipadn://open?tab=0")!
        case .downloads: return URL(string: "ipadn://open?tab=1")!
        case .purchased: return URL(string: "ipadn://open?tab=2")!
        case .updates: return URL(string: "ipadn://open?tab=1&check=updates")!
        }
    }
}

struct ShortcutsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "arrow.down.app").font(.title2.weight(.semibold))
            }
            .widgetURL(Shortcut.search.url)
            .containerBackground(for: .widget) { Color.clear }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                AppMarkView(size: 44)
                Spacer(minLength: 8)
                Text(verbatim: "iPadn").font(.headline)
                Label(Shortcut.search.title, systemImage: Shortcut.search.symbol)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(Shortcut.search.url)
            .containerBackground(for: .widget) { Color(.systemBackground) }
        default:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    AppMarkView(size: 44)
                    Spacer(minLength: 0)
                    Text(verbatim: "iPadn").font(.headline)
                }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { tile(.search); tile(.downloads) }
                    GridRow { tile(.purchased); tile(.updates) }
                }
            }
            .widgetURL(Shortcut.search.url)
            .containerBackground(for: .widget) { Color(.systemBackground) }
        }
    }

    private func tile(_ shortcut: Shortcut) -> some View {
        Link(destination: shortcut.url) {
            VStack(spacing: 4) {
                Image(systemName: shortcut.symbol).font(.title3.weight(.medium))
                Text(shortcut.title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(.primary)
    }
}
