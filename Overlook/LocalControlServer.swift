import Foundation
import Network

@MainActor
final class LocalControlServer: ObservableObject {
    @Published private(set) var status = "Control API stopped"
    private var listener: NWListener?
    private weak var inputManager: InputManager?
    private let token = UUID().uuidString
    private let tokenURL = URL(fileURLWithPath: "/tmp/overlook-control-token")

    func start(inputManager: InputManager) {
        self.inputManager = inputManager
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 17891)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self, token] connection in
                self?.handle(connection, token: token)
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
            try token.write(to: tokenURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        } catch {
            status = "Control API error: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        status = "Control API stopped"
        try? FileManager.default.removeItem(at: tokenURL)
    }

    nonisolated private func handle(_ connection: NWConnection, token: String) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, accumulated: Data(), token: token)
    }

    nonisolated private func receiveRequest(_ connection: NWConnection, accumulated: Data, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= 1_048_576 else { connection.cancel(); return }
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
        do {
            switch command {
            case "status":
                return ["ok": true, "status": inputManager.activityStatus, "error": inputManager.lastInputError as Any]
            case "text":
                guard let value = request["value"] as? String, value.utf8.count <= 262_144 else {
                    return ["ok": false, "error": "text missing or too large"]
                }
                try await inputManager.sendTextToRemote(value)
            case "click":
                guard let x = request["x"] as? Int, let y = request["y"] as? Int else {
                    return ["ok": false, "error": "coordinates missing"]
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
