import SwiftUI
import WebKit
import UIKit

struct AppIcon: View {
    var url: URL?
    var size: CGFloat = 56
    @State private var localImage: UIImage?
    var body: some View {
        Group {
            if let url, url.isFileURL {
                if let localImage { Image(uiImage: localImage).resizable().interpolation(.high).scaledToFit() }
                else { placeholder }
            } else {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().interpolation(.high).scaledToFit() }
                    else { placeholder }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
        .task(id: url) {
            localImage = nil
            guard let url, url.isFileURL else { return }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled, let data else { return }
            localImage = UIImage(data: data)
        }
    }
    private var placeholder: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            Image(systemName: "app.dashed").font(.system(size: size * 0.42)).foregroundStyle(.secondary)
        }
    }

}

struct AppRow: View {
    let app: StoreApp
    var body: some View {
        HStack(spacing: 14) {
            AppIcon(url: app.iconURL)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(.headline).lineLimit(2)
                Text([app.category, app.version.isEmpty ? "" : "v\(app.version)"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if app.size > 0 { Text(app.size.byteLabel).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 5)
    }
}

struct StatusBanner: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        Label(text, systemImage: symbol).font(.footnote)
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
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
    @EnvironmentObject private var signer: SAPSigner
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let destinations = [("搜索", "magnifyingglass"), ("下载", "arrow.down.circle"), ("已购", "clock.arrow.circlepath"), ("账号", "person.crop.circle")]
    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(selection: Binding<Int?>(get: { store.tab }, set: { if let value = $0 { store.tab = value } })) {
                        Section {
                            ForEach(0..<destinations.count, id: \.self) { index in
                                Label(destinations[index].0, systemImage: destinations[index].1).tag(index)
                            }
                        }
                        Section { Text("搜索、下载与版本管理").font(.caption).foregroundStyle(.secondary) }
                    }.navigationTitle("iPadn").navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                } detail: {
                    NavigationStack {
                        page(store.tab).frame(maxWidth: 900).frame(maxWidth: .infinity)
                            .background(Color(.systemGroupedBackground))
                    }.id(store.tab)
                }
            } else {
                TabView(selection: $store.tab) {
                    NavigationStack { SearchView() }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(0)
                    NavigationStack { DownloadsView() }.tabItem { Label("下载", systemImage: "arrow.down.circle") }
                        .badge(downloads.jobs.filter { DownloadFilter.active.includes($0.status) }.count).tag(1)
                    NavigationStack { PurchasedView() }.tabItem { Label("已购", systemImage: "clock.arrow.circlepath") }.tag(2)
                    NavigationStack { AccountsView() }.tabItem { Label("账号", systemImage: "person.crop.circle") }.tag(3)
                }
            }
        }
        .preferredColorScheme(store.settings.appearance == "system" ? nil : store.settings.appearance == "dark" ? .dark : .light)
        .sensoryFeedback(.selection, trigger: store.tab)
        .background {
            if let web = signer.webView {
                SignerWebView(web: web).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = store.infoMessage {
                Button { store.infoMessage = nil } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                        Text(message).font(.footnote.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(UX.onAccent).padding(.horizontal, 18).padding(.vertical, 13)
                        .background(UX.buttonTint, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).accessibilityLabel(message).accessibilityHint("点按关闭提示")
                    .frame(maxWidth: 420).padding(.horizontal, 24).padding(.bottom, sizeClass == .regular ? 20 : 88)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.infoMessage)
        .task(id: store.infoMessage) {
            guard let message = store.infoMessage else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            do { try await Task.sleep(nanoseconds: 3_500_000_000) } catch { return }
            if store.infoMessage == message { store.infoMessage = nil }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
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

