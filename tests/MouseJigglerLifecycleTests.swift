import Foundation
import Combine

@main
struct MouseJigglerLifecycleTests {
    @MainActor static func main() async throws {
        let tests: [(String, @MainActor () async throws -> Void)] = [
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
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        guard failures.isEmpty else { throw TestFailure.message("\(failures.count) lifecycle regressions") }
        print("MouseJigglerLifecycleTests: \(tests.count) scenarios passed; URLProtocol only, no KVM or persisted state")
    }

    @MainActor private static func setup(enabled: Bool = true, supported: Bool = true) async throws -> (KVMDeviceManager, JigglerFixture) {
        let fixture = JigglerFixture(enabled: enabled, supported: supported)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JigglerURLProtocol.self]
        let client = try GLKVMClient(host: fixture.host, authToken: "fixture-only", allowInsecureTLS: false, sessionConfiguration: configuration)
        let device = KVMDevice(id: fixture.host, name: "Synthetic KVM", host: fixture.host, port: 80, type: .custom, authToken: "", capabilities: [])
        let manager = KVMDeviceManager(startsServices: false, persistsConnections: false)
        manager.commitConnection(PreparedKVMConnection(device: device, client: client))
        try await eventually { manager.mouseJigglerSupported != nil }
        return (manager, fixture)
    }

    @MainActor private static func enterHeadless(_ manager: KVMDeviceManager) async throws {
        let owner = manager.beginHeadlessConfigurationTransition()
        defer { manager.endHeadlessConfigurationTransition(owner) }
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
        try expect(fixture.posts == [false] && captures == [true, false], "Restore and capture must wait for real drain")
        fixture.holdNextPost()
        await blocker.release()
        _ = try await mutation.value
        try await eventually { fixture.hasHeldRequest }
        try expect(captures == [true, false, true], "Firmware restore delayed Manual capture after drain")
        fixture.releaseHeldRequests()
        try await eventually { manager.mouseJigglerEnabled == true }
        try expect(fixture.posts == [false, true] && manager.mouseJigglerEnabled == true, "Enabled state was not restored")
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
        try expect(fixture.enabled && manager.mouseJigglerEnabled == true, "Manual failure recovery lost prior enabled state")
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
        try expect(!fixture.enabled && fixture.posts == [false, true, false], "Sent restore overrode newer Manual toggle")
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
        try expect(fixture.posts == [false] && manager.mouseJigglerEnabled == nil, "Disconnected session was restored")
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
        try expect(fixture.enabled && manager.mouseJigglerErrorMessage == nil, "Restore could not recover")
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
        try expect(fixture.posts == [false] && captures == [true], "Failed-transition recovery bypassed drain")
        await blocker.release()
        _ = try await mutation.value
        try await eventually { fixture.enabled }
        try expect(captures == [true, true], "Failure hook delayed Manual capture")
        try expect(fixture.enabled, "Shared failure hook did not restore previous state")
    }

    @MainActor private static func testLockedRestore() async throws {
        let (manager, fixture) = try await setup()
        try await enterHeadless(manager)
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(fixture.posts == [false], "Locked restore sent enable")
        do { try await manager.setMouseJigglerEnabled(true); throw TestFailure.message("Locked Manual toggle succeeded") }
        catch is TestFailure { throw TestFailure.message("Locked Manual toggle succeeded") }
        catch { }
        manager.setHeadlessModeActive(false)
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(fixture.enabled, "Locked request erased prior true intent")
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
        try expect(manager.mouseJigglerEnabled == true, "Cancellation erased confirmed state")
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
        try expect(fixture.posts.isEmpty, "Unsupported firmware received a configuration write")
    }

    @MainActor private static func testReplacementSession() async throws {
        let (manager, first) = try await setup()
        try await enterHeadless(manager)
        let (replacement, second) = try await setup(enabled: false)
        manager.commitConnection(PreparedKVMConnection(device: replacement.connectedDevice!, client: replacement.glkvmClient!))
        manager.setHeadlessModeActive(false)
        try await manager.resumeMouseJigglerAfterHeadless()
        try expect(first.posts == [false] && second.posts.isEmpty, "Restoration crossed session boundary")
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
        try expect(fixture.getCount - before == 1 && manager.mouseJigglerEnabled == true, "Cancelled backoff retried or erased state")
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

private final class JigglerFixture: @unchecked Sendable {
    let host = "jiggler-\(UUID().uuidString.lowercased()).invalid"
    private let lock = NSLock()
    private var currentEnabled: Bool
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
        currentEnabled = enabled; self.supported = supported
        JigglerURLProtocol.register(self)
    }
    var enabled: Bool { lock.withLock { currentEnabled } }
    var posts: [Bool] { lock.withLock { writes } }
    var getCount: Int { lock.withLock { gets } }
    var hasHeldRequest: Bool { lock.withLock { !held.isEmpty } }
    func holdNextGet() { lock.withLock { holdGet = true } }
    func holdGet(number: Int) { lock.withLock { holdGetNumber = number } }
    func simulateFirmwareEnabled(_ enabled: Bool) { lock.withLock { currentEnabled = enabled } }
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
            let isPost = request.httpMethod == "POST"
            if isPost {
                guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let enabled = object["mouse_jiggle"] as? Bool else {
                    return { reply(400, #"{"ok":false}"#) }
                }
                currentEnabled = enabled; writes.append(enabled)
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
