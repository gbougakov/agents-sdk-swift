# agents-sdk-swift

An idiomatic Swift client SDK for the [Cloudflare Agents SDK](https://developers.cloudflare.com/agents/).

Cloudflare's Agents SDK ships a JS/TS client plus a chat layer that talk to a server-side `Agent`
(a Durable Object built on PartyServer) over a single WebSocket. This package is a Swift port of the
**client** side of that wire protocol, with first-class SwiftUI integration so Apple-platform apps
can connect to existing Agents deployments:

- **Real-time, bidirectional, typed state sync** — your `Codable` state struct stays in sync with the agent.
- **RPC** — call server methods (`@callable`) and await typed results, including streaming RPC.
- **Chat** — the full `useAgentChat` experience: streaming assistant messages, history hydration,
  tool calls / approvals, and stream resumption on reconnect.
- **`@Observable`** — connection state, agent state, and chat messages are observable properties
  SwiftUI reads directly; no Combine, no manual `objectWillChange`.

The library mirrors the reference wire protocol exactly (message-type string literals and field
names match `packages/agents` and `packages/ai-chat`). It implements only the client; there is no
server code.

## Requirements

- Swift 6.0+ (built in Swift 6 language mode / strict concurrency)
- iOS 17 / macOS 14 / tvOS 17 / watchOS 10 or later (uses the Observation framework)

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/agents-sdk-swift.git", from: "1.0.0")
]
```

Then depend on the products you need:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Agents", package: "agents-sdk-swift"),       // core: state sync + RPC
        .product(name: "AgentsChat", package: "agents-sdk-swift"),    // chat (depends on Agents)
    ]
)
```

In Xcode: **File ▸ Add Package Dependencies…**, paste the repository URL, and add the `Agents`
and/or `AgentsChat` library products to your target.

Two products are vended:

| Product | Module | Use it for |
||||
| `Agents` | `import Agents` | Connecting, typed state sync, RPC, `agentFetch`. |
| `AgentsChat` | `import AgentsChat` | The chat session on top of an `AgentClient`. |



## Quickstart 1 — State sync

`AgentClient<State>` is a `@MainActor @Observable` class. Give it a `Codable & Sendable` struct that
matches the agent's state shape; `client.state` is populated from the agent's `initialState` on
connect and stays in sync thereafter. Calling `setState(_:)` pushes optimistically and the agent
broadcasts the canonical value back.

```swift
import Agents

// Matches the server's StateAgentState { counter, items, lastUpdated }.
struct CounterState: Codable, Sendable {
    var counter: Int
    var items: [String]
    var lastUpdated: String?
}

@MainActor
func makeClient() -> AgentClient<CounterState> {
    let client = AgentClient(
        AgentClientOptions(
            agent: "StateAgent",      // class name; kebab-cased to "state-agent" in the URL
            name: "room-123",         // instance / room (defaults to "default")
            host: "localhost:8787",   // localhost/private hosts auto-select ws:// (else wss://)
            protocolOverride: .ws     // optional; forces ws (otherwise auto-detected for localhost)
        ),
        state: CounterState.self
    )
    client.connect()                  // opens the socket (skip if you set startClosed)
    return client
}
```

Reading `client.state` from a SwiftUI `body` re-renders automatically via Observation:

```swift
import SwiftUI
import Agents

struct CounterView: View {
    @State private var client = makeClient()

    var body: some View {
        VStack {
            Text("Counter: \(client.state?.counter ?? 0)")
            Button("Increment") {
                guard var s = client.state else { return }
                s.counter += 1
                client.setState(s)    // optimistic push; server broadcasts canonical state back
            }
        }
        .task { await client.ready() } // suspends until cf_agent_identity arrives
    }
}
```

Optional callbacks are available if you prefer them to observation:
`client.onStateUpdate = { state, source in … }` (`source` is `.server` or `.client`),
`client.onConnectionChange`, `client.onIdentity`, `client.onStateUpdateError`.



## Quickstart 2 — RPC

Server methods marked `@callable()` are invoked with `call(_:_:returning:)`. Arguments are passed
positionally as `JSONValue`s (which conform to the `ExpressibleBy…Literal` protocols, so literals
work directly), and the result is decoded into the type you ask for.

```swift
import Agents

@MainActor
func runRPC(_ client: AgentClient<CounterState>) async throws {
    await client.ready()

    // increment() -> StateAgentState   (no args)
    let newState = try await client.call("increment", returning: CounterState.self)
    print("counter is now \(newState.counter)")

    // setCounter(value: number) -> StateAgentState
    let reset = try await client.call("setCounter", [42], returning: CounterState.self)
    print("counter is now \(reset.counter)")

    // addItem(item: string) -> StateAgentState
    _ = try await client.call("addItem", ["hello"], returning: CounterState.self)

    // With a timeout:
    let r = try await client.call("increment", returning: CounterState.self, timeout: .seconds(5))
    _ = r
}
```

