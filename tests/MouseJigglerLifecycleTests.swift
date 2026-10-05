import Foundation
import Combine

@main
struct MouseJigglerLifecycleTests {
    @MainActor static func main() async throws {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("firmware jiggler migrates to local micro intent", testMigration),
            ("micro enable never enables firmware", testMicroEnable),
            ("daemon and config are independently confirmed", testIndependentFirmwareStates),
            ("malformed daemon state fails closed", testMalformedDaemon),
            ("daemon readback mismatch fails closed", testDaemonReadbackMismatch),
            ("config readback mismatch fails closed", testConfigReadbackMismatch),
            ("local intent survives app relaunch per endpoint", testPreferenceRelaunch),
            ("stored local off overrides old firmware intent", testPreferenceOffMigration),
            ("failed safety confirmation retains explicit local off", testFailedDisablePreference),
            ("refresh supersedes in-flight local activation", testRefreshSupersedesActivation),
            ("enabled jiggler resumes only after remote drain", testRestoreAfterDrain),
            ("previously disabled jiggler stays disabled", testPriorOff),
            ("failed disable recovers in Manual", testFailedDisable),
            ("manual toggle supersedes pending restoration", testManualSupersession),
            ("manual toggle supersedes a sent restore", testManualSupersessionAfterPost),
            ("Headless interrupts restoration safely", testReheadless),
            ("Headless interrupts delayed readback safely", testReheadlessDuringReadback),
            ("Headless cancellation repairs sent firmware write", testCancelledRestoreInHeadless),
            ("control store cancellation repairs sent firmware write", testStoreCancellation),
            ("failed transition uses shared drain and capture hook", testFailedTransitionHook),
            ("restore failure is visible and can recover", testRestoreFailure),
            ("locked restore retains its pending intent", testLockedRestore),
            ("disconnect invalidates restoration", testDisconnect),
            ("stale refresh cannot publish old configuration", testStaleRefresh),
            ("cancelled refresh preserves confirmed state", testCancelledRefresh),
            ("newest refresh owns success and cleanup", testRefreshOwnership),
            ("transient refresh retries are bounded", testTransientRefresh),
            ("authentication rejection is never retried", testAuthenticationFailure),
            ("unsupported firmware is never retried or enabled", testUnsupported),
            ("replacement session never inherits restoration", testReplacementSession),
            ("disconnected state rejects jiggler writes", testDisconnectedState),
            ("cancelled retry backoff preserves state", testCancelledRetryBackoff),
        ]
        var failures: [String] = []
        for (name, test) in tests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)") }
        }
        if JigglerURLProtocol.anyFirmwareTrueWrite { failures.append("A lifecycle scenario sent firmware true") }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        guard failures.isEmpty else { throw TestFailure.message("\(failures.count) lifecycle regressions") }
        print("MouseJigglerLifecycleTests: \(tests.count) scenarios passed; URLProtocol only, no KVM or persisted state")
    }

    @MainActor private static func setup(enabled: Bool = true, supported: Bool = true) async throws -> (KVMDeviceManager, JigglerFixture) {
        let fixture = JigglerFixture(enabled: enabled, supported: supported)
        return (try await setup(fixture: fixture), fixture)
    }

    @MainActor private static func setup(fixture: JigglerFixture, preference: MicroJigglerPreference = .disabled) async throws -> KVMDeviceManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JigglerURLProtocol.self]
        let client = try GLKVMClient(host: fixture.host, authToken: "fixture-only", allowInsecureTLS: false, sessionConfiguration: configuration)
        let device = KVMDevice(id: fixture.host, name: "Synthetic KVM", host: fixture.host, port: 80, type: .custom, authToken: "", capabilities: [])
        let manager = KVMDeviceManager(startsServices: false, persistsConnections: false, microJigglerPreference: preference)
        manager.commitConnection(PreparedKVMConnection(device: device, client: client))
        try await eventually { manager.mouseJigglerSupported != nil }
        return manager
    }

    @MainActor private static func testMigration() async throws {
        let (manager, fixture) = try await setup()
        try expect(manager.mouseJigglerEnabled == true, "Existing enabled intent was lost")
        try expect(!fixture.enabled && !fixture.daemonEnabled, "Large firmware jiggler was not disabled")
        try expect(fixture.posts == [false] && fixture.daemonPosts == [false], "Migration did not disable both actual daemon and config")
    }

    @MainActor private static func testMicroEnable() async throws {
        let (manager, fixture) = try await setup(enabled: false)
        try await manager.setMouseJigglerEnabled(true)
        try expect(manager.mouseJigglerEnabled == true, "Confirmed micro intent was not published")
        try expect(!fixture.enabled && !fixture.daemonEnabled, "Micro enable activated large firmware jiggler")
        try expect(fixture.posts == [false] && fixture.daemonPosts == [false], "Micro enable must only send firmware false")
    }

    @MainActor private static func testIndependentFirmwareStates() async throws {
        for configEnabled in [false, true] {
            let fixture = JigglerFixture(enabled: configEnabled, supported: true)
            fixture.simulateDaemonEnabled(!configEnabled)
            let manager = try await setup(fixture: fixture)
            try expect(manager.mouseJigglerEnabled == true, "Separate enabled firmware intent was not adopted")
            try expect(!fixture.enabled && !fixture.daemonEnabled, "Config/daemon disagreed after migration")
            try expect(fixture.posts.allSatisfy { !$0 } && fixture.daemonPosts.allSatisfy { !$0 }, "Firmware true was sent")
            manager.disconnectFromDevice()
        }
    }

    @MainActor private static func testMalformedDaemon() async throws {
        let (manager, fixture) = try await setup(enabled: false)
        for payload in [#"{"ok":true,"result":{}}"#, #"{"ok":true,"result":{"jiggler":{"active":"false"}}}"#,
                        #"{"ok":true,"result":{"jiggler":{"active":0}}}"#, #"{"ok":true,"result":{"jiggler":{"active":null}}}"#] {
            fixture.setDaemonPayload(payload)
            do { try await manager.setMouseJigglerEnabled(true); throw TestFailure.message("Invalid HID granted micro enable") }
            catch GLKVMClient.ClientError.decodingFailed {}
            try expect(manager.mouseJigglerEnabled != true && manager.mouseJigglerErrorMessage != nil, "Malformed HID did not stop movement")
        }
        try expect(fixture.posts.isEmpty && fixture.daemonPosts.isEmpty, "Malformed HID emitted a firmware write")
    }

    @MainActor private static func testDaemonReadbackMismatch() async throws {
        let (manager, fixture) = try await setup(enabled: false)
        fixture.ignoreDaemonDisable = true
        fixture.simulateDaemonEnabled(true)
        do { try await manager.setMouseJigglerEnabled(true); throw TestFailure.message("Active daemon allowed micro enable") }
        catch MouseJigglerError.readbackMismatch {}
        try expect(manager.mouseJigglerEnabled != true && fixture.daemonPosts == [false], "Daemon mismatch was hidden")
    }

    @MainActor private static func testConfigReadbackMismatch() async throws {
        let (manager, fixture) = try await setup(enabled: false)
        fixture.ignoreConfigDisable = true
        fixture.simulateFirmwareEnabled(true)
        do { try await manager.setMouseJigglerEnabled(true); throw TestFailure.message("Enabled config allowed micro enable") }
        catch MouseJigglerError.readbackMismatch {}
        try expect(manager.mouseJigglerEnabled != true && fixture.posts == [false], "Config mismatch was hidden")
    }

    @MainActor private static func testPreferenceRelaunch() async throws {
        let memory = MemoryMicroPreference()
        let fixture = JigglerFixture(enabled: false, supported: true)
        let first = try await setup(fixture: fixture, preference: memory.dependencies)
        try await first.setMouseJigglerEnabled(true)
        first.disconnectFromDevice()
        let second = try await setup(fixture: fixture, preference: memory.dependencies)
        try expect(second.mouseJigglerEnabled == true && !fixture.enabled && !fixture.daemonEnabled, "Relaunch did not restore only local intent")
        let other = JigglerFixture(enabled: false, supported: true)
        let unrelated = try await setup(fixture: other, preference: memory.dependencies)
        try expect(unrelated.mouseJigglerEnabled == false, "Preference crossed endpoints")
        try await second.setMouseJigglerEnabled(false)
        second.disconnectFromDevice()
        let third = try await setup(fixture: fixture, preference: memory.dependencies)
        try expect(third.mouseJigglerEnabled == false, "Explicit local off was not retained")
    }

    @MainActor private static func testPreferenceOffMigration() async throws {
        let memory = MemoryMicroPreference()
        let fixture = JigglerFixture(enabled: true, supported: true)
        memory.values[MicroJigglerPreference.endpointKey(host: fixture.host, port: 80)] = false
        let manager = try await setup(fixture: fixture, preference: memory.dependencies)
        try expect(manager.mouseJigglerEnabled == false && !fixture.enabled && !fixture.daemonEnabled, "Legacy firmware overrode explicit local off")
    }

    @MainActor private static func testFailedDisablePreference() async throws {
        let memory = MemoryMicroPreference()
        let fixture = JigglerFixture(enabled: false, supported: true)
        let manager = try await setup(fixture: fixture, preference: memory.dependencies)
        try await manager.setMouseJigglerEnabled(true)
        fixture.setDaemonPayload(#"{"ok":true,"result":{}}"#)
        do { try await manager.setMouseJigglerEnabled(false); throw TestFailure.message("Missing daemon confirmation succeeded") }
        catch GLKVMClient.ClientError.decodingFailed {}
        manager.disconnectFromDevice()
        fixture.setDaemonPayload(nil)
        let relaunched = try await setup(fixture: fixture, preference: memory.dependencies)
        try expect(relaunched.mouseJigglerEnabled == false, "Failed confirmation erased explicit local off intent")
    }

    @MainActor private static func testRefreshSupersedesActivation() async throws {
        let (manager, fixture) = try await setup(enabled: false)
        fixture.holdNextPost()
        let enabling = Task { try await manager.setMouseJigglerEnabled(true) }
        try await eventually { fixture.hasHeldRequest }
        fixture.holdNextGet()
        let refresh = Task { await manager.refreshMouseJigglerState() }
        await spin()
        fixture.releaseHeldRequests()
        do { try await enabling.value; throw TestFailure.message("Obsolete activation was published") }
        catch is CancellationError {}
        try await eventually { fixture.hasHeldRequest }
        try expect(manager.mouseJigglerEnabled != true, "Activation resumed before new firmware confirmation")
        fixture.releaseHeldRequests()
        await refresh.value
        try expect(manager.mouseJigglerEnabled == true && !fixture.enabled && !fixture.daemonEnabled, "Latest refresh did not restore local intent safely")
    }

    @MainActor private static func enterHeadless(_ manager: KVMDeviceManager) async throws {
        let owner = manager.beginHeadlessConfigurationTransition()
        defer { manager.endHeadlessConfigurationTransition(owner) }
        try expect(manager.mouseJigglerEnabled == false, "Transition must synchronously stop local movement")
        try await manager.pauseMouseJigglerForHeadless()
        manager.setHeadlessModeActive(true)
    }

    @MainActor private static func testRestoreAfterDrain() async throws {
        let (manager, fixture) = try await setup()
        let store = ControlModeStore(defaults: nil)
        let modeBinding = store.$mode.sink { manager.setHeadlessModeActive($0 == .codexHeadless) }
        defer { modeBinding.cancel() }
        let drain = RemoteMutationGate()
        let blocker = TestBarrier()
        let mutation = Task { try await drain.perform { await blocker.wait() } }
        try await eventually { drain.isBusy }
        var captures: [Bool] = []
        store.configureInputCapture({ captures.append($0) }, waitForRemoteMutations: {
            await drain.waitUntilIdle()
        }, didResumeManualCapture: {
            try? await manager.resumeMouseJigglerAfterHeadless()
        })
        let owner = manager.beginHeadlessConfigurationTransition()
        try await manager.pauseMouseJigglerForHeadless()
        store.setMode(.codexHeadless)
        manager.endHeadlessConfigurationTransition(owner)
        try expect(!fixture.enabled && manager.mouseJigglerEnabled == false, "Headless must confirm off")
        store.setMode(.manual)
        await spin()
        try expect(fixture.posts == [false, false] && captures == [true, false], "Restore and capture must wait for real drain")
        fixture.holdNextPost()
        await blocker.release()
        _ = try await mutation.value
        try await eventually { fixture.hasHeldRequest }
        try expect(captures == [true, false, true], "Firmware restore delayed Manual capture after drain")
        fixture.releaseHeldRequests()
        try await eventually { manager.mouseJigglerEnabled == true }
        try expect(fixture.posts == [false, false, false] && fixture.daemonPosts == [false, false, false] && manager.mouseJigglerEnabled == true, "Enabled state was not restored")
    }

    @MainActor private static func testPriorOff() async throws {
        let (manager, fixture) = try await setup(enabled: false)
        try await enterHeadless(manager)
        manager.setHeadlessModeActive(false)
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(!fixture.enabled && !fixture.posts.contains(true), "Prior off was enabled")
    }

    @MainActor private static func testFailedDisable() async throws {
        let (manager, fixture) = try await setup()
        fixture.failNextPostAfterApplying()
        let owner = manager.beginHeadlessConfigurationTransition()
        do { try await manager.pauseMouseJigglerForHeadless(); throw TestFailure.message("Rejected disable unexpectedly succeeded") }
        catch is TestFailure { throw TestFailure.message("Rejected disable unexpectedly succeeded") }
        catch { }
        manager.endHeadlessConfigurationTransition(owner)
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(!fixture.enabled && !fixture.daemonEnabled && manager.mouseJigglerEnabled == true, "Manual failure recovery lost prior enabled state")
    }

    @MainActor private static func testManualSupersession() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        manager.setHeadlessModeActive(false)
        fixture.holdNextGet()
        let restore = Task { try await manager.resumeMouseJigglerAfterHeadless() }
        try await eventually { fixture.hasHeldRequest }
        let manual = Task { try await manager.setMouseJigglerEnabled(false) }
        await spin()
        fixture.releaseHeldRequests()
        _ = try? await restore.value
        try await manual.value
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(!fixture.enabled && !fixture.posts.contains(true), "Newer Manual choice was overwritten")
    }

    @MainActor private static func testReheadless() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        manager.setHeadlessModeActive(false)
        fixture.holdNextPost()
        let restore = Task { try await manager.resumeMouseJigglerAfterHeadless() }
        try await eventually { fixture.hasHeldRequest }
        manager.setHeadlessModeActive(true)
        fixture.releaseHeldRequests()
        _ = try? await restore.value
        try expect(!fixture.enabled, "Interrupted restore left firmware enabled in Headless")
        try expect(manager.mouseJigglerEnabled != true, "Interrupted restore published enabled in Headless")
    }

    @MainActor private static func testManualSupersessionAfterPost() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        manager.setHeadlessModeActive(false)
        fixture.holdNextPost()
        let restore = Task { try await manager.resumeMouseJigglerAfterHeadless() }
        try await eventually { fixture.hasHeldRequest }
        let manual = Task { try await manager.setMouseJigglerEnabled(false) }
        await spin()
        fixture.releaseHeldRequests()
        _ = try? await restore.value
        try await manual.value
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(!fixture.enabled && fixture.posts == [false, false, false, false], "Sent restore overrode newer Manual toggle")
    }

    @MainActor private static func testDisconnect() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        manager.setHeadlessModeActive(false)
        fixture.holdNextGet()
        let restore = Task { try await manager.resumeMouseJigglerAfterHeadless() }
        try await eventually { fixture.hasHeldRequest }
        manager.disconnectFromDevice()
        fixture.releaseHeldRequests()
        _ = try? await restore.value
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(fixture.posts == [false, false] && manager.mouseJigglerEnabled == nil, "Disconnected session was restored")
    }

    @MainActor private static func testReheadlessDuringReadback() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        manager.setHeadlessModeActive(false)
        fixture.holdGet(number: fixture.getCount + 2)
        let restore = Task { try await manager.resumeMouseJigglerAfterHeadless() }
        try await eventually { fixture.hasHeldRequest }
        manager.setHeadlessModeActive(true)
        fixture.releaseHeldRequests()
        _ = try? await restore.value
        try expect(!fixture.enabled && manager.mouseJigglerEnabled == false, "Delayed readback left Headless enabled")
    }

    @MainActor private static func testCancelledRestoreInHeadless() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        manager.setHeadlessModeActive(false)
        fixture.holdNextPost()
        let restore = Task { try await manager.resumeMouseJigglerAfterHeadless() }
        try await eventually { fixture.hasHeldRequest }
        manager.setHeadlessModeActive(true)
        restore.cancel()
        _ = try? await restore.value
        fixture.releaseHeldRequests()
        try expect(!fixture.enabled && manager.mouseJigglerEnabled == false, "Cancellation left sent enable active")
    }

    @MainActor private static func testRestoreFailure() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        manager.setHeadlessModeActive(false)
        fixture.failNextPostAfterApplying()
        do { try await manager.resumeMouseJigglerAfterHeadless(); throw TestFailure.message("Rejected restore succeeded") }
        catch is TestFailure { throw TestFailure.message("Rejected restore succeeded") }
        catch { }
        try expect(manager.mouseJigglerErrorMessage != nil, "Restore failure was hidden")
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(!fixture.enabled && !fixture.daemonEnabled && manager.mouseJigglerEnabled == true && manager.mouseJigglerErrorMessage == nil, "Restore could not recover")
    }

    @MainActor private static func testStoreCancellation() async throws {
        let (manager, fixture) = try await setup()
        let store = ControlModeStore(defaults: nil)
        let binding = store.$mode.sink { manager.setHeadlessModeActive($0 == .codexHeadless) }
        defer { binding.cancel() }
        var captures: [Bool] = []
        store.configureInputCapture({ captures.append($0) }, didResumeManualCapture: {
            try? await manager.resumeMouseJigglerAfterHeadless()
        })
        let owner = manager.beginHeadlessConfigurationTransition()
        try await manager.pauseMouseJigglerForHeadless()
        store.setMode(.codexHeadless)
        manager.endHeadlessConfigurationTransition(owner)
        fixture.holdNextPost()
        store.setMode(.manual)
        try await eventually { fixture.hasHeldRequest }
        store.setMode(.codexHeadless)
        try await eventually { !fixture.enabled && !manager.isMouseJigglerUpdating }
        fixture.releaseHeldRequests()
        try expect(captures == [true, false, true, false], "Cancelled Manual task resumed local capture")
        try expect(manager.mouseJigglerEnabled == false, "Store cancellation did not confirm safe firmware state")
    }

    @MainActor private static func testFailedTransitionHook() async throws {
        let (manager, fixture) = try await setup()
        let store = ControlModeStore(defaults: nil)
        let drain = RemoteMutationGate()
        let blocker = TestBarrier()
        let mutation = Task { try await drain.perform { await blocker.wait() } }
        try await eventually { drain.isBusy }
        var captures: [Bool] = []
        store.configureInputCapture({ captures.append($0) }, waitForRemoteMutations: {
            await drain.waitUntilIdle()
        }, didResumeManualCapture: {
            try? await manager.resumeMouseJigglerAfterHeadless()
        })
        let owner = manager.beginHeadlessConfigurationTransition()
        try await manager.pauseMouseJigglerForHeadless()
        manager.endHeadlessConfigurationTransition(owner)
        store.resumeManualCaptureIfNeeded()
        await spin()
        try expect(fixture.posts == [false, false] && captures == [true], "Failed-transition recovery bypassed drain")
        await blocker.release()
        _ = try await mutation.value
        try await eventually { manager.mouseJigglerEnabled == true }
        try expect(captures == [true, true], "Failure hook delayed Manual capture")
        try expect(manager.mouseJigglerEnabled == true && !fixture.enabled, "Shared failure hook did not restore previous state")
    }

    @MainActor private static func testLockedRestore() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(fixture.posts == [false, false], "Locked restore sent enable")
        do { try await manager.setMouseJigglerEnabled(true); throw TestFailure.message("Locked Manual toggle succeeded") }
        catch is TestFailure { throw TestFailure.message("Locked Manual toggle succeeded") }
        catch { }
        manager.setHeadlessModeActive(false)
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(manager.mouseJigglerEnabled == true && !fixture.enabled, "Locked request erased prior true intent")
    }

    @MainActor private static func testRefreshOwnership() async throws {
        let (manager, fixture) = try await setup()
        try await manager.setMouseJigglerEnabled(false)
        fixture.simulateFirmwareEnabled(true)
        fixture.holdNextGet()
        let old = Task { await manager.refreshMouseJigglerState() }
        try await eventually { fixture.hasHeldRequest }
        fixture.simulateFirmwareEnabled(false)
        fixture.holdNextGet()
        let newest = Task { await manager.refreshMouseJigglerState() }
        await spin()
        fixture.releaseHeldRequests()
        await old.value
        try await eventually { fixture.hasHeldRequest }
        try expect(manager.mouseJigglerEnabled == false, "Old owner published stale success")
        fixture.releaseHeldRequests()
        await newest.value
        try expect(manager.mouseJigglerEnabled == false, "Old cleanup invalidated newer refresh")
    }

    @MainActor private static func testStaleRefresh() async throws {
        let (manager, fixture) = try await setup()
        try await manager.setMouseJigglerEnabled(false)
        fixture.simulateFirmwareEnabled(true)
        fixture.holdNextGet()
        let refresh = Task { await manager.refreshMouseJigglerState() }
        try await eventually { fixture.hasHeldRequest }
        fixture.holdNextPost()
        let manual = Task { try await manager.setMouseJigglerEnabled(false) }
        await spin()
        fixture.releaseHeldRequests()
        await refresh.value
        try await eventually { fixture.hasHeldRequest }
        try expect(manager.mouseJigglerEnabled != true, "Stale refresh published superseded configuration")
        fixture.releaseHeldRequests()
        try await manual.value
        try expect(manager.mouseJigglerEnabled == false, "New state lost")
    }

    @MainActor private static func testCancelledRefresh() async throws {
        let (manager, fixture) = try await setup()
        fixture.holdNextGet()
        let refresh = Task { await manager.refreshMouseJigglerState() }
        try await eventually { fixture.hasHeldRequest }
        refresh.cancel()
        await refresh.value
        fixture.releaseHeldRequests()
        try expect(manager.mouseJigglerEnabled == false, "Cancelled refresh must leave local movement stopped")
    }

    @MainActor private static func testTransientRefresh() async throws {
        let (manager, fixture) = try await setup()
        fixture.failNextGets(count: 2, status: nil)
        let before = fixture.getCount
        await manager.refreshMouseJigglerState()
        try expect(fixture.getCount - before == 3 && manager.mouseJigglerEnabled == true, "Transient failures were not retried")
        fixture.failNextGets(count: 4, status: nil)
        let boundedBefore = fixture.getCount
        await manager.refreshMouseJigglerState()
        try expect(fixture.getCount - boundedBefore == 3 && manager.mouseJigglerEnabled == nil, "Retries exceeded three or did not expose unavailable state")
    }

    @MainActor private static func testAuthenticationFailure() async throws {
        let (manager, fixture) = try await setup()
        fixture.failNextGets(count: 3, status: 401)
        let before = fixture.getCount
        await manager.refreshMouseJigglerState()
        try expect(fixture.getCount - before == 1, "Authentication failure was retried")
    }

    @MainActor private static func testUnsupported() async throws {
        let (manager, fixture) = try await setup(supported: false)
        try expect(manager.mouseJigglerSupported == false && manager.mouseJigglerEnabled == nil, "Unsupported firmware was misrepresented")
        let owner = manager.beginHeadlessConfigurationTransition()
        try await manager.pauseMouseJigglerForHeadless()
        manager.setHeadlessModeActive(true)
        manager.endHeadlessConfigurationTransition(owner)
        manager.setHeadlessModeActive(false)
        try await manager.resumeMouseJigglerAfterHeadless()
        do { try await manager.setMouseJigglerEnabled(true); throw TestFailure.message("Unsupported firmware granted micro activation") }
        catch MouseJigglerError.unavailable {}
        try expect(fixture.posts.isEmpty && fixture.daemonPosts.isEmpty, "Unsupported firmware received a configuration write")
    }

    @MainActor private static func testReplacementSession() async throws {
        let (manager, first) = try await setup()
        try await enterHeadless(manager)
        let (replacement, second) = try await setup(enabled: false)
        manager.commitConnection(PreparedKVMConnection(device: replacement.connectedDevice!, client: replacement.glkvmClient!))
        manager.setHeadlessModeActive(false)
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(first.posts == [false, false] && second.posts.isEmpty, "Restoration crossed session boundary")
    }

    @MainActor private static func testDisconnectedState() async throws {
        let manager = KVMDeviceManager(startsServices: false, persistsConnections: false)
        await manager.refreshMouseJigglerState()
        try await manager.resumeMouseJigglerAfterHeadless()
        do { try await manager.setMouseJigglerEnabled(true); throw TestFailure.message("Disconnected write succeeded") }
        catch is TestFailure { throw TestFailure.message("Disconnected write succeeded") }
        catch { }
        try expect(manager.mouseJigglerEnabled == nil && manager.mouseJigglerSupported == nil, "Disconnected state was available")
    }

    @MainActor private static func testCancelledRetryBackoff() async throws {
        let (manager, fixture) = try await setup()
        fixture.failNextGets(count: 3, status: nil)
        let before = fixture.getCount
        let refresh = Task { await manager.refreshMouseJigglerState() }
        try await eventually { fixture.getCount > before }
        refresh.cancel()
        await refresh.value
        try expect(fixture.getCount - before == 1 && manager.mouseJigglerEnabled == false, "Cancelled backoff must leave local movement stopped")
    }

    @MainActor private static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw TestFailure.message("Timed out awaiting in-process fixture")
    }
    private static func spin() async { for _ in 0..<20 { await Task.yield() } }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure.message(message) }
    }
}

