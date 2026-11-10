import AryaCore
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation

// Governance read models and checks (governance lane): who may approve what, and one policy
// summary per steward of the tools and actions its charter allows.

/// A steward's policy in one read: per binding, the tools a run may read and each action
/// kind with its disposition, risk, and approvers.
public struct PolicySummary: Sendable, Hashable, Codable {
    /// One action kind a binding allows.
    public struct Action: Sendable, Hashable, Codable {
        public var kind: String
        /// `auto`, `ask`, or `deny`, after rules and autonomy.
        public var decision: String
        /// The verdict's reason, for example `rule:reply` or `autonomy:act_low:medium`.
        public var reason: String
        /// `low`, `medium`, or `high`.
        public var risk: String
        /// Who may grant it when held; nil when anyone may.
        public var approvers: [String]?
        /// The approver rule's note.
        public var approverNote: String?
    }

    /// One binding and what it lets a run do.
    public struct Binding: Sendable, Hashable, Codable {
        public var id: String
        /// `mcp` or `person`.
        public var kind: String
        /// Tools a run may call (the tool allowlist).
        public var tools: [String]
        /// The binding server may use the network when sandboxed.
        public var network: Bool
        /// For people: the relay binding, nil for the local inbox.
        public var via: String?
        public var actions: [Action]
    }

    /// One `policy.approvers` rule.
    public struct ApproverLine: Sendable, Hashable, Codable {
        public var action: String
        public var binding: String?
        public var people: [String]
        public var note: String?
    }

    public var steward: String
    /// The autonomy level, nil when the policy alone decides.
    public var autonomy: String?
    /// The disposition for kinds no rule names.
    public var fallback: String
    public var bindings: [Binding]
    public var approvers: [ApproverLine]
}

extension PolicySummary {
    /// The summary of a charter's policy.
    init(_ charter: Charter) {
        let policy = ActionPolicy(charter: charter)
        steward = charter.id.rawValue
        autonomy = charter.autonomy?.rawValue
        fallback = charter.policy.default.rawValue
        approvers = charter.policy.approvers.map {
            ApproverLine(action: $0.action, binding: $0.binding, people: $0.people, note: $0.note)
        }
        bindings = charter.bindings.map { binding in
            let actions = binding.actions.map { kind in
                let verdict = policy.classify(PolicyAction(kind: kind, binding: binding.id))
                let rule = charter.policy.approverRule(forAction: kind, binding: binding.id)
                return Action(
                    kind: kind, decision: verdict.disposition.rawValue, reason: verdict.reason,
                    risk: policy.risk(of: PolicyAction(kind: kind, binding: binding.id)).rawValue,
                    approvers: rule?.people, approverNote: rule?.note)
            }
            return Binding(
                id: binding.id, kind: binding.kind.rawValue, tools: binding.read,
                network: binding.network, via: binding.via, actions: actions)
        }
    }
}

extension Workspace {
    /// The steward's policy summary from its live charter.
    public func policySummary(steward: String) async throws -> PolicySummary {
        PolicySummary(try await existing(steward).charter)
    }

    /// Records `approval.refused` and throws when `person` may not grant a pending action
    /// approval under the live charter's `policy.approvers`. Anything else (questions, decided
    /// or unknown approvals) is left to the grant itself.
    func checkApprover(_ id: String, person: String) async throws {
        let approval = ApprovalID(unchecked: id)
        guard let record = try await approvalQueue.book().records[approval],
            record.status == .pending, case .action(let action) = record.subject
        else { return }
        let charter = try await existing(record.steward.rawValue).charter
        guard case .refused(let rule) = charter.policy.authority(of: person, for: action) else {
            return
        }
        let name = rule.binding.map { "\(rule.action)@\($0)" } ?? rule.action
        let payload = ApprovalRefused(
            approval: approval, by: person, people: rule.people, rule: name, note: rule.note)
        _ = try await sink.append(
            RuntimeEventDraft(
                type: ApprovalRefused.type.rawValue, steward: record.steward, run: record.run,
                actor: .person(person),
                payload: try CanonicalJSON.decode(
                    JSONValue.self, from: try CanonicalJSON.encode(payload))))
        let who = rule.people.joined(separator: " or ")
        let why = rule.note.map { " (\($0))" } ?? ""
        throw WorkspaceError.rejected(
            "\(person) may not approve \(action.kind) actions; only \(who) may\(why)")
    }
}

