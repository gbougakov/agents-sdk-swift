import Testing
import Foundation
@testable import Agents

/// Tests for the core wire messages in `AgentMessage.swift`, round-tripped
/// against literal JSON fixtures matching the reference protocol
/// (`packages/agents/src/types.ts`, `index.ts`, and `client.ts:305-406`).
@Suite("AgentMessage")
struct AgentMessageTests {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Decodes a literal JSON string into the inbound envelope.
    private func inbound(_ json: String) throws -> InboundAgentMessage {
        try decoder.decode(InboundAgentMessage.self, from: Data(json.utf8))
    }

    /// Re-parses an encoded JSON string into a `JSONValue` so assertions are
    /// independent of key ordering.
    private func parse(_ string: String) throws -> JSONValue {
        try decoder.decode(JSONValue.self, from: Data(string.utf8))
    }

    // MARK: - Message type literals

    @Test("message-type string literals match the wire protocol")
    func typeLiterals() {
        #expect(MessageType.identity == "cf_agent_identity")
        #expect(MessageType.state == "cf_agent_state")
        #expect(MessageType.stateError == "cf_agent_state_error")
        #expect(MessageType.rpc == "rpc")
    }

    // MARK: - cf_agent_identity (S -> C)

    @Test("decodes cf_agent_identity")
    func decodeIdentity() throws {
        let json = #"{"type":"cf_agent_identity","name":"room-1","agent":"chat-agent"}"#
        guard case let .identity(message) = try inbound(json) else {
            Issue.record("expected .identity")
            return
        }
        #expect(message.name == "room-1")
        #expect(message.agent == "chat-agent")
    }

    // MARK: - cf_agent_state (both directions)

    @Test("decodes inbound cf_agent_state with a typed payload")
    func decodeState() throws {
        let json = #"{"type":"cf_agent_state","state":{"count":3,"label":"hi"}}"#
        guard case let .state(message) = try inbound(json) else {
            Issue.record("expected .state")
            return
        }
        #expect(message.state["count"] == .number(3))
        #expect(message.state["label"] == .string("hi"))
    }

    @Test("encodes outbound cf_agent_state matching the wire shape")
    func encodeStateUpdate() throws {
        let state: JSONValue = .object(["count": .number(3), "label": .string("hi")])
        let json = try OutboundAgentMessage.setState(state)
        let parsed = try parse(json)
        #expect(parsed["type"] == .string("cf_agent_state"))
        #expect(parsed["state"]?["count"] == .number(3))
        #expect(parsed["state"]?["label"] == .string("hi"))
    }

    @Test("cf_agent_state round-trips: decode inbound then re-encode outbound")
    func stateRoundTrip() throws {
        let json = #"{"type":"cf_agent_state","state":{"nested":{"a":[1,2,3]}}}"#
        guard case let .state(message) = try inbound(json) else {
            Issue.record("expected .state")
            return
        }
        let reencoded = try OutboundAgentMessage.setState(message.state)
        let parsed = try parse(reencoded)
        #expect(parsed["type"] == .string("cf_agent_state"))
        #expect(parsed["state"]?["nested"]?["a"] == .array([.number(1), .number(2), .number(3)]))
    }

    // MARK: - cf_agent_state_error (S -> C)

    @Test("decodes cf_agent_state_error")
    func decodeStateError() throws {
        let json = #"{"type":"cf_agent_state_error","error":"invalid state shape"}"#
        guard case let .stateError(message) = try inbound(json) else {
            Issue.record("expected .stateError")
            return
        }
        #expect(message.error == "invalid state shape")
    }

    // MARK: - rpc request (C -> S)

