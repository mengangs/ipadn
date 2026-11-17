import XCTest
@testable import iPadn

final class AccountBackupTests: XCTestCase {
    func testProfileBackupExcludesSensitiveCredentialsAndPreservesFields() throws {
        let accounts = [
            AppleAccount(
                id: "alice@example.com",
                name: "Alice",
                password: "super-secret-password",
                cookie: "session=secret-cookie-value",
                dsid: "987654321",
                passwordToken: "super-secret-token-xyz",
                storeFront: "143465",
                fullStoreFront: "143465-19,29"
            ),
            AppleAccount(
                id: "bob@example.com",
                name: "Bob",
                password: "bob-password",
                cookie: "bob=cookie",
                dsid: "123456789",
                passwordToken: "bob-secret-token",
                storeFront: "143441",
                fullStoreFront: "143441-1,29"
            )
        ]

        let backup = try AccountBackupService.makeBackup(from: accounts, activeID: "alice@example.com")
        let data = try backup.encoded()
        let rawText = try XCTUnwrap(String(data: data, encoding: .utf8))

        for forbiddenSecret in [
            "super-secret-password",
            "super-secret-token-xyz",
            "secret-cookie-value",
            "bob-password",
            "bob-secret-token",
            "987654321",
            "123456789",
            "passwordToken",
            "\"cookie\"",
            "\"password\"",
            "\"dsid\""
        ] {
            XCTAssertFalse(rawText.contains(forbiddenSecret), "Exported profile backup must not contain \(forbiddenSecret)")
        }

        let decoded = try AccountProfileBackup.decode(data)
        XCTAssertEqual(decoded.format, AccountProfileBackup.currentFormat)
        XCTAssertEqual(decoded.accounts.count, 2)
        XCTAssertEqual(decoded.accounts[0].id, "alice@example.com")
        XCTAssertEqual(decoded.accounts[0].storeFront, "143465")
        XCTAssertEqual(decoded.accounts[1].fullStoreFront, "143441-1,29")

        let placeholders = decoded.accounts.map(\.placeholderAccount)
        XCTAssertTrue(placeholders.allSatisfy(\.needsReauthentication))
        XCTAssertFalse(placeholders.contains(where: \.hasValidSession))
    }

