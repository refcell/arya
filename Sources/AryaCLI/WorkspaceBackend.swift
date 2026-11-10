import Arya
import AryaCore
import Foundation

/// The backend over `Arya.Workspace`. Facade calls that have not landed yet throw
/// `WorkspaceError.unavailable`, which becomes "not available yet" (exit 69) naming the call.
struct WorkspaceBackend: CLIBackend {
    let home: URL
    /// When set (`ARYA_CLOCK`), events are stamped from this time instead of the real clock.
    var clock: Date?

    private func open() async throws(CLIError) -> Workspace {
        if let clock {
            // Stamp events from `clock`, one millisecond per reading; ids stay random.
            let start = Timestamp(millis: Int64((clock.timeIntervalSince1970 * 1000).rounded()))
            let ambient = Ambient.fixed(
                start: start, stepMillis: 1, seed: UInt64.random(in: 1...UInt64.max))
            return try await call("open") {
                try await Workspace.open(home: home, ambient: ambient)
            }
        }
        return try await call("open") { try await Workspace.open(home: home) }
    }

    /// Parses `ARYA_CLOCK`: an RFC 3339 UTC time, with or without fractional seconds.
    static func clock(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    func initHome() async throws(CLIError) -> InitReport {
        let ledger = home.appendingPathComponent("ledger", isDirectory: true)
        let existed = FileManager.default.fileExists(atPath: ledger.path)
        _ = try await open()
        return InitReport(home: home.path, status: existed ? .existing : .created)
    }

    func createSteward(charterPath: String) async throws(CLIError) -> StewardDetail {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: charterPath))
        } catch {
            throw .notFound("charter file \(charterPath)")
        }
        let workspace = try await open()
        let summary = try await call("createSteward", rejection: { .invalidInput($0) }) {
            try await workspace.createSteward(charter: data)
        }
        return Mapping.detail(
            Mapping.steward(summary, pendingApprovals: 0, lastRun: nil),
            outcome: summary.outcome, charter: CharterDigest(json: data))
    }

    func fleet() async throws(CLIError) -> [FleetRow] {
        let workspace = try await open()
        return try await call("fleet") { try await workspace.fleet() }.map(Mapping.fleet)
    }

    func listStewards() async throws(CLIError) -> [StewardRow] {
        let workspace = try await open()
        let stewards = try await call("stewards") { try await workspace.stewards() }
        let approvals = await optional { try await workspace.approvals() } ?? []
        let runs = await optional { try await workspace.runs() } ?? []
        return stewards.map { steward in
            Mapping.steward(
                steward, pendingApprovals: approvals.filter { $0.steward == steward.id }.count,
                lastRun: runs.first { $0.steward == steward.id }?.id)
        }
    }

    func showSteward(_ id: String) async throws(CLIError) -> StewardDetail {
        let workspace = try await open()
        guard let steward = try await call("steward", { try await workspace.steward(id) }) else {
            throw .notFound("steward \(id)")
        }
        let approvals = await optional { try await workspace.approvals() } ?? []
        let runs = await optional { try await workspace.runs(steward: id) } ?? []
        let summary = Mapping.steward(
            steward, pendingApprovals: approvals.filter { $0.steward == id }.count,
            lastRun: runs.first?.id)
        let charter = await optional { try await workspace.charter(id) }
        return Mapping.detail(
            summary, outcome: steward.outcome, charter: charter.flatMap(CharterDigest.init(json:)))
    }

    func pauseSteward(_ id: String) async throws(CLIError) -> StewardDetail {
        let workspace = try await open()
        try await call("pauseSteward") { try await workspace.pauseSteward(id) }
        return try await showSteward(id)
    }

    func resumeSteward(_ id: String) async throws(CLIError) -> StewardDetail {
        let workspace = try await open()
        try await call("resumeSteward") { try await workspace.resumeSteward(id) }
        return try await showSteward(id)
    }

    func startRun(steward: String, input: String?) async throws(CLIError) -> RunReport {
        let workspace = try await open()
        let run = try await call("startRun") {
            try await workspace.startRun(steward: steward, input: input ?? "")
        }
        return try await report(run, workspace: workspace)
    }

    func abortRun(_ id: String, reason: String?) async throws(CLIError) -> RunReport {
        let workspace = try await open()
        let summary = try await call("abortRun", rejection: { .invalidInput($0) }) {
            try await workspace.abortRun(id, reason: reason)
        }
        return try await showRun(summary.id)
    }

    func showRun(_ id: String) async throws(CLIError) -> RunReport {
        let workspace = try await open()
        guard let detail = try await call("run", { try await workspace.run(id) }) else {
            throw .notFound("run \(id)")
        }
        return Mapping.report(detail, crew: await crew(of: id, workspace: workspace))
    }

    /// The crew children and join run of `id`, oldest first.
    private func crew(of id: String, workspace: Workspace) async -> [RunSummary] {
        let runs = await optional { try await workspace.runs() } ?? []
        return runs.filter { $0.parent == id }.sorted { $0.startedAt < $1.startedAt }
    }

    /// The run's detail from the facade, or a report read from its ledger entries.
    private func report(_ run: RunSummary, workspace: Workspace) async throws(CLIError)
        -> RunReport
    {
        if let detail = await optional({ try await workspace.run(run.id) }), let detail {
            return Mapping.report(detail, crew: await crew(of: run.id, workspace: workspace))
        }
        let entries = await optional { try await workspace.ledger() } ?? []
        let approvals = await optional { try await workspace.approvals(includeDecided: true) } ?? []
        return Mapping.report(
            run, entries: entries.filter { $0.run == run.id },
            approvals: approvals.filter { $0.run == run.id })
    }

    func listApprovals(steward: String?, scope: ApprovalScope) async throws(CLIError)
        -> [ApprovalRow]
    {
        let workspace = try await open()
        let approvals = try await call("approvals") {
            try await workspace.approvals(includeDecided: scope == .all)
        }
        return approvals.filter { steward == nil || $0.steward == steward }.map(Mapping.approval)
    }

    func decide(approval: String, decision: ApprovalDecision, note: String?, as person: String?)
        async throws(CLIError) -> ApprovalRow
    {
        let workspace = try await open()
        let result =
            switch decision {
            case .grant:
                try await call("approve") {
                    try await workspace.approve(approval, note: note, as: person ?? "local")
                }
            case .deny: try await call("deny") { try await workspace.deny(approval, note: note) }
            }
        return Mapping.approval(result)
    }

    func tailLedger(count: Int, steward: String?) async throws(CLIError) -> [EventSummary] {
        let workspace = try await open()
        let entries = try await call("ledger") { try await workspace.ledger() }
        let matching = entries.filter { steward == nil || $0.steward == steward }
        return matching.suffix(count).map(Mapping.event)
    }

    func verifyLedger() async throws(CLIError) -> VerifyReport {
        let workspace = try await open()
        let check = try await call("verifyLedger") { try await workspace.verifyLedger() }
        return Mapping.verify(check)
    }
}

