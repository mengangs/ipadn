import Foundation

enum AppSearchIndex {
    static func unique(_ apps: [StoreApp]) -> [StoreApp] {
        var seen = Set<String>()
        return apps.filter { app in
            !app.id.isEmpty && app.id.allSatisfy { $0.isASCII && $0.isNumber } && seen.insert(app.id).inserted
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func search(_ input: String, apps: [StoreApp]) -> [StoreApp] {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let needle = normalized(term)
        guard !needle.isEmpty else { return [] }
        return unique(apps.filter {
            normalized($0.name).contains(needle) || normalized($0.bundleID).contains(needle) || $0.id == term
        })
    }
}
