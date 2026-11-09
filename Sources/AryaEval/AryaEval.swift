import AryaCore

/// Namespace for the `AryaEval` module: deterministic replay, rehearsal on casebooks, scorers,
/// proposals and gates, and outcome metric series.
public enum AryaEval {
    /// The module name, used by the smoke test.
    public static let name = "AryaEval"
}

/// Errors raised by the eval module.
public enum EvalError: Error, Equatable, Sendable {
    /// The named capability has an interface but no implementation yet.
    case notImplemented(String)
    /// A charter's rubric names a check kind eval does not implement.
    case unknownRubricCheck(String)
    /// The case is not in the casebook.
    case unknownCase(CaseID)
    /// No casebook with this version was imported.
    case unknownCasebook(String)
    /// A stored casebook's content does not hash to its version.
    case casebookMismatch(expected: String, actual: String)
    /// No `run.started` for this run.
    case unknownRun(RunID)
    /// A rehearsal run's rehearsal is not on the ledger, or no casebook source was given.
    case unknownRehearsal(RehearsalID)
    /// A judge's reply was not a valid verdict, or the judge gave none.
    case badVerdict(String)
}
