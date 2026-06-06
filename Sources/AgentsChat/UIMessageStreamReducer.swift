import Agents
import Foundation

/// Folds a stream of ``UIMessageChunk`` values into a single, evolving assistant ``UIMessage``.
///
/// This reimplements the fold that the Vercel AI SDK performs inside `processUIMessageStream`
/// (see `node_modules/ai/src/ui/process-ui-message-stream.ts`) without depending on the AI SDK.
/// It owns one in-progress assistant message and mutates it in place as chunks arrive, tracking
/// the bookkeeping the AI SDK keeps in `StreamingUIMessageState`:
///
/// - `activeTextParts` / `activeReasoningParts`: text/reasoning parts currently streaming, keyed
///   by the chunk `id`, so deltas append to the right part and `*-end` closes it.
/// - `partialToolCalls`: accumulated input-delta text for each `toolCallId`, parsed into a partial
///   ``JSONValue`` so a tool part's `input` updates as the call streams in.
///
/// The reducer is a pure value type: feed it chunks with ``apply(_:)`` and read the assembled
/// ``message`` and ``isDone``. This makes the fold trivially unit-testable in isolation from any
/// network or transport.
///
/// ## Leniency vs. the AI SDK
/// The AI SDK throws (`UIMessageStreamError`) when it receives a delta/output chunk for a part it
/// has never seen (e.g. a `text-delta` with no preceding `text-start`). A client SDK that may
/// attach mid-stream during stream resumption should not crash on a gap, so this reducer instead
/// lazily creates the missing part and continues. In the well-formed (start → delta → end) case
/// the assembled message is identical to the AI SDK's.
public struct UIMessageStreamReducer: Sendable {

    // MARK: - Public state

    /// The assistant message assembled from the chunks applied so far.
    public private(set) var message: UIMessage

    /// Whether a `finish` chunk has been applied (the assistant turn is complete).
    public private(set) var isDone: Bool = false

    /// The most recent stream-level error reported via an `error` chunk, if any.
    ///
    /// The AI SDK forwards `error` chunks to its `onError` handler rather than mutating the
    /// message; this reducer surfaces the text here so callers can react without a side channel.
    public private(set) var errorText: String?

    /// The finish reason from the terminating `finish` chunk, if one was provided.
    public private(set) var finishReason: String?

    // MARK: - Private bookkeeping

    /// Indices into `message.parts` of text parts that are still streaming, keyed by chunk `id`.
    private var activeTextParts: [String: Int] = [:]

    /// Indices into `message.parts` of reasoning parts that are still streaming, keyed by chunk `id`.
    private var activeReasoningParts: [String: Int] = [:]

    /// Accumulated state for a tool call whose input is still streaming in, keyed by `toolCallId`.
    private struct PartialToolCall {
        var text: String = ""
        var toolName: String
        var dynamic: Bool
        var title: String?
        var toolMetadata: JSONValue?
    }

    private var partialToolCalls: [String: PartialToolCall] = [:]

    // MARK: - Init

    /// Creates a reducer seeded with a fresh assistant message.
    ///
    /// - Parameter messageId: The id to give the in-progress assistant message. A `start` chunk
    ///   carrying a `messageId` will override this; if you have no id up front, pass a generated
    ///   one (e.g. ``newUUIDLower()``). Defaults to a generated UUID.
    public init(messageId: String = newUUIDLower()) {
        self.message = UIMessage(id: messageId, role: .assistant, metadata: nil, parts: [])
    }

    // MARK: - Apply

