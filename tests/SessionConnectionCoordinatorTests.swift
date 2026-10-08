import Foundation

@main
struct SessionConnectionCoordinatorTests {
    @MainActor
    static func main() async throws {
        try await testSwitchDoesNotContactUnreachableOldEndpoint()
        try await testLatestAuthenticationWins()
        try await testSupersededAuthenticationCannotCommitWhileLatestWaits()
        try await testDisconnectDuringPreparation()
        try await testManualTokenLookupBelongsToAttempt()
        try await testHIDEnableSettlesBeforeSessionDrainAndReplacement()
        try await testMutationDrainPrecedesReplacement()
        try await testStaleVideoCompletionCannotChangeReplacement()
        try await testCancellationAndAuthenticationFailureRemainDistinct()
        try await testCurrentTransportFailureKeepsAPIConnection()
        try await testCurrentCancellationDrainsCommittedSession()
        try await testCancelledTaskCannotStartPreparation()
        try await testHIDEnableFailureDoesNotBlockLocalDisconnect()
        try await testDisconnectDoesNotContactUnreachableEndpoint()
        try await testRepeatedDisconnectsStayLocal()
        try await testLatestReplacementWinsWhileOldEnableSettles()
        try await testStaleEnableFailureCannotReportOrStartVideo()
        try await testCurrentCancellationWaitsForAlreadySentEnable()
        try await testDisconnectWaitsForAlreadySentEnable()
        try await testReplacementWaitsForPendingDisconnectDrain()
        try await testAuthenticationFailureCannotRestoreOldSession()
        try await testInitialDrainPrecedesFirstCommit()
        try await testVideoTransportCancellationDrainsSession()
        try await testInputDrainRecoveryLatchSurvivesReplacement()
        try await testCancelledAttemptCannotCommitAfterDrain()
        print("SessionConnectionCoordinatorTests passed (25 behavioral groups)")
    }

