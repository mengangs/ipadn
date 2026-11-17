import Foundation

/// The only path from diagnostic text to the clipboard or an exported file.
/// Drop credential-bearing lines (including multiline XML/JSON values), then
/// scrub known secrets, email addresses, URL credentials and opaque tokens.
enum DiagnosticRedactor {
    static let replacement = "[REDACTED]"

    static func sanitize(_ text: String, secrets: [String] = []) -> String {
        var value = text
        for secret in secrets.filter({ $0.count >= 4 }).sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(of: secret, with: replacement)
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), encoded != secret {
                value = value.replacingOccurrences(of: encoded, with: replacement)
            }
        }
        let sensitive = #"(?i)(authorization|(?:set[-_]?)?cookie|password|passwd|\bpwd\b|token|secret|credential|apple[ _-]?id|\bdsid\b|dsprsid|personid|session[-_ ]?(?:id|key)|x-apple-|sinf\s*[:=<"'\[]|<key>\s*sinf\s*</key>|密[码钥]|令牌|凭据)"#
        var droppingValue = false
        value = value.components(separatedBy: .newlines).map { line in
            if line.range(of: sensitive, options: .regularExpression) != nil {
                // A key on its own can introduce an arbitrarily long value.
                droppingValue = true
                return replacement
            }
            if droppingValue {
                // An untrusted multiline value can contain blank lines or a
                // forged log prefix. Only the caller knows event boundaries;
                // consume the remainder of this event without guessing.
                return replacement
            }
            return line
        }.joined(separator: "\n")
        let patterns = [
            #"(?i)[A-Z0-9._%+\-]+(?:@|%40)[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            #"(?i)https?://[^\s/]+:[^\s@]+@[^\s]+"#,
            #"(?i)https?://[^\s]*[?][^\s]+"#,
            #"(?i)\bBearer\s+\S+"#,
            #"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b"#,
            #"[A-Za-z0-9+/_=\-]{40,}"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
        }
        return value
    }
}
