import Agents
import Foundation

/// A single chunk in an AI SDK UI message stream.
///
/// This is a direct port of the Vercel AI SDK v6 `UIMessageChunk` discriminated union
/// (see `node_modules/ai/dist/index.d.ts`). Each case maps to one `type` literal on the wire,
/// and the associated values use the exact field names the AI SDK emits so the encoding
/// round-trips losslessly.
///
/// The stream is folded back into an evolving ``UIMessage`` by ``UIMessageStreamReducer``.
///
/// Unknown / future `type` values decode into ``unknown(type:raw:)`` instead of failing, so a
/// newer server cannot break an older client.
public enum UIMessageChunk: Codable, Sendable {

    /// `start` — begins a new assistant message.
    case start(messageId: String?, messageMetadata: JSONValue?)

    /// `start-step` — begins a step within the message.
    case startStep

    /// `text-start` — opens a text part identified by `id`.
    case textStart(id: String, providerMetadata: JSONValue?)

    /// `text-delta` — appends `delta` to the text part `id`.
    case textDelta(id: String, delta: String, providerMetadata: JSONValue?)

    /// `text-end` — closes the text part `id`.
    case textEnd(id: String, providerMetadata: JSONValue?)

    /// `reasoning-start` — opens a reasoning part identified by `id`.
    case reasoningStart(id: String, providerMetadata: JSONValue?)

    /// `reasoning-delta` — appends `delta` to the reasoning part `id`.
    case reasoningDelta(id: String, delta: String, providerMetadata: JSONValue?)

    /// `reasoning-end` — closes the reasoning part `id`.
    case reasoningEnd(id: String, providerMetadata: JSONValue?)

    /// `tool-input-start` — begins streaming the input for a tool call.
    case toolInputStart(
        toolCallId: String,
        toolName: String,
        providerExecuted: Bool?,
        providerMetadata: JSONValue?,
        toolMetadata: JSONValue?,
        dynamic: Bool?,
        title: String?
    )

    /// `tool-input-delta` — appends a partial-input text fragment for a tool call.
    case toolInputDelta(toolCallId: String, inputTextDelta: String)

    /// `tool-input-available` — the complete input for a tool call is now available.
    case toolInputAvailable(
        toolCallId: String,
        toolName: String,
        input: JSONValue,
        providerExecuted: Bool?,
        providerMetadata: JSONValue?,
        toolMetadata: JSONValue?,
        dynamic: Bool?,
        title: String?
    )

    /// `tool-input-error` — the tool input could not be produced.
    case toolInputError(
        toolCallId: String,
        toolName: String,
        input: JSONValue,
        providerExecuted: Bool?,
        providerMetadata: JSONValue?,
        toolMetadata: JSONValue?,
        dynamic: Bool?,
        errorText: String,
        title: String?
    )

    /// `tool-approval-request` — the server requests approval before executing a tool.
    case toolApprovalRequest(approvalId: String, toolCallId: String)

    /// `tool-output-available` — the tool produced output.
    case toolOutputAvailable(
        toolCallId: String,
        output: JSONValue,
        providerExecuted: Bool?,
        providerMetadata: JSONValue?,
        toolMetadata: JSONValue?,
        dynamic: Bool?,
        preliminary: Bool?
    )

    /// `tool-output-error` — the tool failed while producing output.
    case toolOutputError(
        toolCallId: String,
        errorText: String,
        providerExecuted: Bool?,
        providerMetadata: JSONValue?,
        toolMetadata: JSONValue?,
        dynamic: Bool?
    )

    /// `tool-output-denied` — a previously requested tool approval was denied.
    case toolOutputDenied(toolCallId: String)

    /// `source-url` — a URL source citation.
    case sourceUrl(sourceId: String, url: String, title: String?, providerMetadata: JSONValue?)

    /// `source-document` — a document source citation.
    case sourceDocument(
        sourceId: String,
        mediaType: String,
        title: String,
        filename: String?,
        providerMetadata: JSONValue?
    )

