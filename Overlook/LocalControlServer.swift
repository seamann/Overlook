import Foundation
import Network

@MainActor
final class LocalControlServer: ObservableObject {
    private static let maximumTextBytes = 256 * 1024
    private static let coordinateRange = -32_767...32_767

    @Published private(set) var status = "Control API stopped"
    private var listener: NWListener?
    private weak var inputManager: InputManager?
    private weak var snapshotManager: WebRTCManager?
    private let controlPort: UInt16
    private let controlDirectoryURL: URL?
    private let actionLedger = RemoteActionLedger()
    private var actionTasks: [String: Task<Void, Never>] = [:]
    private(set) var listeningPort: UInt16?
    private var token = UUID().uuidString
    private let connectionLimiter = ConnectionLimiter(limit: ControlServerConnectionPolicy.maximumConnections)
    private let mutationGate = RemoteMutationGate()
    private var modeProvider: @MainActor () -> ControlModeSnapshot = {
        ControlModeSnapshot(mode: .manual, generation: 0)
    }
    private var shouldRun = false
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?
    private lazy var tokenDirectoryURL: URL = {
        controlDirectoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overlook", isDirectory: true)
            .appendingPathComponent("Control", isDirectory: true)
    }()
    private lazy var tokenURL = tokenDirectoryURL.appendingPathComponent("control-token")

    init(port: UInt16 = 17891, controlDirectoryURL: URL? = nil) {
        self.controlPort = port
        self.controlDirectoryURL = controlDirectoryURL
    }

    func setSnapshotProvider(_ manager: WebRTCManager) {
        snapshotManager = manager
    }

    /// Supplies the canonical mode for status reporting and command gating.
    func setModeProvider(_ provider: @escaping @MainActor () -> ControlModeSnapshot) {
        modeProvider = provider
    }

    func start(inputManager: InputManager) {
        self.inputManager = inputManager
        guard !shouldRun else { return }
        shouldRun = true
        retryAttempt = 0
        startListener()
    }