Errors surface as `AgentClientError`: `.rpc(String)` (server returned `success: false`),
`.connectionClosed`, `.timeout(method:duration:)`, `.encodingFailed`, `.invalidURL`.

### Streaming RPC

A method that emits multiple `rpc` responses (intermediate frames followed by a `done: true` frame)
is consumed as an `AsyncThrowingStream<JSONValue, Error>`:

```swift
for try await chunk in client.callStream("streamTokens", ["a topic"]) {
    if let text = chunk.string {
        print(text, terminator: "")
    }
}
```

### One-shot HTTP (`agentFetch`)

For a plain HTTP request to an agent instance (no socket), use `agentFetch`:

```swift
import Agents

let (data, response) = try await agentFetch(
    AgentFetchOptions(agent: "StateAgent", name: "room-123", host: "localhost:8787"),
    AgentFetchRequest(method: "GET")
)
print(response.statusCode, String(decoding: data, as: UTF8.self))
```



## Quickstart 3 — Chat

`ChatSession` (in `AgentsChat`) is a `@MainActor @Observable` facade over an `AgentClient`. It
hydrates history on init, streams assistant responses, and exposes `messages` / `status` / `error`
plus tool entry points.

```swift
import Agents
import AgentsChat

// The chat agent's synced state is often empty; an empty struct is fine.
struct ChatState: Codable, Sendable {}

@MainActor
func makeChat() -> ChatSession {
    let client = AgentClient(
        AgentClientOptions(
            agent: "ChatAgent",
            name: "room-123",
            host: "localhost:8787",
            protocolOverride: .ws
        ),
        state: ChatState.self
    )
    client.connect()
    return ChatSession(client: client)   // hydrates GET /get-messages, subscribes to inbound frames
}
```

```swift
let session = makeChat()
session.sendMessage("What's the weather in London?")

// Drive a SwiftUI list from session.messages; it updates as chunks stream in.
// session.status: .ready / .submitted / .streaming / .error
// session.isStreaming: true while any stream (turn, resume, or tool continuation) is active.
```

### Client-side tools and approvals

When the model calls a tool the server cannot execute (`input-available`), `onToolCall` fires;
resolve it with `addToolOutput`. When a tool needs approval, respond with `addToolApprovalResponse`:

```swift
session.onToolCall = { call in
    // call.toolCallId / call.toolName / call.input
    if call.toolName == "getLocalTimezone" {
        await MainActor.run {
            session.addToolOutput(toolCallId: call.toolCallId, output: .string("Europe/London"))
        }
    }
}

// From an approve/reject UI:
session.addToolApprovalResponse(toolCallId: someId, approved: true)
```

`stop()` cancels the active turn (and the durable server turn), `clearHistory()` wipes local and
server history (`cf_agent_chat_clear`). Both stream resumption on reconnect and tool continuation
are handled automatically.

A complete SwiftUI chat + state example lives in [`Examples/ChatExample.swift`](Examples/ChatExample.swift).



## End-to-end verification against a local worker

This repo ships a self-contained test worker in [E2E/`](E2E/) (depends only on the published
`agents` package — no external monorepo). It exposes a `StateAgent` (state sync + RPC) and a
`CallableAgent` (pure RPC), and is driven by the [`E2ESmoke`](Sources/E2ESmoke/main.swift) target.

```bash
# Terminal 1 — start the worker
cd E2E
npm install
npm run dev                # → Ready on http://127.0.0.1:8787

# Terminal 2 — run the Swift client against it (from repo root)
swift run E2ESmoke localhost:8787
```

Expect `RESULT: PASS` (12/12 checks): identity/`ready()`, initial state push, typed RPC calls,
server→client state broadcast, and server-error propagation. See [`E2E/README.md`](E2E/README.md)
for details (including a local-dev `x-partykit-room` note). This covers the **core client**; the
chat layer (`AgentsChat`) is unit-tested but not yet covered by a live worker (that needs an
`AIChatAgent` + a model backend).

### Notes

- Hosts matching `localhost:`, `127.0.0.1:`, and private ranges (`192.168.`, `10.`, `172.16–31.`,
  the IPv6-mapped loopback) auto-select `ws://`; everything else uses `wss://`. Passing
  `protocolOverride: .ws` is the explicit, unambiguous choice for local development.
- The HTTP form used for chat history (`GET /get-messages`) and `agentFetch` is derived from the
  same host with `http(s)://`, so localhost works without TLS.
- `wrangler dev` always listens on `localhost:8787` by default; pass `--port` to change it and
  update `host` accordingly.

## License

The source code in this repository is licensed under the MIT license.

This SDK is an independent reimplementation of the wire protocols
and API shapes of the Cloudflare Agents SDK (MIT), PartyKit `partysocket` (MIT)
and `partyserver` (ISC), and the Vercel AI SDK (Apache-2.0). No upstream source
is copied here, but those projects are credited and their licenses reproduced in
**[THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md)** and
[`Third Party Licenses/`](./Third Party Licenses/). This is an unofficial project
and is not affiliated with or endorsed by any of them.
