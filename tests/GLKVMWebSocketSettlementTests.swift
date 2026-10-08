import AppKit
import Combine
import Foundation

private struct StalledConnection: Decodable {
    let id: Int
    let mode: String
    let upgraded: Bool
    let closed: Bool
    let bytes: Int
    let events: [String]
    let binary: [String]
}
private struct FixtureStatus: Decodable { let connections: [StalledConnection]; let printTexts: [String] }

private final class SettlementTLS: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct SettlementControl {
    let port: Int
    let session = URLSession(configuration: .ephemeral, delegate: SettlementTLS(), delegateQueue: nil)
    func request(_ path: String, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        try expect((response as? HTTPURLResponse)?.statusCode == 200, "Fixture request failed: \(path)")
        return data
    }
    func mode(_ mode: String) async throws { _ = try await request("/fixture/mode?value=\(mode)", method: "POST") }
    func close(_ id: Int) async throws { _ = try await request("/fixture/close?id=\(id)", method: "POST") }
    func status() async throws -> [StalledConnection] {
        try JSONDecoder().decode(FixtureStatus.self, from: await request("/fixture/status")).connections
    }
    func printedTexts() async throws -> [String] {
        try JSONDecoder().decode(FixtureStatus.self, from: await request("/fixture/status")).printTexts
    }
    func waitForConnection(after count: Int) async throws -> StalledConnection {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let connection = try await status().dropFirst(count).first { return connection }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CaptureTestFailure(description: "Fixture did not receive WebSocket upgrade")
    }
}

@MainActor
private final class SettlementProbe {
    var completed = false
    var dispatched = false
    var error: Error?
    var observedErrors: [String] = []
}

