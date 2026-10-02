import Foundation

@main
struct SessionConnectionCoordinatorTests {
    @MainActor
    static func main() async throws {
        try await testLatestAuthenticationWins()
        try await testSupersededAuthenticationCannotCommitWhileLatestWaits()
        try await testDisconnectDuringPreparation()
        try await testManualTokenLookupBelongsToAttempt()
        try await testHIDEnableAndDisableSettleBeforeReplacement()
        try await testMutationDrainPrecedesReplacement()
        try await testStaleVideoCompletionCannotChangeReplacement()
        try await testCancellationAndAuthenticationFailureRemainDistinct()
        try await testCurrentTransportFailureKeepsAPIConnection()
        try await testFailedTeardownBlocksReplacementUntilRetry()
        try await testCurrentCancellationCleansCommittedSession()
        try await testCancelledTaskCannotStartPreparation()
        try await testHIDEnableFailureStaysOwnedUntilDisconnect()
        try await testCancelledSessionReportsFailedCleanup()
        print("SessionConnectionCoordinatorTests passed (14 behavioral groups)")
    }

    @MainActor
    private static func testLatestAuthenticationWins() async throws {
        let fixture = SessionFixture()
        let blockedA = SessionGate()
        fixture.preparationGates["A"] = blockedA
        let a = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("prepare:A")
        let b = fixture.coordinator.startConnection(to: fixture.device("B"))
        let connected = try await b.task.value
        precondition(connected.name == "B", "B must finish without waiting for stale authentication")
        precondition(fixture.coordinator.isCurrent(b.id))
        precondition(!fixture.coordinator.isCurrent(a.id))
        blockedA.release()
        await expectCancellation(a.task)
        precondition(fixture.committedNames == ["B"])
        precondition(fixture.installedName == "B")
    }

    @MainActor
    private static func testSupersededAuthenticationCannotCommitWhileLatestWaits() async throws {
        let fixture = SessionFixture()
        let blockedA = SessionGate()
        let blockedB = SessionGate()
        fixture.preparationGates = ["A": blockedA, "B": blockedB]
        let a = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("prepare:A")
        let b = fixture.coordinator.startConnection(to: fixture.device("B"))
        await fixture.waitFor("prepare:B")
        blockedA.release()
        await expectCancellation(a.task)
        precondition(fixture.committedNames.isEmpty)
        precondition(fixture.coordinator.isConnecting, "Old completion must not clear the new attempt's busy state")
        blockedB.release()
        _ = try await b.task.value
        precondition(fixture.committedNames == ["B"])
        precondition(!fixture.coordinator.isConnecting)
    }

