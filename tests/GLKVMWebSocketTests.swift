import Foundation
import Darwin

struct KVMDevice {
    let host: String
    let port: Int
    let authToken: String
}

@main
struct GLKVMWebSocketTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2, let port = UInt16(CommandLine.arguments[1]), port != 17891 else {
            throw TestFailure.fixturePortRequired
        }
        var failures: [String] = []
        for path in ["events", "quiet"] {
            let session = URLSession(configuration: .ephemeral)
            let socket = GLKVMClient.WebSocketClient(
                session: session,
                request: URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/\(path)")!)
            )
            await socket.connect()
            if path == "quiet" {
                try await socket.send(eventType: "ping")
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !(await socket.isConnected), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let connected = await socket.isConnected
            let connecting = await socket.isConnecting
            await socket.disconnect()
            let connectedAfterClose = await socket.isConnected
            let connectingAfterClose = await socket.isConnecting
            let disconnected = !connectedAfterClose && !connectingAfterClose
            session.invalidateAndCancel()
            if !connected || connecting || !disconnected {
                failures.append("\(path): readiness must follow a successful read-only transport exchange")
            }
        }
        for failure in failures { print("FAIL: \(failure)") }
        guard failures.isEmpty else { exit(1) }
        print("GLKVMWebSocketTests passed (receive, read-only ping, disconnect; no HID)")
    }

    enum TestFailure: Error { case fixturePortRequired }
}
