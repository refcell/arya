import Foundation

/// Every routine across stewards, one entry per name: which stewards have it and at which live
/// version, every version, and how its runs went (a `routine` action naming it, settled by
/// `action.executed` or `action.failed`). The Routines library reads it.
struct RoutineLibrary: Hashable, Sendable {
    /// One run of a routine: the `routine` action, where it ran, on what, and how it settled.
    struct Run: Identifiable, Hashable, Sendable {
        enum Outcome: String, Hashable, Sendable { case passed, failed, denied, waiting }
        var id: String
        var steward: String?
        var input: String
        var at: Date
        var outcome: Outcome
    }

    struct Entry: Identifiable, Hashable, Sendable {
        var name: String
        /// One per steward that has proposed or runs it, by steward id.
        var uses: [RoutineItem]
        var runs: Int
        var passed: Int
        var failed: Int
        var lastRun: Date?
        /// Runs per day for the last 7 days, oldest first.
        var daily: [Double]
        /// Every run, oldest first.
        var all: [Run] = []
        /// The newest runs first, at most 20.
        var recent: [Run] { Array(all.reversed().prefix(20)) }

        var id: String { name }

        /// Stewards whose live charter runs a version of it.
        var live: [RoutineItem] { uses.filter { $0.live != nil } }

        /// Settled runs that passed, 0...1; nil before any settled.
        var passRate: Double? {
            let settled = passed + failed
            return settled == 0 ? nil : Double(passed) / Double(settled)
        }

        /// What "Use in steward…" copies: the newest live version and the steward that has
        /// it, else the newest proposed version.
        var source: (steward: String, version: String)? {
            let pick = live.max {
                ($0.history.last?.at ?? .distantPast) < ($1.history.last?.at ?? .distantPast)
            }
            if let pick, let steward = pick.steward, let version = pick.live {
                return (steward, version)
            }
            guard let item = uses.last, let steward = item.steward,
                let version = item.versions.last
            else { return nil }
            return (steward, version)
        }

        /// The use whose versions make the most useful diff (the one with the most versions).
        var diffable: RoutineItem? { uses.max { $0.versions.count < $1.versions.count } }

        /// The cache key of the diff the inspector shows; nil with a single version.
        var diffKey: String? {
            guard let item = diffable, let pair = item.defaultComparison else { return nil }
            return "\(item.id)@\(pair.old)..\(pair.new)"
        }
    }

    var entries: [Entry]

    init(events: [FeatureEvent], now: Date) {
        let items = RoutineList.build(events: events).routines
        var runs: [String: (runs: Int, passed: Int, failed: Int, last: Date?, at: [Date])] = [:]
        var pending: [String: String] = [:]
        var history: [String: [Run]] = [:]
        var spots: [String: (name: String, index: Int)] = [:]
        for event in events {
            switch event.type {
            case "action.proposed":
                guard let action = event.payload["action"], action["kind"]?.string == "routine",
                    let name = action["params"]?["name"]?.string
                else { continue }
                runs[name, default: (0, 0, 0, nil, [])].runs += 1
                runs[name]?.last = event.at
                runs[name]?.at.append(event.at)
                if let run = event.run, let id = action["id"]?.string {
                    let key = "\(run)/\(id)"
                    pending[key] = name
                    let input =
                        action["params"]?["input"]?.string ?? action["target"]?.string ?? ""
                    history[name, default: []].append(
                        Run(
                            id: key, steward: event.steward, input: input, at: event.at,
                            outcome: .waiting))
                    spots[key] = (name, (history[name]?.count ?? 1) - 1)
                }
            case "action.executed", "action.failed", "action.rejected":
                guard let run = event.run, let id = event.payload["action"]?.string else {
                    continue
                }
                let key = "\(run)/\(id)"
                if let spot = spots[key] {
                    history[spot.name]?[spot.index].outcome =
                        event.type == "action.executed"
                        ? .passed : event.type == "action.failed" ? .failed : .denied
                }
                guard event.type != "action.rejected",
                    let name = pending.removeValue(forKey: key)
                else { continue }
                if event.type == "action.executed" {
                    runs[name]?.passed += 1
                } else {
                    runs[name]?.failed += 1
                }
            default: continue
            }
        }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let grouped = Dictionary(grouping: items, by: \.name)
        entries = grouped.keys.sorted().map { name in
            let tally = runs[name]
            var daily = [Double](repeating: 0, count: 7)
            for at in tally?.at ?? [] {
                let days =
                    calendar.dateComponents([.day], from: calendar.startOfDay(for: at), to: today)
                    .day ?? 7
                if days >= 0, days < 7 { daily[6 - days] += 1 }
            }
            return Entry(
                name: name, uses: grouped[name] ?? [], runs: tally?.runs ?? 0,
                passed: tally?.passed ?? 0, failed: tally?.failed ?? 0, lastRun: tally?.last,
                daily: daily, all: history[name] ?? [])
        }
    }
}

enum RoutineLibraryText {
    /// "Upgrade to 1a2b3c4d5e6f" or "upgrade pending", for a steward that follows another.
    static func upgrade(_ upgrade: FeatureRoutineUpgrade) -> String {
        upgrade.pending ? "upgrade pending" : "Upgrade to " + RoutinesText.shortVersion(upgrade.to)
    }

    /// "pinned 1a2b3c4d5e6f": each steward runs its own live version until it adopts another
    /// (decision 0060); "proposed only" before one goes live.
    static func pin(_ use: RoutineItem) -> String {
        use.live.map { "pinned " + RoutinesText.shortVersion($0) } ?? "proposed only"
    }

    /// "92% pass · 25 runs", "no settled runs · 3 runs", or "not run yet".
    static func runs(_ entry: RoutineLibrary.Entry) -> String {
        guard entry.runs > 0 else { return "not run yet" }
        let count = entry.runs == 1 ? "1 run" : "\(entry.runs) runs"
        guard let rate = entry.passRate else { return "no settled runs · \(count)" }
        return "\(Int((rate * 100).rounded()))% pass · \(count)"
    }

    /// "live 1a2b3c4d5e6f" when every steward runs one version, "2 live versions", or
    /// "not live".
    static func version(_ entry: RoutineLibrary.Entry) -> String {
        let live = Set(entry.live.compactMap(\.live))
        switch live.count {
        case 0: return "not live"
        case 1: return "live " + RoutinesText.shortVersion(live.first ?? "")
        default: return "\(live.count) live versions"
        }
    }
}
