import Foundation
import Agents

/// Wire-protocol message-type string literals used by the Cloudflare AI Chat layer.
///
/// These values must match the server implementation **exactly**. They are ported
/// verbatim from `packages/ai-chat/src/types.ts` (`MessageType`).
public enum ChatMessageType {
    /// Updated chat-message list (both directions): `{ messages: [UIMessage] }`.
    public static let chatMessages = "cf_agent_chat_messages"
    /// Chat request (client → server): `{ id, init: { method, body } }`.
    public static let useChatRequest = "cf_agent_use_chat_request"
    /// Chat response chunk (server → client): `{ id, body, done, ... }`.
    public static let useChatResponse = "cf_agent_use_chat_response"
    /// Clear chat history (both directions): `{ }`.
    public static let chatClear = "cf_agent_chat_clear"
    /// Cancel in-flight generation (client → server): `{ id }`.
    public static let chatRequestCancel = "cf_agent_chat_request_cancel"

    /// Server announces an active stream to resume (server → client): `{ id }`.
    public static let streamResuming = "cf_agent_stream_resuming"
    /// Client acknowledges resume and requests chunks (client → server): `{ id }`.
    public static let streamResumeAck = "cf_agent_stream_resume_ack"
    /// Client requests a stream-resume check (client → server): `{ }`.
    public static let streamResumeRequest = "cf_agent_stream_resume_request"
    /// Server reports no active stream to resume (server → client): `{ }`.
    public static let streamResumeNone = "cf_agent_stream_resume_none"

    /// Client sends a tool result (client → server).
    public static let toolResult = "cf_agent_tool_result"
    /// Client sends a tool approval response (client → server).
    public static let toolApproval = "cf_agent_tool_approval"
    /// Server notifies that a message was updated (server → client): `{ message }`.
    public static let messageUpdated = "cf_agent_message_updated"
}

// MARK: - Shared sub-payloads

/// Request-initialization options for a `cf_agent_use_chat_request` frame.
///
/// Mirrors the `init` field of `IncomingMessage` in `types.ts`. The SDK only ever
/// sends `method: "POST"` with a JSON-encoded `body` string (the body is itself a
/// JSON document containing `{ messages, trigger, ...extraBody }`).
public struct ChatRequestInit: Codable, Hashable, Sendable {
    /// The HTTP method (always `"POST"` for the chat protocol).
    public let method: String
    /// The request body, pre-encoded as a JSON string.
    public let body: String

    public init(method: String = "POST", body: String) {
        self.method = method
        self.body = body
    }
}

/// Tool-result part state override used by `cf_agent_tool_result`.
///
/// Mirrors the `state` union in `types.ts`
/// (`"output-available" | "output-error"`).
public enum ChatToolResultState: String, Codable, Hashable, Sendable {
    /// The tool produced an output (`"output-available"`).
    case outputAvailable = "output-available"
    /// The tool failed (`"output-error"`).
    case outputError = "output-error"
}

/// A client tool schema attached to a tool result for continuation, where the
/// client is the source of truth for available tools.
///
/// Mirrors an element of `clientTools` in `IncomingMessage` (`types.ts`).
public struct ChatClientTool: Codable, Hashable, Sendable {
    /// Tool name.
    public let name: String
    /// Optional human-readable description.
    public let description: String?
    /// Optional JSON-Schema parameters object.
    public let parameters: JSONValue?

