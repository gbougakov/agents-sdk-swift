import Foundation

/// A type-erased JSON value.
///
/// `JSONValue` losslessly represents any JSON document and is used throughout the SDK as the
/// "escape hatch" for dynamic payloads: RPC arguments and results, untyped chat data parts, and
/// tool input/output where the concrete Swift type is not known at compile time.
///
/// It conforms to `Codable` (round-tripping arbitrary JSON), `Sendable` (safe to pass across
/// concurrency domains), and `Hashable` (usable in sets/dictionaries and for equality in tests).
public enum JSONValue: Codable, Sendable, Hashable {
    /// JSON `null`.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON number. Stored as `Double`; see ``int`` for integral access.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object, preserving key/value pairs (ordering is not guaranteed).
    case object([String: JSONValue])

    // MARK: - Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Decode booleans before numbers: JSONDecoder will happily turn `true`/`false` into 1/0
        // for some number types, so the order matters for correct round-tripping.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Value is not a valid JSON fragment"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: - Conversions

    /// Builds a `JSONValue` from any `Encodable` value by encoding to JSON and re-decoding.
    ///
    /// Use this to convert strongly-typed Swift values into the dynamic representation the wire
    /// protocol expects for RPC arguments and tool payloads.
    public init<T: Encodable>(encodable value: T) throws {
        if let value = value as? JSONValue {
            self = value
            return
        }
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into a concrete `Decodable` type.
    ///
    /// Use this to convert dynamic RPC results / chat payloads back into strongly-typed Swift
    /// values once the expected shape is known.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        if T.self == JSONValue.self, let value = self as? T {
            return value
        }
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    /// The wrapped boolean, or `nil` if this is not a `.bool`.
    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The wrapped number as a `Double`, or `nil` if this is not a `.number`.
    public var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The wrapped number as an `Int`, or `nil` if this is not an integral `.number`.
    public var int: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    /// The wrapped string, or `nil` if this is not a `.string`.
    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The wrapped array, or `nil` if this is not an `.array`.
    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The wrapped object, or `nil` if this is not an `.object`.
    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Whether this value is JSON `null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Accesses the value for `key` if this is an `.object`, otherwise `nil`.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    /// Accesses the element at `index` if this is an `.array` and the index is in bounds.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }
}

// MARK: - Literal conformances

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
