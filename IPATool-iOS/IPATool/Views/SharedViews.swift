import SwiftUI
import WebKit

struct AppIcon: View {
    var url: URL?
    var size: CGFloat = 56
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else {
                ZStack {
                    Color.accentColor.opacity(0.10)
                    Image(systemName: "app.dashed").font(.system(size: size * 0.42)).foregroundStyle(.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
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
    var body: some View {
        TabView(selection: $store.tab) {
            NavigationStack { SearchView() }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(0)
            NavigationStack { DownloadsView() }.tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .badge(downloads.jobs.filter { $0.status == .running }.count).tag(1)
            NavigationStack { PurchasedView() }.tabItem { Label("已购", systemImage: "clock.arrow.circlepath") }.tag(2)
            NavigationStack { AccountsView() }.tabItem { Label("账号", systemImage: "person.crop.circle") }.tag(3)
        }
        .preferredColorScheme(store.settings.appearance == "system" ? nil : store.settings.appearance == "dark" ? .dark : .light)
        .sheet(isPresented: $signer.isPresented) {
            NavigationStack {
                Group {
                    if let web = signer.webView { SignerWebView(web: web).ignoresSafeArea(edges: .bottom) }
                    else { ProgressView("准备签名环境…") }
                }
                .navigationTitle(signer.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { signer.cancel() } } }
            }
            .interactiveDismissDisabled()
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("提示", isPresented: Binding(get: { store.infoMessage != nil }, set: { if !$0 { store.infoMessage = nil } })) {
            Button("好", role: .cancel) { store.infoMessage = nil }
        } message: { Text(store.infoMessage ?? "") }
    }
}