    @MainActor
    private static func testDisconnectDuringPreparation() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        fixture.preparationGates["A"] = gate
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("prepare:A")
        let disconnect = fixture.coordinator.disconnect()
        precondition(!fixture.coordinator.isCurrent(attempt.id))
        precondition(!fixture.coordinator.isConnecting)
        await disconnect.value
        gate.release()
        await expectCancellation(attempt.task)
        precondition(fixture.committedNames.isEmpty)
        precondition(!fixture.events.contains("enable:A"))
    }

    @MainActor
    private static func testManualTokenLookupBelongsToAttempt() async throws {
        let fixture = SessionFixture()
        let tokenLookup = SessionGate()
        let manual = fixture.coordinator.startConnection(deviceFactory: {
            fixture.record("token-lookup")
            await tokenLookup.wait()
            return fixture.device("manual")
        })
        await fixture.waitFor("token-lookup")
        let selected = fixture.coordinator.startConnection(to: fixture.device("selected"))
        _ = try await selected.task.value
        tokenLookup.release()
        await expectCancellation(manual.task)
        precondition(!fixture.events.contains("prepare:manual"))
        precondition(fixture.committedNames == ["selected"])
    }

    @MainActor
    private static func testHIDEnableAndDisableSettleBeforeReplacement() async throws {
        let fixture = SessionFixture()
        let enableA = SessionGate()
        let disableA = SessionGate()
        fixture.enableGates["A"] = enableA
        fixture.disableGates["A"] = disableA
        let a = fixture.coordinator.startConnection(to: fixture.device("A", host: "same.invalid"))
        await fixture.waitFor("enable:A")
        let b = fixture.coordinator.startConnection(to: fixture.device("B", host: "same.invalid"))
        await fixture.waitFor("prepared:B")
        precondition(!fixture.events.contains("enable:B"))
        enableA.release()
        await fixture.waitFor("disable:A")
        precondition(!fixture.events.contains("enable:B"))
        disableA.release()
        _ = try await b.task.value
        await expectCancellation(a.task)
        fixture.expectOrder("enabled:A", "disable:A", "disabled:A", "commit:B", "enable:B")
        precondition(!fixture.events.contains("disable:B"))
        precondition(fixture.installedName == "B")
    }

    @MainActor
    private static func testMutationDrainPrecedesReplacement() async throws {
        let fixture = SessionFixture()
        let a = fixture.coordinator.startConnection(to: fixture.device("A"))
        _ = try await a.task.value
        let drain = SessionGate()
        fixture.nextDrainGate = drain
        let b = fixture.coordinator.startConnection(to: fixture.device("B"))
        await fixture.waitFor("prepared:B")
        precondition(fixture.installedName == nil, "Invalidation is synchronous")
        precondition(!fixture.events.contains("commit:B"))
        drain.release()
        _ = try await b.task.value
        fixture.expectOrder("drained:2", "disable:A", "commit:B", "enable:B")
    }

    @MainActor
    private static func testStaleVideoCompletionCannotChangeReplacement() async throws {
        let fixture = SessionFixture()
        let videoA = SessionGate()
        fixture.videoGates["A"] = videoA
        fixture.videoFailures.insert("A")
        let a = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("video:A")
        let b = fixture.coordinator.startConnection(to: fixture.device("B"))
        _ = try await b.task.value
        let invalidationsBeforeOldCompletion = fixture.invalidationCount
        videoA.release()
        await expectCancellation(a.task)
        precondition(fixture.reportedErrors.isEmpty)
        precondition(fixture.invalidationCount == invalidationsBeforeOldCompletion)
        precondition(fixture.installedName == "B")
        precondition(!fixture.coordinator.isConnecting)
    }

    @MainActor
    private static func testCancellationAndAuthenticationFailureRemainDistinct() async throws {
        let cancelled = SessionFixture()
        cancelled.preparationErrors["cancel"] = URLError(.cancelled)
        let attempt = cancelled.coordinator.startConnection(to: cancelled.device("cancel"))
        await expectCancellation(attempt.task)
        precondition(!cancelled.coordinator.isConnecting)

        let failed = SessionFixture()
        failed.preparationErrors["auth"] = SessionFixtureError.authentication
        do {
            _ = try await failed.coordinator.startConnection(to: failed.device("auth")).task.value
            preconditionFailure("Authentication failure was ignored")
        } catch SessionFixtureError.authentication { }
        precondition(failed.committedNames.isEmpty)
        precondition(!failed.coordinator.isConnecting)
    }

    @MainActor
    private static func testCurrentTransportFailureKeepsAPIConnection() async throws {
        let fixture = SessionFixture()
        fixture.videoFailures.insert("A")
        let result = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        precondition(result.name == "A")
        precondition(fixture.installedName == "A")
        precondition(fixture.reportedErrors == ["WebRTC"])
        let disconnect = fixture.coordinator.disconnect()
        precondition(fixture.installedName == nil)
        await disconnect.value
        fixture.expectOrder("enabled:A", "disable:A", "disabled:A")
    }

    @MainActor
    private static func testFailedTeardownBlocksReplacementUntilRetry() async throws {
        let fixture = SessionFixture()
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        fixture.disableFailures.insert("A")
        do {
            _ = try await fixture.coordinator.startConnection(to: fixture.device("B")).task.value
            preconditionFailure("Unconfirmed teardown allowed replacement")
        } catch SessionConnectionError.previousSessionCleanupFailed { }
        precondition(fixture.committedNames == ["A"])
        precondition(!fixture.events.contains("enable:B"))
        fixture.disableFailures.remove("A")
        _ = try await fixture.coordinator.startConnection(to: fixture.device("C")).task.value
        precondition(fixture.committedNames == ["A", "C"])
        fixture.expectOrder("disabled:A", "commit:C", "enable:C")
    }

    @MainActor
    private static func testCurrentCancellationCleansCommittedSession() async throws {
        let fixture = SessionFixture()
        let video = SessionGate()
        fixture.videoGates["A"] = video
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("video:A")
        attempt.task.cancel()
        video.release()
        await expectCancellation(attempt.task)
        precondition(fixture.installedName == nil, "Cancelled video startup must not leave a committed session")
        fixture.expectOrder("enabled:A", "disable:A", "disabled:A")
    }

    @MainActor
    private static func testCancelledTaskCannotStartPreparation() async throws {
        let fixture = SessionFixture()
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        attempt.task.cancel()
        await expectCancellation(attempt.task)
        precondition(!fixture.events.contains("prepare:A"))
        precondition(fixture.committedNames.isEmpty)
    }

    @MainActor
    private static func testHIDEnableFailureStaysOwnedUntilDisconnect() async throws {
        let fixture = SessionFixture()
        fixture.enableFailures.insert("A")
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        precondition(fixture.reportedErrors == ["HID connect"])
        await fixture.coordinator.disconnect().value
        precondition(fixture.events.contains("disabled:A"))
    }

    @MainActor
    private static func testCancelledSessionReportsFailedCleanup() async throws {
        let fixture = SessionFixture()
        let video = SessionGate()
        fixture.videoGates["A"] = video
        fixture.disableFailures.insert("A")
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("video:A")
        attempt.task.cancel()
        video.release()
        await expectCancellation(attempt.task)
        precondition(fixture.installedName == nil)
        precondition(fixture.reportedErrors == ["HID disconnect"], "Failed cancellation cleanup must be reported")
        fixture.disableFailures.remove("A")
        _ = try await fixture.coordinator.startConnection(to: fixture.device("B")).task.value
        fixture.expectOrder("disabled:A", "commit:B", "enable:B")
    }

    private static func expectCancellation(_ task: Task<KVMDevice, Error>) async {
        do { _ = try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        catch { preconditionFailure("Cancellation became \(error)") }
    }
}

