import Agents
import Foundation
import Observation

/// The lifecycle status of a ``ChatSession``.
///
/// Mirrors the Vercel AI SDK `useChat` `status` union
/// (`"ready" | "submitted" | "streaming" | "error"`). The raw values are not sent
/// on the wire; this is a client-side UI signal.
public enum ChatStatus: String, Sendable, Hashable {
    /// Idle: no request is in flight and the last turn (if any) completed.
    case ready
    /// A request has been submitted and the session is awaiting the first chunk.
    case submitted
    /// Assistant chunks are actively streaming in.
    case streaming
    /// The last turn failed. ``ChatSession/error`` carries the failure.
    case error
}

/// The terminal state to record for a tool result supplied via
/// ``ChatSession/addToolOutput(toolCallId:output:state:errorText:)``.
///
/// Mirrors the `state` field accepted by `addToolOutput` in the reference
/// (`"output-available" | "output-error"`).
public enum ToolResultState: Sendable, Hashable {
    /// The tool produced a successful output (`"output-available"`).
    case available
    /// The tool failed; ``ChatSession`` will not auto-continue (`"output-error"`).
    case error

    /// The wire-level tool-result state this maps to.
    var wireState: ChatToolResultState {
        switch self {
        case .available: return .outputAvailable
        case .error: return .outputError
        }
    }
}

/// A client-side tool call awaiting resolution.
///
/// Delivered to ``ChatSession/onToolCall`` when the model emits a tool call in the
/// `input-available` state for a tool the server cannot execute. The handler should
/// produce a result and report it via
/// ``ChatSession/addToolOutput(toolCallId:output:state:errorText:)``. Mirrors the
/// `toolCall` payload of the reference `onToolCall` callback.
public struct ToolCall: Sendable, Hashable {
    /// The id of the tool call.
    public let toolCallId: String
    /// The name of the tool being invoked.
    public let toolName: String
    /// The tool's input arguments, if any.
    public let input: JSONValue?

    public init(toolCallId: String, toolName: String, input: JSONValue?) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.input = input
    }
}

/// Configuration for a ``ChatSession``.
///
/// All options have sensible defaults matching the reference `useAgentChat`
/// behaviour, so `ChatOptions()` is the common case.
public struct ChatOptions: Sendable {
    /// Whether the server should automatically continue the conversation after a
    /// client-side tool result or approval (merging the continuation into the same
    /// assistant message). Defaults to `true`. An `output-error` result never
    /// auto-continues regardless of this flag (matching the reference).
    public var autoContinueAfterToolResult: Bool

    /// Whether to attempt stream resumption when the connection re-opens.
    /// Defaults to `true`.
    public var resume: Bool

    /// Whether a generic client-side abort should cancel the durable server turn.
    /// Defaults to `false`: client cleanup is local-only so the server turn keeps
    /// running and can be resumed. Explicit ``ChatSession/stop()`` always cancels.
    public var cancelOnClientAbort: Bool

    /// Extra top-level fields merged into every chat request body. Available to the
    /// server in `onChatMessage` via `options.body`. Mirrors the reference `body`
    /// option (static form).
    public var body: [String: JSONValue]

    /// Overrides history hydration on init. When provided, it is awaited instead of
    /// the default `GET {httpBaseURL}/get-messages` fetch. Returning an empty array
    /// hydrates nothing. Mirrors the reference `getInitialMessages` option; pass a
    /// closure returning `[]` to disable the fetch entirely.
    public var getInitialMessages: (@Sendable () async -> [UIMessage])?

    /// Creates chat options.
    /// - Parameters:
    ///   - autoContinueAfterToolResult: See ``autoContinueAfterToolResult``.
    ///   - resume: See ``resume``.
    ///   - cancelOnClientAbort: See ``cancelOnClientAbort``.
    ///   - body: See ``body``.
    ///   - getInitialMessages: See ``getInitialMessages``.
    public init(
        autoContinueAfterToolResult: Bool = true,
        resume: Bool = true,
        cancelOnClientAbort: Bool = false,
        body: [String: JSONValue] = [:],
        getInitialMessages: (@Sendable () async -> [UIMessage])? = nil
    ) {
        self.autoContinueAfterToolResult = autoContinueAfterToolResult
        self.resume = resume
        self.cancelOnClientAbort = cancelOnClientAbort
        self.body = body
        self.getInitialMessages = getInitialMessages
    }
}