    /// Applies a single streaming chunk, mutating ``message`` (and possibly ``isDone`` /
    /// ``errorText`` / ``finishReason``) to reflect it.
    ///
    /// Chunks are expected in stream order. Unknown chunk types, source/file parts that carry no
    /// streaming state, and `abort` are appended or recorded as appropriate but never throw.
    public mutating func apply(_ chunk: UIMessageChunk) {
        switch chunk {
        case let .start(messageId, messageMetadata):
            if let messageId { message.id = messageId }
            updateMessageMetadata(messageMetadata)

        case .startStep:
            message.parts.append(.stepStart)

        case let .textStart(id, providerMetadata):
            let part = UIMessagePart.text(text: "", state: .streaming, providerMetadata: providerMetadata)
            activeTextParts[id] = message.parts.count
            message.parts.append(part)

        case let .textDelta(id, delta, providerMetadata):
            let index = textPartIndex(for: id)
            if case let .text(text, _, existingMetadata) = message.parts[index] {
                message.parts[index] = .text(
                    text: text + delta,
                    state: .streaming,
                    providerMetadata: providerMetadata ?? existingMetadata
                )
            }

        case let .textEnd(id, providerMetadata):
            let index = textPartIndex(for: id)
            if case let .text(text, _, existingMetadata) = message.parts[index] {
                message.parts[index] = .text(
                    text: text,
                    state: .done,
                    providerMetadata: providerMetadata ?? existingMetadata
                )
            }
            activeTextParts[id] = nil

        case let .reasoningStart(id, providerMetadata):
            let part = UIMessagePart.reasoning(text: "", state: .streaming, providerMetadata: providerMetadata)
            activeReasoningParts[id] = message.parts.count
            message.parts.append(part)

        case let .reasoningDelta(id, delta, providerMetadata):
            let index = reasoningPartIndex(for: id)
            if case let .reasoning(text, _, existingMetadata) = message.parts[index] {
                message.parts[index] = .reasoning(
                    text: text + delta,
                    state: .streaming,
                    providerMetadata: providerMetadata ?? existingMetadata
                )
            }

        case let .reasoningEnd(id, providerMetadata):
            let index = reasoningPartIndex(for: id)
            if case let .reasoning(text, _, existingMetadata) = message.parts[index] {
                message.parts[index] = .reasoning(
                    text: text,
                    state: .done,
                    providerMetadata: providerMetadata ?? existingMetadata
                )
            }
            activeReasoningParts[id] = nil

        case let .file(url, mediaType, providerMetadata):
            message.parts.append(.file(mediaType: mediaType, filename: nil, url: url, providerMetadata: providerMetadata))

        case let .sourceUrl(sourceId, url, title, providerMetadata):
            message.parts.append(.sourceUrl(sourceId: sourceId, url: url, title: title, providerMetadata: providerMetadata))

        case let .sourceDocument(sourceId, mediaType, title, filename, providerMetadata):
            message.parts.append(
                .sourceDocument(
                    sourceId: sourceId,
                    mediaType: mediaType,
                    title: title,
                    filename: filename,
                    providerMetadata: providerMetadata
                )
            )

        case let .toolInputStart(toolCallId, toolName, providerExecuted, providerMetadata, toolMetadata, dynamic, title):
            let isDynamic = dynamic ?? false
            partialToolCalls[toolCallId] = PartialToolCall(
                text: "",
                toolName: toolName,
                dynamic: isDynamic,
                title: title,
                toolMetadata: toolMetadata
            )
            updateToolPart(
                toolCallId: toolCallId,
                toolName: toolName,
                dynamic: isDynamic,
                state: .inputStreaming,
                input: nil,
                providerExecuted: providerExecuted,
                title: title,
                toolMetadata: toolMetadata,
                providerMetadata: providerMetadata
            )

        case let .toolInputDelta(toolCallId, inputTextDelta):
            guard var partial = partialToolCalls[toolCallId] else {
                // No prior tool-input-start: nothing to accumulate against. Be lenient and skip.
                break
            }
            partial.text += inputTextDelta
            partialToolCalls[toolCallId] = partial
            updateToolPart(
                toolCallId: toolCallId,
                toolName: partial.toolName,
                dynamic: partial.dynamic,
                state: .inputStreaming,
                input: Self.parsePartialJSON(partial.text),
                providerExecuted: nil,
                title: partial.title,
                toolMetadata: partial.toolMetadata,
                providerMetadata: nil
            )

        case let .toolInputAvailable(toolCallId, toolName, input, providerExecuted, providerMetadata, toolMetadata, dynamic, title):
            updateToolPart(
                toolCallId: toolCallId,
                toolName: toolName,
                dynamic: isDynamicTool(toolCallId: toolCallId, fallback: dynamic ?? false),
                state: .inputAvailable,
                input: input,
                providerExecuted: providerExecuted,
                title: title,
                toolMetadata: toolMetadata,
                providerMetadata: providerMetadata
            )

        case let .toolInputError(toolCallId, toolName, input, providerExecuted, providerMetadata, toolMetadata, dynamic, errorText, _):
            // Honour an existing part's kind so we update in place rather than duplicating it.
            let isDynamic = isDynamicTool(toolCallId: toolCallId, fallback: dynamic ?? false)
            updateToolPart(
                toolCallId: toolCallId,
                toolName: toolName,
                dynamic: isDynamic,
                state: .outputError,
                // Static tools store the failed input under `rawInput`; dynamic tools keep it as `input`.
                input: isDynamic ? input : nil,
                rawInput: isDynamic ? nil : input,
                providerExecuted: providerExecuted,
                errorText: errorText,
                toolMetadata: toolMetadata,
                providerMetadata: providerMetadata
            )

        case let .toolApprovalRequest(approvalId, toolCallId):
            mutateToolInvocation(toolCallId: toolCallId) { invocation in
                invocation.state = .approvalRequested
                invocation.approval = ToolInvocation.Approval(id: approvalId)
            }

        case let .toolOutputDenied(toolCallId):
            mutateToolInvocation(toolCallId: toolCallId) { invocation in
                invocation.state = .outputDenied
            }

        case let .toolOutputAvailable(toolCallId, output, providerExecuted, providerMetadata, _, _, preliminary):
            mutateToolInvocation(toolCallId: toolCallId) { invocation in
                invocation.state = .outputAvailable
                invocation.output = output
                invocation.preliminary = preliminary
                if let providerExecuted { invocation.providerExecuted = providerExecuted }
                if let providerMetadata { invocation.resultProviderMetadata = providerMetadata }
            }

        case let .toolOutputError(toolCallId, errorText, providerExecuted, providerMetadata, _, _):
            mutateToolInvocation(toolCallId: toolCallId) { invocation in
                invocation.state = .outputError
                invocation.errorText = errorText
                if let providerExecuted { invocation.providerExecuted = providerExecuted }
                if let providerMetadata { invocation.resultProviderMetadata = providerMetadata }
            }

        case let .data(name, id, data, transient):
            // Transient data parts are not added to the message (they are event-only in the AI SDK).
            if transient == true { break }
            if let id, let index = dataPartIndex(name: name, id: id) {
                message.parts[index] = .data(name: name, id: id, value: data)
            } else {
                message.parts.append(.data(name: name, id: id, value: data))
            }

        case .finishStep:
            // A step boundary resets which text/reasoning parts are considered "active".
            activeTextParts.removeAll()
            activeReasoningParts.removeAll()

        case let .finish(finishReason, messageMetadata):
            if let finishReason { self.finishReason = finishReason }
            updateMessageMetadata(messageMetadata)
            isDone = true

        case let .abort(reason):
            // Treat an abort as terminal; record the reason as the error text if present.
            if let reason { self.errorText = reason }
            isDone = true

        case let .error(errorText):
            self.errorText = errorText

        case let .messageMetadata(messageMetadata):
            updateMessageMetadata(messageMetadata)

        case .unknown:
            // Forward-compatible: an unrecognised chunk contributes nothing to the assembled message.
            break
        }
    }

