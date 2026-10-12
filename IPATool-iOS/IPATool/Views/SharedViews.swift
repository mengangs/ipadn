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
        .sheet(isPresented: Binding(get: { signer.isPresented }, set: { if !$0 { signer.cancel() } })) {
            SignerProgressView().environmentObject(signer).interactiveDismissDisabled()
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("提示", isPresented: Binding(get: { store.infoMessage != nil }, set: { if !$0 { store.infoMessage = nil } })) {
            Button("好", role: .cancel) { store.infoMessage = nil }
        } message: { Text(store.infoMessage ?? "") }
    }
}


struct SignerProgressView: View {
    @EnvironmentObject private var signer: SAPSigner
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                if let web = signer.webView {
                    SignerWebView(web: web).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Image(systemName: signer.title == "准备下载" ? "arrow.down.app" : "lock.shield")
                            .font(.system(size: 40)).foregroundStyle(.tint)
                            .padding(20).background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(signer.title).font(.largeTitle.bold())
                            Text("请保持应用在前台，首次准备可能需要较长时间。")
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(0..<3) { index in
                                HStack(spacing: 14) {
                                    if index < signer.stageIndex { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                    else if index == signer.stageIndex { ProgressView().frame(width: 20) }
                                    else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                                    Text(index == 0 ? "准备本地环境" : index == 1 ? "加载验证组件" : signer.title == "准备下载" ? "生成下载授权数据" : "生成请求签名")
                                        .foregroundStyle(index <= signer.stageIndex ? .primary : .secondary)
                                }
                            }
                            Divider()
                            TimelineView(.periodic(from: signer.startedAt, by: 1)) { context in
                                let elapsed = max(0, Int(context.date.timeIntervalSince(signer.startedAt)))
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("已用时 \(elapsed) 秒").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                    if elapsed >= 30 { Text("仍在处理，可以取消后重试；本次验证超时会自动停止。")
                                        .font(.footnote).foregroundStyle(.secondary) }
                                }
                            }
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                        Button("取消本次操作", role: .cancel) { signer.cancel() }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }.padding(24).frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("IPA 工具箱").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { signer.cancel() } } }
        }
    }
}
