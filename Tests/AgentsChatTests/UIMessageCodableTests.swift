import XCTest
import Agents
@testable import AgentsChat

/// Round-trip tests for ``UIMessage`` and ``UIMessagePart`` against literal JSON fixtures.
///
/// These lock down the wire shape: literal `type` discriminators (`"text"`, `"tool-<name>"`,
/// `"dynamic-tool"`, `"data-<name>"`) and the `data-`/`tool-` prefix splitting, plus every
/// ``ToolInvocation/State``.
final class UIMessageCodableTests: XCTestCase {

    // MARK: - Whole message

    func testFullMessageRoundTrips() {
        let fixture = """
        {
          "id": "msg_1",
          "role": "assistant",
          "metadata": { "createdAt": 1700000000, "model": "gpt-4o" },
          "parts": [
            { "type": "step-start" },
            { "type": "text", "text": "Hello, world", "state": "done" }
          ]
        }
        """
        assertRoundTrips(UIMessage.self, fixture: fixture)
    }

    func testMinimalMessageRoundTrips() {
        let fixture = """
        { "id": "u1", "role": "user", "parts": [ { "type": "text", "text": "hi" } ] }
        """
        assertRoundTrips(UIMessage.self, fixture: fixture)
    }

    // MARK: - Text part

    func testTextPartStreamingState() {
        let fixture = """
        { "type": "text", "text": "partial", "state": "streaming" }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)

        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture) else { return }
        guard case let .text(text, state, _) = part else {
            return XCTFail("Expected .text, got \(part)")
        }
        XCTAssertEqual(text, "partial")
        XCTAssertEqual(state, .streaming)
    }

    func testTextPartWithoutState() {
        let fixture = """
        { "type": "text", "text": "no state" }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
    }

    // MARK: - Static tool part (tool-<name>)

    func testStaticToolPartPrefixSplit() {
        let fixture = """
        {
          "type": "tool-getWeather",
          "toolCallId": "call_abc",
          "state": "output-available",
          "input": { "city": "SF" },
          "output": { "tempC": 18 }
        }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)

        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture) else { return }
        guard case let .tool(name, invocation) = part else {
            return XCTFail("Expected .tool, got \(part)")
        }
        XCTAssertEqual(name, "getWeather")
        XCTAssertEqual(invocation.toolCallId, "call_abc")
        XCTAssertEqual(invocation.state, .outputAvailable)
        XCTAssertEqual(invocation.input?["city"]?.string, "SF")
        XCTAssertEqual(invocation.output?["tempC"]?.int, 18)
    }

    // MARK: - dynamic-tool part

    func testDynamicToolPart() {
        let fixture = """
        {
          "type": "dynamic-tool",
          "toolName": "mcp_search",
          "toolCallId": "call_dyn",
          "state": "input-available",
          "input": { "query": "swift" }
        }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)

        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture) else { return }
        guard case let .dynamicTool(toolName, invocation) = part else {
            return XCTFail("Expected .dynamicTool, got \(part)")
        }
        XCTAssertEqual(toolName, "mcp_search")
        XCTAssertEqual(invocation.toolCallId, "call_dyn")
        XCTAssertEqual(invocation.state, .inputAvailable)
    }

    // MARK: - data-<name> part

    func testDataPartPrefixSplit() {
        let fixture = """
        { "type": "data-weather", "id": "d1", "data": { "temp": 72, "unit": "F" } }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)

        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture) else { return }
        guard case let .data(name, id, value) = part else {
            return XCTFail("Expected .data, got \(part)")
        }
        XCTAssertEqual(name, "weather")
        XCTAssertEqual(id, "d1")
        XCTAssertEqual(value["temp"]?.int, 72)
    }

    func testDataPartWithoutID() {
        let fixture = """
        { "type": "data-notification", "data": { "kind": "toast" } }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
    }

    // MARK: - ToolInvocation state coverage

    func testToolInvocationInputStreaming() {
        let fixture = """
        { "type": "tool-search", "toolCallId": "c1", "state": "input-streaming", "input": { "q": "sw" } }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
        assertToolState(fixture, expected: .inputStreaming)
    }

    func testToolInvocationInputAvailable() {
        let fixture = """
        { "type": "tool-search", "toolCallId": "c2", "state": "input-available", "input": { "q": "swift" } }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
        assertToolState(fixture, expected: .inputAvailable)
    }

    func testToolInvocationApprovalRequested() {
        let fixture = """
        {
          "type": "tool-deleteFile",
          "toolCallId": "c3",
          "state": "approval-requested",
          "input": { "path": "/tmp/x" },
          "approval": { "id": "appr_1" }
        }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
        assertToolState(fixture, expected: .approvalRequested)

        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture),
              case let .tool(_, invocation) = part else { return }
        XCTAssertEqual(invocation.approval?.id, "appr_1")
        XCTAssertNil(invocation.approval?.approved)
    }

    func testToolInvocationApprovalResponded() {
        let fixture = """
        {
          "type": "tool-deleteFile",
          "toolCallId": "c4",
          "state": "approval-responded",
          "input": { "path": "/tmp/x" },
          "approval": { "id": "appr_2", "approved": true, "reason": "ok" }
        }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
        assertToolState(fixture, expected: .approvalResponded)

        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture),
              case let .tool(_, invocation) = part else { return }
        XCTAssertEqual(invocation.approval?.approved, true)
        XCTAssertEqual(invocation.approval?.reason, "ok")
    }

    func testToolInvocationOutputAvailable() {
        let fixture = """
        {
          "type": "tool-search",
          "toolCallId": "c5",
          "state": "output-available",
          "input": { "q": "swift" },
          "output": [ { "title": "Result" } ],
          "preliminary": false
        }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
        assertToolState(fixture, expected: .outputAvailable)
    }

    func testToolInvocationOutputError() {
        let fixture = """
        {
          "type": "tool-search",
          "toolCallId": "c6",
          "state": "output-error",
          "rawInput": { "q": 5 },
          "errorText": "boom"
        }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
        assertToolState(fixture, expected: .outputError)

        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture),
              case let .tool(_, invocation) = part else { return }
        XCTAssertEqual(invocation.errorText, "boom")
        XCTAssertEqual(invocation.rawInput?["q"]?.int, 5)
    }

    func testToolInvocationOutputDenied() {
        let fixture = """
        {
          "type": "tool-deleteFile",
          "toolCallId": "c7",
          "state": "output-denied",
          "approval": { "id": "appr_3", "approved": false }
        }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)
        assertToolState(fixture, expected: .outputDenied)
    }

    // MARK: - Forward-compatible unknown part

    func testUnknownPartRoundTrips() {
        let fixture = """
        { "type": "some-future-part", "foo": "bar", "n": 3 }
        """
        assertRoundTrips(UIMessagePart.self, fixture: fixture)

        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture) else { return }
        guard case let .unknown(type, _) = part else {
            return XCTFail("Expected .unknown, got \(part)")
        }
        XCTAssertEqual(type, "some-future-part")
    }

    // MARK: - Helpers

    private func assertToolState(
        _ fixture: String,
        expected: ToolInvocation.State,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let part = JSONTestSupport.decode(UIMessagePart.self, from: fixture, file: file, line: line) else {
            return
        }
        let state: ToolInvocation.State?
        switch part {
        case let .tool(_, invocation): state = invocation.state
        case let .dynamicTool(_, invocation): state = invocation.state
        default: state = nil
        }
        XCTAssertEqual(state, expected, file: file, line: line)
    }
}
