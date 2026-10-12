import SwiftUI

struct DownloadFilterBar: View {
    @Binding var selection: DownloadFilter
    let jobs: [DownloadJob]
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: typeSize.isAccessibilitySize ? 2 : 5), spacing: 6) {
            ForEach(DownloadFilter.allCases) { item in
                Button { selection = item; UX.feedback() } label: {
                    VStack(spacing: 3) {
                        Text(title(item)).font(.caption.weight(selection == item ? .semibold : .regular))
                        Text("\(jobs.filter { item.includes($0.status) }.count)").font(.caption2.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(selection == item ? UX.onAccent : Color.primary)
                    .background(selection == item ? UX.buttonTint : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityIdentifier("download.filter.\(item.id)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.rawValue)，\(jobs.filter { item.includes($0.status) }.count) 项")
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
    }
    private func title(_ filter: DownloadFilter) -> String {
        switch filter {
        case .all: return "全部"
        case .active: return "进行中"
        case .paused: return "暂停"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }
}