extension Workspace {
    /// Asks arya to stop a running run on behalf of `person` (`run.abort.requested`). The
    /// process running it stops the adapter and executes nothing the run proposes; the run
    /// ends `stopped` (or fails `aborted`). When no live process holds the run, it is failed
    /// `aborted` here. Returns the run as the ledger now says; a run that was already handed
    /// to its process may still be running, so read it again for the end.
    public func abortRun(_ id: String, reason: String? = nil, as person: String = "local")
        async throws -> RunSummary
    {
        let run = RunID(unchecked: id)
        guard let record = try await runBook().records[run] else {
            throw WorkspaceError.notFound(id)
        }
        guard record.status == .running else {
            throw WorkspaceError.rejected("\(id) is already \(record.status.rawValue)")
        }
        let text = reason.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: RunAbortRequested.type.rawValue, steward: record.steward, run: run,
                actor: .person(person), payload: try Self.json(RunAbortRequested(reason: text))))
        if !leases.isHeld(run) {
            let failed = RunFailed(reason: "aborted", detail: "no process was running it")
            _ = try await sink.append(
                RuntimeEventDraft(
                    type: RunFailed.type.rawValue, steward: record.steward, run: run,
                    actor: .system, payload: try Self.json(failed)))
        }
        guard let now = try await runBook().records[run] else { throw WorkspaceError.notFound(id) }
        return RunSummary(now)
    }

    static func json(_ payload: some Encodable) throws -> JSONValue {
        try CanonicalJSON.decode(JSONValue.self, from: try CanonicalJSON.encode(payload))
    }
}

/// An executed action the charter's `policy.undo` says how to undo.
public struct UndoOption: Sendable, Hashable, Codable {
    public var run: String
    /// The executed action's id within the run.
    public var action: String
    public var kind: String
    public var binding: String?
    public var target: String?
    /// The compensating action kind.
    public var with: String
    /// The undo rule's note.
    public var note: String?
    /// The compensation already requested for it, if any (then it cannot be undone again).
    public var undoneBy: String?
}

/// What happened to a requested undo.
public struct UndoSummary: Sendable, Hashable, Codable {
    public var option: UndoOption
    /// The compensating action's disposition: `auto`, `ask`, or `deny`.
    public var decision: String
    /// The policy verdict's reason.
    public var reason: String
    /// The approval it waits on, for `ask`.
    public var approval: String?
    /// True when the compensation executed successfully.
    public var executed: Bool
}

extension Workspace {
    /// The run's executed actions that the live charter can undo, in execution order.
    public func undoOptions(run: String) async throws -> [UndoOption] {
        try await undoState(run).2
    }

    /// Undoes an executed action on behalf of `person`: records `action.undo.requested`, then
    /// proposes the compensating action (`undo:<id>`, same binding and target) through policy,
    /// so it runs, waits for approval, or is refused like any other action. Its params are
    /// `{undoes, params, previous}`: the action's id and params, and the params of the last
    /// action of the same kind and target executed before it (null when none).
    public func undoAction(
        run: String, action: String, reason: String? = nil, as person: String = "local"
    ) async throws -> UndoSummary {
        let (record, charter, options) = try await undoState(run)
        guard var option = options.first(where: { $0.action == action }) else {
            throw WorkspaceError.rejected("\(action) in \(run) is not an executed, undoable action")
        }
        if let done = option.undoneBy {
            throw WorkspaceError.rejected("\(action) in \(run) is already undone by \(done)")
        }
        let original = try await executedAction(record, action)
        let compensation = ProposedAction(
            id: "undo:\(action)", kind: option.with, binding: original.action.binding,
            target: original.action.target,
            params: [
                "undoes": .string(action), "params": original.action.params ?? .null,
                "previous": original.previous ?? .null,
            ],
            rationale: reason, why: "Undo \(original.action.kind) \(action)")
        let text = reason.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: ActionUndoRequested.type.rawValue, steward: record.steward, run: record.id,
                actor: .person(person),
                payload: try Self.json(
                    ActionUndoRequested(
                        action: action, compensation: compensation.id, reason: text))))
        let disposal = try await dispatcher.dispose(
            [compensation], charter: charter, run: record.id)
        option.undoneBy = compensation.id
        let executed: Bool =
            if case .succeeded? = disposal.first?.outcome { true } else { false }
        return UndoSummary(
            option: option, decision: disposal.first?.verdict.disposition.rawValue ?? "deny",
            reason: disposal.first?.verdict.reason ?? "",
            approval: disposal.first?.approval?.rawValue,
            executed: executed)
    }

    private func undoState(_ run: String) async throws -> (RunRecord, Charter, [UndoOption]) {
        guard let record = try await runBook().records[RunID(unchecked: run)] else {
            throw WorkspaceError.notFound(run)
        }
        let charter = try await existing(record.steward.rawValue).charter
        var proposed: [String: ProposedAction] = [:]
        var executed: [String] = []
        var undone: [String: String] = [:]
        for event in try reader.events(LedgerFilter(run: record.id)) {
            switch event.type {
            case .actionProposed:
                let action = try event.payload(as: ActionProposed.self).action
                proposed[action.id] = action
            case .actionExecuted: executed.append(try event.payload(as: ActionExecuted.self).action)
            case .actionUndoRequested:
                let body = try event.payload(as: ActionUndoRequested.self)
                undone[body.action] = body.compensation
            default: break
            }
        }
        let options = executed.compactMap { id -> UndoOption? in
            guard let action = proposed[id],
                let rule = charter.policy.undoRule(forAction: action.kind, binding: action.binding)
            else { return nil }
            return UndoOption(
                run: run, action: id, kind: action.kind, binding: action.binding,
                target: action.target, with: rule.with, note: rule.note, undoneBy: undone[id])
        }
        return (record, charter, options)
    }

    /// The executed action and the params of the last action of its kind and target that the
    /// steward executed before it.
    private func executedAction(_ record: RunRecord, _ id: String) async throws
        -> (action: ProposedAction, previous: JSONValue?)
    {
        let filter = LedgerFilter(
            steward: record.steward, types: [.actionProposed, .actionExecuted])
        var proposed: [String: ProposedAction] = [:]
        var history: [ProposedAction] = []
        for event in try reader.events(filter) {
            guard let run = event.run?.rawValue else { continue }
            if event.type == .actionProposed {
                let action = try event.payload(as: ActionProposed.self).action
                proposed["\(run):\(action.id)"] = action
                continue
            }
            let executedID = try event.payload(as: ActionExecuted.self).action
            guard let action = proposed["\(run):\(executedID)"] else { continue }
            if run == record.id.rawValue, executedID == id {
                let previous = history.last {
                    $0.kind == action.kind && $0.target == action.target
                }
                return (action, previous?.params)
            }
            history.append(action)
        }
        throw WorkspaceError.notFound(id)
    }
}