    // MARK: - Text / reasoning part lookup

    /// Returns the index of the active text part for `id`, creating an empty streaming part if the
    /// `text-start` was missed (lenient resumption handling).
    private mutating func textPartIndex(for id: String) -> Int {
        if let index = activeTextParts[id] { return index }
        let index = message.parts.count
        message.parts.append(.text(text: "", state: .streaming, providerMetadata: nil))
        activeTextParts[id] = index
        return index
    }

    /// Returns the index of the active reasoning part for `id`, creating one if `reasoning-start`
    /// was missed.
    private mutating func reasoningPartIndex(for id: String) -> Int {
        if let index = activeReasoningParts[id] { return index }
        let index = message.parts.count
        message.parts.append(.reasoning(text: "", state: .streaming, providerMetadata: nil))
        activeReasoningParts[id] = index
        return index
    }

    // MARK: - Data part lookup

    /// Finds the index of an existing `data-<name>` part with a matching `id`, for in-place update.
    private func dataPartIndex(name: String, id: String) -> Int? {
        message.parts.firstIndex { part in
            if case let .data(partName, partId, _) = part {
                return partName == name && partId == id
            }
            return false
        }
    }

    // MARK: - Tool part management

    /// Locates an existing tool part for `toolCallId` and reports whether it is a dynamic-tool part.
    private func isDynamicTool(toolCallId: String, fallback: Bool) -> Bool {
        for part in message.parts {
            switch part {
            case let .tool(_, invocation) where invocation.toolCallId == toolCallId:
                return false
            case let .dynamicTool(_, invocation) where invocation.toolCallId == toolCallId:
                return true
            default:
                continue
            }
        }
        return fallback
    }

