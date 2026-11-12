import SwiftUI

/// Two downloaded packages of one app side by side: what the newer one
/// changed (Pro mode, from Package Info).
struct PackageCompareView: View {
    let older: (version: String, file: URL)
    let newer: (version: String, file: URL)
    @State private var comparison: PackageComparison?
    @State private var issue: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(verbatim: older.version.isEmpty ? "–" : older.version).font(.headline.monospacedDigit())
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: newer.version.isEmpty ? "–" : newer.version).font(.headline.monospacedDigit())
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AppText.text("从 \(older.version) 到 \(newer.version)"))
            }
            if let comparison {
                if comparison.unchanged {
                    Section { Text("两个安装包声明的内容相同。").foregroundStyle(.secondary) }
                }
                if !comparison.basics.isEmpty {
                    Section("基本信息") {
                        ForEach(comparison.basics) { change in
                            LabeledContent(change.title) {
                                Text(verbatim: "\(change.old) → \(change.new)").foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                    }
                }
                ForEach(comparison.lists.filter { !$0.change.isEmpty }, id: \.title) { list in
                    Section {
                        ForEach(list.change.added, id: \.self) { item in changeRow(item, added: true) }
                        ForEach(list.change.removed, id: \.self) { item in changeRow(item, added: false) }
                    } header: {
                        Text(verbatim: list.title)
                    }
                }
            } else if let issue {
                Section { InlineIssue(message: issue) }
            } else {
                Section { HStack(spacing: 10) { ProgressView(); Text("正在读取…").foregroundStyle(.secondary) } }
            }
        }
        .toolPage().navigationTitle("版本对比").navigationBarTitleDisplayMode(.inline)
        .task {
            let old = older.file, new = newer.file
            do {
                comparison = try await Task.detached(priority: .userInitiated) {
                    PackageComparison.compare(try PackageInfoService.read(old), try PackageInfoService.read(new))
                }.value
            } catch { issue = error.localizedDescription }
        }
    }

    private func changeRow(_ item: String, added: Bool) -> some View {
        Label {
            Text(verbatim: item).textSelection(.enabled)
        } icon: {
            Image(systemName: added ? "plus.circle.fill" : "minus.circle.fill").foregroundStyle(added ? .green : .red)
        }
        .accessibilityLabel(added ? AppText.text("新增：\(item)") : AppText.text("移除：\(item)"))
    }
}
