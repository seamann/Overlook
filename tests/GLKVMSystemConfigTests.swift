import Foundation

struct KVMDevice {
    let host: String
    let port: Int
    let authToken: String
}

@main
struct GLKVMSystemConfigTests {
    private static let fixtureLoginPassword = "fixture-password"
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
        var failedContracts = 0
        do { try testLosslessConfigContract() } catch { failedContracts += 1 }
        do { try await testLoginContract() } catch { failedContracts += 1 }
        do { try await testHIDReadbackContract() } catch { failedContracts += 1 }
        do { try testConfigEditContract() } catch { failedContracts += 1 }
        guard failedContracts == 0 else { throw ContractFailure.regressions(failedContracts) }
        print("GLKVMSystemConfigTests passed")
    }

    private static func testLosslessConfigContract() throws {
        let cases = [
            "{}",
            #"{"mouse_jiggle":true,"future":{"text":"Grüße 🖱️","flags":[true,null,17,2.5]},"show_cursor":"firmware-value","shortcuts":[{"keys":["Ctrl"],"label":"Test","new_option":true}]}"#,
            #"{"orientation":0,"show_cursor":false,"keymap":"de","future":null}"#,
        ]
        var failures: [String] = []
        for (index, payload) in cases.enumerated() {
            let data = Data(payload.utf8)
            let original = try JSONDecoder().decode(GLKVMJSONObject.self, from: data)
            let config = try JSONDecoder().decode(GLKVMSystemConfig.self, from: data)
            let roundtrip = try JSONDecoder().decode(GLKVMJSONObject.self, from: JSONEncoder().encode(config))
            if original != roundtrip { failures.append("lossless roundtrip \(index)") }
        }
        for payload in [#"{"mouse_jiggle":"true"}"#, #"{"mouse_jiggle":null}"#, #"{"mouse_jiggle":1}"#] {
            do {
                _ = try JSONDecoder().decode(GLKVMSystemConfig.self, from: Data(payload.utf8))
                failures.append("invalid present jiggler accepted")
            } catch {}
        }
        var edited = try JSONDecoder().decode(GLKVMSystemConfig.self, from: Data("{}".utf8))
        edited.keymap = "de"
        let changed = try JSONDecoder().decode(GLKVMJSONObject.self, from: JSONEncoder().encode(edited))
        if changed != ["keymap": .string("de")] { failures.append("edit inserted untouched default fields") }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        guard failures.isEmpty else { throw ContractFailure.regressions(failures.count) }
        print("Lossless config contract: \(cases.count + 4) scenarios passed")
    }

    private static func testConfigEditContract() throws {
        let decoder = JSONDecoder()
        let baseline = try decoder.decode(GLKVMSystemConfig.self, from: Data("{}".utf8))
        var draft = baseline
        draft.shortcuts = [GLKVMSystemConfigShortcut(keys: ["Ctrl", "Enter"], label: "Grüße 🖱️")]
        draft.orientation = 90
        draft.streamQuality = 3
        draft.videoMode = "stream"
        draft.showCursor = false
        draft.mousePolling = 20
        draft.mouseControl = false
        draft.relativeSense = 20
        draft.scrollRate = 10
        draft.reverseScrolling = "REVERSED"
        draft.keyboardControl = false
        draft.themeMode = "dark"
        draft.keymap = "de"
        draft.gotMutedPanelTip = true
        draft.isAbsoluteMouse = false
        draft.fingerbotStrength = 4
        draft.videoProcessing = "low_latency_first"
        let expected = try decoder.decode(GLKVMJSONObject.self, from: Data(#"{"shortcuts":[{"keys":["Ctrl","Enter"],"label":"Grüße 🖱️"}],"orientation":90,"stream_quality":3,"video_mode":"stream","show_cursor":false,"mouse_polling":20,"mouse_control":false,"relative_sense":20,"scroll_rate":10,"reverse_scrolling":"REVERSED","keyboard_control":false,"theme_mode":"dark","keymap":"de","got_muted_panel_tip":true,"is_absolute_mouse":false,"fingerbot_strength":4,"video_processing":"low_latency_first"}"#.utf8))
        guard draft.settingsEditKeys(relativeTo: baseline) == Set(expected.keys) else { throw ContractFailure.regressions(1) }
        let actual = try decoder.decode(GLKVMJSONObject.self, from: JSONEncoder().encode(draft))
        guard actual == expected else { throw ContractFailure.regressions(1) }
        let unchanged = try decoder.decode(GLKVMJSONObject.self, from: JSONEncoder().encode(baseline))
        guard unchanged.isEmpty else { throw ContractFailure.regressions(1) }

        let fresh = try decoder.decode(GLKVMSystemConfig.self, from: Data(#"{"keymap":"fr","mouse_jiggle":true,"stream_quality":3,"future":null}"#.utf8))
        let unchangedMerge = try fresh.mergingSettingsEdits(from: baseline, editedFields: baseline.settingsEditKeys(relativeTo: baseline))
        let unchangedPayload = try decoder.decode(GLKVMJSONObject.self, from: JSONEncoder().encode(unchangedMerge))
        let freshPayload = try decoder.decode(GLKVMJSONObject.self, from: JSONEncoder().encode(fresh))
        guard unchangedPayload == freshPayload else { throw ContractFailure.regressions(1) }
        var jigglerOnly = fresh
        jigglerOnly.mouseJiggle = false
        let protected = try fresh.mergingSettingsEdits(from: jigglerOnly, editedFields: ["mouse_jiggle"])
        guard protected.mouseJiggle else { throw ContractFailure.regressions(1) }

        let large: GLKVMJSONObject = ["unknown_entries": .array((0..<10_000).map { .object(["value": .int($0)]) })]
        let largeData = try JSONEncoder().encode(large)
        let largeConfig = try decoder.decode(GLKVMSystemConfig.self, from: largeData)
        let largeRoundtrip = try decoder.decode(GLKVMJSONObject.self, from: JSONEncoder().encode(largeConfig))
        guard largeRoundtrip == large else { throw ContractFailure.regressions(1) }
        print("Config edit contract: all 17 settings, unchanged/protected merge and 10k unknown entries passed")
    }

    private static func testHIDReadbackContract() async throws {
        let cases: [(String, Bool?)] = [
            ("hid-off", false), ("hid-on", true), ("hid-missing", nil),
            ("hid-missing-active", nil), ("hid-null", nil), ("hid-string", nil),
            ("hid-number", nil), ("hid-disabled-active", true),
        ]
        var failures = 0
        for (scenario, expected) in cases {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [GLKVMResponseFixtureProtocol.self]
            let client = try GLKVMClient(host: "\(scenario).invalid", allowInsecureTLS: false, sessionConfiguration: config)
            do {
                let result = try await client.getHIDJigglerState()
                if result != expected { failures += 1 }
            } catch GLKVMClient.ClientError.decodingFailed {
                if expected != nil { failures += 1 }
            } catch { failures += 1 }
        }
        guard failures == 0 else { throw ContractFailure.regressions(failures) }
        print("HID daemon contract: \(cases.count) strict boolean scenarios passed")
    }

    private static func testLoginContract() async throws {
        let cases: [(String, String?)] = [
            ("login-token", nil), ("login-cookie", nil),
            ("login-reject-token", "requestRejected"),
            ("login-reject-cookie", "requestRejected"),
            ("login-reject-empty", "requestRejected"),
            ("login-http-error", "httpError(403)"),
            ("login-malformed", "decodingFailed"),
            ("login-invalid-ok-cookie", "decodingFailed"),
            ("login-empty-cookie", "decodingFailed"),
            ("login-transport-error", "transportFailed"),
        ]
        var failures: [String] = []
        for (scenario, expected) in cases {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GLKVMResponseFixtureProtocol.self]
            configuration.httpCookieStorage = nil
            let client = try GLKVMClient(host: "\(scenario).invalid", allowInsecureTLS: false, sessionConfiguration: configuration)
            do {
                let token = try await client.authLogin(password: fixtureLoginPassword)
                if expected != nil || token != "fixture-token" { failures.append("\(scenario): unexpected login success") }
            } catch {
                if String(describing: error) != expected { failures.append("\(scenario): wrong error category") }
            }
        }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        guard failures.isEmpty else { throw ContractFailure.regressions(failures.count) }
        print("Login contract: \(cases.count) scenarios passed; synthetic credentials only")
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
        if scenario == "transport-error" || scenario == "login-transport-error" {
            let error = URLError(.timedOut, userInfo: [
                NSLocalizedDescriptionKey: "synthetic-secret transport detail",
                NSURLErrorFailingURLErrorKey: URL(string: "https://synthetic-secret.invalid/private")!,
            ])
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let payload = Self.payload(for: scenario)
        var headers = ["Content-Type": "application/json"]
        if scenario.contains("cookie") { headers["Set-Cookie"] = scenario == "login-empty-cookie" ? "auth_token=; Path=/" : "auth_token=fixture-token; Path=/" }
        let response = HTTPURLResponse(
            url: url, statusCode: scenario.contains("http-error") ? 403 : 200,
            httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func payload(for scenario: String) -> String {
        switch scenario {
        case "hid-off": return #"{"ok":true,"result":{"jiggler":{"enabled":true,"active":false,"interval":20}}}"#
        case "hid-on": return #"{"ok":true,"result":{"jiggler":{"enabled":true,"active":true}}}"#
        case "hid-missing": return #"{"ok":true,"result":{}}"#
        case "hid-missing-active": return #"{"ok":true,"result":{"jiggler":{"enabled":true}}}"#
        case "hid-null": return #"{"ok":true,"result":{"jiggler":{"active":null}}}"#
        case "hid-string": return #"{"ok":true,"result":{"jiggler":{"active":"false"}}}"#
        case "hid-number": return #"{"ok":true,"result":{"jiggler":{"active":0}}}"#
        case "hid-disabled-active": return #"{"ok":true,"result":{"jiggler":{"enabled":false,"active":true}}}"#
        case "login-token": return #"{"ok":true,"result":{"token":"fixture-token"}}"#
        case "login-invalid-ok-cookie": return #"{"ok":"true"}"#
        case "login-empty-cookie": return #"{"ok":true}"#
        case "login-cookie": return #"{"ok":true}"#
        case "login-reject-token": return #"{"ok":false,"result":{"token":"fixture-token"}}"#
        case "login-reject-cookie", "login-reject-empty": return #"{"ok":false}"#
        case "login-http-error": return #"{"ok":false,"result":{"token":"fixture-token"}}"#
        case "login-malformed": return "invalid response"
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

private enum ContractFailure: Error { case regressions(Int) }
