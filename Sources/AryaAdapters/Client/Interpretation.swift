import AryaCore
import Foundation

/// What a host does with one message read from an adapter. Pure, so the live connection and
/// the replay adapter treat recorded and live messages identically.
struct Interpretation {
    /// Typed updates to publish after the `.wire` update of the message.
    var updates: [AdapterUpdate] = []
    /// The response to resolve a pending request with.
    var response: RPCResponse?
    /// A response the host sends back on its own (to a request it does not serve).
    var reply: RPCResponse?
    /// Whether the message was the run's `run/result`.
    var isResult = false

    /// Interprets one received line.
    static func of(line: Data) -> (RPCMessage?, Interpretation) {
        do {
            let message = try LineCodec.decode(line)
            return (message, of(message))
        } catch {
            return (nil, Interpretation(updates: [.protocolError(error)]))
        }
    }

    /// Interprets one received message.
    static func of(_ message: RPCMessage) -> Interpretation {
        switch message {
        case .response(let response):
            return Interpretation(response: response)
        case .notification(let notification):
            return of(notification)
        case .request(let request):
            return of(request)
        }
    }

    private static func of(_ notification: RPCNotification) -> Interpretation {
        let params = notification.params ?? .null
        do {
            switch notification.method {
            case RPCMethod.runEvent:
                return Interpretation(updates: [.event(try params.decode(RunEventParams.self))])
            case RPCMethod.runResult:
                let result = try params.decode(RunResultParams.self)
                return Interpretation(updates: [.result(result)], isResult: true)
            default:
                return Interpretation()
            }
        } catch {
            let message = "invalid \(notification.method) params: \(error)"
            return Interpretation(
                updates: [
                    .protocolError(RPCError(code: RPCErrorCode.invalidParams, message: message))
                ])
        }
    }

    private static func of(_ request: RPCRequest) -> Interpretation {
        guard request.method == RPCMethod.hostAsk || request.method == RPCMethod.hostDelegate
        else {
            let error = RPCError(
                code: RPCErrorCode.methodNotFound, message: "unknown method \(request.method)")
            return Interpretation(reply: RPCResponse(id: request.id, error: error))
        }
        do {
            let params = request.params ?? .null
            if request.method == RPCMethod.hostDelegate {
                let delegation = try params.decode(HostDelegateParams.self)
                return Interpretation(updates: [.delegate(id: request.id, delegation)])
            }
            return Interpretation(
                updates: [.ask(id: request.id, try params.decode(HostAskParams.self))])
        } catch {
            let error = RPCError(code: RPCErrorCode.invalidParams, message: "\(error)")
            return Interpretation(
                updates: [.protocolError(error)], reply: RPCResponse(id: request.id, error: error))
        }
    }
}
