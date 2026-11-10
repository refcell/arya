import Foundation

/// One past unit of work with its known result: the input a steward would have seen, the
/// context recorded at the time, and what it should have done. One JSON line in a casebook.
public struct Case: Hashable, Sendable, Codable {
    /// Schema version; always 1.
    public var v: Int
    public var id: CaseID
    public var input: CaseInput
    public var context: CaseContext
    /// The expected result, in the shape of `run/result.result` (`decisions`, `actions`, …).
    /// Scorers read it by path, so it stays free-form.
    public var expected: JSONValue
    /// Where the case came from, for people reading it.
    public var source: String?

    public init(
        id: CaseID, input: CaseInput, context: CaseContext = CaseContext(),
        expected: JSONValue, source: String? = nil
    ) {
        v = 1
        self.id = id
        self.input = input
        self.context = context
        self.expected = expected
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case v, id, input, context, expected, source }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(CaseID.self, forKey: .id)
        input = try c.decode(CaseInput.self, forKey: .input)
        context = try c.decodeIfPresent(CaseContext.self, forKey: .context) ?? CaseContext()
        expected = try c.decode(JSONValue.self, forKey: .expected)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    /// Decodes and validates one case.
    public static func load(from data: Data) throws -> Case {
        let value: Case
        do {
            value = try JSONDecoder().decode(Case.self, from: data)
        } catch {
            throw CaseError.malformed(String(describing: error))
        }
        let issues = value.validate()
        if !issues.isEmpty { throw CaseError.invalid(issues) }
        return value
    }

    /// Every rule the case breaks. Empty means valid.
    public func validate() -> [CharterIssue] {
        var issues: [CharterIssue] = []
        if v != 1 { issues.append(.init("v", "unsupported version \(v)")) }
        if input.text.trimmed.isEmpty { issues.append(.init("input.text", "must not be empty")) }
        if expected.objectValue == nil { issues.append(.init("expected", "must be an object")) }
        for (i, result) in context.toolResults.enumerated() where result.tool.trimmed.isEmpty {
            issues.append(.init("context.toolResults[\(i)].tool", "must not be empty"))
        }
        return issues
    }
}

/// Why a case was refused.
public enum CaseError: Error, Hashable, Sendable {
    case malformed(String)
    case invalid([CharterIssue])
}

/// The input of a case, in the shape of `run/start.input`.
public struct CaseInput: Hashable, Sendable, Codable {
    /// Usually `case`.
    public var kind: String
    public var text: String
    public var attachments: [JSONValue]

    public init(kind: String = "case", text: String, attachments: [JSONValue] = []) {
        self.kind = kind
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case kind, text, attachments }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "case"
        text = try c.decode(String.self, forKey: .text)
        attachments = try c.decodeIfPresent([JSONValue].self, forKey: .attachments) ?? []
    }
}

/// What was known when the case happened. Rehearsal answers tool reads from `toolResults`.
public struct CaseContext: Hashable, Sendable, Codable {
    public var toolResults: [RecordedToolResult]
    /// Memory the steward should see, as recorded (free-form note objects).
    public var memory: [JSONValue]
    /// The steward's plan when the case happened (plan item objects). A rehearsal shows this
    /// plan, never the steward's live one, so the same case always gets the same instructions.
    public var plan: [JSONValue]

    public init(
        toolResults: [RecordedToolResult] = [], memory: [JSONValue] = [], plan: [JSONValue] = []
    ) {
        self.toolResults = toolResults
        self.memory = memory
        self.plan = plan
    }

    private enum CodingKeys: String, CodingKey { case toolResults, memory, plan }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolResults = try c.decodeIfPresent([RecordedToolResult].self, forKey: .toolResults) ?? []
        memory = try c.decodeIfPresent([JSONValue].self, forKey: .memory) ?? []
        plan = try c.decodeIfPresent([JSONValue].self, forKey: .plan) ?? []
    }

    /// `plan` is written only when it has items, so cases without one keep their bytes.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolResults, forKey: .toolResults)
        try c.encode(memory, forKey: .memory)
        if !plan.isEmpty { try c.encode(plan, forKey: .plan) }
    }
}

/// A tool call and its answer, recorded so a rehearsal or replay can serve it again.
public struct RecordedToolResult: Hashable, Sendable, Codable {
    /// `<binding>.<tool>`, for example `tracker.get`.
    public var tool: String
    public var input: JSONValue
    public var output: JSONValue
    public var isError: Bool

    public init(tool: String, input: JSONValue, output: JSONValue, isError: Bool = false) {
        self.tool = tool
        self.input = input
        self.output = output
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey { case tool, input, output, isError }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(String.self, forKey: .tool)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
        output = try c.decodeIfPresent(JSONValue.self, forKey: .output) ?? .null
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}
