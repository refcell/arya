import AryaCore
import Foundation

/// A JSON-RPC 2.0 request or response id: a number or a string.
public enum RPCID: Sendable, Hashable, Codable, CustomStringConvertible {
    case int(Int64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var json: JSONValue {
        switch self {
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        }
    }

    public var description: String {
        switch self {
        case .int(let value): String(value)
        case .string(let value): value
        }
    }
}

/// A JSON-RPC error object. Also thrown by adapter clients when a request fails.
public struct RPCError: Error, Sendable, Hashable, Codable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case code, message, data
    }
}

/// A request: it carries an id and expects a response with the same id.
public struct RPCRequest: Sendable, Hashable {
    public var id: RPCID
    public var method: String
    public var params: JSONValue?

    public init(id: RPCID, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A notification: a one-way message without an id.
public struct RPCNotification: Sendable, Hashable {
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

/// A response to a request, either a result or an error.
public struct RPCResponse: Sendable, Hashable {
    public var id: RPCID
    public var outcome: Result<JSONValue, RPCError>

    public init(id: RPCID, result: JSONValue) {
        self.id = id
        self.outcome = .success(result)
    }

    public init(id: RPCID, error: RPCError) {
        self.id = id
        self.outcome = .failure(error)
    }
}

/// One JSON-RPC 2.0 message, as it travels on one line of stdin or stdout.
public enum RPCMessage: Sendable, Hashable {
    case request(RPCRequest)
    case notification(RPCNotification)
    case response(RPCResponse)

    /// The method name for requests and notifications, `nil` for responses.
    public var method: String? {
        switch self {
        case .request(let request): request.method
        case .notification(let notification): notification.method
        case .response: nil
        }
    }
}

extension RPCMessage {
    /// The message as a JSON object, ready to encode.
    public var json: JSONValue {
        var members: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let request):
            members["id"] = request.id.json
            members["method"] = .string(request.method)
            if let params = request.params { members["params"] = params }
        case .notification(let notification):
            members["method"] = .string(notification.method)
            if let params = notification.params { members["params"] = params }
        case .response(let response):
            members["id"] = response.id.json
            switch response.outcome {
            case .success(let result):
                members["result"] = result
            case .failure(let error):
                var object: [String: JSONValue] = [
                    "code": .int(Int64(error.code)), "message": .string(error.message),
                ]
                if let data = error.data { object["data"] = data }
                members["error"] = .object(object)
            }
        }
        return .object(members)
    }

    /// Interprets a decoded JSON value as a JSON-RPC message.
    public init(json: JSONValue) throws(RPCError) {
        guard case .object(let members) = json, members["jsonrpc"] == "2.0" else {
            throw RPCError(code: RPCErrorCode.invalidRequest, message: "not a JSON-RPC 2.0 object")
        }
        let id = try Self.parseID(members["id"])
        if let methodValue = members["method"] {
            guard case .string(let method) = methodValue else {
                throw RPCError(code: RPCErrorCode.invalidRequest, message: "method is not a string")
            }
            let params = members["params"]
            if let id {
                self = .request(RPCRequest(id: id, method: method, params: params))
            } else {
                self = .notification(RPCNotification(method: method, params: params))
            }
            return
        }
        guard let id else {
            throw RPCError(
                code: RPCErrorCode.invalidRequest, message: "message has no id or method")
        }
        if let result = members["result"] {
            self = .response(RPCResponse(id: id, result: result))
        } else if let errorValue = members["error"] {
            let error = try Self.parseError(errorValue)
            self = .response(RPCResponse(id: id, error: error))
        } else {
            throw RPCError(code: RPCErrorCode.invalidRequest, message: "response has no result")
        }
    }

    private static func parseID(_ value: JSONValue?) throws(RPCError) -> RPCID? {
        switch value {
        case nil, .null?: return nil
        case .int(let id)?: return .int(id)
        case .string(let id)?: return .string(id)
        default: throw RPCError(code: RPCErrorCode.invalidRequest, message: "invalid id")
        }
    }

    private static func parseError(_ value: JSONValue) throws(RPCError) -> RPCError {
        guard let code = value["code"]?.intValue, let message = value["message"]?.stringValue
        else {
            throw RPCError(code: RPCErrorCode.invalidRequest, message: "malformed error object")
        }
        return RPCError(code: Int(code), message: message, data: value["data"])
    }
}

/// Error codes from the JSON-RPC specification and the adapter protocol.
public enum RPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// The adapter does not support the requested protocol version.
    public static let unsupportedProtocol = -32001
    /// The adapter lacks the capability the method needs.
    public static let capabilityNotSupported = -32002
    /// The session id is not known to the adapter.
    public static let unknownSession = -32003
    /// The harness failed; the message has detail.
    public static let harnessFailure = -32004
    /// The process already serves a run.
    public static let busy = -32005
}

/// Method names of the adapter protocol.
public enum RPCMethod {
    public static let initialize = "initialize"
    public static let runStart = "run/start"
    public static let runSend = "run/send"
    public static let runStop = "run/stop"
    public static let runTranscript = "run/transcript"
    public static let runCost = "run/cost"
    public static let shutdown = "shutdown"
    public static let ping = "ping"
    public static let runEvent = "run/event"
    public static let runResult = "run/result"
    public static let hostAsk = "host/ask"
    public static let hostDelegate = "host/delegate"
}
