import SwiftUI
import UIKit

struct PackageFilePresentation: Identifiable {
    enum Kind { case save, share }
    let id = UUID()
    let url: URL
    let kind: Kind
}

/// Coordinates deferred and launch/background cleanup of temporary export,
/// hard-linked Share, and plaintext/encrypted backup files so out-of-process
/// share extensions finish reading while APFS hard links and credentials never leak.
enum TemporaryExportSweeper {
    private static let queue = DispatchQueue(label: "iPadn.temp-export-sweeper", qos: .utility)

    static func scheduleDelayedRemoval(of url: URL, delay: TimeInterval = 60) {
        queue.asyncAfter(deadline: .now() + delay) {
            removeTemporaryItem(at: url)
        }
    }

    static func removeShareHardLink(for jobID: UUID) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
        queue.async {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static func sweepStaleFiles(maxAge: TimeInterval = 0) {
        queue.async {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            let cutoff = Date().addingTimeInterval(-max(0, maxAge))

            func isStale(_ url: URL) -> Bool {
                guard maxAge > 0 else { return true }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (modified ?? .distantPast).timeIntervalSinceReferenceDate <= cutoff.timeIntervalSinceReferenceDate
            }

            for subfolder in ["Share", "PackageExports", "PackageContents"] {
                let dir = tmp.appendingPathComponent(subfolder, isDirectory: true)
                let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for entry in entries where isStale(entry) {
                    try? fm.removeItem(at: entry)
                }
            }

            let rootItems = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for item in rootItems where (item.lastPathComponent.hasPrefix("iPadn-Backup-")
                                         || item.lastPathComponent == "iPadn-Diagnostics.txt") && isStale(item) {
                try? fm.removeItem(at: item)
            }
        }
    }

    static func removeTemporaryItem(at url: URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let tmpPrefix = tmp.path.hasSuffix("/") ? tmp.path : tmp.path + "/"
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let lexical = url.standardizedFileURL

        for subfolder in ["Share", "PackageExports", "PackageContents"] {
            let root = tmp.appendingPathComponent(subfolder, isDirectory: true).standardizedFileURL.path + "/"
            if lexical.path.hasPrefix(root) {
                try? fm.removeItem(at: lexical.deletingLastPathComponent())
                return
            }
            if resolved.path.hasPrefix(root) {
                try? fm.removeItem(at: resolved.deletingLastPathComponent())
                return
            }
        }

        if lexical.path.hasPrefix(tmpPrefix) && lexical.lastPathComponent.hasPrefix("iPadn-Backup-") {
            try? fm.removeItem(at: lexical)
        } else if resolved.path.hasPrefix(tmpPrefix) && resolved.lastPathComponent.hasPrefix("iPadn-Backup-") {
            try? fm.removeItem(at: resolved)
        }
    }
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
            if let presentedURL { TemporaryExportSweeper.scheduleDelayedRemoval(of: presentedURL) }
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
