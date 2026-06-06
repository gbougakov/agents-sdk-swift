//
//  ChatExample.swift
//  agents-sdk-swift
//
//  A self-contained SwiftUI example demonstrating @Observable usage of the
//  Agents and AgentsChat modules: a live state view backed by `AgentClient`
//  and a streaming chat view backed by `ChatSession`.
//
//  This file is illustrative — it is not part of any package target, so it is
//  not compiled by `swift build`. Drop it into an iOS/macOS app target (with the
//  `Agents` and `AgentsChat` products linked) to use it. Everything is guarded by
//  `#if canImport(SwiftUI)` so it is inert on platforms without SwiftUI.
//
//  To run the state + RPC path against the bundled local worker:
//    cd E2E && npm install && npm run dev      (StateAgent/CallableAgent on :8787)
//  then `swift run E2ESmoke localhost:8787`. See the README and E2E/README.md.
//  (The chat path needs an AIChatAgent-backed worker, which this repo does not
//  yet include.)
//

#if canImport(SwiftUI)

import SwiftUI
import Agents
import AgentsChat

// MARK: - Shared configuration

private enum Demo {
    /// The reference worker host. `wrangler dev` listens here by default.
    static let host = "localhost:8787"
    /// The instance / room name to join.
    static let room = "swift-demo"
}

// MARK: - State sync demo

/// State shape mirroring the reference `playground` `StateAgent`
/// (`{ counter, items, lastUpdated }`).
struct CounterState: Codable, Sendable {
    var counter: Int
    var items: [String]
    var lastUpdated: String?
}

/// A view that observes `AgentClient.state` directly. Any change to the agent's
/// synced state — whether pushed locally via `setState` or broadcast by the
/// server — re-renders this view automatically through the Observation framework.
@available(iOS 17, macOS 14, *)
struct StateView: View {
    /// `AgentClient` is `@MainActor @Observable`, so `@State` observes it.
    @State private var client = AgentClient(
        AgentClientOptions(
            agent: "StateAgent",
            name: Demo.room,
            host: Demo.host,
            protocolOverride: .ws
        ),
        state: CounterState.self
    )

    /// Surfaces the most recent RPC error, if any.
    @State private var lastError: String?