private enum SessionFixtureError: Error { case authentication, video, disable, enable }

@MainActor
private final class SessionGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class SessionFixture {
    var events: [String] = []
    var committedNames: [String] = []
    var installedName: String?
    var invalidationCount = 0
    var reportedErrors: [String] = []
    var preparationGates: [String: SessionGate] = [:]
    var preparationErrors: [String: Error] = [:]
    var enableGates: [String: SessionGate] = [:]
    var enableFailures: Set<String> = []
    var disableGates: [String: SessionGate] = [:]
    var disableFailures: Set<String> = []
    var videoGates: [String: SessionGate] = [:]
    var videoFailures: Set<String> = []
    var nextDrainGate: SessionGate?
    private var drainCount = 0
    private var clientNames: [ObjectIdentifier: String] = [:]
    private var eventWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    lazy var coordinator = SessionConnectionCoordinator(dependencies: .init(
        prepare: { [unowned self] device, _ in
            record("prepare:\(device.name)")
            await preparationGates[device.name]?.wait()
            if let error = preparationErrors[device.name] { throw error }
            let client = try GLKVMClient(device: device)
            clientNames[ObjectIdentifier(client)] = device.name
            record("prepared:\(device.name)")
            return PreparedKVMConnection(device: device, client: client)
        },
        commit: { [unowned self] prepared in
            committedNames.append(prepared.device.name)
            record("commit:\(prepared.device.name)")
            return prepared.device
        },
        invalidateSession: { [unowned self] in
            installedName = nil
            invalidationCount += 1
            record("invalidate")
        },
        drainSession: { [unowned self] in
            drainCount += 1
            let count = drainCount
            let gate = nextDrainGate
            nextDrainGate = nil
            record("drain:\(count)")
            await gate?.wait()
            record("drained:\(count)")
        },
        installInput: { [unowned self] client in
            installedName = clientNames[ObjectIdentifier(client)]
            record("input:\(installedName!)")
        },
        setHIDConnected: { [unowned self] client, enabled in
            precondition(!Task.isCancelled, "Already sent HID work must settle outside the cancelled attempt")
            let name = clientNames[ObjectIdentifier(client)]!
            record("\(enabled ? "enable" : "disable"):\(name)")
            await (enabled ? enableGates[name] : disableGates[name])?.wait()
            if enabled, enableFailures.contains(name) { throw SessionFixtureError.enable }
            if !enabled, disableFailures.contains(name) { throw SessionFixtureError.disable }
            record("\(enabled ? "enabled" : "disabled"):\(name)")
        },
        connectVideo: { [unowned self] device in
            record("video:\(device.name)")
            await videoGates[device.name]?.wait()
            if videoFailures.contains(device.name) { throw SessionFixtureError.video }
            record("video-ready:\(device.name)")
        },
        setConnectionTransitioning: { [unowned self] value in record("transition:\(value)") },
        reportTransportError: { [unowned self] phase, _ in reportedErrors.append(phase) }
    ))

    func device(_ name: String, host: String? = nil) -> KVMDevice {
        KVMDevice(id: name, name: name, host: host ?? "\(name).invalid", port: 443,
                  type: .glinetComet, authToken: "", capabilities: [.videoStreaming, .keyboardInput])
    }

    func record(_ event: String) {
        events.append(event)
        let waiters = eventWaiters.removeValue(forKey: event) ?? []
        waiters.forEach { $0.resume() }
    }

    func waitFor(_ event: String) async {
        guard !events.contains(event) else { return }
        await withCheckedContinuation { eventWaiters[event, default: []].append($0) }
    }

    func expectOrder(_ expected: String...) {
        let indices = expected.map { event in
            guard let index = events.firstIndex(of: event) else { preconditionFailure("Missing \(event): \(events)") }
            return index
        }
        precondition(zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 }, "Wrong order: \(events)")
    }
}