    @Test("encodes an rpc request matching the wire shape")
    func encodeRPCRequest() throws {
        let args: [JSONValue] = [.string("hello"), .number(42), .bool(true)]
        let json = try OutboundAgentMessage.rpcRequest(id: "req-1", method: "greet", args: args)
        let parsed = try parse(json)
        #expect(parsed["type"] == .string("rpc"))
        #expect(parsed["id"] == .string("req-1"))
        #expect(parsed["method"] == .string("greet"))
        #expect(parsed["args"] == .array([.string("hello"), .number(42), .bool(true)]))
    }

    @Test("encodes an rpc request with no arguments as an empty array")
    func encodeRPCRequestNoArgs() throws {
        let json = try OutboundAgentMessage.rpcRequest(id: "req-2", method: "ping")
        let parsed = try parse(json)
        #expect(parsed["type"] == .string("rpc"))
        #expect(parsed["id"] == .string("req-2"))
        #expect(parsed["method"] == .string("ping"))
        #expect(parsed["args"] == .array([]))
    }

    // MARK: - rpc response (S -> C)

    @Test("decodes a non-streaming successful rpc response (no done flag)")
    func decodeRPCSuccess() throws {
        let json = #"{"type":"rpc","id":"req-1","success":true,"result":{"value":7}}"#
        guard case let .rpc(response) = try inbound(json) else {
            Issue.record("expected .rpc")
            return
        }
        #expect(response.id == "req-1")
        #expect(response.success == true)
        #expect(response.done == nil)  // non-streaming: done absent
        #expect(response.result?["value"] == .number(7))
        #expect(response.error == nil)
    }

    @Test("decodes a streaming rpc chunk (done: false)")
    func decodeRPCStreamChunk() throws {
        let json = #"{"type":"rpc","id":"req-1","success":true,"result":"chunk-1","done":false}"#
        guard case let .rpc(response) = try inbound(json) else {
            Issue.record("expected .rpc")
            return
        }
        #expect(response.id == "req-1")
        #expect(response.success == true)
        #expect(response.done == false)  // intermediate chunk
        #expect(response.result == .string("chunk-1"))
    }

    @Test("decodes a streaming rpc final frame (done: true)")
    func decodeRPCStreamDone() throws {
        let json = #"{"type":"rpc","id":"req-1","success":true,"result":"final","done":true}"#
        guard case let .rpc(response) = try inbound(json) else {
            Issue.record("expected .rpc")
            return
        }
        #expect(response.id == "req-1")
        #expect(response.success == true)
        #expect(response.done == true)  // terminal frame
        #expect(response.result == .string("final"))
    }

    @Test("decodes a failed rpc response with an error")
    func decodeRPCError() throws {
        let json = #"{"type":"rpc","id":"req-1","success":false,"error":"method not found"}"#
        guard case let .rpc(response) = try inbound(json) else {
            Issue.record("expected .rpc")
            return
        }
        #expect(response.id == "req-1")
        #expect(response.success == false)
        #expect(response.error == "method not found")
        #expect(response.result == nil)
    }

    // MARK: - Unknown / v1-ignored types

    @Test("v1-ignored message types decode to .unknown rather than throwing", arguments: [
        "cf_agent_mcp_servers",
        "cf_mcp_agent_event",
        "cf_agent_session",
        "cf_agent_session_error",
        "some_future_type",
    ])
    func decodeUnknown(type: String) throws {
        let json = #"{"type":"\#(type)","extra":"ignored"}"#
        guard case let .unknown(decodedType) = try inbound(json) else {
            Issue.record("expected .unknown for \(type)")
            return
        }
        #expect(decodedType == type)
    }

    // MARK: - RPCRequest as a value type

    @Test("RPCRequest sets the constant rpc discriminator")
    func rpcRequestDiscriminator() {
        let request = RPCRequest(id: "x", method: "m", args: [])
        #expect(request.type == "rpc")
    }

    @Test("StateUpdateMessage sets the constant cf_agent_state discriminator")
    func stateUpdateDiscriminator() {
        let message = StateUpdateMessage(state: .null)
        #expect(message.type == "cf_agent_state")
    }
}