    var body: some View {
        VStack(spacing: 16) {
            connectionBadge

            Text("Counter: \(client.state?.counter ?? 0)")
                .font(.largeTitle.monospacedDigit())

            HStack {
                Button("−") { Task { await callRPC("decrement") } }
                Button("+") { Task { await callRPC("increment") } }
                Button("Reset") { Task { await callRPC("resetState") } }
            }
            .buttonStyle(.bordered)

            // Local optimistic push (no RPC): mutate and setState.
            Button("Add item locally") {
                guard var s = client.state else { return }
                s.items.append("item \(s.items.count + 1)")
                client.setState(s)
            }

            if let items = client.state?.items, !items.isEmpty {
                List(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                }
                .frame(maxHeight: 160)
            }

            if let lastError {
                Text(lastError).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding()
        .task {
            client.connect()
            await client.ready()   // suspends until cf_agent_identity arrives
        }
    }

    /// A small badge reflecting `client.connection`, which is observable.
    @ViewBuilder private var connectionBadge: some View {
        switch client.connection {
        case .idle: Label("Idle", systemImage: "circle").foregroundStyle(.secondary)
        case .connecting: Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
        case .connected: Label("Connected", systemImage: "bolt.fill").foregroundStyle(.green)
        case .closed: Label("Closed", systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }

    /// Calls a no-argument `@callable()` returning the full state.
    private func callRPC(_ method: String) async {
        do {
            // The result also arrives as a state broadcast, so we discard it here;
            // `client.state` updates either way.
            _ = try await client.call(method, returning: CounterState.self)
            lastError = nil
        } catch {
            lastError = "\(method) failed: \(error)"
        }
    }
}

// MARK: - Chat demo

/// The chat agent's synced state is unused by this demo; an empty struct suffices.
struct ChatDemoState: Codable, Sendable {}

/// A streaming chat view backed by `ChatSession` (`@MainActor @Observable`).
/// `session.messages` and `session.status` are observed directly, so the list
/// and the composer update as assistant chunks stream in.
@available(iOS 17, macOS 14, *)
struct ChatView: View {
    @State private var session: ChatSession
    @State private var draft: String = ""

    init() {
        let client = AgentClient(
            AgentClientOptions(
                agent: "ChatAgent",
                name: Demo.room,
                host: Demo.host,
                protocolOverride: .ws
            ),
            state: ChatDemoState.self
        )
        client.connect()
        let session = ChatSession(client: client)

        // Resolve a client-side tool the server cannot execute (e.g. the
        // browser-timezone tool in the ai-chat example).
        session.onToolCall = { call in
            guard call.toolName.contains("timezone") || call.toolName.contains("Timezone") else { return }
            let tz = TimeZone.current.identifier
            await MainActor.run {
                session.addToolOutput(toolCallId: call.toolCallId, output: .string(tz))
            }
        }

        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            List(session.messages, id: \.id) { message in
                MessageRow(message: message, onApproval: handleApproval)
            }

            if session.status == .error, let error = session.error {
                Text("Error: \(error.localizedDescription)")
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.horizontal)
            }

            composer
        }
    }

    /// A text field + send/stop button. `session.isStreaming` is observable, so
    /// the button toggles automatically while a turn (or resume / tool
    /// continuation) is in flight.
    private var composer: some View {
        HStack {
            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)

            if session.isStreaming {
                Button("Stop", role: .destructive) { session.stop() }
            } else {
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.sendMessage(text)
        draft = ""
    }

    private func handleApproval(toolCallId: String, approved: Bool) {
        session.addToolApprovalResponse(toolCallId: toolCallId, approved: approved)
    }
}

/// Renders a single `UIMessage` by walking its `parts`. Demonstrates the
/// `UIMessagePart` / `ToolInvocation` model: text/reasoning, tool calls with an
/// approve/reject prompt, and tool output.
@available(iOS 17, macOS 14, *)
struct MessageRow: View {
    let message: UIMessage
    let onApproval: (_ toolCallId: String, _ approved: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(roleLabel)
                .font(.caption.bold())
                .foregroundStyle(message.role == .user ? .blue : .secondary)

            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                partView(part)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var roleLabel: String {
        switch message.role {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "Assistant"
        }
    }

    @ViewBuilder private func partView(_ part: UIMessagePart) -> some View {
        switch part {
        case let .text(text, _, _):
            Text(text)

        case let .reasoning(text, _, _):
            Text(text).italic().foregroundStyle(.secondary)

        case let .tool(name, invocation):
            toolView(name: name, invocation: invocation)

        case let .dynamicTool(name, invocation):
            toolView(name: name, invocation: invocation)

        case .stepStart:
            Divider()

        case let .file(_, filename, url, _):
            Label(filename ?? url, systemImage: "doc")

        default:
            EmptyView()
        }
    }

    /// Shows a tool's state machine, including an approve/reject prompt when the
    /// invocation is in `approval-requested`.
    @ViewBuilder private func toolView(name: String, invocation: ToolInvocation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(name) · \(invocation.state.rawValue)", systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)

            if invocation.state == .approvalRequested {
                HStack {
                    Button("Approve") { onApproval(invocation.toolCallId, true) }
                    Button("Reject", role: .destructive) { onApproval(invocation.toolCallId, false) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if invocation.state == .outputError, let errorText = invocation.errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Container

/// A tabbed container showing both demos side by side.
@available(iOS 17, macOS 14, *)
struct AgentsDemoView: View {
    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            StateView()
                .tabItem { Label("State", systemImage: "number") }
        }
    }
}

#if DEBUG
@available(iOS 17, macOS 14, *)
#Preview {
    AgentsDemoView()
}
#endif

#endif // canImport(SwiftUI)
