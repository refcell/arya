import AryaCore
import Foundation
import Testing

@testable import AryaMemory

func routineEvent(
    seq: Int, steward: StewardID = "st_triage", type: String,
    _ payload: some Encodable
) throws -> MemoryEventRecord {
    MemoryEventRecord(
        seq: seq, id: EventID(unchecked: "ev_\(seq)"), steward: steward, type: type,
        payload: try JSONEncoder().encode(payload))
}

let labelV1 = "#!/bin/sh\n# Label new issues by keyword.\ngrep -qi login \"$1\" && echo auth\n"
let labelV2 =
    "#!/bin/sh\n# Label new issues by keyword.\ngrep -qi -e login -e sso \"$1\" "
    + "&& echo auth\n"

@Suite struct RoutineSourceTests {
    @Test func versionIsTheContentHash() throws {
        let source = try RoutineSource(name: "label-issue", language: "sh", content: labelV1)
        #expect(source.version == RoutineNaming.version(of: Data(labelV1.utf8)))
        #expect(RoutineNaming.isValid(version: source.version))
        #expect(
            RoutineNaming.version(of: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func validatesNameLanguageAndContent() {
        #expect(throws: RoutineError.invalidName("Label")) {
            try RoutineSource(name: "Label", language: "sh", content: "echo")
        }
        #expect(throws: RoutineError.invalidName("-x")) {
            try RoutineSource(name: "-x", language: "sh", content: "echo")
        }
        #expect(throws: RoutineError.unknownLanguage("py")) {
            try RoutineSource(name: "x", language: "py", content: "print()")
        }
        #expect(throws: RoutineError.emptyContent) {
            try RoutineSource(name: "x", language: "sh", content: " \n")
        }
        #expect(RoutineNaming.isValid(name: "a.b_c-1"))
        #expect(!RoutineNaming.isValid(name: String(repeating: "a", count: 65)))
    }

    @Test func summaryPrefersReasonThenComment() throws {
        let source = try RoutineSource(name: "label-issue", language: .sh, content: labelV1)
        #expect(source.summary(reason: "Faster labeling.\nMore.") == "Faster labeling.")
        #expect(source.summary(reason: nil) == "Label new issues by keyword.")
        let bare = try RoutineSource(name: "bare", language: .sh, content: "echo hi\n")
        #expect(bare.summary(reason: "  ") == "bare")
    }

    @Test func proposedPayloadMatchesGolden() throws {
        let store = InMemoryRoutineBlobStore()
        let source = try RoutineSource(name: "label-issue", language: .sh, content: labelV1)
        let payload = try source.propose(into: store, reason: "Repeated in 5 runs.", run: "run_1")
        #expect(try encodeJSON(payload) == (try fixture("routine.proposed.json")))
        #expect(try store.getIfPresent(source.version) == source.data)
        let promoted = RoutinePromotedPayload(
            name: "label-issue", version: source.version, proposal: ProposalID(body: "1"))
        #expect(try encodeJSON(promoted) == (try fixture("routine.promoted.json")))
        let retired = RoutineRetiredPayload(
            name: "label-issue", version: source.version, reason: "Replaced by a binding.")
        #expect(try encodeJSON(retired) == (try fixture("routine.retired.json")))
    }
}

@Suite struct RoutineLibraryTests {
    func sources() throws -> (RoutineSource, RoutineSource) {
        (
            try RoutineSource(name: "label-issue", language: .sh, content: labelV1),
            try RoutineSource(name: "label-issue", language: .sh, content: labelV2)
        )
    }

