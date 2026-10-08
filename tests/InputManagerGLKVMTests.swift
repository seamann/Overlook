import AppKit
import Darwin
import Foundation

@main
struct InputManagerGLKVMTests {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try await testInputRecoveryPersistsAcrossManagers()
            try await testInputRecoveryRestoresConservativeStoredFlags()
            try await testRejectedInputRecoveryKeepsPersistedBlock()
            try await testAuthorizedInputRecoveryClearsPersistedBlock()
            for revocation in PasteRevocation.allCases {
                try await testPasteRechecksAuthorityAfterConfiguration(revocation)
            }
            try await testToolbarPasteRejectsRevokedCaptureGeneration()
            try await testFailedPasteKeepsManualRecoveryAuthority()
            try await testSessionDisconnectDrainsDispatchedPrint()
            try await testExplicitUnconfirmedSessionBlocksWithoutRecoveryTransport()
            try await testPendingHTTPPrintsRequireFreshManualReview(failPrint: false)
            try await testPendingHTTPPrintsRequireFreshManualReview(failPrint: true)
            print("InputManagerGLKVMTests passed (11 HTTP cases, 4 persistence groups)")
        } catch {
            fputs("InputManagerGLKVMTests FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func withRecoveryDefaults(
        _ operation: @MainActor (UserDefaults) async throws -> Void
    ) async throws {
        let suiteName = "overlook.input-recovery-fixture.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CaptureTestFailure(description: "Cannot create isolated recovery defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await operation(defaults)
    }

    @MainActor private static func testInputRecoveryPersistsAcrossManagers() async throws {
        try await withRecoveryDefaults { defaults in
            let first = InputManager(inputRecoveryDefaults: defaults)
            try expect(!first.inputBlocked, "A fresh installation has no recovery block")
            first.blockInputAfterUnconfirmedSession()
            try expect(defaults.bool(forKey: InputManager.inputRecoveryBlockedDefaultsKey),
                       "Unknown input must persist before shutdown")
            defaults.removeObject(forKey: InputManager.inputRecoveryBlockedDefaultsKey)
            first.blockInputAfterUnconfirmedSession()
            try expect(defaults.bool(forKey: InputManager.inputRecoveryBlockedDefaultsKey),
                       "Every unknown outcome must persist even when already blocked")
            await first.shutdown()
            let restarted = InputManager(inputRecoveryDefaults: defaults)
            try expect(restarted.inputBlocked, "A replacement manager must restore the previous unknown outcome")
            try expect(restarted.activityStatus == "Input blocked: previous remote outcome is unknown",
                       "Restart must expose the recovery block in activity status")
            let readiness = await restarted.inputReadiness()
            try expect(!readiness.text && !readiness.mouse, "Restart cannot restore normal input readiness")
            try expect(!restarted.hasInputRecoveryTransport, "Restoring uncertainty cannot invent a release transport")
            await restarted.shutdown()
            let isolated = InputManager()
            try expect(!isolated.inputBlocked, "Default fixture managers must remain independent of stored app state")
            isolated.blockInputAfterUnconfirmedSession()
            let nextIsolated = InputManager()
            try expect(!nextIsolated.inputBlocked, "In-memory fixture blocks cannot leak into another manager")
            await isolated.shutdown()
            await nextIsolated.shutdown()
        }
    }

    @MainActor private static func testInputRecoveryRestoresConservativeStoredFlags() async throws {
        try await withRecoveryDefaults { defaults in
            for value in [false, "false", 0] as [Any] {
                defaults.removeObject(forKey: InputManager.inputRecoveryBlockedDefaultsKey)
                defaults.set(value, forKey: InputManager.inputRecoveryBlockedDefaultsKey)
                let manager = InputManager(inputRecoveryDefaults: defaults)
                try expect(!manager.inputBlocked, "Stored false must preserve unblocked input: \(value)")
                manager.blockInputAfterUnconfirmedSession()
                let restarted = InputManager(inputRecoveryDefaults: defaults)
                try expect(restarted.inputBlocked, "A fresh unknown outcome must persist across restart: \(value)")
                await manager.shutdown()
                await restarted.shutdown()
            }
            for value in [true, "true", 1] as [Any] {
                defaults.removeObject(forKey: InputManager.inputRecoveryBlockedDefaultsKey)
                defaults.set(value, forKey: InputManager.inputRecoveryBlockedDefaultsKey)
                let manager = InputManager(inputRecoveryDefaults: defaults)
                try expect(manager.inputBlocked, "A truthy stored flag must conservatively restore the block: \(value)")
                manager.blockInputAfterUnconfirmedSession()
                let restarted = InputManager(inputRecoveryDefaults: defaults)
                try expect(restarted.inputBlocked, "Relatching a truthy flag must stay blocked after restart: \(value)")
                await manager.shutdown()
                await restarted.shutdown()
            }
        }
    }

    @MainActor private static func testRejectedInputRecoveryKeepsPersistedBlock() async throws {
        try await withRecoveryDefaults { defaults in
            let manager = InputManager(inputRecoveryDefaults: defaults)
            manager.blockInputAfterUnconfirmedSession()
            do {
                try await manager.recoverInputAfterManualReview(authorization: { false })
                throw CaptureTestFailure(description: "Unauthorized recovery must reject")
            } catch let error as RemoteActionError { try expect(error == .unauthorized, "Recovery requires current Manual authority") }
            do {
                try await manager.recoverInputAfterManualReview(authorization: { true })
                throw CaptureTestFailure(description: "Recovery without a transport must reject")
            } catch let error as RemoteActionError { try expect(error == .inputUnavailable, "Absent release transport must remain unavailable") }
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                try await manager.recoverInputAfterManualReview(authorization: { true })
            }
            do {
                try await cancelled.value
                throw CaptureTestFailure(description: "Cancelled recovery must reject")
            } catch is CancellationError {}
            try expect(manager.inputBlocked && defaults.bool(forKey: InputManager.inputRecoveryBlockedDefaultsKey),
                       "Failed, unauthorized and cancelled recovery must retain persistent uncertainty")
            await manager.shutdown()
            let restarted = InputManager(inputRecoveryDefaults: defaults)
            try expect(restarted.inputBlocked, "Rejected review must remain blocked after restart")
            await restarted.shutdown()
        }
    }

    @MainActor private static func testAuthorizedInputRecoveryClearsPersistedBlock() async throws {
        try await withRecoveryHIDFixture { fixture in
            try await testInputRecoveryOnCurrentTransport(fixture)
        }
    }

    @MainActor private static func withRecoveryHIDFixture(
        _ operation: @MainActor (RecoveryHIDFixture) async throws -> Void
    ) async throws {
        let fixture = try await RecoveryHIDFixture.start()
        do { try await operation(fixture) }
        catch {
            await fixture.finish()
            throw error
        }
        await fixture.finish()
    }

    @MainActor private static func testInputRecoveryOnCurrentTransport(_ fixture: RecoveryHIDFixture) async throws {
        try await withRecoveryDefaults { defaults in
            defaults.set(true, forKey: InputManager.inputRecoveryBlockedDefaultsKey)
            let manager = InputManager(inputRecoveryDefaults: defaults)
            let client = try GLKVMClient(host: "127.0.0.1", port: fixture.port, allowInsecureTLS: true,
                                         sessionConfiguration: .ephemeral)
            manager.setGLKVMClient(client)
            manager.setSessionAvailable(true)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !manager.hasInputRecoveryTransport {
                try expect(ProcessInfo.processInfo.systemUptime < deadline, "Local recovery HID transport did not become ready")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(manager.inputBlocked, "Connecting a fresh transport cannot acknowledge a restored block")
            var checks = 0
            do {
                try await manager.recoverInputAfterManualReview(authorization: {
                    checks += 1
                    if checks == 4 { manager.blockInputAfterUnconfirmedSession() }
                    return true
                })
                throw CaptureTestFailure(description: "A newer unknown outcome after release must reject recovery")
            } catch let error as RemoteActionError { try expect(error == .sessionChanged, "A new block needs another review") }
            try expect(defaults.bool(forKey: InputManager.inputRecoveryBlockedDefaultsKey),
                       "A transmitted release cannot erase a newer unreviewed block")
            var revocationChecks = 0
            do {
                try await manager.recoverInputAfterManualReview(authorization: {
                    revocationChecks += 1
                    return revocationChecks < 4
                })
                throw CaptureTestFailure(description: "Revoked authority after release must reject recovery")
            } catch let error as RemoteActionError { try expect(error == .sessionChanged, "Final release must retain current authority") }
            try expect(defaults.bool(forKey: InputManager.inputRecoveryBlockedDefaultsKey),
                       "A transmitted release cannot erase the block after authority is revoked")
            var cancellationChecks = 0
            let cancelled = Task { @MainActor in
                try await manager.recoverInputAfterManualReview(authorization: {
                    cancellationChecks += 1
                    if cancellationChecks == 4 { withUnsafeCurrentTask { $0?.cancel() } }
                    return true
                })
            }
            do {
                try await cancelled.value
                throw CaptureTestFailure(description: "Cancellation after release must reject recovery")
            } catch is CancellationError {}
            try expect(defaults.bool(forKey: InputManager.inputRecoveryBlockedDefaultsKey),
                       "Cancellation after an actual release must retain the stored block")
            try await manager.recoverInputAfterManualReview(authorization: { true })
            try expect(!manager.inputBlocked, "Successful authorized release must clear the live block")
            try expect(defaults.object(forKey: InputManager.inputRecoveryBlockedDefaultsKey) == nil,
                       "Successful authorized release must remove the stored recovery block")
            let releases = ["0100", "02006c656674", "02007269676874", "02006d6964646c65"]
            let releaseDeadline = ProcessInfo.processInfo.systemUptime + 3
            var packets = try await fixture.releasePackets()
            while packets.count < 16 {
                try expect(ProcessInfo.processInfo.systemUptime < releaseDeadline, "Fixture did not receive actual HID releases")
                try await Task.sleep(nanoseconds: 10_000_000)
                packets = try await fixture.releasePackets()
            }
            try expect(Array(packets.prefix(16)) == releases + releases + releases + releases,
                       "Each recovery must transmit keyboard and all three mouse-button releases")
            await manager.shutdown()
            let restarted = InputManager(inputRecoveryDefaults: defaults)
            try expect(!restarted.inputBlocked, "An acknowledged block must stay cleared after restart")
            await restarted.shutdown()
        }
    }

    @MainActor private static func testToolbarPasteRejectsRevokedCaptureGeneration() async throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let http = CaptureHTTPHarness()
        CaptureHTTPProtocol.harness = http
        defer { CaptureHTTPProtocol.harness = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPProtocol.self]
        let client = try GLKVMClient(host: "capture-fixture.invalid", sessionConfiguration: configuration)
        fixture.manager.setGLKVMClient(client)
        await http.waitForFirstConfiguration()
        http.holdConfiguration = true
        let authorization = fixture.manager.makeLocalKeyboardAuthorization()
        let paste = Task { @MainActor in
            try await fixture.manager.sendTextToRemote("toolbar fixture text", authorization: authorization)
        }
        await http.waitForHeldConfiguration()
        let overlayOwner = UUID()
        fixture.manager.setLocalUIBlocked(true, owner: overlayOwner)
        fixture.manager.setLocalUIBlocked(false, owner: overlayOwner)
        try expectCapture(fixture, keyboard: true, mouse: true)
        http.releaseConfiguration()
        do {
            try await paste.value
            throw CaptureTestFailure(description: "An earlier toolbar paste must not regain authority when its overlay closes")
        } catch InputManager.RemoteTextInputError.authorizationExpired {
            try expect(http.printRequests == 0, "Toolbar paste must retain the capture revocation across overlay open/close")
        }
    }

    private enum PasteRevocation: CaseIterable {
        case none, focus, mode, session, temporarilyBlocked
    }

    @MainActor private static func testPasteRechecksAuthorityAfterConfiguration(_ revocation: PasteRevocation) async throws {
        let fixture = CaptureFixture(clipboardText: "fixture text only")
        defer { fixture.finish() }
        let http = CaptureHTTPHarness()
        CaptureHTTPProtocol.harness = http
        defer { CaptureHTTPProtocol.harness = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPProtocol.self]
        let client = try GLKVMClient(host: "capture-fixture.invalid", sessionConfiguration: configuration)
        fixture.manager.setGLKVMClient(client)
        await http.waitForFirstConfiguration()
        http.holdConfiguration = true

        NSApp.sendEvent(fixture.event(characters: "v", keyCode: 9, modifiers: [.command]))
        await http.waitForHeldConfiguration()
        guard let pasteTask = fixture.manager.localClipboardTransferTask else {
            throw CaptureTestFailure(description: "Cmd+V must expose its actual asynchronous transfer task")
        }
        switch revocation {
        case .none: break
        case .focus: fixture.keyWindow = fixture.otherWindow
        case .mode: fixture.manager.setLocalInputCaptureAllowed(false)
        case .session: fixture.manager.setSessionAvailable(false)
        case .temporarilyBlocked:
            let owner = UUID()
            fixture.manager.setLocalUIBlocked(true, owner: owner)
            fixture.manager.setLocalUIBlocked(false, owner: owner)
        }
        // No refresh call: the resumed operation must inspect live focus itself.
        http.releaseConfiguration()
        await pasteTask.value
        let expectedPrints = revocation == .none ? 1 : 0
        try expect(http.printRequests == expectedPrints,
                   "Paste expected \(expectedPrints) hidPrint requests after \(revocation), actual \(http.printRequests)")
    }

    @MainActor private static func testFailedPasteKeepsManualRecoveryAuthority() async throws {
        let fixture = CaptureFixture(clipboardText: "fixture failure")
        defer { fixture.finish() }
        let http = CaptureHTTPHarness()
        http.failPrint = true
        CaptureHTTPProtocol.harness = http
        defer { CaptureHTTPProtocol.harness = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPProtocol.self]
        let client = try GLKVMClient(host: "capture-fixture.invalid", sessionConfiguration: configuration)
        fixture.manager.setGLKVMClient(client)
        await http.waitForFirstConfiguration()
        do {
            try await fixture.manager.sendTextToRemote("fixture failure")
            throw CaptureTestFailure(description: "Fixture print failure must reach caller")
        } catch GLKVMClient.ClientError.transportFailed {
            try expect(fixture.manager.inputBlocked, "Unconfirmed print must block further input")
            try expect(fixture.manager.isLocalInputCaptureAllowed, "Input block must retain Manual recovery authority")
            try expectCapture(fixture, keyboard: false, mouse: false)
        }
        do {
            try await fixture.manager.recoverInputAfterManualReview(authorization: { true })
            throw CaptureTestFailure(description: "Recovery cannot complete without a release transport")
        } catch let error as RemoteActionError {
            try expect(error == .inputUnavailable, "Recovery must pass the Manual-authority gate before finding the absent fixture release transport")
        }
    }

    @MainActor private static func testSessionDisconnectDrainsDispatchedPrint() async throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let http = CaptureHTTPHarness()
        http.holdPrint = true
        http.failPrint = true
        CaptureHTTPProtocol.harness = http
        defer { CaptureHTTPProtocol.harness = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPProtocol.self]
        let firstClient = try GLKVMClient(host: "capture-fixture.invalid", sessionConfiguration: configuration)
        let nextClient = try GLKVMClient(host: "capture-fixture.invalid", port: 8443, sessionConfiguration: configuration)
        fixture.manager.setGLKVMClient(firstClient)
        await http.waitForFirstConfiguration()
        let printTask = Task { @MainActor in try await fixture.manager.sendTextToRemote("held fixture print") }
        await http.waitForHeldPrint()
        var blockedBeforeNextSession = false
        let transition = Task { @MainActor in
            await fixture.manager.disconnectInputForSession()
            blockedBeforeNextSession = fixture.manager.inputBlocked
            fixture.manager.setGLKVMClient(nextClient)
        }

        // This bounded observation detects an incorrectly completed disconnect
        // while a real URLSession print request is still deliberately suspended.
        let finishedWhilePrintPending = await completesWithinObservationWindow(transition)
        http.releasePrint()
        do {
            try await printTask.value
            throw CaptureTestFailure(description: "Held fixture print must fail when released")
        } catch GLKVMClient.ClientError.transportFailed {
            try expect(http.printRequests == 1, "Exactly one held print must report the fixture transport failure")
        }
        await transition.value
        try expect(!finishedWhilePrintPending, "disconnectInputForSession must wait for the already dispatched HTTP print")
        try expect(blockedBeforeNextSession, "Old print failure must be handled before the next session can install its client")
        try expect(fixture.manager.inputBlocked, "An unconfirmed old print must retain the conservative input block")
    }

    @MainActor private static func testExplicitUnconfirmedSessionBlocksWithoutRecoveryTransport() async throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        try expect(!fixture.manager.hasInputRecoveryTransport, "An uninstalled HID socket must never advertise recovery")
        fixture.manager.blockInputAfterUnconfirmedSession()
        fixture.manager.blockInputAfterUnconfirmedSession()
        try expect(fixture.manager.inputBlocked, "An unconfirmed session must latch and retain the input block")
        try expectCapture(fixture, keyboard: false, mouse: false)
        let readiness = await fixture.manager.inputReadiness()
        try expect(!readiness.text && !readiness.mouse, "A latched session must disable all input readiness")
        do {
            try await fixture.manager.recoverInputAfterManualReview(authorization: { true })
            throw CaptureTestFailure(description: "Disconnected manual recovery must reject")
        } catch let error as RemoteActionError {
            try expect(error == .inputUnavailable, "Absent recovery transport must report inputUnavailable")
        }
        try expect(fixture.manager.inputBlocked, "Rejected disconnected recovery must keep the input block")
    }

    @MainActor private static func testPendingHTTPPrintsRequireFreshManualReview(failPrint: Bool) async throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let http = CaptureHTTPHarness()
        http.holdPrint = true
        http.failPrint = failPrint
        CaptureHTTPProtocol.harness = http
        defer { CaptureHTTPProtocol.harness = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPProtocol.self]
        let client = try GLKVMClient(host: "capture-fixture.invalid", sessionConfiguration: configuration)
        fixture.manager.setGLKVMClient(client)
        await http.waitForFirstConfiguration()
        let first = Task { @MainActor in try? await fixture.manager.sendTextToRemote("first outstanding fixture print") }
        let second = Task { @MainActor in try? await fixture.manager.sendTextToRemote("second outstanding fixture print") }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while http.printRequests < 2 {
            try expect(ProcessInfo.processInfo.systemUptime < deadline, "Both actual HTTP print requests must dispatch")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fixture.manager.blockInputAfterUnconfirmedSession()
        var recoveryError: Error?
        let recovery = Task { @MainActor in
            do { try await fixture.manager.recoverInputAfterManualReview(authorization: { true }) }
            catch { recoveryError = error }
        }
        let finishedWithTwoPrintsOutstanding = await completesWithinObservationWindow(recovery)
        http.releaseOnePrint()
        let finishedWithOnePrintOutstanding = await completesWithinObservationWindow(recovery)
        http.releasePrint()
        _ = await first.value
        _ = await second.value
        await recovery.value
        try expect(!finishedWithTwoPrintsOutstanding && !finishedWithOnePrintOutstanding,
                   "Manual recovery must wait for every already dispatched HTTP print before requesting a new review")
        try expect(recoveryError as? RemoteActionError == .sessionChanged,
                   "A sight review predating pending text must reject even when all prints succeed")
        try expect(fixture.manager.inputBlocked, "Pending or later failed prints must preserve the input block")
        try expectCapture(fixture, keyboard: false, mouse: false)
        try expect(http.printRequests == 2, "Draining review must never replay either original print")
    }

    @MainActor private static func completesWithinObservationWindow(_ operation: Task<Void, Never>) async -> Bool {
        let result = CaptureCompletionRace()
        Task { @MainActor in
            await operation.value
            result.resolve(true)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            result.resolve(false)
        }
        return await result.wait()
    }
}

