import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// Ways to support iPadn. Everything here is optional: the app stays free.
enum SupportLinks {
    static let afdian = URL(string: "https://afdian.com/a/mengangs")!
    /// USDT on BNB Smart Chain (BEP20) only.
    static let usdtAddress = "0x5f0cff7587b9fc305f9fa626135789bd5100818e"
    static let repository = URL(string: "https://github.com/mengangs/ipadn")!
    static let issues = URL(string: "https://github.com/mengangs/ipadn/issues")!
}

/// The settings row that opens the support page: a heart on a soft pink tile.
struct SupportRow: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.56), Color(red: 0.98, green: 0.24, blue: 0.38)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                Image(systemName: "heart.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("支持 iPadn").foregroundStyle(.primary)
                Text("永久免费开源").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SupportView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = 0
    private static let pink = Color(red: 0.98, green: 0.3, blue: 0.45)

    var body: some View {
        Form {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
            Section {
                Button { openURL(SupportLinks.afdian) } label: {
                    HStack(spacing: 14) {
                        tile("cup.and.saucer.fill", colors: [Color(red: 0.98, green: 0.6, blue: 0.3), Color(red: 0.95, green: 0.42, blue: 0.24)])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("爱发电").foregroundStyle(.primary)
                            Text("支持支付宝、微信").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("support.afdian")
            } header: { Text("请作者喝杯咖啡") }
            Section {
                VStack(spacing: 14) {
                    if let qr = Self.qrCode {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 168, height: 168)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
                            .accessibilityLabel(Text("USDT 收款地址二维码"))
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: "USDT").font(.subheadline.weight(.semibold))
                        Text(verbatim: "BNB Smart Chain (BEP20)").font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color(red: 0.95, green: 0.73, blue: 0.18).opacity(0.18), in: Capsule())
                            .foregroundStyle(Color(red: 0.72, green: 0.52, blue: 0.0))
                    }
                    Text(verbatim: SupportLinks.usdtAddress)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                        .padding(.horizontal, 4)
                        .environment(\.layoutDirection, .leftToRight)
                    Button { copyAddress() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("复制地址")
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle())
                    .accessibilityIdentifier("support.copy-usdt")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: { Text(verbatim: "USDT") } footer: {
                Text("仅接收 BEP20 网络的 USDT。转账前请核对网络和地址，其他网络或币种转入可能无法找回。")
            }
            Section {
                Link(destination: SupportLinks.repository) { Label("在 GitHub 上点个 Star", systemImage: "star") }
                Link(destination: SupportLinks.issues) { Label("反馈问题或改进翻译", systemImage: "bubble.left.and.text.bubble.right") }
            } header: { Text("其他支持方式") }
        }
        .toolPage().navigationTitle("支持 iPadn").navigationBarTitleDisplayMode(.inline)
        .task { if !reduceMotion { try? await Task.sleep(for: .milliseconds(350)); beat += 1 } }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                // A few small hearts around the big one, like confetti.
                ForEach(Self.confetti.indices, id: \.self) { index in
                    let item = Self.confetti[index]
                    Image(systemName: "heart.fill").font(.system(size: item.size))
                        .foregroundStyle(Self.pink.opacity(item.opacity))
                        .rotationEffect(.degrees(item.angle))
                        .offset(x: item.x, y: item.y)
                }
                Circle().fill(Self.pink.opacity(0.12)).frame(width: 104, height: 104)
                Image(systemName: "heart.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.58), Color(red: 0.94, green: 0.2, blue: 0.36)],
                                                    startPoint: .top, endPoint: .bottom))
                    .compatibleBounce(trigger: beat)
                    .onTapGesture { if !reduceMotion { beat += 1 } }
            }
            .frame(height: 130)
            .accessibilityHidden(true)
            Text("感谢你使用 iPadn").font(.title3.weight(.bold))
            Text("iPadn 会一直免费开源，没有广告。如果它帮到了你，欢迎请作者喝杯咖啡，你的鼓励是持续更新的动力。")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private func tile(_ symbol: String, colors: [Color]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private func copyAddress() {
        UIPasteboard.general.string = SupportLinks.usdtAddress
        store.infoMessage = AppText.text("已复制到剪贴板")
        UX.feedback()
    }

    private struct Confetti { let x: CGFloat; let y: CGFloat; let size: CGFloat; let angle: Double; let opacity: Double }
    private static let confetti = [
        Confetti(x: -88, y: -30, size: 16, angle: -18, opacity: 0.55),
        Confetti(x: -66, y: 34, size: 11, angle: 12, opacity: 0.35),
        Confetti(x: -112, y: 18, size: 8, angle: -6, opacity: 0.3),
        Confetti(x: 86, y: -36, size: 12, angle: 16, opacity: 0.4),
        Confetti(x: 102, y: 20, size: 17, angle: 22, opacity: 0.55),
        Confetti(x: 64, y: 44, size: 9, angle: -10, opacity: 0.3),
    ]

    /// The address as a QR code, made on the device.
    private static let qrCode: UIImage? = {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(SupportLinks.usdtAddress.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }()
}
