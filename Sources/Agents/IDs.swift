import Foundation

/// Generates a lowercased UUID string, matching the JavaScript `crypto.randomUUID()` output.
///
/// `crypto.randomUUID()` returns a canonical RFC 4122 version-4 UUID in lowercase
/// (e.g. `"f47ac10b-58cc-4372-a567-0e02b2c3d479"`). `Foundation.UUID().uuidString` produces the
/// same shape but uppercased, so we lowercase it to match the wire format exactly. This is used
/// for the PartySocket connection id (`_pk`) and RPC request ids.
public func newUUIDLower() -> String {
    UUID().uuidString.lowercased()
}

/// The default Nano ID alphabet: URL-safe characters `A-Za-z0-9_-` (64 symbols).
///
/// Matches the `nanoid` package's default alphabet so generated ids are byte-compatible with the
/// JS client (e.g. chat request ids use `nanoid(8)`).
private let nanoidAlphabet: [Character] = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
)

/// Generates a random, URL-safe identifier using the default Nano ID alphabet (`A-Za-z0-9_-`).
///
/// Each character is drawn uniformly from the 64-symbol alphabet using the system CSPRNG
/// (`SystemRandomNumberGenerator`). Because the alphabet size is a power of two (64), sampling an
/// index in `0..<64` is unbiased.
///
/// - Parameter size: The number of characters to generate. Defaults to `21` (the `nanoid`
///   library default). The chat layer uses `nanoid(8)` for request ids.
/// - Returns: A random identifier of the requested length.
public func nanoid(_ size: Int = 21) -> String {
    guard size > 0 else { return "" }
    var generator = SystemRandomNumberGenerator()
    var result = ""
    result.reserveCapacity(size)
    let count = nanoidAlphabet.count
    for _ in 0..<size {
        let index = Int.random(in: 0..<count, using: &generator)
        result.append(nanoidAlphabet[index])
    }
    return result
}
