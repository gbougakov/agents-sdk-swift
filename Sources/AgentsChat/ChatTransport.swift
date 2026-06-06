import Foundation
import Agents

/// The reason a chat turn is being requested.
///
/// Mirrors the `trigger` union in `ws-chat-transport.ts`
/// (`"submit-message" | "regenerate-message"`). The raw values are sent verbatim
/// inside the request body, so they must match the server exactly.
public enum ChatTrigger: String, Codable, Hashable, Sendable {
    /// A new user message was submitted (`"submit-message"`).
    case submitMessage = "submit-message"
    /// An existing assistant message is being regenerated (`"regenerate-message"`).
    case regenerateMessage = "regenerate-message"
}

/// Errors surfaced by ``ChatTransport`` streams.
public enum ChatTransportError: Error, Sendable {
    /// The server reported a stream error. The associated value is the server's
    /// error text (the `body` of an errored `cf_agent_use_chat_response` frame),
    /// or a generic message when none was provided.
    case stream(String)
    /// A request body could not be encoded as JSON.
    case encodingFailed
    /// The local stream was aborted (matches the JS `AbortError`). Emitted when an
    /// in-flight turn is cancelled locally or by a client abort.
    case aborted
}

/// WebSocket-based chat transport speaking the `CF_AGENT_*` chat protocol natively.
///
/// This is the Swift port of `WebSocketChatTransport` from
/// `packages/ai-chat/src/ws-chat-transport.ts`. Where the reference builds
/// `ReadableStream<UIMessageChunk>` values driven by `addEventListener`, this
/// implementation builds `AsyncThrowingStream<UIMessageChunk, Error>` values
/// driven by ``AgentConnectionProviding/inboundMessages()``.
///
/// It is an `actor`: all mutable state (the pending resume handshake resolvers,
/// the active-server-turn bookkeeping, and the tool-continuation flag) is isolated
/// so the request / resume / tool-continuation state machine stays consistent
/// under concurrent access. The underlying connection is a `@MainActor`
/// ``AgentConnectionProviding`` (typically an `AgentClient`); its `send` and
/// `inboundMessages()` are reached via `await` hops.
///
/// Data flow: WS → ``ChatTransport`` → caller's `AsyncThrowingStream` → reducer.
public actor ChatTransport {

    // MARK: - Dependencies

    /// The underlying agent connection used to send frames and observe inbound
    /// frames. `@MainActor`-isolated, so access is via `await`.
    private let connection: any AgentConnectionProviding

    /// Whether generic client-side abort/cancel should cancel the durable server
    /// turn. Explicit cancellation via ``cancelActiveServerTurn()`` always sends a
    /// cancel frame regardless of this flag. Defaults to `false`, matching the
    /// reference: durable turns keep running and can be resumed.
    private var cancelOnClientAbort: Bool

    // MARK: - Resume handshake state

    /// Pending resume resolver — set by ``reconnectToStream()`` and invoked when an
    /// inbound `cf_agent_stream_resuming` arrives. Mirrors `_resumeResolver`.
    private var resumeResolver: ((StreamResumingMessage) -> Void)?

    /// Pending "no stream" resolver — invoked when an inbound
    /// `cf_agent_stream_resume_none` arrives. Mirrors `_resumeNoneResolver`.
    private var resumeNoneResolver: (() -> Void)?

    /// When set, the next ``reconnectToStream()`` attaches to a server-initiated
    /// tool continuation rather than a page-load resume. Mirrors
    /// `_expectToolContinuation`.
    private var expectingToolContinuation = false

    /// Aborts the active tool-continuation stream, if one is attached. Mirrors
    /// `_abortToolContinuation`.
    private var abortToolContinuation: (() -> Bool)?

    // MARK: - Active-server-turn state

    /// The request id of the server turn currently being rendered, if any. Mirrors
    /// `_activeServerTurnId`.
    private var activeServerTurnId: String?

    /// Cancels the locally-attached stream for the active server turn. Mirrors
    /// `_cancelAttachedStream`.
    private var cancelAttachedStream: (() -> Bool)?

    // MARK: - Init

    /// Creates a transport over an agent connection.
    ///
    /// - Parameters:
    ///   - connection: The agent connection (typically an `AgentClient`).
    ///   - cancelOnClientAbort: Whether a generic client abort should cancel the
    ///     durable server turn. Defaults to `false`.
    public init(
        connection: any AgentConnectionProviding,
        cancelOnClientAbort: Bool = false
    ) {
        self.connection = connection
        self.cancelOnClientAbort = cancelOnClientAbort
    }

    /// Updates whether a generic client abort cancels the server turn.
    public func setCancelOnClientAbort(_ value: Bool) {
        cancelOnClientAbort = value
    }

    // MARK: - Public state queries

    /// `true` while the transport is awaiting a resume handshake. Mirrors
    /// `isAwaitingResume()`.
    public var isAwaitingResume: Bool {
        resumeResolver != nil || resumeNoneResolver != nil
    }

    /// Marks that the next ``reconnectToStream()`` should attach to a
    /// server-initiated tool continuation. Mirrors `expectToolContinuation()`.
    public func expectToolContinuation() {
        expectingToolContinuation = true
    }

    /// Aborts the active client-side tool continuation stream, if one is attached.
    /// Mirrors `abortActiveToolContinuation()`.
    @discardableResult
    public func abortActiveToolContinuation() -> Bool {
        abortToolContinuation?() ?? false
    }

    // MARK: - Inbound dispatch

    /// Routes an inbound chat frame into the transport's pending handshake
    /// resolvers, returning `true` when the frame was consumed by the transport.
    ///
    /// The owning ``AgentConnectionProviding`` fans every raw frame out to its
    /// subscribers; the chat session decodes frames and calls this for the resume
    /// handshake types so the transport can drive its state machine in lockstep
    /// with the session's own handling. Mirrors `handleStreamResuming` /
    /// `handleStreamResumeNone` from the reference.
    ///
    /// - Returns: `true` if a pending resume handshake consumed the frame.
    @discardableResult
    public func handleInbound(_ message: InboundChatMessage) -> Bool {
        switch message {
        case let .streamResuming(payload):
            return handleStreamResuming(payload)
        case .streamResumeNone:
            return handleStreamResumeNone()
        default:
            return false
        }
    }

    /// Handles `cf_agent_stream_resuming`: if a resume is pending, fires the
    /// resolver and returns `true`. Mirrors `handleStreamResuming`.
    @discardableResult
    public func handleStreamResuming(_ data: StreamResumingMessage) -> Bool {
        guard let resolver = resumeResolver else { return false }
        resolver(data)
        return true
    }

    /// Handles `cf_agent_stream_resume_none`: if a resume is pending, resolves it
    /// with no stream and returns `true`. Mirrors `handleStreamResumeNone`.
    @discardableResult
    public func handleStreamResumeNone() -> Bool {
        guard let resolver = resumeNoneResolver else { return false }
        resolver()
        return true
    }

    /// Clears bookkeeping for a server turn finishing outside an attached stream
    /// (e.g. after local-only client cleanup). Mirrors `handleServerTurnCompleted`.
    public func handleServerTurnCompleted(_ requestId: String) {
        clearActiveServerTurn(requestId)
    }

    /// Registers a server turn rendered outside a transport-owned stream (the
    /// cross-tab / resume observer path). Mirrors `observeServerTurn`.
    public func observeServerTurn(_ requestId: String) {
        setActiveServerTurn(requestId, cancelAttachedStream: nil)
    }

    // MARK: - Active-server-turn bookkeeping

    private func setActiveServerTurn(_ requestId: String, cancelAttachedStream: (() -> Bool)?) {
        activeServerTurnId = requestId
        self.cancelAttachedStream = cancelAttachedStream
    }

    private func clearActiveServerTurn(_ requestId: String) {
        if activeServerTurnId == requestId {
            activeServerTurnId = nil
            cancelAttachedStream = nil
        }
    }

    // MARK: - Cancellation

    /// Explicitly cancels the active server turn, if any, by sending
    /// `cf_agent_chat_request_cancel`.
    ///
    /// This is separate from generic client-side abort: callers can detach locally
    /// (default) without stopping durable server work, then use this to stop the
    /// turn for real. Also aborts an active tool continuation. Mirrors
    /// `cancelActiveServerTurn()`.
    ///
    /// - Returns: `true` if a request or tool continuation was cancelled.
    @discardableResult
    public func cancelActiveServerTurn() async -> Bool {
        var cancelledRequest = false

        if let requestId = activeServerTurnId {
            await sendCancelFrame(requestId)
            _ = cancelAttachedStream?()
            clearActiveServerTurn(requestId)
            cancelledRequest = true
        }

        let cancelledToolContinuation = abortActiveToolContinuation()
        return cancelledRequest || cancelledToolContinuation
    }

    /// Sends a `cf_agent_chat_request_cancel` frame, ignoring encode/send failures
    /// (e.g. the connection already closed). Mirrors `sendCancelFrame`.
    private func sendCancelFrame(_ requestId: String) async {
        guard let frame = try? OutboundChatMessage.chatRequestCancel(id: requestId) else { return }
        await send(frame)
    }

    /// Sends a raw frame over the `@MainActor` connection.
    private func send(_ frame: String) async {
        await connection.send(frame)
    }

    // MARK: - Send

    /// Sends a chat request and returns the stream of assistant chunks for it.
    ///
    /// Generates a `nanoid(8)` request id, encodes the body as JSON
    /// `{ messages, trigger, ...extraBody }`, sends a `cf_agent_use_chat_request`
    /// frame, and returns an `AsyncThrowingStream` that yields each
    /// `cf_agent_use_chat_response` frame (matching the id) parsed into a
    /// ``UIMessageChunk``. The stream finishes on the `done` frame and throws
    /// ``ChatTransportError/stream(_:)`` on an errored frame. Mirrors
    /// `sendMessages` from the reference.
    ///
    /// The stream's `onTermination` performs the local-abort cleanup the reference
    /// runs in the `ReadableStream` `cancel()` callback, honouring
    /// ``cancelOnClientAbort``.
    ///
    /// - Parameters:
    ///   - messages: The conversation to send.
    ///   - trigger: Why the turn is requested.
    ///   - extraBody: Extra top-level fields merged into the request body.
    /// - Returns: A stream of parsed assistant chunks for this turn.
    /// - Throws: ``ChatTransportError/encodingFailed`` if the body cannot be built.
    public func send(
        messages: [UIMessage],
        trigger: ChatTrigger,
        extraBody: [String: JSONValue] = [:]
    ) throws -> AsyncThrowingStream<UIMessageChunk, Error> {
        let requestId = nanoid(8)
        let bodyPayload = try Self.encodeRequestBody(
            messages: messages,
            trigger: trigger,
            extraBody: extraBody
        )

        let (stream, continuation) = AsyncThrowingStream<UIMessageChunk, Error>.makeStream()

        // Drives the inbound frame loop; cancelled on every terminal path.
        let reader = Task { [weak self] in
            await self?.runChunkReader(requestId: requestId, continuation: continuation)
        }

        // Register the active server turn. Cancelling the attached stream throws
        // `.aborted` into the consumer while keeping the request id alive so the
        // session skips in-flight chunks until the server's `done` frame.
        setActiveServerTurn(requestId) {
            continuation.finish(throwing: ChatTransportError.aborted)
            return true
        }

        // Local cleanup mirrors the JS `cancel()` callback: by default abort is
        // local-only; under `cancelOnClientAbort` we also send a cancel frame.
        continuation.onTermination = { [weak self] termination in
            reader.cancel()
            guard let self else { return }
            Task {
                await self.finishSend(requestId: requestId, termination: termination)
            }
        }

        // Send the request. PartySocket-style queueing flushes this on connect, so
        // it is safe regardless of current socket state.
        let frame = try OutboundChatMessage.useChatRequest(id: requestId, body: bodyPayload)
        Task { [weak self] in
            await self?.send(frame)
        }

        return stream
    }

    /// Performs the local cleanup for a finished/aborted send. Sends a cancel frame
    /// only when ``cancelOnClientAbort`` is set and the termination was a
    /// cancellation. Always clears the active-server-turn bookkeeping.
    private func finishSend(
        requestId: String,
        termination: AsyncThrowingStream<UIMessageChunk, Error>.Continuation.Termination
    ) async {
        if cancelOnClientAbort, case .cancelled = termination {
            await sendCancelFrame(requestId)
        }
        clearActiveServerTurn(requestId)
    }

    /// Consumes inbound frames for `requestId`, parsing matching
    /// `cf_agent_use_chat_response` bodies into chunks and feeding `continuation`.
    /// Finishes on `done`, throws on an errored frame, and finishes on connection
    /// close (matching the reference `onClose` path). This is the
    /// `AsyncStream`-driven analogue of the reference `onMessage` listener.
    private func runChunkReader(
        requestId: String,
        continuation: AsyncThrowingStream<UIMessageChunk, Error>.Continuation
    ) async {
        let inbound = await connection.inboundMessages()
        for await text in inbound {
            if Task.isCancelled { return }
            guard let response = Self.decodeChatResponse(text, matching: requestId) else {
                continue
            }

            if response.error == true {
                let message = response.body.isEmpty ? "Stream error" : response.body
                continuation.finish(throwing: ChatTransportError.stream(message))
                return
            }

            if let chunk = Self.parseChunk(response.body) {
                continuation.yield(chunk)
            }

            if response.done {
                continuation.finish()
                return
            }
        }
        // Inbound stream ended (connection closed): close gracefully.
        continuation.finish()
    }

    // MARK: - Reconnect / resume

    /// Detects whether the server has an active stream to resume and, if so,
    /// returns the chunk stream for it. Returns `nil` when there is nothing to
    /// resume. Mirrors `reconnectToStream`.
    ///
    /// When a tool continuation is expected (see ``expectToolContinuation()``),
    /// returns a deferred stream immediately that waits for the server to announce
    /// the continuation via `cf_agent_stream_resuming`.
    ///
    /// Otherwise it sends `cf_agent_stream_resume_request` and arms resolvers that
    /// ``handleStreamResuming(_:)`` / ``handleStreamResumeNone()`` fire. On
    /// `cf_agent_stream_resuming` it replies `cf_agent_stream_resume_ack` and
    /// returns the resumed stream; on `cf_agent_stream_resume_none` it returns
    /// `nil`. A 5-second safety timeout resolves `nil` if the server never
    /// responds.
    public func reconnectToStream() async -> AsyncThrowingStream<UIMessageChunk, Error>? {
        if expectingToolContinuation {
            expectingToolContinuation = false
            return makeToolContinuationStream()
        }

        // Race the resume handshake against a 5s safety timeout. The first to
        // resolve wins; the rest are cleared.
        let resumeRequestId: String? = await withCheckedContinuation { continuation in
            let box = ResolveOnce<String?>(continuation: continuation)

            resumeNoneResolver = { [box] in
                box.resolve(nil)
            }
            resumeResolver = { [box] data in
                box.resolve(data.id)
            }

            // Send the resume request (queued/flushed by the socket as needed).
            Task { [weak self] in
                guard let self else { return }
                if let frame = try? OutboundChatMessage.streamResumeRequest() {
                    await self.send(frame)
                }
            }

            // Safety-net timeout.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.resumeTimeoutNanoseconds)
                await self?.fireResumeTimeout(box)
            }
        }

        // Clear handshake resolvers now that one fired.
        resumeResolver = nil
        resumeNoneResolver = nil

        guard let requestId = resumeRequestId else { return nil }

        // ACK the resume, then return a stream fed by replayed + live chunks.
        if let ack = try? OutboundChatMessage.streamResumeAck(id: requestId) {
            await send(ack)
        }
        return makeResumeStream(requestId: requestId)
    }

    /// Resolves a pending resume handshake with `nil` when the safety timeout
    /// elapses. Clears the resolvers so a late server frame is a no-op.
    private func fireResumeTimeout(_ box: ResolveOnce<String?>) {
        guard resumeResolver != nil || resumeNoneResolver != nil else { return }
        resumeResolver = nil
        resumeNoneResolver = nil
        box.resolve(nil)
    }

    /// Builds the chunk stream for a resumed server turn (`requestId`), registering
    /// it as the active server turn. Mirrors `_createResumeStream`.
    private func makeResumeStream(requestId: String) -> AsyncThrowingStream<UIMessageChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<UIMessageChunk, Error>.makeStream()

        let reader = Task { [weak self] in
            await self?.runChunkReader(requestId: requestId, continuation: continuation)
        }

        setActiveServerTurn(requestId) {
            continuation.finish(throwing: ChatTransportError.aborted)
            return true
        }

        continuation.onTermination = { [weak self] termination in
            reader.cancel()
            guard let self else { return }
            Task {
                await self.finishSend(requestId: requestId, termination: termination)
            }
        }

        return stream
    }

    // MARK: - Tool continuation

    /// Builds a deferred stream for a client-side tool continuation.
    ///
    /// The stream is returned immediately (so a chat session can transition to
    /// "submitted"), then waits for the server to announce the continuation via
    /// `cf_agent_stream_resuming`. On that frame it ACKs and begins forwarding
    /// chunks; on `cf_agent_stream_resume_none`, connection close, or a 5-second
    /// timeout it closes empty. Mirrors `_createToolContinuationStream`.
    private func makeToolContinuationStream() -> AsyncThrowingStream<UIMessageChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<UIMessageChunk, Error>.makeStream()

        // Shared, actor-isolated coordination for the handshake → reader transition.
        let coordinator = ToolContinuationCoordinator()

        // Allow explicit cancellation to abort this continuation.
        //
        // These resolvers are only ever invoked synchronously from the
        // transport actor's own isolated methods (`handleStreamResuming`,
        // `handleStreamResumeNone`, `abortActiveToolContinuation`), so it is
        // safe to assume actor isolation when forwarding to the isolated
        // implementations.
        abortToolContinuation = { [weak self] in
            guard let self else { return false }
            return self.assumeIsolated { transport in
                transport.abortToolContinuationStream(coordinator, continuation: continuation)
            }
        }

        // Arm resume resolvers: the first `cf_agent_stream_resuming` wins.
        resumeNoneResolver = { [weak self] in
            self?.assumeIsolated { transport in
                transport.finishToolContinuation(coordinator, continuation: continuation, throwing: nil)
            }
        }
        resumeResolver = { [weak self] data in
            self?.assumeIsolated { transport in
                transport.beginToolContinuation(
                    coordinator,
                    requestId: data.id,
                    continuation: continuation
                )
            }
        }

        // Send the resume request to prompt the server.
        Task { [weak self] in
            guard let self else { return }
            if let frame = try? OutboundChatMessage.streamResumeRequest() {
                await self.send(frame)
            }
        }

        // Safety-net timeout: close empty if the server never announces.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.resumeTimeoutNanoseconds)
            await self?.finishToolContinuationOnTimeout(coordinator, continuation: continuation)
        }

        continuation.onTermination = { [weak self] termination in
            guard let self else { return }
            Task {
                await self.toolContinuationTerminated(
                    coordinator,
                    termination: termination
                )
            }
        }

        return stream
    }

    /// Handles the `cf_agent_stream_resuming` for a pending tool continuation:
    /// records the request id, ACKs, registers the active turn, and starts the
    /// chunk reader.
    private func beginToolContinuation(
        _ coordinator: ToolContinuationCoordinator,
        requestId: String,
        continuation: AsyncThrowingStream<UIMessageChunk, Error>.Continuation
    ) {
        guard coordinator.requestId == nil, !coordinator.completed else { return }
        coordinator.requestId = requestId

        // Handshake consumed; clear resolvers so a duplicate frame is a no-op.
        resumeResolver = nil
        resumeNoneResolver = nil

        setActiveServerTurn(requestId) {
            continuation.finish(throwing: ChatTransportError.aborted)
            return true
        }

        coordinator.reader = Task { [weak self] in
            await self?.runChunkReader(requestId: requestId, continuation: continuation)
        }

        Task { [weak self] in
            guard let self else { return }
            if let ack = try? OutboundChatMessage.streamResumeAck(id: requestId) {
                await self.send(ack)
            }
        }
    }

    /// Finishes a tool continuation that resolved with no stream (resume-none /
    /// timeout): closes the consumer empty and clears resolvers.
    private func finishToolContinuation(
        _ coordinator: ToolContinuationCoordinator,
        continuation: AsyncThrowingStream<UIMessageChunk, Error>.Continuation,
        throwing error: Error?
    ) {
        guard !coordinator.completed else { return }
        coordinator.completed = true
        abortToolContinuation = nil
        resumeResolver = nil
        resumeNoneResolver = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func finishToolContinuationOnTimeout(
        _ coordinator: ToolContinuationCoordinator,
        continuation: AsyncThrowingStream<UIMessageChunk, Error>.Continuation
    ) {
        guard coordinator.requestId == nil else { return }
        finishToolContinuation(coordinator, continuation: continuation, throwing: nil)
    }

    /// Aborts an active tool continuation. If the handshake has not completed it
    /// errors the consumer locally; otherwise it sends a cancel frame for the
    /// resolved request id before erroring. Mirrors `_abortToolContinuation`.
    private func abortToolContinuationStream(
        _ coordinator: ToolContinuationCoordinator,
        continuation: AsyncThrowingStream<UIMessageChunk, Error>.Continuation
    ) -> Bool {
        guard !coordinator.completed else { return false }

        if let requestId = coordinator.requestId {
            Task { [weak self] in
                await self?.sendCancelFrame(requestId)
            }
        }
        finishToolContinuation(coordinator, continuation: continuation, throwing: ChatTransportError.aborted)
        return true
    }

    /// `onTermination` handler for a tool-continuation stream: cancels the reader
    /// and applies `cancelOnClientAbort` semantics for the resolved request id.
    private func toolContinuationTerminated(
        _ coordinator: ToolContinuationCoordinator,
        termination: AsyncThrowingStream<UIMessageChunk, Error>.Continuation.Termination
    ) async {
        coordinator.reader?.cancel()
        coordinator.completed = true
        abortToolContinuation = nil

        guard let requestId = coordinator.requestId else { return }
        if cancelOnClientAbort, case .cancelled = termination {
            await sendCancelFrame(requestId)
        }
        clearActiveServerTurn(requestId)
    }

    // MARK: - Encoding / decoding helpers

    /// 5-second resume safety timeout in nanoseconds (matches the reference).
    private static let resumeTimeoutNanoseconds: UInt64 = 5_000_000_000

    /// Encodes the request body `{ messages, trigger, ...extraBody }` as a JSON
    /// string. `extraBody` fields are merged at the top level; `messages` and
    /// `trigger` win on key collision, matching the reference spread order.
    static func encodeRequestBody(
        messages: [UIMessage],
        trigger: ChatTrigger,
        extraBody: [String: JSONValue]
    ) throws -> String {
        let encoder = JSONEncoder()

        // Encode messages and re-decode to JSONValue so we can compose one object.
        let messagesData = try encoder.encode(messages)
        let messagesValue = try JSONDecoder().decode(JSONValue.self, from: messagesData)

        var object: [String: JSONValue] = extraBody
        object["messages"] = messagesValue
        object["trigger"] = .string(trigger.rawValue)

        let data = try encoder.encode(JSONValue.object(object))
        guard let string = String(data: data, encoding: .utf8) else {
            throw ChatTransportError.encodingFailed
        }
        return string
    }

    /// Decodes a raw inbound frame into a `cf_agent_use_chat_response` payload,
    /// returning it only when its `id` matches `requestId`. Returns `nil` for any
    /// other frame type, a non-matching id, or non-JSON text (all skipped).
    static func decodeChatResponse(_ text: String, matching requestId: String) -> UseChatResponseMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let inbound = try? JSONDecoder().decode(InboundChatMessage.self, from: data) else {
            return nil
        }
        guard case let .useChatResponse(response) = inbound, response.id == requestId else {
            return nil
        }
        return response
    }

    /// Parses a non-empty response `body` string into a ``UIMessageChunk``.
    /// Returns `nil` for empty/whitespace bodies and silently skips malformed
    /// chunk bodies (matching the reference's `try { … } catch {}`).
    static func parseChunk(_ body: String) -> UIMessageChunk? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UIMessageChunk.self, from: data)
    }
}

// MARK: - Resolve-once continuation guard

/// Wraps a `CheckedContinuation` so it is resumed at most once even though several
/// racing callbacks (resume resolver, resume-none resolver, timeout) may fire. The
/// transport actor isolates all callers, so the `resolved` flag needs no lock.
private final class ResolveOnce<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: T) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: value)
    }
}

// MARK: - Tool-continuation coordinator

/// Mutable coordination shared between a tool-continuation stream's handshake
/// resolvers, its chunk reader, and its termination handler. Only ever touched
/// from within the `ChatTransport` actor, so its mutation is safe.
private final class ToolContinuationCoordinator: @unchecked Sendable {
    /// The resolved server request id once `cf_agent_stream_resuming` arrives.
    var requestId: String?
    /// Whether the continuation has reached a terminal state.
    var completed = false
    /// The chunk-reading task, started after the handshake completes.
    var reader: Task<Void, Never>?
}
