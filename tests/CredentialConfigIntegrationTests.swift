import Foundation

@main
struct CredentialConfigIntegrationTests {
    private static let currentFixtureToken = "fixture-current-token"
    @MainActor static func main() async throws {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("settings edit preserves fresh firmware fields", testFreshMerge),
            ("reverted setting survives an earlier pending write", testRevertedSettingDuringPendingWrite),
            ("invalid jiggler prevents Headless approval", testInvalidJiggler),
            ("Headless settings are rejected without HTTP", testLockedSettings),
            ("obsolete settings session is rejected", testObsoleteSession),
            ("disconnect during fresh GET prevents POST", testDisconnectDuringGET),
            ("Headless during fresh GET prevents POST", testHeadlessDuringGET),
            ("disconnect during sent POST cannot publish", testDisconnectDuringPOST),
            ("Keychain warning clears after secure retry", testSecureRetry),
            ("identical storage failures emit distinct warning events", testRepeatedStorageWarning),
            ("failed Keychain save keeps a new token in session only", testFailedPersistence),
            ("successful Keychain save stores no plaintext", testSuccessfulPersistence),
            ("empty token never invokes credential store", testEmptyPersistence),
            ("existing legacy records are not migrated on failed save", testLegacyPersistence),
            ("empty session token preserves existing legacy record", testEmptyLegacyPersistence),
        ]
        var failures: [String] = []
        for (name, test) in tests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)") }
        }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        guard failures.isEmpty else { throw Failure.message("\(failures.count) contract regressions") }
        print("CredentialConfigIntegrationTests: \(tests.count) scenarios passed; in-memory records and URLProtocol only")
    }

    @MainActor private static func testFreshMerge() async throws {
        let fixture = ConfigFixture(payload: #"{"keymap":"de","stream_quality":1,"mouse_jiggle":false,"future":{"mode":"old"}}"#)
        let client = try makeClient(fixture)
        let baseline = try await client.getSystemConfig()
        var draft = baseline
        draft.keymap = "en-us"
        fixture.setPayload(#"{"keymap":"de","stream_quality":3,"mouse_jiggle":true,"future":{"mode":"new"},"added_after_open":42}"#)
        let manager = KVMDeviceManager(startsServices: false, persistsConnections: false)
        manager.commitConnection(PreparedKVMConnection(device: device(fixture.host), client: client))
        let updated = try await manager.applySystemConfig(draft, editedFields: ["keymap"], connectionSessionID: manager.connectionSessionID!)
        let expected = try values(#"{"keymap":"en-us","stream_quality":3,"mouse_jiggle":false,"future":{"mode":"new"},"added_after_open":42}"#)
        try expect(fixture.postedPayloads.last == expected, "Full config POST overwrote newer firmware data")
        try expect(updated.streamQuality == 3, "Updated state lost fresh setting")
        try expect(!fixture.postedPayloads.contains { $0["mouse_jiggle"] == .bool(true) }, "Settings re-enabled the large firmware jiggler")
        manager.disconnectFromDevice()
    }

    @MainActor private static func testRevertedSettingDuringPendingWrite() async throws {
        let (manager, fixture, baseline) = try await settingsSetup()
        let id = manager.connectionSessionID!
        var firstDraft = baseline
        firstDraft.keymap = "en-us"
        fixture.holdNextPost()
        let first = Task { try await manager.applySystemConfig(firstDraft, editedFields: ["keymap"], connectionSessionID: id) }
        try await eventually { fixture.hasHeldRequest }
        let revertedDraft = baseline
        let second = Task { try await manager.applySystemConfig(revertedDraft, editedFields: ["keymap"], connectionSessionID: id) }
        fixture.release()
        _ = try await first.value
        let updated = try await second.value
        try expect(fixture.postedPayloads.count == 2, "Revert did not use both real POSTs")
        try expect(fixture.postedPayloads.last?["keymap"] == .string("de") && updated.keymap == "de", "Second user intent was lost after the pending write")
        manager.disconnectFromDevice()
    }

    @MainActor private static func testInvalidJiggler() async throws {
        let fixture = ConfigFixture(payload: #"{"mouse_jiggle":"true"}"#)
        let manager = KVMDeviceManager(startsServices: false, persistsConnections: false)
        manager.commitConnection(PreparedKVMConnection(device: device(fixture.host), client: try makeClient(fixture)))
        await manager.refreshMouseJigglerState()
        let owner = manager.beginHeadlessConfigurationTransition()
        defer { manager.endHeadlessConfigurationTransition(owner); manager.disconnectFromDevice() }
        do {
            try await manager.pauseMouseJigglerForHeadless()
            throw Failure.message("Invalid firmware value granted Headless safety approval")
        } catch is MouseJigglerError {} catch is GLKVMClient.ClientError {}
        try expect(fixture.postedPayloads.isEmpty, "Invalid config must not produce a firmware write")
    }

    @MainActor private static func testLockedSettings() async throws {
        let (manager, fixture, baseline) = try await settingsSetup()
        let owner = manager.beginHeadlessConfigurationTransition()
        defer { manager.endHeadlessConfigurationTransition(owner); manager.disconnectFromDevice() }
        do {
            _ = try await manager.applySystemConfig(baseline, editedFields: [], connectionSessionID: manager.connectionSessionID!)
            throw Failure.message("Locked settings unexpectedly succeeded")
        } catch MouseJigglerError.settingsLockedForHeadless {}
        try expect(fixture.postedPayloads.isEmpty, "Locked settings wrote firmware")
    }

    @MainActor private static func testObsoleteSession() async throws {
        let (manager, fixture, baseline) = try await settingsSetup()
        defer { manager.disconnectFromDevice() }
        do {
            _ = try await manager.applySystemConfig(baseline, editedFields: [], connectionSessionID: UUID())
            throw Failure.message("Obsolete settings session succeeded")
        } catch MouseJigglerError.unavailable {}
        try expect(fixture.postedPayloads.isEmpty, "Obsolete session wrote firmware")
    }

    @MainActor private static func testDisconnectDuringGET() async throws {
        let (manager, fixture, baseline) = try await settingsSetup()
        let id = manager.connectionSessionID!
        fixture.holdNextGet()
        let apply = Task { try await manager.applySystemConfig(baseline, editedFields: [], connectionSessionID: id) }
        try await eventually { fixture.hasHeldRequest }
        manager.disconnectFromDevice()
        fixture.release()
        do { _ = try await apply.value; throw Failure.message("Disconnected settings completed") }
        catch is CancellationError {}
        try expect(fixture.postedPayloads.isEmpty, "Old settings wrote after disconnect")
    }

    @MainActor private static func testHeadlessDuringGET() async throws {
        let (manager, fixture, baseline) = try await settingsSetup()
        let id = manager.connectionSessionID!
        fixture.holdNextGet()
        let apply = Task { try await manager.applySystemConfig(baseline, editedFields: [], connectionSessionID: id) }
        try await eventually { fixture.hasHeldRequest }
        let owner = manager.beginHeadlessConfigurationTransition()
        defer { manager.endHeadlessConfigurationTransition(owner); manager.disconnectFromDevice() }
        fixture.release()
        do { _ = try await apply.value; throw Failure.message("Stale settings crossed Headless transition") }
        catch is CancellationError {}
        try expect(fixture.postedPayloads.isEmpty, "Settings wrote after Headless invalidated request")
    }

    @MainActor private static func testDisconnectDuringPOST() async throws {
        let (manager, fixture, baseline) = try await settingsSetup()
        let id = manager.connectionSessionID!
        var draft = baseline
        draft.keymap = "en-us"
        fixture.holdNextPost()
        let apply = Task { try await manager.applySystemConfig(draft, editedFields: ["keymap"], connectionSessionID: id) }
        try await eventually { fixture.hasHeldRequest }
        try expect(fixture.postedPayloads.count == 1, "Expected the already-sent write")
        manager.disconnectFromDevice()
        fixture.release()
        do { _ = try await apply.value; throw Failure.message("Disconnected response published") }
        catch is CancellationError {}
        try expect(manager.mouseJigglerEnabled == nil, "Old POST response restored disconnected state")
    }

    @MainActor private static func testSecureRetry() async throws {
        let store = MemoryCredentialStore(acceptsToken: false)
        let manager = try persist(store, token: currentFixtureToken)
        try expect(manager.credentialStorageWarning != nil, "Missing storage warning")
        store.acceptsToken = true
        let fixture = ConfigFixture(payload: "{}", host: "persist.invalid")
        var candidate = device(fixture.host)
        candidate.authToken = "fixture-retry-token"
        manager.commitConnection(PreparedKVMConnection(device: candidate, client: try makeClient(fixture)))
        try expect(manager.credentialStorageWarning == nil, "Secure retry kept error notice")
        try expect(!store.recordsText.contains("fixture-retry-token"), "Secure retry wrote plaintext")
        manager.disconnectFromDevice()
    }

    @MainActor private static func testRepeatedStorageWarning() async throws {
        let store = MemoryCredentialStore(acceptsToken: false)
        let manager = try persist(store, token: currentFixtureToken)
        let firstMessage = manager.credentialStorageWarning
        let firstGeneration = manager.credentialStorageWarningGeneration
        let fixture = ConfigFixture(payload: "{}", host: "persist.invalid")
        var candidate = device(fixture.host)
        candidate.authToken = "fixture-current-token"
        manager.commitConnection(PreparedKVMConnection(device: candidate, client: try makeClient(fixture)))
        try expect(manager.credentialStorageWarning == firstMessage && firstMessage != nil, "Repeated failure changed diagnostic text")
        try expect(firstGeneration > 0 && manager.credentialStorageWarningGeneration > firstGeneration, "Identical warning cannot retrigger UI alert")
        try expect(!store.recordsText.contains("fixture-current-token"), "Repeated failure leaked plaintext token")
        manager.disconnectFromDevice()
    }

    @MainActor private static func settingsSetup() async throws -> (KVMDeviceManager, ConfigFixture, GLKVMSystemConfig) {
        let fixture = ConfigFixture(payload: #"{"mouse_jiggle":false,"keymap":"de"}"#)
        let client = try makeClient(fixture)
        let baseline = try await client.getSystemConfig()
        let manager = KVMDeviceManager(startsServices: false, persistsConnections: false)
        manager.commitConnection(PreparedKVMConnection(device: device(fixture.host), client: client))
        await manager.refreshMouseJigglerState()
        return (manager, fixture, baseline)
    }

    @MainActor private static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure.message("Local fixture timed out")
    }

    @MainActor private static func testFailedPersistence() async throws {
        let store = MemoryCredentialStore(acceptsToken: false)
        let manager = try persist(store, token: currentFixtureToken)
        try expect(manager.connectedDevice?.authToken == "fixture-current-token", "Session token was lost")
        try expect(store.savedTokens == ["fixture-current-token"], "Secure save was not attempted")
        try expect(!(store.recordsText.contains("fixture-current-token")), "Failed secure save leaked token into metadata")
        try expect(manager.credentialStorageWarning != nil, "Secure store failure has no visible notice")
        manager.disconnectFromDevice()
    }

    @MainActor private static func testSuccessfulPersistence() async throws {
        let store = MemoryCredentialStore(acceptsToken: true)
        let manager = try persist(store, token: currentFixtureToken)
        try expect(store.savedTokens.count == 1, "Secure save was not attempted")
        try expect(manager.credentialStorageWarning == nil, "Successful secure save kept an error notice")
        try expect(!store.recordsText.contains("fixture-current-token"), "Secure save leaked plaintext metadata")
        manager.disconnectFromDevice()
    }

    @MainActor private static func testEmptyPersistence() async throws {
        let store = MemoryCredentialStore(acceptsToken: false)
        let manager = try persist(store, token: "")
        try expect(store.savedTokens.isEmpty, "An empty token touched Keychain")
        try expect(manager.credentialStorageWarning == nil, "Empty token generated an error notice")
        try expect(!store.recordsText.contains("authToken"), "Empty token was persisted")
        manager.disconnectFromDevice()
    }

    @MainActor private static func testLegacyPersistence() async throws {
        let store = MemoryCredentialStore(acceptsToken: false)
        store.records = Data(#"[{"host":"persist.invalid","port":80,"name":"Prior device","type":"custom","authToken":"fixture-legacy-token","capabilities":[]}]"#.utf8)
        let manager = try persist(store, token: currentFixtureToken)
        try expect(store.recordsText.contains("fixture-legacy-token"), "Existing credential was changed without migration approval")
        try expect(!store.recordsText.contains("fixture-current-token"), "New session token leaked into old record")
        manager.disconnectFromDevice()
    }

    @MainActor private static func testEmptyLegacyPersistence() async throws {
        let store = MemoryCredentialStore(acceptsToken: false)
        store.records = Data(#"[{"host":"persist.invalid","port":80,"name":"Prior device","type":"custom","authToken":"fixture-legacy-token","capabilities":[]}]"#.utf8)
        let manager = try persist(store, token: "")
        try expect(store.recordsText.contains("fixture-legacy-token"), "Empty session token deleted existing credential")
        try expect(store.savedTokens.isEmpty, "Empty legacy reconnect touched secure store")
        manager.disconnectFromDevice()
    }

    @MainActor private static func persist(_ store: MemoryCredentialStore, token: String) throws -> KVMDeviceManager {
        let fixture = ConfigFixture(payload: "{}", host: "persist.invalid")
        let manager = KVMDeviceManager(startsServices: false, persistsConnections: true, persistence: store.dependencies)
        var candidate = device(fixture.host)
        candidate.authToken = token
        manager.commitConnection(PreparedKVMConnection(device: candidate, client: try makeClient(fixture)))
        return manager
    }

    private static func makeClient(_ fixture: ConfigFixture) throws -> GLKVMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfigURLProtocol.self]
        config.httpCookieStorage = nil
        return try GLKVMClient(host: fixture.host, allowInsecureTLS: false, sessionConfiguration: config)
    }

    private static func device(_ host: String) -> KVMDevice {
        KVMDevice(id: host, name: "Synthetic KVM", host: host, port: 80, type: .custom, authToken: "", capabilities: [])
    }

    private static func values(_ text: String) throws -> GLKVMJSONObject {
        try JSONDecoder().decode(GLKVMJSONObject.self, from: Data(text.utf8))
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.message(message) }
    }
    private enum Failure: Error { case message(String) }
}

private final class MemoryCredentialStore {
    var records: Data?
    var savedTokens: [String] = []
    var acceptsToken: Bool
    init(acceptsToken: Bool) { self.acceptsToken = acceptsToken }
    var recordsText: String { records.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    var dependencies: KVMDevicePersistence {
        KVMDevicePersistence(readRecords: { self.records }, writeRecords: { self.records = $0 }, saveToken: { token, _, _ in
            self.savedTokens.append(token)
            return self.acceptsToken
        })
    }
}

private final class ConfigFixture: @unchecked Sendable {
    static let registryLock = NSLock()
    static var registry: [String: ConfigFixture] = [:]
    let host: String
    private let lock = NSLock()
    private var payload: Data
    private var posts: [GLKVMJSONObject] = []
    private var heldMethod: String?
    private var held: [() -> Void] = []
    init(payload: String, host: String = "config-\(UUID().uuidString.lowercased()).invalid") {
        self.host = host
        self.payload = Data(payload.utf8)
        Self.registryLock.lock()
        Self.registry[host] = self
        Self.registryLock.unlock()
    }
    static func lookup(_ host: String) -> ConfigFixture? {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[host]
    }
    func setPayload(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        payload = Data(text.utf8)
    }
    var postedPayloads: [GLKVMJSONObject] {
        lock.lock(); defer { lock.unlock() }
        return posts
    }
    func holdNextGet() {
        lock.lock(); defer { lock.unlock() }
        heldMethod = "GET"
    }
    func holdNextPost() {
        lock.lock(); defer { lock.unlock() }
        heldMethod = "POST"
    }
    var hasHeldRequest: Bool {
        lock.lock(); defer { lock.unlock() }
        return !held.isEmpty
    }
    func deliver(_ operation: @escaping () -> Void, method: String?) {
        lock.lock()
        if heldMethod != nil, heldMethod == method {
            heldMethod = nil
            held.append(operation)
            lock.unlock()
        } else {
            lock.unlock()
            operation()
        }
    }
    func release() {
        lock.lock()
        let callbacks = held
        held = []
        lock.unlock()
        callbacks.forEach { $0() }
    }
    func response(to request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if request.url?.path == "/api/hid" {
            return Data(#"{"ok":true,"result":{"jiggler":{"enabled":true,"active":false}}}"#.utf8)
        }
        if request.url?.path == "/api/hid/set_params" {
            let jiggler = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "jiggler" })?.value
            guard jiggler == "false" else { throw URLError(.cannotDecodeContentData) }
            return Data(#"{"ok":true,"result":{}}"#.utf8)
        }
        if request.httpMethod == "POST" {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 4096)
                    guard count > 0 else { break }
                    data.append(buffer, count: count)
                }
                body = data
            }
            guard let body else { throw URLError(.cannotDecodeContentData) }
            posts.append(try JSONDecoder().decode(GLKVMJSONObject.self, from: body))
            payload = body
        }
        let config = try JSONDecoder().decode(GLKVMJSONObject.self, from: payload)
        return try JSONEncoder().encode(JSONValue.object(["ok": .bool(true), "result": .object(["config": .object(config)])]))
    }
}

private final class ConfigURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = ConfigFixture.lookup(url.host ?? "") else { preconditionFailure("Missing local fixture") }
        do {
            let data = try fixture.response(to: request)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            fixture.deliver({
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }, method: request.httpMethod)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
