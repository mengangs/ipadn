import Foundation

/// GitHub's public Atom feed remains usable when its anonymous API is rate limited.
/// Accept stable tags and links only for this repository. IPA names follow the
/// release workflow's naming contract; the feed does not supply asset sizes.
enum AppReleaseFeed {
    static func parse(_ data: Data) -> AppRelease? {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else { return nil }
        let delegate = Feed()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.validFeed else { return nil }
        return delegate.releases.reduce(nil as AppRelease?) { best, next in
            guard let best else { return next }
            return VersionOrder.isNewer(next.version, than: best.version) ? next : best
        }
    }

    private final class Feed: NSObject, XMLParserDelegate {
        var validFeed = false
        var releases: [AppRelease] = []
        var stack: [String] = []
        var entryDepth: Int?
        var page: URL?
        var content = ""
        var updated = ""
        var count = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard stack.count < 64, count < 100_000 else { parser.abortParsing(); return }
            if stack.isEmpty {
                guard name == "feed", namespaceURI == "http://www.w3.org/2005/Atom" else { parser.abortParsing(); return }
                validFeed = true
            }
            stack.append(name)
            if name == "entry", stack.count == 2 {
                entryDepth = stack.count; page = nil; content = ""; updated = ""
            }
            if entryDepth != nil, name == "link", stack.count == 3,
               attributes["rel"] == "alternate", let href = attributes["href"] {
                page = URL(string: href)
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard entryDepth != nil else { return }
            if stack.contains("content") { content += string }
            else if stack.last == "updated", stack.count == 3 { updated += string }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let value = String(data: CDATABlock, encoding: .utf8) else { parser.abortParsing(); return }
            self.parser(parser, foundCharacters: value)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "entry", stack.count == entryDepth {
                appendRelease(); entryDepth = nil
            }
            _ = stack.popLast()
        }
        private func appendRelease() {
            guard let page, page.scheme == "https", page.host == "github.com",
                  page.user == nil, page.password == nil, page.port == nil,
                  page.query == nil, page.fragment == nil else { return }
            let prefix = "/\(AppUpdateService.repository)/releases/tag/"
            let path = page.path(percentEncoded: true)
            guard path.hasPrefix(prefix) else { return }
            let tag = String(path.dropFirst(prefix.count))
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return }
            let package = URL(string: "https://github.com/\(AppUpdateService.repository)/releases/download/\(tag)/iPadn-\(version)-unsigned.ipa")
            let date = try? Date(updated.trimmingCharacters(in: .whitespacesAndNewlines), strategy: .iso8601)
            releases.append(AppRelease(version: version, notes: plainNotes(content), page: page,
                package: package, packageSize: 0, published: date))
        }
        private func plainNotes(_ html: String) -> String {
            var text = html.replacingOccurrences(of: #"(?i)</(?:p|h[1-6]|li|ul|ol|div)>|<br\s*/?>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: value)
            }
            return AppUpdateService.notes(text)
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    }
}
