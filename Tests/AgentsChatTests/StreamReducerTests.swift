import XCTest
import Agents
@testable import AgentsChat

/// Tests that ``UIMessageStreamReducer`` folds a recorded chunk sequence into the expected
/// assembled ``UIMessage`` parts/states.
///
/// Chunks are built by decoding literal JSON fixtures (the same shape the server emits), so these
/// exercise the reducer through the real `UIMessageChunk` decode path.
final class StreamReducerTests: XCTestCase {

    /// Decodes a sequence of chunk-fixture strings.
    private func chunks(_ fixtures: [String], file: StaticString = #filePath, line: UInt = #line) -> [UIMessageChunk] {
        fixtures.compactMap { JSONTestSupport.decode(UIMessageChunk.self, from: $0, file: file, line: line) }
    }

    /// Feeds chunks through a fresh reducer and returns the assembled state.
    private func reduce(_ fixtures: [String]) -> UIMessageStreamReducer {
        var reducer = UIMessageStreamReducer(messageId: "seed")
        for chunk in chunks(fixtures) {
            reducer.apply(chunk)
        }
        return reducer
    }

    // MARK: - Text turn: start → text-start / delta×N / text-end → finish

    func testTextStreamAssemblesSingleDoneTextPart() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "msg_assistant" }"#,
            #"{ "type": "text-start", "id": "t1" }"#,
            #"{ "type": "text-delta", "id": "t1", "delta": "Hel" }"#,
            #"{ "type": "text-delta", "id": "t1", "delta": "lo " }"#,
            #"{ "type": "text-delta", "id": "t1", "delta": "world" }"#,
            #"{ "type": "text-end", "id": "t1" }"#,
            #"{ "type": "finish", "finishReason": "stop" }"#,
        ])

        XCTAssertEqual(reducer.message.id, "msg_assistant")
        XCTAssertEqual(reducer.message.role, .assistant)
        XCTAssertTrue(reducer.isDone)
        XCTAssertEqual(reducer.finishReason, "stop")
        XCTAssertNil(reducer.errorText)

        XCTAssertEqual(reducer.message.parts.count, 1)
        guard case let .text(text, state, _) = reducer.message.parts[0] else {
            return XCTFail("Expected a text part, got \(reducer.message.parts)")
        }
        XCTAssertEqual(text, "Hello world")
        XCTAssertEqual(state, .done, "text-end should mark the part .done")
    }

    func testStartMessageIdOverridesSeed() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "from-server" }"#,
        ])
        XCTAssertEqual(reducer.message.id, "from-server")
    }

    func testTextPartIsStreamingBeforeEnd() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "m" }"#,
            #"{ "type": "text-start", "id": "t1" }"#,
            #"{ "type": "text-delta", "id": "t1", "delta": "partial" }"#,
        ])
        XCTAssertFalse(reducer.isDone)
        guard case let .text(text, state, _) = reducer.message.parts.first else {
            return XCTFail("Expected text part")
        }
        XCTAssertEqual(text, "partial")
        XCTAssertEqual(state, .streaming)
    }

    // MARK: - Tool round-trip: tool-input-available → tool-output-available

    func testToolRoundTripReachesOutputAvailable() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "m" }"#,
            """
            {
              "type": "tool-input-available",
              "toolCallId": "call_1",
              "toolName": "getWeather",
              "input": { "city": "SF" }
            }
            """,
            """
            {
              "type": "tool-output-available",
              "toolCallId": "call_1",
              "output": { "tempC": 18 }
            }
            """,
            #"{ "type": "finish" }"#,
        ])

        XCTAssertTrue(reducer.isDone)
        XCTAssertEqual(reducer.message.parts.count, 1, "input + output should fold into one tool part")

        guard case let .tool(name, invocation) = reducer.message.parts[0] else {
            return XCTFail("Expected a static tool part, got \(reducer.message.parts)")
        }
        XCTAssertEqual(name, "getWeather")
        XCTAssertEqual(invocation.toolCallId, "call_1")
        XCTAssertEqual(invocation.state, .outputAvailable)
        XCTAssertEqual(invocation.input?["city"]?.string, "SF")
        XCTAssertEqual(invocation.output?["tempC"]?.int, 18)
    }

    func testToolInputStreamingThenAvailable() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "m" }"#,
            """
            { "type": "tool-input-start", "toolCallId": "call_2", "toolName": "search" }
            """,
            """
            { "type": "tool-input-delta", "toolCallId": "call_2", "inputTextDelta": "{\\"q\\":" }
            """,
            """
            { "type": "tool-input-delta", "toolCallId": "call_2", "inputTextDelta": "\\"swift\\"}" }
            """,
            """
            {
              "type": "tool-input-available",
              "toolCallId": "call_2",
              "toolName": "search",
              "input": { "q": "swift" }
            }
            """,
        ])

        XCTAssertEqual(reducer.message.parts.count, 1)
        guard case let .tool(name, invocation) = reducer.message.parts[0] else {
            return XCTFail("Expected static tool part, got \(reducer.message.parts)")
        }
        XCTAssertEqual(name, "search")
        XCTAssertEqual(invocation.state, .inputAvailable)
        XCTAssertEqual(invocation.input?["q"]?.string, "swift")
    }

    func testToolApprovalFlowAdvancesState() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "m" }"#,
            """
            {
              "type": "tool-input-available",
              "toolCallId": "call_3",
              "toolName": "deleteFile",
              "input": { "path": "/tmp/x" }
            }
            """,
            """
            { "type": "tool-approval-request", "approvalId": "appr_1", "toolCallId": "call_3" }
            """,
        ])

        guard case let .tool(_, invocation) = reducer.message.parts.first else {
            return XCTFail("Expected tool part")
        }
        XCTAssertEqual(invocation.state, .approvalRequested)
        XCTAssertEqual(invocation.approval?.id, "appr_1")
    }

    func testToolOutputErrorState() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "m" }"#,
            """
            {
              "type": "tool-input-available",
              "toolCallId": "call_4",
              "toolName": "search",
              "input": { "q": "x" }
            }
            """,
            """
            { "type": "tool-output-error", "toolCallId": "call_4", "errorText": "upstream 500" }
            """,
        ])

        guard case let .tool(_, invocation) = reducer.message.parts.first else {
            return XCTFail("Expected tool part")
        }
        XCTAssertEqual(invocation.state, .outputError)
        XCTAssertEqual(invocation.errorText, "upstream 500")
    }

    // MARK: - Mixed: text then tool, ordering preserved

    func testMixedTextAndToolPreserveOrder() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "m" }"#,
            #"{ "type": "text-start", "id": "t1" }"#,
            #"{ "type": "text-delta", "id": "t1", "delta": "Let me check." }"#,
            #"{ "type": "text-end", "id": "t1" }"#,
            """
            {
              "type": "tool-input-available",
              "toolCallId": "call_5",
              "toolName": "getWeather",
              "input": { "city": "NYC" }
            }
            """,
            """
            { "type": "tool-output-available", "toolCallId": "call_5", "output": { "tempC": 9 } }
            """,
            #"{ "type": "finish", "finishReason": "tool-calls" }"#,
        ])

        XCTAssertEqual(reducer.message.parts.count, 2)
        guard case .text = reducer.message.parts[0] else {
            return XCTFail("Expected first part to be text")
        }
        guard case let .tool(_, invocation) = reducer.message.parts[1] else {
            return XCTFail("Expected second part to be tool")
        }
        XCTAssertEqual(invocation.state, .outputAvailable)
        XCTAssertEqual(reducer.finishReason, "tool-calls")
    }

    // MARK: - Error chunk surfaces errorText

    func testErrorChunkSurfacesText() {
        let reducer = reduce([
            #"{ "type": "start", "messageId": "m" }"#,
            #"{ "type": "error", "errorText": "stream broke" }"#,
        ])
        XCTAssertEqual(reducer.errorText, "stream broke")
    }
}
