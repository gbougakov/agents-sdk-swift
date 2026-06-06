import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The origin of a state update delivered to ``AgentClient/onStateUpdate``.
///
/// Mirrors the reference client's `"server" | "client"` discriminator passed to
/// `onStateUpdate`.
public enum StateUpdateSource: String, Sendable, Equatable {
    /// The agent broadcast the state (a `cf_agent_state` frame arrived).
    case server
    /// The local client pushed the state via ``AgentClient/setState(_:)``.
    case client
}

/// Errors surfaced by ``AgentClient`` RPC calls.
public enum AgentClientError: Error, Sendable, Equatable {
    /// The server returned `{ success: false, error }` for an RPC call.
    case rpc(String)
    /// The connection closed (or `disconnect()` was called) before the call
    /// resolved. The reason is `"Connection closed"`, matching the reference.
    case connectionClosed
    /// The call did not complete within the supplied timeout.
    case timeout(method: String, duration: Duration)
    /// An outbound message could not be encoded to JSON.
    case encodingFailed
    /// The connection URL could not be assembled from the supplied options.
    case invalidURL
}

/// A minimal connection surface that higher-level modules (e.g. the chat layer)
/// build on without reaching into ``AgentClient`` internals.
///
/// The chat transport needs three things from the underlying agent connection:
/// the ability to send a raw JSON text frame, a stream of inbound raw text
/// frames it can parse itself, and the HTTP base URL (for history fetches). It
/// also exposes identity/ready so the transport can sequence work after the
/// server has identified the instance.
///
/// ``AgentClient`` is the canonical conformer. All members are `@MainActor` so
/// the chat session (also `@MainActor @Observable`) can interact without hops.
@MainActor
public protocol AgentConnectionProviding: AnyObject, Sendable {
    /// Sends a raw JSON text frame over the connection. Frames sent while
    /// disconnected are queued and flushed on the next open.
    func send(_ text: String)

    /// A multicast stream of inbound raw text frames from the server.
    ///
    /// Each call returns an independent subscription; a new subscriber receives
    /// frames that arrive after it subscribes (no replay). The chat transport
    /// parses these strings into its own message types.
    func inboundMessages() -> AsyncStream<String>

    /// The HTTP form of the agent URL (`http(s)://…`), used for chat history
    /// fetches (`/get-messages`) and other one-shot requests.
    var httpBaseURL: URL? { get }

    /// Whether the server has sent identity for the current connection.
    var identified: Bool { get }

    /// Suspends until the server sends `cf_agent_identity`. Resets on close so it
    /// can be awaited again after a reconnect.
    func ready() async
}

/// A `@MainActor`, `@Observable` WebSocket client for a deployed Cloudflare
/// Agent.
///
/// `AgentClient` is the Swift port of the reference `AgentClient`
/// (`packages/agents/src/client.ts`). Networking lives in the
/// ``ReconnectingWebSocket`` actor; this facade marshals that actor's events to
/// the main actor and publishes observable properties SwiftUI reads directly:
///
/// ```swift
/// let client = AgentClient(
///     .init(agent: "GameAgent", name: "game-123", host: "my-worker.workers.dev"),
///     state: GameState.self
/// )
/// client.connect()
/// await client.ready()
/// let result = try await client.call("roll", returning: Int.self)
/// // SwiftUI: Text("Score: \(client.state?.score ?? 0)") updates automatically.
/// ```
///
/// The generic `State` is the typed shape of the agent's synced state. It starts
/// `nil` and is populated when the server sends its first `cf_agent_state` frame
/// (from the agent's `initialState`).
@MainActor
@Observable
public final class AgentClient<State: Codable & Sendable>: AgentConnectionProviding {

    // MARK: - Observable state

    /// The current agent state. `nil` until the first `cf_agent_state` frame is
    /// received from the server. Updated on server broadcasts and local
    /// ``setState(_:)`` calls.
    public private(set) var state: State?

    /// The current connection lifecycle phase. Observable; SwiftUI views reading
    /// this re-render on transitions.
    public private(set) var connection: ConnectionPhase