    func testDecodeRejectsMalformedSettingsOrEncryptedBackups() throws {
        XCTAssertThrowsError(try AccountProfileBackup.decode(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? AccountBackupError, .invalidFormat)
        }
        XCTAssertThrowsError(try AccountProfileBackup.decode(Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? AccountBackupError, .invalidFormat)
        }

        let settingsBackup = AppBackup(
            settings: ToolSettings(),
            favorites: [],
            watch: [:],
            keptVersions: [:],
            searchHistory: []
        )
        let settingsData = try settingsBackup.encoded()
        XCTAssertThrowsError(try AccountProfileBackup.decode(settingsData)) { error in
            XCTAssertEqual(error as? AccountBackupError, .wrongBackupKindSettings)
        }

        let encryptedPayload = Data(#"{"schema":"app.ipadn.account-profiles","format":1,"kind":"encrypted","cipher":"AES-256-GCM","accounts":[]}"#.utf8)
        XCTAssertThrowsError(try AccountProfileBackup.decode(encryptedPayload)) { error in
            XCTAssertEqual(error as? AccountBackupError, .encryptedUnsupported)
        }

        var futureBackup = try AccountBackupService.makeBackup(
            from: [AppleAccount(id: "future@example.com", name: "F", password: "", cookie: "", dsid: "", passwordToken: "", storeFront: "143441", fullStoreFront: "")],
            activeID: nil
        )
        futureBackup.format = AccountProfileBackup.currentFormat + 1
        let futureData = try futureBackup.encoded()
        XCTAssertThrowsError(try AccountProfileBackup.decode(futureData)) { error in
            XCTAssertEqual(error as? AccountBackupError, .unsupportedVersion)
        }

        let blankIDPayload = Data(#"{"schema":"app.ipadn.account-profiles","format":1,"kind":"profile","accounts":[{"id":"   ","name":"Bad"}]}"#.utf8)
        XCTAssertThrowsError(try AccountProfileBackup.decode(blankIDPayload)) { error in
            XCTAssertEqual(error as? AccountBackupError, .invalidAccountEntry)
        }

        let emptyListPayload = Data(#"{"schema":"app.ipadn.account-profiles","format":1,"kind":"profile","accounts":[]}"#.utf8)
        XCTAssertThrowsError(try AccountProfileBackup.decode(emptyListPayload)) { error in
            XCTAssertEqual(error as? AccountBackupError, .emptyAccounts)
        }
    }

    func testDecodeCompatibleWithMinimalLegacyFieldsAndDeduplicatesWithinFile() throws {
        let minimal = Data("""
        {
          "schema": "app.ipadn.account-profiles",
          "format": 1,
          "accounts": [
            { "id": "  User@Example.com " },
            { "id": "user@example.com", "name": "Recovered Name", "storeFront": "143462" }
          ]
        }
        """.utf8)
        let decoded = try AccountProfileBackup.decode(minimal)
        XCTAssertEqual(decoded.accounts.count, 1)
        XCTAssertEqual(decoded.accounts[0].id, "User@Example.com")
        XCTAssertEqual(decoded.accounts[0].name, "Recovered Name")
        XCTAssertEqual(decoded.accounts[0].storeFront, "143462")
    }

    func testMergePreservesExistingCredentialsUnderAllPolicies() throws {
        let signedInExisting = AppleAccount(
            id: "existing@example.com",
            name: "Local Name",
            password: "local-password",
            cookie: "local-cookie",
            dsid: "777",
            passwordToken: "local-token",
            storeFront: "143465",
            fullStoreFront: "143465-19,29"
        )
        let imported = AccountProfileBackup(accounts: [
            AccountProfileEntry(id: "EXISTING@example.com", name: "Imported Name", storeFront: "143441", fullStoreFront: "143441-1,29"),
            AccountProfileEntry(id: "new@example.com", name: "New Placeholder", storeFront: "143462", fullStoreFront: "")
        ])

        let skipped = AccountBackupService.merge(imported: imported, into: [signedInExisting], policy: .skipExisting)
        XCTAssertEqual(skipped.mergedAccounts.count, 2)
        XCTAssertEqual(skipped.addedIDs, ["new@example.com"])
        XCTAssertEqual(skipped.skippedIDs, ["existing@example.com"])
        XCTAssertEqual(skipped.mergedAccounts[0].name, "Local Name")
        XCTAssertEqual(skipped.mergedAccounts[0].passwordToken, "local-token")
        XCTAssertTrue(skipped.mergedAccounts[0].hasValidSession)
        XCTAssertTrue(skipped.mergedAccounts[1].needsReauthentication)

        let updated = AccountBackupService.merge(imported: imported, into: [signedInExisting], policy: .updateProfileKeepingSession)
        XCTAssertEqual(updated.mergedAccounts.count, 2)
        XCTAssertEqual(updated.updatedIDs, ["existing@example.com"])
        XCTAssertEqual(updated.mergedAccounts[0].name, "Imported Name")
        XCTAssertEqual(updated.mergedAccounts[0].storeFront, "143441")
        XCTAssertEqual(updated.mergedAccounts[0].password, "local-password")
        XCTAssertEqual(updated.mergedAccounts[0].passwordToken, "local-token")
        XCTAssertEqual(updated.mergedAccounts[0].dsid, "777")
        XCTAssertTrue(updated.mergedAccounts[0].hasValidSession)
    }

    @MainActor
    func testEmptyTokenAccountCannotPassAsValidSession() async throws {
        let placeholder = AppleAccount(
            id: "imported@example.com",
            name: "Imported",
            password: "",
            cookie: "",
            dsid: "123456", // Even with DSID alone, missing passwordToken must require re-auth
            passwordToken: "",
            storeFront: "143465",
            fullStoreFront: ""
        )
        XCTAssertFalse(placeholder.hasValidSession)
        XCTAssertTrue(placeholder.needsReauthentication)

        let key = "AppleService_PlaceholderTest"
        _ = key
        let backup = AccountProfileBackup(accounts: [
            AccountProfileEntry(id: "placeholder@example.com", name: "Placeholder", storeFront: "143465", fullStoreFront: "")
        ])
        let merged = AccountBackupService.merge(imported: backup, into: [], policy: .skipExisting)
        XCTAssertEqual(merged.mergedAccounts.count, 1)
        XCTAssertFalse(merged.mergedAccounts[0].hasValidSession)
    }

    func testUnifiedBackupCarriesAndDeduplicatesNonSensitiveAccountProfiles() throws {
        let accounts = [
            AppleAccount(
                id: "alice@example.com",
                name: "Alice",
                password: "secret-password",
                cookie: "secret=cookie",
                dsid: "999999",
                passwordToken: "secret-token",
                storeFront: "143465",
                fullStoreFront: "143465-19,29"
            ),
            AppleAccount(
                id: "ALICE@example.com",
                name: "Duplicate",
                password: "dup",
                cookie: "",
                dsid: "",
                passwordToken: "",
                storeFront: "143441",
                fullStoreFront: ""
            )
        ]
        let entries = AccountBackupService.entries(from: accounts)
        XCTAssertEqual(entries.count, 1)

        let unified = AppBackup(
            settings: ToolSettings(),
            favorites: [],
            watch: [:],
            keptVersions: [:],
            searchHistory: [],
            accountProfiles: entries,
            preferredActiveAccountID: "alice@example.com"
        )
        let data = try unified.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for secret in ["secret-password", "secret=cookie", "999999", "secret-token", "passwordToken", "\"password\"", "\"cookie\"", "\"dsid\""] {
            XCTAssertFalse(text.contains(secret), "Unified backup leaked credential material: \(secret)")
        }
        let decoded = try AppBackup.decode(data)
        XCTAssertEqual(decoded.format, AppBackup.currentFormat)
        XCTAssertEqual(decoded.accountProfiles?.count, 1)
        XCTAssertEqual(decoded.accountProfiles?.first?.id, "alice@example.com")
    }

    func testFullBackupPreservesCookiesTokensPasswordsGUIDAndStoreProofs() throws {
        let accounts = [
            AppleAccount(
                id: "alice@example.com",
                name: "Alice",
                password: "alice-password",
                cookie: "mz_at0-999999=fresh-cookie; mzf_in=123",
                dsid: "999999",
                passwordToken: "alice-secret-token",
                storeFront: "143465",
                fullStoreFront: "143465-19,29"
            ),
            AppleAccount(
                id: "ALICE@example.com",
                name: "",
                password: "",
                cookie: "",
                dsid: "",
                passwordToken: "",
                storeFront: "143441",
                fullStoreFront: ""
            )
        ]
        let sessions = AccountBackupService.sessions(
            from: accounts,
            liveCookies: ["alice@example.com": "mz_at0-999999=live-cookie-v2; wosid=abc"]
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].cookie, "mz_at0-999999=live-cookie-v2; wosid=abc")
        XCTAssertEqual(sessions[0].passwordToken, "alice-secret-token")

        let proof = StoreProofRecord(
            identifier: "0123456789abcdef",
            files: ["adi.pb": "AQIDBA=="],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let backup = AppBackup(
            settings: ToolSettings(),
            favorites: [],
            watch: [:],
            keptVersions: [:],
            searchHistory: [],
            accountSessions: sessions,
            preferredActiveAccountID: "alice@example.com",
            deviceGUID: "a1b2c3d4e5f6",
            storeProofRecords: ["a1b2c3d4e5f6": proof]
        )

        let plainData = try backup.encoded()
        let decoded = try AppBackup.decode(plainData)
        XCTAssertEqual(decoded.deviceGUID, "A1B2C3D4E5F6")
        XCTAssertEqual(decoded.accountSessions?.count, 1)
        XCTAssertEqual(decoded.accountSessions?.first?.cookie, "mz_at0-999999=live-cookie-v2; wosid=abc")
        XCTAssertEqual(decoded.accountSessions?.first?.passwordToken, "alice-secret-token")
        XCTAssertEqual(decoded.accountSessions?.first?.password, "alice-password")
        XCTAssertEqual(decoded.accountSessions?.first?.dsid, "999999")
        XCTAssertEqual(decoded.storeProofRecords?["a1b2c3d4e5f6"]?.identifier, "0123456789abcdef")
        XCTAssertTrue(decoded.includesSensitiveCredentials)

        // Merge: skipExisting preserves existing local account while adding new full accounts cleanly
        let localExisting = AppleAccount(
            id: "existing@example.com",
            name: "Local",
            password: "local-pw",
            cookie: "local=cookie",
            dsid: "111",
            passwordToken: "local-token",
            storeFront: "143465",
            fullStoreFront: ""
        )
        let skipped = AccountBackupService.merge(
            entries: sessions + [AccountSessionEntry(id: "EXISTING@example.com", name: "Over", password: "new-pw", cookie: "new=cookie", dsid: "222", passwordToken: "new-tok", storeFront: "143441")],
            into: [localExisting],
            policy: .skipExisting
        )
        XCTAssertEqual(skipped.mergedAccounts.count, 2)
        XCTAssertEqual(skipped.mergedAccounts[0].cookie, "local=cookie")
        XCTAssertEqual(skipped.mergedAccounts[1].cookie, "mz_at0-999999=live-cookie-v2; wosid=abc")
        XCTAssertTrue(skipped.mergedAccounts[1].hasValidSession)

        // Merge: overwriteExisting replaces full session credentials including cookie & token
        let overwritten = AccountBackupService.merge(
            entries: [AccountSessionEntry(id: "EXISTING@example.com", name: "Over", password: "new-pw", cookie: "new=cookie", dsid: "222", passwordToken: "new-tok", storeFront: "143441")],
            into: [localExisting],
            policy: .overwriteExisting
        )
        XCTAssertEqual(overwritten.updatedIDs, ["existing@example.com"])
        XCTAssertEqual(overwritten.mergedAccounts[0].cookie, "new=cookie")
        XCTAssertEqual(overwritten.mergedAccounts[0].passwordToken, "new-tok")
        XCTAssertEqual(overwritten.mergedAccounts[0].password, "new-pw")
        XCTAssertEqual(overwritten.mergedAccounts[0].dsid, "222")

        #if canImport(CryptoKit) && canImport(CommonCrypto)
        // Optional password encryption round-trip + wrong-password rejection
        let encrypted = try BackupCrypto.encrypt(plainData, password: "correct-horse-battery")
        XCTAssertTrue(EncryptedBackupEnvelope.isEncryptedEnvelope(encrypted))
        let encText = try XCTUnwrap(String(data: encrypted, encoding: .utf8))
        XCTAssertFalse(encText.contains("alice-secret-token"))
        XCTAssertFalse(encText.contains("live-cookie-v2"))
        XCTAssertThrowsError(try AppBackup.decode(encrypted)) { error in
            XCTAssertEqual(error as? AccountBackupError, .encryptedPasswordRequired)
        }
        XCTAssertThrowsError(try BackupCrypto.decrypt(encrypted, password: "wrong-password")) { error in
            XCTAssertEqual(error as? AccountBackupError, .wrongPassword)
        }
        let decrypted = try BackupCrypto.decrypt(encrypted, password: "correct-horse-battery")
        let decryptedBackup = try AppBackup.decode(decrypted)
        XCTAssertEqual(decryptedBackup.accountSessions?.first?.cookie, "mz_at0-999999=live-cookie-v2; wosid=abc")
        #endif
    }

    func testStoreProofSanitizationDropsInvalidKeysIdentifiersAndPaths() throws {
        let backup = AppBackup(
            settings: ToolSettings(),
            favorites: [],
            watch: [:],
            keptVersions: [:],
            searchHistory: [],
            accountSessions: nil,
            preferredActiveAccountID: nil,
            deviceGUID: "a1b2c3d4e5f6",
            storeProofRecords: [
                "a1b2c3d4e5f6": StoreProofRecord(
                    identifier: "0123456789abcdef",
                    files: [
                        "adi.pb": "AQIDBA==",
                        "../escape": "evil",
                        "nested/path": "evil",
                        ".": "evil",
                        "..": "evil"
                    ]
                ),
                "bad-guid": StoreProofRecord(
                    identifier: "0123456789abcdef",
                    files: ["adi.pb": "AQIDBA=="]
                ),
                "112233445566": StoreProofRecord(
                    identifier: "not-16-hex",
                    files: ["adi.pb": "AQIDBA=="]
                )
            ]
        )

        let decoded = try AppBackup.decode(backup.encoded())
        XCTAssertEqual(decoded.storeProofRecords?.count, 1)
        let record = try XCTUnwrap(decoded.storeProofRecords?["a1b2c3d4e5f6"])
        XCTAssertEqual(record.identifier, "0123456789abcdef")
        XCTAssertEqual(record.files, ["adi.pb": "AQIDBA=="])
    }
}
