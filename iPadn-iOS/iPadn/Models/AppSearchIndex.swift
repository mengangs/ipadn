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
        return AppSearchRanking.mergeUnique(apps.filter {
            normalized($0.name).contains(needle) || normalized($0.bundleID).contains(needle) || $0.id == term
        })
    }
}

enum AppSearchRanking {
    /// Relevance tier for keyword ranking:
    /// 5 = exact App ID, 4 = exact normalized name/alias,
    /// 3 = prefix or word-prefix match on name/alias,
    /// 2 = substring match on name/alias,
    /// 1 = bundleID match,
    /// 0 = server metadata / localized match without literal name substring.
    static func relevanceTier(for app: StoreApp, query: String, aliases: [String] = []) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if app.id == trimmed { return 5 }
        let needle = AppSearchIndex.normalized(trimmed)
        guard !needle.isEmpty else { return 0 }
        let names = ([app.name] + aliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedNames = names.map(AppSearchIndex.normalized).filter { !$0.isEmpty }
        if normalizedNames.contains(needle) { return 4 }
        let foldedNeedle = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                           locale: Locale(identifier: "en_US_POSIX")).lowercased()
        if normalizedNames.contains(where: { $0.hasPrefix(needle) }) ||
           names.contains(where: { hasWordPrefix($0, needle: needle, foldedNeedle: foldedNeedle) }) {
            return 3
        }
        if normalizedNames.contains(where: { $0.contains(needle) }) { return 2 }
        if AppSearchIndex.normalized(app.bundleID).contains(needle) { return 1 }
        return 0
    }

    private static func hasWordPrefix(_ name: String, needle: String, foldedNeedle: String) -> Bool {
        let tokens = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if tokens.contains(where: { AppSearchIndex.normalized($0).hasPrefix(needle) }) { return true }
        return name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                            locale: Locale(identifier: "en_US_POSIX")).lowercased().hasPrefix(foldedNeedle)
    }

    /// Deduplicates while preserving the strongest known metadata across saved sources.
    static func mergeUnique(_ apps: [StoreApp]) -> [StoreApp] {
        var result: [StoreApp] = []
        var indices: [String: Int] = [:]
        for app in apps where !app.id.isEmpty && app.id.allSatisfy({ $0.isASCII && $0.isNumber }) {
            if let index = indices[app.id] {
                if result[index].iconURL == nil { result[index].iconURL = app.iconURL }
                if app.delisted == true { result[index].delisted = true }
                if result[index].bundleID.isEmpty && !app.bundleID.isEmpty { result[index].bundleID = app.bundleID }
                if result[index].version.isEmpty && !app.version.isEmpty { result[index].version = app.version }
                if result[index].category.isEmpty && !app.category.isEmpty { result[index].category = app.category }
            } else {
                indices[app.id] = result.count
                result.append(app)
            }
        }
        return result
    }

    /// Merges remote storefront results with local candidates. When `prioritizeDelisted`
    /// is true, confirmed-delisted matches advance ahead of non-delisted results of
    /// equal or lower relevance tier while keeping live store order intact.
    static func arrange(
        remote: [StoreApp],
        local: [StoreApp],
        aliasesByID: [String: [String]] = [:],
        query: String,
        prioritizeDelisted: Bool
    ) -> (results: [StoreApp], localResults: [StoreApp]) {
        let remoteIDs = Set(remote.map(\.id))
        let remainingLocal = local.filter { !remoteIDs.contains($0.id) }
        guard prioritizeDelisted else {
            return (remote, remainingLocal)
        }
        var promoted: [(app: StoreApp, tier: Int, order: Int)] = []
        var keptLocal: [(app: StoreApp, tier: Int, order: Int)] = []
        for (offset, app) in remainingLocal.enumerated() {
            let tier = relevanceTier(for: app, query: query, aliases: aliasesByID[app.id] ?? [])
            if app.isDelisted && tier > 0 {
                promoted.append((app, tier, offset))
            } else {
                keptLocal.append((app, tier, offset))
            }
        }
        keptLocal.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
            return lhs.order < rhs.order
        }
        let sortedLocal = keptLocal.map(\.app)

        var liveRemote: [(app: StoreApp, tier: Int)] = []
        var delistedRemote: [(app: StoreApp, tier: Int, order: Int)] = []
        for (offset, app) in remote.enumerated() {
            let tier = relevanceTier(for: app, query: query, aliases: aliasesByID[app.id] ?? [])
            if app.isDelisted {
                delistedRemote.append((app, tier, offset))
            } else {
                liveRemote.append((app, tier))
            }
        }
        guard !promoted.isEmpty || !delistedRemote.isEmpty else {
            return (remote, sortedLocal)
        }
        let orderedDelisted = (delistedRemote + promoted.map { ($0.app, $0.tier, remote.count + $0.order) })
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
                return lhs.order < rhs.order
            }
        for item in orderedDelisted {
            let insertAt = liveRemote.firstIndex { existing in
                if existing.app.isDelisted { return existing.tier < item.tier }
                return existing.tier <= item.tier
            } ?? liveRemote.endIndex
            liveRemote.insert((item.app, item.tier), at: insertAt)
        }
        return (liveRemote.map(\.app), sortedLocal)
    }
}
