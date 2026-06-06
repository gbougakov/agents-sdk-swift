import Foundation

/// Converts a camelCase (or SCREAMING_CASE) string to kebab-case.
///
/// This is a direct port of `camelCaseToKebabCase` from the reference
/// `packages/agents/src/utils.ts`. The agent class name supplied by callers is
/// run through this to form the "party" / namespace segment of the URL.
///
/// Behaviour, matching the reference exactly:
/// - If the string is entirely uppercase (and not entirely lowercase, i.e. it
///   contains at least one cased letter), it is lowercased and underscores are
///   replaced with hyphens. e.g. `"MY_AGENT"` -> `"my-agent"`.
/// - Otherwise each uppercase ASCII letter is replaced with `"-"` + its
///   lowercase form, a leading hyphen is dropped, remaining underscores become
///   hyphens, and a single trailing hyphen is removed.
///   e.g. `"MyAgent"` -> `"my-agent"`, `"chatAgent"` -> `"chat-agent"`.
///
/// - Parameter str: The string to convert.
/// - Returns: The kebab-case representation.
public func camelCaseToKebabCase(_ str: String) -> String {
    // If string is all uppercase (and has some cased content), lowercase it
    // and convert underscores to hyphens.
    if str == str.uppercased() && str != str.lowercased() {
        return str.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    // Otherwise handle camelCase -> kebab-case: prefix each uppercase ASCII
    // letter with a hyphen and lowercase it.
    var kebabified = ""
    kebabified.reserveCapacity(str.count + 4)
    for character in str {
        if character.isASCII && character.isUppercase {
            kebabified.append("-")
            kebabified.append(Character(character.lowercased()))
        } else {
            kebabified.append(character)
        }
    }

    // Drop a single leading hyphen (introduced when the first char was uppercase).
    if kebabified.hasPrefix("-") {
        kebabified.removeFirst()
    }

    // Convert any remaining underscores to hyphens, then strip a single
    // trailing hyphen.
    kebabified = kebabified.replacingOccurrences(of: "_", with: "-")
    if kebabified.hasSuffix("-") {
        kebabified.removeLast()
    }
    return kebabified
}

/// Builds the WebSocket and HTTP URLs used to talk to a Cloudflare Agent,
/// porting `getPartyInfo`/host-normalization from the `partysocket` package and
/// the agent-specific defaults (`prefix: "agents"`, room default `"default"`,
/// kebab-cased agent namespace) from `packages/agents/src/client.ts`.
///
/// This is a pure value type: it performs no networking and is fully
/// deterministic given its inputs, so it can be unit-tested in isolation.
///
/// ## URL shape
/// Standard routing:
/// ```
/// ws(s)://{host}/agents/{kebab(agent)}/{room}{path}?_pk={id}&{query}
/// ```
/// With an explicit `basePath` (bypasses agent/name construction):
/// ```
/// ws(s)://{host}/{basePath}{path}?_pk={id}&{query}
/// ```
/// The HTTP form (``httpURL``) is identical but with the `ws`/`wss` scheme
/// swapped for `http`/`https`; it is used for chat history fetches and
/// `agentFetch`.
public struct PartySocketURL: Sendable, Hashable {
    /// The transport scheme selected for the WebSocket URL.
    public enum WebSocketScheme: String, Sendable, Hashable {
        /// Insecure WebSocket (`ws://`). Used for localhost / private-network hosts.
        case ws
        /// Secure WebSocket (`wss://`). Used for public hosts.
        case wss

        /// The matching HTTP scheme (`ws` -> `http`, `wss` -> `https`).
        var httpScheme: String {
            switch self {
            case .ws: return "http"
            case .wss: return "https"
            }
        }
    }

    /// The host after stripping any leading `http(s)://`/`ws(s)://` and a single
    /// trailing slash. May include a port (e.g. `"localhost:8787"`).
    public let host: String

    /// The path segment following the host, e.g. `"agents/chat-agent/default"`
    /// or a caller-supplied `basePath`. Never has a leading or trailing slash of
    /// its own beyond the appended `path`.
    public let pathComponent: String

    /// The optional extra path (already normalized to begin with `/`, or empty).
    public let extraPath: String

    /// The connection id sent as the `_pk` query parameter on every connect.
    public let connectionId: String

    /// Ordered, non-nil query parameters appended after `_pk`.
    public let query: [(name: String, value: String)]

    /// The resolved WebSocket scheme.
    public let scheme: WebSocketScheme

    /// Creates a URL builder for an Agent connection.
    ///
    /// Mirrors `getPartyInfo` host normalization and the agent client defaults.
    ///
    /// - Parameters:
    ///   - host: The host, optionally prefixed with a scheme (`http(s)://` or
    ///     `ws(s)://`) and/or a trailing slash; both are stripped. May contain a port.
    ///   - agent: The agent class name. Converted to a kebab-case namespace via
    ///     ``camelCaseToKebabCase(_:)``. Ignored when `basePath` is non-nil.
    ///   - name: The specific agent instance / room name. Defaults to `"default"`
    ///     when nil. Ignored when `basePath` is non-nil.
    ///   - basePath: When set, used verbatim as the path (after the host),
    ///     bypassing the `agents/{agent}/{room}` construction.
    ///   - path: Additional path appended to the URL. Must not begin with `/`.
    ///   - query: Ordered query parameters. Entries whose value is `nil` are
    ///     dropped, matching `partysocket`'s `valueIsNotNil` filter.
    ///   - connectionId: The PartySocket connection id, sent as `_pk`. Callers
    ///     supply a stable id (a lowercased UUID) reused across reconnects.
    ///   - protocolOverride: When set, forces the WebSocket scheme regardless of
    ///     the host. Matches `partysocket`'s explicit `protocol` option.
    public init(
        host: String,
        agent: String,
        name: String? = nil,
        basePath: String? = nil,
        path: String? = nil,
        query: [(name: String, value: String?)] = [],
        connectionId: String,
        protocolOverride: WebSocketScheme? = nil
    ) {
        // Strip a leading http(s)://, ws(s):// scheme, then a single trailing
        // slash. Mirrors: rawHost.replace(/^(http|https|ws|wss):\/\//, "").
        let normalizedHost = Self.normalizeHost(host)
        self.host = normalizedHost

        // path must not start with a slash; mirror reference by prefixing with
        // "/" when present, otherwise empty.
        if let path, !path.isEmpty {
            self.extraPath = path.hasPrefix("/") ? path : "/\(path)"
        } else {
            self.extraPath = ""
        }

        // basePath bypasses agent/name construction. Otherwise:
        //   "agents/{kebab(agent)}/{room}".
        if let basePath, !basePath.isEmpty {
            self.pathComponent = basePath
        } else {
            let namespace = camelCaseToKebabCase(agent)
            let room = name ?? "default"
            self.pathComponent = "agents/\(namespace)/\(room)"
        }

        self.connectionId = connectionId

        // Drop nil-valued query entries, preserving order.
        self.query = query.compactMap { entry in
            entry.value.map { (entry.name, $0) }
        }

        self.scheme = protocolOverride ?? Self.resolveScheme(host: normalizedHost)
    }

    /// Strips a leading `http(s)://`/`ws(s)://` scheme and a single trailing
    /// slash from the supplied host string.
    static func normalizeHost(_ rawHost: String) -> String {
        var host = rawHost
        for prefix in ["https://", "http://", "wss://", "ws://"] {
            if host.hasPrefix(prefix) {
                host.removeFirst(prefix.count)
                break
            }
        }
        if host.hasSuffix("/") {
            host.removeLast()
        }
        return host
    }

    /// Determines whether a (normalized) host is localhost / private-network and
    /// therefore should use insecure `ws`, otherwise secure `wss`.
    ///
    /// Mirrors the prefix checks in `getPartyInfo`:
    /// `localhost:`, `127.0.0.1:`, `192.168.`, `10.`, `172.16`–`172.31`,
    /// and `[::ffff:7f00:1]:`.
    static func resolveScheme(host: String) -> WebSocketScheme {
        if host.hasPrefix("localhost:")
            || host.hasPrefix("127.0.0.1:")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || host.hasPrefix("[::ffff:7f00:1]:")
            || isPrivate172(host: host)
        {
            return .ws
        }
        return .wss
    }

    /// True for hosts in the `172.16.0.0`–`172.31.255.255` private range.
    ///
    /// Mirrors the reference's string comparison:
    /// `host.startsWith("172.") && host.split(".")[1] >= "16" && <= "31"`.
    private static func isPrivate172(host: String) -> Bool {
        guard host.hasPrefix("172.") else { return false }
        // Second dotted component, compared lexicographically like the reference.
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count > 1 else { return false }
        let second = String(components[1])
        return second >= "16" && second <= "31"
    }

    /// The base URL (no query string) shared by the WS and HTTP forms, for a
    /// given scheme. e.g. `ws://localhost:8787/agents/chat-agent/default`.
    private func baseURLString(scheme schemeString: String) -> String {
        "\(schemeString)://\(host)/\(pathComponent)\(extraPath)"
    }

    /// Builds an `application/x-www-form-urlencoded` query string of `_pk`
    /// followed by the non-nil caller query parameters, matching `partysocket`'s
    /// `URLSearchParams` ordering (`defaultParams` first, then query) and
    /// encoding rules exactly.
    ///
    /// `URLComponents`/`URLQueryItem` is deliberately *not* used here: it leaves
    /// spaces and `&` inside a value unescaped, producing a malformed URL that
    /// does not match the wire protocol. Instead we replicate the JavaScript
    /// `URLSearchParams.toString()` serializer (space -> `+`, everything outside
    /// the unreserved set `[A-Za-z0-9*-._]` percent-encoded).
    ///
    /// The reference always appends `?` even with no extra query, because `_pk`
    /// is always present; we do the same.
    private func queryString() -> String {
        var pairs: [String] = [
            "_pk=" + Self.formURLEncode(connectionId)
        ]
        for entry in query {
            pairs.append(Self.formURLEncode(entry.name) + "=" + Self.formURLEncode(entry.value))
        }
        return pairs.joined(separator: "&")
    }

    /// Percent-encodes a single component using the `application/x-www-form-urlencoded`
    /// rules used by JavaScript's `URLSearchParams`:
    /// - The unreserved set `*`, `-`, `.`, `_` and ASCII alphanumerics are kept
    ///   literally.
    /// - A space becomes `+`.
    /// - Every other byte is percent-encoded from its UTF-8 representation.
    static func formURLEncode(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, // A-Z a-z 0-9
                 0x2A, 0x2D, 0x2E, 0x5F:                // * - . _
                result.append(Character(UnicodeScalar(byte)))
            case 0x20: // space
                result.append("+")
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }

    /// The WebSocket URL (`ws://` or `wss://`) including the `_pk` and query
    /// parameters. Returns `nil` only if the assembled string is not a valid URL.
    public var webSocketURL: URL? {
        URL(string: "\(baseURLString(scheme: scheme.rawValue))?\(queryString())")
    }

    /// The HTTP form of the URL (`http://` or `https://`), used for chat history
    /// fetches and `agentFetch`. Returns `nil` only if the assembled string is
    /// not a valid URL.
    public var httpURL: URL? {
        URL(string: "\(baseURLString(scheme: scheme.httpScheme))?\(queryString())")
    }

    /// The WebSocket URL as a string (always constructible).
    public var webSocketURLString: String {
        "\(baseURLString(scheme: scheme.rawValue))?\(queryString())"
    }

    /// The HTTP URL as a string (always constructible).
    public var httpURLString: String {
        "\(baseURLString(scheme: scheme.httpScheme))?\(queryString())"
    }

    // MARK: - Hashable / Equatable

    public static func == (lhs: PartySocketURL, rhs: PartySocketURL) -> Bool {
        lhs.host == rhs.host
            && lhs.pathComponent == rhs.pathComponent
            && lhs.extraPath == rhs.extraPath
            && lhs.connectionId == rhs.connectionId
            && lhs.scheme == rhs.scheme
            && lhs.query.count == rhs.query.count
            && zip(lhs.query, rhs.query).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(pathComponent)
        hasher.combine(extraPath)
        hasher.combine(connectionId)
        hasher.combine(scheme)
        for entry in query {
            hasher.combine(entry.name)
            hasher.combine(entry.value)
        }
    }
}