    /// Whether the server has sent identity for the current connection. Becomes
    /// `true` on the first `cf_agent_identity` frame and resets to `false` when
    /// the connection closes.
    public private(set) var identified: Bool

    /// The agent namespace (kebab-cased). Initialized from options and updated to
    /// the server-authoritative value on `cf_agent_identity`.
    public let agent: String

    /// The instance / room name. Initialized from options (defaulting to
    /// `"default"`) and updated to the server-authoritative value on
    /// `cf_agent_identity`.
    public private(set) var name: String

    // MARK: - Callbacks

    /// Called whenever the state changes, with its origin. Optional; for most
    /// use cases reading ``state`` directly is simpler.
    public var onStateUpdate: ((State, StateUpdateSource) -> Void)?

    /// Called when the server sends identity on connect, with the resolved
    /// `(name, agent)`. Useful with `basePath` routing where the instance is
    /// determined server-side.
    public var onIdentity: ((_ name: String, _ agent: String) -> Void)?

    /// Called when a state update fails server-side (a `cf_agent_state_error`
    /// frame arrived, e.g. a read-only connection), with the error description.
    public var onStateUpdateError: ((String) -> Void)?

    /// Called on every connection-phase transition. Optional.
    public var onConnectionChange: ((ConnectionPhase) -> Void)?

    // MARK: - Private stored state

    /// Untracked storage so Observation does not treat networking plumbing as
    /// observable surface.
    @ObservationIgnored private let options: AgentClientOptions
    @ObservationIgnored private let socket: ReconnectingWebSocket
    @ObservationIgnored private let httpURLValue: URL?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    /// A pending RPC call awaiting its `rpc` response.
    private enum PendingCall {
        /// A one-shot `call`: resume the continuation on the terminal frame.
        case single(CheckedContinuation<JSONValue, Error>)
        /// A streaming `callStream`: yield chunks, finish on `done`.
        case stream(AsyncThrowingStream<JSONValue, Error>.Continuation)
    }

    @ObservationIgnored private var pendingCalls: [String: PendingCall] = [:]

    /// Per-call timeout tasks, keyed by RPC id, so they can be cancelled when the
    /// call resolves.
    @ObservationIgnored private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Continuations awaiting ``ready()``. Resolved on identity, reset on close.
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Inbound raw-message subscribers (for ``inboundMessages()``), keyed by id.
    @ObservationIgnored private var inboundSubscribers:
        [UUID: AsyncStream<String>.Continuation] = [:]

    // MARK: - Init

