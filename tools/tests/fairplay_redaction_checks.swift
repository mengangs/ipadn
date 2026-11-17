import Foundation

@main struct RedactionChecks {
    static func main() {
        let cases: [(String, [String])] = [
            ("Authorization: Bearer very-secret\n continuation-cookie\n[OK] safe", ["very-secret", "continuation-cookie"]),
            ("Set-Cookie: session=secret-cookie; path=/", ["secret-cookie"]),
            ("{\"passwordToken\":\n  \"short-secret\"\n}\n[INFO] safe", ["short-secret"]),
            ("<key>password</key>\n<string>xml-secret</string>\n[OK] safe", ["xml-secret"]),
            ("download user@example.com and user%40example.com", ["user@example.com", "user%40example.com"]),
            ("https://user:pass@example.com/file", ["user:pass"]),
            ("https://example.com/file?access_token=query-secret", ["query-secret"]),
            ("opaque abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG", ["abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"]),
            ("DSID=123456789\n[PHASE] PACK", ["123456789"])
            ,("Cookie:\n\n[OK] short-folded-value", ["short-folded-value"])
            ,("<key>token</key>\n[INFO] forged-prefix-value", ["forged-prefix-value"])
        ]
        for (input, forbidden) in cases {
            let output = DiagnosticRedactor.sanitize(input)
            for secret in forbidden { precondition(!output.contains(secret), "Redaction leaked a fixture value") }
            precondition(DiagnosticRedactor.sanitize(output) == output, "Redaction must be idempotent")
        }
        precondition(DiagnosticRedactor.sanitize("known tiny-value", secrets: ["tiny-value"]) == "known [REDACTED]")
        precondition(DiagnosticRedactor.sanitize("UNPACK Claude_1.26.19.ipa (145860236 B)", secrets: ["1", "3", "/"]) == "UNPACK Claude_1.26.19.ipa (145860236 B)")
        precondition(DiagnosticRedactor.sanitize("[INFO] SINF placed beside 5 nested binaries") == "[INFO] SINF placed beside 5 nested binaries")
        precondition(!DiagnosticRedactor.sanitize("sinf=secret-blob\n<key>sinf</key>\n<data>abc</data>").contains("secret-blob"))
        precondition(DiagnosticRedactor.sanitize("[OK] decrypted Frameworks/App\n[PHASE] PACK").contains("Frameworks/App"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipadn-ui-safety-\(UUID())")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.ipa")
        precondition(PackageOutputPolicy.existing(source: source, directory: directory).isEmpty)
        let expected = PackageOutputPolicy.candidates(source: source, directory: directory)
        precondition(expected.map(\.lastPathComponent) == ["sample-decrypted.ipa", "sample-PARTIAL.ipa"])
        try! Data("first".utf8).write(to: expected[0])
        try! Data("partial".utf8).write(to: expected[1])
        precondition(PackageOutputPolicy.existing(source: source, directory: directory).count == 2)
        let first = PackageOutputPolicy.identity(expected[0])
        precondition(PackageOutputPolicy.matches(first, url: expected[0]))
        precondition(PackageOutputPolicy.matches("/old/container/" + first, url: expected[0]))
        try! Data("replacement".utf8).write(to: expected[0])
        precondition(!PackageOutputPolicy.matches(first, url: expected[0]))
        let second = PackageOutputPolicy.identity(expected[0])
        precondition(second != first, "Changing output invalidates earlier consent and verification")
        let fm = FileManager.default
        let symRoot = fm.temporaryDirectory.appendingPathComponent("ipadn-symlink-test-\(UUID())")
        let privateVar = symRoot.appendingPathComponent("private/var", isDirectory: true)
        let realDecrypted = privateVar.appendingPathComponent("mobile/Decrypted", isDirectory: true)
        try! fm.createDirectory(at: realDecrypted, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: symRoot) }
        try! fm.createSymbolicLink(atPath: symRoot.appendingPathComponent("var").path, withDestinationPath: "private/var")
        let embyReal = realDecrypted.appendingPathComponent("084F11F7-Emby_2.2.59-decrypted.ipa")
        try! Data("emby".utf8).write(to: embyReal)
        let embyVarAlias = symRoot.appendingPathComponent("var/mobile/Decrypted/084F11F7-Emby_2.2.59-decrypted.ipa")
        let embyRelativeDot = symRoot.appendingPathComponent("var/mobile/../mobile/Decrypted/./084F11F7-Emby_2.2.59-decrypted.ipa")
        let scanned = try! fm.contentsOfDirectory(at: realDecrypted, includingPropertiesForKeys: nil)
        precondition(scanned.count == 1 && !Set([embyVarAlias]).contains(scanned[0]), "Raw URL set misses /var vs /private/var")
        precondition(PackageOutputPolicy.canonicalPath(embyVarAlias) == PackageOutputPolicy.canonicalPath(scanned[0]))
        precondition(PackageOutputPolicy.canonicalPath(embyRelativeDot) == PackageOutputPolicy.canonicalPath(scanned[0]))
        precondition(PackageOutputPolicy.unlinkedOutputs(in: realDecrypted, knownOutputs: [embyVarAlias]).isEmpty, "Known output via /var symlink must not appear unlinked")
        precondition(PackageOutputPolicy.unlinkedOutputs(in: realDecrypted, knownOutputs: []).map(\.lastPathComponent) == ["084F11F7-Emby_2.2.59-decrypted.ipa"], "Cleared records must surface physical file once as unlinked")
        print("PASS: 14 diagnostic privacy checks, 7 output collision/provenance checks, 5 symlink deduplication checks")
    }
}