    public init(name: String, description: String? = nil, parameters: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Inbound payloads (server → client)

/// Updated chat-message list. Wire shape: `{ messages: [UIMessage] }`.
public struct ChatMessagesMessage: Codable, Hashable, Sendable {
    /// The full set of chat messages.
    public let messages: [UIMessage]

    public init(messages: [UIMessage]) {
        self.messages = messages
    }
}

/// A single chat-response chunk (server → client).
///
/// Wire shape: `{ id, body, done, error?, continuation?, replay?, replayComplete? }`.
/// The `body` is itself a JSON string that parses into a `UIMessageChunk`.
public struct UseChatResponseMessage: Codable, Hashable, Sendable {
    /// The request id this response corresponds to.
    public let id: String
    /// The response body (a JSON-encoded `UIMessageChunk`, or an error message when `error` is true).
    public let body: String
    /// Whether this is the final chunk of the response.
    public let done: Bool
    /// Whether this response carries an error.
    public let error: Bool?
    /// Whether this is a continuation (append to the last assistant message).
    public let continuation: Bool?
    /// Whether this chunk is being replayed from storage (stream resumption).
    public let replay: Bool?
    /// Signals replay of stored chunks is complete (the stream is still active).
    public let replayComplete: Bool?

    public init(
        id: String,
        body: String,
        done: Bool,
        error: Bool? = nil,
        continuation: Bool? = nil,
        replay: Bool? = nil,
        replayComplete: Bool? = nil
    ) {
        self.id = id
        self.body = body
        self.done = done
        self.error = error
        self.continuation = continuation
        self.replay = replay
        self.replayComplete = replayComplete
    }
}

/// Server announcement of an active stream to resume. Wire shape: `{ id }`.
public struct StreamResumingMessage: Codable, Hashable, Sendable {
    /// The request id of the stream being resumed.
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// Server notification that a single message was updated. Wire shape: `{ message }`.
public struct MessageUpdatedMessage: Codable, Hashable, Sendable {
    /// The updated message.
    public let message: UIMessage

    public init(message: UIMessage) {
        self.message = message
    }
}

// MARK: - Inbound message envelope

/// A decoded inbound chat WebSocket message.
///
/// Decoding switches on the `"type"` discriminator and never throws for an
/// unrecognized type: those decode to ``unknown(type:)`` so a stray message can
/// be safely skipped. Mirrors `OutgoingMessage` in `types.ts` (server → client)
/// plus the symmetric `cf_agent_chat_messages` / `cf_agent_chat_clear` frames.
public enum InboundChatMessage: Decodable, Sendable {
    /// `cf_agent_chat_messages`
    case chatMessages(ChatMessagesMessage)
    /// `cf_agent_use_chat_response`
    case useChatResponse(UseChatResponseMessage)
    /// `cf_agent_chat_clear`
    case chatClear
    /// `cf_agent_stream_resuming`
    case streamResuming(StreamResumingMessage)
    /// `cf_agent_stream_resume_none`
    case streamResumeNone
    /// `cf_agent_message_updated`
    case messageUpdated(MessageUpdatedMessage)
    /// Any other / unrecognized type (future additions, ignored frames).
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()

        switch type {
        case ChatMessageType.chatMessages:
            self = .chatMessages(try single.decode(ChatMessagesMessage.self))
        case ChatMessageType.useChatResponse:
            self = .useChatResponse(try single.decode(UseChatResponseMessage.self))
        case ChatMessageType.chatClear:
            self = .chatClear
        case ChatMessageType.streamResuming:
            self = .streamResuming(try single.decode(StreamResumingMessage.self))
        case ChatMessageType.streamResumeNone:
            self = .streamResumeNone
        case ChatMessageType.messageUpdated:
            self = .messageUpdated(try single.decode(MessageUpdatedMessage.self))
        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - Outbound frame structs (client → server)

/// `cf_agent_use_chat_request` frame. Wire shape: `{ type, id, init }`.
public struct UseChatRequestFrame: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_use_chat_request"`).
    public let type: String
    /// Unique id for this request.
    public let id: String
    /// Request-initialization options (`{ method, body }`).
    public let `init`: ChatRequestInit

    public init(id: String, `init`: ChatRequestInit) {
        self.type = ChatMessageType.useChatRequest
        self.id = id
        self.`init` = `init`
    }
}

/// `cf_agent_chat_messages` frame. Wire shape: `{ type, messages }`.
public struct ChatMessagesFrame: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_chat_messages"`).
    public let type: String
    /// The full set of chat messages.
    public let messages: [UIMessage]

    public init(messages: [UIMessage]) {
        self.type = ChatMessageType.chatMessages
        self.messages = messages
    }
}

/// `cf_agent_chat_clear` frame. Wire shape: `{ type }`.
public struct ChatClearFrame: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_chat_clear"`).
    public let type: String

    public init() {
        self.type = ChatMessageType.chatClear
    }
}

/// `cf_agent_chat_request_cancel` frame. Wire shape: `{ type, id }`.
public struct ChatRequestCancelFrame: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_chat_request_cancel"`).
    public let type: String
    /// The request id to cancel.
    public let id: String

    public init(id: String) {
        self.type = ChatMessageType.chatRequestCancel
        self.id = id
    }
}

/// `cf_agent_stream_resume_ack` frame. Wire shape: `{ type, id }`.
public struct StreamResumeAckFrame: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_stream_resume_ack"`).
    public let type: String
    /// The request id of the stream being resumed.
    public let id: String

    public init(id: String) {
        self.type = ChatMessageType.streamResumeAck
        self.id = id
    }
}

/// `cf_agent_stream_resume_request` frame. Wire shape: `{ type }`.
public struct StreamResumeRequestFrame: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_stream_resume_request"`).
    public let type: String

    public init() {
        self.type = ChatMessageType.streamResumeRequest
    }
}

