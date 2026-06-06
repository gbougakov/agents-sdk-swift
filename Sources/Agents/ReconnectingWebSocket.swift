import Foundation

/// A reconnecting WebSocket built on `URLSessionWebSocketTask`.
///
/// This is a Swift port of the reference `partysocket` `ReconnectingWebSocket`
/// (`node_modules/partysocket/dist/ws.js`). It reproduces that client's
/// reconnection semantics exactly so behaviour is wire-identical to the JS SDK:
///
/// - **Exponential backoff.** Before reconnect attempt `n` (`n >= 2`) the actor
///   waits `min(minReconnectionDelay * growFactor^(n - 1), maxReconnectionDelay)`.
///   The first attempt (`n <= 1`) is immediate. See ``ReconnectionConfig/delay(forRetryCount:)``.
/// - **Uptime-based reset.** Once a connection has stayed open for `minUptime`,
///   the retry counter resets to zero, so a long-lived connection that later
///   drops starts its backoff curve fresh.
/// - **Connection timeout.** If a connection does not open within
///   `connectionTimeout`, the attempt is treated as a failure and a reconnect is
///   scheduled.
/// - **Infinite retries** by default (`maxRetries = .max`).
/// - **Outbound queueing.** ``send(_:)`` enqueues text while the socket is not
///   open and flushes the queue (in order) on the next open. Chat stream
///   resumption relies on this so a message submitted mid-reconnect is delivered
///   once the socket comes back. The queue is bounded by `maxEnqueuedMessages`.
///
/// Unlike browsers, `URLSession` permits arbitrary headers on the WebSocket
/// upgrade request, so the actor connects from a caller-supplied
/// ``RequestProvider`` closure that is **re-evaluated before every (re)connect**.
/// This lets callers refresh short-lived auth tokens (header or query-param) and
/// rebuild the URL on each attempt, mirroring `useAgent`'s async `query`.
///
/// Lifecycle and inbound frames are surfaced through ``events`` as an
/// `AsyncStream<Event>`. Only a single consumer is supported; the stream is
/// created once at init.
public actor ReconnectingWebSocket {

    // MARK: - Event

    /// A lifecycle or message event emitted on the ``events`` stream.
    public enum Event: Sendable {
        /// The socket opened and is ready to send and receive frames. Any
        /// queued outbound messages have been flushed by the time this is
        /// delivered.
        case open

        /// A text frame was received from the server. (Binary frames are
        /// ignored; the agent protocol is JSON text.)
        case message(String)

        /// The socket closed. Carries the WebSocket close code and optional
        /// reason. A reconnect may still be scheduled afterwards unless the
        /// close was caused by ``close(code:reason:)``.
        case close(code: Int, reason: String?)

        /// A transport-level error occurred (connection failure, timeout, or
        /// receive error). A reconnect is scheduled after this is delivered.
        case error(Error)
    }

    /// Re-evaluable provider of the upgrade request, resolved before each
    /// (re)connect. Throwing propagates as an `.error` event and schedules a
    /// retry, exactly as a failed URL/protocol resolution does in the reference.
    public typealias RequestProvider = @Sendable () async throws -> URLRequest

    // MARK: - Errors

    /// Errors raised by the reconnecting transport itself.
    public enum TransportError: Error, Sendable {
        /// The connection did not open within `connectionTimeout`.
        case timeout
    }

    // MARK: - Stored state

    private let provider: RequestProvider
    private let config: ReconnectionConfig
    private let session: URLSession

    /// The `AsyncStream` consumers iterate for lifecycle + message events.
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    /// The currently active task, if any.
    private var task: URLSessionWebSocketTask?

    /// A monotonically increasing identifier for the live connection attempt.
    /// Used so that callbacks (timeout, receive loop) belonging to a superseded
    /// attempt are ignored.
    private var generation: Int = 0

    /// Mirrors partysocket's `_retryCount` (starts at -1; incremented at the top
    /// of each connect; reset to 0 on accept-open).
    private var retryCount: Int = -1

    /// `true` while the socket should attempt to (re)connect. Cleared by
    /// ``close(code:reason:)`` (matches `_shouldReconnect`).
    private var shouldReconnect: Bool = true

    /// Mirrors partysocket's `_closeCalled`: set when ``close(code:reason:)`` is
    /// invoked so an in-flight connect aborts instead of opening.
    private var closeCalled: Bool = false

    /// Prevents overlapping connect attempts (mirrors `_connectLock`).
    private var connecting: Bool = false

    /// Whether the socket is currently open (queue flushing depends on this).
    private var isOpen: Bool = false

    /// Outbound text buffered while the socket is not open.
    private var messageQueue: [String] = []

    /// The task that fires `minUptime` after open to reset the retry counter.
    private var uptimeTask: Task<Void, Never>?

    /// The task enforcing `connectionTimeout` for the current attempt.
    private var timeoutTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a reconnecting WebSocket.
    ///
    /// The connection is **not** opened by this initializer; call ``connect()``
    /// to begin. (The owning `AgentClient` decides when to connect based on
    /// `AgentClientOptions.startClosed`.)
    ///
    /// - Parameters:
    ///   - requestProvider: An async closure that produces the upgrade
    ///     `URLRequest`. Re-evaluated before every (re)connect so headers,
    ///     auth tokens, and the URL (including a refreshed query string) can
    ///     change between attempts.
    ///   - configuration: Reconnection / backoff configuration. Defaults to the
    ///     reference PartySocket values.
    ///   - session: The `URLSession` used to create WebSocket tasks. Defaults to
    ///     a session with the shared configuration; inject a custom session in
    ///     tests.
    public init(
        requestProvider: @escaping RequestProvider,
        configuration: ReconnectionConfig = .default,
        session: URLSession = URLSession(configuration: .default)
    ) {
        self.provider = requestProvider
        self.config = configuration
        self.session = session

        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { c in
            cont = c
        }
        self.continuation = cont
    }

    // MARK: - Public API

    /// Begins connecting (or reconnecting). Idempotent: a no-op if a connect is
    /// already in flight or the socket is already open.
    ///
    /// Calling this after a prior ``close(code:reason:)`` re-enables
    /// reconnection (mirrors partysocket's `reconnect`, resetting the retry
    /// counter).
    public func connect() {
        // Re-enable reconnection if a previous close disabled it.
        shouldReconnect = true
        closeCalled = false
        if isOpen { return }
        scheduleConnect()
    }

    /// Closes the socket and disables reconnection.
    ///
    /// - Parameters:
    ///   - code: The WebSocket close code. Defaults to `1000` (normal closure).
    ///   - reason: An optional close reason string.
    public func close(code: Int = 1000, reason: String? = nil) {
        closeCalled = true
        shouldReconnect = false
        clearTimers()

        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        let reasonData = reason?.data(using: .utf8)
        task?.cancel(with: closeCode, reason: reasonData)
        task = nil
        isOpen = false
    }

    /// Enqueues a text frame to be sent over the WebSocket.
    ///
    /// If the socket is open the frame is sent immediately; otherwise it is
    /// buffered (up to `maxEnqueuedMessages`) and flushed, in order, on the next
    /// open.
    ///
    /// - Parameter text: The UTF-8 text payload (a JSON-encoded agent message).
    public func send(_ text: String) {
        if isOpen, let task {
            sendNow(text, on: task)
        } else if messageQueue.count < config.maxEnqueuedMessages {
            messageQueue.append(text)
        }
    }

    // MARK: - Connect scheduling (port of _connect)

    /// Schedules a connection attempt after the appropriate backoff delay,
    /// honouring `maxRetries` and the connect lock. Mirrors `_connect`.
    private func scheduleConnect() {
        if connecting || !shouldReconnect { return }
        connecting = true

        if retryCount >= config.maxRetries {
            connecting = false
            return
        }

        retryCount += 1
        let delay = config.delay(forRetryCount: retryCount)
        let attempt = generation &+ 1
        generation = attempt

        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.performConnect(attempt: attempt)
        }
    }

    /// Resolves the request provider and opens a `URLSessionWebSocketTask`.
    /// Mirrors the `.then` body of `_connect`.
    private func performConnect(attempt: Int) async {
        // A newer attempt (or a close) superseded this one while waiting.
        guard attempt == generation else {
            connecting = false
            return
        }

        let request: URLRequest
        do {
            request = try await provider()
        } catch {
            connecting = false
            // Mirror _handleError: surface, then reconnect.
            emit(.error(error))
            scheduleConnect()
            return
        }

        // close() may have been called while resolving the request.
        guard !closeCalled, attempt == generation else {
            connecting = false
            return
        }

        let newTask = session.webSocketTask(with: request)
        self.task = newTask
        self.isOpen = false
        connecting = false

        newTask.resume()

        // Arm the connection timeout. URLSessionWebSocketTask has no explicit
        // "open" callback, so we treat the first successful receive (or the
        // timeout firing first) as the open/failure signal.
        startTimeout(attempt: attempt)

        // Begin receiving; the first frame both signals "open" and delivers a
        // message.
        receive(on: newTask, attempt: attempt, awaitingOpen: true)
    }

    // MARK: - Open handling (port of _handleOpen / _acceptOpen)

    /// Marks the connection open: cancels the connect timeout, flushes the
    /// outbound queue, arms the uptime reset, and emits `.open`.
    private func handleOpen(attempt: Int, on task: URLSessionWebSocketTask) {
        guard attempt == generation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        isOpen = true

        // Arm uptime reset (mirrors _uptimeTimeout -> _acceptOpen).
        uptimeTask?.cancel()
        let uptime = config.minUptime
        uptimeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(uptime * 1_000_000_000))
            await self?.acceptOpen(attempt: attempt)
        }

        // Flush queued messages in order (mirrors _handleOpen's forEach).
        let queued = messageQueue
        messageQueue.removeAll()
        for text in queued {
            sendNow(text, on: task)
        }

        emit(.open)
    }

    /// Resets the retry counter once the connection has been up for `minUptime`.
    /// Mirrors `_acceptOpen`.
    private func acceptOpen(attempt: Int) {
        guard attempt == generation else { return }
        retryCount = 0
    }

    // MARK: - Receive loop (port of _handleMessage)

    /// Recursively reads frames from the task. The first read (with
    /// `awaitingOpen == true`) doubles as the open signal. A receive failure is
    /// treated as an error + close and triggers a reconnect.
    private func receive(
        on task: URLSessionWebSocketTask,
        attempt: Int,
        awaitingOpen: Bool
    ) {
        Task { [weak self] in
            do {
                let message = try await task.receive()
                guard let self else { return }
                await self.handleReceived(
                    message,
                    on: task,
                    attempt: attempt,
                    awaitingOpen: awaitingOpen
                )
            } catch {
                await self?.handleReceiveFailure(error, attempt: attempt)
            }
        }
    }

    private func handleReceived(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask,
        attempt: Int,
        awaitingOpen: Bool
    ) {
        guard attempt == generation else { return }

        // The first successful receive confirms the upgrade succeeded.
        if awaitingOpen {
            handleOpen(attempt: attempt, on: task)
        }

        switch message {
        case let .string(text):
            emit(.message(text))
        case let .data(data):
            // The agent protocol is JSON text; tolerate a server that frames it
            // as binary by decoding UTF-8.
            if let text = String(data: data, encoding: .utf8) {
                emit(.message(text))
            }
        @unknown default:
            break
        }

        // Continue reading.
        receive(on: task, attempt: attempt, awaitingOpen: false)
    }

    /// Handles a receive failure: emits `.error` + `.close` and schedules a
    /// reconnect. Mirrors `_handleError` -> `_disconnect` -> `_connect`.
    private func handleReceiveFailure(_ error: Error, attempt: Int) {
        guard attempt == generation else { return }
        disconnectAndReconnect(error: error, code: 1006, reason: nil)
    }

    // MARK: - Timeout (port of _handleTimeout)

    /// Arms the connection-open timeout for the current attempt.
    private func startTimeout(attempt: Int) {
        timeoutTask?.cancel()
        let timeout = config.connectionTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.handleTimeout(attempt: attempt)
        }
    }

    private func handleTimeout(attempt: Int) {
        guard attempt == generation, !isOpen else { return }
        disconnectAndReconnect(error: TransportError.timeout, code: 1006, reason: "timeout")
    }

    // MARK: - Disconnect + reconnect (port of _handleError / _disconnect / _handleClose)

    /// Tears down the current task, emits `.error` then `.close`, and schedules
    /// a reconnect if reconnection is still enabled.
    private func disconnectAndReconnect(error: Error, code: Int, reason: String?) {
        // Invalidate this attempt so straggling callbacks are ignored.
        generation &+= 1
        clearTimers()

        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .abnormalClosure
        task?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
        task = nil
        isOpen = false

        emit(.error(error))
        emit(.close(code: code, reason: reason))

        if shouldReconnect {
            scheduleConnect()
        }
    }

    // MARK: - Helpers

    /// Sends a text frame on a live task. A send failure is treated like a
    /// receive failure (error + reconnect), matching how the reference's
    /// underlying socket surfaces send errors.
    private func sendNow(_ text: String, on task: URLSessionWebSocketTask) {
        let attempt = generation
        Task { [weak self] in
            do {
                try await task.send(.string(text))
            } catch {
                await self?.handleReceiveFailure(error, attempt: attempt)
            }
        }
    }

    private func clearTimers() {
        timeoutTask?.cancel()
        timeoutTask = nil
        uptimeTask?.cancel()
        uptimeTask = nil
    }

    /// Yields an event to the stream. `nonisolated`-safe because
    /// `AsyncStream.Continuation` is `Sendable`.
    private func emit(_ event: Event) {
        continuation.yield(event)
    }

    deinit {
        continuation.finish()
    }
}
