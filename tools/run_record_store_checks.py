"""Exercise the actual metadata store on Linux with publisher-only shims.

Combine observation is irrelevant to these file-lifecycle checks. The store's
Foundation implementation is compiled unchanged except for its Combine import.
"""
import os
import subprocess
from pathlib import Path

root=Path(__file__).resolve().parents[1]
folder=root/'artifacts/uiux/store-checks'
folder.mkdir(parents=True,exist_ok=True)
source=(root/'iPadn-iOS/iPadn/Services/FairPlay/DecryptRecordStore.swift').read_text(encoding='utf-8')
(folder/'Store.swift').write_text(source.replace('import Combine',''),encoding='utf-8')
(folder/'Shims.swift').write_text('''import Foundation
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum FairPlayEnvironment {
    static let documentsDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipadn-record-test-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
''',encoding='utf-8')
(folder/'Main.swift').write_text('''import Foundation
@main struct Check {
    @MainActor static func main() throws {
        let directory = FairPlayEnvironment.documentsDirectory
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.ipa")
        try Data("original-fixture".utf8).write(to: source)
        let store = DecryptRecordStore()
        store.load()
        let record = DecryptRecord(sourceName: "original.ipa", sourceBytes: 16, appName: "Fixture", state: .running)
        store.upsert(record)
        let file = directory.appendingPathComponent("fairplay-records.json")
        precondition(FileManager.default.fileExists(atPath: file.path), "First save must create the history file")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode([DecryptRecord].self, from: Data(contentsOf: file))
        precondition(persisted.count == 1 && persisted[0].state == .running)
        let restored = DecryptRecordStore(); restored.load()
        precondition(restored.records.first?.state == .interrupted, "A dead process cannot have a live task")
        precondition(restored.records.first?.failure?.kind == .interrupted)
        restored.remove(id: record.id)
        let original = try Data(contentsOf: source)
        precondition(original == Data("original-fixture".utf8), "Removing metadata must preserve IPA files")
        for n in 0..<55 { restored.upsert(DecryptRecord(sourceName: "\\(n).ipa", sourceBytes: n, appName: "Fixture", state: .finished)) }
        precondition(restored.records.count == 50)
        restored.load()
        precondition(restored.records.count == 50, "Loading must be idempotent")
        print("PASS: 7 first-save, interruption recovery, retention and file-preservation checks")
    }
}
''',encoding='utf-8')
def wsl(path):
    path = Path(path).resolve()
    if path.drive:
        return '/mnt/'+path.drive[0].lower()+path.as_posix().split(':',1)[1]
    return path.as_posix()
files=[root/'iPadn-iOS/iPadn/Services/FairPlay/DecryptRecord.swift',folder/'Shims.swift',folder/'Store.swift',folder/'Main.swift']
command='swiftc '+' '.join("'"+wsl(p)+"'" for p in files)+' -o /tmp/ipadn-record-check && /tmp/ipadn-record-check'
runner = ['wsl','-d','Ubuntu','--','bash','-lc',command] if os.name == 'nt' else ['bash','-lc',command]
subprocess.run(runner,check=True)
