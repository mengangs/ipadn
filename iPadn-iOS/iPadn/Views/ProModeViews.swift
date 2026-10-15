import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

/// 专业模式: the device identifier Apple sees and each account's sign-in
/// token. Only reachable when 专业模式 is on.
struct CredentialsView: View {
    @EnvironmentObject private var store: ToolStore
    @EnvironmentObject private var apple: AppleService
    @State private var editing = false
    @State private var draft = ""
    @State private var revealed = Set<String>()
    var body: some View {
        Form {
            Section {
                LabeledContent("设备标识") {
                    Text(apple.guid).font(.body.monospaced()).textSelection(.enabled)
                }
                Button("拷贝设备标识", systemImage: "doc.on.doc") { copy(apple.guid, secret: false) }
                Button("修改设备标识", systemImage: "pencil") { draft = apple.guid; editing = true }
                    .accessibilityIdentifier("pro.edit-device")
            } header: { Text("这台设备") } footer: {
                Text("Apple 用设备标识识别正在下载的设备。修改后，已登录的账号可能需要重新登录；Apple 也会限制一个账号同时使用的设备数量。")
            }
            if apple.accounts.isEmpty {
                Section { Text("还没有登录 Apple 账号。").foregroundStyle(.secondary) }
            }
            ForEach(apple.accounts) { account in
                Section {
                    if !account.dsid.isEmpty {
                        LabeledContent("DSID") { Text(account.dsid).font(.body.monospaced()).textSelection(.enabled) }
                    }
                    if !account.storeFront.isEmpty { LabeledContent("商店代码", value: account.storeFront) }
                    LabeledContent("令牌") {
                        Text(revealed.contains(account.id) ? account.passwordToken : String(repeating: "•", count: 12))
                            .font(.footnote.monospaced()).lineLimit(revealed.contains(account.id) ? nil : 1)
                            .textSelection(.enabled)
                    }
                    Button(revealed.contains(account.id) ? "隐藏令牌" : "显示令牌",
                           systemImage: revealed.contains(account.id) ? "eye.slash" : "eye") {
                        if revealed.contains(account.id) { revealed.remove(account.id) } else { revealed.insert(account.id) }
                    }
                    Button("拷贝令牌", systemImage: "doc.on.doc") { copy(account.passwordToken, secret: true) }
                        .disabled(account.passwordToken.isEmpty)
                } header: { Text(account.id).textCase(nil) }
            }
            if !apple.accounts.isEmpty {
                Section {} footer: {
                    Text("令牌可以直接访问你的 Apple 账号，请勿分享给任何人。拷贝的令牌两分钟后会从剪贴板清除。")
                }
            }
        }
        .toolPage().navigationTitle("账号与设备标识").navigationBarTitleDisplayMode(.inline)
        .alert("修改设备标识", isPresented: $editing) {
            TextField("12 位十六进制字符", text: $draft)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("随机生成") { save(AppleService.randomGUID()) }
            Button("保存") { save(draft) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("修改后，已登录的账号可能需要重新登录。")
        }
    }
    private func save(_ value: String) {
        do { try apple.setGUID(value); store.infoMessage = "已修改设备标识" }
        catch { store.errorMessage = error.localizedDescription }
    }
    private func copy(_ value: String, secret: Bool) {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if secret { options[.expirationDate] = Date().addingTimeInterval(120) }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: value]], options: options)
        store.infoMessage = "已拷贝"
    }
}

/// One file or folder inside a package.
struct PackageItem: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var isFolder: Bool
    var size: UInt64
    var compressedSize: UInt64
    var modified: Date?
    var id: String { path }
}

