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
}
private struct FixtureStatus: Decodable { let connections: [StalledConnection] }

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
            print("GLKVMWebSocketSettlementTests passed (6 groups)")
        } catch {
            fputs("GLKVMWebSocketSettlementTests FAILED: \(error)\n", stderr)
            exit(1)
        }
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