/// A `@MainActor`, `@Observable` chat facade over an agent connection.
///
/// `ChatSession` is the Swift port of the reference `useAgentChat` hook
/// (`packages/ai-chat/src/react.tsx`). It owns the observable chat surface SwiftUI
/// reads directly — ``messages``, ``status``, ``error`` — and drives the underlying
/// ``ChatTransport`` request / resume / tool-continuation state machine:
///
/// ```swift
/// let client = AgentClient(
///     .init(agent: "ChatAgent", name: "room-123", host: "my-worker.workers.dev"),
///     state: ChatState.self
/// )
/// client.connect()
/// let session = ChatSession(client: client)
/// session.sendMessage("Hello!")
/// // SwiftUI: List(session.messages, id: \.id) { … } updates automatically.
/// ```
///
/// On init it hydrates history from the agent's `/get-messages` endpoint, subscribes
/// to inbound frames to reconcile server-pushed message lists and the stream-resume
/// handshake, and exposes `sendMessage` / `stop` / `clearHistory` plus tool result
/// and approval entry points.
///
/// Client-executed tools (the reference `tools` option) are registered via
/// ``registerTool(_:)`` or the `tools:` init parameter: their schemas are sent in
/// every chat request body, and when the model calls one the session runs its
/// `execute` closure and reports the output automatically. Unregistered client tool
/// calls fall back to ``onToolCall``.
@MainActor
@Observable
public final class ChatSession {

    // MARK: - Observable state

    /// The current chat messages, in display order. Updated optimistically on send,
    /// during streaming, and on server-pushed `cf_agent_chat_messages` frames.
    public private(set) var messages: [UIMessage]

    /// The session lifecycle status. SwiftUI views reading this re-render on changes.
    public private(set) var status: ChatStatus

    /// The error from the most recent failed turn, if ``status`` is ``ChatStatus/error``.
    public private(set) var error: Error?

    /// Whether any stream is active: a client-initiated turn (``ChatStatus/streaming``),
    /// a server-initiated stream (resume / tool continuation), or a client tool call
    /// still executing. The last covers the gap where the server has ended its stream
    /// at a client tool call but the local `execute` / ``onToolCall`` work is still in
    /// flight — without it consumers would see a "nothing happening" window. Mirrors
    /// the reference `isStreaming` / `hasPendingClientToolCalls` derivation.
    public var isStreaming: Bool {
        status == .streaming || serverStreaming || !pendingClientToolCallIds.isEmpty
    }

    /// Whether the current activity is a server-pushed tool continuation (the server
    /// auto-continuing after `addToolOutput` / `addToolApprovalResponse`) rather than
    /// a fresh user submission. Mirrors the reference `isToolContinuation` flag.
    public private(set) var isToolContinuation: Bool

    // MARK: - Callbacks

    /// Invoked when the model emits a client-side tool call in the `input-available`
    /// state (a tool without a server-side `execute`) whose name does not match a
    /// registered ``ClientTool`` — registered tools are executed automatically and
    /// never reach this handler. The handler should resolve the call via
    /// ``addToolOutput(toolCallId:output:state:errorText:)``. Mirrors the reference
    /// `onToolCall`.
    public var onToolCall: ((ToolCall) async -> Void)?

    // MARK: - Dependencies

    @ObservationIgnored private let client: any AgentConnectionProviding
    @ObservationIgnored private let transport: ChatTransport
    @ObservationIgnored private let options: ChatOptions

    // MARK: - Private bookkeeping

    /// `true` while a server-initiated stream (resume or tool continuation) is active.
    /// Backs the streaming portion of ``isStreaming``.
    @ObservationIgnored private var serverStreaming: Bool = false

