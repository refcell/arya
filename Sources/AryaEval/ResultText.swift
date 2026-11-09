import AryaCore

/// Plain-text renderings of results and differences that the app shows verbatim, so views need
/// no formatting logic. Pure and deterministic.
public enum ResultText {
    /// A result in a few words: `chose billing; label inbox:MSG-1, route inbox:MSG-1`.
    /// Decisions show their choices, actions their kind and target, other scalar fields
    /// `key value`; `summary` and structured fields (plan, measurements) are left out. An empty
    /// result is `nothing`.
    public static func describe(_ result: JSONValue?) -> String {
        guard let result else { return "no result" }
        guard case .object(let members) = result else { return value(result) }
        var parts: [String] = []
        if case .array(let decisions)? = members["decisions"], !decisions.isEmpty {
            parts.append("chose " + decisions.map(value).joined(separator: ", "))
        }
        if case .array(let actions)? = members["actions"], !actions.isEmpty {
            parts.append(actions.map(value).joined(separator: ", "))
        }
        let rest = members.keys.sorted().filter {
            !["decisions", "actions", "summary"].contains($0)
        }
        for key in rest {
            guard let item = members[key], isScalar(item) else { continue }
            parts.append("\(key) \(value(item))")
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
    }

    /// Differences in a line: `decisions[0].choice: expected billing, got how-to`; no
    /// differences is `matches expected`.
    public static func describe(_ diff: [FieldDiff]) -> String {
        guard !diff.isEmpty else { return "matches expected" }
        return diff.map { item in
            let path = item.path.isEmpty ? "result" : item.path
            switch (item.expected, item.actual) {
            case (nil, let actual?): return "\(path): unexpected \(value(actual))"
            case (let expected?, nil): return "\(path): expected \(value(expected)), got nothing"
            case (let expected?, let actual?):
                return "\(path): expected \(value(expected)), got \(value(actual))"
            case (nil, nil): return path
            }
        }.joined(separator: "; ")
    }

    /// One value in words: a string as is, `{choice}` as its choice, `{kind, target}` as
    /// `kind target`, anything else as canonical JSON.
    public static func value(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number):
            if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
            return String(describing: number)
        case .object(let members):
            if case .string(let choice)? = members["choice"] { return choice }
            if case .string(let kind)? = members["kind"] {
                if case .string(let target)? = members["target"] { return "\(kind) \(target)" }
                return kind
            }
            return canonical(value)
        case .array:
            return canonical(value)
        }
    }

    static func canonical(_ value: JSONValue) -> String {
        (try? CanonicalJSON.string(value)) ?? "?"
    }

    static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .string, .bool, .int, .double: return true
        case .array, .object, .null: return false
        }
    }
}
