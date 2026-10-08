import AppKit
import Foundation

@main
struct InputManagerGLKVMTests {
    @MainActor static func main() async {
        do {
            for revocation in PasteRevocation.allCases {
                try await testPasteRechecksAuthorityAfterConfiguration(revocation)
            }
            try await testToolbarPasteRejectsRevokedCaptureGeneration()
            try await testFailedPasteKeepsManualRecoveryAuthority()
            try await testSessionDisconnectDrainsDispatchedPrint()
            try await testExplicitUnconfirmedSessionBlocksWithoutRecoveryTransport()
            try await testPendingHTTPPrintsRequireFreshManualReview(failPrint: false)
            try await testPendingHTTPPrintsRequireFreshManualReview(failPrint: true)
            print("InputManagerGLKVMTests passed (11 HTTP cases)")
        } catch {
            fputs("InputManagerGLKVMTests FAILED: \(error)\n", stderr)
            exit(1)
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
