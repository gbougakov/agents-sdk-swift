import Testing
import Foundation
@testable import Agents

/// Tests for ``ReconnectionConfig`` and its ``ReconnectionConfig/delay(forRetryCount:)``
/// backoff curve, which ports `partysocket`'s `_getNextDelay`
/// (`node_modules/partysocket/dist/ws.js`):
///
/// ```js
/// let delay = 0;
/// if (this._retryCount > 0) {
///   delay = minReconnectionDelay * reconnectionDelayGrowFactor ** (this._retryCount - 1);
///   if (delay > maxReconnectionDelay) delay = maxReconnectionDelay;
/// }
/// ```
///
/// The Swift port treats `retryCount <= 1` as the immediate-first-reconnect case
/// (`delay = 0`) and otherwise computes
/// `min(minReconnectionDelay * growFactor^(retryCount - 1), maxReconnectionDelay)`.
@Suite("Backoff")
struct BackoffTests {

    /// Tolerance for floating-point comparisons of the backoff curve.
    private let epsilon = 1e-9

    @Test("default config matches the partysocket defaults")
    func defaults() {
        let config = ReconnectionConfig.default
        #expect(config.minReconnectionDelay == 3.0)
        #expect(config.maxReconnectionDelay == 10.0)
        #expect(config.reconnectionDelayGrowFactor == 1.3)
        #expect(config.minUptime == 5.0)
        #expect(config.connectionTimeout == 4.0)
        #expect(config.maxRetries == .max)
    }

    @Test("retry counts <= 1 yield an immediate (zero) delay")
    func immediateFirstReconnect() {
        let config = ReconnectionConfig.default
        #expect(config.delay(forRetryCount: 0) == 0)
        #expect(config.delay(forRetryCount: 1) == 0)
        #expect(config.delay(forRetryCount: -5) == 0)
    }

    /// The partysocket backoff table: `3.0 * 1.3^(n-1)` capped at `10.0`.
    ///
    /// | retryCount | delay (s)                    |
    /// |-----------:|------------------------------|
    /// | 2          | 3.0 * 1.3^1 = 3.9            |
    /// | 3          | 3.0 * 1.3^2 = 5.07          |
    /// | 4          | 3.0 * 1.3^3 = 6.591         |
    /// | 5          | 3.0 * 1.3^4 = 8.5683        |
    /// | 6          | 3.0 * 1.3^5 = 11.13879 -> capped 10.0 |
    @Test("backoff curve follows 3.0 * 1.3^(n-1)")
    func backoffCurve() {
        let config = ReconnectionConfig.default
        #expect(abs(config.delay(forRetryCount: 2) - 3.9) < epsilon)
        #expect(abs(config.delay(forRetryCount: 3) - 5.07) < epsilon)
        #expect(abs(config.delay(forRetryCount: 4) - 6.591) < epsilon)
        #expect(abs(config.delay(forRetryCount: 5) - 8.5683) < epsilon)
    }

    @Test("delay is capped at maxReconnectionDelay (10.0s)")
    func cappedAtMax() {
        let config = ReconnectionConfig.default
        // 3.0 * 1.3^5 = 11.13879 -> capped to 10.0.
        #expect(config.delay(forRetryCount: 6) == 10.0)
        // Large retry counts stay capped.
        #expect(config.delay(forRetryCount: 50) == 10.0)
        #expect(config.delay(forRetryCount: 1000) == 10.0)
    }

    @Test("the backoff curve is monotonically non-decreasing up to the cap")
    func monotonic() {
        let config = ReconnectionConfig.default
        var previous = config.delay(forRetryCount: 2)
        for n in 3...20 {
            let current = config.delay(forRetryCount: n)
            #expect(current >= previous)
            #expect(current <= config.maxReconnectionDelay + epsilon)
            previous = current
        }
    }

    @Test("custom growth factor and bounds are honoured")
    func customConfig() {
        let config = ReconnectionConfig(
            minReconnectionDelay: 1.0,
            maxReconnectionDelay: 4.0,
            reconnectionDelayGrowFactor: 2.0
        )
        #expect(config.delay(forRetryCount: 1) == 0)
        #expect(abs(config.delay(forRetryCount: 2) - 2.0) < epsilon)  // 1.0 * 2^1
        #expect(abs(config.delay(forRetryCount: 3) - 4.0) < epsilon)  // 1.0 * 2^2
        #expect(config.delay(forRetryCount: 4) == 4.0)                // 1.0 * 2^3 = 8 -> capped 4.0
    }
}