private final class RecoveryFixtureTLS: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct RecoveryHIDFixture {
    let port: Int
    let process: Process
    let directory: URL
    let session: URLSession

    static func start() async throws -> RecoveryHIDFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlook-recovery-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let portFile = directory.appendingPathComponent("port")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        process.arguments = ["node", sourceDirectory.appendingPathComponent("hid-capture-fixture.mjs").path, portFile.path]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: RecoveryFixtureTLS(), delegateQueue: nil)
        do {
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var publishedPort: Int?
            while publishedPort == nil {
                if let portText = try? String(contentsOf: portFile, encoding: .utf8),
                   let port = Int(portText), (1...65535).contains(port), port != 17891 {
                    publishedPort = port
                    break
                }
                try expect(process.isRunning && ProcessInfo.processInfo.systemUptime < deadline,
                           "Local HID fixture failed to publish its port")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let port = publishedPort else {
                throw CaptureTestFailure(description: "Invalid local HID fixture port")
            }
            let (data, response) = try await session.data(from: URL(string: "https://127.0.0.1:\(port)/fixture/health")!)
            let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try expect((response as? HTTPURLResponse)?.statusCode == 200
                       && identity?["fixture"] as? String == "overlook-hid-capture-fixture"
                       && identity?["loopback"] as? Bool == true,
                       "Recovery test may connect only to the verified local recording fixture")
            return RecoveryHIDFixture(port: port, process: process, directory: directory, session: session)
        } catch {
            session.invalidateAndCancel()
            await stop(process)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func releasePackets() async throws -> [String] {
        struct Packet: Decodable { let raw: String }
        let (data, response) = try await session.data(from: URL(string: "https://127.0.0.1:\(port)/fixture/events")!)
        try expect((response as? HTTPURLResponse)?.statusCode == 200, "Cannot read recorded local HID releases")
        return try JSONDecoder().decode([Packet].self, from: data).map(\.raw)
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        await Task.detached {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }.value
    }

    func finish() async {
        session.invalidateAndCancel()
        await Self.stop(process)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class CaptureCompletionRace {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
private final class CaptureHTTPHarness {
    var holdConfiguration = false
    var failPrint = false
    var holdPrint = false
    private(set) var printRequests = 0
    private var pending: [CaptureHTTPProtocol] = []
    private var pendingPrints: [CaptureHTTPProtocol] = []
    private let firstConfiguration = CaptureBarrier()
    private let heldConfiguration = CaptureBarrier()
    private let heldPrint = CaptureBarrier()

    func handle(_ request: CaptureHTTPProtocol) {
        switch request.request.url?.path {
        case "/api/system/get_config":
            firstConfiguration.release()
            if holdConfiguration {
                pending = pending + [request]
                heldConfiguration.release()
            } else {
                respondConfiguration(request)
            }
        case "/api/hid/print":
            printRequests += 1
            if holdPrint {
                pendingPrints = pendingPrints + [request]
                heldPrint.release()
            } else {
                respondPrint(request)
            }
        default:
            request.client?.urlProtocol(request, didFailWithError: URLError(.unsupportedURL))
        }
    }

    func waitForFirstConfiguration() async { await firstConfiguration.wait() }
    func waitForHeldConfiguration() async { await heldConfiguration.wait() }
    func waitForHeldPrint() async { await heldPrint.wait() }

    func releaseOnePrint() {
        guard let request = pendingPrints.first else { return }
        pendingPrints = Array(pendingPrints.dropFirst())
        respondPrint(request)
    }

    func releasePrint() {
        holdPrint = false
        let requests = pendingPrints
        pendingPrints = []
        requests.forEach(respondPrint)
    }

    func releaseConfiguration() {
        holdConfiguration = false
        let requests = pending
        pending = []
        requests.forEach(respondConfiguration)
    }

    private func respondConfiguration(_ request: CaptureHTTPProtocol) {
        respond(request, body: "{\"ok\":true,\"result\":{\"config\":{\"is_absolute_mouse\":true}}}")
    }

    private func respondPrint(_ request: CaptureHTTPProtocol) {
        if failPrint {
            request.client?.urlProtocol(request, didFailWithError: URLError(.networkConnectionLost))
        } else {
            respond(request, body: "{\"ok\":true,\"result\":{}}")
        }
    }

    private func respond(_ request: CaptureHTTPProtocol, body: String) {
        let response = HTTPURLResponse(url: request.request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: Data(body.utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

private final class CaptureHTTPProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var harness: CaptureHTTPHarness?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "capture-fixture.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            guard let harness = Self.harness else {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            harness.handle(self)
        }
    }
    override func stopLoading() {}
}
