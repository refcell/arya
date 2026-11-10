import Arya
import AryaAdapters
import AryaCore
import Foundation

// arya-demo HOME EXAMPLES: seeds a busy demo home in one process (decision 0052). The fleet is
// the three example stewards (EXAMPLES/triage, refunds, digest: casebooks, rehearsals, a
// proposal, a correction, history, a crew) and eight generated ones across departments
// (Specs.swift): weeks of runs whose metrics follow on-track, behind, and recovering curves,
// approvals people decided and some still waiting, messages from people, proposals, memory,
// and today's runs with their cost. Every adapter is the fake adapter in process; the clock
// moves through the timeline; ids come from a fixed seed. `etc/scripts/demo.sh` runs it.

// `--pace-ms N` makes every adapter profile pace the fake adapter (for `demo.sh --live`);
// ARYA_DEMO_FLEET=examples seeds only the three example stewards (a quick check).
var arguments = Array(CommandLine.arguments.dropFirst())
var pace: Int?
if let flag = arguments.firstIndex(of: "--pace-ms"), flag + 1 < arguments.count {
    pace = Int(arguments[flag + 1])
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: arya-demo HOME EXAMPLES [--pace-ms N]\n".utf8))
    exit(64)
}
let home = URL(fileURLWithPath: arguments[0], isDirectory: true)
let examples = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fleet = ProcessInfo.processInfo.environment["ARYA_DEMO_FLEET"] != "examples"

do {
    let started = Date()
    let seeder = DemoSeeder(
        home: home, examples: examples, now: Date(), fleet: fleet, paceMillis: pace)
    let report = try await seeder.seed()
    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
    print("arya-demo: seeded \(report) in \(seconds) s")
} catch {
    FileHandle.standardError.write(Data("arya-demo: \(error)\n".utf8))
    exit(1)
}
