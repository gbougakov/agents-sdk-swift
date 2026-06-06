import XCTest
import Agents
@testable import AgentsChat

/// Round-trip / wire-shape tests for the `cf_agent_*` chat protocol frames.
///
/// Outbound frames are `Encodable`; their encoded JSON is asserted against literal fixtures
/// (verifying the exact `type` discriminator and field names). Inbound payload structs are
/// `Codable & Hashable`, so they round-trip decode→encode against fixtures, and the
/// ``InboundChatMessage`` envelope is exercised for type dispatch.
final class ChatWireMessageTests: XCTestCase {

    // MARK: - cf_agent_use_chat_request (client → server)

    func testUseChatRequestEncodes() throws {
        let bodyJSON = #"{"messages":[],"trigger":"submit-message"}"#
        let frame = UseChatRequestFrame(id: "req_1", init: ChatRequestInit(method: "POST", body: bodyJSON))
        let fixture = """
        {
          "type": "cf_agent_use_chat_request",
          "id": "req_1",
          "init": {
            "method": "POST",
            "body": "{\\"messages\\":[],\\"trigger\\":\\"submit-message\\"}"
          }
        }
        """
        assertEncodes(frame, to: fixture)
    }

    func testUseChatRequestHelperMatchesFrame() throws {
        let body = #"{"messages":[]}"#
        let encoded = try OutboundChatMessage.useChatRequest(id: "req_2", body: body)
        let tree = JSONTestSupport.parse(encoded)
        XCTAssertEqual(tree["type"]?.string, ChatMessageType.useChatRequest)
        XCTAssertEqual(tree["id"]?.string, "req_2")
        XCTAssertEqual(tree["init"]?["method"]?.string, "POST")
        XCTAssertEqual(tree["init"]?["body"]?.string, body)
    }

    // MARK: - cf_agent_use_chat_response (server → client)