/// `cf_agent_tool_result` frame.
///
/// Wire shape: `{ type, toolCallId, toolName, output, state?, errorText?,
/// autoContinue?, clientTools? }`.
public struct ToolResultFrame: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_tool_result"`).
    public let type: String
    /// The tool-call id this result is for.
    public let toolCallId: String
    /// The name of the tool.
    public let toolName: String
    /// The tool output as a JSON value.
    public let output: JSONValue
    /// Optional part-state override (`output-available` / `output-error`).
    public let state: ChatToolResultState?
    /// Error message when `state` is `output-error`.
    public let errorText: String?
    /// Whether the server should auto-continue after applying the result.
    public let autoContinue: Bool?
    /// Client tool schemas for continuation (client is source of truth).
    public let clientTools: [ChatClientTool]?

    public init(
        toolCallId: String,
        toolName: String,
        output: JSONValue,
        state: ChatToolResultState? = nil,
        errorText: String? = nil,
        autoContinue: Bool? = nil,
        clientTools: [ChatClientTool]? = nil
    ) {
        self.type = ChatMessageType.toolResult
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.output = output
        self.state = state
        self.errorText = errorText
        self.autoContinue = autoContinue
        self.clientTools = clientTools
    }
}

/// `cf_agent_tool_approval` frame.
///
/// Wire shape: `{ type, toolCallId, approved, autoContinue? }`.
public struct ToolApprovalFrame: Encodable, Sendable {
    /// Constant discriminator (`"cf_agent_tool_approval"`).
    public let type: String
    /// The tool-call id this approval is for.
    public let toolCallId: String
    /// Whether the tool execution was approved.
    public let approved: Bool
    /// Whether the server should auto-continue after applying the approval.
    public let autoContinue: Bool?

    public init(toolCallId: String, approved: Bool, autoContinue: Bool? = nil) {
        self.type = ChatMessageType.toolApproval
        self.toolCallId = toolCallId
        self.approved = approved
        self.autoContinue = autoContinue
    }
}

// MARK: - Outbound encoders

/// Errors thrown while encoding outbound chat wire messages.
public enum ChatMessageEncodingError: Error, Sendable {
    /// The encoded JSON could not be represented as a UTF-8 string.
    case invalidUTF8
}

/// Outbound chat-frame encoders producing the exact JSON strings the server expects.
///
/// Every helper returns a single compact JSON object string suitable for sending
/// as a WebSocket text frame.
public enum OutboundChatMessage {
    /// Encodes a `cf_agent_use_chat_request` frame.
    public static func useChatRequest(id: String, `init`: ChatRequestInit) throws -> String {
        try encode(UseChatRequestFrame(id: id, init: `init`))
    }

    /// Encodes a `cf_agent_use_chat_request` frame from a method + pre-encoded body string.
    public static func useChatRequest(
        id: String,
        method: String = "POST",
        body: String
    ) throws -> String {
        try encode(UseChatRequestFrame(id: id, init: ChatRequestInit(method: method, body: body)))
    }

    /// Encodes a `cf_agent_chat_messages` frame.
    public static func chatMessages(_ messages: [UIMessage]) throws -> String {
        try encode(ChatMessagesFrame(messages: messages))
    }

    /// Encodes a `cf_agent_chat_clear` frame.
    public static func chatClear() throws -> String {
        try encode(ChatClearFrame())
    }

    /// Encodes a `cf_agent_chat_request_cancel` frame.
    public static func chatRequestCancel(id: String) throws -> String {
        try encode(ChatRequestCancelFrame(id: id))
    }

    /// Encodes a `cf_agent_stream_resume_ack` frame.
    public static func streamResumeAck(id: String) throws -> String {
        try encode(StreamResumeAckFrame(id: id))
    }

    /// Encodes a `cf_agent_stream_resume_request` frame.
    public static func streamResumeRequest() throws -> String {
        try encode(StreamResumeRequestFrame())
    }

    /// Encodes a `cf_agent_tool_result` frame.
    public static func toolResult(
        toolCallId: String,
        toolName: String,
        output: JSONValue,
        state: ChatToolResultState? = nil,
        errorText: String? = nil,
        autoContinue: Bool? = nil,
        clientTools: [ChatClientTool]? = nil
    ) throws -> String {
        try encode(
            ToolResultFrame(
                toolCallId: toolCallId,
                toolName: toolName,
                output: output,
                state: state,
                errorText: errorText,
                autoContinue: autoContinue,
                clientTools: clientTools
            )
        )
    }

    /// Encodes a `cf_agent_tool_approval` frame.
    public static func toolApproval(
        toolCallId: String,
        approved: Bool,
        autoContinue: Bool? = nil
    ) throws -> String {
        try encode(ToolApprovalFrame(toolCallId: toolCallId, approved: approved, autoContinue: autoContinue))
    }

    /// Encodes any `Encodable` chat frame to a compact JSON string.
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ChatMessageEncodingError.invalidUTF8
        }
        return string
    }
}