    /// `file` — a generated file referenced by URL.
    case file(url: String, mediaType: String, providerMetadata: JSONValue?)

    /// `data-<name>` — a custom data part. `name` is the suffix after `data-`.
    case data(name: String, id: String?, data: JSONValue, transient: Bool?)

    /// `finish-step` — ends the current step.
    case finishStep

    /// `finish` — finishes the message.
    case finish(finishReason: String?, messageMetadata: JSONValue?)

    /// `abort` — the stream was aborted.
    case abort(reason: String?)

    /// `error` — a stream-level error occurred.
    case error(errorText: String)

    /// `message-metadata` — updates the message metadata.
    case messageMetadata(messageMetadata: JSONValue)

    /// An unrecognized chunk type. Preserves the raw payload so it can be re-encoded verbatim.
    case unknown(type: String, raw: JSONValue)

    // MARK: - Coding keys

    private enum CodingKeys: String, CodingKey {
        case type
        case messageId
        case messageMetadata
        case id
        case delta
        case providerMetadata
        case toolCallId
        case toolName
        case providerExecuted
        case toolMetadata
        case dynamic
        case title
        case input
        case inputTextDelta
        case errorText
        case approvalId
        case output
        case preliminary
        case sourceId
        case url
        case mediaType
        case filename
        case finishReason
        case reason
        case data
        case transient
    }