    /// The id of the assistant message currently being streamed by an active turn,
    /// used to preserve it across server-pushed `cf_agent_chat_messages` reconciles.
    @ObservationIgnored private var streamingAssistantId: String?

    /// The task running the inbound-frame reconcile loop (message lists, clear,
    /// resume handshake). Cancelled on ``stop()`` of the session lifecycle.
    @ObservationIgnored private var inboundTask: Task<Void, Never>?

    /// The task driving the active client-initiated turn, cancelled by ``stop()``.
    @ObservationIgnored private var activeTurn: Task<Void, Never>?

    /// Tool-call ids already dispatched to a registered tool or ``onToolCall``, to
    /// avoid re-firing as the same assistant message re-renders. Mirrors the
    /// reference `processedToolCalls`.
    @ObservationIgnored private var processedToolCalls: Set<String> = []

    /// The registered client-executed tools, in registration order (preserved when
    /// serializing schemas). Looked up by name on dispatch; replaced by name on
    /// re-registration. Mirrors the reference `tools` option.
    @ObservationIgnored private var registeredTools: [ClientTool]

    /// Tool-call ids whose client-side work (registered `execute` or ``onToolCall``)
    /// is still in flight. Observable (not ignored) so ``isStreaming`` re-derives as
    /// work starts and finishes. Mirrors the reference `pendingOnToolCallIds`.
    private var pendingClientToolCallIds: Set<String> = []

    // MARK: - Init

    /// Creates a chat session over an agent connection and begins history hydration.
    ///
    /// - Parameters:
    ///   - client: The agent connection (typically an `AgentClient`).
    ///   - options: Chat configuration. Defaults to ``ChatOptions/init(autoContinueAfterToolResult:resume:cancelOnClientAbort:body:getInitialMessages:)``.
    ///   - tools: Client-executed tools to register up front. More can be added later
    ///     via ``registerTool(_:)``.
    public init(
        client: any AgentConnectionProviding,
        options: ChatOptions = .init(),
        tools: [ClientTool] = []
    ) {
        self.client = client
        self.options = options
        self.registeredTools = tools
        self.transport = ChatTransport(
            connection: client,
            cancelOnClientAbort: options.cancelOnClientAbort
        )
        self.messages = []
        self.status = .ready
        self.error = nil
        self.isToolContinuation = false

        startInboundLoop()
        hydrateHistory()
    }

    deinit {
        inboundTask?.cancel()
        activeTurn?.cancel()
    }

    // MARK: - History hydration

    /// Fetches initial history and merges it with any local messages.
    ///
    /// Uses ``ChatOptions/getInitialMessages`` when provided, otherwise performs the
    /// default `GET {httpBaseURL}/get-messages` fetch. Hydrated messages missing from
    /// the current list are prepended (matching `prependMissingHydratedMessages`);
    /// existing local copies win by id because they may carry newer streamed state.
    private func hydrateHistory() {
        let override = options.getInitialMessages
        let httpBase = client.httpBaseURL

        Task { @MainActor [weak self] in
            let hydrated: [UIMessage]
            if let override {
                hydrated = await override()
            } else {
                hydrated = await Self.defaultGetInitialMessages(httpBase: httpBase)
            }
            guard let self else { return }
            self.messages = Self.prependMissingHydratedMessages(
                hydrated: hydrated,
                current: self.messages
            )
        }
    }

