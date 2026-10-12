import Foundation

enum AppSearchIndex {
    static func unique(_ apps: [StoreApp]) -> [StoreApp] {
        var seen = Set<String>()
        return apps.filter { app in
            !app.id.isEmpty && app.id.allSatisfy { $0.isASCII && $0.isNumber } && seen.insert(app.id).inserted
        }
    }

    static func search(_ input: String, apps: [StoreApp]) -> [StoreApp] {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return unique(apps).filter {
            $0.name.localizedCaseInsensitiveContains(term) || $0.bundleID.localizedCaseInsensitiveContains(term) || $0.id == term
        }
    }
}
