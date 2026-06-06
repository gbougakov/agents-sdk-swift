import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Connection options for a one-shot HTTP request to a Cloudflare Agent.
///
/// Port of `AgentClientFetchOptions` from the reference
/// `packages/agents/src/client.ts`, reduced to the fields the Swift client needs
/// to build the request URL. The same URL-construction rules as the WebSocket
/// client apply: the `agent` class name is kebab-cased to form the namespace, the
/// `name` selects the instance (defaulting to `"default"`), and a non-nil
/// `basePath` bypasses that construction entirely.
///
/// ## URL shape
/// Standard routing:
/// ```
/// http(s)://{host}/agents/{kebab(agent)}/{name}?_pk={id}
/// ```
/// With an explicit `basePath`:
/// ```
/// http(s)://{host}/{basePath}?_pk={id}
/// ```
public struct AgentFetchOptions: Sendable, Hashable {
    /// The agent class name. Converted to a kebab-case namespace via
    /// ``camelCaseToKebabCase(_:)``. Ignored when ``basePath`` is non-nil.
    public var agent: String

    /// The specific agent instance / room name. Defaults to `"default"` when nil.
    /// Ignored when ``basePath`` is non-nil.
    public var name: String?

    /// The host, optionally prefixed with a scheme (`http(s)://` or `ws(s)://`)
    /// and/or a trailing slash; both are stripped. May contain a port.
    public var host: String

    /// When set, used verbatim as the path (after the host), bypassing the
    /// `agents/{agent}/{name}` construction. Mirrors the reference's `basePath`.
    public var basePath: String?

    /// Creates options for an Agent HTTP request.
    ///
    /// - Parameters:
    ///   - agent: The agent class name (kebab-cased into the namespace).
    ///   - name: The instance / room name. Defaults to `"default"` when nil.
    ///   - host: The host (scheme and trailing slash are stripped). May include a port.
    ///   - basePath: When set, replaces the constructed path.
    public init(
        agent: String,
        name: String? = nil,
        host: String,
        basePath: String? = nil
    ) {
        self.agent = agent
        self.name = name
        self.host = host
        self.basePath = basePath
    }
}

/// Initialization values for an Agent HTTP request, mirroring the subset of the
/// JavaScript `RequestInit` used by `agentFetch`.
///
/// All fields are optional; the defaults produce a plain `GET` with no extra
/// headers or body, matching `fetch(url)` with no `init`.
public struct AgentFetchRequest: Sendable {
    /// The HTTP method (e.g. `"GET"`, `"POST"`). Defaults to `"GET"`.
    public var method: String

    /// Request headers as ordered name/value pairs. Header names are applied
    /// verbatim; duplicate names are preserved in order.
    public var headers: [(name: String, value: String)]

    /// The request body, sent as-is. Callers are responsible for encoding (e.g.
    /// JSON) and for any matching `Content-Type` header.
    public var body: Data?

    /// Creates a request description.
    ///
    /// - Parameters:
    ///   - method: The HTTP method. Defaults to `"GET"`.
    ///   - headers: Ordered header name/value pairs. Defaults to empty.
    ///   - body: The request body. Defaults to `nil`.
    public init(
        method: String = "GET",
        headers: [(name: String, value: String)] = [],
        body: Data? = nil
    ) {
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// Errors thrown by ``agentFetch(_:_:_:)``.
public enum AgentFetchError: Error, Sendable {
    /// The options could not be assembled into a valid HTTP URL.
    case invalidURL

    /// The response was not an `HTTPURLResponse` (should not occur for HTTP URLs).
    case nonHTTPResponse
}

/// Makes a one-shot HTTP request to a Cloudflare Agent.
///
/// This is the Swift port of `agentFetch` from the reference
/// `packages/agents/src/client.ts`. It opens no WebSocket: it constructs the
/// HTTP form of the Agent URL (via ``PartySocketURL`` — the same builder used by
/// the WebSocket client, sharing ``camelCaseToKebabCase(_:)`` for the namespace)
/// and performs a single request with `URLSession`.
///
/// As in the reference, a `_pk` connection-id query parameter is always appended
/// (a freshly generated lowercased UUID per call, since one-shot HTTP has no
/// persistent connection identity).
///
/// - Parameters:
///   - opts: Connection options identifying the agent / instance / host.
///   - request: The request method, headers, and body. Defaults to a plain `GET`.
///   - session: The `URLSession` to use. Defaults to `.shared`.
/// - Returns: A tuple of the raw response body `Data` and the `HTTPURLResponse`.
/// - Throws: ``AgentFetchError/invalidURL`` if the URL cannot be built,
///   ``AgentFetchError/nonHTTPResponse`` if the response is not HTTP, or any
///   error thrown by the underlying `URLSession` data task.
public func agentFetch(
    _ opts: AgentFetchOptions,
    _ request: AgentFetchRequest = AgentFetchRequest(),
    session: URLSession = .shared
) async throws -> (Data, HTTPURLResponse) {
    // Build the HTTP form using the shared PartySocketURL builder so the path,
    // kebab-cased namespace, `_pk`, and host normalization match the WS client.
    let urlBuilder = PartySocketURL(
        host: opts.host,
        agent: opts.agent,
        name: opts.name,
        basePath: opts.basePath,
        connectionId: newUUIDLower()
    )

    guard let url = urlBuilder.httpURL else {
        throw AgentFetchError.invalidURL
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    for header in request.headers {
        urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
    }
    if let body = request.body {
        urlRequest.httpBody = body
    }

    let (data, response) = try await session.data(for: urlRequest)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw AgentFetchError.nonHTTPResponse
    }

    return (data, httpResponse)
}