    func testUseChatResponseRoundTrips() {
        let fixture = """
        {
          "id": "req_1",
          "body": "{\\"type\\":\\"text-delta\\",\\"id\\":\\"t1\\",\\"delta\\":\\"Hi\\"}",
          "done": false
        }
        """
        assertRoundTrips(UseChatResponseMessage.self, fixture: fixture)

        guard let msg = JSONTestSupport.decode(UseChatResponseMessage.self, from: fixture) else { return }
        XCTAssertEqual(msg.id, "req_1")
        XCTAssertFalse(msg.done)
        // The body is itself a JSON-encoded UIMessageChunk.
        guard let chunk = JSONTestSupport.decode(UIMessageChunk.self, from: msg.body) else { return }
        guard case let .textDelta(id, delta, _) = chunk else {
            return XCTFail("Expected nested .textDelta, got \(chunk)")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(delta, "Hi")
    }

    func testUseChatResponseWithResumeFlags() {
        let fixture = """
        {
          "id": "req_9",
          "body": "{\\"type\\":\\"finish\\"}",
          "done": true,
          "replay": true,
          "replayComplete": true,
          "continuation": false
        }
        """
        assertRoundTrips(UseChatResponseMessage.self, fixture: fixture)

        guard let msg = JSONTestSupport.decode(UseChatResponseMessage.self, from: fixture) else { return }
        XCTAssertTrue(msg.done)
        XCTAssertEqual(msg.replay, true)
        XCTAssertEqual(msg.replayComplete, true)
        XCTAssertEqual(msg.continuation, false)
    }

    func testUseChatResponseEnvelopeDispatch() {
        let fixture = """
        {
          "type": "cf_agent_use_chat_response",
          "id": "req_1",
          "body": "{}",
          "done": true
        }
        """
        guard let inbound = JSONTestSupport.decode(InboundChatMessage.self, from: fixture) else { return }
        guard case let .useChatResponse(payload) = inbound else {
            return XCTFail("Expected .useChatResponse, got \(inbound)")
        }
        XCTAssertEqual(payload.id, "req_1")
        XCTAssertTrue(payload.done)
    }

    // MARK: - cf_agent_tool_result (client → server)

    func testToolResultEncodes() {
        let frame = ToolResultFrame(
            toolCallId: "call_1",
            toolName: "getWeather",
            output: .object(["tempC": .number(18)]),
            state: .outputAvailable,
            autoContinue: true
        )
        let fixture = """
        {
          "type": "cf_agent_tool_result",
          "toolCallId": "call_1",
          "toolName": "getWeather",
          "output": { "tempC": 18 },
          "state": "output-available",
          "autoContinue": true
        }
        """
        assertEncodes(frame, to: fixture)
    }

    func testToolResultErrorState() {
        let frame = ToolResultFrame(
            toolCallId: "call_2",
            toolName: "search",
            output: .null,
            state: .outputError,
            errorText: "boom",
            autoContinue: false
        )
        let fixture = """
        {
          "type": "cf_agent_tool_result",
          "toolCallId": "call_2",
          "toolName": "search",
          "output": null,
          "state": "output-error",
          "errorText": "boom",
          "autoContinue": false
        }
        """
        assertEncodes(frame, to: fixture)
    }

    // MARK: - cf_agent_tool_approval (client → server)

    func testToolApprovalEncodes() {
        let frame = ToolApprovalFrame(toolCallId: "call_3", approved: true, autoContinue: true)
        let fixture = """
        {
          "type": "cf_agent_tool_approval",
          "toolCallId": "call_3",
          "approved": true,
          "autoContinue": true
        }
        """
        assertEncodes(frame, to: fixture)
    }

    func testToolApprovalDeniedEncodes() {
        let frame = ToolApprovalFrame(toolCallId: "call_4", approved: false)
        let tree = JSONTestSupport.tree(frame)
        XCTAssertEqual(tree["type"]?.string, ChatMessageType.toolApproval)
        XCTAssertEqual(tree["toolCallId"]?.string, "call_4")
        XCTAssertEqual(tree["approved"]?.bool, false)
        XCTAssertNil(tree["autoContinue"], "nil autoContinue should be omitted")
    }

    // MARK: - Stream resume frames

    func testStreamResumeRequestEncodes() throws {
        let encoded = try OutboundChatMessage.streamResumeRequest()
        assertEncodes(StreamResumeRequestFrame(), to: encoded)
        XCTAssertEqual(JSONTestSupport.parse(encoded)["type"]?.string, ChatMessageType.streamResumeRequest)
    }

    func testStreamResumeAckEncodes() {
        let frame = StreamResumeAckFrame(id: "stream_1")
        let fixture = """
        { "type": "cf_agent_stream_resume_ack", "id": "stream_1" }
        """
        assertEncodes(frame, to: fixture)
    }

    func testStreamResumingInboundDispatch() {
        let fixture = """
        { "type": "cf_agent_stream_resuming", "id": "stream_1" }
        """
        guard let inbound = JSONTestSupport.decode(InboundChatMessage.self, from: fixture) else { return }
        guard case let .streamResuming(payload) = inbound else {
            return XCTFail("Expected .streamResuming, got \(inbound)")
        }
        XCTAssertEqual(payload.id, "stream_1")
    }

    func testStreamResumeNoneInboundDispatch() {
        let fixture = """
        { "type": "cf_agent_stream_resume_none" }
        """
        guard let inbound = JSONTestSupport.decode(InboundChatMessage.self, from: fixture) else { return }
        guard case .streamResumeNone = inbound else {
            return XCTFail("Expected .streamResumeNone, got \(inbound)")
        }
    }

    // MARK: - cf_agent_chat_messages / clear

    func testChatMessagesFrameEncodes() {
        let message = UIMessage(id: "m1", role: .user, parts: [.text(text: "hi", state: nil, providerMetadata: nil)])
        let frame = ChatMessagesFrame(messages: [message])
        let fixture = """
        {
          "type": "cf_agent_chat_messages",
          "messages": [
            { "id": "m1", "role": "user", "parts": [ { "type": "text", "text": "hi" } ] }
          ]
        }
        """
        assertEncodes(frame, to: fixture)
    }

    func testChatMessagesInboundDispatch() {
        let fixture = """
        {
          "type": "cf_agent_chat_messages",
          "messages": [ { "id": "m1", "role": "assistant", "parts": [] } ]
        }
        """
        guard let inbound = JSONTestSupport.decode(InboundChatMessage.self, from: fixture) else { return }
        guard case let .chatMessages(payload) = inbound else {
            return XCTFail("Expected .chatMessages, got \(inbound)")
        }
        XCTAssertEqual(payload.messages.count, 1)
        XCTAssertEqual(payload.messages.first?.id, "m1")
    }

    func testChatClearFrameEncodes() {
        assertEncodes(ChatClearFrame(), to: #"{ "type": "cf_agent_chat_clear" }"#)
    }

    func testChatRequestCancelEncodes() {
        assertEncodes(ChatRequestCancelFrame(id: "req_1"), to: #"{ "type": "cf_agent_chat_request_cancel", "id": "req_1" }"#)
    }

    // MARK: - Unknown inbound frames are tolerated

    func testUnknownInboundDispatch() {
        let fixture = """
        { "type": "cf_agent_some_future_message", "foo": 1 }
        """
        guard let inbound = JSONTestSupport.decode(InboundChatMessage.self, from: fixture) else { return }
        guard case let .unknown(type) = inbound else {
            return XCTFail("Expected .unknown, got \(inbound)")
        }
        XCTAssertEqual(type, "cf_agent_some_future_message")
    }

    // MARK: - message_updated

    func testMessageUpdatedInboundDispatch() {
        let fixture = """
        {
          "type": "cf_agent_message_updated",
          "message": { "id": "m9", "role": "assistant", "parts": [ { "type": "text", "text": "ok", "state": "done" } ] }
        }
        """
        guard let inbound = JSONTestSupport.decode(InboundChatMessage.self, from: fixture) else { return }
        guard case let .messageUpdated(payload) = inbound else {
            return XCTFail("Expected .messageUpdated, got \(inbound)")
        }
        XCTAssertEqual(payload.message.id, "m9")
    }
}
