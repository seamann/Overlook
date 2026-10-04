import Foundation

private struct JanusTestFailure: Error, CustomStringConvertible {
    let description: String
}

private enum FixtureError: Error { case timeout, send, disconnected }

@MainActor
private final class Gate {
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

@MainActor
private final class RequestProbe {
    var result: Result<[String: Any], Error>?
    var aborts = 0
    var sends = 0
}

@main
struct JanusRequestCoordinatorTests {
    @MainActor static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("response during suspended send is retained", testFastResponse),
            ("ACK waits for a final response", testAcknowledgement),
            ("send failure settles and clears deadline", testSendFailure),
            ("deadline settles a suspended send", testTimeout),
            ("already cancelled request never dispatches", testAlreadyCancelled),
            ("cancellation during dispatch settles once", testCancelledSend),
            ("cancellation while waiting settles once", testCancelledWait),
            ("disconnect settles all pending requests", testDisconnect),
            ("late and duplicate responses cannot finish again", testLateAndDuplicate),
            ("a retired deadline cannot finish a newer request", testRetiredDeadline),
            ("an ACK cannot hide a later send error", testAckThenSendFailure),
            ("cancel mark prevents queued dispatch admission", testCancellationAdmission),
            ("cancel during registration prevents queued send", testCancelAtDeadlineStart),
            ("a late send error cannot fail a replacement transaction", testRetiredSend),
            ("duplicate pending transaction leaves original owner intact", testDuplicateTransaction),
            ("a matching message without Janus type cannot finish", testMalformedResponse),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("JanusRequestCoordinatorTests: \(tests.count - failures)/\(tests.count) passed")
        if failures > 0 { exit(1) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw JanusTestFailure(description: message) }
    }

