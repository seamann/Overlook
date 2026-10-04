import Foundation

private struct ScopeTestFailure: Error, CustomStringConvertible { let description: String }
private enum ScopeError: Error { case failure }

@MainActor private final class ScopeGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var earlyResult: Result<Void, Error>?
    private(set) var isWaiting = false
    func wait() async throws {
        isWaiting = true
        try await withCheckedThrowingContinuation {
            if let earlyResult { $0.resume(with: earlyResult) }
            else { continuation = $0 }
        }
    }
    func finish(_ result: Result<Void, Error> = .success(())) {
        if let continuation { self.continuation = nil; continuation.resume(with: result) }
        else { earlyResult = result }
    }
}

@MainActor private final class ScopeOwner {
    var generation = 1
    var socket: NSObject? = NSObject()
    var operations = 0
    var failures = 0
}

@main struct WebRTCConnectionTaskScopeTests {
    @MainActor static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("current hotplug delay runs once", testCurrentDelay),
            ("cancelled hotplug delay cannot reconnect", testCancelledDelay),
            ("old hotplug generation cannot reconnect", testOldGeneration),
            ("replacement socket invalidates old hotplug", testReplacementSocket),
            ("current keepalive failure reaches owner", testCurrentFailure),
            ("old keepalive failure cannot affect a new session", testOldFailure),
            ("cancelled keepalive cannot request reconnect", testCancelledFailure),
            ("already retired keepalive never sends", testRetiredBeforeSend),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("WebRTCConnectionTaskScopeTests: \(tests.count - failures)/\(tests.count) passed")
        if failures > 0 { exit(1) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ScopeTestFailure(description: message) }
    }

    @MainActor private static func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ScopeTestFailure(description: "Scope fixture did not reach its event") }
            await Task.yield()
        }
    }

    @MainActor private static func delayed(
        _ owner: ScopeOwner, gate: ScopeGate
    ) -> Task<Void, Never> {
        let scope = WebRTCConnectionTaskScope(generation: owner.generation, socket: owner.socket)
        return Task { @MainActor in
            await scope.run(
                afterNanoseconds: 800_000_000, sleep: { _ in try await gate.wait() },
                isCurrent: { scope.isCurrent(generation: owner.generation, socket: owner.socket) },
                operation: { owner.operations += 1 }, onFailure: { _ in owner.failures += 1 }
            )
        }
    }

    @MainActor private static func testCurrentDelay() async throws {
        let owner = ScopeOwner(), gate = ScopeGate()
        let task = delayed(owner, gate: gate)
        try await until { gate.isWaiting }
        gate.finish()
        await task.value
        try expect(owner.operations == 1 && owner.failures == 0, "Current delay did not reconnect once")
    }

    @MainActor private static func testCancelledDelay() async throws {
        let owner = ScopeOwner(), gate = ScopeGate()
        let task = delayed(owner, gate: gate)
        try await until { gate.isWaiting }
        task.cancel()
        gate.finish(.failure(CancellationError()))
        await task.value
        try expect(owner.operations == 0 && owner.failures == 0, "Cancelled sleep was ignored and reconnected")
    }

    @MainActor private static func testOldGeneration() async throws {
        let owner = ScopeOwner(), gate = ScopeGate()
        let task = delayed(owner, gate: gate)
        try await until { gate.isWaiting }
        owner.generation += 1
        gate.finish()
        await task.value
        try expect(owner.operations == 0, "Old generation triggered hotplug reconnect")
    }

    @MainActor private static func testReplacementSocket() async throws {
        let owner = ScopeOwner(), gate = ScopeGate()
        let task = delayed(owner, gate: gate)
        try await until { gate.isWaiting }
        owner.socket = NSObject()
        gate.finish()
        await task.value
        try expect(owner.operations == 0, "Replacement socket accepted old hotplug task")
    }

    @MainActor private static func failing(
        _ owner: ScopeOwner, gate: ScopeGate
    ) -> Task<Void, Never> {
        let scope = WebRTCConnectionTaskScope(generation: owner.generation, socket: owner.socket)
        return Task { @MainActor in
            await scope.run(
                isCurrent: { scope.isCurrent(generation: owner.generation, socket: owner.socket) },
                operation: { owner.operations += 1; try await gate.wait() },
                onFailure: { _ in owner.failures += 1 }
            )
        }
    }

    @MainActor private static func testCurrentFailure() async throws {
        let owner = ScopeOwner(), gate = ScopeGate()
        let task = failing(owner, gate: gate)
        try await until { gate.isWaiting }
        gate.finish(.failure(ScopeError.failure))
        await task.value
        try expect(owner.operations == 1 && owner.failures == 1, "Current keepalive failure did not reach its owner")
    }

    @MainActor private static func testOldFailure() async throws {
        let owner = ScopeOwner(), gate = ScopeGate()
        let task = failing(owner, gate: gate)
        try await until { gate.isWaiting }
        owner.generation += 1; owner.socket = NSObject()
        gate.finish(.failure(ScopeError.failure))
        await task.value
        try expect(owner.failures == 0, "Old keepalive failure requested reconnect on the replacement")
    }

    @MainActor private static func testCancelledFailure() async throws {
        let owner = ScopeOwner(), gate = ScopeGate()
        let task = failing(owner, gate: gate)
        try await until { gate.isWaiting }
        task.cancel()
        gate.finish(.failure(ScopeError.failure))
        await task.value
        try expect(owner.failures == 0, "Cancelled keepalive requested reconnect")
    }

    @MainActor private static func testRetiredBeforeSend() async throws {
        let owner = ScopeOwner(), gate = ScopeGate()
        let task = failing(owner, gate: gate)
        owner.socket = NSObject()
        gate.finish(.failure(ScopeError.failure))
        await task.value
        try expect(owner.operations == 0 && owner.failures == 0, "Retired timer sent through the replacement")
    }
}