    /// Finds the index of the tool (static or dynamic) part for `toolCallId`.
    private func toolPartIndex(toolCallId: String) -> Int? {
        message.parts.firstIndex { part in
            switch part {
            case let .tool(_, invocation): return invocation.toolCallId == toolCallId
            case let .dynamicTool(_, invocation): return invocation.toolCallId == toolCallId
            default: return false
            }
        }
    }

    /// Creates or updates a static/dynamic tool part for `toolCallId`, advancing its
    /// ``ToolInvocation`` through the state machine. Mirrors the AI SDK `updateToolPart` /
    /// `updateDynamicToolPart` helpers.
    private mutating func updateToolPart(
        toolCallId: String,
        toolName: String,
        dynamic: Bool,
        state: ToolInvocation.State,
        input: JSONValue? = nil,
        rawInput: JSONValue? = nil,
        output: JSONValue? = nil,
        providerExecuted: Bool? = nil,
        errorText: String? = nil,
        preliminary: Bool? = nil,
        title: String? = nil,
        toolMetadata: JSONValue? = nil,
        providerMetadata: JSONValue? = nil
    ) {
        let isResultState = state == .outputAvailable || state == .outputError

        if let index = toolPartIndex(toolCallId: toolCallId) {
            // Update the existing invocation in place, preserving its kind (static vs dynamic).
            var invocation = currentInvocation(at: index)
            invocation.state = state
            invocation.input = input
            invocation.output = output
            invocation.errorText = errorText
            invocation.rawInput = rawInput
            invocation.preliminary = preliminary
            if let title { invocation.title = title }
            if let toolMetadata { invocation.toolMetadata = toolMetadata }
            // Once set, providerExecuted persists across streaming updates.
            invocation.providerExecuted = providerExecuted ?? invocation.providerExecuted
            if let providerMetadata {
                if isResultState {
                    invocation.resultProviderMetadata = providerMetadata
                } else {
                    invocation.callProviderMetadata = providerMetadata
                }
            }
            replaceInvocation(at: index, with: invocation, toolName: toolName, dynamic: dynamic)
        } else {
            // Create a fresh part.
            var invocation = ToolInvocation(toolCallId: toolCallId, state: state)
            invocation.title = title
            invocation.toolMetadata = toolMetadata
            invocation.input = input
            invocation.rawInput = rawInput
            invocation.output = output
            invocation.errorText = errorText
            invocation.providerExecuted = providerExecuted
            invocation.preliminary = preliminary
            if let providerMetadata {
                if isResultState {
                    invocation.resultProviderMetadata = providerMetadata
                } else {
                    invocation.callProviderMetadata = providerMetadata
                }
            }
            if dynamic {
                message.parts.append(.dynamicTool(toolName: toolName, invocation: invocation))
            } else {
                message.parts.append(.tool(name: toolName, invocation: invocation))
            }
        }
    }

