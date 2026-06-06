import Foundation

/// Connection lifecycle phase for an ``AgentClient``.
///
/// Mirrors the WebSocket lifecycle exposed by the reference PartySocket client
/// (`open` / `message` / `close` / `error`), collapsed into the four states an
/// observer of the Swift client cares about.
///
/// The `closed` case carries the error that triggered the close, if any. A
/// clean, intentional close (e.g. via ``AgentClient/disconnect()``) carries
/// `nil`.
public enum ConnectionPhase: Sendable {
    /// No connection has been opened yet (initial state), or the client was
    /// constructed with auto-connect disabled.
    case idle

    /// A connection attempt is in flight (socket opening / upgrading).
    case connecting

    /// The WebSocket is open and ready to send and receive frames.
    case connected

    /// The connection is closed. Carries the error that caused the close, or
    /// `nil` for a clean/intentional close.
    case closed(Error?)
}

extension ConnectionPhase: Equatable {
    /// Equality ignores the associated `Error`'s concrete value (Swift `Error`
    /// is not `Equatable`); two `closed` phases compare equal when both either
    /// carry an error or both carry `nil`.
    public static func == (lhs: ConnectionPhase, rhs: ConnectionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.connecting, .connecting),
             (.connected, .connected):
            return true
        case let (.closed(lError), .closed(rError)):
            return (lError == nil) == (rError == nil)
        default:
            return false
        }
    }

    /// `true` when the phase is `closed` and carries an underlying error.
    public var isErrorClose: Bool {
        if case let .closed(error) = self { return error != nil }
        return false
    }
}

/// A query-parameter provider for the connection URL.
///
/// The reference client accepts either a static parameter map or an async
/// closure that is re-evaluated before every (re)connect — the latter is how
/// short-lived auth tokens are refreshed across reconnects (`useAgent`'s async
/// `query`). `nil` values are dropped when building the URL.
public enum QueryProvider: Sendable {
    /// A fixed set of query parameters. Entries with a `nil` value are omitted.
    case `static`([String: String?])

    /// A closure evaluated before each (re)connect, e.g. to fetch a fresh token.
    /// Entries with a `nil` value are omitted.
    case dynamic(@Sendable () async -> [String: String?])

    /// Resolves the provider to a concrete parameter map.
    public func resolve() async -> [String: String?] {
        switch self {
        case let .static(params):
            return params
        case let .dynamic(closure):
            return await closure()
        }
    }
}

/// Reconnection / backoff configuration for the underlying reconnecting
/// WebSocket.
///
/// Defaults match the reference PartySocket (`partysocket`) client exactly so
/// behaviour is wire-identical. Backoff for retry `n` (with `n >= 2`) is
/// `min(minReconnectionDelay * growFactor^(n - 1), maxReconnectionDelay)`; the
/// retry counter resets after the connection has stayed up for `minUptime`.
///
/// All durations use `TimeInterval` (seconds).
public struct ReconnectionConfig: Sendable, Equatable {
    /// Minimum delay before the first reconnection attempt. Default: 3 seconds
    /// (`3000` ms in the reference).
    public var minReconnectionDelay: TimeInterval

    /// Maximum delay between reconnection attempts (backoff cap). Default:
    /// 10 seconds (`10000` ms in the reference).
    public var maxReconnectionDelay: TimeInterval

    /// Multiplicative growth factor applied to the delay on each successive
    /// retry. Default: `1.3`.
    public var reconnectionDelayGrowFactor: Double

    /// How long a connection must stay open before the retry counter resets.
    /// Default: 5 seconds (`5000` ms in the reference).
    public var minUptime: TimeInterval

    /// How long to wait for a connection to open before treating the attempt
    /// as failed. Default: 4 seconds (`4000` ms in the reference).
    public var connectionTimeout: TimeInterval

    /// Maximum number of reconnection attempts. Default: effectively unlimited
    /// (`Int.max`, matching the reference's `Infinity`).
    public var maxRetries: Int

    /// Maximum number of outbound messages to buffer while disconnected; they
    /// are flushed on the next open. Default: effectively unlimited
    /// (`Int.max`, matching the reference's `Infinity`).
    public var maxEnqueuedMessages: Int

    /// Creates a reconnection configuration. Every parameter defaults to the
    /// reference PartySocket value, so `ReconnectionConfig()` is wire-identical
    /// to the JS client's defaults.
    public init(
        minReconnectionDelay: TimeInterval = 3.0,
        maxReconnectionDelay: TimeInterval = 10.0,
        reconnectionDelayGrowFactor: Double = 1.3,
        minUptime: TimeInterval = 5.0,
        connectionTimeout: TimeInterval = 4.0,
        maxRetries: Int = .max,
        maxEnqueuedMessages: Int = .max
    ) {
        self.minReconnectionDelay = minReconnectionDelay
        self.maxReconnectionDelay = maxReconnectionDelay
        self.reconnectionDelayGrowFactor = reconnectionDelayGrowFactor
        self.minUptime = minUptime
        self.connectionTimeout = connectionTimeout
        self.maxRetries = maxRetries
        self.maxEnqueuedMessages = maxEnqueuedMessages
    }

    /// The reference PartySocket defaults.
    public static let `default` = ReconnectionConfig()

