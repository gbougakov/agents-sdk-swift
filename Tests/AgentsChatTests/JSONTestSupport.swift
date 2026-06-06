import Foundation
import XCTest
import Agents

/// Shared helpers for the AgentsChat Codable round-trip tests.
///
/// JSON object key ordering is not guaranteed by `JSONEncoder`, so equality checks compare the
/// *parsed* `JSONValue` tree rather than raw strings. `JSONValue` is `Hashable`, so structural
/// equality falls out for free and is order-independent for object keys.
enum JSONTestSupport {
    /// Parses a JSON string into a ``JSONValue`` for order-independent structural comparison.
    static func parse(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            XCTFail("Fixture is not valid UTF-8", file: file, line: line)
            return .null
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            XCTFail("Fixture is not valid JSON: \(error)", file: file, line: line)
            return .null
        }
    }

    /// Encodes an `Encodable` value to its ``JSONValue`` tree.
    static func tree<T: Encodable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) -> JSONValue {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            XCTFail("Failed to encode value: \(error)", file: file, line: line)
            return .null
        }
    }

    /// Decodes a value of type `T` from a JSON fixture string.
    static func decode<T: Decodable>(
        _ type: T.Type,
        from string: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T? {
        guard let data = string.data(using: .utf8) else {
            XCTFail("Fixture is not valid UTF-8", file: file, line: line)
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            XCTFail("Failed to decode \(T.self): \(error)", file: file, line: line)
            return nil
        }
    }
}

extension XCTestCase {
    /// Asserts that decoding `fixture` into `T` and re-encoding produces JSON structurally equal to
    /// the fixture (an order-independent decode→encode round-trip against a literal JSON fixture).
    func assertRoundTrips<T: Codable & Equatable>(
        _ type: T.Type,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let decoded = JSONTestSupport.decode(T.self, from: fixture, file: file, line: line) else {
            return
        }
        let reEncoded = JSONTestSupport.tree(decoded, file: file, line: line)
        let expected = JSONTestSupport.parse(fixture, file: file, line: line)
        XCTAssertEqual(
            reEncoded,
            expected,
            "Re-encoded JSON does not structurally match the fixture",
            file: file,
            line: line
        )
    }

    /// Asserts that `value` encodes to JSON structurally equal to `fixture`.
    func assertEncodes<T: Encodable>(
        _ value: T,
        to fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = JSONTestSupport.tree(value, file: file, line: line)
        let expected = JSONTestSupport.parse(fixture, file: file, line: line)
        XCTAssertEqual(actual, expected, "Encoded JSON does not match fixture", file: file, line: line)
    }
}