    /// Default history fetch: `GET {httpBase}/get-messages`, parsing the body as
    /// `[UIMessage]`. An empty/whitespace body, a non-OK status, or any error yields
    /// `[]`. Mirrors `defaultGetInitialMessagesFetch`.
    static func defaultGetInitialMessages(httpBase: URL?) async -> [UIMessage] {
        guard let httpBase else { return [] }
        let url = httpBase.appendingPathComponent("get-messages")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            let trimmed = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return (try? JSONDecoder().decode([UIMessage].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    /// Prepends hydrated messages whose ids are not already present locally.
    ///
    /// Port of `prependMissingHydratedMessages`: when there are no local messages the
    /// hydrated set is used verbatim; otherwise only hydrated messages with ids not in
    /// the current list are prepended (preserving local copies for matching ids).
    static func prependMissingHydratedMessages(
        hydrated: [UIMessage],
        current: [UIMessage]
    ) -> [UIMessage] {
        guard !current.isEmpty else { return hydrated }
        let currentIds = Set(current.map(\.id))
        let missing = hydrated.filter { !currentIds.contains($0.id) }
        guard !missing.isEmpty else { return current }
        return missing + current
    }

    // MARK: - Sending

    /// Sends a plain-text user message and drives the assistant response stream.
    ///
    /// Wraps `text` in a single-text-part user ``UIMessage`` with a generated id, then
    /// behaves like ``sendMessage(_:)``.
    public func sendMessage(_ text: String) {
        let message = UIMessage(
            id: newUUIDLower(),
            role: .user,
            parts: [.text(text: text, state: nil, providerMetadata: nil)]
        )
        sendMessage(message)
    }

    /// Appends `message` to the conversation and drives the assistant response.
    ///
    /// Appends the user message, sets ``status`` to ``ChatStatus/submitted``, opens a
    /// transport stream with ``ChatTrigger/submitMessage``, folds the resulting chunks
    /// into a streaming assistant message (``status`` → ``ChatStatus/streaming`` once
    /// chunks arrive), and finishes with ``ChatStatus/ready`` on the `done` chunk or
    /// ``ChatStatus/error`` on failure.
    public func sendMessage(_ message: UIMessage) {
        messages.append(message)
        startTurn(trigger: .submitMessage)
    }

    /// Begins a turn: submits the current conversation and consumes its chunk stream.
    private func startTurn(trigger: ChatTrigger) {
        error = nil
        status = .submitted

        let outgoing = messages
        var extraBody = options.body
        // Registered client tool schemas ride in the request body as the top-level
        // `clientTools` field, overriding any body-provided value (matching the
        // reference `prepareBody`, which assigns after spreading the body option).
        if !registeredTools.isEmpty {
            extraBody["clientTools"] = ClientTool.schemaJSON(of: registeredTools)
        }

        activeTurn?.cancel()
        activeTurn = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.transport.send(
                    messages: outgoing,
                    trigger: trigger,
                    extraBody: extraBody
                )
                await self.consume(stream: stream, isContinuation: false)
            } catch is CancellationError {
                self.finishCancelled()
            } catch {
                self.finishFailed(error)
            }
        }
    }

    /// Consumes an assistant chunk stream, folding it into a streaming assistant
    /// message via ``UIMessageStreamReducer`` and applying it to ``messages`` after
    /// each chunk. Shared by client-initiated turns and tool continuations.
    private func consume(
        stream: AsyncThrowingStream<UIMessageChunk, Error>,
        isContinuation: Bool
    ) async {
        var reducer = UIMessageStreamReducer()
        var started = false

        do {
            for try await chunk in stream {
                reducer.apply(chunk)

                if !started {
                    started = true
                    status = .streaming
                    if isContinuation {
                        serverStreaming = true
                    }
                }

                let assistant = reducer.message
                streamingAssistantId = assistant.id
                upsertAssistant(assistant)
                dispatchPendingToolCalls(in: assistant)

                if reducer.isDone { break }
            }

            if let text = reducer.errorText {
                finishFailed(ChatTransportError.stream(text))
            } else {
                finishReady()
            }
        } catch is CancellationError {
            finishCancelled()
        } catch ChatTransportError.aborted {
            // Local abort (stop / client cleanup): the durable turn may continue, but
            // from the consumer's perspective the active stream is done.
            finishCancelled()
        } catch {
            finishFailed(error)
        }
    }

    /// Inserts or replaces the streaming assistant message by id, appending it when
    /// new. Mirrors the AI SDK behaviour of growing a single assistant message tail.
    private func upsertAssistant(_ assistant: UIMessage) {
        if let index = messages.firstIndex(where: { $0.id == assistant.id }) {
            messages[index] = assistant
        } else {
            messages.append(assistant)
        }
    }

    // MARK: - Turn completion

    private func finishReady() {
        status = .ready
        streamingAssistantId = nil
        serverStreaming = false
        isToolContinuation = false
        activeTurn = nil
    }

    private func finishFailed(_ error: Error) {
        self.error = error
        status = .error
        streamingAssistantId = nil
        serverStreaming = false
        isToolContinuation = false
        activeTurn = nil
    }

    private func finishCancelled() {
        // A cancelled stream is not an error: return to ready without surfacing one.
        if status != .error {
            status = .ready
        }
        streamingAssistantId = nil
        serverStreaming = false
        isToolContinuation = false
        activeTurn = nil
    }

    // MARK: - Stop / clear

    /// Cancels the active turn and any server stream.
    ///
    /// Cancels the local stream consumer and explicitly cancels the durable server
    /// turn (via `cf_agent_chat_request_cancel`) and any active tool continuation —
    /// matching the reference `stop()`, which always cancels the server turn.
    public func stop() {
        activeTurn?.cancel()
        activeTurn = nil
        Task { [transport] in
            await transport.cancelActiveServerTurn()
        }
        finishCancelled()
    }

    /// Clears chat history locally and on the server.
    ///
    /// Resets local state and sends `cf_agent_chat_clear`. Mirrors the reference
    /// `clearHistory`.
    public func clearHistory() {
        resetLocalState()
        sendFrame { try OutboundChatMessage.chatClear() }
    }

    /// Shared local reset for every history-wipe path (`clearHistory` and an inbound
    /// `cf_agent_chat_clear`). Mirrors `resetLocalChatState`.
    private func resetLocalState() {
        activeTurn?.cancel()
        activeTurn = nil
        messages = []
        status = .ready
        error = nil
        serverStreaming = false
        isToolContinuation = false
        streamingAssistantId = nil
        processedToolCalls.removeAll()
        pendingClientToolCallIds.removeAll()
    }

    // MARK: - Client tool registration

    /// Registers a client-executed tool, replacing any existing tool with the same
    /// name.
    ///
    /// Registered tool schemas are sent as the top-level `clientTools` field of every
    /// chat request body (and refreshed on every `cf_agent_tool_result`), so the
    /// server advertises them to the model. When the model calls one, the session
    /// executes ``ClientTool/execute`` and reports the output automatically —
    /// auto-continuing the turn. Mirrors the reference `useAgentChat` `tools` option.
    ///
    /// Tools registered mid-conversation take effect from the next request.
    public func registerTool(_ tool: ClientTool) {
        if let index = registeredTools.firstIndex(where: { $0.name == tool.name }) {
            registeredTools[index] = tool
        } else {
            registeredTools.append(tool)
        }
    }

    /// Registers a client-executed tool from its parts. See ``registerTool(_:)``.
    ///
    /// - Parameters:
    ///   - name: Unique tool name (replaces an existing registration of the same name).
    ///   - description: Human-readable description shown to the model.
    ///   - parameters: JSON-Schema object describing the tool input.
    ///   - execute: The tool implementation; its return value is the tool output.
    public func registerTool(
        name: String,
        description: String? = nil,
        parameters: JSONValue? = nil,
        execute: @escaping ClientTool.Execute
    ) {
        registerTool(
            ClientTool(
                name: name,
                description: description,
                parameters: parameters,
                execute: execute
            )
        )
    }

    /// Removes the registered client tool with `name`, if any. Takes effect from the
    /// next request; calls already dispatched still resolve.
    public func unregisterTool(name: String) {
        registeredTools.removeAll { $0.name == name }
    }

    /// The wire schemas of the registered tools, or `nil` when none are registered
    /// (so the field is omitted from frames entirely).
    private var registeredToolSchemas: [ChatClientTool]? {
        registeredTools.isEmpty ? nil : registeredTools.map(\.wireSchema)
    }

    // MARK: - Tool results / approvals

    /// Reports the output (or error) for a client-side tool call.
    ///
    /// Sends `cf_agent_tool_result { toolCallId, toolName, output, state?, errorText?,
    /// autoContinue }`, updates the local tool part in place, and — unless this is an
    /// `output-error` — kicks the server tool continuation. `autoContinue` is true by
    /// default (``ChatOptions/autoContinueAfterToolResult``) except for an
    /// `output-error`, which never auto-continues. Mirrors `sendToolOutputToServer` /
    /// `addToolOutput`.
    ///
    /// - Parameters:
    ///   - toolCallId: The id of the tool call being resolved.
    ///   - output: The tool output as a JSON value.
    ///   - state: Whether the result is a success or an error. Defaults to ``ToolResultState/available``.
    ///   - errorText: The error message when `state` is ``ToolResultState/error``.
    public func addToolOutput(
        toolCallId: String,
        output: JSONValue,
        state: ToolResultState = .available,
        errorText: String? = nil
    ) {
        let toolName = toolName(for: toolCallId) ?? ""
        let shouldAutoContinue = state == .error ? false : options.autoContinueAfterToolResult

        // The call is resolved from the client's perspective; stop counting it as
        // pending client-side work (no-op for ids not tracked).
        pendingClientToolCallIds.remove(toolCallId)

        sendFrame {
            try OutboundChatMessage.toolResult(
                toolCallId: toolCallId,
                toolName: toolName,
                output: output,
                state: state.wireState,
                errorText: errorText,
                autoContinue: shouldAutoContinue,
                // Refresh the server's persisted client tools on every result (the
                // client is the source of truth), matching `sendToolOutputToServer`.
                clientTools: registeredToolSchemas
            )
        }

        applyLocalToolResult(
            toolCallId: toolCallId,
            output: output,
            state: state,
            errorText: errorText
        )

        if shouldAutoContinue {
            startToolContinuation()
        }
    }

    /// Responds to a tool approval request.
    ///
    /// Sends `cf_agent_tool_approval { toolCallId, approved, autoContinue }`, updates
    /// the local tool part to `approval-responded`, and kicks the server tool
    /// continuation (approvals auto-continue for both approve and reject, matching the
    /// reference). Mirrors `sendToolApprovalToServer` /
    /// `addToolApprovalResponseAndNotifyServer`.
    public func addToolApprovalResponse(toolCallId: String, approved: Bool) {
        let autoContinue = options.autoContinueAfterToolResult

        sendFrame {
            try OutboundChatMessage.toolApproval(
                toolCallId: toolCallId,
                approved: approved,
                autoContinue: autoContinue
            )
        }

        applyLocalApproval(toolCallId: toolCallId, approved: approved)

        if autoContinue {
            startToolContinuation()
        }
    }

    /// Arms the transport to attach to the server-pushed continuation stream, then
    /// drives it through the reducer. Mirrors `startToolContinuation` →
    /// `expectToolContinuation` + `resumeStream`.
    private func startToolContinuation() {
        guard options.autoContinueAfterToolResult else { return }
        // A continuation is in flight from the consumer's perspective even before the
        // server announces it.
        isToolContinuation = true
        serverStreaming = true
        status = .submitted

        activeTurn?.cancel()
        activeTurn = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.transport.expectToolContinuation()
            guard let stream = await self.transport.reconnectToStream() else {
                // Server announced no continuation (resume-none / timeout).
                self.finishReady()
                return
            }
            await self.consume(stream: stream, isContinuation: true)
        }
    }

