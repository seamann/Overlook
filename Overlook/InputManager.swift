import Foundation
import Cocoa
import CoreGraphics
import Combine
import SwiftUI

extension Notification.Name {
    static let overlookToggleCopyMode = Notification.Name("overlook.toggleCopyMode")
}

@MainActor
class InputManager: ObservableObject {
    private var webRTCManager: WebRTCManager?
    private var glkvmClient: GLKVMClient?
    private var glkvmWebSocketClient: GLKVMClient.WebSocketClient?
    private var keyEventMonitor: Any?
    private var mouseEventMonitor: Any?
    private(set) var localClipboardTransferTask: Task<Void, Never>?
    private var isCapturing = false
    private var mouseModeRefreshTask: Task<Void, Never>?
    private var hidCommandTail: Task<Void, Never>?
    private var hidReconnectTask: Task<Void, Never>?
    private var acceptsHIDCommands = true
    private let localInputCapture: LocalInputCaptureContext
    private let clipboardText: @MainActor () -> String?
    private var localInputFocusObservers: [NSObjectProtocol] = []
    private var keyboardCaptureGeneration = 0
    private var mouseCaptureGeneration = 0
    private var activePrintOperations = 0
    private var activePrintDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var transportID = UUID().uuidString
    @Published private(set) var inputBlocked = false

    private struct PendingAbsoluteMouseMove: Equatable, Sendable {
        let toX: Int
        let toY: Int
    }

    private struct PendingRelativeMouseMove: Equatable, Sendable {
        var deltaX: Int
        var deltaY: Int
    }

    private enum PendingMouseMoveCommand: Equatable, Sendable {
        case absolute(PendingAbsoluteMouseMove)
        case relative(PendingRelativeMouseMove)

        func merged(with newer: PendingMouseMoveCommand) -> PendingMouseMoveCommand {
            switch (self, newer) {
            case (.relative(let oldMove), .relative(let newMove)):
                return .relative(
                    PendingRelativeMouseMove(
                        deltaX: oldMove.deltaX + newMove.deltaX,
                        deltaY: oldMove.deltaY + newMove.deltaY
                    )
                )
            default:
                return newer
            }
        }
    }

    private struct PendingMouseMoveCommandSnapshot: Sendable {
        let move: PendingMouseMoveCommand
        let mode: TransportMode
        let ws: GLKVMClient.WebSocketClient?
    }

    private var mouseMoveBuffer = LatestMouseMoveCommandBuffer<PendingMouseMoveCommand>()
    private var mouseMoveGeneration = 0

    private var pendingCommandKeyCode: UInt16?
    private var activeCommandKeyCode: UInt16?
    private var commandKeySentToRemote: Bool = false
    private var suppressedKeyUps: Set<UInt16> = []
    
    @Published private(set) var isKeyboardCaptureEnabled = false
    @Published private(set) var isMouseCaptureEnabled = false
    @Published private(set) var isLocalInputCaptureAllowed = true
    @Published private(set) var activityStatus = "Ready"
    @Published private(set) var lastInputError: String?
    @Published private(set) var hidStatus = "Disconnected"

    enum TransportMode: String, CaseIterable, Sendable {
        case webRTC
        case glkvmWebSocket
    }

    @Published var transportMode: TransportMode = .glkvmWebSocket
    @Published private(set) var isGLKVMAbsoluteMouseMode = true

    init(
        inputFocusEnvironment: @escaping @MainActor () -> LocalInputFocusEnvironment = {
            LocalInputFocusEnvironment.live()
        },
        clipboardText: @escaping @MainActor () -> String? = {
            NSPasteboard.general.string(forType: .string)
        }
    ) {
        localInputCapture = LocalInputCaptureContext(focusEnvironment: inputFocusEnvironment)
        self.clipboardText = clipboardText
        observeLocalInputFocusChanges()
        installKeyboardMonitorIfNeeded()
        refreshLocalInputFocus()
    }
    
    func setup(with webRTCManager: WebRTCManager) {
        self.webRTCManager = webRTCManager
    }

    func setGLKVMClient(_ client: GLKVMClient?) {
        guard glkvmClient !== client else { return }
        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
        disconnectGLKVMWebSocket()
        glkvmClient = client
        isGLKVMAbsoluteMouseMode = true
        stopMouseMoveSender()
        if client == nil {
            return
        }
        let oldInputDrain = hidCommandTail
        Task { [weak self] in
            await oldInputDrain?.value
            guard let self, self.glkvmClient === client else { return }
            await self.reconnectGLKVMWebSocketIfNeeded()
        }
        mouseModeRefreshTask = Task { [weak self, weak client] in
            guard let client else { return }
            do {
                let config = try await client.getSystemConfig()
                await MainActor.run {
                    guard let self, self.glkvmClient === client else { return }
                    self.setGLKVMAbsoluteMouseMode(config.isAbsoluteMouse)
                }
            } catch {
                // Keep the default absolute-mode behavior if settings cannot be loaded.
            }
        }
    }

    func setGLKVMAbsoluteMouseMode(_ isAbsolute: Bool) {
        guard isGLKVMAbsoluteMouseMode != isAbsolute else { return }
        isGLKVMAbsoluteMouseMode = isAbsolute
        stopMouseMoveSender()
    }

    func handleVideoMouseMove(pointInView: CGPoint, deltaInView: CGSize = .zero, viewSize: CGSize, videoSize: CGSize?) {
        refreshLocalInputFocus()
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let moveEvent = MouseMoveEvent(position: normalized, delta: deltaInView, timestamp: CACurrentMediaTime())
        if transportMode == .glkvmWebSocket {
            if isGLKVMAbsoluteMouseMode {
                enqueueAbsoluteMouseMoveEvent(moveEvent)
            } else {
                enqueueRelativeMouseMoveEvent(moveEvent)
            }
        } else {
            sendMouseMoveEvent(moveEvent)
        }
    }

    private func enqueueAbsoluteMouseMoveEvent(_ event: MouseMoveEvent) {
        guard isNormalized(event.position) else { return }
        let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
        enqueueMouseMoveCommand(.absolute(PendingAbsoluteMouseMove(toX: toX, toY: toY)))
    }

    private func enqueueRelativeMouseMoveEvent(_ event: MouseMoveEvent) {
        let deltaX = Int(event.delta.width.rounded())
        let deltaY = Int(event.delta.height.rounded())
        guard deltaX != 0 || deltaY != 0 else { return }

        enqueueMouseMoveCommand(.relative(PendingRelativeMouseMove(deltaX: deltaX, deltaY: deltaY)))
    }