    @Test func liveVersionFollowsPromotionsAndRetirement() throws {
        let (v1, v2) = try sources()
        let p = RoutineEventType.self
        var library = try RoutineLibrary(events: [
            routineEvent(seq: 1, type: p.proposed, RoutineProposedPayload(source: v1)),
            routineEvent(
                seq: 2, type: p.promoted,
                RoutinePromotedPayload(name: v1.name, version: v1.version)),
            routineEvent(seq: 3, type: p.proposed, RoutineProposedPayload(source: v2)),
        ])
        #expect(library.live(steward: "st_triage", name: "label-issue")?.version == v1.version)
        #expect(library.pending(steward: "st_triage").map(\.version) == [v2.version])
        try library.apply(
            routineEvent(
                seq: 4, type: p.promoted,
                RoutinePromotedPayload(
                    name: v2.name, version: v2.version,
                    proposal: ProposalID(body: "2"))))
        let live = try #require(library.live(steward: "st_triage", name: "label-issue"))
        #expect(live.version == v2.version)
        #expect(live.proposal == ProposalID(body: "2"))
        #expect(library.versions(steward: "st_triage", name: "label-issue").count == 2)
        try library.apply(
            routineEvent(
                seq: 5, type: p.retired, RoutineRetiredPayload(name: v2.name, version: v2.version)))
        #expect(library.live(steward: "st_triage", name: "label-issue") == nil)
        #expect(
            library.history(steward: "st_triage", name: "label-issue").map(\.kind) == [
                .proposed, .promoted, .proposed, .promoted, .retired,
            ])
        #expect(library.anomalies.isEmpty)
        #expect(library.names(steward: "st_triage") == ["label-issue"])
    }

    @Test func recordsAnomaliesInsteadOfApplyingThem() throws {
        let (v1, v2) = try sources()
        let p = RoutineEventType.self
        let library = try RoutineLibrary(events: [
            routineEvent(
                seq: 1, type: p.promoted,
                RoutinePromotedPayload(name: v1.name, version: v1.version)),
            routineEvent(seq: 2, type: p.proposed, RoutineProposedPayload(source: v1)),
            routineEvent(seq: 3, type: p.proposed, RoutineProposedPayload(source: v1)),
            routineEvent(
                seq: 4, type: p.retired,
                RoutineRetiredPayload(name: v1.name, version: v2.version)),
        ])
        #expect(library.anomalies.map(\.seq) == [1, 3, 4])
        #expect(library.live(steward: "st_triage", name: "label-issue") == nil)
    }

    @Test func stewardsAreIsolatedAndSortedByName() throws {
        let p = RoutineEventType.self
        let a = try RoutineSource(name: "zeta", language: .prompt, content: "Be brief.")
        let b = try RoutineSource(name: "alpha", language: .sh, content: "echo a")
        let library = try RoutineLibrary(events: [
            routineEvent(seq: 1, type: p.proposed, RoutineProposedPayload(source: a)),
            routineEvent(
                seq: 2, type: p.promoted,
                RoutinePromotedPayload(name: a.name, version: a.version)),
            routineEvent(seq: 3, type: p.proposed, RoutineProposedPayload(source: b)),
            routineEvent(
                seq: 4, type: p.promoted,
                RoutinePromotedPayload(name: b.name, version: b.version)),
            routineEvent(
                seq: 5, steward: "st_inbox", type: p.proposed,
                RoutineProposedPayload(source: b)),
        ])
        #expect(library.liveRoutines(steward: "st_triage").map(\.name) == ["alpha", "zeta"])
        #expect(library.liveRoutines(steward: "st_inbox").isEmpty)
    }

    @Test func incrementalEqualsFromScratch() throws {
        let (v1, v2) = try sources()
        let p = RoutineEventType.self
        let events = [
            try routineEvent(seq: 1, type: p.proposed, RoutineProposedPayload(source: v1)),
            try routineEvent(
                seq: 2, type: p.promoted,
                RoutinePromotedPayload(name: v1.name, version: v1.version)),
            try routineEvent(seq: 3, type: p.proposed, RoutineProposedPayload(source: v2)),
        ]
        var incremental = RoutineLibrary()
        for event in events { try incremental.apply(event) }
        #expect(incremental == (try RoutineLibrary(events: events)))
    }

    @Test func loadsAndChecksContent() throws {
        let (v1, _) = try sources()
        let store = InMemoryRoutineBlobStore()
        let payload = try v1.propose(into: store)
        let library = try RoutineLibrary(events: [
            routineEvent(seq: 1, type: RoutineEventType.proposed, payload)
        ])
        let version = try #require(
            library.version(steward: "st_triage", name: v1.name, version: v1.version))
        #expect(try version.content(from: store) == labelV1)
        #expect(throws: RoutineContentError.missingBlob(v1.version)) {
            try version.content(from: InMemoryRoutineBlobStore())
        }
        store.overwrite(v1.version, with: Data("tampered".utf8))
        #expect(throws: RoutineContentError.corruptBlob(v1.version)) {
            try version.content(from: store)
        }
    }
}
