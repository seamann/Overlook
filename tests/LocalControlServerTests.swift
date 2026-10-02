import Foundation
import Darwin
import ImageIO

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw FixtureFailure(description: message) }
}

// A real loopback TCP client. Socket I/O runs off MainActor and has a fixed
// deadline; the only address it can use is the fixture listener's 127.0.0.1.
private final class FixtureSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var sentRequest = false
    private var connected = false
    private let beforeSend: DispatchSemaphore?

    init(pauseBeforeSend: Bool = false) {
        beforeSend = pauseBeforeSend ? DispatchSemaphore(value: 0) : nil
    }

    var didConnect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    func resumeSending() { beforeSend?.signal() }

    var didSendRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sentRequest
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) }
    }

    func exchange(port: UInt16, payload: Data) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureFailure(description: "fixture socket failed") }
        lock.lock()
        descriptor = fd
        lock.unlock()
        defer {
            lock.lock()
            descriptor = -1
            _ = close(fd)
            lock.unlock()
        }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw FixtureFailure(description: "fixture connect failed") }
        lock.lock()
        self.connected = true
        lock.unlock()
        if let beforeSend, beforeSend.wait(timeout: .now() + 3) != .success {
            throw FixtureFailure(description: "fixture pre-send barrier timed out")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var sent = 0
        while sent < payload.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = payload.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: sent), payload.count - sent, 0) }
            guard count > 0 else { throw FixtureFailure(description: "fixture send failed") }
            sent += count
        }
        lock.lock()
        sentRequest = true
        lock.unlock()
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while output.count <= 8 * 1024 * 1024 {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { throw FixtureFailure(description: "fixture peer closed") }
            output.append(contentsOf: bytes.prefix(count))
            if let newline = output.firstIndex(of: 0x0A) { return Data(output[..<newline]) }
        }
        throw FixtureFailure(description: "fixture response too large")
    }

    private func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw FixtureFailure(description: "fixture deadline exceeded") }
        var item = pollfd(fd: fd, events: events, revents: 0)
        guard poll(&item, 1, Int32(max(1, remaining * 1000))) > 0 else {
            throw FixtureFailure(description: "fixture socket timed out")
        }
    }
}

@MainActor
private final class ServerFixture {
    let input = InputManager()
    let video = WebRTCManager()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlook-control-tests-" + UUID().uuidString)
    var mode = ControlModeSnapshot(mode: .codexHeadless, generation: 1)
    private(set) var server: LocalControlServer!
    private var token = ""

    func start() async throws {
        server = LocalControlServer(port: 0, controlDirectoryURL: directory)
        server.setModeProvider { [unowned self] in self.mode }
        server.setSnapshotProvider(video)
        server.start(inputManager: input)
        try await until("fixture listener ready") { self.server.listeningPort != nil }
        token = try String(contentsOf: directory.appendingPathComponent("control-token"), encoding: .utf8)
        try expect(server.listeningPort != 17891, "test must never use the live control port")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("control-token").path)
        try expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600, "fixture token mode600")
    }

    func stop() {
        input.cleanup.release()
        video.captureBarrier?.release()
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func request(_ fields: [String: Any], socket: FixtureSocket = FixtureSocket()) async throws -> [String: Any] {
        var body = fields
        body["token"] = token
        return try await raw(JSONSerialization.data(withJSONObject: body) + Data([0x0A]), socket: socket)
    }

    func raw(_ payload: Data, socket: FixtureSocket = FixtureSocket()) async throws -> [String: Any] {
        guard let port = server.listeningPort else { throw FixtureFailure(description: "fixture port missing") }
        let data = try await Task.detached { try socket.exchange(port: port, payload: payload) }.value
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureFailure(description: "fixture response not an object")
        }
        return result
    }

    func observe() async throws -> [String: Any] { try await request(["command": "observe"]) }

    func action(_ frame: [String: Any], sequence: Int? = nil, value: [String: Any] = ["type": "click", "x": 3, "y": 4]) -> [String: Any] {
        ["command": "act", "session_id": frame["session_id"]!,
         "action_seq": sequence ?? (frame["next_action_seq"] as! Int), "frame_id": frame["frame_id"]!, "action": value]
    }

    func reference(_ request: [String: Any], command: String) -> [String: Any] {
        ["command": command, "session_id": request["session_id"]!, "action_seq": request["action_seq"]!]
    }
}

