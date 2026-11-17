import Foundation

// Host-side harness: run the app's MachOScan implementation over an unpacked
// IPA tree so the parsing offsets are validated before any device run.
// Build: swiftc -O FairPlayEnvironment.swift tools/host/scan_main.swift -o scan

@main
struct ScanMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("usage: scan <directory>")
            exit(2)
        }
        let root = URL(fileURLWithPath: arguments[1])
        let rows = MachOScan.scanTree(root)
        var encrypted = 0
        var plain = 0
        var encryptedSlices = 0
        for row in rows.sorted(by: { $0.path < $1.path }) {
            let ids = row.slices.map { $0.cryptid }
            let isEncrypted = ids.contains { $0 != 0 }
            if isEncrypted {
                encrypted += 1
                encryptedSlices += ids.filter { $0 != 0 }.count
            } else {
                plain += 1
            }
            print("\(isEncrypted ? "ENCRYPTED" : "plain    ") \(row.path) \(row.slices.map { $0.description }.joined(separator: " | "))")
        }
        print("\nsummary: \(plain) plain, \(encrypted) encrypted, \(rows.count) Mach-O, \(encryptedSlices) encrypted slices")
        exit(encrypted > 0 ? 1 : 0)
    }
}
