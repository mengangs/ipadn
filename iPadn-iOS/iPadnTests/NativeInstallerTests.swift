import XCTest
@testable import iPadn

final class NativeInstallerTests: XCTestCase {
    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    func testPairingFileValidationAcceptsOnlyRemotePairingFiles() throws {
        let key = Data(repeating: 7, count: 32)
        XCTAssertNoThrow(try NativeInstaller.validatePairingFile(plist(["public_key": key, "private_key": key, "identifier": "host"])))
        // The optional key some tools add must not be rejected.
        XCTAssertNoThrow(try NativeInstaller.validatePairingFile(plist(["public_key": key, "private_key": key, "identifier": "host", "alt_irk": Data(count: 16)])))

        XCTAssertThrowsError(try NativeInstaller.validatePairingFile(Data("not a plist".utf8)))
        XCTAssertThrowsError(try NativeInstaller.validatePairingFile(plist(["public_key": Data(count: 31), "private_key": key, "identifier": "host"])))
        XCTAssertThrowsError(try NativeInstaller.validatePairingFile(plist(["public_key": key, "private_key": key, "identifier": ""])))
        XCTAssertThrowsError(try NativeInstaller.validatePairingFile(plist(["public_key": key, "identifier": "host"])))
        XCTAssertThrowsError(try NativeInstaller.validatePairingFile(Data(count: 64 * 1024 + 1)))
        // A lockdown pairing file gets its own explanation.
        XCTAssertThrowsError(try NativeInstaller.validatePairingFile(plist(["HostCertificate": Data(count: 8), "HostID": "x"]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("旧格式"))
        }
    }

    func testLookupReplyDistinguishesStoreManifestAndMissingApps() throws {
        let store = try NativeInstaller.lookupResult(from: Data(#"{"ok":true,"app":{"installed":true,"version":"26.1.4","build":"59151816","signer":"Apple iPhone OS Application Signing","placeholder":false,"store_item_id":"477537958","store_version_id":"894270367","has_purchase_record":true,"manifest_install":false}}"#.utf8))
        XCTAssertTrue(store.recognisedByAppStore)
        XCTAssertEqual(store.version, "26.1.4")
        XCTAssertEqual(store.storeItemID, "477537958")

        let manifest = try NativeInstaller.lookupResult(from: Data(#"{"ok":true,"app":{"installed":true,"version":"3.20.1","store_item_id":null,"store_version_id":null,"has_purchase_record":false,"manifest_install":true}}"#.utf8))
        XCTAssertTrue(manifest.installed)
        XCTAssertFalse(manifest.recognisedByAppStore)

        let missing = try NativeInstaller.lookupResult(from: Data(#"{"ok":true,"app":{"installed":false}}"#.utf8))
        XCTAssertFalse(missing.installed)
        XCTAssertFalse(missing.recognisedByAppStore)

        // A reply without an app must not read as "not installed".
        XCTAssertThrowsError(try NativeInstaller.lookupResult(from: Data(#"{"ok":true}"#.utf8)))
        XCTAssertThrowsError(try NativeInstaller.lookupResult(from: Data("garbage".utf8)))
    }

    func testInstallReplyReportsUpgradeFailureStageAndCancellation() throws {
        let upgraded = try NativeInstaller.installResult(from: Data(#"{"ok":true,"upgraded":true,"before":{"installed":true},"after":{"installed":true,"store_item_id":"1","has_purchase_record":true,"manifest_install":false}}"#.utf8))
        XCTAssertTrue(upgraded.upgraded)
        XCTAssertEqual(upgraded.after?.recognisedByAppStore, true)

        // The final lookup is best effort: a missing result is not a failure.
        let fresh = try NativeInstaller.installResult(from: Data(#"{"ok":true,"upgraded":false,"before":{"installed":false},"after":null}"#.utf8))
        XCTAssertFalse(fresh.upgraded)
        XCTAssertNil(fresh.after)

        XCTAssertThrowsError(try NativeInstaller.installResult(from: Data(#"{"ok":false,"stage":"pairing","message":"PairVerifyFailed"}"#.utf8))) { error in
            XCTAssertEqual(error as? NativeInstaller.Failure, NativeInstaller.Failure(stage: "pairing", detail: "PairVerifyFailed"))
            XCTAssertTrue(error.localizedDescription.contains("配对文件"))
        }
        XCTAssertThrowsError(try NativeInstaller.installResult(from: Data(#"{"ok":false,"stage":"cancelled","message":"cancelled"}"#.utf8))) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPairingEventsAndReplyAreParsedStrictly() throws {
        let ready = NativeInstaller.readyEvent(from: Data(#"{"port":53211,"identifier":"ABC","txt":{"name":"iPadn","flags":"1"}}"#.utf8))
        XCTAssertEqual(ready, .ready(port: 53211, identifier: "ABC", txt: ["name": "iPadn", "flags": "1"]))
        XCTAssertNil(NativeInstaller.readyEvent(from: Data(#"{"port":0,"identifier":"ABC","txt":{}}"#.utf8)))
        XCTAssertNil(NativeInstaller.readyEvent(from: Data(#"{"port":53211,"identifier":"","txt":{}}"#.utf8)))

        let file = Data("pairing".utf8)
        let reply = Data(#"{"ok":true,"device_name":"iPhone","pairing_file":"\#(file.base64EncodedString())"}"#.utf8)
        XCTAssertEqual(try NativeInstaller.pairingFile(fromReply: reply), file)
        XCTAssertThrowsError(try NativeInstaller.pairingFile(fromReply: Data(#"{"ok":true}"#.utf8)))
        XCTAssertThrowsError(try NativeInstaller.pairingFile(fromReply: Data(#"{"ok":false,"stage":"cancelled","message":""}"#.utf8))) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(NativeInstaller.message(stage: "timeout", detail: "").contains("5 分钟"))
    }

    func testFailureMessagesNameWhatTheUserCanFix() {
        XCTAssertTrue(NativeInstaller.message(stage: "connect", detail: "timed out").contains("LocalDevVPN"))
        XCTAssertTrue(NativeInstaller.message(stage: "install", detail: "ApplicationVerificationFailed").contains("验证"))
        XCTAssertTrue(NativeInstaller.message(stage: "install", detail: "DowngradeError").contains("降级"))
        XCTAssertTrue(NativeInstaller.message(stage: "upload", detail: "NoSpace").contains("存储空间"))
        // Unknown stages still surface the detail instead of hiding it.
        XCTAssertTrue(NativeInstaller.message(stage: "mystery", detail: "E42").contains("E42"))
    }

    func testNativeInstallationIsOptInAndKeepsTheOtherMethodChoice() throws {
        // Settings saved by earlier versions have no such key.
        var settings = try JSONDecoder().decode(ToolSettings.self, from: Data(#"{"automaticInstallation":false,"localInstallation":true}"#.utf8))
        XCTAssertFalse(settings.nativeInstallation)
        XCTAssertEqual(settings.installationMethodTitle, "本机证书")

        settings.nativeInstallation = true
        let restored = try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.nativeInstallation)
        XCTAssertFalse(restored.automaticInstallation)
        XCTAssertTrue(restored.localInstallation)
        // Without the library (simulator, builds without it) the choice
        // falls back to the method chosen before.
        XCTAssertEqual(restored.usesNativeInstallation, NativeInstaller.isAvailable)
        XCTAssertEqual(restored.installationMethodTitle, NativeInstaller.isAvailable ? "原生安装" : "本机证书")
    }
}
