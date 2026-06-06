import Testing
@testable import Agents

/// Tests for ``PartySocketURL`` and ``camelCaseToKebabCase(_:)`` — the pure URL
/// builder ported from `partysocket`'s `getPartyInfo` and the agent client
/// defaults in `packages/agents/src/client.ts`.
@Suite("PartySocketURL")
struct PartySocketURLTests {

    // MARK: - Kebab casing

    @Test("camelCase agent name -> kebab-case namespace")
    func camelCaseToKebab() {
        #expect(camelCaseToKebabCase("MyAgent") == "my-agent")
        #expect(camelCaseToKebabCase("chatAgent") == "chat-agent")
        #expect(camelCaseToKebabCase("Agent") == "agent")
        #expect(camelCaseToKebabCase("StatefulCounterAgent") == "stateful-counter-agent")
    }

    @Test("SCREAMING_CASE agent name -> kebab-case namespace")
    func screamingCaseToKebab() {
        // All-uppercase strings are lowercased with underscores -> hyphens.
        #expect(camelCaseToKebabCase("MY_AGENT") == "my-agent")
        #expect(camelCaseToKebabCase("CHAT") == "chat")
    }

    @Test("already-lowercase passes through unchanged")
    func lowercasePassthrough() {
        #expect(camelCaseToKebabCase("agent") == "agent")
        #expect(camelCaseToKebabCase("my-agent") == "my-agent")
    }

    @Test("kebab-cased namespace appears in the path")
    func kebabInPath() {
        let url = PartySocketURL(
            host: "example.com",
            agent: "ChatAgent",
            connectionId: "abc"
        )
        #expect(url.pathComponent == "agents/chat-agent/default")
    }

    // MARK: - Scheme resolution (ws vs wss)

    @Test("public host -> wss", arguments: [
        "example.com",
        "my-worker.workers.dev",
        "1.2.3.4:8080",
        "172.15.0.1:80",   // just below the private 172.16 range
        "172.32.0.1:80",   // just above the private 172.31 range
        "100.64.0.1:80",
    ])
    func publicHostUsesWss(host: String) {
        let url = PartySocketURL(host: host, agent: "A", connectionId: "id")
        #expect(url.scheme == .wss)
    }

    @Test("localhost / private-range host -> ws", arguments: [
        "localhost:8787",
        "127.0.0.1:8787",
        "192.168.1.10:3000",
        "10.0.0.1:8080",
        "172.16.0.1:80",
        "172.20.5.5:80",
        "172.31.255.255:80",
        "[::ffff:7f00:1]:8787",
    ])
    func privateHostUsesWs(host: String) {
        let url = PartySocketURL(host: host, agent: "A", connectionId: "id")
        #expect(url.scheme == .ws)
    }

    @Test("explicit protocol override wins over host heuristics")
    func protocolOverrideWins() {
        let forcedSecure = PartySocketURL(
            host: "localhost:8787",
            agent: "A",
            connectionId: "id",
            protocolOverride: .wss
        )
        #expect(forcedSecure.scheme == .wss)

        let forcedInsecure = PartySocketURL(
            host: "example.com",
            agent: "A",
            connectionId: "id",
            protocolOverride: .ws
        )
        #expect(forcedInsecure.scheme == .ws)
    }

    // MARK: - Host normalization

    @Test("leading scheme and trailing slash are stripped from host", arguments: [
        "https://example.com/",
        "http://example.com",
        "wss://example.com/",
        "ws://example.com",
        "example.com",
    ])
    func hostNormalization(raw: String) {
        let url = PartySocketURL(host: raw, agent: "A", connectionId: "id")
        #expect(url.host == "example.com")
    }

    // MARK: - basePath override

    @Test("basePath bypasses agents/{agent}/{room} construction")
    func basePathOverride() {
        let url = PartySocketURL(
            host: "example.com",
            agent: "ChatAgent",
            name: "room-1",
            basePath: "custom/base/path",
            connectionId: "id"
        )
        #expect(url.pathComponent == "custom/base/path")
        #expect(url.webSocketURLString.hasPrefix("wss://example.com/custom/base/path?"))
    }

    @Test("name defaults to \"default\" when omitted")
    func nameDefaultsToDefault() {
        let url = PartySocketURL(host: "example.com", agent: "ChatAgent", connectionId: "id")
        #expect(url.pathComponent == "agents/chat-agent/default")
    }

    @Test("explicit name is used as the room segment")
    func explicitRoom() {
        let url = PartySocketURL(
            host: "example.com",
            agent: "ChatAgent",
            name: "room-123",
            connectionId: "id"
        )
        #expect(url.pathComponent == "agents/chat-agent/room-123")
    }

