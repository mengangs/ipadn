import XCTest
@testable import iPadn

final class FairPlayTests: XCTestCase {
    private func appendLE(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private func appendBE(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private func makeThinMachO64(cryptoff: UInt32, cryptsize: UInt32, cryptid: UInt32) -> Data {
        var data = Data()
        appendLE(&data, 0xfeedfacf) // MH_MAGIC_64
        appendLE(&data, 0x0100000c) // CPU_TYPE_ARM64
        appendLE(&data, 0)
        appendLE(&data, 2)          // MH_EXECUTE
        appendLE(&data, 1)          // ncmds
        appendLE(&data, 24)         // sizeofcmds
        appendLE(&data, 0)          // flags
        appendLE(&data, 0)          // reserved
        appendLE(&data, 0x2c)       // LC_ENCRYPTION_INFO_64
        appendLE(&data, 24)         // cmdsize
        appendLE(&data, cryptoff)
        appendLE(&data, cryptsize)
        appendLE(&data, cryptid)
        appendLE(&data, 0)          // pad
        return data
    }

    func testVerifierReadsThinAndFat64Slices() {
        let thin = makeThinMachO64(cryptoff: 4096, cryptsize: 16384, cryptid: 1)
        let thinSlices = FairPlayVerifier.slices(thin)
        XCTAssertEqual(thinSlices.count, 1)
        XCTAssertEqual(thinSlices.first?.sliceOffset, 0)
        XCTAssertEqual(thinSlices.first?.cryptoff, 4096)
        XCTAssertEqual(thinSlices.first?.cryptsize, 16384)
        XCTAssertEqual(thinSlices.first?.cryptid, 1)

        var fat = Data()
        appendBE(&fat, 0xcafebabe)  // FAT_MAGIC
        appendBE(&fat, 2)           // nfat_arch
        // Arch 0: 32-bit slice (must be skipped)
        appendBE(&fat, 12)          // CPU_TYPE_ARM (32-bit)
        appendBE(&fat, 9)
        appendBE(&fat, 512)
        appendBE(&fat, 64)
        appendBE(&fat, 0)
        // Arch 1: 64-bit arm64 slice at offset 512
        appendBE(&fat, 0x0100000c)  // CPU_TYPE_ARM64
        appendBE(&fat, 0)
        appendBE(&fat, 512)
        appendBE(&fat, UInt32(thin.count))
        appendBE(&fat, 0)
        fat.append(Data(repeating: 0, count: 512 - fat.count))
        fat.append(thin)

        let fatSlices = FairPlayVerifier.slices(fat)
        XCTAssertEqual(fatSlices.count, 1)
        XCTAssertEqual(fatSlices.first?.sliceOffset, 512)
        XCTAssertEqual(fatSlices.first?.cryptoff, 4096)
        XCTAssertEqual(fatSlices.first?.cryptsize, 16384)
        XCTAssertEqual(fatSlices.first?.cryptid, 1)
    }

    func testVerifierMatchesBundleRelativePathsWithoutSuffixCollision() {
        XCTAssertTrue(FairPlayVerifier.matchesRelativePath("Demo.app/Demo", expectedKey: "Demo"))
        XCTAssertTrue(FairPlayVerifier.matchesRelativePath("Demo.app/Frameworks/Foo.framework/Foo", expectedKey: "Frameworks/Foo.framework/Foo"))
        XCTAssertFalse(FairPlayVerifier.matchesRelativePath("Demo.app/MyDemo", expectedKey: "Demo"))
        XCTAssertFalse(FairPlayVerifier.matchesRelativePath("Demo.app/DemoHelper", expectedKey: "Helper"))
    }

    func testFailureMapperDistinguishesEPERMAndEINVAL() {
        let denied = DecryptFailureMapper.map(
            error: FairPlayDecryptor.Failure.notDecryptable("refused"),
            logLines: ["  slice[0] [--] read+cid2 mremap=-1(Operation not permitted) mmap=ok"]
        )
        XCTAssertEqual(denied.kind, .fairplayDenied)
        XCTAssertEqual(denied.errno, EPERM)

        let invalid = DecryptFailureMapper.map(
            error: FairPlayDecryptor.Failure.notDecryptable("refused"),
            logLines: ["  slice[0] [--] read+cid2 mremap=-1(Invalid argument) mmap=ok"]
        )
        XCTAssertEqual(invalid.kind, .unsupportedBinary)
        XCTAssertEqual(invalid.errno, EINVAL)
    }

    func testMachOScanTreePreservesNestedRelativePaths() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ipadn-macho-scan-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let bin = makeThinMachO64(cryptoff: 4096, cryptsize: 16384, cryptid: 1)
        let mainURL = root.appendingPathComponent("Demo")
        let extDir = root.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true)
        let fwDir = root.appendingPathComponent("Frameworks/Lib.framework", isDirectory: true)
        try fm.createDirectory(at: extDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: fwDir, withIntermediateDirectories: true)
        try bin.write(to: mainURL)
        try bin.write(to: extDir.appendingPathComponent("Widget"))
        try bin.write(to: fwDir.appendingPathComponent("Lib"))

        let scanned = MachOScan.scanTree(root).map(\.path)
        XCTAssertEqual(Set(scanned), Set(["Demo", "PlugIns/Widget.appex/Widget", "Frameworks/Lib.framework/Lib"]))
    }

    func testDiagnosticRedactorIgnoresShortFlagsAndPreservesSinfStatus() {
        let log = "UNPACK Claude_1.26.19.ipa (145860236 B)\n[INFO] SINF placed beside 5 nested binaries"
        let out = DiagnosticRedactor.sanitize(log, secrets: ["1", "3", "/"])
        XCTAssertEqual(out, log)
        XCTAssertFalse(DiagnosticRedactor.sanitize("sinf=AAAABBBBCCCC").contains("AAAABBBBCCCC"))
    }

    func testFileReportAcceptsCodeConfirmedHighEntropyTablesAndRejectsHalfDecrypted() {
        // Pure-entropy pass even with zero landmarks (data-only/obfuscated).
        let dataOnly = FairPlayFileReport(
            path: "Demo.app/Frameworks/Data.framework/Data",
            cryptsize: 16384, entropy: 6.19, codeWords: 0, cryptid: 0, wasEncrypted: true
        )
        XCTAssertTrue(dataOnly.ok)

        // Constant-table heavy binary like Python `_codecs_cn`: entropy 7.57 with strong ARM64 landmarks.
        let cjkCodec = FairPlayFileReport(
            path: "APTV.app/Frameworks/_codecs_cn.framework/_codecs_cn",
            cryptsize: 28672, entropy: 7.57, codeWords: 23, cryptid: 0, wasEncrypted: true
        )
        XCTAssertTrue(cjkCodec.ok)

        // High entropy without sufficient code landmarks must still be rejected.
        let highNoCode = FairPlayFileReport(
            path: "Demo.app/Demo",
            cryptsize: 16384, entropy: 7.57, codeWords: 2, cryptid: 0, wasEncrypted: true
        )
        XCTAssertFalse(highNoCode.ok)

        // Half-decrypted ciphertext (>= 7.8) must still be rejected even with landmarks.
        let halfDecrypted = FairPlayFileReport(
            path: "Demo.app/Demo",
            cryptsize: 16384, entropy: 7.85, codeWords: 25, cryptid: 0, wasEncrypted: true
        )
        XCTAssertFalse(halfDecrypted.ok)
    }
}
