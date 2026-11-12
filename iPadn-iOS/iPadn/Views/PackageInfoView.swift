import SwiftUI

/// Everything a downloaded package declares, on one page.
struct PackageInfoView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var manager: DownloadManager
    let file: URL
    /// The download it belongs to; other downloads of the same app can then
    /// be compared with it in Pro mode.
    var job: DownloadJob? = nil
    @State private var info: PackageInfo?
    @State private var issue: String?

    var body: some View {
        Form {
            if let info {
                Section("概览") {
                    row("Bundle ID", info.bundleID, monospaced: true)
                    row("版本", info.version)
                    row("构建号", info.build)
                    row("最低系统", info.minimumOS.isEmpty ? "" : "iOS " + info.minimumOS)
                    row("适用设备", info.devices)
                    if !info.languages.isEmpty {
                        NavigationLink {
                            List(info.languages, id: \.self) { code in
                                LabeledContent(Locale.current.localizedString(forIdentifier: code) ?? code, value: code)
                            }
                            .toolPage().navigationTitle("支持的语言").navigationBarTitleDisplayMode(.inline)
                        } label: {
                            LabeledContent("支持的语言", value: "\(info.languages.count)")
                        }
                    }
                }
                let permissions = PackageInfoService.groupedPermissions(info.permissions)
                Section {
                    if permissions.isEmpty {
                        Text("这个安装包没有声明需要用户授权的权限。").foregroundStyle(.secondary)
                    }
                    ForEach(permissions, id: \.name) { permission in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: permission.name)
                            ForEach(permission.reasons, id: \.self) { reason in
                                Text(verbatim: reason).font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("权限") + Text(verbatim: permissions.isEmpty ? "" : " · \(permissions.count)")
                } footer: {
                    if !info.permissions.isEmpty { Text("说明文字由开发者填写，申请时系统会显示给你。") }
                }
                if !info.extensions.isEmpty {
                    Section {
                        ForEach(info.extensions) { item in
                            LabeledContent(item.name, value: PackageInfoService.extensionKind(item.point) ?? item.point)
                        }
                    } header: {
                        Text("扩展") + Text(verbatim: " · \(info.extensions.count)")
                    }
                }
                Section("其他") {
                    LabeledContent("Apple Watch 版", value: info.hasWatchApp ? AppText.text("包含") : AppText.text("不包含"))
                    LabeledContent("App Clip", value: info.hasAppClip ? AppText.text("包含") : AppText.text("不包含"))
                    LabeledContent("内置框架", value: "\(info.frameworks)")
                    if !info.backgroundModes.isEmpty {
                        LabeledContent("后台运行", value: info.backgroundModes
                            .map { PackageInfoService.backgroundModeName($0) ?? $0 }
                            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                            .joined(separator: AppText.text("、")))
                    }
                    if !info.urlSchemes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("URL Scheme")
                            Text(verbatim: info.urlSchemes.joined(separator: "\n"))
                                .font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let job, store.settings.proMode, !otherVersions(of: job).isEmpty {
                    Section {
                        ForEach(otherVersions(of: job)) { other in
                            NavigationLink { compare(job, other) } label: {
                                LabeledContent(AppText.text("与版本 \(other.app.version.isEmpty ? "–" : other.app.version) 对比"),
                                               value: other.createdAt.formatted(date: .abbreviated, time: .omitted))
                            }
                            .accessibilityIdentifier("package-info.compare." + other.id.uuidString)
                        }
                    } header: { Text("版本对比") } footer: {
                        Text("对比两个已下载安装包的版本、权限、扩展、框架等变化。")
                    }
                }
            } else if let issue {
                Section { InlineIssue(message: issue) }
            } else {
                Section { HStack(spacing: 10) { ProgressView(); Text("正在读取…").foregroundStyle(.secondary) } }
            }
        }
        .toolPage().navigationTitle("安装包信息").navigationBarTitleDisplayMode(.inline)
        .task(id: file) {
            let url = file
            do { info = try await Task.detached(priority: .userInitiated) { try PackageInfoService.read(url) }.value }
            catch { issue = error.localizedDescription }
        }
    }

    /// Other finished downloads of the same app.
    private func otherVersions(of job: DownloadJob) -> [DownloadJob] {
        manager.jobs.filter {
            $0.id != job.id && $0.status == .completed && $0.rawFormat == nil
                && !$0.app.bundleID.isEmpty && $0.app.bundleID == job.app.bundleID && manager.fileURL($0) != nil
        }
    }

    /// Older on the left, newer on the right.
    @ViewBuilder private func compare(_ job: DownloadJob, _ other: DownloadJob) -> some View {
        if let otherFile = manager.fileURL(other) {
            let mine = (version: job.app.version, file: file), theirs = (version: other.app.version, file: otherFile)
            if VersionOrder.isNewer(job.app.version, than: other.app.version) {
                PackageCompareView(older: theirs, newer: mine)
            } else {
                PackageCompareView(older: mine, newer: theirs)
            }
        }
    }

    @ViewBuilder private func row(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        if !value.isEmpty {
            LabeledContent(title) {
                Text(verbatim: value).font(monospaced ? .footnote.monospaced() : .body)
                    .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}
