/// Why a charter document was refused.
public enum CharterError: Error, Hashable, Sendable {
    /// The JSON does not decode into a charter.
    case malformed(String)
    /// The charter decoded but breaks one or more rules.
    case invalid([CharterIssue])
}

/// One broken charter rule. `path` points at the offending field, for example `bindings[1].id`.
public struct CharterIssue: Hashable, Sendable, Codable, CustomStringConvertible {
    public var path: String
    public var message: String

    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }

    private enum CodingKeys: String, CodingKey { case path, message }
}

extension Charter {
    /// Every rule the charter breaks, in field order. Empty means valid.
    public func validate() -> [CharterIssue] {
        var issues: [CharterIssue] = []
        if v != 1 { issues.append(.init("v", "unsupported version \(v)")) }
        if name.trimmed.isEmpty { issues.append(.init("name", "must not be empty")) }
        if outcome.trimmed.isEmpty { issues.append(.init("outcome", "must not be empty")) }
        if metric.name.trimmed.isEmpty { issues.append(.init("metric.name", "must not be empty")) }
        var names: Set<String> = [metric.name]
        for (i, extra) in (guardrailMetrics ?? []).enumerated() {
            let field = "guardrailMetrics[\(i)].name"
            if extra.name.trimmed.isEmpty {
                issues.append(.init(field, "must not be empty"))
            } else if !names.insert(extra.name).inserted {
                issues.append(.init(field, "repeats metric \(extra.name)"))
            }
        }
        for (i, rule) in guardrails.enumerated() where rule.trimmed.isEmpty {
            issues.append(.init("guardrails[\(i)]", "must not be empty"))
        }
        issues += validateBindings()
        issues += validateTriggers()
        issues += validatePolicy()
        issues += validateReport()
        if adapter.trimmed.isEmpty { issues.append(.init("adapter", "must not be empty")) }
        if crew.maxParallel < 1 { issues.append(.init("crew.maxParallel", "must be at least 1")) }
        if limits.maxTurns < 1 { issues.append(.init("limits.maxTurns", "must be at least 1")) }
        if limits.timeoutSeconds < 1 {
            issues.append(.init("limits.timeoutSeconds", "must be at least 1"))
        }
        if limits.maxCostMicros < 0 {
            issues.append(.init("limits.maxCostMicros", "must not be negative"))
        }
        issues += validateScorer()
        if gate.samples < 1 { issues.append(.init("gate.samples", "must be at least 1")) }
        if !(gate.tolerance >= 0) { issues.append(.init("gate.tolerance", "must not be negative")) }
        return issues
    }

    private func validateBindings() -> [CharterIssue] {
        var issues: [CharterIssue] = []
        var seen = Set<String>()
        for (i, binding) in bindings.enumerated() {
            let path = "bindings[\(i)]"
            if binding.id.trimmed.isEmpty {
                issues.append(.init("\(path).id", "must not be empty"))
            }
            if !seen.insert(binding.id).inserted {
                issues.append(.init("\(path).id", "duplicate binding id \(binding.id)"))
            }
            switch binding.kind {
            case .mcp where binding.command?.trimmed.isEmpty ?? true:
                issues.append(.init("\(path).command", "required for an mcp binding"))
            case .person where binding.channel?.trimmed.isEmpty ?? true:
                issues.append(.init("\(path).channel", "required for a person binding"))
            default: break
            }
        }
        return issues
    }

    private func validateTriggers() -> [CharterIssue] {
        var issues: [CharterIssue] = []
        for (i, trigger) in triggers.enumerated() {
            switch trigger {
            case .interval(let seconds) where seconds < 1:
                issues.append(.init("triggers[\(i)].everySeconds", "must be at least 1"))
            case .message(let from?) where binding(from)?.kind != .person:
                issues.append(.init("triggers[\(i)].from", "unknown person binding \(from)"))
            default: break
            }
        }
        return issues
    }

    private func validatePolicy() -> [CharterIssue] {
        var issues: [CharterIssue] = []
        for (i, rule) in policy.rules.enumerated() {
            if rule.action.trimmed.isEmpty {
                issues.append(.init("policy.rules[\(i)].action", "must not be empty"))
            }
            if let id = rule.binding, binding(id) == nil {
                issues.append(.init("policy.rules[\(i)].binding", "unknown binding \(id)"))
            }
        }
        return issues + validateApprovers() + validateUndo()
    }

    private func validateUndo() -> [CharterIssue] {
        var issues: [CharterIssue] = []
        for (i, rule) in policy.undo.enumerated() {
            let path = "policy.undo[\(i)]"
            if rule.action.trimmed.isEmpty {
                issues.append(.init("\(path).action", "must not be empty"))
            }
            if rule.with.trimmed.isEmpty {
                issues.append(.init("\(path).with", "must not be empty"))
            }
            if let id = rule.binding, binding(id) == nil {
                issues.append(.init("\(path).binding", "unknown binding \(id)"))
            }
        }
        return issues
    }

    private func validateApprovers() -> [CharterIssue] {
        var issues: [CharterIssue] = []
        for (i, rule) in policy.approvers.enumerated() {
            let path = "policy.approvers[\(i)]"
            if rule.action.trimmed.isEmpty {
                issues.append(.init("\(path).action", "must not be empty"))
            }
            if let id = rule.binding, binding(id) == nil {
                issues.append(.init("\(path).binding", "unknown binding \(id)"))
            }
            if rule.people.isEmpty { issues.append(.init("\(path).people", "must not be empty")) }
            for person in rule.people where person != "local" && binding(person)?.kind != .person {
                issues.append(.init("\(path).people", "unknown person \(person)"))
            }
        }
        return issues
    }

    private func validateScorer() -> [CharterIssue] {
        switch scorer {
        case .exact(let fields):
            if fields.isEmpty { return [.init("scorer.fields", "must not be empty")] }
            return fields.enumerated().compactMap { i, field in
                field.trimmed.isEmpty ? .init("scorer.fields[\(i)]", "must not be empty") : nil
            }
        case .rubric(let checks, let threshold):
            var issues: [CharterIssue] = []
            if checks.isEmpty { issues.append(.init("scorer.checks", "must not be empty")) }
            for (i, check) in checks.enumerated() where !(check.weight >= 0) {
                issues.append(.init("scorer.checks[\(i)].weight", "must not be negative"))
            }
            if !(0...1).contains(threshold) {
                issues.append(.init("scorer.passThreshold", "must be within 0...1"))
            }
            return issues
        }
    }
}

extension String {
    /// The string without leading and trailing whitespace.
    var trimmed: Substring {
        guard let first = firstIndex(where: { !$0.isWhitespace }),
            let last = lastIndex(where: { !$0.isWhitespace })
        else { return "" }
        return self[first...last]
    }
}