    @Test("extra path is appended after the room with a leading slash")
    func extraPathAppended() {
        let withSlash = PartySocketURL(
            host: "example.com",
            agent: "A",
            path: "/get-messages",
            connectionId: "id"
        )
        #expect(withSlash.extraPath == "/get-messages")

        // A path without a leading slash is normalized to begin with one.
        let withoutSlash = PartySocketURL(
            host: "example.com",
            agent: "A",
            path: "get-messages",
            connectionId: "id"
        )
        #expect(withoutSlash.extraPath == "/get-messages")
    }

    // MARK: - _pk + query encoding

    @Test("_pk is always present and carries the connection id")
    func pkAlwaysPresent() {
        let url = PartySocketURL(host: "example.com", agent: "A", connectionId: "conn-1234")
        let string = url.webSocketURLString
        #expect(string.contains("_pk=conn-1234"))
        // The reference always appends "?" because _pk is always present.
        #expect(string.contains("?"))
    }

    @Test("_pk precedes the caller's query parameters")
    func pkOrdering() {
        let url = PartySocketURL(
            host: "example.com",
            agent: "A",
            query: [("token", "secret"), ("foo", "bar")],
            connectionId: "conn"
        )
        let string = url.webSocketURLString
        let pkIndex = string.range(of: "_pk=conn")
        let tokenIndex = string.range(of: "token=secret")
        let fooIndex = string.range(of: "foo=bar")
        #expect(pkIndex != nil)
        #expect(tokenIndex != nil)
        #expect(fooIndex != nil)
        if let pk = pkIndex, let token = tokenIndex, let foo = fooIndex {
            #expect(pk.lowerBound < token.lowerBound)
            #expect(token.lowerBound < foo.lowerBound)
        }
    }

    @Test("nil-valued query entries are dropped, preserving order")
    func nilQueryDropped() {
        let url = PartySocketURL(
            host: "example.com",
            agent: "A",
            query: [("keep", "yes"), ("drop", nil), ("alsoKeep", "1")],
            connectionId: "conn"
        )
        #expect(url.query.count == 2)
        #expect(url.query[0].name == "keep")
        #expect(url.query[1].name == "alsoKeep")
        let string = url.webSocketURLString
        #expect(string.contains("keep=yes"))
        #expect(string.contains("alsoKeep=1"))
        #expect(!string.contains("drop"))
    }

    @Test("query values are percent-encoded")
    func queryPercentEncoding() {
        let url = PartySocketURL(
            host: "example.com",
            agent: "A",
            query: [("q", "a b&c")],
            connectionId: "conn"
        )
        let string = url.webSocketURLString
        // Matches JavaScript `URLSearchParams`: a space encodes as `+` and an
        // ampersand as `%26` (application/x-www-form-urlencoded).
        #expect(string.contains("q=a+b%26c"))
    }

    // MARK: - ws -> http conversion

    @Test("httpURL mirrors the WS URL with the scheme swapped (wss -> https)")
    func wssToHttps() {
        let url = PartySocketURL(
            host: "example.com",
            agent: "ChatAgent",
            name: "room-1",
            connectionId: "conn"
        )
        #expect(url.webSocketURLString.hasPrefix("wss://"))
        #expect(url.httpURLString.hasPrefix("https://"))
        // Path + query are identical apart from the scheme.
        let wsTail = String(url.webSocketURLString.dropFirst("wss".count))
        let httpTail = String(url.httpURLString.dropFirst("https".count))
        #expect(wsTail == httpTail)
    }

    @Test("httpURL mirrors the WS URL with the scheme swapped (ws -> http)")
    func wsToHttp() {
        let url = PartySocketURL(
            host: "localhost:8787",
            agent: "ChatAgent",
            connectionId: "conn"
        )
        #expect(url.webSocketURLString.hasPrefix("ws://"))
        #expect(url.httpURLString.hasPrefix("http://"))
        #expect(url.httpURLString == "http://localhost:8787/agents/chat-agent/default?_pk=conn")
    }

    @Test("full WS URL assembles host, path, room and _pk")
    func fullURLAssembly() {
        let url = PartySocketURL(
            host: "https://my-worker.workers.dev/",
            agent: "ChatAgent",
            name: "room-123",
            connectionId: "abc123"
        )
        #expect(
            url.webSocketURLString
                == "wss://my-worker.workers.dev/agents/chat-agent/room-123?_pk=abc123"
        )
    }
}
