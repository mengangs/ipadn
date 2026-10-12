import SwiftUI
import UIKit

struct AppDetailView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    let app: StoreApp
    @State private var versions: [AppVersion] = []
    @State private var versionsLoading = false
    @State private var downloadLoading = false
    @State private var manualID = ""
    @State private var versionSearch = ""
    @State private var versionError: String?
    @State private var official = false
    @State private var showLogin = false
    @State private var showDescription = false
    @State private var reloadID = 0
    private var storeURL: URL { URL(string: "https://apps.apple.com/\(store.settings.store.country.lowercased())/app/id\(app.id)")! }
    private var filtered: [AppVersion] {
        versionSearch.isEmpty ? versions : versions.filter { $0.version.localizedCaseInsensitiveContains(versionSearch) || $0.id.contains(versionSearch) }
    }
    var body: some View {
        List {
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) { AppIcon(url: app.iconURL, size: 88); appHeading }
                    VStack(alignment: .leading, spacing: 16) { AppIcon(url: app.iconURL, size: 80); appHeading }
                }.padding(.vertical, 16)
                HStack(alignment: .top, spacing: 12) {
                    StatCell(value: app.size > 0 ? app.size.byteLabel : "—", title: "安装包大小")
                    StatCell(value: app.rating > 0 ? String(format: "%.1f", app.rating) : "—", title: "商店评分")
                    StatCell(value: app.minimumOS.isEmpty ? "—" : app.minimumOS, title: "最低系统")
                }.padding(.vertical, 8)
            }.listRowSeparator(.hidden)
            Section {
                Toggle("Apple 完整列表", isOn: $official).font(.subheadline)
                    .disabled(apple.active == nil || store.settings.store.platform == .tvOS)
                if versionsLoading { HStack { ProgressView(); Text("正在查找历史版本…").foregroundStyle(.secondary) } }
                if let versionError { InlineIssue(message: versionError) { reloadID += 1 } }
                if !versions.isEmpty {
                    SearchInput(text: $versionSearch, placeholder: "筛选版本号或版本 ID")
                    ForEach(filtered.prefix(100)) { version in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(version.version).font(.headline)
                                Text(version.source).font(.caption).foregroundStyle(.secondary)
                                Text(version.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            Button { download(versionID: version.id) } label: { Image(systemName: "arrow.down.circle.fill").font(.title2).frame(width: 48, height: 48) }
                                .buttonStyle(.borderless).disabled(downloadLoading).accessibilityLabel("下载版本 \(version.version)")
                        }.padding(.vertical, 6)
                            .contextMenu { Button("复制版本 ID") { copy(version.id) } }
                    }
                    if filtered.isEmpty { Text("没有匹配版本，请修改筛选条件。").font(.subheadline).foregroundStyle(.secondary) }
                    if filtered.count > 100 { Text("已显示前 100 项，输入版本号可继续查找。").font(.caption).foregroundStyle(.secondary) }
                } else if !versionsLoading && versionError == nil {
                    Text("暂无历史版本，可刷新或手动输入版本 ID。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                DisclosureGroup("手动指定版本") {
                    TextField("内部版本 ID（数字）", text: $manualID).keyboardType(.numberPad)
                    Button("下载此版本", systemImage: "arrow.down.circle") { download(versionID: manualID) }
                        .disabled(manualID.isEmpty || downloadLoading)
                }
            } header: {
                HStack { Text("历史版本 · \(versions.count)"); Spacer(); Button("刷新") { reloadID += 1 }.disabled(versionsLoading).textCase(nil) }
            } footer: { Text("版本可用性取决于商店地区及账号许可。") }
            Section("应用信息") {
                LabeledContent("App ID", value: app.id).textSelection(.enabled)
                if !app.bundleID.isEmpty { Text(app.bundleID).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                Button("复制 App ID", systemImage: "doc.on.doc") { copy(app.id) }
                Link(destination: storeURL) { Label("在 App Store 查看", systemImage: "arrow.up.right.square") }
            }
            if !app.description.isEmpty {
                Section("应用介绍") {
                    Text(app.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(showDescription ? nil : 5).textSelection(.enabled)
                    Button(showDescription ? "收起介绍" : "展开介绍") { showDescription.toggle() }
                }
            }
        }
        .toolPage().navigationTitle("应用详情").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button { download(versionID: app.externalVersionID) } label: {
                    HStack(spacing: 10) {
                        if downloadLoading { ProgressView().tint(.white) }
                        Label(downloadLoading ? "正在准备下载…" : apple.active == nil ? "登录后下载" : "下载当前版本", systemImage: apple.active == nil ? "person.crop.circle" : "arrow.down.circle.fill")
                    }.font(.headline).frame(maxWidth: .infinity).frame(minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(UX.buttonTint).controlSize(.large).disabled(downloadLoading)
                Text(apple.active.map { "使用账号 \($0.id)" } ?? "登录后获取你拥有许可的应用")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 680).frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .toolbar {
            Button { store.toggleFavorite(app); UX.feedback() } label: { Image(systemName: store.isFavorite(app) ? "star.fill" : "star").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel(store.isFavorite(app) ? "取消收藏" : "收藏应用")
            ShareLink(item: storeURL) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享商店链接")
        }
        .navigationDestination(isPresented: $showLogin) { LoginView() }
        .task(id: "\(official)-\(reloadID)-\(store.settings.store.country)-\(store.settings.store.platform.rawValue)") { await fetchVersions(force: reloadID > 0) }
    }
    private var appHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app.name.isEmpty ? app.bundleID : app.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            if !app.category.isEmpty { Text(app.category).font(.subheadline).foregroundStyle(.secondary) }
            Text(app.version.isEmpty ? "版本待查询" : "v\(app.version)").font(.subheadline.monospacedDigit()).foregroundStyle(.tint)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func copy(_ text: String) { UIPasteboard.general.string = text; store.infoMessage = "已复制到剪贴板"; UX.feedback() }
    private func fetchVersions(force: Bool) async {
        versionsLoading = true; versionError = nil
        defer { if !Task.isCancelled { versionsLoading = false } }
        do {
            let result = try await store.loadVersions(for: app, force: force, official: official)
            try Task.checkCancellation(); versions = result
        } catch is CancellationError { }
        catch { if !Task.isCancelled { versionError = error.localizedDescription } }
    }
    private func download(versionID: String?) {
        guard !downloadLoading else { return }
        guard apple.active != nil else { showLogin = true; return }
        if let versionID, !versionID.isEmpty, !versionID.allSatisfy(\.isNumber) { store.errorMessage = "版本 ID 必须是数字"; return }
        downloadLoading = true
        Task {
            defer { downloadLoading = false }
            do { try await store.startDownload(app: app, versionID: versionID?.isEmpty == true ? nil : versionID) }
            catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}
