import AryaCore

extension Event {
    /// Builds an event from a parsed line, with the same rules as its `Decodable` conformance:
    /// unknown members are ignored, `steward` and `run` may be missing or null, ids must be
    /// valid, and `at` must be a timestamp. Throws a reason naming the first bad field.
    init(envelope json: JSONValue) throws(EnvelopeProblem) {
        guard case .object(let fields) = json else { throw EnvelopeProblem("not an object") }
        func string(_ key: String) throws(EnvelopeProblem) -> String {
            guard case .string(let value)? = fields[key] else { throw EnvelopeProblem(key) }
            return value
        }
        func optional<ID: PrefixedID>(_ key: String, _: ID.Type) throws(EnvelopeProblem) -> ID? {
            switch fields[key] {
            case nil, .null?: return nil
            case .string(let raw)?:
                guard let id = ID(rawValue: raw) else { throw EnvelopeProblem(key) }
                return id
            default: throw EnvelopeProblem(key)
            }
        }
        guard case .int(let version)? = fields["v"], let v = Int(exactly: version) else {
            throw EnvelopeProblem("v")
        }
        guard case .int(let seq)? = fields["seq"] else { throw EnvelopeProblem("seq") }
        guard let id = EventID(rawValue: try string("id")) else { throw EnvelopeProblem("id") }
        guard let at = Timestamp(try string("at")) else { throw EnvelopeProblem("at") }
        guard let payload = fields["payload"] else { throw EnvelopeProblem("payload") }
        self.init(
            v: v, seq: seq, id: id, at: at, steward: try optional("steward", StewardID.self),
            run: try optional("run", RunID.self), actor: try Actor(envelope: fields["actor"]),
            type: EventType(rawValue: try string("type")), payload: payload,
            prev: try string("prev"), hash: try string("hash"))
    }
}

extension Actor {
    init(envelope json: JSONValue?) throws(EnvelopeProblem) {
        guard case .object(let fields)? = json, case .string(let kind)? = fields["kind"],
            let parsed = Kind(rawValue: kind), case .string(let id)? = fields["id"]
        else { throw EnvelopeProblem("actor") }
        self.init(kind: parsed, id: id)
    }
}

/// The envelope field that failed to decode.
struct EnvelopeProblem: Error {
    var field: String
    init(_ field: String) { self.field = field }
}