    // MARK: - Local tool-part updates

    /// Finds the tool name for `toolCallId` across the current messages.
    private func toolName(for toolCallId: String) -> String? {
        for message in messages {
            for part in message.parts {
                switch part {
                case let .tool(name, invocation) where invocation.toolCallId == toolCallId:
                    return name
                case let .dynamicTool(toolName, invocation) where invocation.toolCallId == toolCallId:
                    return toolName
                default:
                    continue
                }
            }
        }
        return nil
    }

    /// Applies a tool result to the matching local tool part for immediate UI feedback.
    private func applyLocalToolResult(
        toolCallId: String,
        output: JSONValue,
        state: ToolResultState,
        errorText: String?
    ) {
        mutateToolInvocation(toolCallId: toolCallId) { invocation in
            switch state {
            case .available:
                invocation.state = .outputAvailable
                invocation.output = output
                invocation.errorText = nil
            case .error:
                invocation.state = .outputError
                invocation.errorText = errorText
            }
        }
    }

    /// Applies an approval decision to the matching local tool part.
    private func applyLocalApproval(toolCallId: String, approved: Bool) {
        mutateToolInvocation(toolCallId: toolCallId) { invocation in
            invocation.state = .approvalResponded
            if var approval = invocation.approval {
                approval.approved = approved
                invocation.approval = approval
            } else {
                invocation.approval = ToolInvocation.Approval(id: toolCallId, approved: approved)
            }
        }
    }