private enum TestFailure: Error { case message(String) }
private actor TestBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; let current = waiters; waiters = []; current.forEach { $0.resume() } }
}

private final class MemoryMicroPreference {
    var values: [String: Bool] = [:]
    var dependencies: MicroJigglerPreference {
        MicroJigglerPreference(read: { self.values[$0] }, write: { self.values[$1] = $0 })
    }
}

private final class JigglerFixture: @unchecked Sendable {
    let host = "jiggler-\(UUID().uuidString.lowercased()).invalid"
    private let lock = NSLock()
    private var currentEnabled: Bool
    private var daemonActive: Bool
    private var daemonWrites: [Bool] = []
    private var daemonPayload: String?
    var ignoreDaemonDisable = false
    var ignoreConfigDisable = false
    private let supported: Bool
    private var writes: [Bool] = []
    private var gets = 0
    private var held: [() -> Void] = []
    private var holdGet = false
    private var holdGetNumber: Int?
    private var holdPost = false
    private var rejectPost = false
    private var remainingFailures = 0
    private var failureStatus: Int?
    init(enabled: Bool, supported: Bool) {
        currentEnabled = enabled; daemonActive = enabled; self.supported = supported
        JigglerURLProtocol.register(self)
    }
    var enabled: Bool { lock.withLock { currentEnabled } }
    var posts: [Bool] { lock.withLock { writes } }
    var daemonEnabled: Bool { lock.withLock { daemonActive } }
    var daemonPosts: [Bool] { lock.withLock { daemonWrites } }
    var getCount: Int { lock.withLock { gets } }
    var hasHeldRequest: Bool { lock.withLock { !held.isEmpty } }
    func holdNextGet() { lock.withLock { holdGet = true } }
    func holdGet(number: Int) { lock.withLock { holdGetNumber = number } }
    func simulateFirmwareEnabled(_ enabled: Bool) { lock.withLock { currentEnabled = enabled } }
    func simulateDaemonEnabled(_ enabled: Bool) { lock.withLock { daemonActive = enabled } }
    func setDaemonPayload(_ payload: String?) { lock.withLock { daemonPayload = payload } }
    func holdNextPost() { lock.withLock { holdPost = true } }
    func failNextPostAfterApplying() { lock.withLock { rejectPost = true } }
    func failNextGets(count: Int, status: Int?) { lock.withLock { remainingFailures = count; failureStatus = status } }
    func releaseHeldRequests() {
        let callbacks = lock.withLock { let callbacks = held; held = []; return callbacks }
        callbacks.forEach { $0() }
    }
    func handle(_ request: URLRequest, reply: @escaping (Int?, String?) -> Void) {
        let body = Self.bodyData(request)
        let callback: (() -> Void)? = lock.withLock {
            if request.url?.path == "/api/hid" {
                let payload = daemonPayload ?? "{\"ok\":true,\"result\":{\"jiggler\":{\"enabled\":true,\"active\":\(daemonActive),\"interval\":60,\"schedule\":[]}}}"
                return { reply(200, payload) }
            }
            if request.url?.path == "/api/hid/set_params" {
                let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "jiggler" })?.value
                guard value == "false" || value == "true" else { return { reply(400, #"{"ok":false}"#) } }
                if !ignoreDaemonDisable { daemonActive = value == "true" }; daemonWrites.append(value == "true")
                return { reply(200, #"{"ok":true,"result":{}}"#) }
            }
            let isPost = request.httpMethod == "POST"
            if isPost {
                guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let enabled = object["mouse_jiggle"] as? Bool else {
                    return { reply(400, #"{"ok":false}"#) }
                }
                if !ignoreConfigDisable { currentEnabled = enabled }; writes.append(enabled)
            } else { gets += 1 }
            let shouldHold = isPost ? holdPost : (holdGet || holdGetNumber == gets)
            if isPost { holdPost = false } else { holdGet = false }
            let failedPost = isPost && rejectPost
            if isPost { rejectPost = false }
            let failedGet = !isPost && remainingFailures > 0
            if failedGet { remainingFailures -= 1 }
            let status = failedGet ? failureStatus : 200
            let config = supported ? "\"mouse_jiggle\":\(currentEnabled)" : ""
            let payload = failedPost ? #"{"ok":false}"# : "{\"ok\":true,\"result\":{\"config\":{\(config)}}}"
            let callback = { reply(status, status == nil ? nil : payload) }
            if shouldHold { held.append(callback); return nil }
            return callback
        }
        callback?()
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class JigglerURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: JigglerFixture] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    static func register(_ fixture: JigglerFixture) { lock.withLock { fixtures[fixture.host] = fixture } }
    static var anyFirmwareTrueWrite: Bool {
        lock.withLock { fixtures.values.contains { $0.posts.contains(true) || $0.daemonPosts.contains(true) } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else {
            preconditionFailure("Unexpected URL: fixture cannot contact network")
        }
        fixture.handle(request) { [weak self] status, payload in
            guard let self else { return }
            self.stateLock.withLock {
                guard !self.stopped else { return }
                guard let status else { self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data((payload ?? "").utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}