enum PackageContents {
    /// Everything in the archive, as paths without a trailing slash.
    static func items(_ file: URL) throws -> [PackageItem] {
        let archive = try Archive(url: file, accessMode: .read)
        var items: [PackageItem] = []
        var folders = Set<String>()
        for entry in archive {
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            guard !path.isEmpty, PackageService.isSafeArchivePath(path) else { continue }
            // Folders are often implied by their files rather than stored.
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, folders.insert(parent).inserted { parent = (parent as NSString).deletingLastPathComponent }
            if entry.type == .directory { folders.insert(path); continue }
            items.append(PackageItem(path: path, name: (path as NSString).lastPathComponent, isFolder: false,
                                     size: entry.uncompressedSize, compressedSize: entry.compressedSize,
                                     modified: entry.fileAttributes[.modificationDate] as? Date))
        }
        items += folders.map { PackageItem(path: $0, name: ($0 as NSString).lastPathComponent, isFolder: true, size: 0, compressedSize: 0) }
        return items
    }
    /// The direct children of `folder` ("" for the top level), folders first.
    static func children(of folder: String, in items: [PackageItem]) -> [PackageItem] {
        items.filter { ($0.path as NSString).deletingLastPathComponent == folder }
            .sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Copies one file out of the package into a temporary folder.
    static func extract(_ path: String, from file: URL) throws -> URL {
        let archive = try Archive(url: file, accessMode: .read)
        guard PackageService.isSafeArchivePath(path), let entry = archive[path], entry.type == .file else {
            throw ToolError.message("找不到这个文件")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PackageContents", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(PackageService.safeName((path as NSString).lastPathComponent))
        let checksum = try archive.extract(entry, to: destination)
        guard checksum == entry.checksum else {
            try? FileManager.default.removeItem(at: folder)
            throw ToolError.message("安装包已损坏，请重新下载")
        }
        return destination
    }
}

/// Browse what's inside a downloaded package and take single files out.
struct PackageContentsView: View {
    let file: URL
    var folder = ""
    /// Shared by every level, so the archive is read once.
    var preloaded: [PackageItem]?
    @State private var items: [PackageItem]?
    @State private var failure: String?
    @State private var query = ""
    private var title: String { folder.isEmpty ? "安装包内容" : (folder as NSString).lastPathComponent }
    var body: some View {
        let all = items ?? preloaded
        List {
            if let failure {
                Section { InlineIssue(message: failure) }
            } else if let all {
                let shown = query.isEmpty ? PackageContents.children(of: folder, in: all)
                    : all.filter { !$0.isFolder && $0.path.hasPrefix(folder) && $0.name.localizedCaseInsensitiveContains(query) }
                        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                Section {
                    ForEach(shown) { item in
                        if item.isFolder {
                            NavigationLink { PackageContentsView(file: file, folder: item.path, preloaded: all) } label: {
                                Label(item.name, systemImage: "folder").lineLimit(1)
                            }
                        } else {
                            NavigationLink { PackageFileView(file: file, item: item) } label: {
                                HStack {
                                    Label(item.name, systemImage: Self.symbol(item.name)).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(Int64(clamping: item.size).byteLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(query.isEmpty ? "\(shown.count) 项" : "找到 \(shown.count) 个文件")
                }
            } else {
                Section { HStack { ProgressView(); Text("正在读取…").foregroundStyle(.secondary) } }
            }
        }
        .toolPage().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索文件名")
        .task {
            guard items == nil, preloaded == nil else { return }
            let url = file
            do { items = try await Task.detached(priority: .userInitiated) { try PackageContents.items(url) }.value }
            catch { failure = "无法读取安装包内容。" }
        }
    }
    static func symbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "pdf": return "photo"
        case "plist", "json", "xml", "strings", "txt", "md": return "doc.text"
        case "car": return "paintpalette"
        case "dylib", "framework", "": return "gearshape"
        default: return "doc"
        }
    }
}

/// One file: its details, a preview for text and images, and a way to take
/// it out of the package.
private struct PackageFileView: View {
    let file: URL
    let item: PackageItem
    @State private var extracted: URL?
    @State private var text: String?
    @State private var image: UIImage?
    @State private var busy = false
    @State private var failure: String?
    @State private var sharing: SharedFile?
    private var kind: String { (item.name as NSString).pathExtension.lowercased() }
    private var previewsText: Bool { ["plist", "json", "xml", "strings", "txt", "md", "entitlements"].contains(kind) && item.size <= 1024 * 1024 }
    private var previewsImage: Bool { ["png", "jpg", "jpeg", "gif", "heic"].contains(kind) && item.size <= 20 * 1024 * 1024 }
    var body: some View {
        Form {
            Section {
                LabeledContent("路径") { Text(item.path).font(.footnote.monospaced()).textSelection(.enabled) }
                LabeledContent("大小", value: Int64(clamping: item.size).byteLabel)
                LabeledContent("压缩后", value: Int64(clamping: item.compressedSize).byteLabel)
                if let modified = item.modified { LabeledContent("修改时间", value: modified.formatted(date: .abbreviated, time: .shortened)) }
            }
            if let image {
                Section("预览") { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).frame(maxWidth: .infinity) }
            } else if let text {
                Section("预览") { Text(text).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if let failure { Section { InlineIssue(message: failure) } }
            Section {
                Button {
                    Task { if let url = await extract() { sharing = SharedFile(url: url) } }
                } label: {
                    HStack { Label("提取并分享", systemImage: "square.and.arrow.up"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy)
                .accessibilityIdentifier("pro.extract")
            } footer: { Text("文件会复制到临时位置，不会改动安装包。") }
        }
        .toolPage().navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .task {
            guard previewsText || previewsImage, let url = await extract() else { return }
            let wantsImage = previewsImage
            // Read and prepared off the main thread; long text is cut short so
            // the page stays responsive.
            let preview = await Task.detached(priority: .userInitiated) { () -> (UIImage?, String?) in
                guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
                if wantsImage {
                    guard let full = UIImage(data: data) else { return (nil, nil) }
                    let scale = min(1, 1200 / max(full.size.width, full.size.height, 1))
                    let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
                    return (await full.byPreparingThumbnail(ofSize: size) ?? full, nil)
                }
                return (nil, Self.readable(data).map(Self.shortened))
            }.value
            image = preview.0; text = preview.1
        }
    }
    private func extract() async -> URL? {
        if let extracted { return extracted }
        busy = true; defer { busy = false }
        let (source, path) = (file, item.path)
        do {
            let url = try await Task.detached(priority: .userInitiated) { try PackageContents.extract(path, from: source) }.value
            extracted = url
            return url
        } catch { failure = error.localizedDescription; return nil }
    }
    nonisolated static func shortened(_ text: String) -> String {
        let limit = 20_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n…（仅显示前 \(limit) 个字符，完整内容请提取后查看）"
    }
    /// Text as is; property lists (often binary) as XML.
    nonisolated static func readable(_ data: Data) -> String? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            return String(data: xml, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }
}
