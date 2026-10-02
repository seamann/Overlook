import Foundation

struct KVMDevice {
    let host: String
    let port: Int
    let authToken: String
}

@main
struct GLKVMSystemConfigTests {
    static func main() async throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let supported = try decoder.decode(
            GLKVMSystemConfig.self,
            from: Data(#"{"mouse_jiggle":true}"#.utf8)
        )
        precondition(supported.supportsMouseJiggle)
        precondition(supported.mouseJiggle)

        let supportedPayload = try jsonObject(from: encoder.encode(supported))
        precondition(supportedPayload["mouse_jiggle"] as? Bool == true)
        precondition(supportedPayload["supportsMouseJiggle"] == nil)

        let unsupported = try decoder.decode(GLKVMSystemConfig.self, from: Data("{}".utf8))
        precondition(!unsupported.supportsMouseJiggle)

        let unsupportedPayload = try jsonObject(from: encoder.encode(unsupported))
        precondition(unsupportedPayload["mouse_jiggle"] == nil)

        let printQuery = GLKVMHIDPrintRequestPolicy.query(
            keymap: "de",
            limit: 0,
            slow: nil
        )
        precondition(printQuery.contains(URLQueryItem(name: "keymap", value: "de")))
        precondition(printQuery.contains(URLQueryItem(name: "limit", value: "0")))
        precondition(GLKVMHIDPrintRequestPolicy.contentType == "text/plain; charset=utf-8")

        try await testResponseContract()
        print("GLKVMSystemConfigTests passed")
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func testResponseContract() async throws {
        let cases: [(String, String, String?, (GLKVMClient) async throws -> Void)] = [
            ("text success", "accepted", nil, { try await $0.hidPrint(text: "synthetic text") }),
            ("shortcut success", "accepted", nil, { try await $0.sendHidShortcut(keys: ["Enter"]) }),
            ("text rejection", "rejected", "requestRejected", { try await $0.hidPrint(text: "synthetic text") }),
            ("shortcut rejection", "rejected", "requestRejected", { try await $0.sendHidShortcut(keys: ["Enter"]) }),
            ("rejection without result", "no-result", "requestRejected", { try await $0.authCheck() }),
            ("rejection detail is private", "private-detail", "requestRejected", { try await $0.authCheck() }),
            ("config success", "config", nil, {
                let config = try await $0.getSystemConfig()
                precondition(config.keymap == "de")
            }),
            ("config rejection", "rejected", "requestRejected", { _ = try await $0.getSystemConfig() }),
            ("HTTP rejection is private", "http-error", "httpError(403)", { try await $0.authCheck() }),
            ("malformed JSON", "malformed", "decodingFailed", { try await $0.authCheck() }),
            ("missing ok", "missing-ok", "decodingFailed", { try await $0.authCheck() }),
            ("nonboolean ok", "invalid-ok", "decodingFailed", { try await $0.authCheck() }),
            ("success requires result", "success-no-result", "decodingFailed", { try await $0.authCheck() }),
            ("transport error is private", "transport-error", "transportFailed", { try await $0.authCheck() }),
            ("task cancellation is preserved", "accepted", "CancellationError()", { client in
                let cancelled = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await client.authCheck()
                }
                try await cancelled.value
            }),
        ]
        var failures: [String] = []
        for (name, scenario, expectedError, operation) in cases {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [GLKVMResponseFixtureProtocol.self]
            let originalTimeout = config.timeoutIntervalForRequest
            let client = try GLKVMClient(
                host: "\(scenario).invalid", authToken: "synthetic-request-secret",
                allowInsecureTLS: false, sessionConfiguration: config
            )
            precondition(config.timeoutIntervalForRequest == originalTimeout)
            do {
                try await operation(client)
                if expectedError != nil { failures.append("\(name): unexpectedly succeeded") }
            } catch {
                let actual = String(describing: error)
                if actual != expectedError { failures.append("\(name): wrong error category") }
                if actual.contains("synthetic-secret") || error.localizedDescription.contains("synthetic-secret") {
                    failures.append("\(name): exposed response or transport detail")
                }
            }
        }
        for failure in failures {
            FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
        }
        precondition(failures.isEmpty, "GLKVM response contract regressions")
        let privateError = GLKVMClient.ClientError.httpError(statusCode: 403, body: "synthetic-secret")
        precondition(String(describing: privateError) == "httpError(403)")
        precondition(privateError.localizedDescription == "httpError(403)")
        print("GLKVM response contract: \(cases.count) scenarios passed (in-process fixtures)")
    }
}

private final class GLKVMResponseFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { preconditionFailure("Fixture needs a URL") }
        let scenario = url.host?.split(separator: ".").first.map(String.init) ?? ""
        if scenario == "transport-error" {
            let error = URLError(.timedOut, userInfo: [
                NSLocalizedDescriptionKey: "synthetic-secret transport detail",
                NSURLErrorFailingURLErrorKey: URL(string: "https://synthetic-secret.invalid/private")!,
            ])
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let payload = Self.payload(for: scenario)
        let response = HTTPURLResponse(
            url: url, statusCode: scenario == "http-error" ? 403 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func payload(for scenario: String) -> String {
        switch scenario {
        case "accepted": return #"{"ok":true,"result":{}}"#
        case "rejected": return #"{"ok":false,"result":{}}"#
        case "no-result": return #"{"ok":false}"#
        case "private-detail", "http-error":
            return #"{"ok":false,"result":{"error_msg":"synthetic-secret response detail"}}"#
        case "config": return #"{"ok":true,"result":{"config":{"keymap":"de"}}}"#
        case "malformed": return "synthetic-secret invalid JSON"
        case "missing-ok": return #"{"result":{}}"#
        case "invalid-ok": return #"{"ok":"true","result":{}}"#
        case "success-no-result": return #"{"ok":true}"#
        default: preconditionFailure("Unknown synthetic fixture")
        }
    }
}