    private func startListener() {
        guard shouldRun else { return }
        guard listener == nil else { return }
        token = UUID().uuidString
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: controlPort)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self, token] connection in
                guard let self, let lease = self.connectionLimiter.acquire() else {
                    connection.cancel()
                    return
                }
                self.handle(connection, token: token, lease: lease)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.retryAttempt = 0
                        self.retryTask?.cancel()
                        self.retryTask = nil
                        self.listeningPort = listener.port?.rawValue
                        self.status = "Control API ready on 127.0.0.1:\(self.listeningPort ?? self.controlPort)"
                    case .failed(let error):
                        self.handleListenerFailure(listener, error: error)
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
            scheduleRetry()
        }
    }

    func stop() {
        actionTasks.values.forEach { $0.cancel() }
        token = UUID().uuidString
        actionLedger.invalidateFrames()
        shouldRun = false
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        listener?.cancel()
        listener = nil
        listeningPort = nil
        status = "Control API stopped"
        try? FileManager.default.removeItem(at: tokenURL)
    }

    func waitForMutationsToDrain() async {
        await mutationGate.waitUntilIdle()
    }

    private func handleListenerFailure(_ failedListener: NWListener, error: NWError) {
        guard listener === failedListener else { return }
        failedListener.cancel()
        listener = nil
        token = UUID().uuidString
        actionTasks.values.forEach { $0.cancel() }
        actionLedger.invalidateFrames()
        try? FileManager.default.removeItem(at: tokenURL)
        status = "Control API error: \(error.localizedDescription)"
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard shouldRun, retryTask == nil else { return }
        let delay = ControlServerRetryPolicy.delay(forAttempt: retryAttempt)
        retryAttempt = min(retryAttempt + 1, 6)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.startListener()
        }
    }

    nonisolated private func handle(_ connection: NWConnection, token: String, lease: ConnectionLease) {
        let requestLifetime = RequestLifetime()
        requestLifetime.scheduleTimeout(after: ControlServerConnectionPolicy.requestReadTimeout) {
            connection.cancel()
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                requestLifetime.cancel()
                lease.release()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(
            connection,
            accumulated: Data(),
            token: token,
            requestLifetime: requestLifetime
        )
    }

    nonisolated private func receiveRequest(
        _ connection: NWConnection,
        accumulated: Data,
        token: String,
        requestLifetime: RequestLifetime
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= 512 * 1024 else { connection.cancel(); return }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let request = Data(buffer[..<newline])
                requestLifetime.scheduleTimeout(after: ControlServerConnectionPolicy.commandTimeout) {
                    connection.cancel()
                }
                let task = Task { @MainActor in
                    let response = await self?.process(request, token: token) ?? ["ok": false, "error": "server unavailable"]
                    guard !Task.isCancelled else {
                        requestLifetime.finish()
                        connection.cancel()
                        return
                    }
                    let output = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"ok\":false}".utf8)
                    connection.send(content: output + Data([0x0A]), completion: .contentProcessed { _ in
                        requestLifetime.finish()
                        connection.cancel()
                    })
                }
                requestLifetime.install(task)
                // A peer which closes before the response must cancel its own
                // operation, while inner input cleanup still retains the gate.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                    requestLifetime.cancel()
                    connection.cancel()
                }
            } else if isComplete {
                connection.cancel()
            } else {
                self?.receiveRequest(
                    connection,
                    accumulated: buffer,
                    token: token,
                    requestLifetime: requestLifetime
                )
            }
        }
    }

    private func process(_ data: Data, token: String) async -> [String: Any] {
        guard shouldRun, token == self.token else { return failure(.unauthorized) }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCommand = request["command"] as? String,
              let command = LocalControlCommand(rawValue: rawCommand),
              let inputManager else { return failure(.invalidRequest) }
        guard request["token"] as? String == token else { return failure(.unauthorized) }
        _ = synchronizeSession()
        let modeSnapshot = modeProvider()
        let capturedTransport = inputManager.transportID
        let capturedSource = snapshotManager?.snapshotSourceID
        guard ControlMutationPolicy.allows(command.kind, in: modeSnapshot.mode) else {
            return failure(.headlessRequired, request: request)
        }
        let authorization: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, let inputManager = self.inputManager else { return false }
            return self.modeProvider() == modeSnapshot
                && self.shouldRun && self.token == token
                && modeSnapshot.mode == .codexHeadless
                && !inputManager.isLocalInputCaptureAllowed
                && !inputManager.inputBlocked
                && inputManager.transportID == capturedTransport
                && self.snapshotManager?.snapshotSourceID == capturedSource
                && self.snapshotManager?.snapshotReady == true
                && self.endpointMatches()
        }
        do {
            switch command {
            case .status:
                let readiness = await inputManager.inputReadiness()
                _ = synchronizeSession()
                let currentMode = modeProvider()
                let bindingMatches = endpointMatches()
                let response: [String: Any] = [
                    "ok": true,
                    "status": inputManager.activityStatus,
                    "mode": currentMode.mode.rawValue,
                    "control_api": status,
                    "hid_status": inputManager.hidStatus,
                    "local_input_capture_allowed": inputManager.isLocalInputCaptureAllowed,
                    "protocol_version": 2,
                    "session_id": actionLedger.sessionID,
                    "next_action_seq": actionLedger.nextActionSequence,
                    "capabilities": ["status", "observe", "act", "action_status", "cancel", "click", "text", "shortcut", "scroll", "drag"],
                    "build_id": Bundle.main.object(forInfoDictionaryKey: "OverlookBuildID") as? String ?? "development",
                    "input_blocked": inputManager.inputBlocked,
                    "readiness": ["video": snapshotManager?.snapshotReady == true,
                                  "text": readiness.text && bindingMatches,
                                  "mouse": readiness.mouse && bindingMatches],
                ]
                return response
            case .observe:
                return try await observe(request)
            case .act:
                return try await act(request)
            case .actionStatus, .cancel:
                let pair = try actionIdentity(request)
                let record = try actionLedger.record(sessionID: pair.session, sequence: pair.sequence)
                if command == .cancel, !record.state.isTerminal {
                    actionTasks[actionKey(pair.session, pair.sequence)]?.cancel()
                }
                return actionResponse(sessionID: pair.session, sequence: pair.sequence, record: record)
            case .text:
                guard let value = request["value"] as? String, value.utf8.count <= Self.maximumTextBytes else {
                    throw RemoteActionError.invalidRequest
                }
                try await mutationGate.perform {
                    defer { self.actionLedger.invalidateFrames() }
                    try await inputManager.sendTextToRemote(value, authorization: authorization, willDispatch: {
                        self.actionLedger.invalidateFrames()
                    })
                }
            case .click:
                guard let x = request["x"] as? Int, let y = request["y"] as? Int else {
                    throw RemoteActionError.invalidRequest
                }
                guard Self.coordinateRange.contains(x), Self.coordinateRange.contains(y) else {
                    throw RemoteActionError.invalidRequest
                }
                try await mutationGate.perform {
                    defer { self.actionLedger.invalidateFrames() }
                    try await inputManager.sendCodexClick(
                        signedX: x,
                        signedY: y,
                        authorization: authorization,
                        willDispatch: { self.actionLedger.invalidateFrames() }
                    )
                }
            case .shortcut:
                guard let keys = request["keys"] as? [String], RemoteShortcutPolicy.accepts(keys) else {
                    throw RemoteActionError.invalidRequest
                }
                try await mutationGate.perform {
                    defer { self.actionLedger.invalidateFrames() }
                    try await inputManager.sendCodexShortcut(
                        keys: keys,
                        authorization: authorization,
                        willDispatch: { self.actionLedger.invalidateFrames() }
                    )
                }
            }
            return ["ok": true]
        } catch {
            if let snapshotError = error as? RemoteSnapshotError {
                return ["ok": false, "error_code": snapshotError.rawValue, "error": snapshotError.rawValue]
            }
            return failure(classify(error), request: request)
        }
    }

    private func endpointMatches() -> Bool {
        guard let video = snapshotManager?.snapshotEndpointID, let input = inputManager?.controlEndpointID else { return false }
        return video == input
    }

    @discardableResult
    private func synchronizeSession() -> String {
        let old = actionLedger.sessionID
        let session = actionLedger.synchronize(sourceID: snapshotManager?.snapshotSourceID ?? "unavailable",
                                              transportID: inputManager?.transportID ?? "unavailable",
                                              modeGeneration: modeProvider().generation)
        if !old.isEmpty, old != session {
            for (key, task) in actionTasks where !key.hasPrefix(session + ":") { task.cancel() }
        }
        return session
    }

    private func observe(_ request: [String: Any]) async throws -> [String: Any] {
        guard !mutationGate.isBusy else { throw RemoteSnapshotError.busy }
        guard let manager = snapshotManager, manager.snapshotReady, endpointMatches() else { throw RemoteActionError.inputUnavailable }
        let session = synchronizeSession()
        let revision = actionLedger.mutationGeneration
        var region: SnapshotRegion?
        if let raw = request["region"] {
            guard let value = raw as? [String: Any], Set(value.keys) == ["x", "y", "width", "height"] else {
                throw RemoteActionError.invalidRequest
            }
            region = try SnapshotRegion(x: RemoteActionCommand.integer(value["x"]),
                                        y: RemoteActionCommand.integer(value["y"]),
                                        width: RemoteActionCommand.integer(value["width"]),
                                        height: RemoteActionCommand.integer(value["height"]))
        }
        let snapshot = try await manager.captureRemoteSnapshot(region: region)
        try Task.checkCancellation()
        guard !mutationGate.isBusy else { throw RemoteSnapshotError.busy }
        guard synchronizeSession() == session, snapshot.sourceID == manager.snapshotSourceID,
              revision == actionLedger.mutationGeneration, endpointMatches() else { throw RemoteActionError.sessionChanged }
        actionLedger.registerFrame(id: snapshot.frameID, width: snapshot.width, height: snapshot.height, receivedAt: snapshot.receivedAt)
        return ["ok": true, "protocol_version": 2, "session_id": session,
                "frame_id": snapshot.frameID, "next_action_seq": actionLedger.nextActionSequence,
                "received_at": snapshot.receivedAt,
                "frame_age_ms": max(0, (ProcessInfo.processInfo.systemUptime - snapshot.receivedAt) * 1000),
                "width": snapshot.width, "height": snapshot.height,
                "region": ["x": snapshot.region.x, "y": snapshot.region.y,
                           "width": snapshot.region.width, "height": snapshot.region.height],
                "scale": 1, "rotation_degrees": 0,
                "mime_type": "image/png", "image_base64": snapshot.pngData.base64EncodedString()]
    }

    private func act(_ request: [String: Any]) async throws -> [String: Any] {
        let pair = try actionIdentity(request)
        guard let frameID = request["frame_id"] as? String, validIdentifier(frameID),
              let value = request["action"] as? [String: Any] else { throw RemoteActionError.invalidRequest }
        let command = try RemoteActionCommand.parse(value)
        let isNew = try actionLedger.reserve(sessionID: pair.session, sequence: pair.sequence, digest: command.digest(frameID: frameID))
        if !isNew {
            return actionResponse(sessionID: pair.session, sequence: pair.sequence,
                                  record: try actionLedger.record(sessionID: pair.session, sequence: pair.sequence))
        }
        let key = actionKey(pair.session, pair.sequence)
        let authority = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(command, sessionID: pair.session, sequence: pair.sequence, frameID: frameID, authority: authority)
            self.actionTasks.removeValue(forKey: key)
        }
        actionTasks[key] = task
        await withTaskCancellationHandler {
            if Task.isCancelled { task.cancel() }
            await task.value
        } onCancel: { task.cancel() }
        return actionResponse(sessionID: pair.session, sequence: pair.sequence,
                              record: try actionLedger.record(sessionID: pair.session, sequence: pair.sequence))
    }

    private func execute(_ command: RemoteActionCommand, sessionID: String, sequence: Int, frameID: String, authority: String) async {
        var didDispatch = false
        do {
            try await mutationGate.perform {
                defer { self.actionLedger.invalidateFrames() }
                guard let input = self.inputManager else { throw RemoteActionError.inputUnavailable }
                guard self.shouldRun, self.token == authority else { throw RemoteActionError.unauthorized }
                guard self.synchronizeSession() == sessionID else { throw RemoteActionError.sessionChanged }
                guard self.endpointMatches(), self.snapshotManager?.snapshotReady == true else { throw RemoteActionError.inputUnavailable }
                guard !input.inputBlocked else { throw RemoteActionError.inputBlocked }
                let mode = self.modeProvider()
                guard mode.mode == .codexHeadless, !input.isLocalInputCaptureAllowed else { throw RemoteActionError.headlessRequired }
                let frame = try self.actionLedger.frame(id: frameID, now: ProcessInfo.processInfo.systemUptime)
                try command.validate(width: frame.width, height: frame.height)
                self.actionLedger.markRunning(sessionID: sessionID, sequence: sequence)
                let authorization: @MainActor @Sendable () -> Bool = { [weak self] in
                    guard let self else { return false }
                    return self.synchronizeSession() == sessionID && self.modeProvider() == mode
                        && self.shouldRun && self.token == authority
                        && self.endpointMatches() && !input.isLocalInputCaptureAllowed && !input.inputBlocked
                        && self.snapshotManager?.snapshotReady == true
                }
                try await input.performRemoteAction(command, width: frame.width, height: frame.height, authorization: authorization) {
                    try Task.checkCancellation()
                    guard authorization() else { throw RemoteActionError.sessionChanged }
                    _ = try self.actionLedger.consumeFrame(id: frameID, now: ProcessInfo.processInfo.systemUptime)
                    try self.actionLedger.markDispatched(sessionID: sessionID, sequence: sequence)
                    didDispatch = true
                }
            }
            actionLedger.finish(sessionID: sessionID, sequence: sequence, state: .transmitted)
        } catch {
            actionLedger.finish(sessionID: sessionID, sequence: sequence,
                                state: didDispatch ? .outcomeUnknown : .notStarted, error: classify(error))
        }
    }

    private func actionIdentity(_ request: [String: Any]) throws -> (session: String, sequence: Int) {
        guard let session = request["session_id"] as? String, validIdentifier(session) else { throw RemoteActionError.invalidRequest }
        let sequence = try RemoteActionCommand.integer(request["action_seq"])
        guard sequence > 0 else { throw RemoteActionError.invalidRequest }
        return (session, sequence)
    }

    private func validIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.count <= 128
            && identifier.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0) }
    }

    private func actionKey(_ session: String, _ sequence: Int) -> String { "\(session):\(sequence)" }

    private func actionResponse(sessionID: String, sequence: Int, record: RemoteActionRecord) -> [String: Any] {
        var response: [String: Any] = ["ok": true, "protocol_version": 2, "session_id": sessionID,
                                      "action_seq": sequence, "state": record.state.rawValue]
        if let error = record.error { response["error_code"] = error.rawValue }
        return response
    }

    private func failure(_ error: RemoteActionError, request: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["ok": false, "protocol_version": 2, "error_code": error.rawValue, "error": error.rawValue]
        if let pair = try? actionIdentity(request) {
            result["session_id"] = pair.session
            result["action_seq"] = pair.sequence
        }
        return result
    }

    private func classify(_ error: Error) -> RemoteActionError {
        if let error = error as? RemoteActionError { return error }
        if error is CancellationError { return .cancelled }
        if error is RemoteMutationGateError { return .queueFull }
        if let error = error as? InputManager.RemoteTextInputError {
            switch error {
            case .notConnected: return .inputUnavailable
            case .authorizationExpired: return .sessionChanged
            case .emptyText, .invalidShortcut: return .invalidRequest
            }
        }
        return .transportError
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

private final class RequestLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var timeout: DispatchWorkItem?
    private var isCancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = isCancelled
        if !shouldCancel { self.task = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func scheduleTimeout(after delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            self?.cancel()
            action()
        }
        lock.lock()
        let previousTimeout = timeout
        let shouldSchedule = !isCancelled
        if shouldSchedule { timeout = work }
        lock.unlock()
        previousTimeout?.cancel()
        if shouldSchedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work.cancel()
        }
    }

    func finish() {
        lock.lock()
        let currentTimeout = timeout
        timeout = nil
        task = nil
        lock.unlock()
        currentTimeout?.cancel()
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let currentTask = task
        let currentTimeout = timeout
        task = nil
        timeout = nil
        lock.unlock()
        currentTimeout?.cancel()
        currentTask?.cancel()
    }
}
