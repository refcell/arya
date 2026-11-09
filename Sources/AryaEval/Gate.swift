import AryaCore

/// Decides whether a proposal may go live. Conforms to `AryaCore.GateChecking`, which the
/// runtime calls and the facade wires to an eval gate. `AryaCore.RefusingGate` is the safe
/// default until one is wired.
public protocol Gate: GateChecking {}
