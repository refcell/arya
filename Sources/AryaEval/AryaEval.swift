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
}
