import SwiftUI
import WebKit
import UIKit

struct AppIcon: View {
    var url: URL?
    var size: CGFloat = 56
    /// The image last loaded, with the address it came from.
    @State private var loaded: (url: URL, image: UIImage)?
    private var source: URL? { url.map { $0.isFileURL ? $0 : StoreService.sharpArtwork($0) } }
    var body: some View {
        let source = source
        // An icon already in memory shows in the very first frame.
        let image = loaded.flatMap { $0.url == source ? $0.image : nil } ?? source.flatMap { IconCache.cached($0, size: size) }
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit().transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * UX.iconCorner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * UX.iconCorner, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: source) {
            guard let source else { return }
            // Kept here too, in case memory pressure later empties the cache.
            if let cached = IconCache.cached(source, size: size) {
                if loaded?.url != source { loaded = (source, cached) }
                return
            }
            guard let image = await IconCache.load(source, size: size), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { loaded = (source, image) }
        }
    }
    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "app.fill").font(.system(size: size * 0.4)).foregroundStyle(.quaternary)
        }
    }
}

/// Decoded app icons shared by every `AppIcon`, so a row scrolled back into
/// view, or the same app on the next page, shows its icon at once instead of
/// a placeholder while it loads again.
enum IconCache {
    private actor Requests {
        var pending: [String: Task<UIImage?, Never>] = [:]
        func load(_ url: URL, side: CGFloat) async -> UIImage? {
            let key = "\(Int(side))|\(url.absoluteString)"
            if let task = pending[key] { return await task.value }
            let task = Task.detached(priority: .utility) { () -> UIImage? in
                let data: Data?
                if url.isFileURL { data = try? Data(contentsOf: url) }
                else { data = try? await URLSession.shared.data(from: url).0 }
                guard let data, let image = UIImage(data: data) else { return nil }
                return await image.byPreparingThumbnail(ofSize: CGSize(width: side, height: side)) ?? image
            }
            pending[key] = task
            let image = await task.value
            if let image { cache.setObject(image, forKey: key as NSString, cost: cost(of: image)) }
            pending.removeValue(forKey: key)
            return image
        }
    }
    private static let requests = Requests()
    /// Bounded by memory, not count: hundreds of list icons fit.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 80 * 1024 * 1024; return cache
    }()
    /// List rows and the large detail icon keep separate, right-sized copies.
    private static func pixels(for size: CGFloat) -> CGFloat { size <= 64 ? 192 : 384 }
    private static func key(_ url: URL, _ size: CGFloat) -> NSString { "\(Int(pixels(for: size)))|\(url.absoluteString)" as NSString }
    static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
    static func cached(_ url: URL, size: CGFloat) -> UIImage? { cache.object(forKey: key(url, size)) }
    static func load(_ url: URL, size: CGFloat) async -> UIImage? {
        if let image = cached(url, size: size) { return image }
        return await requests.load(url, side: pixels(for: size))
    }
}