    /// Creates an agent client.
    ///
    /// The connection is opened immediately unless `options.startClosed` is
    /// `true`, in which case the caller must invoke ``connect()``.
    ///
    /// - Parameters:
    ///   - options: Connection options (agent, instance, host, query, headers,
    ///     reconnection config).
    ///   - state: The typed state shape. Passed as a metatype so callers write
    ///     `AgentClient(options, state: GameState.self)`.
    public init(_ options: AgentClientOptions, state: State.Type = State.self) {
        self.options = options
        self.agent = camelCaseToKebabCase(options.agent)
        self.name = options.name
        self.state = nil
        self.identified = false
        self.connection = options.startClosed ? .idle : .connecting

        // Stable connection id (_pk), reused across reconnects like PartySocket.
        let connectionId = newUUIDLower()

        // Resolve the HTTP base URL once for chat history / fetches. Query is
        // resolved lazily for the socket; for the HTTP URL we omit dynamic query
        // (history fetch carries its own auth via headers if needed).
        let staticQuery: [(name: String, value: String?)]
        if case let .static(map) = options.query {
            staticQuery = map.map { ($0.key, $0.value) }
        } else {
            staticQuery = []
        }
        let httpBuilder = PartySocketURL(
            host: options.host ?? "",
            agent: options.agent,
            name: options.name,
            basePath: options.basePath,
            path: options.path,
            query: staticQuery,
            connectionId: connectionId,
            protocolOverride: options.protocolOverride.map(Self.mapScheme)
        )
        self.httpURLValue = options.host == nil ? nil : httpBuilder.httpURL

        // Build the request provider: re-evaluated before every (re)connect so
        // dynamic query (auth token refresh) and headers are picked up fresh.
        let host = options.host
        let agentName = options.agent
        let instanceName = options.name
        let basePath = options.basePath
        let extraPath = options.path
        let queryProvider = options.query
        let headers = options.headers
        let schemeOverride = options.protocolOverride.map(Self.mapScheme)

        let provider: ReconnectingWebSocket.RequestProvider = {
            let resolvedHost = host ?? ""
            let resolvedQuery: [(name: String, value: String?)]
            if let queryProvider {
                resolvedQuery = await queryProvider.resolve().map { ($0.key, $0.value) }
            } else {
                resolvedQuery = []
            }
            let builder = PartySocketURL(
                host: resolvedHost,
                agent: agentName,
                name: instanceName,
                basePath: basePath,
                path: extraPath,
                query: resolvedQuery,
                connectionId: connectionId,
                protocolOverride: schemeOverride
            )
            guard let url = builder.webSocketURL else {
                throw AgentClientError.invalidURL
            }
            var request = URLRequest(url: url)
            if let headers {
                for (field, value) in headers {
                    request.setValue(value, forHTTPHeaderField: field)
                }
            }
            return request
        }

        self.socket = ReconnectingWebSocket(
            requestProvider: provider,
            configuration: options.reconnection
        )

        startEventLoop()

        if !options.startClosed {
            let socket = self.socket
            Task { await socket.connect() }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    // MARK: - Connection control

    /// Opens (or re-opens) the connection. Idempotent if already connecting /
    /// connected. Re-enables reconnection after a prior ``disconnect()``.
    public func connect() {
        setConnection(.connecting)
        let socket = self.socket
        Task { await socket.connect() }
    }

    /// Closes the connection and disables reconnection. All pending RPC calls are
    /// rejected immediately with ``AgentClientError/connectionClosed``, providing
    /// instant feedback rather than waiting for the close handshake.
    public func disconnect() {
        rejectAllPending(AgentClientError.connectionClosed)
        let socket = self.socket
        Task { await socket.close() }
        handleClose(error: nil)
    }

    // MARK: - Ready

    /// Suspends until the server sends `cf_agent_identity` for the current
    /// connection. Returns immediately if already identified. Resets on close, so
    /// it can be awaited again after a reconnect (mirrors the reference's
    /// `ready` promise / `_resetReady`).
    public func ready() async {
        if identified { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readyWaiters.append(continuation)
        }
    }

    // MARK: - State

    /// Pushes a new state to the agent.
    ///
    /// Sends a `cf_agent_state` frame, optimistically updates ``state`` locally,
    /// and fires ``onStateUpdate`` with ``StateUpdateSource/client``. The agent
    /// will broadcast the canonical state back, which updates ``state`` again
    /// (with source ``StateUpdateSource/server``).
    public func setState(_ newState: State) {
        do {
            let json = try JSONValue(encodable: newState)
            let text = try OutboundAgentMessage.setState(json)
            sendRaw(text)
            self.state = newState
            onStateUpdate?(newState, .client)
        } catch {
            // Encoding the local state should not fail for a Codable State; if it
            // does, surface via the state-update error hook to avoid a silent drop.
            onStateUpdateError?("Failed to encode state: \(error)")
        }
    }

    // MARK: - RPC

    /// Calls a method on the agent and awaits its single result.
    ///
    /// A per-call UUID correlates the request with its `rpc` response. The result
    /// is decoded from the response's `result` JSON into `R`. If the server
    /// returns `{ success: false, error }`, throws ``AgentClientError/rpc(_:)``.
    /// If the connection closes first, throws
    /// ``AgentClientError/connectionClosed``. If `timeout` elapses, throws
    /// ``AgentClientError/timeout(method:duration:)``.
    ///
    /// - Parameters:
    ///   - method: The remote method name.
    ///   - args: Positional arguments as JSON values. Defaults to none.
    ///   - returning: The expected return type.
    ///   - timeout: Optional timeout; `nil` waits indefinitely.
    /// - Returns: The decoded result.
    public func call<R: Decodable>(
        _ method: String,
        _ args: [JSONValue] = [],
        returning: R.Type = R.self,
        timeout: Duration? = nil
    ) async throws -> R {
        let id = newUUIDLower()
        let resultJSON: JSONValue = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCalls[id] = .single(continuation)
                armTimeout(id: id, method: method, timeout: timeout)
                do {
                    let text = try OutboundAgentMessage.rpcRequest(
                        id: id, method: method, args: args
                    )
                    sendRaw(text)
                } catch {
                    resolvePending(id: id, with: .failure(AgentClientError.encodingFailed))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolvePending(id: id, with: .failure(CancellationError()))
            }
        }
        return try resultJSON.decode(as: R.self)
    }

    /// Calls a streaming method on the agent, returning the chunks as they
    /// arrive.
    ///
    /// Each intermediate `rpc` response (`done` absent or `false`) yields its
    /// `result` as a ``JSONValue``; the terminal frame (`done: true`) also yields
    /// its final `result` and then finishes the stream. A `{ success: false }`
    /// frame, or a connection close, finishes the stream with an error. Cancel
    /// the iterating task to abandon the call.
    ///
    /// - Parameters:
    ///   - method: The remote method name.
    ///   - args: Positional arguments. Defaults to none.
    /// - Returns: An async stream of result chunks.
    public func callStream(
        _ method: String,
        _ args: [JSONValue] = []
    ) -> AsyncThrowingStream<JSONValue, Error> {
        let id = newUUIDLower()
        return AsyncThrowingStream { continuation in
            pendingCalls[id] = .stream(continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.discardPending(id: id)
                }
            }
            do {
                let text = try OutboundAgentMessage.rpcRequest(
                    id: id, method: method, args: args
                )
                sendRaw(text)
            } catch {
                continuation.finish(throwing: AgentClientError.encodingFailed)
                pendingCalls[id] = nil
            }
        }
    }