/// Retention settings and what they would move to `archive/` now.
public struct RetentionSummary: Sendable, Hashable, Codable {
    /// One steward's own setting.
    public struct Steward: Sendable, Hashable, Codable {
        public var steward: String
        public var days: Int
    }

    /// Days for history with no steward and stewards without their own setting.
    public var defaultDays: Int?
    public var stewards: [Steward]
    /// Closed segments eligible now, oldest first.
    public var segments: [String]
    /// The last eligible `seq` (0 when none).
    public var through: Int
    /// Eligible events by steward id (`""` for home-level events).
    public var events: [String: Int]
    public var bytes: Int
    /// Why eligible history is not archived yet, if it is not; nil when archiving can run.
    public var blocker: String?
    /// Segments already in `archive/`, and the last retention run's `seq` range.
    public var archived: Int = 0
    public var lastApplied: Int?
}

extension Workspace {
    /// The retention settings and the current plan.
    public func retention() async throws -> RetentionSummary {
        let policy = try RetentionPolicy.read(reader)
        let plan = try RetentionPlan.compute(reader, policy: policy, now: ambient.now())
        return RetentionSummary(
            defaultDays: policy.defaultDays,
            stewards: policy.stewards.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                policy.stewards[id].map { RetentionSummary.Steward(steward: id.rawValue, days: $0) }
            },
            segments: plan.segments, through: Int(plan.through), events: plan.events,
            bytes: Int(plan.bytes), blocker: nil, archived: try Self.archivedSegments(home),
            lastApplied: try reader.newest(
                LedgerFilter(types: [.systemRetentionApplied]), limit: 1
            ).first.map { Int((try $0.payload(as: SystemRetentionApplied.self)).through) })
    }

    static func archivedSegments(_ home: URL) throws -> Int {
        let archive = home.appendingPathComponent("archive", isDirectory: true)
        guard FileManager.default.fileExists(atPath: archive.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: archive.path)
            .filter { $0.hasSuffix(".jsonl") }.count
    }

    /// Archives what retention covers now: a checkpoint at the head, the eligible closed
    /// segments moved to `archive/` (never deleted; history reads still see them), and
    /// `system.retention.applied` (actor: the person). A no-op when nothing is eligible.
    public func applyRetention(as person: String = "local") async throws -> RetentionSummary {
        let signer = try CheckpointKeys(home: home).ensure(store: sink.store)
        do {
            try RetentionArchive.apply(
                store: sink.store, signer: signer, now: ambient.now(), actor: .human(person))
        } catch let error as CompactionError {
            throw WorkspaceError.rejected("retention could not archive: \(error)")
        }
        return try await retention()
    }

    /// Records how many days of history to keep for `steward` (the home default when nil);
    /// nil `days` clears the setting (`system.retention.set`, actor: the person).
    public func setRetention(steward: String? = nil, days: Int?, as person: String = "local")
        async throws -> RetentionSummary
    {
        if let days, days < 1 { throw WorkspaceError.rejected("days must be at least 1") }
        var id: StewardID?
        if let steward { id = try await existing(steward).id }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: SystemRetentionSet.type.rawValue, steward: id, actor: .person(person),
                payload: try Self.json(SystemRetentionSet(steward: id, days: days))))
        return try await retention()
    }
}

