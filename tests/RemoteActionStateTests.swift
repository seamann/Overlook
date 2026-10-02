import Foundation

@main
struct RemoteActionStateTests {
    @MainActor
    static func main() async throws {
        try testValidation()
        try testDeduplicationAndEviction()
        try testFrameLifetimeAndSessions()
        try await testCancellationWaitsForRelease()
        try await testUnconfirmedReleaseFailsClosed()
        print("RemoteActionStateTests passed (5 behavioral groups)")
    }

    private static func testValidation() throws {
        let click = try RemoteActionCommand.parse(["type": "click", "x": 0, "y": 1079])
        try click.validate(width: 1920, height: 1080)
        precondition(RemoteActionCommand.signedHID(pixel: 0, extent: 1920) == -32767)
        precondition(RemoteActionCommand.signedHID(pixel: 1919, extent: 1920) == 32767)
        try expect(.invalidRequest) { try click.validate(width: 1920, height: 1079) }
        for invalid: [String: Any] in [
            ["type": "click", "x": true, "y": 1],
            ["type": "click", "x": 1.5, "y": 1],
            ["type": "click", "x": -1, "y": 1],
            ["type": "text", "value": ""],
            ["type": "text", "value": "x", "extra": "unbounded"],
            ["type": "scroll", "x": 1, "y": 1, "delta_y": 11],
            ["type": "drag", "x": 0, "y": 0, "to_x": 5, "to_y": 5, "duration_ms": 2001],
            ["type": "shortcut", "keys": ["ControlLeft", "KeyS"]],
            ["type": "shortcut", "keys": ["Enter", "Enter"]],
            ["type": "batch", "actions": []]
        ] { try expect(.invalidRequest) { _ = try RemoteActionCommand.parse(invalid) } }
    }

    @MainActor
    private static func testDeduplicationAndEviction() throws {
        let ledger = RemoteActionLedger(maximumRecords: 2, bootID: "test-boot")
        let session = ledger.synchronize(sourceID: "video-A", transportID: "input-A", modeGeneration: 1)
        let action = try RemoteActionCommand.parse(["type": "text", "value": "Änderung\nZeile 2"])
        let digest = action.digest(frameID: "f1")
        try check(ledger.reserve(sessionID: session, sequence: 1, digest: digest))
        try check(!ledger.reserve(sessionID: session, sequence: 1, digest: digest))
        try expect(.actionConflict) { _ = try ledger.reserve(sessionID: session, sequence: 1, digest: "different") }
        ledger.finish(sessionID: session, sequence: 1, state: .transmitted)
        try check(ledger.record(sessionID: session, sequence: 1).state == .transmitted)
        try check(!ledger.reserve(sessionID: session, sequence: 1, digest: digest))
        _ = try ledger.reserve(sessionID: session, sequence: 2, digest: "second")
        ledger.finish(sessionID: session, sequence: 2, state: .notStarted, error: .cancelled)
        _ = try ledger.reserve(sessionID: session, sequence: 3, digest: "third")
        try expect(.actionExpired) { _ = try ledger.reserve(sessionID: session, sequence: 1, digest: digest) }
        precondition(ledger.nextActionSequence == 4)
    }

    @MainActor
    private static func testFrameLifetimeAndSessions() throws {
        let ledger = RemoteActionLedger(frameTTL: 30, bootID: "test-boot")
        let session = ledger.synchronize(sourceID: "A", transportID: "I", modeGeneration: 1)
        ledger.registerFrame(id: "one", width: 100, height: 100, receivedAt: 10)
        _ = try ledger.frame(id: "one", now: 39.9)
        try expect(.staleFrame) { _ = try ledger.frame(id: "one", now: 40.1) }
        ledger.registerFrame(id: "two", width: 100, height: 100, receivedAt: 50)
        _ = try ledger.consumeFrame(id: "two", now: 51)
        try expect(.staleFrame) { _ = try ledger.frame(id: "two", now: 51) }
        ledger.registerFrame(id: "three", width: 100, height: 100, receivedAt: 60)
        ledger.invalidateFrames()
        try expect(.staleFrame) { _ = try ledger.frame(id: "three", now: 61) }
        _ = try ledger.reserve(sessionID: session, sequence: 1, digest: "d")
        let replaced = ledger.synchronize(sourceID: "B", transportID: "I", modeGeneration: 1)
        precondition(replaced != session)
        _ = try ledger.reserve(sessionID: replaced, sequence: 1, digest: "new-current")
        try expect(.sessionChanged) { try ledger.markDispatched(sessionID: session, sequence: 1) }
        try check(ledger.record(sessionID: replaced, sequence: 1).digest == "new-current")
        try check(!ledger.record(sessionID: replaced, sequence: 1).didDispatch)
        try check(ledger.record(sessionID: session, sequence: 1).digest == "d")
        try expect(.sessionChanged) { _ = try ledger.reserve(sessionID: session, sequence: 1, digest: "d") }
        precondition(ledger.nextActionSequence == 2)
        let restarted = RemoteActionLedger(bootID: "new-boot")
        precondition(restarted.synchronize(sourceID: "B", transportID: "I", modeGeneration: 1) != replaced)
    }

    private static func testCancellationWaitsForRelease() async throws {
        let recorder = GestureRecorder()
        let operation = Task {
            try await RemoteGestureCleanup.perform(
                press: { await recorder.markPressed() },
                body: { try await Task.sleep(nanoseconds: 10_000_000_000) },
                release: {
                    precondition(!Task.isCancelled)
                    try await Task.sleep(nanoseconds: 30_000_000)
                    await recorder.markReleased()
                }
            )
        }
        while !(await recorder.pressed) { await Task.yield() }
        operation.cancel()
        do { try await operation.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError { }
        let released = await recorder.released
        precondition(released, "Gate could release before cleanup finishes")
    }

    private static func testUnconfirmedReleaseFailsClosed() async throws {
        do {
            try await RemoteGestureCleanup.perform(
                press: {}, body: {}, release: { throw RemoteActionError.transportError }, timeout: 0.02
            )
            preconditionFailure("Unconfirmed release reported success")
        } catch let error as RemoteActionError { precondition(error == .cleanupFailed) }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try await RemoteGestureCleanup.perform(
                press: {}, body: {}, release: { try await Task.sleep(nanoseconds: 10_000_000_000) }, timeout: 0.02
            )
            preconditionFailure("Unbounded release reported success")
        } catch let error as RemoteActionError { precondition(error == .cleanupFailed) }
        precondition(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    private static func expect(_ expected: RemoteActionError, _ body: () throws -> Void) throws {
        do { try body(); preconditionFailure("Expected \(expected)") }
        catch let error as RemoteActionError { precondition(error == expected, "Got \(error), expected \(expected)") }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool) rethrows {
        let actual = try condition()
        precondition(actual)
    }
}

private actor GestureRecorder {
    var pressed = false
    var released = false
    func markPressed() { pressed = true }
    func markReleased() { released = true }
}