    // MARK: - AgentConnectionProviding

    /// Sends a raw JSON text frame (queued while disconnected, flushed on open).
    public func send(_ text: String) {
        sendRaw(text)
    }

    /// Returns a fresh multicast subscription to inbound raw text frames.
    public func inboundMessages() -> AsyncStream<String> {
        let id = UUID()
        return AsyncStream { continuation in
            inboundSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.inboundSubscribers[id] = nil
                }
            }
        }
    }

    /// The HTTP form of the agent URL, used by the chat layer for history fetches.
    public var httpBaseURL: URL? { httpURLValue }

    // MARK: - Event loop

    /// Consumes the socket's event stream on a `Task` and marshals each event to
    /// the main actor for handling.
    private func startEventLoop() {
        let events = socket.events
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: ReconnectingWebSocket.Event) {
        switch event {
        case .open:
            setConnection(.connected)
        case let .message(text):
            handleMessage(text)
        case .close:
            handleClose(error: nil)
        case let .error(error):
            handleClose(error: error)
        }
    }

    private func handleMessage(_ text: String) {
        // Fan out the raw frame to subscribers (chat transport) first, so they
        // see every frame regardless of whether the core client recognizes it.
        for continuation in inboundSubscribers.values {
            continuation.yield(text)
        }

        guard let data = text.data(using: .utf8) else { return }
        let inbound: InboundAgentMessage
        do {
            inbound = try JSONDecoder().decode(InboundAgentMessage.self, from: data)
        } catch {
            // Silently ignore invalid / unrecognized messages (matches reference).
            return
        }

        switch inbound {
        case let .identity(message):
            handleIdentity(message)
        case let .state(message):
            handleStateBroadcast(message)
        case let .stateError(message):
            onStateUpdateError?(message.error)
        case let .rpc(response):
            handleRPCResponse(response)
        case .unknown:
            break
        }
    }

    private func handleIdentity(_ message: AgentIdentityMessage) {
        identified = true
        resolveReadyWaiters()

        // Server is authoritative for the instance name. `agent` is a `let`: the
        // kebab-cased class name is fixed at init and the server reports the same
        // namespace, so only `name` is updated here; both server values are
        // surfaced via the callback.
        name = message.name

        onIdentity?(message.name, message.agent)
    }

    private func handleStateBroadcast(_ message: AgentStateMessage) {
        do {
            let decoded = try message.state.decode(as: State.self)
            state = decoded
            onStateUpdate?(decoded, .server)
        } catch {
            // A broadcast we cannot decode into State is surfaced as a state error
            // rather than crashing; keep the previous state.
            onStateUpdateError?("Failed to decode server state: \(error)")
        }
    }

    private func handleRPCResponse(_ response: RPCResponse) {
        guard let pending = pendingCalls[response.id] else { return }

        // Failure terminates either kind of pending call.
        if !response.success {
            let message = response.error ?? "RPC call failed"
            resolvePending(id: response.id, with: .failure(AgentClientError.rpc(message)))
            return
        }

        let result = response.result ?? .null

        switch pending {
        case let .single(continuation):
            // Non-streaming: `done` absent → resolve. Streaming into a `call`:
            // resolve on the terminal frame; ignore intermediate chunks.
            if let done = response.done, done == false {
                // Intermediate chunk for a single call; the reference forwards it
                // to stream callbacks only. With `call` there is none, so we wait
                // for the terminal frame.
                return
            }
            cancelTimeout(id: response.id)
            pendingCalls[response.id] = nil
            continuation.resume(returning: result)

        case let .stream(continuation):
            if let done = response.done {
                if done {
                    continuation.yield(result)
                    continuation.finish()
                    cancelTimeout(id: response.id)
                    pendingCalls[response.id] = nil
                } else {
                    continuation.yield(result)
                }
            } else {
                // Non-streaming response delivered to a stream call: emit and end.
                continuation.yield(result)
                continuation.finish()
                cancelTimeout(id: response.id)
                pendingCalls[response.id] = nil
            }
        }
    }

    private func handleClose(error: Error?) {
        if identified { identified = false }
        // Reset ready so it can be awaited again after reconnect. Waiters from a
        // closed connection are left to resolve on the next identity; the
        // reference leaves them pending across reconnect as well.
        rejectAllPending(AgentClientError.connectionClosed)
        setConnection(.closed(error))
    }

    // MARK: - Pending-call management

    private func armTimeout(id: String, method: String, timeout: Duration?) {
        guard let timeout else { return }
        timeoutTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            if Task.isCancelled { return }
            self?.resolvePending(
                id: id,
                with: .failure(AgentClientError.timeout(method: method, duration: timeout))
            )
        }
    }

    private func cancelTimeout(id: String) {
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
    }

    /// Resolves a pending call with a success value or error and removes it.
    private func resolvePending(id: String, with result: Result<JSONValue, Error>) {
        guard let pending = pendingCalls.removeValue(forKey: id) else { return }
        cancelTimeout(id: id)
        switch pending {
        case let .single(continuation):
            continuation.resume(with: result)
        case let .stream(continuation):
            switch result {
            case let .success(value):
                continuation.yield(value)
                continuation.finish()
            case let .failure(error):
                continuation.finish(throwing: error)
            }
        }
    }

    /// Drops a pending call's bookkeeping without resuming it (used when a stream
    /// consumer terminates the stream itself).
    private func discardPending(id: String) {
        pendingCalls[id] = nil
        cancelTimeout(id: id)
    }

    /// Rejects every pending call with the given error (on close / disconnect).
    private func rejectAllPending(_ error: Error) {
        let calls = pendingCalls
        pendingCalls.removeAll()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        for pending in calls.values {
            switch pending {
            case let .single(continuation):
                continuation.resume(throwing: error)
            case let .stream(continuation):
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: - Ready waiters

    private func resolveReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Helpers

    private func sendRaw(_ text: String) {
        let socket = self.socket
        Task { await socket.send(text) }
    }

    private func setConnection(_ phase: ConnectionPhase) {
        guard connection != phase else { return }
        connection = phase
        onConnectionChange?(phase)
    }

    private static func mapScheme(
        _ scheme: AgentClientOptions.ConnectionProtocol
    ) -> PartySocketURL.WebSocketScheme {
        switch scheme {
        case .ws: return .ws
        case .wss: return .wss
        }
    }
}
