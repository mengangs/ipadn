import SwiftUI
import UIKit

struct PackageFilePresentation: Identifiable {
    enum Kind { case save, share }
    let id = UUID()
    let url: URL
    let kind: Kind
}

/// Export a stable copy, so replacement/deletion of an internal output cannot
/// change the file while a system picker or share extension is using it.
enum PackageFileActions {
    static func prepare(_ source: URL, name: String? = nil, kind: PackageFilePresentation.Kind) throws -> PackageFilePresentation {
        guard FileManager.default.fileExists(atPath: source.path) else { throw ToolError.message(AppText.text("文件已不存在，请刷新后重试。")) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PackageExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(PackageService.safeName(name ?? source.lastPathComponent))
        do { try FileManager.default.linkItem(at: source, to: target) }
        catch { try FileManager.default.copyItem(at: source, to: target) }
        return PackageFilePresentation(url: target, kind: kind)
    }

    static func removeTemporary(_ url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PackageExports", isDirectory: true).standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

struct PackageFilePresenter: ViewModifier {
    @EnvironmentObject private var store: ToolStore
    @Binding var presentation: PackageFilePresentation?
    @State private var presentedURL: URL?
    func body(content: Content) -> some View {
        content.sheet(item: $presentation, onDismiss: {
            if let presentedURL { PackageFileActions.removeTemporary(presentedURL) }
            presentedURL = nil
        }) { item in
            Group {
                if item.kind == .save {
                    FileExportPicker(url: item.url, onFinish: { presentation = nil }, onExported: { store.infoMessage = AppText.text("已保存副本") }).ignoresSafeArea()
                } else { ShareSheet(items: [item.url]) }
            }.onAppear { presentedURL = item.url }
        }
    }
}

extension View {
    func packageFilePresenter(_ presentation: Binding<PackageFilePresentation?>) -> some View {
        modifier(PackageFilePresenter(presentation: presentation))
    }
}

struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void
    var onExported: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onExported: onExported) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        let onExported: (() -> Void)?
        init(onFinish: @escaping () -> Void, onExported: (() -> Void)?) { self.onFinish = onFinish; self.onExported = onExported }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if !urls.isEmpty { onExported?() }; onFinish() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
    }
}