    /// Mutates the ``ToolInvocation`` of the tool part for `toolCallId`, preserving the
    /// part's kind (static vs dynamic).
    private func mutateToolInvocation(
        toolCallId: String,
        _ body: (inout ToolInvocation) -> Void
    ) {
        for messageIndex in messages.indices {
            for partIndex in messages[messageIndex].parts.indices {
                switch messages[messageIndex].parts[partIndex] {
                case let .tool(name, invocation) where invocation.toolCallId == toolCallId:
                    var updated = invocation
                    body(&updated)
                    messages[messageIndex].parts[partIndex] = .tool(name: name, invocation: updated)
                    return
                case let .dynamicTool(toolName, invocation) where invocation.toolCallId == toolCallId:
                    var updated = invocation
                    body(&updated)
                    messages[messageIndex].parts[partIndex] = .dynamicTool(toolName: toolName, invocation: updated)
                    return
                default:
                    continue
                }
            }
        }
    }

    // MARK: - Client tool dispatch

    /// Dispatches `input-available` client tool calls on the latest assistant message,
    /// once each: calls matching a registered ``ClientTool`` are executed
    /// automatically; the rest go to ``onToolCall``. Mirrors the reference automatic
    /// tool resolution and `onToolCall` effects.
    private func dispatchPendingToolCalls(in assistant: UIMessage) {
        guard assistant.role == .assistant,
              onToolCall != nil || !registeredTools.isEmpty
        else { return }

        for part in assistant.parts {
            let invocation: ToolInvocation
            let toolName: String
            switch part {
            case let .tool(name, inv):
                invocation = inv
                toolName = name
            case let .dynamicTool(name, inv):
                invocation = inv
                toolName = name
            default:
                continue
            }

            guard invocation.state == .inputAvailable,
                  !processedToolCalls.contains(invocation.toolCallId)
            else { continue }

            if let tool = registeredTools.first(where: { $0.name == toolName }) {
                processedToolCalls.insert(invocation.toolCallId)
                executeRegisteredTool(
                    tool,
                    toolCallId: invocation.toolCallId,
                    input: invocation.input
                )
            } else if let handler = onToolCall {
                processedToolCalls.insert(invocation.toolCallId)
                let toolCall = ToolCall(
                    toolCallId: invocation.toolCallId,
                    toolName: toolName,
                    input: invocation.input
                )
                pendingClientToolCallIds.insert(invocation.toolCallId)
                Task { @MainActor [weak self] in
                    await handler(toolCall)
                    self?.pendingClientToolCallIds.remove(toolCall.toolCallId)
                }
            }
        }
    }