    @MainActor private static func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw JanusTestFailure(description: "Expected lifecycle event did not settle within one second")
            }
            await Task.yield()
        }
    }

    @MainActor private static func start(
        _ coordinator: JanusRequestCoordinator, _ probe: RequestProbe,
        transaction: String = "request", send: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                let response = try await coordinator.request(
                    transaction: transaction, timeoutNanoseconds: 8_000_000_000,
                    timeoutError: FixtureError.timeout,
                    send: { probe.sends += 1; try await send() },
                    abortTransport: { probe.aborts += 1 }
                )
                probe.result = .success(response)
            } catch { probe.result = .failure(error) }
        }
    }

    private static func response(_ transaction: String = "request", type: String = "success") -> [String: Any] {
        ["janus": type, "transaction": transaction, "data": ["id": 42]]
    }

    @MainActor private static func expectFailure(_ probe: RequestProbe, _ expected: FixtureError) throws {
        guard case .failure(let error)? = probe.result, let actual = error as? FixtureError,
              actual == expected else { throw JanusTestFailure(description: "Expected \(expected), got \(String(describing: probe.result))") }
    }

    @MainActor private static func testFastResponse() async throws {
        let deadline = Gate(), send = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish(); send.finish() }
        var registeredBeforeSend = false
        let task = start(coordinator, probe) {
            registeredBeforeSend = coordinator.pendingRequestCount == 1
            _ = coordinator.receive(response())
            try await send.wait()
        }
        try await until { send.isWaiting }
        // Also release the deadline: a response lost before registration must fail this test.
        deadline.finish()
        try await until { probe.result != nil }
        try expect(registeredBeforeSend, "Request was sent before its waiter was registered")
        guard case .success(let result)? = probe.result else { throw JanusTestFailure(description: "A fast response was lost") }
        try expect((result["data"] as? [String: Int])?["id"] == 42, "Wrong fast response")
        try expect(coordinator.pendingRequestCount == 0 && probe.aborts == 0, "Successful response left a pending request or aborted the socket")
        send.finish(.failure(FixtureError.send))
        await task.value
    }

    @MainActor private static func testAcknowledgement() async throws {
        let deadline = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish() }
        let task = start(coordinator, probe) {}
        try await until { probe.sends == 1 }
        try expect(coordinator.receive(response(type: "ack")), "Matching ACK was not consumed")
        try expect(coordinator.pendingRequestCount == 1, "ACK incorrectly finished the transaction")
        try expect(coordinator.receive(response()), "Final response did not match")
        try await until { probe.result != nil }
        guard case .success? = probe.result else { throw JanusTestFailure(description: "Final answer failed") }
        await task.value
    }

    @MainActor private static func testSendFailure() async throws {
        let deadline = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish() }
        let task = start(coordinator, probe) { throw FixtureError.send }
        try await until { probe.result != nil }
        try expectFailure(probe, .send)
        try expect(coordinator.pendingRequestCount == 0 && probe.aborts == 1, "Send failure did not clear its request and captured transport")
        await task.value
    }

    @MainActor private static func testTimeout() async throws {
        let deadline = Gate(), send = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish(); send.finish() }
        let task = start(coordinator, probe) { try await send.wait() }
        try await until { send.isWaiting && deadline.isWaiting }
        deadline.finish()
        try await until { probe.result != nil }
        try expectFailure(probe, .timeout)
        try expect(coordinator.pendingRequestCount == 0 && probe.aborts == 1, "Timeout did not settle its suspended send")
        try expect(!coordinator.receive(response()), "Late response resurrected a timed out request")
        send.finish(.failure(FixtureError.send))
        await task.value
    }

    @MainActor private static func testAlreadyCancelled() async throws {
        let probe = RequestProbe()
        let coordinator = JanusRequestCoordinator()
        let task = start(coordinator, probe) {}
        task.cancel()
        try await until { probe.result != nil }
        guard case .failure(let error)? = probe.result, error is CancellationError else {
            throw JanusTestFailure(description: "Already cancelled caller did not receive cancellation")
        }
        try expect(probe.sends == 0 && probe.aborts == 0 && coordinator.pendingRequestCount == 0, "An already cancelled caller dispatched")
        await task.value
    }

    @MainActor private static func testCancelledSend() async throws {
        let deadline = Gate(), send = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish(); send.finish() }
        let task = start(coordinator, probe) { try await send.wait() }
        try await until { send.isWaiting }
        task.cancel()
        try await until { probe.result != nil }
        guard case .failure(let error)? = probe.result, error is CancellationError else { throw JanusTestFailure(description: "Cancelled send did not settle") }
        try expect(probe.aborts == 1 && coordinator.pendingRequestCount == 0, "Cancelled send retained ownership")
        try expect(!coordinator.receive(response()), "Late response settled cancelled caller")
        send.finish(.failure(FixtureError.send))
        await task.value
    }

    @MainActor private static func testCancelledWait() async throws {
        let deadline = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish() }
        let task = start(coordinator, probe) {}
        try await until { probe.sends == 1 && deadline.isWaiting }
        task.cancel()
        try await until { probe.result != nil }
        guard case .failure(let error)? = probe.result, error is CancellationError else { throw JanusTestFailure(description: "Cancelled wait did not settle") }
        try expect(probe.aborts == 1 && coordinator.pendingRequestCount == 0, "Cancelled wait retained ownership")
        await task.value
    }

    @MainActor private static func testDisconnect() async throws {
        let deadlineA = Gate(), deadlineB = Gate(), send = Gate(), a = RequestProbe(), b = RequestProbe()
        var timeoutCalls = 0
        let coordinator = JanusRequestCoordinator(sleep: { _ in
            timeoutCalls += 1
            if timeoutCalls == 1 { try await deadlineA.wait() } else { try await deadlineB.wait() }
        })
        defer { deadlineA.finish(); deadlineB.finish(); send.finish() }
        let first = start(coordinator, a, transaction: "a") { try await send.wait() }
        let second = start(coordinator, b, transaction: "b") {}
        try await until { send.isWaiting && b.sends == 1 }
        coordinator.cancelAll(throwing: FixtureError.disconnected)
        try await until { a.result != nil && b.result != nil }
        try expectFailure(a, .disconnected); try expectFailure(b, .disconnected)
        try expect(a.aborts == 1 && b.aborts == 1 && coordinator.pendingRequestCount == 0, "Disconnect did not settle every request once")
        coordinator.cancelAll(throwing: FixtureError.disconnected)
        try expect(a.aborts == 1 && b.aborts == 1, "Second disconnect settled again")
        send.finish()
        await first.value; await second.value
    }

    @MainActor private static func testLateAndDuplicate() async throws {
        let deadline = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish() }
        let task = start(coordinator, probe) {}
        try await until { probe.sends == 1 }
        try expect(!coordinator.receive(response("unrelated")), "Unrelated transaction finished caller")
        try expect(coordinator.receive(response(type: "error")), "Final Janus error was not delivered to caller")
        try expect(!coordinator.receive(response()), "Duplicate final response finished again")
        try await until { probe.result != nil }
        try expect(coordinator.pendingRequestCount == 0 && probe.aborts == 0, "Delivered final response left transport cleanup")
        await task.value
    }

    @MainActor private static func testRetiredDeadline() async throws {
        let oldDeadline = Gate(), newDeadline = Gate(), first = RequestProbe(), second = RequestProbe()
        var timeoutCalls = 0
        var oldSleepReturned = false
        let coordinator = JanusRequestCoordinator(sleep: { _ in
            timeoutCalls += 1
            if timeoutCalls == 1 {
                try await oldDeadline.wait()
                oldSleepReturned = true
            } else { try await newDeadline.wait() }
        })
        defer { oldDeadline.finish(); newDeadline.finish() }
        let a = start(coordinator, first) {}
        try await until { first.sends == 1 && oldDeadline.isWaiting }
        _ = coordinator.receive(response())
        try await until { first.result != nil }
        await a.value
        let b = start(coordinator, second) {}
        try await until { second.sends == 1 && newDeadline.isWaiting }
        oldDeadline.finish()
        // The timeout continuation runs on MainActor without another suspension
        // between this sleep returning and settlement. Yield until that old actor
        // turn has run before answering the replacement.
        try await until { oldSleepReturned }
        try expect(coordinator.pendingRequestCount == 1 && second.result == nil,
                   "Retired timeout changed the replacement before its final response")
        try expect(coordinator.receive(response()), "Retired timeout removed the replacement request")
        try await until { second.result != nil }
        guard case .success? = second.result else { throw JanusTestFailure(description: "Retired timeout failed the replacement") }
        await b.value
    }

    @MainActor private static func testAckThenSendFailure() async throws {
        let deadline = Gate(), send = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish(); send.finish() }
        let task = start(coordinator, probe) { try await send.wait() }
        try await until { send.isWaiting }
        _ = coordinator.receive(response(type: "ack"))
        send.finish(.failure(FixtureError.send))
        try await until { probe.result != nil }
        try expectFailure(probe, .send)
        try expect(probe.aborts == 1 && coordinator.pendingRequestCount == 0, "ACK hid a failed send")
        await task.value
    }

    private static func testCancellationAdmission() async throws {
        let cancelledBeforeRegistration = JanusRequestCancellation()
        cancelledBeforeRegistration.cancel()
        try expect(cancelledBeforeRegistration.isCancelled, "Synchronous cancel mark was lost")
        try expect(!cancelledBeforeRegistration.beginDispatch(), "A queued send claimed dispatch after cancellation")
        let cancelledAfterAdmission = JanusRequestCancellation()
        try expect(cancelledAfterAdmission.beginDispatch(), "Current send could not claim dispatch")
        cancelledAfterAdmission.cancel()
        try expect(!cancelledAfterAdmission.beginDispatch(), "Cancellation admitted a later send")
    }

    @MainActor private static func testCancelAtDeadlineStart() async throws {
        let deadline = Gate(), probe = RequestProbe()
        var requestTask: Task<Void, Never>?
        var cancelledBeforeSend = false
        let coordinator = JanusRequestCoordinator(sleep: { _ in
            cancelledBeforeSend = probe.sends == 0
            requestTask?.cancel()
            try await deadline.wait()
        })
        defer { deadline.finish() }
        requestTask = start(coordinator, probe) {}
        try await until { probe.result != nil }
        try expect(cancelledBeforeSend, "Fixture did not cancel in the registered-before-send window")
        guard case .failure(let error)? = probe.result, error is CancellationError else {
            throw JanusTestFailure(description: "Registration cancellation did not settle")
        }
        try expect(probe.sends == 0 && probe.aborts == 1 && coordinator.pendingRequestCount == 0,
                   "Queued send started after cancellation was synchronously observed")
        await requestTask?.value
    }

    @MainActor private static func testRetiredSend() async throws {
        let deadlineA = Gate(), deadlineB = Gate(), oldSend = Gate()
        let first = RequestProbe(), second = RequestProbe()
        var timeoutCalls = 0
        var oldSendReturned = false
        let coordinator = JanusRequestCoordinator(sleep: { _ in
            timeoutCalls += 1
            if timeoutCalls == 1 { try await deadlineA.wait() } else { try await deadlineB.wait() }
        })
        defer { deadlineA.finish(); deadlineB.finish(); oldSend.finish() }
        let a = start(coordinator, first) {
            defer { oldSendReturned = true }
            _ = coordinator.receive(response())
            try await oldSend.wait()
        }
        try await until { first.result != nil && oldSend.isWaiting }
        await a.value
        let b = start(coordinator, second) {}
        try await until { second.sends == 1 }
        oldSend.finish(.failure(FixtureError.send))
        try await until { oldSendReturned }
        try expect(second.result == nil && second.aborts == 0 && coordinator.pendingRequestCount == 1,
                   "Late send error from a retired request failed its replacement")
        _ = coordinator.receive(response())
        try await until { second.result != nil }
        await b.value
    }

    @MainActor private static func testDuplicateTransaction() async throws {
        let deadline = Gate(), first = RequestProbe(), second = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish() }
        let a = start(coordinator, first) {}
        try await until { first.sends == 1 }
        let b = start(coordinator, second) {}
        try await until { second.result != nil }
        guard case .failure(let error)? = second.result,
              error as? JanusRequestCoordinatorError == .duplicateTransaction else {
            throw JanusTestFailure(description: "Duplicate request replaced its original owner")
        }
        try expect(second.sends == 0 && second.aborts == 0 && coordinator.pendingRequestCount == 1,
                   "Duplicate transaction affected the original request")
        _ = coordinator.receive(response())
        try await until { first.result != nil }
        await a.value; await b.value
    }

    @MainActor private static func testMalformedResponse() async throws {
        let deadline = Gate(), probe = RequestProbe()
        let coordinator = JanusRequestCoordinator(sleep: { _ in try await deadline.wait() })
        defer { deadline.finish() }
        let task = start(coordinator, probe) {}
        try await until { probe.sends == 1 }
        try expect(!coordinator.receive(["transaction": "request"]), "Malformed response completed the request")
        try expect(coordinator.pendingRequestCount == 1 && probe.result == nil, "Malformed response changed ownership")
        _ = coordinator.receive(response())
        try await until { probe.result != nil }
        await task.value
    }
}
