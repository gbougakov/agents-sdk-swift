import XCTest
import Agents
@testable import AgentsChat

/// Round-trip tests for representative ``UIMessageChunk`` cases against literal JSON fixtures.
///
/// `UIMessageChunk` is `Codable` but not `Equatable`, so round-tripping is verified by decoding the
/// fixture and re-encoding it, then comparing the resulting `JSONValue` trees (order-independent).
final class UIMessageChunkTests: XCTestCase {

    /// Decode→encode a chunk fixture and assert structural equality with the fixture.
    private func assertChunkRoundTrips(
        _ fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture, file: file, line: line) else {
            return
        }
        let reEncoded = JSONTestSupport.tree(chunk, file: file, line: line)
        let expected = JSONTestSupport.parse(fixture, file: file, line: line)
        XCTAssertEqual(reEncoded, expected, "Chunk did not round-trip", file: file, line: line)
    }

    func testStartChunk() {
        assertChunkRoundTrips("""
        { "type": "start", "messageId": "msg_1" }
        """)
    }

    func testTextDeltaChunk() {
        let fixture = """
        { "type": "text-delta", "id": "t1", "delta": "Hello" }
        """
        assertChunkRoundTrips(fixture)

        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture) else { return }
        guard case let .textDelta(id, delta, _) = chunk else {
            return XCTFail("Expected .textDelta, got \(chunk)")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(delta, "Hello")
    }

    func testTextStartAndEndChunks() {
        assertChunkRoundTrips("""
        { "type": "text-start", "id": "t1" }
        """)
        assertChunkRoundTrips("""
        { "type": "text-end", "id": "t1" }
        """)
    }

    func testToolInputAvailableChunk() {
        let fixture = """
        {
          "type": "tool-input-available",
          "toolCallId": "call_1",
          "toolName": "getWeather",
          "input": { "city": "SF" }
        }
        """
        assertChunkRoundTrips(fixture)

        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture) else { return }
        guard case let .toolInputAvailable(toolCallId, toolName, input, _, _, _, _, _) = chunk else {
            return XCTFail("Expected .toolInputAvailable, got \(chunk)")
        }
        XCTAssertEqual(toolCallId, "call_1")
        XCTAssertEqual(toolName, "getWeather")
        XCTAssertEqual(input["city"]?.string, "SF")
    }

    func testToolOutputAvailableChunk() {
        let fixture = """
        {
          "type": "tool-output-available",
          "toolCallId": "call_1",
          "output": { "tempC": 18 }
        }
        """
        assertChunkRoundTrips(fixture)

        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture) else { return }
        guard case let .toolOutputAvailable(toolCallId, output, _, _, _, _, _) = chunk else {
            return XCTFail("Expected .toolOutputAvailable, got \(chunk)")
        }
        XCTAssertEqual(toolCallId, "call_1")
        XCTAssertEqual(output["tempC"]?.int, 18)
    }

    func testToolInputDeltaChunk() {
        let fixture = """
        { "type": "tool-input-delta", "toolCallId": "call_1", "inputTextDelta": "{\\"ci" }
        """
        assertChunkRoundTrips(fixture)

        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture) else { return }
        guard case let .toolInputDelta(toolCallId, inputTextDelta) = chunk else {
            return XCTFail("Expected .toolInputDelta, got \(chunk)")
        }
        XCTAssertEqual(toolCallId, "call_1")
        XCTAssertEqual(inputTextDelta, "{\"ci")
    }

    func testToolApprovalRequestChunk() {
        assertChunkRoundTrips("""
        { "type": "tool-approval-request", "approvalId": "appr_1", "toolCallId": "call_1" }
        """)
    }

    func testFinishChunk() {
        let fixture = """
        { "type": "finish", "finishReason": "stop" }
        """
        assertChunkRoundTrips(fixture)

        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture) else { return }
        guard case let .finish(reason, _) = chunk else {
            return XCTFail("Expected .finish, got \(chunk)")
        }
        XCTAssertEqual(reason, "stop")
    }

    func testFinishChunkBare() {
        assertChunkRoundTrips("""
        { "type": "finish" }
        """)
    }

    func testErrorChunk() {
        let fixture = """
        { "type": "error", "errorText": "something failed" }
        """
        assertChunkRoundTrips(fixture)

        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture) else { return }
        guard case let .error(errorText) = chunk else {
            return XCTFail("Expected .error, got \(chunk)")
        }
        XCTAssertEqual(errorText, "something failed")
    }

    func testDataChunkPrefixSplit() {
        let fixture = """
        { "type": "data-progress", "id": "p1", "data": { "pct": 50 }, "transient": true }
        """
        assertChunkRoundTrips(fixture)

        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture) else { return }
        guard case let .data(name, id, data, transient) = chunk else {
            return XCTFail("Expected .data, got \(chunk)")
        }
        XCTAssertEqual(name, "progress")
        XCTAssertEqual(id, "p1")
        XCTAssertEqual(data["pct"]?.int, 50)
        XCTAssertEqual(transient, true)
    }

    func testUnknownChunkRoundTrips() {
        let fixture = """
        { "type": "future-chunk", "payload": { "x": 1 } }
        """
        assertChunkRoundTrips(fixture)

        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: fixture) else { return }
        guard case let .unknown(type, _) = chunk else {
            return XCTFail("Expected .unknown, got \(chunk)")
        }
        XCTAssertEqual(type, "future-chunk")
    }
}
