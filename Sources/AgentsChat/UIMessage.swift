import Agents
import Foundation

/// A chat message in the Vercel AI SDK v6 "UI message" shape.
///
/// This is the canonical message representation exchanged between the client and a Cloudflare
/// Agent's chat endpoint. A message has a stable `id`, a `role`, optional free-form `metadata`,
/// and an ordered list of ``UIMessagePart`` values that together make up the rendered content.
///
/// The wire format matches the AI SDK exactly (field names `id`, `role`, `metadata`, `parts`),
/// so values decode from and encode back to JSON that the server understands without
/// transformation.
public struct UIMessage: Codable, Sendable, Identifiable, Hashable {
    /// The role of a chat message.
    public enum Role: String, Codable, Sendable, Hashable {
        case system
        case user
        case assistant
    }

    /// A unique identifier for the message.
    public var id: String

    /// The role of the message.
    public var role: Role

    /// Free-form metadata attached to the message, if any.
    ///
    /// The AI SDK leaves this untyped (`METADATA = unknown`), so it is represented here as a
    /// ``JSONValue`` to preserve arbitrary payloads losslessly.
    public var metadata: JSONValue?

    /// The ordered parts of the message used for rendering.
    public var parts: [UIMessagePart]

    /// Creates a UI message.
    /// - Parameters:
    ///   - id: A unique identifier for the message.
    ///   - role: The role of the message.
    ///   - metadata: Optional free-form metadata.
    ///   - parts: The ordered parts of the message.
    public init(id: String, role: Role, metadata: JSONValue? = nil, parts: [UIMessagePart] = []) {
        self.id = id
        self.role = role
        self.metadata = metadata
        self.parts = parts
    }
}

/// A single part of a ``UIMessage``.
///
/// The AI SDK models message parts as a discriminated union keyed on a `type` string. Most parts
/// use a literal `type` (`"text"`, `"reasoning"`, …), but two families embed a name in the
/// discriminator: data parts use `"data-<name>"` and static tool parts use `"tool-<name>"`. The
/// custom `Codable` implementation splits those prefixes to recover the embedded name while
/// preserving exact round-tripping.
///
/// Any `type` not recognised decodes to ``unknown`` so that forward-compatible payloads survive a
/// decode/encode cycle without data loss.
public enum UIMessagePart: Codable, Sendable, Hashable {
    /// A text part (`type: "text"`).
    case text(text: String, state: StreamingState?, providerMetadata: JSONValue?)

    /// A reasoning part (`type: "reasoning"`).
    case reasoning(text: String, state: StreamingState?, providerMetadata: JSONValue?)

    /// A URL source citation (`type: "source-url"`).
    case sourceUrl(sourceId: String, url: String, title: String?, providerMetadata: JSONValue?)

    /// A document source citation (`type: "source-document"`).
    case sourceDocument(
        sourceId: String,
        mediaType: String,
        title: String,
        filename: String?,
        providerMetadata: JSONValue?
    )

    /// A file part (`type: "file"`).
    case file(mediaType: String, filename: String?, url: String, providerMetadata: JSONValue?)

    /// A step boundary part (`type: "step-start"`).
    case stepStart

    /// A data part (`type: "data-<name>"`). `name` is the suffix after `data-`.
    case data(name: String, id: String?, value: JSONValue)

    /// A static tool invocation part (`type: "tool-<name>"`). `name` is the suffix after `tool-`.
    case tool(name: String, invocation: ToolInvocation)

    /// A dynamic tool invocation part (`type: "dynamic-tool"`).
    case dynamicTool(toolName: String, invocation: ToolInvocation)

    /// A part whose `type` is not recognised, preserved verbatim for forward compatibility.
    case unknown(type: String, value: JSONValue)