@main
struct GLKVMWebSocketSettlementTests {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2, let port = Int(CommandLine.arguments[1]),
              (1...65535).contains(port), port != 17891 else { exit(2) }
        let control = SettlementControl(port: port)
        defer { control.session.invalidateAndCancel() }
        do {
            let health = try JSONSerialization.jsonObject(with: await control.request("/fixture/health")) as? [String: Any]
            try expect(health?["fixture"] as? String == "overlook-ws-settlement", "Only the local settlement fixture is allowed")
            try await testInputRecoveryKeepsBlockAcrossReconnect(control)
            print("PASS: live recovery transport survives the block; reconnect never unblocks or replays text")
            try await testInputRecoveryRejectsRevocationCancellationAndStaleSession(control)
            print("PASS: absent, failed, unauthorized, revoked, cancelled and replaced recovery keep input blocked")
            try await testCancelledRemoteActionBlocksInputAndDrains(control)
            print("PASS: cancellation after dispatch blocks actual input before bounded queue cleanup")
            try await testStalledCallerCancellationDoesNotReplay(control)
            print("PASS: caller cancellation settles an uncertain send and preserves its replacement")
            try await testAlreadyCancelledSendDoesNotDispatch(control)
            print("PASS: cancellation before dispatch never reaches the fixture")
            try await testDisconnectSettlesPendingSend(control)
            print("PASS: disconnect settles an uncertain send and preserves its replacement")
            try await testShutdownDoesNotReconnect(control)
            print("PASS: shutdown settles and never reconnects after an in-flight local key fails")
            try await testLocalKeyTimeoutBlocksInput(control)
            print("PASS: local key timeout remains visible and blocks input")
            try await testDisconnectSettlesStalledRelease(control)
            print("PASS: stalled release settles, visible error and conservative block")
            try await testStalledSendKeepsNewSocketAlive(control)
            print("PASS: stalled send deadline preserves the newer shared-session socket")
            try await testStaleAbortCannotCloseReplacementTask(control)
            print("PASS: stale abort preserves replacement task on the same client")
            try await testReconnectAfterOldPingStarted(control)
            print("PASS: reconnect remains usable after the old connection's regular ping started")
            print("GLKVMWebSocketSettlementTests passed (12 groups)")
        } catch {
            fputs("GLKVMWebSocketSettlementTests FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func testInputRecoveryKeepsBlockAcrossReconnect(_ control: SettlementControl) async throws {
        try await control.mode("normal")
        let previous = try await control.status().count
        let textCount = try await control.printedTexts().count
        var clock: TimeInterval = 0
        let fixture = CaptureFixture(microJigglerClock: { clock })
        defer { fixture.finish() }
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        fixture.manager.setGLKVMClient(client)
        fixture.manager.setTransportMode(.glkvmWebSocket)
        let first = try await control.waitForConnection(after: previous)
        try await waitForRecoveryTransport(fixture.manager, available: true)
        try expect(fixture.manager.hidStatus == "Connected", "Only actual socket readiness may publish Connected")
        do {
            try await fixture.manager.sendTextToRemote("original unconfirmed fixture text")
            throw CaptureTestFailure(description: "The fixture must reject the original HTTP print")
        } catch is GLKVMClient.ClientError {}
        fixture.manager.blockInputAfterUnconfirmedSession()
        await fixture.manager.waitForHIDCommandsToDrain()
        try expect(fixture.manager.hasInputRecoveryTransport, "A connected release transport remains available while input is blocked")
        let blockedReady = await fixture.manager.inputReadiness()
        try expect(!blockedReady.text && !blockedReady.mouse, "Recovery capability must not grant normal remote input")
        try expectCapture(fixture, keyboard: false, mouse: false)
        let firstBefore = try await control.status().first(where: { $0.id == first.id })!.binary
        fixture.manager.setMicroJigglerEnabled(true)
        clock = 61
        NSApp.sendEvent(fixture.event())
        fixture.manager.handleVideoMouseScroll(deltaX: 0, deltaY: 1)
        await fixture.manager.performMicroJigglerTick()
        await fixture.manager.waitForHIDCommandsToDrain()
        let firstAfter = try await control.status().first(where: { $0.id == first.id })!.binary
        try expect(firstAfter == firstBefore, "Blocked local events and Jiggler must emit no HID packets")

        await fixture.manager.disconnectInputForSession()
        try expect(!fixture.manager.hasInputRecoveryTransport && fixture.manager.inputBlocked,
                   "Session retire must remove recovery capability and retain uncertainty")
        fixture.manager.setGLKVMClient(client)
        fixture.manager.setSessionAvailable(true)
        let replacement = try await control.waitForConnection(after: previous + 1)
        try await waitForRecoveryTransport(fixture.manager, available: true)
        try expect(fixture.manager.inputBlocked, "Reconnect cannot clear a previous unconfirmed outcome")
        try expectCapture(fixture, keyboard: false, mouse: false)
        let reconnectedReady = await fixture.manager.inputReadiness()
        try expect(!reconnectedReady.text && !reconnectedReady.mouse, "Reconnect under the block must preserve disabled normal readiness")
        clock = 122
        await fixture.manager.performMicroJigglerTick()
        let blockedReplacement = try await control.status().first(where: { $0.id == replacement.id })!
        try expect(blockedReplacement.binary.isEmpty, "Blocked reconnect must never start the Jiggler")
        try await fixture.manager.recoverInputAfterManualReview(authorization: { true })
        try expect(!fixture.manager.inputBlocked, "Explicit Manual release on the current live socket must clear the block")
        try expectCapture(fixture, keyboard: true, mouse: true)
        let ready = await fixture.manager.inputReadiness()
        try expect(ready.text && ready.mouse, "Successful Manual recovery restores normal readiness")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var packets: [String] = []
        repeat {
            packets = try await control.status().first(where: { $0.id == replacement.id })!.binary
            if packets.count >= 4 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        try expect(Array(packets.prefix(4)) == ["0100", "02006c656674", "02007269676874", "02006d6964646c65"],
                   "Manual recovery must transmit actual keyboard and three mouse releases")
        let texts = try await control.printedTexts()
        try expect(Array(texts.dropFirst(textCount)) == ["original unconfirmed fixture text"],
                   "Failed text must be dispatched once only, with no replay during recovery")
        try await control.close(replacement.id)
        try await waitForRecoveryTransport(fixture.manager, available: false)
        try expect(!fixture.manager.inputBlocked,
                   "Socket failure alone must not invent an unconfirmed action after successful Manual recovery")
        await fixture.manager.disconnectInputForSession()
    }

    @MainActor private static func testInputRecoveryRejectsRevocationCancellationAndStaleSession(_ control: SettlementControl) async throws {
        try await control.mode("normal")
        let previous = try await control.status().count
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        fixture.manager.setGLKVMClient(client)
        fixture.manager.setTransportMode(.glkvmWebSocket)
        let connected = try await control.waitForConnection(after: previous)
        try await waitForRecoveryTransport(fixture.manager, available: true)
        fixture.manager.blockInputAfterUnconfirmedSession()
        await fixture.manager.waitForHIDCommandsToDrain()
        do {
            try await fixture.manager.recoverInputAfterManualReview(authorization: { false })
            throw CaptureTestFailure(description: "Unauthorized recovery must reject")
        } catch let error as RemoteActionError { try expect(error == .unauthorized, "False Manual authority must remain unauthorized") }
        var checks = 0
        do {
            try await fixture.manager.recoverInputAfterManualReview(authorization: {
                checks += 1
                return checks == 1
            })
            throw CaptureTestFailure(description: "Authority revoked during queue drain must reject")
        } catch let error as RemoteActionError { try expect(error == .sessionChanged, "Recovery must recheck authority after queue drain") }
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.manager.recoverInputAfterManualReview(authorization: { true })
        }
        do { try await cancelled.value; throw CaptureTestFailure(description: "Cancelled recovery must reject") }
        catch is CancellationError {}
        try expect(fixture.manager.inputBlocked, "All rejected review attempts must retain the latch")

        var latchChecks = 0
        do {
            try await fixture.manager.recoverInputAfterManualReview(authorization: {
                latchChecks += 1
                if latchChecks == 4 { fixture.manager.blockInputAfterUnconfirmedSession() }
                return true
            })
            throw CaptureTestFailure(description: "A newer unconfirmed outcome during actual release must reject")
        } catch let error as RemoteActionError {
            try expect(error == .sessionChanged, "Successful release cannot acknowledge a newer latched uncertainty")
        }
        try expect(fixture.manager.inputBlocked, "A newer block must require another explicit Manual sight review")

        var cancellationChecks = 0
        let cancelledAfterRelease = Task { @MainActor in
            try await fixture.manager.recoverInputAfterManualReview(authorization: {
                cancellationChecks += 1
                if cancellationChecks == 4 { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            })
        }
        do {
            try await cancelledAfterRelease.value
            throw CaptureTestFailure(description: "Cancellation after actual release must reject")
        } catch is CancellationError {}
        try expect(fixture.manager.inputBlocked, "Cancellation after successful transport release must retain uncertainty")

        var finalChecks = 0
        do {
            try await fixture.manager.recoverInputAfterManualReview(authorization: {
                finalChecks += 1
                if finalChecks >= 4 { fixture.manager.setLocalInputCaptureAllowed(false) }
                return true
            })
            throw CaptureTestFailure(description: "Manual mode revoked after release must reject")
        } catch let error as RemoteActionError { try expect(error == .sessionChanged, "Final release must retain Manual mode authorization") }
        try expect(fixture.manager.inputBlocked, "Successful transport release cannot override revoked Manual mode")
        fixture.manager.setLocalInputCaptureAllowed(true)
        try await control.close(connected.id)
        try await waitForRecoveryTransport(fixture.manager, available: false)
        do {
            try await fixture.manager.recoverInputAfterManualReview(authorization: { true })
            throw CaptureTestFailure(description: "Closed WebSocket recovery must reject")
        } catch let error as RemoteActionError { try expect(error == .inputUnavailable, "An installed but closed socket is unavailable") }
        try expect(fixture.manager.inputBlocked, "Failed socket must retain the block")

        fixture.manager.setGLKVMClient(nil)
        fixture.manager.setGLKVMClient(client)
        try await waitForRecoveryTransport(fixture.manager, available: true)
        var replacedChecks = 0
        do {
            try await fixture.manager.recoverInputAfterManualReview(authorization: {
                replacedChecks += 1
                if replacedChecks >= 4 { fixture.manager.setGLKVMClient(nil) }
                return true
            })
            throw CaptureTestFailure(description: "Replaced socket after release must reject")
        } catch let error as RemoteActionError { try expect(error == .sessionChanged, "A captured release cannot authorize a replacement session") }
        try expect(fixture.manager.inputBlocked && !fixture.manager.hasInputRecoveryTransport,
                   "Retiring the captured socket must retain the block and clear recovery capability")
        await fixture.manager.disconnectInputForSession()
    }

    @MainActor private static func waitForRecoveryTransport(_ manager: InputManager, available: Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while manager.hasInputRecoveryTransport != available {
            try expect(ProcessInfo.processInfo.systemUptime < deadline,
                       "Recovery transport expected \(available), actual \(manager.hasInputRecoveryTransport)")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor private static func testCancelledRemoteActionBlocksInputAndDrains(_ control: SettlementControl) async throws {
        try await control.mode("stall-handshake")
        let previous = try await control.status().count
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        fixture.manager.setGLKVMClient(client)
        fixture.manager.setTransportMode(.glkvmWebSocket)
        _ = try await control.waitForConnection(after: previous)
        let probe = SettlementProbe()
        let action = Task { @MainActor in
            do {
                try await fixture.manager.performRemoteAction(
                    .scroll(x: 10, y: 10, deltaY: 1), width: 100, height: 100,
                    authorization: { true }, willDispatch: { probe.dispatched = true }
                )
            } catch { probe.error = error }
            probe.completed = true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(probe.dispatched, "The real command must pass its dispatch boundary before cancellation")
        action.cancel()
        try await waitForCompletion(probe, "A cancelled actual HID action must release its waiting caller within one second")
        await action.value
        try expect(probe.error?.localizedDescription == "WebSocket send was cancelled; remote outcome is unknown.",
                   "The real dispatched action must retain its unknown outcome")
        try expect(fixture.manager.inputBlocked, "Cancellation after dispatch must block input before cleanup")
        try expect(fixture.manager.lastInputError != nil, "Cancellation after dispatch must leave a visible error")
        let cleanup = SettlementProbe()
        let disconnect = Task { @MainActor in
            await fixture.manager.disconnectInputForSession()
            cleanup.completed = true
        }
        try await waitForCompletion(cleanup, "The uncertain command must not prevent the real HID queue from draining")
        await disconnect.value
        try expect(fixture.manager.inputBlocked, "Queue cleanup must never clear an uncertain action's input block")
    }

    @MainActor private static func testStalledCallerCancellationDoesNotReplay(_ control: SettlementControl) async throws {
        try await control.mode("stall-handshake")
        let previous = try await control.status().count
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        let socket = try client.makeWebSocketClient()
        await socket.connect()
        let oldConnection = try await control.waitForConnection(after: previous)
        let probe = SettlementProbe()
        let send = Task { @MainActor in
            do { try await socket.send(eventType: "cancelled-stalled-probe") }
            catch { probe.error = error }
            probe.completed = true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        send.cancel()
        try await waitForCompletion(probe, "Cancellation must settle an actual pending send within one second")
        await send.value
        try expect(probe.error?.localizedDescription == "WebSocket send was cancelled; remote outcome is unknown.",
                   "Cancellation after dispatch must never report success or a definitive not-started result")
        try await verifyReplacement(socket, after: previous + 1, event: "replacement-after-cancel", control: control)
        let records = try await control.status()
        try expect(records.first(where: { $0.id == oldConnection.id })?.closed == true,
                   "Cancellation must close only the affected stalled transport")
        try expect(!records.contains(where: { $0.events.contains("cancelled-stalled-probe") }),
                   "A cancelled uncertain send must never replay on a replacement")
    }

    @MainActor private static func testAlreadyCancelledSendDoesNotDispatch(_ control: SettlementControl) async throws {
        try await control.mode("normal")
        let previous = try await control.status().count
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        let socket = try client.makeWebSocketClient()
        await socket.connect()
        let connection = try await control.waitForConnection(after: previous)
        try await waitUntilConnected(socket)
        let probe = SettlementProbe()
        // This MainActor task cannot run until the current actor turn yields.
        let send = Task { @MainActor in
            do { try await socket.send(eventType: "never-dispatched-cancelled-probe") }
            catch { probe.error = error }
            probe.completed = true
        }
        send.cancel()
        try await waitForCompletion(probe, "An already cancelled send must settle without transport dispatch")
        await send.value
        try await Task.sleep(nanoseconds: 100_000_000)
        let records = try await control.status()
        let connected = await socket.isConnected
        await socket.disconnect()
        guard let record = records.first(where: { $0.id == connection.id }) else {
            throw CaptureTestFailure(description: "Fixture lost the active connection record")
        }
        try expect(probe.error is CancellationError, "Cancellation before dispatch must retain its definitive cancellation result")
        try expect(!record.events.contains("never-dispatched-cancelled-probe"),
                   "Cancellation before dispatch must emit no command")
        try expect(connected, "A send cancelled before dispatch must preserve the healthy transport")
    }

    @MainActor private static func testDisconnectSettlesPendingSend(_ control: SettlementControl) async throws {
        try await control.mode("stall-handshake")
        let previous = try await control.status().count
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        let socket = try client.makeWebSocketClient()
        await socket.connect()
        _ = try await control.waitForConnection(after: previous)
        let probe = SettlementProbe()
        let send = Task { @MainActor in
            do { try await socket.send(eventType: "disconnected-stalled-probe") }
            catch { probe.error = error }
            probe.completed = true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await socket.disconnect()
        try await waitForCompletion(probe, "Disconnect must settle an actual pending send within one second")
        await send.value
        try expect(probe.error?.localizedDescription == "WebSocket send was cancelled; remote outcome is unknown.",
                   "Disconnect after dispatch must retain the uncertain remote outcome")
        try await verifyReplacement(socket, after: previous + 1, event: "replacement-after-disconnect", control: control)
        let records = try await control.status()
        try expect(!records.contains(where: { $0.events.contains("disconnected-stalled-probe") }),
                   "Disconnect must never replay an uncertain send")
    }

    @MainActor private static func waitForCompletion(_ probe: SettlementProbe, _ message: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !probe.completed, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(probe.completed, message)
    }

    private static func verifyReplacement(_ socket: GLKVMClient.WebSocketClient, after count: Int,
                                          event: String, control: SettlementControl) async throws {
        try await control.mode("normal")
        await socket.connect()
        let replacement = try await control.waitForConnection(after: count)
        try await waitUntilConnected(socket)
        // Cross the retired transport's former send deadline and late callbacks.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        try await socket.send(eventType: event)
        let record = try await waitForEvent(event, id: replacement.id, control: control)
        let connected = await socket.isConnected
        await socket.disconnect()
        try expect(connected, "An old completion must not close a replacement transport")
        try expect(record.events.filter { $0 == event }.count == 1, "The replacement must transmit its probe exactly once")
    }

    @MainActor private static func testShutdownDoesNotReconnect(_ control: SettlementControl) async throws {
        try await control.mode("stall-handshake")
        let previous = try await control.status().count
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        fixture.manager.setGLKVMClient(client)
        fixture.manager.setTransportMode(.glkvmWebSocket)
        let connection = try await control.waitForConnection(after: previous)
        NSApp.sendEvent(fixture.event())
        // Let the real local command enter URLSession before shutdown revokes capture.
        try await Task.sleep(nanoseconds: 100_000_000)
        let probe = SettlementProbe()
        let shutdown = Task { @MainActor in
            await fixture.manager.shutdown()
            probe.completed = true
        }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let boundedCompletion = probe.completed
        try await control.close(connection.id)
        await shutdown.value
        let connectionsAfterShutdown = try await control.status().count - previous
        try expect(boundedCompletion, "shutdown must settle an actual pending HID send within 4 seconds")
        try expect(fixture.manager.inputBlocked, "shutdown must retain uncertainty after an unconfirmed key send")
        try expect(connectionsAfterShutdown == 1, "A late HID failure must not schedule reconnect after shutdown; observed \(connectionsAfterShutdown) connections")
    }

    @MainActor private static func testReconnectAfterOldPingStarted(_ control: SettlementControl) async throws {
        try await control.mode("stall-handshake")
        let previous = try await control.status().count
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        let socket = try client.makeWebSocketClient()
        await socket.connect()
        _ = try await control.waitForConnection(after: previous)
        // The production ping timer fires after 2s. This exercises its normal
        // lifecycle; it cannot force the exact scheduling of the old catch.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        try await control.mode("normal")
        await socket.disconnect()
        await socket.connect()
        let replacement = try await control.waitForConnection(after: previous + 1)
        try await waitUntilConnected(socket)
        // Cross the old ping send's original 2s deadline as well.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        try await socket.send(eventType: "replacement-after-old-ping")
        let record = try await waitForEvent("replacement-after-old-ping", id: replacement.id, control: control)
        let isConnected = await socket.isConnected
        await socket.disconnect()
        try expect(isConnected, "The old ping's completion must not disconnect the replacement transport")
        try expect(record.events.filter { $0 == "replacement-after-old-ping" }.count == 1,
                   "The replacement must send once after the old ping and its deadline have settled")
    }

    @MainActor private static func testLocalKeyTimeoutBlocksInput(_ control: SettlementControl) async throws {
        try await control.mode("stall-handshake")
        let previous = try await control.status().count
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        fixture.manager.setGLKVMClient(client)
        fixture.manager.setTransportMode(.glkvmWebSocket)
        let connection = try await control.waitForConnection(after: previous)
        try expect(fixture.manager.isKeyboardCaptureEnabled, "The actual local event must be authorized before its transport stalls")
        let probe = SettlementProbe()
        let observation = fixture.manager.$lastInputError.sink { error in
            if let error { probe.observedErrors.append(error) }
        }
        defer { observation.cancel() }
        NSApp.sendEvent(fixture.event())
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let blockedAfterTimeout = fixture.manager.inputBlocked
        let errorAfterTimeout = fixture.manager.lastInputError
        // Cleanup cannot be allowed to create the block being tested.
        try await control.close(connection.id)
        await fixture.manager.disconnectInputForSession()
        try expect(probe.observedErrors.contains("WebSocket send timed out."), "The original local HID command must report its typed timeout")
        try expect(errorAfterTimeout != nil, "A local HID timeout must leave a visible transport error")
        try expect(blockedAfterTimeout, "An unconfirmed local key send must block further input before session cleanup")
    }

    @MainActor private static func testStaleAbortCannotCloseReplacementTask(_ control: SettlementControl) async throws {
        try await control.mode("normal")
        let previous = try await control.status().count
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        let socket = try client.makeWebSocketClient()
        await socket.connect()
        _ = try await control.waitForConnection(after: previous)
        try await waitUntilConnected(socket)
        let oldAbort = await socket.scheduleCurrentTransportAbort(after: 500_000_000)
        await socket.disconnect()
        await socket.connect()
        let replacement = try await control.waitForConnection(after: previous + 1)
        try await waitUntilConnected(socket)
        await oldAbort?.value
        try await socket.send(eventType: "replacement-after-old-abort")
        let record = try await waitForEvent("replacement-after-old-abort", id: replacement.id, control: control)
        let replacementIsConnected = await socket.isConnected
        await socket.disconnect()
        try expect(replacementIsConnected, "A captured old-task abort must not close a replacement task on the same WebSocketClient")
        try expect(record.events.filter { $0 == "replacement-after-old-abort" }.count == 1,
                   "A replacement task must transmit the probe once after the old deadline has fired")
    }

    @MainActor private static func testDisconnectSettlesStalledRelease(_ control: SettlementControl) async throws {
        try await control.mode("stall-handshake")
        let previous = try await control.status().count
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port,
                                    sessionConfiguration: .ephemeral)
        fixture.manager.setGLKVMClient(client)
        fixture.manager.setTransportMode(.glkvmWebSocket)
        let connection = try await control.waitForConnection(after: previous)
        try expect(!connection.upgraded, "The actual WebSocket handshake must remain suspended")
        try expect(!fixture.manager.hasInputRecoveryTransport,
                   "A created but unconfirmed WebSocket must not advertise a recovery transport")
        let probe = SettlementProbe()
        let disconnect = Task { @MainActor in
            await fixture.manager.disconnectInputForSession()
            probe.completed = true
        }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let boundedCompletion = probe.completed
        // Always terminate the owned fixture socket so the RED test also exits.
        try await control.close(connection.id)
        await disconnect.value
        try expect(boundedCompletion, "disconnectInputForSession remained pending beyond 4 seconds on an actual stalled WSS release")
        try expect(fixture.manager.lastInputError != nil, "Failed remote release must remain visible")
        try expect(fixture.manager.inputBlocked, "Unconfirmed release must block input conservatively")
    }

    @MainActor private static func testStalledSendKeepsNewSocketAlive(_ control: SettlementControl) async throws {
        try await control.mode("stall-handshake")
        let previous = try await control.status().count
        let client = try GLKVMClient(host: "127.0.0.1", port: control.port, sessionConfiguration: .ephemeral)
        let oldSocket = try client.makeWebSocketClient()
        await oldSocket.connect()
        let oldConnection = try await control.waitForConnection(after: previous)
        let probe = SettlementProbe()
        let oldSend = Task { @MainActor in
            do { try await oldSocket.send(eventType: "old-stalled-probe") }
            catch { probe.error = error }
            probe.completed = true
        }
        try await control.mode("normal")
        // Both sockets deliberately share GLKVMClient's URLSession.
        let newSocket = try client.makeWebSocketClient()
        await newSocket.connect()
        let newConnection = try await control.waitForConnection(after: previous + 1)
        try await waitUntilConnected(newSocket)
        try await newSocket.send(eventType: "fresh-before-timeout")
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let boundedCompletion = probe.completed
        if !boundedCompletion { await oldSocket.disconnect() }
        await oldSend.value
        try await control.close(oldConnection.id)
        try await newSocket.send(eventType: "fresh-after-timeout")
        let record = try await waitForEvent("fresh-after-timeout", id: newConnection.id, control: control)
        let newIsConnected = await newSocket.isConnected
        await newSocket.disconnect()
        await oldSocket.disconnect()
        try expect(boundedCompletion, "An actual pending URLSession WebSocket send must settle within its bounded deadline")
        try expect(probe.error?.localizedDescription == "WebSocket send timed out.", "A stalled send must return the typed timeout error, never success")
        try expect(newIsConnected, "Aborting the old task must not invalidate the shared session's newer socket")
        try expect(record.events.filter { $0 == "fresh-before-timeout" }.count == 1
                   && record.events.filter { $0 == "fresh-after-timeout" }.count == 1,
                   "Transport recovery must never retry and duplicate an input")
        try expect(!record.events.contains("old-stalled-probe"), "An old failed send must not replay on the newer socket")
    }

    private static func waitUntilConnected(_ socket: GLKVMClient.WebSocketClient) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await socket.isConnected) {
            try expect(ProcessInfo.processInfo.systemUptime < deadline, "Normal fixture WebSocket did not become ready")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func waitForEvent(_ event: String, id: Int, control: SettlementControl) async throws -> StalledConnection {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let record = try await control.status().first(where: { $0.id == id }), record.events.contains(event) { return record }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CaptureTestFailure(description: "Normal fixture did not receive expected event \(event)")
    }
}