/// Runs a facade call, mapping its errors. `rejection` picks how `WorkspaceError.rejected` is
/// reported (an invalid charter is invalid input; an already-decided approval is a failure).
private func call<T>(
    _ name: String, rejection: (String) -> CLIError = { .failed($0) },
    _ body: () async throws -> T
) async throws(CLIError) -> T {
    do {
        return try await body()
    } catch let error as WorkspaceError {
        switch error {
        case .unavailable: throw .unavailable("Workspace.\(name) (workspace lane)")
        case .notFound(let id): throw .notFound(id)
        case .rejected(let detail): throw rejection(detail)
        }
    } catch {
        throw .failed("\(name): \(error)")
    }
}

/// A facade call whose result only enriches the output: `nil` when it fails.
private func optional<T>(_ body: () async throws -> T) async -> T? {
    try? await body()
}

// The improvement loop. Calls the facade does not expose yet name the call they will use, so
// `just e2e` reports exactly what is missing.
extension WorkspaceBackend {
    private func missing(_ call: String) -> CLIError {
        .unavailable("Workspace.\(call) (workspace lane)")
    }

    func importCasebook(steward: String, path: String, name: String?) async throws(CLIError)
        -> CasebookRow
    {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .notFound("casebook file \(path)")
        }
        let name = name ?? url.deletingPathExtension().lastPathComponent
        let workspace = try await open()
        let summary = try await call("importCasebook", rejection: { .invalidInput($0) }) {
            try await workspace.importCasebook(steward: steward, data: data, name: name)
        }
        return Mapping.casebook(summary)
    }

    func listCasebooks(steward: String?) async throws(CLIError) -> [CasebookRow] {
        let workspace = try await open()
        let rows = try await call("casebooks") { try await workspace.casebooks(steward: steward) }
        return rows.map(Mapping.casebook)
    }

    func rehearse(steward: String, casebook: String?) async throws(CLIError) -> RehearsalReport {
        let workspace = try await open()
        var version: String?
        if let casebook {
            let books = try await call("casebooks") {
                try await workspace.casebooks(steward: steward)
            }
            guard
                let match = books.first(where: {
                    $0.name == casebook || $0.version.hasPrefix(casebook)
                })
            else { throw .notFound("casebook \(casebook) for \(steward)") }
            version = match.version
        }
        let summary = try await call("rehearse") {
            try await workspace.rehearse(steward: steward, casebook: version)
        }
        return Mapping.rehearsal(summary)
    }

    func correct(steward: String, case caseID: String, choice: String?, note: String?)
        async throws(CLIError) -> CorrectionReport
    {
        let workspace = try await open()
        var expected: Data?
        if let choice {
            expected = try await call("expected") {
                try await workspace.expected(steward: steward, case: caseID, choice: choice)
            }
        }
        let summary = try await call("correct", rejection: { .invalidInput($0) }) {
            try await workspace.correct(
                steward: steward, case: caseID, expected: expected, note: note)
        }
        return CorrectionReport(
            steward: summary.steward, case: summary.caseID, choice: choice, note: note,
            memory: summary.note)
    }

    func markReady(steward: String) async throws(CLIError) -> StewardDetail {
        let workspace = try await open()
        let summary = try await call("markReady") {
            try await workspace.markReady(steward: steward)
        }
        let charter = await optional { try await workspace.charter(steward) }
        let approvals = await optional { try await workspace.approvals() } ?? []
        let runs = await optional { try await workspace.runs(steward: steward) } ?? []
        let row = Mapping.steward(
            summary, pendingApprovals: approvals.filter { $0.steward == steward }.count,
            lastRun: runs.first?.id)
        return Mapping.detail(
            row, outcome: summary.outcome, charter: charter.flatMap(CharterDigest.init(json:)))
    }

    func metrics(steward: String, metric: String?) async throws(CLIError) -> [MetricSeries] {
        let workspace = try await open()
        let summary = try await call("metrics") { try await workspace.metrics(steward: steward) }
        return Mapping.series(summary).filter { metric == nil || $0.metric == metric }
    }

    func propose(steward: String, charterPath: String) async throws(CLIError) -> ProposalRow {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: charterPath))
        } catch {
            throw .notFound("charter file \(charterPath)")
        }
        let workspace = try await open()
        guard let live = try await call("steward", { try await workspace.steward(steward) }) else {
            throw .notFound("steward \(steward)")
        }
        let summary = try await call("proposeCharter", rejection: { .invalidInput($0) }) {
            try await workspace.proposeCharter(
                steward: steward, charter: data, baseVersion: live.charterVersion)
        }
        // Rehearse and gate it on the steward's newest casebook, as the command promises; a
        // steward without a casebook keeps the proposal open.
        let gated = try await call("checkProposal") {
            do {
                return try await workspace.checkProposal(summary.id)
            } catch WorkspaceError.notFound {
                return summary
            }
        }
        return Mapping.proposal(gated)
    }

    func listProposals(steward: String?) async throws(CLIError) -> [ProposalRow] {
        let workspace = try await open()
        let ids: [String]
        if let steward {
            ids = [steward]
        } else {
            ids = try await call("stewards") { try await workspace.stewards() }.map(\.id)
        }
        var rows: [ProposalRow] = []
        for id in ids {
            rows += try await call("proposals") { try await workspace.proposals(steward: id) }
                .map(Mapping.proposal)
        }
        return rows
    }

    func memory(steward: String, scope: MemoryScope) async throws(CLIError) -> [MemoryRow] {
        let workspace = try await open()
        let notes = try await call("memory") {
            try await workspace.memory(steward: steward, includeRetracted: scope == .all)
        }
        return notes.map {
            MemoryRow(
                id: $0.id, text: $0.text, tags: $0.tags, author: $0.author, run: $0.run,
                retracted: $0.retracted)
        }
    }

    func readiness(proposal: String) async throws(CLIError) -> ReadinessReport {
        let workspace = try await open()
        let summary = try await call("liveReadiness", rejection: { .invalidInput($0) }) {
            try await workspace.liveReadiness(proposal: proposal)
        }
        return ReadinessReport(
            proposal: summary.proposal, steward: summary.steward, ready: summary.ready,
            summary: summary.summary, regressions: summary.regressions,
            improved: summary.improved, runsChecked: summary.runsChecked)
    }

    func correctRun(_ run: String, choice: String, note: String?) async throws(CLIError)
        -> CorrectionReport
    {
        let workspace = try await open()
        let expected = try await call("expected") {
            try await workspace.expected(run: run, choice: choice)
        }
        let summary = try await call("correct", rejection: { .invalidInput($0) }) {
            try await workspace.correct(run: run, expected: expected, note: note)
        }
        return CorrectionReport(
            steward: summary.steward, case: summary.caseID, choice: choice, note: note,
            memory: summary.note)
    }

    func retract(memory id: String, reason: String?) async throws(CLIError) -> MemoryRow {
        let workspace = try await open()
        let note = try await call("retract") {
            try await workspace.retract(memory: id, reason: reason)
        }
        return MemoryRow(
            id: note.id, text: note.text, tags: note.tags, author: note.author, run: note.run,
            retracted: note.retracted)
    }

    func routines(steward: String) async throws(CLIError) -> [RoutineRow] {
        let workspace = try await open()
        let rows = try await call("routines") { try await workspace.routines(steward: steward) }
        return rows.map {
            RoutineRow(
                name: $0.name, language: $0.language, liveVersion: $0.liveVersion,
                versions: $0.versions)
        }
    }

    func replay(run: String) async throws(CLIError) -> ReplayReport {
        let workspace = try await open()
        let summary = try await call("replay") { try await workspace.replay(run: run) }
        return Mapping.replay(summary)
    }
    func serveBindingProxy(steward: String, run: String, binding: String, recorded: String?)
        async throws(CLIError)
    {
        throw missing("bindingProxy")
    }

    func serve(every: Int) async throws(CLIError) {
        try await serve(every: every, demoPace: false)
    }

    /// Fires triggers (and, with `demoPace`, paced demo runs) until the process is stopped.
    func serve(every: Int, demoPace: Bool) async throws(CLIError) {
        let workspace = try await open()
        let started = try await call("serve") {
            try await workspace.startServing(every: .seconds(every), demoPace: demoPace)
        }
        guard started else { throw .failed("another process already serves \(home.path)") }
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    func installLoginItem(every: Int) async throws(CLIError) -> LoginItemReport {
        let binary =
            Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        let agent = LaunchAgent(binary: binary, home: home.path, every: every)
        return try LoginItems.user().install(agent)
    }

    func uninstallLoginItem() async throws(CLIError) -> LoginItemReport {
        try LoginItems.user().uninstall()
    }
}

