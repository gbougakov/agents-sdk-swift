import XCTest
import Agents
@testable import AgentsChat

/// Tests for client-executed tools: schema serialization, request-body injection,
/// automatic execution of registered tools, and the ``ChatSession/onToolCall``
/// fallback for unregistered tool calls.
///
/// `ChatSession` is exercised end-to-end over a scriptable in-memory connection:
/// the test captures outbound frames, replies with literal
/// `cf_agent_use_chat_response` chunk frames (the same shape the server emits),
/// and asserts on the resulting `cf_agent_tool_result` frames.
@MainActor
final class ClientToolTests: XCTestCase {

    // MARK: - Mock connection

    /// A scriptable in-memory ``AgentConnectionProviding``.
    ///
    /// Captures every frame passed to ``send(_:)`` and lets the test push inbound
    /// frames. Unlike the real connection, pushed frames are *replayed* to late
    /// subscribers: the transport's chunk reader subscribes from an unstructured
    /// `Task` after `send`, so without replay the test would race it.
    final class MockConnection: AgentConnectionProviding {
        private(set) var sentFrames: [String] = []
        private var subscribers: [AsyncStream<String>.Continuation] = []
        private var pushed: [String] = []

        func send(_ text: String) {
            sentFrames.append(text)
        }

        func inboundMessages() -> AsyncStream<String> {
            let (stream, continuation) = AsyncStream<String>.makeStream()
            subscribers.append(continuation)
            for text in pushed {
                continuation.yield(text)
            }
            return stream
        }

        var httpBaseURL: URL? { nil }
        var identified: Bool { true }
        func ready() async {}

        /// Pushes an inbound frame to all current (and future) subscribers.
        func push(_ text: String) {
            pushed.append(text)
            for continuation in subscribers {
                continuation.yield(text)
            }
        }
    }

    // MARK: - Helpers

    private struct FrameTimeout: Error {}

    /// Polls the mock's sent frames until one's parsed tree satisfies `predicate`.
    private func waitForFrame(
        on mock: MockConnection,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        where predicate: (JSONValue) -> Bool
    ) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = mock.sentFrames
                .map({ JSONTestSupport.parse($0, file: file, line: line) })
                .first(where: predicate)
            {
                return match
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for a matching frame", file: file, line: line)
        throw FrameTimeout()
    }

