import Foundation
import Agents
import AgentsChat

// End-to-end smoke test: drives the real Swift AgentClient against a live
// Cloudflare Agents worker (examples/smoke) running on `wrangler dev`.
//
// Usage: swift run E2ESmoke [host]   (default host: localhost:8787)

struct StateAgentState: Codable, Sendable, Equatable {
    var counter: Int
    var items: [String]
    var lastUpdated: String?
}

struct EmptyState: Codable, Sendable {}

/// A one-shot guard so only the first of several racing tasks "wins".
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Runs `operation`, failing if it does not finish within `seconds`.
///
/// Uses a continuation that resumes with whichever of (operation, timeout)
/// finishes first and *abandons the loser* — a `TaskGroup` would instead await
/// all children before returning, deadlocking on a non-cancellable operation
/// (e.g. `ready()` blocked on a connection that never opens).
func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        Task {
            let value = await operation()
            if once.claim() { cont.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() {
                cont.resume(throwing: NSError(
                    domain: "E2ESmoke", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "timed out after \(seconds)s"]))
            }
        }
    }
}

@MainActor
final class Report {
    var failures = 0
    var count = 0
    func check(_ condition: Bool, _ label: String, detail: String = "") {
        count += 1
        if condition {
            print("  ✅ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            failures += 1
            print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }
}

@main
struct E2ESmoke {
    @MainActor
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0) // unbuffered so progress is visible live
        let host = CommandLine.arguments.dropFirst().first ?? "localhost:8787"
        let report = Report()
        print("E2E smoke test against ws host: \(host)\n")

        // ---------------------------------------------------------------- StateAgent
        print("StateAgent (state sync + RPC):")
        let stateClient = AgentClient(
            AgentClientOptions(agent: "StateAgent", name: "smoke", host: host),
            state: StateAgentState.self
        )
        stateClient.connect()
        do {
            try await withTimeout(8) { await stateClient.ready() }
            report.check(stateClient.identified, "received cf_agent_identity (ready)")
            report.check(stateClient.connection == .connected, "connection phase == .connected")
            report.check(stateClient.state != nil, "initial state pushed by server on connect",
                         detail: stateClient.state.map { "counter=\($0.counter)" } ?? "nil")

            // Deterministic baseline.
            let afterReset: StateAgentState = try await stateClient.call(
                "resetState", returning: StateAgentState.self, timeout: .seconds(5))
            report.check(afterReset.counter == 0, "resetState RPC returns counter 0",
                         detail: "got \(afterReset.counter)")

            // RPC mutate.
            let afterInc: StateAgentState = try await stateClient.call(
                "increment", returning: StateAgentState.self, timeout: .seconds(5))
            report.check(afterInc.counter == 1, "increment RPC returns counter 1",
                         detail: "got \(afterInc.counter)")

            // Server -> client state BROADCAST (distinct from the RPC return value):
            // increment() calls setState server-side, which broadcasts to our socket.
            var observed = stateClient.state?.counter
            for _ in 0..<40 where observed != 1 {
                try await Task.sleep(nanoseconds: 50_000_000)
                observed = stateClient.state?.counter
            }
            report.check(observed == 1, "observable state updated via server broadcast",
                         detail: "client.state.counter=\(observed.map(String.init) ?? "nil")")

            // RPC with a string arg + array state.
            let afterAdd: StateAgentState = try await stateClient.call(
                "addItem", ["hello-swift"], returning: StateAgentState.self, timeout: .seconds(5))
            report.check(afterAdd.items == ["hello-swift"], "addItem RPC appends to items array",
                         detail: "items=\(afterAdd.items)")
        } catch {
            report.check(false, "StateAgent block completed without throwing", detail: "\(error)")
        }
        stateClient.disconnect()

        // ---------------------------------------------------------------- CallableAgent
        print("\nCallableAgent (pure RPC):")
        let callClient = AgentClient(
            AgentClientOptions(agent: "CallableAgent", name: "smoke", host: host),
            state: EmptyState.self
        )
        callClient.connect()
        do {
            try await withTimeout(8) { await callClient.ready() }
            report.check(callClient.identified, "received cf_agent_identity (ready)")

            let sum: Int = try await callClient.call(
                "add", [2, 3], returning: Int.self, timeout: .seconds(5))
            report.check(sum == 5, "add(2,3) == 5", detail: "got \(sum)")

            let echoed: String = try await callClient.call(
                "echo", ["ping"], returning: String.self, timeout: .seconds(5))
            report.check(echoed == "ping", "echo(\"ping\") == \"ping\"", detail: "got \"\(echoed)\"")

            let ts: String = try await callClient.call(
                "getTimestamp", returning: String.self, timeout: .seconds(5))
            report.check(!ts.isEmpty, "getTimestamp() returns non-empty string", detail: ts)

            // Server-thrown error should surface as a Swift throw.
            var threw = false
            do {
                let _: JSONValue = try await callClient.call(
                    "throwError", ["boom"], returning: JSONValue.self, timeout: .seconds(5))
            } catch {
                threw = true
            }
            report.check(threw, "throwError RPC surfaces a thrown error to the client")
        } catch {
            report.check(false, "CallableAgent block completed without throwing", detail: "\(error)")
        }
        callClient.disconnect()

        // ---------------------------------------------------------------- Summary
        print("\n———")
        print("\(report.count - report.failures)/\(report.count) checks passed.")
        if report.failures > 0 {
            print("RESULT: FAIL (\(report.failures) failing)")
            exit(1)
        }
        print("RESULT: PASS")
        exit(0)
    }
}