extension WorkspaceBackend {
    func importHistory(
        steward: String, file: String?, binding: String?, tool: String?, limit: Int
    ) async throws(CLIError) -> HistoryImportSummary {
        let workspace = try await open()
        if let file {
            let url = URL(fileURLWithPath: file)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw .notFound("history file \(file)")
            }
            return try await call("importHistory", rejection: { .invalidInput($0) }) {
                try await workspace.importHistory(
                    steward: steward, data: data, source: url.lastPathComponent,
                    binding: binding, limit: limit)
            }
        }
        return try await call("importHistory", rejection: { .invalidInput($0) }) {
            try await workspace.importHistory(
                steward: steward, binding: binding ?? "", tool: tool ?? "history", limit: limit)
        }
    }

    func reviewQueue(steward: String) async throws(CLIError) -> ReviewQueueSummary? {
        let workspace = try await open()
        return try await call("reviewQueue") { try await workspace.reviewQueue(steward: steward) }
    }

    func reviewCase(steward: String, case caseID: String, verdict: String) async throws(CLIError)
        -> ReviewQueueSummary?
    {
        let workspace = try await open()
        return try await call("reviewCase", rejection: { .invalidInput($0) }) {
            try await workspace.reviewCase(steward: steward, case: caseID, verdict: verdict)
        }
    }
}

