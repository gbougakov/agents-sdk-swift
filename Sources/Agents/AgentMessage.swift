import Foundation

/// Wire-protocol message-type string literals used by the Cloudflare Agents SDK.
///
/// These values must match the server implementation **exactly**. They are ported
/// verbatim from `packages/agents/src/types.ts` (`MessageType`).
public enum MessageType {
    /// State broadcast (server → client) and state update (client → server).
    public static let state = "cf_agent_state"
    /// State-update error (server → client).
    public static let stateError = "cf_agent_state_error"
    /// Identity announcement (server → client): `{ name, agent }`.
    public static let identity = "cf_agent_identity"
    /// RPC request (client → server) and RPC response (server → client).
    public static let rpc = "rpc"

    // Types parsed-and-ignored in v1 (kept for reference / forward-compat).
    /// MCP server-state updates (out of scope for v1).
    public static let mcpServers = "cf_agent_mcp_servers"
    /// MCP agent events (out of scope for v1).
    public static let mcpAgentEvent = "cf_mcp_agent_event"
    /// Experimental session message (out of scope for v1).
    public static let session = "cf_agent_session"
    /// Experimental session error (out of scope for v1).
    public static let sessionError = "cf_agent_session_error"
}

// MARK: - Inbound payloads

/// Identity announcement sent by the server on connect (and on reconnect).
///
/// Wire shape: `{ "type": "cf_agent_identity", "name": "...", "agent": "..." }`.
public struct AgentIdentityMessage: Codable, Hashable, Sendable {
    /// The resolved instance/room name (server is authoritative).
    public let name: String
    /// The resolved agent namespace (kebab-cased).
    public let agent: String

    public init(name: String, agent: String) {
        self.name = name
        self.agent = agent
    }
}

/// State broadcast carrying the agent's current state as an untyped JSON value.
///
/// Wire shape: `{ "type": "cf_agent_state", "state": <JSON> }`. Used in both
/// directions; the client decodes `state` into its typed `State` separately.
public struct AgentStateMessage: Codable, Hashable, Sendable {
    /// The raw state payload, decoded into a typed `State` by the client.
    public let state: JSONValue

    public init(state: JSONValue) {
        self.state = state
    }
}

/// Error reported by the server when a client state update fails.
///
/// Wire shape: `{ "type": "cf_agent_state_error", "error": "..." }`.
public struct AgentStateErrorMessage: Codable, Hashable, Sendable {
    /// Human-readable error description.
    public let error: String

    public init(error: String) {
        self.error = error
    }
}

/// RPC response (server → client).
///
/// Wire shape (success, non-streaming): `{ id, success: true, result }`.
/// Streaming responses repeat `success: true` frames; `done` absent or `false`
/// indicates a chunk, `done: true` indicates the final value. On failure:
/// `{ id, success: false, error }`. Ported from `RPCResponse` in `index.ts`.
public struct RPCResponse: Decodable, Sendable {
    /// Correlation id matching the originating ``RPCRequest``.
    public let id: String
    /// Whether the call succeeded.
    public let success: Bool
    /// The result value (present when `success` is `true`).
    public let result: JSONValue?
    /// Whether this is the terminal frame of a streaming response.
    ///
    /// `nil` for non-streaming responses; `false` for an intermediate chunk;
    /// `true` for the final value.
    public let done: Bool?
    /// Error description (present when `success` is `false`).
    public let error: String?

    public init(
        id: String,
        success: Bool,
        result: JSONValue? = nil,
        done: Bool? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.success = success
        self.result = result
        self.done = done
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case id, success, result, done, error
    }
}

// MARK: - Inbound message envelope

/// A decoded inbound WebSocket message.
///
/// Decoding switches on the `"type"` discriminator and never throws for an
/// unrecognized (or v1-ignored, e.g. MCP/session) type: those decode to
/// ``unknown(type:)`` so a stray message can be safely skipped.
public enum InboundAgentMessage: Decodable, Sendable {
    /// `cf_agent_identity`
    case identity(AgentIdentityMessage)
    /// `cf_agent_state`
    case state(AgentStateMessage)
    /// `cf_agent_state_error`
    case stateError(AgentStateErrorMessage)
    /// `rpc` response
    case rpc(RPCResponse)
    /// Any other / v1-ignored type (MCP, session, future additions).
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()

        switch type {
        case MessageType.identity:
            self = .identity(try single.decode(AgentIdentityMessage.self))
        case MessageType.state:
            self = .state(try single.decode(AgentStateMessage.self))
        case MessageType.stateError:
            self = .stateError(try single.decode(AgentStateErrorMessage.self))
        case MessageType.rpc:
            self = .rpc(try single.decode(RPCResponse.self))
        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - Outbound encoders

/// Errors thrown while encoding outbound wire messages.
public enum AgentMessageEncodingError: Error, Sendable {
    /// The encoded JSON could not be represented as a UTF-8 string.
    case invalidUTF8
}

/// RPC request (client → server).
///
/// Wire shape: `{ "type": "rpc", "id": "...", "method": "...", "args": [<JSON>...] }`.
/// Ported from `RPCRequest` in `index.ts`.
public struct RPCRequest: Encodable, Sendable {
    /// Constant discriminator (`"rpc"`).
    public let type: String
    /// Per-call correlation id (typically a UUID string).
    public let id: String
    /// Name of the remote method to invoke.
    public let method: String
    /// Positional arguments, encoded as JSON values.
    public let args: [JSONValue]

    public init(id: String, method: String, args: [JSONValue]) {
        self.type = MessageType.rpc
        self.id = id
        self.method = method
        self.args = args
    }
}

/// State update (client → server).
///
/// Wire shape: `{ "type": "cf_agent_state", "state": <JSON> }`. Ported from
/// `StateUpdateMessage` in `index.ts` (note the server emits the same `type`).
public struct StateUpdateMessage: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_state"`).
    public let type: String
    /// The new state payload.
    public let state: JSONValue

    public init(state: JSONValue) {
        self.type = MessageType.state
        self.state = state
    }
}

/// Outbound encoders producing the exact JSON strings the server expects.
///
/// All helpers emit a single-line JSON object string suitable for sending as a
/// WebSocket text frame.
public enum OutboundAgentMessage {
    /// Encodes a `cf_agent_state` update frame.
    ///
    /// - Parameter state: The new state payload as a ``JSONValue``.
    /// - Returns: A JSON string, e.g. `{"type":"cf_agent_state","state":{...}}`.
    public static func setState(_ state: JSONValue) throws -> String {
        try encode(StateUpdateMessage(state: state))
    }

    /// Encodes an `rpc` request frame.
    ///
    /// - Parameters:
    ///   - id: Per-call correlation id.
    ///   - method: The remote method name.
    ///   - args: Positional arguments as ``JSONValue``s.
    /// - Returns: A JSON string,
    ///   e.g. `{"type":"rpc","id":"...","method":"...","args":[...]}`.
    public static func rpcRequest(
        id: String,
        method: String,
        args: [JSONValue] = []
    ) throws -> String {
        try encode(RPCRequest(id: id, method: method, args: args))
    }

    /// Encodes any `Encodable` outbound message to a compact JSON string.
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentMessageEncodingError.invalidUTF8
        }
        return string
    }
}