    @MainActor
    private static func testSwitchDoesNotContactUnreachableOldEndpoint() async throws {
        let fixture = SessionFixture()
        _ = try await fixture.coordinator.startConnection(
            to: fixture.device("old", host: "old-kvm.invalid")
        ).task.value
        fixture.unreachableHosts.insert("old-kvm.invalid")
        let replacement = fixture.coordinator.startConnection(
            to: fixture.device("new", host: "new-kvm.invalid")
        )
        precondition(fixture.installedName == nil, "Switch must invalidate the old local session synchronously")
        _ = try await replacement.task.value
        fixture.expectNoGlobalDisconnect()
        fixture.expectOrder("drained:2", "commit:new", "enable:new")
        precondition(fixture.installedName == "new")
        precondition(fixture.reportedErrors.isEmpty, "An unreachable old endpoint must not create a cleanup error")
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
        precondition(fixture.events.filter { $0 == "transition:false" }.count == 1,
                     "Stale preparation must not publish another transition completion")
        fixture.expectNoGlobalDisconnect()
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
    private static func testHIDEnableSettlesBeforeSessionDrainAndReplacement() async throws {
        let fixture = SessionFixture()
        let enableA = SessionGate()
        fixture.enableGates["A"] = enableA
        let a = fixture.coordinator.startConnection(to: fixture.device("A", host: "same.invalid"))
        await fixture.waitFor("enable:A")
        let b = fixture.coordinator.startConnection(to: fixture.device("B", host: "same.invalid"))
        await fixture.waitFor("prepared:B")
        precondition(!fixture.events.contains("drain:2"), "Old enable must settle before the input transport closes")
        precondition(!fixture.events.contains("enable:B"))
        enableA.release()
        _ = try await b.task.value
        await expectCancellation(a.task)
        fixture.expectOrder("enabled:A", "drain:2", "drained:2", "commit:B", "enable:B")
        fixture.expectNoGlobalDisconnect()
        precondition(fixture.installedName == "B")
    }

    @MainActor
    private static func testMutationDrainPrecedesReplacement() async throws {
        let fixture = SessionFixture()
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        let drain = SessionGate()
        fixture.nextDrainGate = drain
        let b = fixture.coordinator.startConnection(to: fixture.device("B"))
        await fixture.waitFor("prepared:B")
        precondition(fixture.installedName == nil, "Invalidation is synchronous")
        precondition(!fixture.events.contains("commit:B"))
        drain.release()
        _ = try await b.task.value
        fixture.expectOrder("drained:2", "commit:B", "enable:B")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testStaleVideoCompletionCannotChangeReplacement() async throws {
        let fixture = SessionFixture()
        let videoA = SessionGate()
        fixture.videoGates["A"] = videoA
        fixture.videoErrors["A"] = SessionFixtureError.video
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
        precondition(cancelled.installedName == nil)

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
        fixture.videoErrors["A"] = SessionFixtureError.video
        let result = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        precondition(result.name == "A")
        precondition(fixture.installedName == "A")
        precondition(fixture.reportedErrors == ["WebRTC"])
        let disconnect = fixture.coordinator.disconnect()
        precondition(fixture.installedName == nil)
        await disconnect.value
        fixture.expectOrder("enabled:A", "drain:2", "drained:2")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testCurrentCancellationDrainsCommittedSession() async throws {
        let fixture = SessionFixture()
        let video = SessionGate()
        fixture.videoGates["A"] = video
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("video:A")
        attempt.task.cancel()
        video.release()
        await expectCancellation(attempt.task)
        precondition(fixture.installedName == nil, "Cancelled video startup must not leave a committed session")
        fixture.expectOrder("enabled:A", "drain:2", "drained:2")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testCancelledTaskCannotStartPreparation() async throws {
        let fixture = SessionFixture()
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        attempt.task.cancel()
        await expectCancellation(attempt.task)
        precondition(!fixture.events.contains("prepare:A"))
        precondition(fixture.committedNames.isEmpty)
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testHIDEnableFailureDoesNotBlockLocalDisconnect() async throws {
        let fixture = SessionFixture()
        fixture.enableFailures.insert("A")
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        precondition(fixture.reportedErrors == ["HID connect"])
        await fixture.coordinator.disconnect().value
        precondition(fixture.installedName == nil)
        precondition(!fixture.inputBlocked, "A failed USB enable must not create an unrelated input recovery latch")
        _ = try await fixture.coordinator.startConnection(to: fixture.device("B")).task.value
        precondition(fixture.installedName == "B")
        fixture.expectOrder("drained:2", "commit:B")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testDisconnectDoesNotContactUnreachableEndpoint() async throws {
        let fixture = SessionFixture()
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        fixture.unreachableHosts.insert("A.invalid")
        let remoteBefore = fixture.remoteEvents
        let disconnect = fixture.coordinator.disconnect()
        precondition(fixture.installedName == nil)
        await disconnect.value
        precondition(fixture.remoteEvents == remoteBefore, "Disconnect must only drain the app's existing session")
        precondition(fixture.reportedErrors.isEmpty)
        precondition(!fixture.inputBlocked)
        precondition(fixture.events.last == "transition:false")
        fixture.expectOrder("drain:2", "drained:2")
    }

    @MainActor
    private static func testRepeatedDisconnectsStayLocal() async throws {
        let fixture = SessionFixture()
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        let remoteBefore = fixture.remoteEvents
        let gate = SessionGate()
        fixture.nextDrainGate = gate
        let first = fixture.coordinator.disconnect()
        await fixture.waitFor("drain:2")
        let second = fixture.coordinator.disconnect()
        let transitionCompletions = fixture.events.filter { $0 == "transition:false" }.count
        gate.release()
        await first.value
        await second.value
        precondition(fixture.events.filter { $0 == "transition:false" }.count == transitionCompletions + 1,
                     "Superseded disconnect must not finish the latest transition")
        fixture.expectOrder("drained:2", "drain:3", "drained:3")
        precondition(fixture.remoteEvents == remoteBefore)
        precondition(fixture.installedName == nil)
    }

    @MainActor
    private static func testLatestReplacementWinsWhileOldEnableSettles() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        fixture.enableGates["A"] = gate
        let a = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("enable:A")
        let b = fixture.coordinator.startConnection(to: fixture.device("B"))
        await fixture.waitFor("prepared:B")
        let c = fixture.coordinator.startConnection(to: fixture.device("C"))
        await fixture.waitFor("prepared:C")
        precondition(fixture.committedNames == ["A"])
        gate.release()
        _ = try await c.task.value
        await expectCancellation(a.task)
        await expectCancellation(b.task)
        precondition(fixture.committedNames == ["A", "C"])
        fixture.expectOrder("enabled:A", "drained:2", "drained:3", "enable:C")
        precondition(!fixture.events.contains("enable:B"))
        precondition(fixture.installedName == "C")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testStaleEnableFailureCannotReportOrStartVideo() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        fixture.enableGates["A"] = gate
        fixture.enableFailures.insert("A")
        let a = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("enable:A")
        let b = fixture.coordinator.startConnection(to: fixture.device("B"))
        await fixture.waitFor("prepared:B")
        gate.release()
        _ = try await b.task.value
        await expectCancellation(a.task)
        precondition(fixture.reportedErrors.isEmpty)
        precondition(!fixture.events.contains("video:A"))
        precondition(fixture.installedName == "B")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testCurrentCancellationWaitsForAlreadySentEnable() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        fixture.enableGates["A"] = gate
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("enable:A")
        attempt.task.cancel()
        gate.release()
        await expectCancellation(attempt.task)
        fixture.expectOrder("enabled:A", "drain:2", "drained:2")
        precondition(!fixture.events.contains("video:A"))
        precondition(fixture.installedName == nil)
        precondition(fixture.reportedErrors.isEmpty)
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testDisconnectWaitsForAlreadySentEnable() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        fixture.enableGates["A"] = gate
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("enable:A")
        let disconnect = fixture.coordinator.disconnect()
        precondition(fixture.installedName == nil)
        await Task.yield()
        precondition(!fixture.events.contains("drain:2"))
        gate.release()
        await disconnect.value
        await expectCancellation(attempt.task)
        fixture.expectOrder("enabled:A", "drain:2", "drained:2")
        precondition(!fixture.events.contains("video:A"))
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testReplacementWaitsForPendingDisconnectDrain() async throws {
        let fixture = SessionFixture()
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        let gate = SessionGate()
        fixture.nextDrainGate = gate
        let disconnect = fixture.coordinator.disconnect()
        await fixture.waitFor("drain:2")
        let enableB = SessionGate()
        fixture.enableGates["B"] = enableB
        let b = fixture.coordinator.startConnection(to: fixture.device("B"))
        await fixture.waitFor("prepared:B")
        precondition(!fixture.events.contains("commit:B"))
        gate.release()
        await disconnect.value
        precondition(fixture.coordinator.isConnecting, "Stale disconnect cannot finish the replacement's transition")
        enableB.release()
        _ = try await b.task.value
        fixture.expectOrder("drained:2", "drain:3", "drained:3", "commit:B", "enable:B")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testAuthenticationFailureCannotRestoreOldSession() async throws {
        let fixture = SessionFixture()
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        fixture.preparationErrors["B"] = SessionFixtureError.authentication
        do {
            _ = try await fixture.coordinator.startConnection(to: fixture.device("B")).task.value
            preconditionFailure("Authentication failure was ignored")
        } catch SessionFixtureError.authentication { }
        await fixture.coordinator.disconnect().value
        precondition(fixture.installedName == nil)
        precondition(fixture.committedNames == ["A"])
        precondition(!fixture.coordinator.isConnecting)
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testInitialDrainPrecedesFirstCommit() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        fixture.nextDrainGate = gate
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("prepared:A")
        precondition(fixture.committedNames.isEmpty)
        gate.release()
        _ = try await attempt.task.value
        fixture.expectOrder("drained:1", "commit:A", "input:A", "enable:A", "video:A")
    }

    @MainActor
    private static func testVideoTransportCancellationDrainsSession() async throws {
        let fixture = SessionFixture()
        fixture.videoErrors["A"] = URLError(.cancelled)
        await expectCancellation(fixture.coordinator.startConnection(to: fixture.device("A")).task)
        precondition(fixture.installedName == nil)
        precondition(fixture.reportedErrors.isEmpty, "Transport cancellation must remain cancellation")
        fixture.expectOrder("enabled:A", "drain:2", "drained:2")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testInputDrainRecoveryLatchSurvivesReplacement() async throws {
        let fixture = SessionFixture()
        _ = try await fixture.coordinator.startConnection(to: fixture.device("A")).task.value
        fixture.nextDrainBlocksInput = true
        _ = try await fixture.coordinator.startConnection(to: fixture.device("B")).task.value
        precondition(fixture.inputBlocked, "Installing the replacement must not clear an actual input-drain recovery latch")
        fixture.expectOrder("input-blocked", "commit:B", "enable:B")
        await fixture.coordinator.disconnect().value
        _ = try await fixture.coordinator.startConnection(to: fixture.device("C")).task.value
        precondition(fixture.inputBlocked, "Later local teardown must retain the input transport's recovery latch")
        precondition(fixture.installedName == "C")
        fixture.expectNoGlobalDisconnect()
    }

    @MainActor
    private static func testCancelledAttemptCannotCommitAfterDrain() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        fixture.nextDrainGate = gate
        let attempt = fixture.coordinator.startConnection(to: fixture.device("A"))
        await fixture.waitFor("prepared:A")
        attempt.task.cancel()
        gate.release()
        await expectCancellation(attempt.task)
        precondition(fixture.committedNames.isEmpty)
        precondition(fixture.installedName == nil)
        fixture.expectOrder("drained:1", "drain:2", "drained:2")
        fixture.expectNoGlobalDisconnect()
    }

    private static func expectCancellation(_ task: Task<KVMDevice, Error>) async {
        do { _ = try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        catch { preconditionFailure("Cancellation became \(error)") }
    }
}

private enum SessionFixtureError: Error { case authentication, video, enable }

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
    var inputBlocked = false
    var preparationGates: [String: SessionGate] = [:]
    var preparationErrors: [String: Error] = [:]
    var enableGates: [String: SessionGate] = [:]
    var enableFailures: Set<String> = []
    var unreachableHosts: Set<String> = []
    var videoGates: [String: SessionGate] = [:]
    var videoErrors: [String: Error] = [:]
    var nextDrainGate: SessionGate?
    var nextDrainBlocksInput = false
    private var drainCount = 0
    private var clientNames: [ObjectIdentifier: String] = [:]

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
            precondition(!Task.isCancelled, "Session drain must settle outside the cancelled attempt")
            drainCount += 1
            let count = drainCount
            let gate = nextDrainGate
            let blocksInput = nextDrainBlocksInput
            nextDrainGate = nil
            nextDrainBlocksInput = false
            record("drain:\(count)")
            await gate?.wait()
            if blocksInput {
                inputBlocked = true
                record("input-blocked")
            }
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
            await enableGates[name]?.wait()
            if unreachableHosts.contains(client.baseURL.host ?? "") { throw URLError(.cannotConnectToHost) }
            if enabled, enableFailures.contains(name) { throw SessionFixtureError.enable }
            record("\(enabled ? "enabled" : "disabled"):\(name)")
        },
        connectVideo: { [unowned self] device in
            record("video:\(device.name)")
            await videoGates[device.name]?.wait()
            if let error = videoErrors[device.name] { throw error }
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
    }

    func waitFor(_ event: String) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !events.contains(event) {
            precondition(clock.now < deadline, "Timed out waiting for \(event): \(events)")
            await Task.yield()
        }
    }

    var remoteEvents: [String] {
        events.filter { $0.hasPrefix("enable:") || $0.hasPrefix("disable:") || $0.hasPrefix("video:") }
    }

    func expectNoGlobalDisconnect() {
        precondition(!events.contains { $0.hasPrefix("disable:") }, "App-session teardown must not change global USB HID")
    }

    func expectOrder(_ expected: String...) {
        let indices = expected.map { event in
            guard let index = events.firstIndex(of: event) else { preconditionFailure("Missing \(event): \(events)") }
            return index
        }
        precondition(zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 }, "Wrong order: \(events)")
    }
}