    /// Runs a registered tool and reports its result.
    ///
    /// A thrown error is reported as the tool *output* (`"Error executing tool: …"`)
    /// rather than an `output-error` state, so the turn still auto-continues and the
    /// model can react to the failure — matching the reference automatic tool
    /// resolution. (An `output-error` never auto-continues, which would leave the
    /// turn hanging with no user action to resume it.)
    private func executeRegisteredTool(
        _ tool: ClientTool,
        toolCallId: String,
        input: JSONValue?
    ) {
        pendingClientToolCallIds.insert(toolCallId)
        Task { @MainActor [weak self] in
            let output: JSONValue
            do {
                output = try await tool.execute(input)
            } catch {
                output = .string("Error executing tool: \(error.localizedDescription)")
            }
            guard let self else { return }
            self.pendingClientToolCallIds.remove(toolCallId)
            self.addToolOutput(toolCallId: toolCallId, output: output)
        }
    }

    // MARK: - Inbound reconcile loop

    /// Subscribes to inbound frames and reconciles server-pushed message lists, chat
    /// clears, and the stream-resume handshake (delegated to the transport). Mirrors
    /// the reference `onAgentMessage` handler for the session-owned message types.
    private func startInboundLoop() {
        let stream = client.inboundMessages()
        inboundTask = Task { @MainActor [weak self] in
            for await text in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.handleInbound(text)
            }
        }
    }

    /// Decodes and routes a single inbound frame.
    private func handleInbound(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(InboundChatMessage.self, from: data)
        else { return }

        switch message {
        case .chatClear:
            resetLocalState()

        case let .chatMessages(payload):
            messages = preservingStreamingAssistant(payload.messages)

        case let .messageUpdated(payload):
            applyMessageUpdate(payload.message)

        case .streamResuming, .streamResumeNone:
            // Let the transport's resume/tool-continuation handshake consume it.
            await transport.handleInbound(message)

        case .useChatResponse, .unknown:
            // Chunk frames are consumed by the transport's own reader; anything
            // unrecognised is ignored.
            break
        }
    }

    /// Replaces the message list with a server-pushed list, but keeps any in-flight
    /// streaming assistant message (by id) so a broadcast does not clobber locally
    /// streamed content. Mirrors `preserveProtectedStreamingAssistant`.
    private func preservingStreamingAssistant(_ incoming: [UIMessage]) -> [UIMessage] {
        guard let streamingId = streamingAssistantId else { return incoming }
        guard let protected = messages.first(where: { $0.id == streamingId })
            ?? incoming.first(where: { $0.id == streamingId })
        else { return incoming }

        var result = incoming.filter { $0.id != streamingId }
        result.append(protected)
        return result
    }

    /// Applies a `cf_agent_message_updated` frame: replaces the matching local message
    /// (by id, then by shared `toolCallId`) preserving the local id; never appends.
    /// Mirrors the reference `CF_AGENT_MESSAGE_UPDATED` handler.
    private func applyMessageUpdate(_ updated: UIMessage) {
        if let index = messages.firstIndex(where: { $0.id == updated.id }) {
            var replacement = updated
            replacement.id = messages[index].id
            messages[index] = replacement
            return
        }

        let updatedToolCallIds = Set(updated.parts.compactMap(Self.toolCallId(of:)))
        guard !updatedToolCallIds.isEmpty else { return }

        if let index = messages.firstIndex(where: { message in
            message.parts.contains { part in
                if let id = Self.toolCallId(of: part) { return updatedToolCallIds.contains(id) }
                return false
            }
        }) {
            var replacement = updated
            replacement.id = messages[index].id
            messages[index] = replacement
        }
        // Not found: do not append (matches the reference; avoids duplicates).
    }

    /// Extracts the `toolCallId` from a tool/dynamic-tool part, if any.
    private static func toolCallId(of part: UIMessagePart) -> String? {
        switch part {
        case let .tool(_, invocation): return invocation.toolCallId
        case let .dynamicTool(_, invocation): return invocation.toolCallId
        default: return nil
        }
    }

    // MARK: - Frame sending

    /// Encodes and sends an outbound chat frame, ignoring encode failures (there is no
    /// meaningful recovery for a frame that cannot be JSON-encoded).
    private func sendFrame(_ build: () throws -> String) {
        guard let frame = try? build() else { return }
        client.send(frame)
    }
}
