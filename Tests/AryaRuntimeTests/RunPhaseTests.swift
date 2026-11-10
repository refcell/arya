import Testing

@testable import AryaRuntime

@Test func happyPathReachesFinished() throws {
    var phase = RunPhase.started
    for input: RunPhaseInput in [
        .adapterStarted, .adapterEvent, .adapterEvent, .resultReceived(.completed),
        .dispositionsRecorded,
    ] {
        phase = try phase.applying(input)
    }
    #expect(phase == .finished(.completed))
    #expect(phase.isTerminal)
}

@Test func stoppedResultFinishesStopped() throws {
    let phase = try RunPhase.started.applying(.adapterStarted)
        .applying(.resultReceived(.stopped)).applying(.dispositionsRecorded)
    #expect(phase == .finished(.stopped))
}

@Test(arguments: RunFailureReason.allCases)
func anyLivePhaseCanFail(_ reason: RunFailureReason) throws {
    let live: [RunPhase] = [.started, .running, .disposing(.completed)]
    for phase in live {
        #expect(try phase.applying(.fail(reason)) == .failed(reason))
    }
}

@Test func terminalPhasesRejectInputs() {
    let terminal: [RunPhase] = [.finished(.completed), .failed(.timeout)]
    let inputs: [RunPhaseInput] = [
        .adapterStarted, .adapterEvent, .resultReceived(.completed), .dispositionsRecorded,
        .fail(.interrupted),
    ]
    for phase in terminal {
        for input in inputs {
            #expect(throws: RunTransitionError(from: phase, input: input)) {
                try phase.applying(input)
            }
        }
    }
}

@Test func outOfOrderInputsAreRejected() {
    #expect(throws: RunTransitionError.self) { try RunPhase.started.applying(.adapterEvent) }
    #expect(throws: RunTransitionError.self) {
        try RunPhase.started.applying(.resultReceived(.completed))
    }
    #expect(throws: RunTransitionError.self) {
        try RunPhase.running.applying(.dispositionsRecorded)
    }
    #expect(throws: RunTransitionError.self) {
        try RunPhase.disposing(.completed).applying(.adapterEvent)
    }
}

@Test func failureReasonsUseLedgerSpelling() {
    #expect(
        RunFailureReason.allCases.map(\.rawValue) == [
            "adapter_exited", "timeout", "invalid_result", "budget", "interrupted",
            "adapter_failed", "aborted",
        ])
}