    private func enqueueMouseMoveCommand(_ command: PendingMouseMoveCommand) {
        let shouldSchedule = mouseMoveBuffer.enqueue(command) { oldCommand, newCommand in
            oldCommand.merged(with: newCommand)
        }
        if shouldSchedule {
            scheduleMouseMoveCommandIfNeeded()
        }
    }

    private func scheduleMouseMoveCommandIfNeeded() {
        guard mouseMoveBuffer.hasScheduledMove else { return }
        let generation = mouseMoveGeneration
        let manager = self

        enqueueHIDCommand(label: "Mouse move", completion: { [weak self] _ in
            self?.finishMouseMoveCommand(generation: generation)
        }, successFeedback: .errorsOnly, freezesPendingMouseMove: false) {
            let snapshot = await MainActor.run {
                manager.takeScheduledMouseMoveCommand(generation: generation)
            }
            guard let snapshot, snapshot.mode == .glkvmWebSocket, let ws = snapshot.ws else { return }

            try await Self.sendMouseMoveCommand(snapshot.move, through: ws)
        }
    }

    private func takeScheduledMouseMoveCommand(generation: Int) -> PendingMouseMoveCommandSnapshot? {
        refreshLocalInputFocus()
        guard isMouseCaptureEnabled,
              generation == mouseMoveGeneration,
              let move = mouseMoveBuffer.takeScheduledMove()
        else {
            return nil
        }

        return PendingMouseMoveCommandSnapshot(
            move: move,
            mode: transportMode,
            ws: glkvmWebSocketClient
        )
    }

    private func finishMouseMoveCommand(generation: Int) {
        guard generation == mouseMoveGeneration else { return }

        if mouseMoveBuffer.finishCommand() {
            scheduleMouseMoveCommandIfNeeded()
        }
    }

    private func freezeMouseMovesForOrderedHIDCommand() {
        guard mouseMoveBuffer.hasScheduledMove else { return }
        mouseMoveBuffer.freezeScheduledMove()

        guard let pendingMove = mouseMoveBuffer.takePendingMoveAfterFrozenCommand() else { return }
        enqueueCapturedMouseMoveCommand(pendingMove, generation: mouseMoveGeneration)
    }

    private func enqueueCapturedMouseMoveCommand(_ command: PendingMouseMoveCommand, generation: Int) {
        let manager = self
        enqueueHIDCommand(
            label: "Mouse move",
            successFeedback: .errorsOnly,
            freezesPendingMouseMove: false
        ) {
            let snapshot = await MainActor.run {
                manager.mouseMoveSnapshot(for: command, generation: generation)
            }
            guard let snapshot, snapshot.mode == .glkvmWebSocket, let ws = snapshot.ws else { return }

            try await Self.sendMouseMoveCommand(snapshot.move, through: ws)
        }
    }

    private func mouseMoveSnapshot(
        for command: PendingMouseMoveCommand,
        generation: Int
    ) -> PendingMouseMoveCommandSnapshot? {
        refreshLocalInputFocus()
        guard isMouseCaptureEnabled, generation == mouseMoveGeneration else { return nil }
        return PendingMouseMoveCommandSnapshot(
            move: command,
            mode: transportMode,
            ws: glkvmWebSocketClient
        )
    }

    private func stopMouseMoveSender() {
        mouseMoveGeneration &+= 1
        mouseMoveBuffer.invalidate()
    }

    func handleVideoMouseButton(button: MouseButton, isDown: Bool, pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) {
        refreshLocalInputFocus()
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let buttonEvent = MouseButtonEvent(button: button, isDown: isDown, position: normalized, timestamp: CACurrentMediaTime())
        sendMouseButtonEvent(buttonEvent)
    }

    func handleVideoMouseScroll(deltaX: CGFloat, deltaY: CGFloat) {
        refreshLocalInputFocus()
        guard isMouseCaptureEnabled else { return }
        let scrollEvent = MouseScrollEvent(deltaX: deltaX, deltaY: deltaY, timestamp: CACurrentMediaTime())
        sendMouseScrollEvent(scrollEvent)
    }

    func setTransportMode(_ mode: TransportMode) {
        guard transportMode != mode else { return }
        transportID = UUID().uuidString
        transportMode = mode
        switch mode {
        case .webRTC:
            stopMouseMoveSender()
            disconnectGLKVMWebSocket()
        case .glkvmWebSocket:
            Task { [weak self] in
                await self?.reconnectGLKVMWebSocketIfNeeded()
            }
        }
    }

    func disconnectGLKVMWebSocket() {
        transportID = UUID().uuidString
        stopMouseMoveSender()
        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        hidStatus = "Disconnected"
        hidReconnectTask?.cancel()
        hidReconnectTask = nil
        let priorCommands = hidCommandTail
        let releaseTask = enqueueHIDCommand(label: "Release inputs") {
            try await ws?.releaseAllHIDInputs()
        }
        let pendingCommands = releaseTask ?? priorCommands
        Task {
            let transportAbort = await ws?.scheduleCurrentTransportAbort(after: 2_000_000_000)
            await pendingCommands?.value
            transportAbort?.cancel()
            await ws?.disconnect()
        }
    }

    func disconnectInputForSession() async {
        setSessionAvailable(false)
        transportID = UUID().uuidString
        stopMouseMoveSender()
        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
        hidReconnectTask?.cancel()
        hidReconnectTask = nil

        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        glkvmClient = nil
        isGLKVMAbsoluteMouseMode = true
        hidStatus = "Disconnected"

        await waitForActivePrintOperationsToDrain()
        let priorCommands = hidCommandTail
        let releaseTask = enqueueHIDCommand(label: "Release inputs", completion: { [weak self] result in
            if case .failure = result {
                self?.latchUnconfirmedInput()
            }
        }) {
            try await ws?.releaseAllHIDInputs()
        }
        let transportAbort = await ws?.scheduleCurrentTransportAbort(after: 2_000_000_000)
        await (releaseTask ?? priorCommands)?.value
        transportAbort?.cancel()
        await ws?.disconnect()
    }

    func inputReadiness() async -> (text: Bool, mouse: Bool) {
        let capturedTransport = transportID
        let mouse = await glkvmWebSocketClient?.isConnected ?? false
        guard capturedTransport == transportID else { return (false, false) }
        return (glkvmClient != nil && !inputBlocked, mouse && !inputBlocked)
    }