    /// Computes the reconnection delay (in seconds) for a given retry count,
    /// matching the reference PartySocket backoff curve.
    ///
    /// - Parameter retryCount: The 1-based attempt number. A value `<= 1`
    ///   yields `0` (immediate first reconnect, as in the reference).
    /// - Returns: The delay in seconds, capped at ``maxReconnectionDelay``.
    public func delay(forRetryCount retryCount: Int) -> TimeInterval {
        guard retryCount > 1 else { return 0 }
        let raw = minReconnectionDelay
            * pow(reconnectionDelayGrowFactor, Double(retryCount - 1))
        return min(raw, maxReconnectionDelay)
    }
}

/// Configuration for connecting an ``AgentClient`` to a deployed Cloudflare
/// Agent over a single WebSocket.
///
/// Port of the reference `AgentClientOptions` (`packages/agents/src/client.ts`)
/// combined with the relevant `PartySocketOptions` fields. URL construction
/// (kebab-casing the agent name, choosing `ws`/`wss`, appending `_pk` and the
/// query string) is performed by the URL builder using these values.
public struct AgentClientOptions: Sendable {
    /// The agent class name to connect to. Converted to kebab-case when
    /// building the namespace segment of the URL. Ignored when ``basePath`` is
    /// set. Required.
    public var agent: String

    /// The specific Agent instance (room) name. Defaults to `"default"`.
    /// Ignored when ``basePath`` is set.
    public var name: String

    /// The host the Agent is deployed on, e.g. `"my-worker.workers.dev"` or
    /// `"localhost:8787"`. Any leading `http(s)://` / `ws(s)://` scheme and
    /// trailing slash are stripped during URL construction. Optional so the
    /// host can be supplied elsewhere (e.g. a default base URL).
    public var host: String?

    /// A full path that bypasses the standard `agent`/`name` URL construction.
    /// When set, the client connects to this path directly and ``agent`` /
    /// ``name`` are ignored for URL purposes (the identity still arrives from
    /// the server via `cf_agent_identity`).
    ///
    /// Example: `basePath: "user"` → `/user`; combined with ``path`` `"settings"`
    /// → `/user/settings`.
    public var basePath: String?

    /// An additional path segment appended to the constructed URL. Works with
    /// both standard routing and ``basePath``.
    ///
    /// Example (standard): `agent: "MyAgent", name: "room", path: "settings"`
    /// → `/agents/my-agent/room/settings`.
    public var path: String?

    /// Query parameters appended to the connection URL. Supports either a
    /// static map or an async closure that is re-evaluated before each
    /// (re)connect (for token refresh). `nil` values are dropped.
    public var query: QueryProvider?

    /// HTTP headers set on the WebSocket upgrade request (and on HTTP
    /// `agentFetch` requests). Unlike browsers, URLSession permits custom
    /// upgrade headers, enabling header-based auth in addition to query-param
    /// auth.
    public var headers: [String: String]?

    /// Explicitly forces the connection scheme (`ws` or `wss`), overriding the
    /// automatic localhost/private-range detection. `nil` means auto-detect.
    public var protocolOverride: ConnectionProtocol?

    /// Reconnection / backoff configuration. Defaults to the reference
    /// PartySocket values.
    public var reconnection: ReconnectionConfig

    /// When `true`, the client is constructed without immediately opening a
    /// connection; call ``AgentClient/connect()`` to begin. Mirrors
    /// PartySocket's `startClosed`. Default: `false`.
    public var startClosed: Bool

    /// The WebSocket connection scheme.
    public enum ConnectionProtocol: String, Sendable, Equatable {
        case ws
        case wss
    }

    /// Creates connection options for an ``AgentClient``.
    ///
    /// - Parameters:
    ///   - agent: The agent class name (required).
    ///   - name: The Agent instance/room name. Defaults to `"default"`.
    ///   - host: The deployment host. Optional.
    ///   - basePath: A full path that bypasses `agent`/`name` construction.
    ///   - path: An extra path segment appended to the URL.
    ///   - query: Static or async query parameters; `nil` values are dropped.
    ///   - headers: Headers for the upgrade request and HTTP fetches.
    ///   - protocolOverride: Forces `ws`/`wss`; `nil` auto-detects.
    ///   - reconnection: Backoff configuration. Defaults to reference values.
    ///   - startClosed: Construct without auto-connecting. Default `false`.
    public init(
        agent: String,
        name: String? = nil,
        host: String? = nil,
        basePath: String? = nil,
        path: String? = nil,
        query: QueryProvider? = nil,
        headers: [String: String]? = nil,
        protocolOverride: ConnectionProtocol? = nil,
        reconnection: ReconnectionConfig = .default,
        startClosed: Bool = false
    ) {
        self.agent = agent
        self.name = name ?? "default"
        self.host = host
        self.basePath = basePath
        self.path = path
        self.query = query
        self.headers = headers
        self.protocolOverride = protocolOverride
        self.reconnection = reconnection
        self.startClosed = startClosed
    }

    /// Convenience initializer for a static query map.
    public init(
        agent: String,
        name: String? = nil,
        host: String? = nil,
        basePath: String? = nil,
        path: String? = nil,
        query: [String: String?],
        headers: [String: String]? = nil,
        protocolOverride: ConnectionProtocol? = nil,
        reconnection: ReconnectionConfig = .default,
        startClosed: Bool = false
    ) {
        self.init(
            agent: agent,
            name: name,
            host: host,
            basePath: basePath,
            path: path,
            query: .static(query),
            headers: headers,
            protocolOverride: protocolOverride,
            reconnection: reconnection,
            startClosed: startClosed
        )
    }
}
