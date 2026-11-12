import SwiftUI

/// Shown on the Downloads page when iPadn runs inside LiveContainer: its
/// "Fix File Picker" app setting makes importing, exporting and the system
/// install prompt work (thanks to issue #44).
struct LiveContainerTip: View {
    var dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward").foregroundStyle(.tint).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("在 LiveContainer 中使用").font(.subheadline.weight(.semibold))
                // The option keeps LiveContainer's own name in each language.
                Text("在 LiveContainer 里长按 iPadn，打开设置中的「\(AppText.text("修复文件导入"))」。之后才能导入、导出安装包和诊断日志，一键安装也能弹出系统安装窗口。")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("知道了", action: dismiss).buttonStyle(CapsuleButtonStyle())
                    .accessibilityIdentifier("downloads.livecontainer-tip.dismiss")
            }
        }
        .padding(.vertical, 6)
    }
}