    var controlEndpointID: String? {
        guard let url = glkvmClient?.baseURL else { return nil }
        return SnapshotEndpointIdentity.from(url)
    }
    
    func startKeyboardCapture() {
        localInputCapture.keyboardRequested = true
        installKeyboardMonitorIfNeeded()
        refreshLocalInputFocus()
    }

    private func installKeyboardMonitorIfNeeded() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.refreshLocalInputFocus()
            guard self.localInputCapture.keyboardEventIsEligible(event) else { return event }
            self.handleKeyEvent(event)
            return nil
        }
    }
    
    func stopKeyboardCapture() {
        localInputCapture.keyboardRequested = false
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        refreshLocalInputFocus()
    }
    
    func startMouseCapture() {
        localInputCapture.mouseRequested = true
        refreshLocalInputFocus()
    }

    func setLocalInputCaptureAllowed(_ allowed: Bool) {
        guard isLocalInputCaptureAllowed != allowed else {
            refreshLocalInputFocus()
            return
        }
        isLocalInputCaptureAllowed = allowed
        localInputCapture.modeReady = allowed
        refreshLocalInputFocus()
    }
    
    func stopMouseCapture() {
        localInputCapture.mouseRequested = false
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        refreshLocalInputFocus()
    }

    func setSessionAvailable(_ available: Bool) {
        localInputCapture.sessionAvailable = available
        refreshLocalInputFocus()
    }

    func setConnectionTransitioning(_ transitioning: Bool) {
        localInputCapture.connectionTransitioning = transitioning
        refreshLocalInputFocus()
    }

    func setLocalUIBlocked(_ blocked: Bool, owner: UUID) {
        localInputCapture.setLocalUIBlocked(blocked, owner: owner)
        refreshLocalInputFocus()
    }

    func registerRemoteInputSurface(_ surface: NSView) {
        localInputCapture.registerRemoteInputSurface(surface)
        refreshLocalInputFocus()
    }

    func unregisterRemoteInputSurface(_ surface: NSView) {
        localInputCapture.unregisterRemoteInputSurface(surface)
        refreshLocalInputFocus()
    }

    func refreshLocalInputFocus() {
        localInputCapture.inputBlocked = inputBlocked
        let previous = LocalInputCaptureDecision(
            keyboardEnabled: isKeyboardCaptureEnabled,
            mouseEnabled: isMouseCaptureEnabled
        )
        let next = localInputCapture.decision()
        guard previous != next else { return }

        if previous.keyboardEnabled && !next.keyboardEnabled {
            keyboardCaptureGeneration &+= 1
            clearPendingCommandKey()
            suppressedKeyUps.removeAll()
        }
        if previous.mouseEnabled && !next.mouseEnabled {
            mouseCaptureGeneration &+= 1
            stopMouseMoveSender()
        }

        isKeyboardCaptureEnabled = next.keyboardEnabled
        isMouseCaptureEnabled = next.mouseEnabled
        isCapturing = next.keyboardEnabled || next.mouseEnabled

        if LocalInputCapturePolicy.revoked(from: previous, to: next),
           let ws = glkvmWebSocketClient {
            enqueueHIDCommand(label: "Local input released") {
                try await ws.releaseAllHIDInputs()
            }
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        guard isKeyboardCaptureEnabled else { return }

        switch event.type {
        case .keyDown, .keyUp:
            let keyCode = event.keyCode
            let isKeyDown = event.type == .keyDown
            let modifiers = event.modifierFlags

            if !isKeyDown, suppressedKeyUps.contains(keyCode) {
                suppressedKeyUps.remove(keyCode)
                return
            }

            if isKeyDown, modifiers.contains(.command) {
                if keyCode == 8 {
                    prepareForLocalCommandShortcut()
                    suppressedKeyUps.insert(keyCode)
                    NotificationCenter.default.post(name: .overlookToggleCopyMode, object: nil)
                    return
                }
                if keyCode == 9 {
                    prepareForLocalCommandShortcut()
                    suppressedKeyUps.insert(keyCode)
                    pasteClipboardToRemote()
                    return
                }

                if let pending = pendingCommandKeyCode,
                   commandKeySentToRemote == false,
                   transportMode == .glkvmWebSocket,
                   let ws = glkvmWebSocketClient,
                   let metaKey = glkvmKeyForMacKeyCode(pending),
                   let keyName = glkvmKeyForMacKeyCode(keyCode) {
                    activeCommandKeyCode = pending
                    pendingCommandKeyCode = nil
                    commandKeySentToRemote = true

                    enqueueLocalKeyboardHIDCommand(label: "Key combination") {
                        try await ws.sendHidKey(key: metaKey, state: true)
                        try await ws.sendHidKey(key: keyName, state: true)
                    }
                    return
                }

                flushPendingCommandKeyIfNeeded(timestamp: event.timestamp, modifiers: modifiers)
            }

            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: isKeyDown,
                modifiers: modifiers,
                timestamp: event.timestamp
            )

            sendKeyEvent(keyEvent)

        case .flagsChanged:
            let keyCode = event.keyCode
            guard let keyName = glkvmKeyForMacKeyCode(keyCode) else { return }

            let flags = event.modifierFlags
            let isDown: Bool
            switch keyName {
            case "ShiftLeft", "ShiftRight":
                isDown = flags.contains(.shift)
            case "ControlLeft", "ControlRight":
                isDown = flags.contains(.control)
            case "AltLeft", "AltRight":
                isDown = flags.contains(.option)
            case "MetaLeft", "MetaRight":
                isDown = flags.contains(.command)
                if isDown {
                    pendingCommandKeyCode = keyCode
                    activeCommandKeyCode = nil
                    commandKeySentToRemote = false
                    return
                }

                if commandKeySentToRemote {
                    let keyEvent = KeyEvent(
                        keyCode: activeCommandKeyCode ?? keyCode,
                        isKeyDown: false,
                        modifiers: flags,
                        timestamp: event.timestamp
                    )
                    sendKeyEvent(keyEvent)
                }

                clearPendingCommandKey()
                return
            case "CapsLock":
                isDown = flags.contains(.capsLock)
            default:
                return
            }

            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: isDown,
                modifiers: flags,
                timestamp: event.timestamp
            )
            sendKeyEvent(keyEvent)

        default:
            break
        }
    }

    private func prepareForLocalCommandShortcut() {
        if commandKeySentToRemote,
           transportMode == .glkvmWebSocket,
           let ws = glkvmWebSocketClient,
           let code = activeCommandKeyCode,
           let metaKey = glkvmKeyForMacKeyCode(code) {
            enqueueLocalKeyboardHIDCommand(label: "Modifier released") {
                try await ws.sendHidKey(key: metaKey, state: false)
            }
        }

        pendingCommandKeyCode = activeCommandKeyCode ?? pendingCommandKeyCode
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func clearPendingCommandKey() {
        pendingCommandKeyCode = nil
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func flushPendingCommandKeyIfNeeded(timestamp: TimeInterval, modifiers: NSEvent.ModifierFlags) {
        guard let pendingCommandKeyCode, commandKeySentToRemote == false else { return }
        activeCommandKeyCode = pendingCommandKeyCode
        self.pendingCommandKeyCode = nil
        commandKeySentToRemote = true

        let keyEvent = KeyEvent(
            keyCode: activeCommandKeyCode ?? pendingCommandKeyCode,
            isKeyDown: true,
            modifiers: modifiers,
            timestamp: timestamp
        )
        sendKeyEvent(keyEvent)
    }

    private func pasteClipboardToRemote() {
        guard let text = clipboardText() else { return }
        guard !text.isEmpty else { return }
        let authorization = makeLocalKeyboardAuthorization()

        localClipboardTransferTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendTextToRemote(text, authorization: authorization)
            } catch RemoteTextInputError.authorizationExpired {
                // Focus or mode changed before the asynchronous paste could dispatch.
            } catch {
                self.lastInputError = error.localizedDescription
                self.activityStatus = "Clipboard transfer failed"
            }
        }
    }

    func makeLocalKeyboardAuthorization() -> @MainActor @Sendable () -> Bool {
        let captureGeneration = keyboardCaptureGeneration
        return { [weak self] in
            guard let self else { return false }
            self.refreshLocalInputFocus()
            return self.isKeyboardCaptureEnabled
                && self.keyboardCaptureGeneration == captureGeneration
        }
    }

    func sendTextToRemote(
        _ text: String,
        authorization: @escaping @MainActor @Sendable () -> Bool = { true },
        willDispatch: @escaping @MainActor @Sendable () throws -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        guard !inputBlocked else { throw RemoteActionError.inputBlocked }
        guard authorization() else {
            throw RemoteTextInputError.authorizationExpired
        }
        guard let client = glkvmClient else {
            throw RemoteTextInputError.notConnected
        }

        guard !text.isEmpty else {
            throw RemoteTextInputError.emptyText
        }

        let keymap: String? = try? await client.getSystemConfig().keymap
        try Task.checkCancellation()
        guard authorization(), glkvmClient === client, !inputBlocked else {
            throw RemoteTextInputError.authorizationExpired
        }
        try willDispatch()
        beginPrintOperation()
        defer { finishPrintOperation() }
        do {
            try await client.hidPrint(text: text, keymap: keymap)
            try Task.checkCancellation()
        } catch {
            latchUnconfirmedInput()
            throw error
        }
        activityStatus = "Text sent (\(text.count) characters)"
        lastInputError = nil
    }

    private func beginPrintOperation() {
        activePrintOperations += 1
    }

    private func finishPrintOperation() {
        precondition(activePrintOperations > 0)
        activePrintOperations -= 1
        guard activePrintOperations == 0 else { return }
        let waiters = activePrintDrainWaiters
        activePrintDrainWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func waitForActivePrintOperationsToDrain() async {
        guard activePrintOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            activePrintDrainWaiters = activePrintDrainWaiters + [continuation]
        }
    }

    func sendCodexShortcut(
        keys: [String],
        authorization: @escaping @MainActor @Sendable () -> Bool = { true },
        willDispatch: @escaping @MainActor @Sendable () throws -> Void = {}
    ) async throws {
        try Task.checkCancellation()
        guard !inputBlocked else { throw RemoteActionError.inputBlocked }
        guard authorization() else {
            throw RemoteTextInputError.authorizationExpired
        }
        guard RemoteShortcutPolicy.accepts(keys) else {
            throw RemoteTextInputError.invalidShortcut
        }
        guard let client = glkvmClient else {
            throw RemoteTextInputError.notConnected
        }

        try willDispatch()
        do {
            try await client.sendHidShortcut(keys: keys)
            try Task.checkCancellation()
        } catch {
            latchUnconfirmedInput()
            throw error
        }
        activityStatus = "Shortcut sent (\(keys.joined(separator: "+")))"
        lastInputError = nil
    }

    func sendCodexClick(
        signedX: Int,
        signedY: Int,
        authorization: @escaping @MainActor @Sendable () -> Bool = { true },
        willDispatch: @escaping @MainActor @Sendable () throws -> Void = {}
    ) async throws {
        let x = Self.clampInt(signedX, min: -32_767, max: 32_767)
        let y = Self.clampInt(signedY, min: -32_767, max: 32_767)
        try await sendRemoteMouseGesture(
            label: "Codex click", authorization: authorization, willDispatch: willDispatch
        ) { ws in
            try await ws.sendHidMouseMove(toX: x, toY: y)
            try Task.checkCancellation()
            guard await authorization() else { throw RemoteTextInputError.authorizationExpired }
            try await RemoteGestureCleanup.perform(
                press: { try await ws.sendHidMouseButton(button: "left", state: true) },
                body: { try await Task.sleep(nanoseconds: 50_000_000) },
                release: { try await ws.sendHidMouseButton(button: "left", state: false) }
            )
        }
    }

    func performRemoteAction(
        _ action: RemoteActionCommand, width: Int, height: Int,
        authorization: @escaping @MainActor @Sendable () -> Bool,
        willDispatch: @escaping @MainActor @Sendable () throws -> Void
    ) async throws {
        try action.validate(width: width, height: height)
        switch action {
        case .text(let text):
            try await sendTextToRemote(text, authorization: authorization, willDispatch: willDispatch)
        case .shortcut(let keys):
            try await sendCodexShortcut(keys: keys, authorization: authorization, willDispatch: willDispatch)
        case .click(let x, let y):
            try await sendCodexClick(signedX: RemoteActionCommand.signedHID(pixel: x, extent: width),
                                    signedY: RemoteActionCommand.signedHID(pixel: y, extent: height),
                                    authorization: authorization, willDispatch: willDispatch)
        case .scroll(let x, let y, let delta):
            try await sendRemoteMouseGesture(label: "Codex scroll", authorization: authorization, willDispatch: willDispatch) { ws in
                try await ws.sendHidMouseMove(toX: RemoteActionCommand.signedHID(pixel: x, extent: width),
                                            toY: RemoteActionCommand.signedHID(pixel: y, extent: height))
                try Task.checkCancellation()
                guard await authorization() else { throw RemoteTextInputError.authorizationExpired }
                try await ws.sendHidMouseWheel(deltaX: 0, deltaY: delta)
            }
        case .drag(let x, let y, let toX, let toY, let duration):
            try await sendRemoteMouseGesture(label: "Codex drag", authorization: authorization, willDispatch: willDispatch) { ws in
                try await ws.sendHidMouseMove(toX: RemoteActionCommand.signedHID(pixel: x, extent: width),
                                            toY: RemoteActionCommand.signedHID(pixel: y, extent: height))
                try Task.checkCancellation()
                guard await authorization() else { throw RemoteTextInputError.authorizationExpired }
                let steps = max(2, min(40, duration / 50))
                try await RemoteGestureCleanup.perform(
                    press: { try await ws.sendHidMouseButton(button: "left", state: true) },
                    body: {
                        for step in 1...steps {
                            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000 / steps))
                            guard await authorization() else { throw RemoteTextInputError.authorizationExpired }
                            let px = x + (toX - x) * step / steps
                            let py = y + (toY - y) * step / steps
                            try await ws.sendHidMouseMove(toX: RemoteActionCommand.signedHID(pixel: px, extent: width),
                                                        toY: RemoteActionCommand.signedHID(pixel: py, extent: height))
                        }
                    },
                    release: { try await ws.sendHidMouseButton(button: "left", state: false) }
                )
            }
        }
    }

    private func sendRemoteMouseGesture(
        label: String,
        authorization: @escaping @MainActor @Sendable () -> Bool,
        willDispatch: @escaping @MainActor @Sendable () throws -> Void,
        operation: @escaping @Sendable (GLKVMClient.WebSocketClient) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !inputBlocked else { throw RemoteActionError.inputBlocked }
        guard authorization() else { throw RemoteTextInputError.authorizationExpired }
        guard transportMode == .glkvmWebSocket, isGLKVMAbsoluteMouseMode, let ws = glkvmWebSocketClient else {
            throw RemoteTextInputError.notConnected
        }
        let expectedTransport = transportID
        let cancellationHandle = HIDCommandCancellationHandle()
        let commandContinuation = CancellableCommandContinuation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                commandContinuation.install(continuation)
                let task = enqueueHIDCommand(label: label, completion: { result in
                    commandContinuation.resume(with: result)
                }) { [weak self] in
                    try Task.checkCancellation()
                    try await MainActor.run {
                        guard let self, !self.inputBlocked, self.transportID == expectedTransport, authorization() else {
                            throw RemoteTextInputError.authorizationExpired
                        }
                        try willDispatch()
                    }
                    do {
                        try await operation(ws)
                    } catch {
                        if error as? RemoteActionError == .cleanupFailed {
                            await MainActor.run { self?.latchUnconfirmedInput() }
                        }
                        throw error
                    }
                }
                cancellationHandle.install(task)
            }
        } onCancel: {
            cancellationHandle.cancel()
            // The inner task owns completion: cancellation must not release the
            // common mutation gate until bounded button-up cleanup has finished.
        }
    }

    enum RemoteTextInputError: LocalizedError, Equatable {
        case notConnected
        case emptyText
        case authorizationExpired
        case invalidShortcut

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "GLKVM input is not connected."
            case .emptyText:
                return "Enter text before sending."
            case .authorizationExpired:
                return "Headless authorization expired before remote input."
            case .invalidShortcut:
                return "Shortcut contains unsupported or too many keys."
            }
        }
    }

    private func latchUnconfirmedInput() {
        inputBlocked = true
        refreshLocalInputFocus()
        activityStatus = "Input blocked: previous remote outcome is unknown"
    }

    /// Only the explicit Manual UI recovery calls this. It never changes the
    /// control mode or upgrades an earlier unknown action to success.
    func recoverInputAfterManualReview(
        authorization: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        guard inputBlocked, isLocalInputCaptureAllowed, authorization() else { throw RemoteActionError.unauthorized }
        let capturedTransport = transportID
        let pending = hidCommandTail
        try await RemoteGestureCleanup.perform(press: {}, body: {}, release: { await pending?.value })
        guard authorization(), isLocalInputCaptureAllowed, capturedTransport == transportID else {
            throw RemoteActionError.sessionChanged
        }
        guard let ws = glkvmWebSocketClient else { throw RemoteActionError.inputUnavailable }
        try await RemoteGestureCleanup.perform(press: {}, body: {}, release: { try await ws.releaseAllHIDInputs() })
        guard authorization(), isLocalInputCaptureAllowed, capturedTransport == transportID else {
            throw RemoteActionError.sessionChanged
        }
        try Task.checkCancellation()
        inputBlocked = false
        transportID = UUID().uuidString
        activityStatus = "Manual review acknowledged; input release transmitted"
        lastInputError = nil
        refreshLocalInputFocus()
    }
    
    private func handleMouseEvent(_ event: NSEvent) {
        guard isMouseCaptureEnabled else { return }
        
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let mouseEvent = MouseButtonEvent(
                button: event.type == .leftMouseDown || event.type == .leftMouseUp ? .left : .right,
                isDown: event.type == .leftMouseDown || event.type == .rightMouseDown,
                position: CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y),
                timestamp: event.timestamp
            )
            sendMouseButtonEvent(mouseEvent)
            
        case .mouseMoved:
            let mouseEvent = MouseMoveEvent(
                position: CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y),
                delta: CGSize(width: event.deltaX, height: -event.deltaY),
                timestamp: event.timestamp
            )
            sendMouseMoveEvent(mouseEvent)
            
        case .scrollWheel:
            let scrollEvent = MouseScrollEvent(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                timestamp: event.timestamp
            )
            sendMouseScrollEvent(scrollEvent)
            
        default:
            break
        }
    }
    
    func sendClick(at location: CGPoint, in geometry: GeometryProxy, videoSize: CGSize? = nil) {
        let normalizedPosition = normalizePointInViewToVideo(
            pointInView: location,
            viewSize: geometry.size,
            videoSize: videoSize
        )
        
        let clickEvent = MouseButtonEvent(
            button: .left,
            isDown: true,
            position: normalizedPosition,
            timestamp: CACurrentMediaTime()
        )
        
        sendMouseButtonEvent(clickEvent)
        
        // Send release event after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let releaseEvent = MouseButtonEvent(
                button: .left,
                isDown: false,
                position: normalizedPosition,
                timestamp: CACurrentMediaTime()
            )
            self.sendMouseButtonEvent(releaseEvent)
        }
    }
    
    private func sendKeyEvent(_ event: KeyEvent) {
        if transportMode == .glkvmWebSocket,
           let key = glkvmKeyForMacKeyCode(event.keyCode),
           let ws = glkvmWebSocketClient {
            enqueueLocalKeyboardHIDCommand(label: event.isKeyDown ? "Key down" : "Key up") {
                let isShiftKey = key == "ShiftLeft" || key == "ShiftRight"
                let carriesSyntheticShift = !isShiftKey && event.modifiers.contains(.shift)
                if event.isKeyDown && carriesSyntheticShift {
                    try await ws.sendHidKey(key: "ShiftLeft", state: true)
                }
                try await ws.sendHidKey(key: key, state: event.isKeyDown)
                if !event.isKeyDown && carriesSyntheticShift {
                    try await ws.sendHidKey(key: "ShiftLeft", state: false)
                }
            }
            return
        }

        let inputEvent = InputEvent(
            type: "keyboard",
            data: [
                "keyCode": .int(Int(event.keyCode)),
                "isKeyDown": .bool(event.isKeyDown),
                "modifiers": .int(Int(event.modifiers.rawValue)),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseButtonEvent(_ event: MouseButtonEvent) {
        if transportMode == .glkvmWebSocket,
           let button = glkvmMouseButtonName(event.button),
           let ws = glkvmWebSocketClient {
            let shouldMove = isGLKVMAbsoluteMouseMode && isNormalized(event.position)
            let absolutePoint = shouldMove ? glkvmAbsolutePoint(fromNormalized: event.position) : nil
            enqueueLocalMouseHIDCommand(label: event.isDown ? "Mouse down" : "Mouse up") {
                if let absolutePoint {
                    try await ws.sendHidMouseMove(toX: absolutePoint.0, toY: absolutePoint.1)
                }
                try await ws.sendHidMouseButton(button: button, state: event.isDown)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-button",
            data: [
                "button": .int(event.button.rawValue),
                "isDown": .bool(event.isDown),
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseMoveEvent(_ event: MouseMoveEvent) {
        if transportMode == .glkvmWebSocket, isGLKVMAbsoluteMouseMode {
            enqueueAbsoluteMouseMoveEvent(event)
            return
        }

        if transportMode == .glkvmWebSocket, !isGLKVMAbsoluteMouseMode {
            enqueueRelativeMouseMoveEvent(event)
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-move",
            data: [
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseScrollEvent(_ event: MouseScrollEvent) {
        if transportMode == .glkvmWebSocket, let ws = glkvmWebSocketClient {
            let dx = Self.clampInt(Int(event.deltaX.rounded()), min: -127, max: 127)
            let dy = Self.clampInt(Int(event.deltaY.rounded()), min: -127, max: 127)
            enqueueLocalMouseHIDCommand(label: "Mouse wheel", successFeedback: .errorsOnly) {
                try await ws.sendHidMouseWheel(deltaX: dx, deltaY: dy)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-scroll",
            data: [
                "deltaX": .double(event.deltaX),
                "deltaY": .double(event.deltaY),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    func sendKeyCombination(_ keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        for keyCode in keys {
            let keyDownEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: modifiers,
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyDownEvent)
        }
        
        // Send key up events after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for keyCode in keys.reversed() {
                let keyUpEvent = KeyEvent(
                    keyCode: keyCode,
                    isKeyDown: false,
                    modifiers: modifiers,
                    timestamp: CACurrentMediaTime()
                )
                self.sendKeyEvent(keyUpEvent)
            }
        }
    }
    
    func sendText(_ text: String) {
        for character in text {
            let keyCode = self.keyCodeForCharacter(character)
            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyEvent)
            
            // Send key up event
            let keyUpEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: false,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyUpEvent)
        }
    }

    private func observeLocalInputFocusChanges() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification
        ]
        localInputFocusObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLocalInputFocus()
                }
            }
        }
    }
    
    private func keyCodeForCharacter(_ character: Character) -> UInt16 {
        // Basic mapping for common characters
        // In a real implementation, you'd want a more comprehensive mapping
        switch character {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case " ": return 49
        case "\n": return 36
        case ",": return 43
        case ".": return 47
        case "/": return 44
        case ";": return 41
        case "'": return 39
        case "[": return 33
        case "]": return 30
        case "\\": return 42
        case "`": return 50
        case "-": return 27
        case "=": return 24
        default: return 0
        }
    }
    
    deinit {
        for observer in localInputFocusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        localInputFocusObservers.removeAll()

        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }

        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }

        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
        mouseMoveGeneration &+= 1
        mouseMoveBuffer.invalidate()
    }

    func shutdown() async {
        acceptsHIDCommands = false
        stopFullInputCapture()
        stopMouseMoveSender()
        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
        hidReconnectTask?.cancel()
        hidReconnectTask = nil
        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        let transportAbort = await ws?.scheduleCurrentTransportAbort(after: 2_000_000_000)
        let pendingCommands = hidCommandTail
        await pendingCommands?.value
        hidCommandTail = nil

        try? await ws?.releaseAllHIDInputs()
        transportAbort?.cancel()
        await ws?.disconnect()
        activityStatus = "Input stopped"
    }

    private func reconnectGLKVMWebSocketIfNeeded() async {
        guard acceptsHIDCommands else { return }
        if transportMode != .glkvmWebSocket {
            return
        }
        guard let client = glkvmClient else {
            return
        }
        let expectedTransport = transportID
        let connected = await glkvmWebSocketClient?.isConnected ?? false
        let connecting = await glkvmWebSocketClient?.isConnecting ?? false
        guard acceptsHIDCommands,
              !Task.isCancelled,
              glkvmClient === client,
              transportID == expectedTransport,
              transportMode == .glkvmWebSocket else { return }
        if !connected && !connecting {
            await glkvmWebSocketClient?.disconnect()
            guard acceptsHIDCommands,
                  !Task.isCancelled,
                  glkvmClient === client,
                  transportID == expectedTransport else { return }
            let ws = try? client.makeWebSocketClient(stream: false)
            glkvmWebSocketClient = ws
            transportID = UUID().uuidString
            let installedTransport = transportID
            await ws?.connect()
            guard acceptsHIDCommands,
                  !Task.isCancelled,
                  glkvmClient === client,
                  transportID == installedTransport else {
                if glkvmWebSocketClient === ws {
                    glkvmWebSocketClient = nil
                }
                await ws?.disconnect()
                return
            }
            // Reconnection does not prove that an earlier HTTP print has stopped
            // or that an unconfirmed release reached the remote application.
            activityStatus = ws == nil ? "HID connection failed" : "HID connecting"
            hidStatus = ws == nil ? "Failed" : "Connecting"
        }
    }

    private func enqueueLocalKeyboardHIDCommand(
        label: String,
        successFeedback: HIDCommandSuccessFeedbackMode = .publishChanges,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        let generation = keyboardCaptureGeneration
        enqueueHIDCommand(
            label: label,
            successFeedback: successFeedback,
            executionAllowed: { [weak self] in
                guard let self else { return false }
                self.refreshLocalInputFocus()
                return self.isKeyboardCaptureEnabled && self.keyboardCaptureGeneration == generation
            },
            operation: operation
        )
    }

    private func enqueueLocalMouseHIDCommand(
        label: String,
        successFeedback: HIDCommandSuccessFeedbackMode = .publishChanges,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        let generation = mouseCaptureGeneration
        enqueueHIDCommand(
            label: label,
            successFeedback: successFeedback,
            executionAllowed: { [weak self] in
                guard let self else { return false }
                self.refreshLocalInputFocus()
                return self.isMouseCaptureEnabled && self.mouseCaptureGeneration == generation
            },
            operation: operation
        )
    }

    @discardableResult
    private func enqueueHIDCommand(
        label: String,
        completion: (@MainActor @Sendable (Result<Void, Error>) -> Void)? = nil,
        successFeedback: HIDCommandSuccessFeedbackMode = .publishChanges,
        freezesPendingMouseMove: Bool = true,
        executionAllowed: @escaping @MainActor @Sendable () -> Bool = { true },
        operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never>? {
        guard acceptsHIDCommands else {
            completion?(.failure(CancellationError()))
            return nil
        }
        if freezesPendingMouseMove {
            freezeMouseMovesForOrderedHIDCommand()
        }
        let predecessor = hidCommandTail
        let task = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else {
                completion?(.failure(CancellationError()))
                return
            }
            guard executionAllowed() else {
                completion?(.success(()))
                return
            }
            do {
                try await operation()
                if let self,
                   let feedback = HIDCommandFeedbackPolicy.successUpdate(
                       currentStatus: self.activityStatus,
                       currentError: self.lastInputError,
                       nextStatus: label,
                       mode: successFeedback
                   ) {
                    if self.activityStatus != feedback.status {
                        self.activityStatus = feedback.status
                    }
                    if feedback.clearsError {
                        self.lastInputError = nil
                    }
                }
                completion?(.success(()))
            } catch {
                if let self {
                    if let webSocketError = error as? GLKVMClient.WebSocketClient.WebSocketError,
                       case .sendTimedOut = webSocketError {
                        self.latchUnconfirmedInput()
                    }
                    let errorDescription = error.localizedDescription
                    if let feedback = HIDCommandFeedbackPolicy.failureUpdate(
                        currentStatus: self.activityStatus,
                        currentError: self.lastInputError,
                        nextError: errorDescription
                    ) {
                        if self.lastInputError != errorDescription {
                            self.lastInputError = errorDescription
                        }
                        if self.activityStatus != feedback.status {
                            self.activityStatus = feedback.status
                        }
                    }
                    if error as? RemoteTextInputError != .authorizationExpired {
                        self.scheduleHIDReconnect()
                    }
                }
                completion?(.failure(error))
            }
        }
        hidCommandTail = task
        return task
    }

    private func scheduleHIDReconnect() {
        guard acceptsHIDCommands, hidReconnectTask == nil else { return }
        hidReconnectTask = Task { [weak self] in
            for delay in [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000] as [UInt64] {
                guard !Task.isCancelled, let self else { return }
                try? await Task.sleep(nanoseconds: delay)
                await self.reconnectGLKVMWebSocketIfNeeded()
                let connected = await self.glkvmWebSocketClient?.isConnected == true
                guard self.acceptsHIDCommands, !Task.isCancelled else { return }
                if connected {
                    self.hidStatus = "Connected"
                    self.hidReconnectTask = nil
                    return
                }
            }
            self?.hidReconnectTask = nil
        }
    }

    private func isNormalized(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }

    private func glkvmAbsolutePoint(fromNormalized point: CGPoint) -> (Int, Int) {
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))
        let maxAxis = 32767.0

        let signedX = (clampedX * 2.0 - 1.0) * maxAxis
        let signedY = (clampedY * 2.0 - 1.0) * maxAxis

        return (Int(signedX.rounded()), Int(signedY.rounded()))
    }

    func normalizePointInViewToVideo(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            let clampedX = max(0, min(1, pointInView.x / viewSize.width))
            let clampedY = max(0, min(1, pointInView.y / viewSize.height))
            return CGPoint(x: clampedX, y: clampedY)
        }

        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        var contentRect = CGRect(origin: .zero, size: viewSize)

        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            contentRect = CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            contentRect = CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }

        let clampedX = max(contentRect.minX, min(contentRect.maxX, pointInView.x))
        let clampedY = max(contentRect.minY, min(contentRect.maxY, pointInView.y))

        let normalizedX = (clampedX - contentRect.minX) / contentRect.width
        let normalizedY = (clampedY - contentRect.minY) / contentRect.height

        return CGPoint(x: max(0, min(1, normalizedX)), y: max(0, min(1, normalizedY)))
    }

    private func glkvmMouseButtonName(_ button: MouseButton) -> String? {
        switch button {
        case .left:
            return "left"
        case .right:
            return "right"
        case .middle:
            return "middle"
        }
    }

    private func glkvmKeyForMacKeyCode(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "KeyA"
        case 11: return "KeyB"
        case 8: return "KeyC"
        case 2: return "KeyD"
        case 14: return "KeyE"
        case 3: return "KeyF"
        case 5: return "KeyG"
        case 4: return "KeyH"
        case 34: return "KeyI"
        case 38: return "KeyJ"
        case 40: return "KeyK"
        case 37: return "KeyL"
        case 46: return "KeyM"
        case 45: return "KeyN"
        case 31: return "KeyO"
        case 35: return "KeyP"
        case 12: return "KeyQ"
        case 15: return "KeyR"
        case 1: return "KeyS"
        case 17: return "KeyT"
        case 32: return "KeyU"
        case 9: return "KeyV"
        case 13: return "KeyW"
        case 7: return "KeyX"
        case 16: return "KeyY"
        case 6: return "KeyZ"

        case 18: return "Digit1"
        case 19: return "Digit2"
        case 20: return "Digit3"
        case 21: return "Digit4"
        case 23: return "Digit5"
        case 22: return "Digit6"
        case 26: return "Digit7"
        case 28: return "Digit8"
        case 25: return "Digit9"
        case 29: return "Digit0"

        case 50: return "Backquote"
        case 27: return "Minus"
        case 24: return "Equal"
        case 33: return "BracketLeft"
        case 30: return "BracketRight"
        case 41: return "Semicolon"
        case 39: return "Quote"
        case 42: return "Backslash"
        case 43: return "Comma"
        case 47: return "Period"
        case 44: return "Slash"

        case 49: return "Space"
        case 48: return "Tab"
        case 36: return "Enter"
        case 51: return "Backspace"
        case 53: return "Escape"

        case 82: return "Numpad0"
        case 83: return "Numpad1"
        case 84: return "Numpad2"
        case 85: return "Numpad3"
        case 86: return "Numpad4"
        case 87: return "Numpad5"
        case 88: return "Numpad6"
        case 89: return "Numpad7"
        case 91: return "Numpad8"
        case 92: return "Numpad9"
        case 65: return "NumpadDecimal"
        case 67: return "NumpadMultiply"
        case 69: return "NumpadAdd"
        case 78: return "NumpadSubtract"
        case 75: return "NumpadDivide"
        case 76: return "NumpadEnter"
        case 81: return "NumpadEqual"

        case 114: return "Help"

        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 117: return "Delete"

        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"

        case 55: return "MetaLeft"
        case 54: return "MetaRight"
        case 56: return "ShiftLeft"
        case 60: return "ShiftRight"
        case 58: return "AltLeft"
        case 61: return "AltRight"
        case 59: return "ControlLeft"
        case 62: return "ControlRight"
        case 57: return "CapsLock"

        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"

        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"

        default:
            return nil
        }
    }

    private static func sendRelativeMouseMove(_ move: PendingRelativeMouseMove, through ws: GLKVMClient.WebSocketClient) async throws {
        var remainingX = move.deltaX
        var remainingY = move.deltaY

        while remainingX != 0 || remainingY != 0 {
            let dx = clampInt(remainingX, min: -127, max: 127)
            let dy = clampInt(remainingY, min: -127, max: 127)
            try await ws.sendHidMouseRelative(deltaX: dx, deltaY: dy)
            remainingX -= dx
            remainingY -= dy
        }
    }

    private static func sendMouseMoveCommand(
        _ command: PendingMouseMoveCommand,
        through ws: GLKVMClient.WebSocketClient
    ) async throws {
        switch command {
        case .absolute(let move):
            try await ws.sendHidMouseMove(toX: move.toX, toY: move.toY)
        case .relative(let move):
            try await sendRelativeMouseMove(move, through: ws)
        }
    }

    private static func clampInt(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

private final class HIDCommandCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func install(_ task: Task<Void, Never>?) {
        guard let task else { return }
        lock.lock()
        let shouldCancel = isCancelled
        if !shouldCancel { self.task = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let currentTask = task
        task = nil
        lock.unlock()
        currentTask?.cancel()
    }
}

// MARK: - Input Event Types
struct KeyEvent {
    let keyCode: UInt16
    let isKeyDown: Bool
    let modifiers: NSEvent.ModifierFlags
    let timestamp: CFTimeInterval
}

struct MouseButtonEvent {
    let button: MouseButton
    let isDown: Bool
    let position: CGPoint
    let timestamp: CFTimeInterval
}

struct MouseMoveEvent {
    let position: CGPoint
    let delta: CGSize
    let timestamp: CFTimeInterval
}

struct MouseScrollEvent {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let timestamp: CFTimeInterval
}

enum MouseButton: Int, Codable, Hashable {
    case left = 0
    case right = 1
    case middle = 2
}

// MARK: - Input Capture Extensions
extension InputManager {
    func toggleKeyboardCapture() {
        if localInputCapture.keyboardRequested {
            stopKeyboardCapture()
        } else {
            startKeyboardCapture()
        }
    }
    
    func toggleMouseCapture() {
        if localInputCapture.mouseRequested {
            stopMouseCapture()
        } else {
            startMouseCapture()
        }
    }
    
    func startFullInputCapture() {
        localInputCapture.keyboardRequested = true
        localInputCapture.mouseRequested = true
        installKeyboardMonitorIfNeeded()
        refreshLocalInputFocus()
    }
    
    func stopFullInputCapture() {
        localInputCapture.keyboardRequested = false
        localInputCapture.mouseRequested = false
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        refreshLocalInputFocus()
    }
}

// MARK: - Accessibility Permissions Helper
extension InputManager {
    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func showAccessibilityPermissionDialog() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Required"
        alert.informativeText = "Overlook needs accessibility permissions to capture keyboard and mouse input for remote control. Please grant permissions in System Preferences > Security & Privacy > Privacy > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Preferences to Accessibility section
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Input Validation and Filtering
extension InputManager {
    private func shouldCaptureKeyEvent(_ event: NSEvent) -> Bool {
        // Filter out system key combinations that should remain local
        let systemKeyCombinations: [UInt16] = [
            55, // Command
            56, // Shift
            57, // Option
            58, // Control
            59, // Caps Lock
            60, // Function
        ]
        
        return !systemKeyCombinations.contains(event.keyCode)
    }
    
    private func shouldCaptureMouseEvent(_ event: NSEvent) -> Bool {
        // Filter out mouse events that should remain local
        // This is a basic implementation - you might want to add more sophisticated filtering
        return true
    }
}