// MARK: Encryption at rest (G4)

/// Whether the home is encrypted, and how much of it is still in the clear.
public struct EncryptionSummary: Sendable, Hashable, Codable {
    /// Whether new events, blobs, and caches are sealed.
    public var enabled: Bool
    /// The key id (`hk_…`), never the key.
    public var key: String?
    public var algorithm: String?
    /// Whether this process can read the key.
    public var keyAvailable: Bool
    /// The `seq` of `system.encryption.enabled`; events after it are sealed.
    public var since: Int?
    /// Events before `since` (or all when off) whose payload is in the clear, `system.*`
    /// excluded: the hash chain covers their bytes, so they stay as written.
    public var clearEvents: Int
    public var sealedBlobs: Int
    public var clearBlobs: Int
}

extension Workspace {
    /// The home's encryption state.
    public func encryption() async throws -> EncryptionSummary {
        let config = try HomeEncryption.config(home)
        var since: Int64?
        if config != nil {
            since = try reader.newest(
                LedgerFilter(types: [SystemEncryptionEnabled.type]), before: nil, limit: 1
            ).last?.seq
        }
        var clear = 0
        try reader.forEachEnvelope { event in
            if let since, event.seq > since { return }
            if SealedPayload.applies(to: event.type), !SealedPayload.isSealed(event) { clear += 1 }
        }
        let blobs = BlobStore(home: home)
        var sealed = 0
        var plain = 0
        for hex in try blobs.keys() {
            guard let data = FileManager.default.contents(atPath: blobs.path(hex).path) else {
                continue
            }
            if HomeEncryption.isSealedFile(data) { sealed += 1 } else { plain += 1 }
        }
        var available = false
        if let key = config?.key { available = (try? keys.key(key)) != nil }
        return EncryptionSummary(
            enabled: config != nil, key: config?.key, algorithm: config?.algorithm,
            keyAvailable: available, since: since.map(Int.init), clearEvents: clear,
            sealedBlobs: sealed, clearBlobs: plain)
    }

    /// Turns encryption on with a new key kept in this workspace's key store (the Keychain
    /// in the app and CLI), records `system.encryption.enabled` (actor: the person), and seals
    /// existing blobs and seeds. Enabling an encrypted home changes nothing.
    public func enableEncryption(as person: String = "local") async throws -> EncryptionSummary {
        try HomeEncryption.enable(store: sink.store, keys: keys, actor: .human(person))
        return try await encryption()
    }
}

// MARK: Signed audit export (G5)

/// A written audit export: where, what it holds, and whether it checks.
public struct AuditExportSummary: Sendable, Hashable, Codable {
    public var directory: String
    public var steward: String?
    public var count: Int
    /// Lines whose payload is sealed, and whether they were opened into `payloads.jsonl`.
    public var sealed: Int
    public var revealed: Bool
    /// The checkpoint key that signed the manifest.
    public var key: String
    public var head: Int
    /// Problems `verifyAudit` found; empty when the bundle checks.
    public var issues: [String]

    public var verified: Bool { issues.isEmpty }

    init(directory: URL, manifest: AuditManifest, revealed: Bool, issues: [String]) {
        self.directory = directory.path
        steward = manifest.steward
        count = manifest.count
        sealed = manifest.sealed
        self.revealed = revealed
        key = manifest.key
        head = Int(manifest.head)
        self.issues = issues
    }
}