extension WorkspaceBackend {
    func message(steward: String, text: String, intent: String, by person: String)
        async throws(CLIError) -> MessageReceipt
    {
        let workspace = try await open()
        return try await call("message", rejection: { .invalidInput($0) }) {
            try await workspace.message(steward: steward, text: text, intent: intent, by: person)
        }
    }

    func reportDigest(steward: String) async throws(CLIError) -> ReportDigest {
        let workspace = try await open()
        return try await call("reportDigest") {
            try await workspace.reportDigest(steward: steward)
        }
    }

    func sendReport(steward: String) async throws(CLIError) -> ReportDigest {
        let workspace = try await open()
        return try await call("sendReport", rejection: { .invalidInput($0) }) {
            try await workspace.sendReport(steward: steward)
        }
    }
}

// Governance (ledger lane): GovernanceCommands.swift.
extension WorkspaceBackend {
    func policy(steward: String) async throws(CLIError) -> PolicySummary {
        let workspace = try await open()
        return try await call("policySummary") {
            try await workspace.policySummary(steward: steward)
        }
    }

    func undoOptions(run: String) async throws(CLIError) -> [UndoOption] {
        let workspace = try await open()
        return try await call("undoOptions") { try await workspace.undoOptions(run: run) }
    }

    func undo(run: String, action: String, reason: String?) async throws(CLIError) -> UndoSummary {
        let workspace = try await open()
        return try await call("undoAction", rejection: { .invalidInput($0) }) {
            try await workspace.undoAction(run: run, action: action, reason: reason)
        }
    }

