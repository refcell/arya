// Test helper: appends notes to a ledger so tests can prove that several processes append
// safely. Usage: AryaLedgerWriter <home> <writer-name> <count> <seed>
// Each note's payload is {"writer": <name>, "n": <1...count>}.
import AryaCore
import AryaLedger
import Foundation

let args = CommandLine.arguments
guard args.count == 5, let count = Int(args[3]), let seed = UInt64(args[4]) else {
    FileHandle.standardError.write(Data("usage: AryaLedgerWriter home name count seed\n".utf8))
    exit(2)
}
let home = URL(fileURLWithPath: args[1], isDirectory: true)
let name = args[2]
do {
    let store = try LedgerStore(home: home, ambient: .fixed(seed: seed), segmentLimitBytes: 4096)
    for n in 1...count {
        try store.append(
            EventDraft(
                type: "test.note", actor: .system,
                payload: ["writer": .string(name), "n": .int(Int64(n))]))
    }
} catch {
    FileHandle.standardError.write(Data("writer \(name) failed: \(error)\n".utf8))
    exit(1)
}