    // MARK: - Decoding

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "start":
            self = .start(
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId),
                messageMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .messageMetadata)
            )

        case "start-step":
            self = .startStep

        case "text-start":
            self = .textStart(
                id: try container.decode(String.self, forKey: .id),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "text-delta":
            self = .textDelta(
                id: try container.decode(String.self, forKey: .id),
                delta: try container.decode(String.self, forKey: .delta),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "text-end":
            self = .textEnd(
                id: try container.decode(String.self, forKey: .id),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "reasoning-start":
            self = .reasoningStart(
                id: try container.decode(String.self, forKey: .id),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "reasoning-delta":
            self = .reasoningDelta(
                id: try container.decode(String.self, forKey: .id),
                delta: try container.decode(String.self, forKey: .delta),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "reasoning-end":
            self = .reasoningEnd(
                id: try container.decode(String.self, forKey: .id),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "tool-input-start":
            self = .toolInputStart(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                toolName: try container.decode(String.self, forKey: .toolName),
                providerExecuted: try container.decodeIfPresent(Bool.self, forKey: .providerExecuted),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata),
                toolMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .toolMetadata),
                dynamic: try container.decodeIfPresent(Bool.self, forKey: .dynamic),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )

        case "tool-input-delta":
            self = .toolInputDelta(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                inputTextDelta: try container.decode(String.self, forKey: .inputTextDelta)
            )

        case "tool-input-available":
            self = .toolInputAvailable(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                toolName: try container.decode(String.self, forKey: .toolName),
                input: try container.decode(JSONValue.self, forKey: .input),
                providerExecuted: try container.decodeIfPresent(Bool.self, forKey: .providerExecuted),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata),
                toolMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .toolMetadata),
                dynamic: try container.decodeIfPresent(Bool.self, forKey: .dynamic),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )

        case "tool-input-error":
            self = .toolInputError(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                toolName: try container.decode(String.self, forKey: .toolName),
                input: try container.decode(JSONValue.self, forKey: .input),
                providerExecuted: try container.decodeIfPresent(Bool.self, forKey: .providerExecuted),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata),
                toolMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .toolMetadata),
                dynamic: try container.decodeIfPresent(Bool.self, forKey: .dynamic),
                errorText: try container.decode(String.self, forKey: .errorText),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )

        case "tool-approval-request":
            self = .toolApprovalRequest(
                approvalId: try container.decode(String.self, forKey: .approvalId),
                toolCallId: try container.decode(String.self, forKey: .toolCallId)
            )

        case "tool-output-available":
            self = .toolOutputAvailable(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                output: try container.decode(JSONValue.self, forKey: .output),
                providerExecuted: try container.decodeIfPresent(Bool.self, forKey: .providerExecuted),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata),
                toolMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .toolMetadata),
                dynamic: try container.decodeIfPresent(Bool.self, forKey: .dynamic),
                preliminary: try container.decodeIfPresent(Bool.self, forKey: .preliminary)
            )

        case "tool-output-error":
            self = .toolOutputError(
                toolCallId: try container.decode(String.self, forKey: .toolCallId),
                errorText: try container.decode(String.self, forKey: .errorText),
                providerExecuted: try container.decodeIfPresent(Bool.self, forKey: .providerExecuted),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata),
                toolMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .toolMetadata),
                dynamic: try container.decodeIfPresent(Bool.self, forKey: .dynamic)
            )

        case "tool-output-denied":
            self = .toolOutputDenied(
                toolCallId: try container.decode(String.self, forKey: .toolCallId)
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
                url: try container.decode(String.self, forKey: .url),
                mediaType: try container.decode(String.self, forKey: .mediaType),
                providerMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .providerMetadata)
            )

        case "finish-step":
            self = .finishStep

        case "finish":
            self = .finish(
                finishReason: try container.decodeIfPresent(String.self, forKey: .finishReason),
                messageMetadata: try container.decodeIfPresent(JSONValue.self, forKey: .messageMetadata)
            )

        case "abort":
            self = .abort(reason: try container.decodeIfPresent(String.self, forKey: .reason))

        case "error":
            self = .error(errorText: try container.decode(String.self, forKey: .errorText))

        case "message-metadata":
            self = .messageMetadata(
                messageMetadata: try container.decode(JSONValue.self, forKey: .messageMetadata)
            )

        default:
            if let name = Self.dataChunkName(from: type) {
                self = .data(
                    name: name,
                    id: try container.decodeIfPresent(String.self, forKey: .id),
                    data: try container.decode(JSONValue.self, forKey: .data),
                    transient: try container.decodeIfPresent(Bool.self, forKey: .transient)
                )
            } else {
                // Preserve the entire payload so an unrecognized chunk re-encodes verbatim.
                let raw = try JSONValue(from: decoder)
                self = .unknown(type: type, raw: raw)
            }
        }
    }

    // MARK: - Encoding

    public func encode(to encoder: any Encoder) throws {
        // An unknown chunk re-encodes its stored payload verbatim through a single-value
        // container; it must not share the keyed container used by the known cases.
        if case .unknown(_, let raw) = self {
            try raw.encode(to: encoder)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .start(let messageId, let messageMetadata):
            try container.encode("start", forKey: .type)
            try container.encodeIfPresent(messageId, forKey: .messageId)
            try container.encodeIfPresent(messageMetadata, forKey: .messageMetadata)

        case .startStep:
            try container.encode("start-step", forKey: .type)

        case .textStart(let id, let providerMetadata):
            try container.encode("text-start", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .textDelta(let id, let delta, let providerMetadata):
            try container.encode("text-delta", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(delta, forKey: .delta)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .textEnd(let id, let providerMetadata):
            try container.encode("text-end", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .reasoningStart(let id, let providerMetadata):
            try container.encode("reasoning-start", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .reasoningDelta(let id, let delta, let providerMetadata):
            try container.encode("reasoning-delta", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(delta, forKey: .delta)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .reasoningEnd(let id, let providerMetadata):
            try container.encode("reasoning-end", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .toolInputStart(let toolCallId, let toolName, let providerExecuted,
                             let providerMetadata, let toolMetadata, let dynamic, let title):
            try container.encode("tool-input-start", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(toolName, forKey: .toolName)
            try container.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
            try container.encodeIfPresent(toolMetadata, forKey: .toolMetadata)
            try container.encodeIfPresent(dynamic, forKey: .dynamic)
            try container.encodeIfPresent(title, forKey: .title)

        case .toolInputDelta(let toolCallId, let inputTextDelta):
            try container.encode("tool-input-delta", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(inputTextDelta, forKey: .inputTextDelta)

        case .toolInputAvailable(let toolCallId, let toolName, let input, let providerExecuted,
                                 let providerMetadata, let toolMetadata, let dynamic, let title):
            try container.encode("tool-input-available", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(input, forKey: .input)
            try container.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
            try container.encodeIfPresent(toolMetadata, forKey: .toolMetadata)
            try container.encodeIfPresent(dynamic, forKey: .dynamic)
            try container.encodeIfPresent(title, forKey: .title)

        case .toolInputError(let toolCallId, let toolName, let input, let providerExecuted,
                             let providerMetadata, let toolMetadata, let dynamic, let errorText, let title):
            try container.encode("tool-input-error", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(input, forKey: .input)
            try container.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
            try container.encodeIfPresent(toolMetadata, forKey: .toolMetadata)
            try container.encodeIfPresent(dynamic, forKey: .dynamic)
            try container.encode(errorText, forKey: .errorText)
            try container.encodeIfPresent(title, forKey: .title)

        case .toolApprovalRequest(let approvalId, let toolCallId):
            try container.encode("tool-approval-request", forKey: .type)
            try container.encode(approvalId, forKey: .approvalId)
            try container.encode(toolCallId, forKey: .toolCallId)

        case .toolOutputAvailable(let toolCallId, let output, let providerExecuted,
                                  let providerMetadata, let toolMetadata, let dynamic, let preliminary):
            try container.encode("tool-output-available", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(output, forKey: .output)
            try container.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
            try container.encodeIfPresent(toolMetadata, forKey: .toolMetadata)
            try container.encodeIfPresent(dynamic, forKey: .dynamic)
            try container.encodeIfPresent(preliminary, forKey: .preliminary)

        case .toolOutputError(let toolCallId, let errorText, let providerExecuted,
                              let providerMetadata, let toolMetadata, let dynamic):
            try container.encode("tool-output-error", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(errorText, forKey: .errorText)
            try container.encodeIfPresent(providerExecuted, forKey: .providerExecuted)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)
            try container.encodeIfPresent(toolMetadata, forKey: .toolMetadata)
            try container.encodeIfPresent(dynamic, forKey: .dynamic)

        case .toolOutputDenied(let toolCallId):
            try container.encode("tool-output-denied", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)

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

        case .file(let url, let mediaType, let providerMetadata):
            try container.encode("file", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encodeIfPresent(providerMetadata, forKey: .providerMetadata)

        case .data(let name, let id, let data, let transient):
            try container.encode("data-\(name)", forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(transient, forKey: .transient)

        case .finishStep:
            try container.encode("finish-step", forKey: .type)

        case .finish(let finishReason, let messageMetadata):
            try container.encode("finish", forKey: .type)
            try container.encodeIfPresent(finishReason, forKey: .finishReason)
            try container.encodeIfPresent(messageMetadata, forKey: .messageMetadata)

        case .abort(let reason):
            try container.encode("abort", forKey: .type)
            try container.encodeIfPresent(reason, forKey: .reason)

        case .error(let errorText):
            try container.encode("error", forKey: .type)
            try container.encode(errorText, forKey: .errorText)

        case .messageMetadata(let messageMetadata):
            try container.encode("message-metadata", forKey: .type)
            try container.encode(messageMetadata, forKey: .messageMetadata)

        case .unknown:
            // Handled above before the keyed container was created.
            break
        }
    }

    // MARK: - Helpers

    /// Extracts the `<name>` from a `data-<name>` chunk type, or `nil` if `type` is not a data chunk.
    private static func dataChunkName(from type: String) -> String? {
        let prefix = "data-"
        guard type.hasPrefix(prefix), type.count > prefix.count else { return nil }
        return String(type.dropFirst(prefix.count))
    }
}
