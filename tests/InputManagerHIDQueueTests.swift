// Actual GLKVMClient/WebSocket queue tests. The only endpoint is the local TLS fixture.
import AppKit
import Foundation

private struct RecordedHIDEvent: Decodable, CustomStringConvertible {
    let seq: Int
    let type: String
    let key: String?
    let button: String?
    let state: Bool?
    let x: Int?
    let y: Int?
    let raw: String

    var description: String { "\(seq):\(type):\(raw)" }
}

private final class FixtureTLSDelegate: NSObject, URLSessionDelegate {
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

private struct HIDFixtureControl {
    let port: Int
    private let session: URLSession

    init(port: Int) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 7
        session = URLSession(configuration: configuration, delegate: FixtureTLSDelegate(), delegateQueue: nil)
    }

    func reset() async throws { _ = try await request(path: "/fixture/reset", method: "POST") }

    func verifyIdentity() async throws {
        struct Identity: Decodable { let fixture: String; let loopback: Bool }
        let data = try await request(path: "/fixture/health", method: "GET")
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        try expect(identity.fixture == "overlook-hid-capture-fixture" && identity.loopback,
                   "Refusing HID: target is not the expected local recording fixture")
    }

    func recordedAfterClose() async throws -> [RecordedHIDEvent] {
        let data = try await request(path: "/fixture/events?wait_closed=1", method: "GET")
        return try JSONDecoder().decode([RecordedHIDEvent].self, from: data)
    }

    func finish() { session.invalidateAndCancel() }

    private func request(path: String, method: String) async throws -> Data {
        let url = URL(string: "https://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        try expect((response as? HTTPURLResponse)?.statusCode == 200,
                   "Local fixture \(path) returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        return data
    }
}

@main
struct InputManagerHIDQueueTests {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2,
              let port = Int(CommandLine.arguments[1]), (1...65535).contains(port), port != 17891 else {
            fputs("Usage: InputManagerHIDQueueTests <local fixture port>\n", stderr)
            exit(2)
        }
        let control = HIDFixtureControl(port: port)
        defer { control.finish() }
        do { try await control.verifyIdentity() }
        catch {
            fputs("InputManagerHIDQueueTests fixture identity check FAILED: \(error)\n", stderr)
            exit(1)
        }
        let cases: [(String, @MainActor (CaptureFixture) async throws -> Void)] = [
            ("actual WebSocket dispatch", testActualWebSocketDispatch),
            ("scheduled move revoked at execution", testScheduledMoveRevoked),
            ("frozen moves revoked at execution", testFrozenMovesRevoked),
            ("queued key and wheel revoked at execution", testKeyAndWheelRevoked),
            ("queued inputs invalidated by disconnect", testQueuedInputsDisconnected),
            ("headless false-to-false emits no extra release", testHeadlessRefreshDoesNotReleaseAgain),
        ]
        var failures: [String] = []
        for (name, run) in cases {
            let fixture = CaptureFixture()
            do {
                try await connect(fixture, port: port)
                try await control.reset()
                try await run(fixture)
                let events = try await control.recordedAfterClose()
                try verify(name: name, events: events)
                print("PASS: \(name)")
            } catch {
                failures = failures + ["\(name): \(error)"]
                await fixture.manager.disconnectInputForSession()
                fputs("FAIL: \(name): \(error)\n", stderr)
            }
            fixture.finish()
        }
        if !failures.isEmpty {
            fputs("InputManagerHIDQueueTests FAILED: \(failures.count)/\(cases.count) groups\n", stderr)
            exit(1)
        }
        print("InputManagerHIDQueueTests passed (\(cases.count) groups)")
    }

