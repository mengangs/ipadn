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
    private var filtered: [AppVersion] {
        versionSearch.isEmpty ? versions : versions.filter { $0.version.localizedCaseInsensitiveContains(versionSearch) || $0.id.contains(versionSearch) }
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        AppIcon(url: app.iconURL, size: 80)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(app.name).font(.title2.bold())
                            Text(app.category).font(.subheadline).foregroundStyle(.secondary)
                            Text(app.version.isEmpty ? "" : "当前版本 \(app.version)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        if app.size > 0 { Label(app.size.byteLabel, systemImage: "internaldrive") }
                        if app.rating > 0 { Label(String(format: "%.1f", app.rating), systemImage: "star.fill") }
                        Spacer()
                        Text(app.price)
                    }.font(.caption).foregroundStyle(.secondary)
                    Button { download(versionID: app.externalVersionID) } label: {
                        HStack { Spacer(); if downloadLoading { ProgressView() }; Label("下载当前版本", systemImage: "arrow.down.circle.fill"); Spacer() }
                    }.buttonStyle(.borderedProminent).disabled(downloadLoading)
                    if apple.active == nil {
                        Button("登录后下载") { store.tab = 3 }
                    } else { Text("下载账号：\(apple.active!.id)").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 10)
            }
            Section("应用信息") {
                LabeledContent("App ID", value: app.id).textSelection(.enabled)
                if !app.bundleID.isEmpty { LabeledContent("Bundle ID", value: app.bundleID).textSelection(.enabled) }
                if !app.minimumOS.isEmpty { LabeledContent("最低系统", value: app.minimumOS) }
                Button("复制 App ID") { UIPasteboard.general.string = app.id }
                if let url = URL(string: "https://apps.apple.com/\(store.settings.store.country.lowercased())/app/id\(app.id)") {
                    Link("在 App Store 查看", destination: url)
                }
            }
            Section("历史版本") {
                Toggle("从 Apple 获取完整版本列表", isOn: $official)
                    .disabled(apple.active == nil || store.settings.store.platform == .tvOS)
                Button { loadVersions(force: true) } label: {
                    HStack { Label("刷新版本列表", systemImage: "arrow.clockwise"); Spacer(); if versionsLoading { ProgressView() } }
                }.disabled(versionsLoading)
                if let error = versionError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !versions.isEmpty {
                    TextField("筛选版本号或版本 ID", text: $versionSearch)
                    ForEach(filtered) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(version.version).font(.headline)
                                Text("\(version.id) · \(version.source)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button { download(versionID: version.id) } label: { Image(systemName: "arrow.down.circle") }
                                .buttonStyle(.borderless).disabled(downloadLoading).accessibilityLabel("下载版本 \(version.version)")
                        }.padding(.vertical, 4)
                        .contextMenu { Button("复制版本 ID") { UIPasteboard.general.string = version.id } }
                    }
                }
                HStack {
                    TextField("手动输入版本 ID", text: $manualID).keyboardType(.numberPad)
                    Button("下载") { download(versionID: manualID) }.disabled(manualID.isEmpty || downloadLoading)
                }
            }
            if !app.description.isEmpty {
                Section("介绍") { Text(app.description).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .navigationTitle("应用详情").navigationBarTitleDisplayMode(.inline)
        .task { await fetchVersions(force: false) }
        .onChange(of: official) { _, _ in loadVersions(force: false) }
    }
    private func loadVersions(force: Bool) { Task { await fetchVersions(force: force) } }
    private func fetchVersions(force: Bool) async {
        guard !versionsLoading else { return }
        versionsLoading = true; versionError = nil
        defer { versionsLoading = false }
        do { versions = try await store.loadVersions(for: app, force: force, official: official) }
        catch is CancellationError { }
        catch { if !Task.isCancelled { versionError = error.localizedDescription } }
    }
    private func download(versionID: String?) {
        guard !downloadLoading else { return }
        if let versionID = versionID, !versionID.isEmpty, !versionID.allSatisfy(\.isNumber) {
            store.errorMessage = "版本 ID 必须是数字"; return
        }
        downloadLoading = true
        Task {
            defer { downloadLoading = false }
            do { try await store.startDownload(app: app, versionID: versionID?.isEmpty == true ? nil : versionID) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}