    /// The streaming lifecycle of a text or reasoning part.
    public enum StreamingState: String, Codable, Sendable, Hashable {
        case streaming
        case done
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case state
        case providerMetadata
        case sourceId
        case url
        case title
        case mediaType
        case filename
        case id
        case data
        case toolName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(
                text: try container.decode(String.self, forKey: .text),
                state: try container.decodeIfPresent(StreamingState.self, forKey: .state),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "reasoning":
            self = .reasoning(
                text: try container.decode(String.self, forKey: .text),
                state: try container.decodeIfPresent(StreamingState.self, forKey: .state),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "source-url":
            self = .sourceUrl(
                sourceId: try container.decode(String.self, forKey: .sourceId),
                url: try container.decode(String.self, forKey: .url),
                title: try container.decodeIfPresent(String.self, forKey: .title),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "source-document":
            self = .sourceDocument(
                sourceId: try container.decode(String.self, forKey: .sourceId),
                mediaType: try container.decode(String.self, forKey: .mediaType),
                title: try container.decode(String.self, forKey: .title),
                filename: try container.decodeIfPresent(String.self, forKey: .filename),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "file":
            self = .file(
                mediaType: try container.decode(String.self, forKey: .mediaType),
                filename: try container.decodeIfPresent(String.self, forKey: .filename),
                url: try container.decode(String.self, forKey: .url),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "step-start":
            self = .stepStart

        case "dynamic-tool":
            self = .dynamicTool(
                toolName: try container.decode(String.self, forKey: .toolName),
                invocation: try ToolInvocation(from: decoder)
            )

        default:
            if let name = type.dropPrefix("data-") {
                // The AI SDK stores the payload under the `data` key for data parts.
                self = .data(
                    name: name,
                    id: try container.decodeIfPresent(String.self, forKey: .id),
                    value: try container.decode(JSONValue.self, forKey: .data)
                )
            } else if let name = type.dropPrefix("tool-") {
                self = .tool(name: name, invocation: try ToolInvocation(from: decoder))
            } else {
                // Forward-compatible fallback: keep the whole object so it round-trips.
                self = .unknown(type: type, value: try JSONValue(from: decoder))
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        // Tool, dynamic-tool, and unknown parts encode their full object representation directly,
        // so they bypass the keyed container assembled below.
        switch self {
        case .tool(let name, let invocation):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("tool-\(name)", forKey: .type)
            try invocation.encode(to: encoder)
            return

        case .dynamicTool(let toolName, let invocation):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("dynamic-tool", forKey: .type)
            try container.encode(toolName, forKey: .toolName)
            try invocation.encode(to: encoder)
            return

        case .unknown(let type, let value):
            // Re-emit the preserved object, ensuring `type` reflects the stored discriminator.
            if case .object(var object) = value {
                object["type"] = .string(type)
                try JSONValue.object(object).encode(to: encoder)
            } else {
                try value.encode(to: encoder)
            }
            return

        default:
            break
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let state, let providerMetadata):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(state, forKey: .state)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .reasoning(let text, let state, let providerMetadata):
            try container.encode("reasoning", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(state, forKey: .state)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .sourceUrl(let sourceId, let url, let title, let providerMetadata):
            try container.encode("source-url", forKey: .type)
            try container.encode(sourceId, forKey: .sourceId)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .sourceDocument(let sourceId, let mediaType, let title, let filename, let providerMetadata):
            try container.encode("source-document", forKey: .type)
            try container.encode(sourceId, forKey: .sourceId)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(filename, forKey: .filename)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .file(let mediaType, let filename, let url, let providerMetadata):
            try container.encode("file", forKey: .type)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encodeIfPresent(filename, forKey: .filename)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .stepStart:
            try container.encode("step-start", forKey: .type)

        case .data(let name, let id, let value):
            try container.encode("data-\(name)", forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(value, forKey: .data)

        case .tool, .dynamicTool, .unknown:
            // Handled above.
            break
        }
    }
}

/// A tool invocation, modelling the AI SDK `UIToolInvocation` state machine.
///
/// A tool invocation always carries a `toolCallId` plus optional shared fields (`title`,
/// `toolMetadata`, `providerExecuted`). The `state` discriminator then selects which additional
/// fields are present:
///
/// - `input-streaming`: a (possibly partial) `input` is streaming in.
/// - `input-available`: the full `input` is available.
/// - `approval-requested`: the call is awaiting approval; carries an ``Approval`` with only `id`.
/// - `approval-responded`: an approval decision was made; the ``Approval`` carries `approved`.
/// - `output-available`: the call produced `output`.
/// - `output-error`: the call failed with `errorText`.
/// - `output-denied`: the approval was denied; the ``Approval`` carries `approved == false`.
///
/// Field names match the wire format exactly so values round-trip through JSON unchanged.
public struct ToolInvocation: Codable, Sendable, Hashable {
    /// The lifecycle state of a tool invocation.
    public enum State: String, Codable, Sendable, Hashable {
        case inputStreaming = "input-streaming"
        case inputAvailable = "input-available"
        case approvalRequested = "approval-requested"
        case approvalResponded = "approval-responded"
        case outputAvailable = "output-available"
        case outputError = "output-error"
        case outputDenied = "output-denied"
    }

    /// An approval request/response attached to a tool invocation.
    public struct Approval: Codable, Sendable, Hashable {
        /// The approval request identifier.
        public var id: String
        /// Whether the request was approved. Absent until a decision is made.
        public var approved: Bool?
        /// An optional human-readable reason for the decision.
        public var reason: String?

        public init(id: String, approved: Bool? = nil, reason: String? = nil) {
            self.id = id
            self.approved = approved
            self.reason = reason
        }
    }

    /// ID of the tool call.
    public var toolCallId: String

    /// The current lifecycle state.
    public var state: State

    /// An optional display title for the tool call.
    public var title: String?

    /// Optional tool-specific metadata.
    public var toolMetadata: JSONValue?

    /// Whether the tool call was executed by the provider.
    public var providerExecuted: Bool?

    /// The tool input. Partial while `state == .inputStreaming`; may be absent on `outputError`.
    public var input: JSONValue?

    /// The raw, unparsed input, only present on `outputError`.
    public var rawInput: JSONValue?

    /// The tool output, present when `state == .outputAvailable`.
    public var output: JSONValue?

    /// The error message, present when `state == .outputError`.
    public var errorText: String?

    /// Provider metadata captured at call time.
    public var callProviderMetadata: JSONValue?

    /// Provider metadata captured for the result.
    public var resultProviderMetadata: JSONValue?

    /// Whether the available output is preliminary (still subject to change).
    public var preliminary: Bool?

    /// The approval request/response, present in approval-related states.
    public var approval: Approval?

    public init(
        toolCallId: String,
        state: State,
        title: String? = nil,
        toolMetadata: JSONValue? = nil,
        providerExecuted: Bool? = nil,
        input: JSONValue? = nil,
        rawInput: JSONValue? = nil,
        output: JSONValue? = nil,
        errorText: String? = nil,
        callProviderMetadata: JSONValue? = nil,
        resultProviderMetadata: JSONValue? = nil,
        preliminary: Bool? = nil,
        approval: Approval? = nil
    ) {
        self.toolCallId = toolCallId
        self.state = state
        self.title = title
        self.toolMetadata = toolMetadata
        self.providerExecuted = providerExecuted
        self.input = input
        self.rawInput = rawInput
        self.output = output
        self.errorText = errorText
        self.callProviderMetadata = callProviderMetadata
        self.resultProviderMetadata = resultProviderMetadata
        self.preliminary = preliminary
        self.approval = approval
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId
        case state
        case title
        case toolMetadata
        case providerExecuted
        case input
        case rawInput
        case output
        case errorText
        case callProviderMetadata
        case resultProviderMetadata
        case preliminary
        case approval
    }
}

// MARK: - Helpers

extension String {
    /// Returns the substring after `prefix`, or `nil` if `self` does not start with `prefix`.
    ///
    /// Used to split the embedded name out of `data-<name>` / `tool-<name>` discriminators.
    fileprivate func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