    /// Reads the ``ToolInvocation`` at `index` (assumes the part is a tool or dynamic-tool part).
    private func currentInvocation(at index: Int) -> ToolInvocation {
        switch message.parts[index] {
        case let .tool(_, invocation): return invocation
        case let .dynamicTool(_, invocation): return invocation
        default:
            // Unreachable in practice; toolPartIndex only returns tool-part indices.
            return ToolInvocation(toolCallId: "", state: .inputStreaming)
        }
    }

    /// Writes `invocation` back to the part at `index`, keeping its existing kind/name unless a
    /// dynamic part needs its `toolName` refreshed.
    private mutating func replaceInvocation(
        at index: Int,
        with invocation: ToolInvocation,
        toolName: String,
        dynamic: Bool
    ) {
        switch message.parts[index] {
        case let .tool(name, _):
            message.parts[index] = .tool(name: name, invocation: invocation)
        case .dynamicTool:
            // Dynamic tools keep their toolName updated from each chunk.
            message.parts[index] = .dynamicTool(toolName: toolName, invocation: invocation)
        default:
            if dynamic {
                message.parts[index] = .dynamicTool(toolName: toolName, invocation: invocation)
            } else {
                message.parts[index] = .tool(name: toolName, invocation: invocation)
            }
        }
    }

    /// Mutates the existing ``ToolInvocation`` for `toolCallId` in place.
    ///
    /// If no part exists yet (e.g. an output chunk arrived without a preceding input chunk during
    /// resumption), a placeholder static tool part is created so the output is not lost. This is
    /// the lenient counterpart to the AI SDK, which throws when the invocation is missing.
    private mutating func mutateToolInvocation(
        toolCallId: String,
        _ body: (inout ToolInvocation) -> Void
    ) {
        if let index = toolPartIndex(toolCallId: toolCallId) {
            var invocation = currentInvocation(at: index)
            body(&invocation)
            switch message.parts[index] {
            case let .tool(name, _):
                message.parts[index] = .tool(name: name, invocation: invocation)
            case let .dynamicTool(name, _):
                message.parts[index] = .dynamicTool(toolName: name, invocation: invocation)
            default:
                break
            }
        } else {
            var invocation = ToolInvocation(toolCallId: toolCallId, state: .inputAvailable)
            body(&invocation)
            message.parts.append(.tool(name: "", invocation: invocation))
        }
    }

    // MARK: - Metadata

    /// Deep-merges `metadata` into the message's existing metadata, matching the AI SDK's
    /// `mergeObjects` semantics (recursive object merge; arrays/primitives replace).
    private mutating func updateMessageMetadata(_ metadata: JSONValue?) {
        guard let metadata else { return }
        message.metadata = Self.mergeObjects(message.metadata, metadata)
    }

    // MARK: - JSON helpers

    /// Deeply merges two ``JSONValue`` metadata payloads, port of the AI SDK `mergeObjects`.
    ///
    /// - Nested objects merge recursively; `overrides` wins on key conflicts.
    /// - Arrays and primitives are replaced wholesale.
    /// - A `nil` on either side yields the other.
    static func mergeObjects(_ base: JSONValue?, _ overrides: JSONValue?) -> JSONValue? {
        guard let base else { return overrides }
        guard let overrides else { return base }

        guard case let .object(baseObject) = base, case let .object(overrideObject) = overrides else {
            return overrides
        }

        var result = baseObject
        for (key, overrideValue) in overrideObject {
            if case .object = overrideValue, case .object = baseObject[key] {
                result[key] = mergeObjects(baseObject[key], overrideValue)
            } else {
                result[key] = overrideValue
            }
        }
        return .object(result)
    }

    /// Best-effort parse of accumulated tool-input-delta text into a ``JSONValue``.
    ///
    /// The AI SDK uses `parsePartialJson`, which recovers a value even from an incomplete JSON
    /// fragment. Foundation has no partial parser, so this attempts a strict parse of the text as
    /// it stands and returns `nil` while the fragment is still incomplete. The final
    /// `tool-input-available` chunk supplies the authoritative, complete input, so a transient
    /// `nil` during streaming does not affect the assembled result.
    static func parsePartialJSON(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