    @MainActor private static func connect(_ fixture: CaptureFixture, port: Int) async throws {
        let client = try GLKVMClient(host: "127.0.0.1", port: port, allowInsecureTLS: true,
                                     sessionConfiguration: .ephemeral)
        fixture.manager.setGLKVMClient(client)
        fixture.manager.setTransportMode(.glkvmWebSocket)
        let deadline = Date().addingTimeInterval(5)
        while !(await fixture.manager.inputReadiness()).mouse {
            try expect(Date() < deadline, "Actual GLKVM WebSocket did not become ready: \(fixture.manager.hidStatus)")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expectCapture(fixture, keyboard: true, mouse: true)
    }

    @MainActor private static func localMove(_ fixture: CaptureFixture, x: CGFloat = 25) {
        fixture.manager.handleVideoMouseMove(pointInView: CGPoint(x: x, y: 75),
            viewSize: CGSize(width: 100, height: 100), videoSize: nil)
    }

    @MainActor private static func sentinelAndDisconnect(_ fixture: CaptureFixture) async throws {
        // This public command is behind all local commands in the actual HID queue.
        try await fixture.manager.sendCodexClick(signedX: 1234, signedY: 5678)
        await fixture.manager.disconnectInputForSession()
    }

    @MainActor private static func testActualWebSocketDispatch(_ fixture: CaptureFixture) async throws {
        localMove(fixture, x: 20)
        fixture.manager.handleVideoMouseScroll(deltaX: 0, deltaY: 1)
        localMove(fixture, x: 40)
        fixture.manager.handleVideoMouseScroll(deltaX: 0, deltaY: 1)
        NSApp.sendEvent(fixture.event())
        NSApp.sendEvent(fixture.event(type: .keyUp))
        try await sentinelAndDisconnect(fixture)
    }

    @MainActor private static func testScheduledMoveRevoked(_ fixture: CaptureFixture) async throws {
        localMove(fixture)
        // No refresh and no suspension between enqueue and focus revocation.
        fixture.keyWindow = fixture.otherWindow
        try await sentinelAndDisconnect(fixture)
    }

    @MainActor private static func testFrozenMovesRevoked(_ fixture: CaptureFixture) async throws {
        localMove(fixture, x: 20)
        fixture.manager.handleVideoMouseScroll(deltaX: 0, deltaY: 1)
        localMove(fixture, x: 40)
        // The first wheel freezes scheduled move1; the second captures pending move2.
        fixture.manager.handleVideoMouseScroll(deltaX: 0, deltaY: 1)
        fixture.keyWindow = fixture.otherWindow
        try await sentinelAndDisconnect(fixture)
    }

    @MainActor private static func testKeyAndWheelRevoked(_ fixture: CaptureFixture) async throws {
        NSApp.sendEvent(fixture.event())
        fixture.manager.handleVideoMouseScroll(deltaX: 0, deltaY: 1)
        fixture.keyWindow = fixture.otherWindow
        try await sentinelAndDisconnect(fixture)
    }

    @MainActor private static func testQueuedInputsDisconnected(_ fixture: CaptureFixture) async throws {
        localMove(fixture, x: 20)
        localMove(fixture, x: 40)
        NSApp.sendEvent(fixture.event())
        fixture.manager.handleVideoMouseScroll(deltaX: 0, deltaY: 1)
        await fixture.manager.disconnectInputForSession()
    }

    @MainActor private static func testHeadlessRefreshDoesNotReleaseAgain(_ fixture: CaptureFixture) async throws {
        fixture.manager.setLocalInputCaptureAllowed(false)
        let owner = UUID()
        fixture.manager.setLocalInputCaptureAllowed(false)
        fixture.manager.setLocalUIBlocked(true, owner: owner)
        fixture.manager.setLocalUIBlocked(false, owner: owner)
        fixture.manager.setConnectionTransitioning(true)
        fixture.manager.setConnectionTransitioning(false)
        fixture.manager.setSessionAvailable(true)
        fixture.manager.refreshLocalInputFocus()
        try await sentinelAndDisconnect(fixture)
    }

    private static func verify(name: String, events: [RecordedHIDEvent]) throws {
        try expect(events.map(\.seq) == events.indices.map { $0 + 1 }, "Recorded sequence is missing or unordered: \(events)")
        let hid = events.filter { $0.type != "json" }
        let moves = hid.filter { $0.type == "move" }
        let sentinelMoves = moves.filter { $0.x == 1234 && $0.y == 5678 }
        if name == "actual WebSocket dispatch" {
            try expect(moves.count == 3 && sentinelMoves.count == 1, "Scheduled/captured moves and sentinel must all dispatch: \(hid)")
            try expect(hid.contains { $0.type == "key" && $0.key == "KeyX" && $0.state == true }, "Actual KeyX down missing: \(hid)")
            try expect(hid.contains { $0.type == "key" && $0.key == "KeyX" && $0.state == false }, "Actual KeyX up missing: \(hid)")
            try expect(hid.filter { $0.type == "wheel" }.count == 2, "Actual local wheels missing: \(hid)")
        } else if name == "queued inputs invalidated by disconnect" {
            try expect(!hid.isEmpty && hid.allSatisfy { isCleanup($0) }, "Disconnect must emit only HID cleanup: \(hid)")
        } else {
            try expect(moves.count == 1 && sentinelMoves.count == 1, "Only sentinel move may dispatch after revoke: \(hid)")
            try expect(hid.allSatisfy { isCleanup($0) || $0.type == "move" || ($0.type == "button" && $0.button == "left") },
                       "Revoked local key/wheel must not reach WebSocket: \(hid)")
            try expect(hid.filter { $0.type == "button" && $0.state == true }.count == 1,
                       "Only sentinel may press a mouse button: \(hid)")
        }
        if name == "headless false-to-false emits no extra release" {
            try expect(hid.filter { $0.type == "key" && $0.key == "" && $0.state == false }.count == 2,
                       "Exactly one initial revoke and one disconnect clear expected: \(hid)")
        }
    }

    private static func isCleanup(_ event: RecordedHIDEvent) -> Bool {
        event.state == false && ((event.type == "key" && event.key == "") || event.type == "button")
    }
}