/// App Store list row: icon, name, subtitle and an optional trailing action.
struct AppRow<Accessory: View>: View {
    let app: StoreApp
    var subtitle: String? = nil
    /// A short state shown next to the size, e.g. 已下载.
    var badge: (text: LocalizedStringKey, tint: Color)? = nil
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        HStack(spacing: 14) {
            AppIcon(url: app.iconURL, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? app.bundleID : app.name).font(.body.weight(.medium)).lineLimit(2)
                // The category gets its own line so a long name in another
                // language doesn't push the version out of view.
                let detail = subtitle ?? app.displayCategory
                if !detail.isEmpty {
                    // Scrolls once in place when the row is too narrow, like download cards.
                    MarqueeText(text: detail).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if app.isDelisted { TagBadge(text: "已下架", tint: .orange) }
                    if let badge { TagBadge(text: badge.text, tint: badge.tint) }
                    let facts = [subtitle == nil && !app.version.isEmpty ? "v\(app.version)" : "", app.size > 0 ? app.size.byteLabel : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    if !facts.isEmpty { Text(facts).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 4)
    }
}
extension AppRow where Accessory == EmptyView {
    init(app: StoreApp, subtitle: String? = nil, badge: (text: LocalizedStringKey, tint: Color)? = nil) {
        self.init(app: app, subtitle: subtitle, badge: badge) { EmptyView() }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct SharedFile: Identifiable { let id = UUID(); let url: URL }

struct SignerWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

struct RootView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var tabs: TabState
    @EnvironmentObject private var signer: SAPSigner
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let destinations: [(title: LocalizedStringKey, symbol: String)] = [("搜索", "magnifyingglass"), ("下载", "arrow.down.circle.fill"), ("已购", "bag.fill"), ("账号", "person.crop.circle.fill")]
    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(selection: Binding<Int?>(get: { tabs.selection }, set: { if let value = $0 { tabs.selection = value } })) {
                        Section {
                            ForEach(0..<destinations.count, id: \.self) { index in
                                Label(destinations[index].title, systemImage: destinations[index].symbol).tag(index)
                            }
                        }

                    }.navigationTitle("iPadn").navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                } detail: {
                    // Keep every section alive, like the iPhone tab bar does, so
                    // switching sections keeps navigation, filters and scroll position.
                    ZStack {
                        ForEach(0..<destinations.count, id: \.self) { index in
                            NavigationStack {
                                page(index).frame(maxWidth: 900).frame(maxWidth: .infinity)
                                    .background(Color(.systemGroupedBackground))
                            }
                            .opacity(tabs.selection == index ? 1 : 0)
                            .allowsHitTesting(tabs.selection == index)
                            .accessibilityHidden(tabs.selection != index)
                        }
                    }
                }
            } else {
                TabView(selection: $tabs.selection) {
                    NavigationStack { SearchView() }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(0)
                    NavigationStack { DownloadsView() }.tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
                        .badge(downloads.jobs.filter { DownloadFilter.active.includes($0.status) }.count).tag(1)
                    NavigationStack { PurchasedView() }.tabItem { Label("已购", systemImage: "bag.fill") }.tag(2)
                    NavigationStack { AccountsView() }.tabItem { Label("账号", systemImage: "person.crop.circle.fill") }.tag(3)
                }
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
            }
        }
        .preferredColorScheme(store.settings.appearance == "system" ? nil : store.settings.appearance == "dark" ? .dark : .light)
        .compatibleSelectionFeedback(trigger: tabs.selection)
        .sheet(item: $store.verificationRequest) { request in
            ExistingAccountVerificationView(accountID: request.accountID) {
                // Runs after the sheet has closed, so a retry can present again.
                let retry = request.retry
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); retry?() }
            }
        }
        .background {
            if let web = signer.webView {
                SignerWebView(web: web).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        // Global success notices belong above the page, never on top of
        // AppDetailView's fixed download CTA or the tab bar.
        .overlay(alignment: .top) {
            if let message = store.undoNotice?.message ?? store.infoMessage {
                Group {
                    if store.undoNotice != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(message).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            Button("撤销") { withAnimation(UX.motion(reduceMotion)) { store.undoLastAction() } }
                                .font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                                .compatibleInteractionShape(Rectangle())
                                .accessibilityIdentifier("notice.undo")
                    }
                    .padding(.horizontal, 14)
                    } else {
                        // Match 1.8.0: the whole compact notice dismisses on tap.
                        Button { store.infoMessage = nil } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(message).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.padding(.horizontal, 18).padding(.vertical, 11).frame(minHeight: 44)
                        }
                        .compatibleInteractionShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityLabel(message).accessibilityHint("点按关闭提示")
                        .accessibilityIdentifier("notice.banner")
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .buttonStyle(.plain)
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)
                // The top of the root tab container includes the navigation bar.
                // On compact-height devices show the banner nearer the top.
                .padding(.top, sizeClass == .regular ? 16 : verticalSizeClass == .compact ? 8 : 52)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.infoMessage)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.undoNotice?.id)
        .task(id: store.undoNotice?.id) {
            guard let notice = store.undoNotice else { return }
            UIAccessibility.post(notification: .announcement, argument: AppText.text("\(notice.message)，可以撤销"))
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if store.undoNotice?.id == notice.id { store.undoNotice = nil }
        }
        .task(id: store.infoMessage) {
            guard let message = store.infoMessage else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            #if DEBUG
            // Deterministic geometry checks without changing real notice timing.
            if LocalResources.isPreview && ProcessInfo.processInfo.arguments.contains("--notice-preview") { return }
            #endif
            // Longer notices (setup steps, other languages) stay up longer.
            let seconds = min(8, max(3.5, Double(message.count) / 14))
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            if store.infoMessage == message { store.infoMessage = nil }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .dismissRevealsWhenTabChanges(tabs.selection)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
        }
    }
    @ViewBuilder private func page(_ index: Int) -> some View {
        switch index {
        case 1: DownloadsView()
        case 2: PurchasedView()
        case 3: AccountsView()
        default: SearchView()
        }
    }
}

/// The top notice inside a sheet, which covers RootView's own banner. The
/// root still times the notice out and announces it; this only shows it.
private struct SheetNotice: ViewModifier {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = store.infoMessage {
                Button { store.infoMessage = nil } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(message).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.horizontal, 18).padding(.vertical, 11).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .frame(maxWidth: 320)
                .padding(.horizontal, 24).padding(.top, 8)
                .accessibilityLabel(message).accessibilityHint("点按关闭提示")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.infoMessage)
    }
}

extension View {
    /// Shows the app's top notice while this view is presented as a sheet.
    func sheetNotice() -> some View { modifier(SheetNotice()) }
}
