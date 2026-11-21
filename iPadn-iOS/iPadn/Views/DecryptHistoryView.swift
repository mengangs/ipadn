import SwiftUI

struct DecryptHistoryView: View {
    @ObservedObject private var records = DecryptRecordStore.shared
    @ObservedObject private var service = FairPlayHub.shared.service
    @ObservedObject private var ui = FairPlayPresentation.shared
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var store: ToolStore

    @State private var filter = 0
    @State private var selected = Set<UUID>()
    @State private var editing = false
    @State private var confirmingSelected = false
    @State private var confirmingClear = false

    private var filtered: [DecryptRecord] {
        switch filter {
        case 1: return records.records.filter { DecryptOutcomeStyle($0) == .success || DecryptOutcomeStyle($0) == .plain }
        case 2: return records.records.filter {
            let style = DecryptOutcomeStyle($0)
            return style == .partial || style == .failed || style == .cancelled || style == .interrupted
        }
        default: return records.records
        }
    }

    private var removableIDs: [UUID] {
        filtered.filter { !(service.isRunning && service.activeRecordID == $0.id) }.map(\.id)
    }

    var body: some View {
        List {
            if records.records.isEmpty {
                Section {
                    EmptyState(title: "还没有处理记录", systemImage: "clock")
                }.listRowBackground(Color.clear)
            } else {
                Section {
                    Picker("筛选记录", selection: $filter) {
                        Text("全部").tag(0)
                        Text("已完成").tag(1)
                        Text("异常与取消").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                if filtered.isEmpty {
                    Section {
                        Text("没有符合条件的记录").foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(filtered) { record in
                            let isActive = record.id == service.activeRecordID && service.isRunning
                            if editing {
                                Button {
                                    if !selected.insert(record.id).inserted { selected.remove(record.id) }
                                    UX.feedback()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2)
                                            .foregroundStyle(selected.contains(record.id) ? Color.accentColor : Color.secondary)
                                            .compatibleSymbolReplacement()
                                        row(record)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isActive)
                            } else {
                                Button {
                                    ui.push(.record(record.id))
                                } label: {
                                    HStack(spacing: 10) {
                                        row(record)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.forward")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(RevealRowButtonStyle())
                                .revealDelete(id: "history." + record.id.uuidString, enabled: !isActive, fills: true) {
                                    records.remove(id: record.id)
                                    ui.markFilesChanged()
                                    UX.feedback()
                                }
                            }
                        }
                    } footer: {
                        Text("保留最近 50 次处理。移除记录不会删除 IPA 文件。")
                    }
                }
            }
        }
        .toolPage()
        .navigationTitle("处理记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatibleTopBarTrailing) {
                Button(editing ? "完成" : "选择") {
                    editing.toggle()
                    selected.removeAll()
                }
                .disabled(records.records.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editing {
                HStack(spacing: 14) {
                    let ids = Set(removableIDs)
                    let all = !ids.isEmpty && ids.isSubset(of: selected)
                    Button(all ? "取消全选" : "全选") {
                        if all { selected.subtract(ids) } else { selected.formUnion(ids) }
                        UX.feedback()
                    }
                    .disabled(ids.isEmpty)

                    Spacer()

                    Button("清空记录", role: .destructive) { confirmingClear = true }
                        .disabled(records.records.allSatisfy { service.isRunning && service.activeRecordID == $0.id })

                    Button("移除所选", role: .destructive) { confirmingSelected = true }
                        .fontWeight(.semibold)
                        .disabled(selected.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.regularMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .actionConfirmation(
            isPresented: $confirmingSelected,
            title: "移除处理记录？",
            message: "只移除记录，所有 IPA 文件保留。",
            confirmTitle: "移除所选记录"
        ) {
            for id in selected where !(service.isRunning && service.activeRecordID == id) {
                records.remove(id: id)
            }
            ui.markFilesChanged()
            selected.removeAll()
            editing = false
        }
        .actionConfirmation(
            isPresented: $confirmingClear,
            title: "清空全部处理记录？",
            message: "只移除记录，所有 IPA 文件保留。",
            confirmTitle: "清空记录"
        ) {
            records.removeInactive(keeping: service.isRunning ? service.activeRecordID : nil)
            ui.markFilesChanged()
            selected.removeAll()
            editing = false
            store.infoMessage = AppText.text("已清空处理记录")
        }
        .compatibleOnChange(of: filter) { _ in selected.removeAll() }
    }

    private func row(_ record: DecryptRecord) -> some View {
        let style = DecryptOutcomeStyle(record)
        let name = PackageStage.displayName(record.appName)
        let time = record.startedAt.formatted(date: .abbreviated, time: .shortened)
        let version = (record.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = [version.isEmpty ? "" : "v\(version)", time].filter { !$0.isEmpty }.joined(separator: " · ")
        return PackageLibraryRow(
            name: name,
            icon: ui.iconURL(for: record, manager: manager),
            metadata: metadata,
            status: style.title,
            symbol: style.symbol,
            color: style.color,
            iconSize: 48
        )
    }
}

private extension EmptyState {
    init(title: LocalizedStringKey, systemImage: String) {
        self.init(title: title, message: "发起解密后，历史记录会保存在这里。", symbol: systemImage)
    }
}
