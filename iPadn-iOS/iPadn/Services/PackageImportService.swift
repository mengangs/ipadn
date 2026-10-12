import Foundation

enum PackageImportService {
    static func prepare(_ source: URL, id: UUID) throws -> StoreApp {
        guard source.isFileURL, ["ipa", "zip"].contains(source.pathExtension.lowercased()) else {
            throw ToolError.message("请选择 IPA 安装包，或包含 Payload 的 ZIP 文件")
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let stage = LocalResources.stagingURL(id)
        do {
            var coordinationError: NSError?
            var copyError: Error?
            // Coordinate provider access so Files and iCloud can materialize their
            // local copy before we inspect it. The original file remains untouched.
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: stage) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            return try PackageService.inspect(stage)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }
}