extension Workspace {
    /// Exports `steward`'s ledger slice (the whole ledger when nil) into the new folder
    /// `directory`: its lines as written, the key events, opened payloads when `reveal`, and a
    /// manifest signed with the home's checkpoint key. Records `system.audit.exported`
    /// (actor: the person) and checks the bundle before returning.
    public func exportAudit(
        steward: String?, to directory: URL, reveal: Bool = false, as person: String = "local"
    ) async throws -> AuditExportSummary {
        var id: StewardID?
        if let steward { id = try await existing(steward).id }
        let manifest: AuditManifest
        do {
            let signer = try CheckpointKeys(home: home).ensure(store: sink.store)
            manifest = try AuditExport.write(
                home: home, steward: id, to: directory, signer: signer, reveal: reveal)
        } catch let error as AuditExportError {
            throw WorkspaceError.rejected(error.description)
        }
        let digest = LedgerLine.hexSHA256(try CanonicalJSON.encode(manifest))
        _ = try await sink.append(
            RuntimeEventDraft(
                type: SystemAuditExported.type.rawValue, steward: id, actor: .person(person),
                payload: try Self.json(
                    SystemAuditExported(
                        steward: id, count: manifest.count, head: manifest.head,
                        manifest: digest, revealed: manifest.payloads != nil))))
        let check = AuditExport.verify(directory)
        return AuditExportSummary(
            directory: directory, manifest: manifest, revealed: manifest.payloads != nil,
            issues: check.issues)
    }

    /// Checks an audit export folder on its own; nil when it holds no readable manifest.
    public nonisolated static func verifyAudit(at directory: URL) -> AuditExportSummary? {
        let check = AuditExport.verify(directory)
        guard let manifest = check.manifest else { return nil }
        return AuditExportSummary(
            directory: directory, manifest: manifest, revealed: manifest.payloads != nil,
            issues: check.issues)
    }
}

// MARK: Import a steward from an audit export (14)

/// A steward recreated from an audit export.
public struct AuditImportSummary: Sendable, Hashable, Codable {
    public var steward: String
    public var name: String
    /// Events in the export, memory notes carried over, and the signer and head it names.
    public var events: Int
    public var notes: Int
    public var key: String
    public var head: Int
}

extension Workspace {
    /// Recreates a steward from an audit export after checking it (`verifyAudit`): its latest
    /// charter becomes version 1 here and its live memory notes are re-recorded, then
    /// `system.audit.imported` names the export (actor: the person). Its runs stay in the
    /// export; this home starts the steward's own history. Refused when the bundle does not
    /// check, its charter is sealed and was not revealed, or the steward already exists.
    public func importAudit(from directory: URL, as person: String = "local") async throws
        -> AuditImportSummary
    {
        let check = AuditExport.verify(directory)
        guard let manifest = check.manifest, check.issues.isEmpty else {
            let reason = check.issues.first ?? "it has no manifest"
            throw WorkspaceError.rejected("the export does not check: \(reason)")
        }
        guard let stewardID = manifest.steward.flatMap(StewardID.init(rawValue:)) else {
            throw WorkspaceError.rejected("only a one-steward export can be imported")
        }
        let events = try AuditExport.events(at: directory)
        let charterTypes: Set<EventType> = [.stewardCreated, .stewardCharterUpdated]
        guard let latest = events.last(where: { charterTypes.contains($0.type) }) else {
            throw WorkspaceError.rejected("the export holds no charter for \(stewardID.rawValue)")
        }
        guard !SealedPayload.isSealed(latest), let body = latest.payload.objectValue?["charter"]
        else {
            throw WorkspaceError.rejected("the export's charter is sealed; export it revealed")
        }
        let charter: Charter
        do {
            charter = try Charter.load(from: try CanonicalJSON.encode(body))
        } catch let error as CharterError {
            throw WorkspaceError.rejected(Self.describe(error))
        }
        let created = try await mapped { try await lifecycle.create(charter) }
        let notes = try MemoryProjection(ledger: events.filter { !SealedPayload.isSealed($0) })
            .allNotes(steward: stewardID).filter { !$0.retracted }.map(\.note.note)
        for note in notes {
            _ = try await sink.append(
                RuntimeEventDraft(
                    type: MemoryEventType.added, steward: stewardID, actor: .person(person),
                    payload: try Self.json(MemoryAddedPayload(note: note))))
        }
        let digest = LedgerLine.hexSHA256(try CanonicalJSON.encode(manifest))
        _ = try await sink.append(
            RuntimeEventDraft(
                type: SystemAuditImported.type.rawValue, steward: stewardID,
                actor: .person(person),
                payload: try Self.json(
                    SystemAuditImported(
                        steward: stewardID, count: manifest.count, head: manifest.head,
                        manifest: digest, key: manifest.key, notes: notes.count))))
        return AuditImportSummary(
            steward: stewardID.rawValue, name: created.charter.name, events: manifest.count,
            notes: notes.count, key: manifest.key, head: Int(manifest.head))
    }
}