@MainActor
private func until(_ label: String, _ predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureFailure(description: label + " timed out") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@main
struct LocalControlServerTests {
    @MainActor
    static func main() async throws {
        let groups: [(String, @MainActor (ServerFixture) async throws -> Void)] = [
            ("manual status, native PNG, crop and authorization", observation),
            ("one dispatch, duplicate replay, conflict and malformed action", identity),
            ("legacy invalidates completed and in-flight observation", legacyInvalidation),
            ("cancel retains gate until cleanup; queued input waits", cancellation),
            ("failed cleanup blocks queued input", failedCleanup),
            ("lost reply replay never dispatches twice", lostReply),
            ("source, transport, mode and endpoint changes", sessionChanges),
            ("expired frame cannot dispatch", expiredFrame),
        ]
        for (name, test) in groups {
            let fixture = ServerFixture()
            do {
                try await fixture.start()
                try await test(fixture)
                fixture.stop()
                print("PASS: " + name)
            } catch {
                fixture.stop()
                throw FixtureFailure(description: name + ": " + String(describing: error))
            }
        }
        print("LocalControlServerTests: 8 integration groups passed (real loopback TCP; fake input/video; no app or remote HID)")
    }

    @MainActor
    private static func observation(_ f: ServerFixture) async throws {
        f.mode = ControlModeSnapshot(mode: .manual, generation: 2)
        f.input.isLocalInputCaptureAllowed = true
        let status = try await f.request(["command": "status"])
        try expect(status["mode"] as? String == "manual" && status["protocol_version"] as? Int == 2, "manual status protocol")
        try expect(status["controlEndpointID"] == nil && status["snapshotEndpointID"] == nil, "status must not expose endpoint IDs")
        let full = try await f.observe()
        try png(full, width: 32, height: 24)
        try expect(full["width"] as? Int == 32 && full["height"] as? Int == 24 && full["scale"] as? Int == 1, "native frame geometry")
        let crop = try await f.request(["command": "observe", "region": ["x": 7, "y": 5, "width": 9, "height": 6]])
        try png(crop, width: 9, height: 6)
        try expect((crop["region"] as? [String: Int]) == ["x": 7, "y": 5, "width": 9, "height": 6], "crop coordinates preserved")
        try expect(full["frame_id"] as? String != crop["frame_id"] as? String, "observation frame identity")
        try error(try await f.request(f.action(crop)), "headless_required")
        try error(try await f.request(["command": "observe", "region": ["x": true, "y": 0, "width": 1, "height": 1]]), "invalid_request")
        try error(try await f.raw(Data("{\"command\":\"status\",\"token\":\"invalid-fixture-token\"}\n".utf8)), "unauthorized")
        try error(try await f.raw(Data("{broken\n".utf8)), "invalid_request")
        try expect(f.input.dispatched.isEmpty, "readonly/manual requests cannot dispatch")
    }

    @MainActor
    private static func identity(_ f: ServerFixture) async throws {
        let frame = try await f.observe()
        let request = f.action(frame)
        try state(try await f.request(request), "transmitted")
        try state(try await f.request(request), "transmitted")
        try expect(f.input.dispatched.count == 1, "duplicate click dispatched twice")
        try error(try await f.request(f.action(frame, value: ["type": "text", "value": "different fixture"])), "action_conflict")
        let next = try await f.observe()
        try state(try await f.request(f.action(next, value: ["type": "text", "value": "fixture text"])), "transmitted")
        try expect(f.input.dispatched == [.click(x: 3, y: 4), .text("fixture text")], "one click and one text dispatch")
        let stale = try await f.request(f.action(next, sequence: 3))
        try state(stale, "not_started", code: "stale_frame")
        let fresh = try await f.observe()
        try error(try await f.request(f.action(fresh, value: ["type": "click", "x": true, "y": 1])), "invalid_request")
        try error(try await f.request(f.action(fresh, value: ["type": "text", "value": "x", "extra": 1])), "invalid_request")
        try state(try await f.request(f.action(fresh, value: ["type": "click", "x": 32, "y": 1])), "not_started", code: "invalid_request")
        try expect(f.input.dispatched.count == 2, "invalid/stale actions cannot dispatch")
    }

    @MainActor
    private static func legacyInvalidation(_ f: ServerFixture) async throws {
        let frame = try await f.observe()
        let legacy = try await f.request(["command": "text", "value": "fixture legacy"])
        try expect(legacy["ok"] as? Bool == true, "legacy text accepted")
        try state(try await f.request(f.action(frame)), "not_started", code: "stale_frame")
        let barrier = FixtureLatch()
        f.video.captureBarrier = barrier
        let count = f.video.captureCount
        let pending = Task { try await f.observe() }
        try await until("in-flight capture") { f.video.captureCount > count }
        _ = try await f.request(["command": "click", "x": -123, "y": 234])
        barrier.release()
        try error(try await pending.value, "session_changed")
        try expect(f.input.dispatched.count == 2, "legacy paths each dispatch once")
    }

    @MainActor
    private static func cancellation(_ f: ServerFixture) async throws { try await cancellationCase(f, cleanupFails: false) }

    @MainActor
    private static func failedCleanup(_ f: ServerFixture) async throws { try await cancellationCase(f, cleanupFails: true) }

    @MainActor
    private static func cancellationCase(_ f: ServerFixture, cleanupFails: Bool) async throws {
        f.input.waitForCancellation = true
        f.input.cleanupFails = cleanupFails
        let action = f.action(try await f.observe())
        let pending = Task { try await f.request(action) }
        try await until("click dispatch") { f.input.dispatched.count == 1 }
        try error(try await f.observe(), "snapshot_busy")
        _ = try await f.request(f.reference(action, command: "cancel"))
        try await until("cleanup starts") { f.input.cleanupStarted }
        let queuedSocket = FixtureSocket()
        var queuedFinished = false
        let queued = Task {
            defer { queuedFinished = true }
            return try await f.request(["command": "text", "value": "queued fixture"], socket: queuedSocket)
        }
        try await until("queued text sent") { queuedSocket.didSendRequest }
        // The control service remains responsive while release is parked.
        // Give the already-sent input request time to reach its mutation gate.
        try await Task.sleep(nanoseconds: 30_000_000)
        try state(try await f.request(f.reference(action, command: "action_status")), "running")
        try error(try await f.observe(), "snapshot_busy")
        try expect(!queuedFinished && !f.input.cleanupCompleted && f.input.dispatched.count == 1, "gate released before cleanup")
        f.input.cleanup.release()
        try state(try await pending.value, "outcome_unknown", code: cleanupFails ? "cleanup_failed" : "cancelled")
        let result = try await queued.value
        if cleanupFails {
            try error(result, "input_blocked")
            try expect(f.input.inputBlocked && f.input.dispatched.count == 1, "failed cleanup must block queued text")
        } else {
            try expect(result["ok"] as? Bool == true && f.input.dispatched.count == 2, "queued text proceeds only after cleanup")
        }
        try state(try await f.request(action), "outcome_unknown")
        try expect(f.input.dispatched.count == (cleanupFails ? 1 : 2), "cancelled action replay cannot redispatch")
    }

    @MainActor
    private static func lostReply(_ f: ServerFixture) async throws {
        f.input.waitForCancellation = true
        let request = f.action(try await f.observe())
        let socket = FixtureSocket()
        let pending = Task { try await f.request(request, socket: socket) }
        try await until("dispatch before connection loss") { f.input.dispatched.count == 1 }
        socket.disconnect()
        try await until("connection loss cleanup") { f.input.cleanupStarted }
        f.input.cleanup.release()
        _ = try? await pending.value
        await f.server.waitForMutationsToDrain()
        try state(try await f.request(request), "outcome_unknown", code: "cancelled")
        try expect(f.input.dispatched.count == 1, "lost reply replay dispatched twice")
    }

    @MainActor
    private static func sessionChanges(_ f: ServerFixture) async throws {
        let oldSource = try await f.observe()
        f.video.snapshotSourceID = "reconnected-fixture-source"
        try error(try await f.request(f.action(oldSource)), "session_changed")
        let oldInput = try await f.observe()
        f.input.transportID = "reconnected-fixture-input"
        try error(try await f.request(f.action(oldInput)), "session_changed")
        let current = try await f.observe()
        let action = f.action(current)
        try state(try await f.request(action), "transmitted")
        f.mode = ControlModeSnapshot(mode: .manual, generation: 2)
        f.input.isLocalInputCaptureAllowed = true
        try state(try await f.request(f.reference(action, command: "action_status")), "transmitted")
        try state(try await f.request(f.reference(action, command: "cancel")), "transmitted")
        f.mode = ControlModeSnapshot(mode: .codexHeadless, generation: 3)
        f.input.isLocalInputCaptureAllowed = false
        let beforeVideoLoss = try await f.observe()
        f.video.snapshotReady = false
        try state(try await f.request(f.action(beforeVideoLoss)), "not_started", code: "input_unavailable")
        f.video.snapshotReady = true
        let beforeMismatch = try await f.observe()
        f.video.snapshotEndpointID = "different-fixture-endpoint"
        let status = try await f.request(["command": "status"])
        let readiness = status["readiness"] as? [String: Bool]
        try expect(readiness?["text"] == false && readiness?["mouse"] == false, "mismatched endpoint input readiness")
        try error(try await f.observe(), "input_unavailable")
        try state(try await f.request(f.action(beforeMismatch)), "not_started", code: "input_unavailable")
        try expect(f.input.dispatched.count == 1, "stale session or endpoint mismatch cannot dispatch")
        f.video.snapshotEndpointID = f.input.controlEndpointID
        let socket = FixtureSocket(pauseBeforeSend: true)
        let oldAuthority = Task { try await f.request(["command": "text", "value": "revoked fixture"], socket: socket) }
        try await until("pre-stop socket connected") { socket.didConnect }
        try await Task.sleep(nanoseconds: 30_000_000)
        f.server.stop()
        socket.resumeSending()
        do {
            try error(try await oldAuthority.value, "unauthorized")
        } catch let failure as FixtureFailure where failure.description == "fixture peer closed" {
            // Closing an already-accepted old-authority connection is safe too.
        }
        try expect(f.input.dispatched.count == 1, "pre-stop socket must not retain input authority")
    }

    @MainActor
    private static func expiredFrame(_ f: ServerFixture) async throws {
        f.video.frameAge = 31
        let expired = try await f.observe()
        try expect((expired["frame_age_ms"] as? Double ?? 0) >= 31_000, "fixture frame is expired")
        try state(try await f.request(f.action(expired)), "not_started", code: "stale_frame")
        try expect(f.input.dispatched.isEmpty, "expired frame cannot dispatch")
    }

    private static func error(_ response: [String: Any], _ code: String) throws {
        try expect(response["ok"] as? Bool == false && response["error_code"] as? String == code, "expected safe error " + code)
    }

    private static func state(_ response: [String: Any], _ phase: String, code: String? = nil) throws {
        try expect(response["ok"] as? Bool == true && response["state"] as? String == phase, "expected action state " + phase)
        if let code { try expect(response["error_code"] as? String == code, "expected action error " + code) }
    }

    private static func png(_ response: [String: Any], width: Int, height: Int) throws {
        guard response["ok"] as? Bool == true, response["mime_type"] as? String == "image/png",
              let base64 = response["image_base64"] as? String, let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureFailure(description: "response must contain decodable PNG")
        }
        try expect(image.width == width && image.height == height, "PNG has original/cropped pixel dimensions")
    }
}
