import Foundation
import Network

@MainActor
final class LocalControlServer: ObservableObject {
    private static let maximumConnections = 4
    private static let maximumTextBytes = 256 * 1024
    private static let coordinateRange = -32_767...32_767

    @Published private(set) var status = "Control API stopped"
    private var listener: NWListener?
    private weak var inputManager: InputManager?
    private var token = UUID().uuidString
    private let connectionLimiter = ConnectionLimiter(limit: maximumConnections)
    private var commandGate: @MainActor () -> Bool = { false }
    private lazy var tokenDirectoryURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlook", isDirectory: true)
            .appendingPathComponent("Control", isDirectory: true)
    }()
    private lazy var tokenURL = tokenDirectoryURL.appendingPathComponent("control-token")

    /// Sets the policy for commands which change remote input. The app should
    /// enable this policy only while an exclusive Headless session is active.
    func setCommandGate(_ gate: @escaping @MainActor () -> Bool) {
        commandGate = gate
    }

    func start(inputManager: InputManager) {
        self.inputManager = inputManager
        guard listener == nil else { return }
        token = UUID().uuidString
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 17891)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self, token] connection in
                guard let self, let lease = self.connectionLimiter.acquire() else {
                    connection.cancel()
                    return
                }
                self.handle(connection, token: token, lease: lease)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.status = "Control API ready on 127.0.0.1:17891"
                    case .failed(let error): self?.status = "Control API error: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            try FileManager.default.createDirectory(
                at: tokenDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tokenDirectoryURL.path)
            try token.write(to: tokenURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        } catch {
            listener?.cancel()
            listener = nil
            try? FileManager.default.removeItem(at: tokenURL)
            status = "Control API error: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        status = "Control API stopped"
        try? FileManager.default.removeItem(at: tokenURL)
    }

    nonisolated private func handle(_ connection: NWConnection, token: String, lease: ConnectionLease) {
        let timeout = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                timeout.cancel()
                lease.release()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, accumulated: Data(), token: token)
    }

    nonisolated private func receiveRequest(_ connection: NWConnection, accumulated: Data, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= 512 * 1024 else { connection.cancel(); return }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let request = Data(buffer[..<newline])
                Task { @MainActor in
                    let response = await self?.process(request, token: token) ?? ["ok": false, "error": "server unavailable"]
                    let output = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"ok\":false}".utf8)
                    connection.send(content: output + Data([0x0A]), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if isComplete {
                connection.cancel()
            } else {
                self?.receiveRequest(connection, accumulated: buffer, token: token)
            }
        }
    }

    private func process(_ data: Data, token: String) async -> [String: Any] {
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = request["command"] as? String,
              let inputManager else { return ["ok": false, "error": "invalid request"] }
        guard request["token"] as? String == token else { return ["ok": false, "error": "unauthorized"] }
        if command != "status", !commandGate() {
            return ["ok": false, "error": "remote control is not enabled for the current mode"]
        }
        do {
            switch command {
            case "status":
                var response: [String: Any] = ["ok": true, "status": inputManager.activityStatus]
                if let error = inputManager.lastInputError { response["error"] = error }
                return response
            case "text":
                guard let value = request["value"] as? String, value.utf8.count <= Self.maximumTextBytes else {
                    return ["ok": false, "error": "text missing or too large"]
                }
                try await inputManager.sendTextToRemote(value)
            case "click":
                guard let x = request["x"] as? Int, let y = request["y"] as? Int else {
                    return ["ok": false, "error": "coordinates missing"]
                }
                guard Self.coordinateRange.contains(x), Self.coordinateRange.contains(y) else {
                    return ["ok": false, "error": "coordinates out of range"]
                }
                try await inputManager.sendCodexClick(signedX: x, signedY: y)
            default:
                return ["ok": false, "error": "unsupported command"]
            }
            return ["ok": true]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}

private final class ConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var activeConnections = 0

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() -> ConnectionLease? {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < limit else { return nil }
        activeConnections += 1
        return ConnectionLease { [weak self] in self?.release() }
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        activeConnections = max(0, activeConnections - 1)
    }
}

private final class ConnectionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (() -> Void)?

    init(releaseAction: @escaping () -> Void) {
        self.releaseAction = releaseAction
    }

    func release() {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        release()
    }
}