    /// Builds a `cf_agent_use_chat_response` frame whose `body` is the chunk JSON.
    private func responseFrame(id: String, chunk: String, done: Bool = false) -> String {
        let object: [String: Any] = [
            "type": ChatMessageType.useChatResponse,
            "id": id,
            "body": chunk,
            "done": done,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    /// Creates a session over `mock` with hydration disabled.
    private func makeSession(mock: MockConnection, tools: [ClientTool] = []) -> ChatSession {
        ChatSession(
            client: mock,
            options: ChatOptions(getInitialMessages: { [] }),
            tools: tools
        )
    }

    /// Sends a user message and replies with a single client tool call, returning
    /// the request id. The turn is: start → tool-input-available → finish/done.
    private func runToolCallTurn(
        session: ChatSession,
        mock: MockConnection,
        toolCallId: String = "call_1",
        toolName: String,
        input: String = "{}"
    ) async throws {
        session.sendMessage("hi")
        let request = try await waitForFrame(on: mock) {
            $0["type"]?.string == ChatMessageType.useChatRequest
        }
        let requestId = try XCTUnwrap(request["id"]?.string)

        mock.push(responseFrame(id: requestId, chunk: #"{"type":"start","messageId":"m1"}"#))
        mock.push(responseFrame(
            id: requestId,
            chunk: """
            {"type":"tool-input-available","toolCallId":"\(toolCallId)",\
            "toolName":"\(toolName)","input":\(input)}
            """
        ))
        mock.push(responseFrame(id: requestId, chunk: #"{"type":"finish"}"#, done: true))
    }

    // MARK: - Schema serialization

    func testSchemaJSONOmitsNilFieldsAndPreservesOrder() {
        let tools = [
            ClientTool(
                name: "getUserTimezone",
                description: "Get the user's timezone",
                parameters: .object(["type": .string("object")])
            ) { _ in .null },
            ClientTool(name: "bare") { _ in .null },
        ]

        let json = ClientTool.schemaJSON(of: tools)

        XCTAssertEqual(json[0]?["name"]?.string, "getUserTimezone")
        XCTAssertEqual(json[0]?["description"]?.string, "Get the user's timezone")
        XCTAssertEqual(json[0]?["parameters"]?["type"]?.string, "object")
        XCTAssertEqual(json[1], .object(["name": .string("bare")]), "nil fields must be omitted")
    }

    // MARK: - Request body

    func testRequestBodyCarriesClientToolSchemas() async throws {
        let mock = MockConnection()
        let session = makeSession(mock: mock, tools: [
            ClientTool(name: "getUserTimezone", description: "old") { _ in .null }
        ])
        // Re-registering the same name replaces the original definition.
        session.registerTool(name: "getUserTimezone", description: "new") { _ in .null }

        session.sendMessage("hi")

        let request = try await waitForFrame(on: mock) {
            $0["type"]?.string == ChatMessageType.useChatRequest
        }
        let body = JSONTestSupport.parse(try XCTUnwrap(request["init"]?["body"]?.string))
        let clientTools = try XCTUnwrap(body["clientTools"])
        XCTAssertEqual(clientTools, .array([
            .object(["name": .string("getUserTimezone"), "description": .string("new")])
        ]))
    }

    func testRequestBodyOmitsClientToolsWhenNoneRegistered() async throws {
        let mock = MockConnection()
        let session = makeSession(mock: mock)

        session.sendMessage("hi")

        let request = try await waitForFrame(on: mock) {
            $0["type"]?.string == ChatMessageType.useChatRequest
        }
        let body = JSONTestSupport.parse(try XCTUnwrap(request["init"]?["body"]?.string))
        XCTAssertNil(body["clientTools"])
    }

    // MARK: - Automatic execution

    func testRegisteredToolAutoExecutesAndSendsResult() async throws {
        let mock = MockConnection()
        let session = makeSession(mock: mock, tools: [
            ClientTool(
                name: "getUserTimezone",
                description: "Get the user's timezone",
                parameters: .object(["type": .string("object")])
            ) { _ in .string("Europe/London") }
        ])
        var fallbackCalls: [ToolCall] = []
        session.onToolCall = { @MainActor call in fallbackCalls.append(call) }

        try await runToolCallTurn(session: session, mock: mock, toolName: "getUserTimezone")

        let result = try await waitForFrame(on: mock) {
            $0["type"]?.string == ChatMessageType.toolResult
        }
        XCTAssertEqual(result["toolCallId"]?.string, "call_1")
        XCTAssertEqual(result["toolName"]?.string, "getUserTimezone")
        XCTAssertEqual(result["output"]?.string, "Europe/London")
        XCTAssertEqual(result["state"]?.string, "output-available")
        XCTAssertEqual(result["autoContinue"]?.bool, true)
        XCTAssertEqual(
            result["clientTools"]?[0]?["name"]?.string,
            "getUserTimezone",
            "tool results must refresh the server's persisted client tools"
        )
        XCTAssertTrue(fallbackCalls.isEmpty, "registered tools must not reach onToolCall")
    }

    func testRegisteredToolReceivesInput() async throws {
        let mock = MockConnection()
        let received = Box<JSONValue?>(nil)
        let session = makeSession(mock: mock, tools: [
            ClientTool(name: "echo") { input in
                await MainActor.run { received.value = input }
                return input ?? .null
            }
        ])

        try await runToolCallTurn(
            session: session,
            mock: mock,
            toolName: "echo",
            input: #"{"text":"hello"}"#
        )

        let result = try await waitForFrame(on: mock) {
            $0["type"]?.string == ChatMessageType.toolResult
        }
        XCTAssertEqual(result["output"]?["text"]?.string, "hello")
        XCTAssertEqual(received.value?["text"]?.string, "hello")
    }

    func testThrowingExecuteReportsErrorAsOutputAndAutoContinues() async throws {
        struct ToolFailure: LocalizedError {
            var errorDescription: String? { "clipboard unavailable" }
        }

        let mock = MockConnection()
        let session = makeSession(mock: mock, tools: [
            ClientTool(name: "getClipboard") { _ in throw ToolFailure() }
        ])

        try await runToolCallTurn(session: session, mock: mock, toolName: "getClipboard")

        let result = try await waitForFrame(on: mock) {
            $0["type"]?.string == ChatMessageType.toolResult
        }
        XCTAssertEqual(
            result["output"]?.string,
            "Error executing tool: clipboard unavailable",
            "a thrown execute error is reported as the tool output so the model can react"
        )
        XCTAssertEqual(result["state"]?.string, "output-available")
        XCTAssertEqual(result["autoContinue"]?.bool, true, "error outputs still auto-continue")
    }

    // MARK: - onToolCall fallback

    func testUnregisteredToolFallsBackToOnToolCall() async throws {
        let mock = MockConnection()
        let session = makeSession(mock: mock, tools: [
            ClientTool(name: "getUserTimezone") { _ in .string("UTC") }
        ])
        let calls = Box<[ToolCall]>([])
        session.onToolCall = { @MainActor call in calls.value.append(call) }

        try await runToolCallTurn(session: session, mock: mock, toolName: "somethingElse")

        let deadline = Date().addingTimeInterval(5)
        while calls.value.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(calls.value.map(\.toolName), ["somethingElse"])
        XCTAssertEqual(calls.value.first?.toolCallId, "call_1")
    }

    /// A reference box for capturing values from `@Sendable` closures in tests.
    final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
