import Testing
import Foundation
@testable import Agents

/// Tests for ``JSONValue`` — the type-erased JSON representation used as the
/// dynamic escape hatch for RPC args/results and untyped chat payloads.
@Suite("JSONValue")
struct JSONValueTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Encodes then re-decodes a `JSONValue`, asserting it survives the round trip.
    private func roundTrip(_ value: JSONValue) throws {
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    // MARK: - Scalar round-trips

    @Test("scalar values round-trip")
    func scalars() throws {
        try roundTrip(.null)
        try roundTrip(.bool(true))
        try roundTrip(.bool(false))
        try roundTrip(.number(42))
        try roundTrip(.number(-3.14159))
        try roundTrip(.number(0))
        try roundTrip(.string(""))
        try roundTrip(.string("hello world"))
        try roundTrip(.string("unicode: café 日本語 emoji"))
    }

    @Test("booleans decode as .bool, not as numbers")
    func boolNotNumber() throws {
        let trueValue = try decoder.decode(JSONValue.self, from: Data("true".utf8))
        let falseValue = try decoder.decode(JSONValue.self, from: Data("false".utf8))
        #expect(trueValue == .bool(true))
        #expect(falseValue == .bool(false))
        // Ensure 1 / 0 are numbers and not coerced into bools.
        let one = try decoder.decode(JSONValue.self, from: Data("1".utf8))
        #expect(one == .number(1))
    }

    // MARK: - Nested fixtures

    @Test("nested object/array fixture round-trips")
    func nestedFixture() throws {
        let value: JSONValue = .object([
            "id": .string("abc-123"),
            "count": .number(7),
            "active": .bool(true),
            "ratio": .number(0.5),
            "tags": .array([.string("a"), .string("b"), .string("c")]),
            "nested": .object([
                "deep": .array([
                    .object(["x": .number(1), "y": .null]),
                    .object(["x": .number(2), "y": .bool(false)]),
                ]),
            ]),
            "missing": .null,
        ])
        try roundTrip(value)
    }

    @Test("decodes a literal JSON fixture into the expected structure")
    func decodeLiteralFixture() throws {
        let json = """
        {
          "name": "counter",
          "value": 10,
          "history": [1, 2, 3],
          "meta": { "enabled": true, "label": null }
        }
        """
        let value = try decoder.decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["name"] == .string("counter"))
        #expect(value["value"] == .number(10))
        #expect(value["value"]?.int == 10)
        #expect(value["history"] == .array([.number(1), .number(2), .number(3)]))
        #expect(value["history"]?[1] == .number(2))
        #expect(value["meta"]?["enabled"] == .bool(true))
        #expect(value["meta"]?["label"]?.isNull == true)
    }

    // MARK: - Convenience accessors

    @Test("convenience accessors return the wrapped value or nil")
    func accessors() {
        #expect(JSONValue.bool(true).bool == true)
        #expect(JSONValue.string("hi").bool == nil)
        #expect(JSONValue.number(3.5).double == 3.5)
        #expect(JSONValue.number(8).int == 8)
        #expect(JSONValue.number(8.5).int == nil)  // non-integral
        #expect(JSONValue.string("hi").string == "hi")
        #expect(JSONValue.array([.number(1)]).array == [.number(1)])
        #expect(JSONValue.object(["k": .null]).object == ["k": .null])
        #expect(JSONValue.null.isNull)
    }

    @Test("literal conformances build the expected cases")
    func literals() {
        let value: JSONValue = [
            "n": 1,
            "f": 2.5,
            "b": true,
            "s": "text",
            "nul": nil,
            "arr": [1, 2, 3],
        ]
        #expect(value["n"] == .number(1))
        #expect(value["f"] == .number(2.5))
        #expect(value["b"] == .bool(true))
        #expect(value["s"] == .string("text"))
        #expect(value["nul"] == .null)
        #expect(value["arr"] == .array([.number(1), .number(2), .number(3)]))
    }

    // MARK: - Decodable / Encodable bridging

    /// A strongly-typed value used to verify `encode(encodable:)` / `decode(as:)`.
    private struct Counter: Codable, Equatable {
        var name: String
        var value: Int
        var tags: [String]
    }

    @Test("init(encodable:) converts a typed Encodable into a JSONValue")
    func encodeFromEncodable() throws {
        let counter = Counter(name: "score", value: 99, tags: ["a", "b"])
        let value = try JSONValue(encodable: counter)
        #expect(value["name"] == .string("score"))
        #expect(value["value"] == .number(99))
        #expect(value["tags"] == .array([.string("a"), .string("b")]))
    }

    @Test("init(encodable:) short-circuits when the input is already a JSONValue")
    func encodeFromJSONValuePassthrough() throws {
        let original: JSONValue = .object(["x": .number(1)])
        let wrapped = try JSONValue(encodable: original)
        #expect(wrapped == original)
    }

    @Test("decode(as:) converts a JSONValue into a typed Decodable")
    func decodeIntoDecodable() throws {
        let value: JSONValue = .object([
            "name": .string("score"),
            "value": .number(99),
            "tags": .array([.string("a"), .string("b")]),
        ])
        let counter: Counter = try value.decode()
        #expect(counter == Counter(name: "score", value: 99, tags: ["a", "b"]))
    }

    @Test("decode(as:) short-circuits when the target type is JSONValue")
    func decodeIntoJSONValuePassthrough() throws {
        let value: JSONValue = .array([.number(1), .string("two")])
        let decoded: JSONValue = try value.decode()
        #expect(decoded == value)
    }

    @Test("Encodable -> JSONValue -> Decodable preserves the value end-to-end")
    func fullBridgeRoundTrip() throws {
        let original = Counter(name: "x", value: -1, tags: [])
        let value = try JSONValue(encodable: original)
        let back: Counter = try value.decode()
        #expect(back == original)
    }
}
