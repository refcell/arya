/// An action a run proposed (`run/result.result.actions[]`), as recorded on `action.proposed`
/// and `approval.requested`. Agents propose, arya disposes (decision 0005).
public struct ProposedAction: Sendable, Hashable, Codable {
    /// The id the adapter gave the action within its result (`a1`).
    public var id: String
    /// Action kind, for example `label` or `routine`.
    public var kind: String
    /// Binding that would carry it out; nil for `routine` (which uses `params.name`).
    public var binding: String?
    /// Target, for example `tracker:ISSUE-7`.
    public var target: String?
    /// Kind-specific parameters.
    public var params: JSONValue?
    /// The steward's reason.
    public var rationale: String?

    public init(
        id: String, kind: String, binding: String? = nil, target: String? = nil,
        params: JSONValue? = nil, rationale: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.binding = binding
        self.target = target
        self.params = params
        self.rationale = rationale
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, binding, target, params, rationale
    }
}