    func retention(steward: String?, days: Int?, clear: Bool) async throws(CLIError)
        -> RetentionSummary
    {
        let workspace = try await open()
        guard days != nil || clear else {
            return try await call("retention") { try await workspace.retention() }
        }
        return try await call("setRetention", rejection: { .invalidInput($0) }) {
            try await workspace.setRetention(steward: steward, days: clear ? nil : days)
        }
    }

    func applyRetention() async throws(CLIError) -> RetentionSummary {
        let workspace = try await open()
        return try await call("applyRetention") { try await workspace.applyRetention() }
    }

    func encryption(enable: Bool, reseal: Bool) async throws(CLIError) -> EncryptionSummary {
        let workspace = try await open()
        return try await call("encryption", rejection: { .invalidInput($0) }) {
            if enable { _ = try await workspace.enableEncryption() }
            if reseal { return try await workspace.resealHistory() }
            return try await workspace.encryption()
        }
    }

    func exportSigned(steward: String, to directory: String, reveal: Bool)
        async throws(CLIError) -> AuditExportSummary
    {
        let workspace = try await open()
        return try await call("exportAudit", rejection: { .invalidInput($0) }) {
            try await workspace.exportAudit(
                steward: steward, to: URL(fileURLWithPath: directory, isDirectory: true),
                reveal: reveal)
        }
    }

    func verifyExport(_ directory: String) async throws(CLIError) -> AuditExportSummary {
        guard
            let summary = Workspace.verifyAudit(
                at: URL(fileURLWithPath: directory, isDirectory: true))
        else { throw .invalidInput("\(directory) holds no readable manifest.json") }
        return summary
    }

    func importExport(_ directory: String) async throws(CLIError) -> AuditImportSummary {
        let workspace = try await open()
        return try await call("importAudit", rejection: { .invalidInput($0) }) {
            try await workspace.importAudit(
                from: URL(fileURLWithPath: directory, isDirectory: true))
        }
    }
}
