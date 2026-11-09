import AryaCore

/// Compares a run's recorded derived events with the events a replay derived.
///
/// Events are compared by position: type first, then payload, field by field. Object keys are
/// visited in sorted order, so the first divergence reported is deterministic. `seq` is not
/// compared because a replay writes to its own scratch ledger.
public enum DivergenceFinder {
    public static func firstDivergence(
        recorded: [ReplayEvent], replayed: [ReplayEvent]
    ) -> Divergence? {
        for index in 0..<max(recorded.count, replayed.count) {
            let old = index < recorded.count ? recorded[index] : nil
            let new = index < replayed.count ? replayed[index] : nil
            guard let old, let new else {
                return Divergence(index: index, path: "event", recorded: old, replayed: new)
            }
            if old.type != new.type {
                return Divergence(index: index, path: "type", recorded: old, replayed: new)
            }
            if let path = firstDifference(old.payload, new.payload, path: "payload") {
                return Divergence(index: index, path: path, recorded: old, replayed: new)
            }
        }
        return nil
    }

    /// The dotted path of the first difference between two values, or `nil` when equal.
    /// Array elements appear as `[i]`.
    public static func firstDifference(_ a: JSONValue, _ b: JSONValue, path: String) -> String? {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            for key in Set(x.keys).union(y.keys).sorted() {
                guard let left = x[key], let right = y[key] else { return "\(path).\(key)" }
                if let found = firstDifference(left, right, path: "\(path).\(key)") {
                    return found
                }
            }
            return nil
        case (.array(let x), .array(let y)):
            for index in 0..<min(x.count, y.count) {
                if let found = firstDifference(x[index], y[index], path: "\(path)[\(index)]") {
                    return found
                }
            }
            return x.count == y.count ? nil : "\(path)[\(min(x.count, y.count))]"
        default:
            return a == b ? nil : path
        }
    }
}
