import SwiftUI
import PhotosUI
import CryptoKit
import ImageIO

enum AvatarStorage {
    static func url(_ id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return LocalResources.support.appendingPathComponent("avatar-\(key).jpg")
    }
    static func prepare(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary), let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else {
            throw ToolError.message("无法读取这张照片，请选择其他图片。")
        }
        return jpeg
    }
}

struct AccountAvatar: View {
    @EnvironmentObject private var store: ToolStore
    let account: AppleAccount
    var size: CGFloat = 48
    var body: some View {
        Group {
            if let data = store.avatarData(for: account.id), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String((account.name.isEmpty ? account.id : account.name).prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .frame(width: size, height: size).foregroundStyle(.tint)
                    .background(Color.accentColor.opacity(0.12))
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct AvatarEditor: View {
    @EnvironmentObject private var store: ToolStore
    let account: AppleAccount
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    var body: some View {
        HStack(spacing: 16) {
            AccountAvatar(account: account, size: 64)
            VStack(alignment: .leading, spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(busy ? "正在保存…" : "更换头像", systemImage: "photo")
                }.disabled(busy)
                Text("仅保存在此设备，不会修改 Apple 账号头像。")
                    .font(.caption).foregroundStyle(.secondary)
                if store.avatarData(for: account.id) != nil {
                    Button("恢复姓名头像") {
                        do { try store.setAvatar(nil, for: account.id) }
                        catch { store.errorMessage = error.localizedDescription }
                    }.font(.caption).disabled(busy)
                }
            }
        }.padding(.vertical, 8)
        .task(id: photo) {
            guard let photo else { return }
            busy = true
            defer { busy = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw ToolError.message("未能读取所选照片。") }
                let jpeg = try await Task.detached(priority: .userInitiated) { try AvatarStorage.prepare(data) }.value
                try Task.checkCancellation()
                try store.setAvatar(jpeg, for: account.id)
                store.infoMessage = "头像已更新"
            } catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}
