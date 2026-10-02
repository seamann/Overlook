import Foundation
import CoreGraphics

enum HIDCommand: Equatable, Sendable {
    case key(String, isPressed: Bool)
    case releaseAll
}

enum HIDCommandSequencer {
    static func commands(key: String, isPressed: Bool, requiresShift: Bool) -> [HIDCommand] {
        if requiresShift {
            return isPressed
                ? [.key("ShiftLeft", isPressed: true), .key(key, isPressed: true)]
                : [.key(key, isPressed: false), .key("ShiftLeft", isPressed: false)]
        }
        return [.key(key, isPressed: isPressed)]
    }

    static let releaseAll: [HIDCommand] = [.releaseAll]
}

struct ReconnectBackoff: Sendable {
    let initialDelay: TimeInterval
    let multiplier: Double
    let maximumDelay: TimeInterval

    func delay(forAttempt attempt: Int) -> TimeInterval {
        min(maximumDelay, initialDelay * pow(multiplier, Double(max(0, attempt))))
    }
}

struct ClipboardPayload: Equatable, Sendable {
    let text: String
    init(rawText: String) { self.text = rawText }
    static func text(_ text: String) -> Self { Self(text: text) }
    private init(text: String) { self.text = text }
}

enum WindowFramePersistence {
    static func key(for mode: OverlookControlMode) -> String {
        "overlook.windowFrame.\(mode.rawValue).v1"
    }
}

enum ControlModeWindowTransitionPolicy {
    // Window animations started by an NSPopUpButton action can crash inside
    // AppKit's nested menu-tracking run loop.
    static let animatesFrameChanges = false
    static let defersPickerSelection = true
}

struct HeadlessConfigurationLockState: Sendable {
    private var isHeadlessModeActive = false
    private var transitionOwners: Set<UUID> = []

    var isLocked: Bool {
        isHeadlessModeActive || !transitionOwners.isEmpty
    }

    mutating func beginTransition() -> UUID {
        let owner = UUID()
        transitionOwners.insert(owner)
        return owner
    }

    mutating func endTransition(_ owner: UUID) {
        transitionOwners.remove(owner)
    }

    mutating func setHeadlessModeActive(_ isActive: Bool) {
        isHeadlessModeActive = isActive
    }

    mutating func reset() {
        isHeadlessModeActive = false
        transitionOwners.removeAll()
    }
}

struct OperationOwnershipState: Sendable {
    private var owners: Set<UUID> = []

    var isActive: Bool { !owners.isEmpty }

    mutating func begin() -> UUID {
        let owner = UUID()
        owners.insert(owner)
        return owner
    }

    mutating func end(_ owner: UUID) {
        owners.remove(owner)
    }

    mutating func reset() {
        owners.removeAll()
    }
}

enum ControlServerRetryPolicy {
    static let maximumDelay: TimeInterval = 30

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let boundedExponent = min(max(0, attempt), 6)
        return min(maximumDelay, 0.5 * pow(2, Double(boundedExponent)))
    }
}

enum ControlServerConnectionPolicy {
    static let maximumConnections = 16
    static let requestReadTimeout: TimeInterval = 2
    static let commandTimeout: TimeInterval = 30
}

@MainActor
final class RemoteMutationGate {
    private var isExecuting = false
    private var mutationWaiters: [MutationWaiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let maximumPendingMutations: Int

    private struct MutationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    init(maximumPendingMutations: Int = ControlServerConnectionPolicy.maximumConnections) {
        self.maximumPendingMutations = maximumPendingMutations
    }

    var pendingMutationCount: Int { mutationWaiters.count }
    var isBusy: Bool { isExecuting || !mutationWaiters.isEmpty }

    func perform<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func waitUntilIdle() async {
        guard isExecuting || !mutationWaiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isExecuting else {
            isExecuting = true
            return
        }
        guard mutationWaiters.count < maximumPendingMutations else {
            throw RemoteMutationGateError.queueFull
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    mutationWaiters.append(MutationWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    private func release() {
        if !mutationWaiters.isEmpty {
            mutationWaiters.removeFirst().continuation.resume()
            return
        }
        isExecuting = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = mutationWaiters.firstIndex(where: { $0.id == id }) else { return }
        mutationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

enum RemoteMutationGateError: LocalizedError {
    case queueFull

    var errorDescription: String? {
        "Too many remote input commands are already pending."
    }
}

final class CancellableCommandContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        precondition(self.continuation == nil, "Command continuation installed more than once")
        let result = pendingResult
        pendingResult = nil
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let currentContinuation = continuation
        continuation = nil
        if currentContinuation == nil { pendingResult = result }
        lock.unlock()
        currentContinuation?.resume(with: result)
    }

    func cancel() {
        resume(with: .failure(CancellationError()))
    }
}

enum ControlCommandKind: Sendable {
    case status
    case mutation
}

enum ControlMutationPolicy {
    static func allows(_ command: ControlCommandKind, in mode: OverlookControlMode) -> Bool {
        switch command {
        case .status:
            return true
        case .mutation:
            return mode == .codexHeadless
        }
    }
}

enum MouseJigglerPolicy {
    static func canToggle(
        mode: OverlookControlMode,
        isConnected: Bool,
        isAvailable: Bool,
        isUpdating: Bool,
        isTransitioning: Bool
    ) -> Bool {
        mode == .manual && isConnected && isAvailable && !isUpdating && !isTransitioning
    }

    static func acceptsReadback(requested: Bool, returned: Bool) -> Bool {
        requested == returned
    }

    static func requiresDisableBeforeHeadless(isEnabled: Bool) -> Bool {
        isEnabled
    }

    static func canEnterHeadless(supportsMouseJiggler: Bool?, enabledState: Bool?) -> Bool {
        guard let supportsMouseJiggler else { return false }
        return !supportsMouseJiggler || enabledState != nil
    }

    static func allowsSettingsApply(isHeadlessConfigurationLocked: Bool) -> Bool {
        !isHeadlessConfigurationLocked
    }

    static func allowsRequestedState(_ enabled: Bool, isHeadlessConfigurationLocked: Bool) -> Bool {
        !enabled || !isHeadlessConfigurationLocked
    }
}

enum LocalControlCommand: String, Sendable {
    case status
    case text
    case click
    case shortcut
    case observe
    case act
    case actionStatus = "action_status"
    case cancel

    var kind: ControlCommandKind {
        switch self {
        case .status, .observe, .actionStatus, .cancel: return .status
        case .text, .click, .shortcut, .act: return .mutation
        }
    }
}

enum RemoteShortcutPolicy {
    static let maximumKeys = 4
    static let maximumKeyTokenLength = 16

    private static let allowedKeys: Set<String> = [
        "ControlLeft", "ShiftLeft", "AltLeft", "MetaLeft",
        "KeyA", "KeyC", "KeyV", "KeyX", "KeyZ",
        "Enter", "Escape", "Tab", "Backspace", "Delete",
        "Home", "End", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
    ]

    static func accepts(_ keys: [String]) -> Bool {
        guard !keys.isEmpty, keys.count <= maximumKeys else { return false }
        guard Set(keys).count == keys.count else { return false }
        return keys.allSatisfy { key in
            !key.isEmpty
                && key.utf8.count <= maximumKeyTokenLength
                && allowedKeys.contains(key)
        }
    }
}

struct CursorVisibilityContext: Equatable, Sendable {
    let mode: OverlookControlMode
    let isConnected: Bool
    let hasVideo: Bool
    let isMouseCaptureEnabled: Bool
    let showingSettings: Bool
    let showingConnections: Bool
    let showingManualConnect: Bool
    let showingPasswordPrompt: Bool
    let showingOCRResult: Bool
    let isOCRModeEnabled: Bool
    let hasConnectionError: Bool

    init(
        mode: OverlookControlMode,
        isConnected: Bool,
        hasVideo: Bool,
        isMouseCaptureEnabled: Bool,
        showingSettings: Bool,
        showingConnections: Bool,
        showingManualConnect: Bool,
        showingPasswordPrompt: Bool,
        showingOCRResult: Bool,
        isOCRModeEnabled: Bool,
        hasConnectionError: Bool
    ) {
        self.mode = mode
        self.isConnected = isConnected
        self.hasVideo = hasVideo
        self.isMouseCaptureEnabled = isMouseCaptureEnabled
        self.showingSettings = showingSettings
        self.showingConnections = showingConnections
        self.showingManualConnect = showingManualConnect
        self.showingPasswordPrompt = showingPasswordPrompt
        self.showingOCRResult = showingOCRResult
        self.isOCRModeEnabled = isOCRModeEnabled
        self.hasConnectionError = hasConnectionError
    }

    init(
        copying context: CursorVisibilityContext,
        mode: OverlookControlMode? = nil,
        isConnected: Bool? = nil,
        hasVideo: Bool? = nil,
        isMouseCaptureEnabled: Bool? = nil,
        showingSettings: Bool? = nil,
        showingConnections: Bool? = nil,
        showingManualConnect: Bool? = nil,
        showingPasswordPrompt: Bool? = nil,
        showingOCRResult: Bool? = nil,
        isOCRModeEnabled: Bool? = nil,
        hasConnectionError: Bool? = nil
    ) {
        self.init(
            mode: mode ?? context.mode,
            isConnected: isConnected ?? context.isConnected,
            hasVideo: hasVideo ?? context.hasVideo,
            isMouseCaptureEnabled: isMouseCaptureEnabled ?? context.isMouseCaptureEnabled,
            showingSettings: showingSettings ?? context.showingSettings,
            showingConnections: showingConnections ?? context.showingConnections,
            showingManualConnect: showingManualConnect ?? context.showingManualConnect,
            showingPasswordPrompt: showingPasswordPrompt ?? context.showingPasswordPrompt,
            showingOCRResult: showingOCRResult ?? context.showingOCRResult,
            isOCRModeEnabled: isOCRModeEnabled ?? context.isOCRModeEnabled,
            hasConnectionError: hasConnectionError ?? context.hasConnectionError
        )
    }
}

enum CursorVisibilityPolicy {
    static func shouldHideLocalCursor(in context: CursorVisibilityContext) -> Bool {
        context.mode == .manual
            && context.isConnected
            && context.hasVideo
            && context.isMouseCaptureEnabled
            && !context.showingSettings
            && !context.showingConnections
            && !context.showingManualConnect
            && !context.showingPasswordPrompt
            && !context.showingOCRResult
            && !context.isOCRModeEnabled
            && !context.hasConnectionError
    }
}

struct RemoteCursorRects: Equatable, Sendable {
    let remoteSurface: CGRect
    let topChromeReleaseBand: CGRect
}

enum RemotePointerOwnershipPolicy {
    static let fullscreenChromeReleaseBandHeight: CGFloat = 6

    static func topChromeReleaseBandHeight(isFullscreen: Bool) -> CGFloat {
        isFullscreen ? fullscreenChromeReleaseBandHeight : 0
    }

    static func cursorRects(
        in bounds: CGRect,
        topChromeReleaseBandHeight: CGFloat
    ) -> RemoteCursorRects {
        let releaseHeight = min(
            max(topChromeReleaseBandHeight, 0),
            max(bounds.height, 0)
        )
        guard releaseHeight > 0 else {
            return RemoteCursorRects(remoteSurface: bounds, topChromeReleaseBand: .zero)
        }

        return RemoteCursorRects(
            remoteSurface: CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: bounds.height - releaseHeight
            ),
            topChromeReleaseBand: CGRect(
                x: bounds.minX,
                y: bounds.maxY - releaseHeight,
                width: bounds.width,
                height: releaseHeight
            )
        )
    }

    static func ownsCursor(
        localPoint: CGPoint,
        visibleRect: CGRect,
        isTopmostInteractiveSurface: Bool,
        topChromeReleaseBandHeight: CGFloat = 0
    ) -> Bool {
        guard visibleRect.contains(localPoint), isTopmostInteractiveSurface else { return false }
        guard topChromeReleaseBandHeight > 0,
              visibleRect.height > topChromeReleaseBandHeight
        else {
            return true
        }

        return localPoint.y < visibleRect.maxY - topChromeReleaseBandHeight
    }
}

struct RemotePointerPresenceState: Equatable, Sendable {
    private(set) var isInsideRemoteSurface = false

    mutating func update(isOwnedByRemoteSurface: Bool) {
        isInsideRemoteSurface = isOwnedByRemoteSurface
    }

    mutating func exit() {
        isInsideRemoteSurface = false
    }
}

enum CursorRefreshPolicy {
    static func shouldApplyInvisibleCursor(
        isAlreadyApplied: Bool,
        forceRefresh: Bool,
        didAcquireHideLease: Bool
    ) -> Bool {
        !isAlreadyApplied || forceRefresh || didAcquireHideLease
    }

    static func shouldApplyArrowCursor(
        isInvisibleCursorApplied: Bool,
        ownsHideLease: Bool
    ) -> Bool {
        isInvisibleCursorApplied || ownsHideLease
    }
}

enum HIDCommandSuccessFeedbackMode: Sendable {
    case publishChanges
    case errorsOnly
}

struct HIDCommandFeedbackUpdate: Equatable, Sendable {
    let status: String
    let clearsError: Bool
}

enum HIDCommandFeedbackPolicy {
    static let interruptedStatus = "Input interrupted; reconnecting"

    static func successUpdate(
        currentStatus: String,
        currentError: String?,
        nextStatus: String,
        mode: HIDCommandSuccessFeedbackMode
    ) -> HIDCommandFeedbackUpdate? {
        if mode == .errorsOnly {
            guard currentError != nil else { return nil }
            return HIDCommandFeedbackUpdate(status: nextStatus, clearsError: true)
        }

        let clearsError = currentError != nil
        guard currentStatus != nextStatus || clearsError else { return nil }
        return HIDCommandFeedbackUpdate(status: nextStatus, clearsError: clearsError)
    }

    static func failureUpdate(
        currentStatus: String,
        currentError: String?,
        nextError: String
    ) -> HIDCommandFeedbackUpdate? {
        guard currentStatus != interruptedStatus || currentError != nextError else { return nil }
        return HIDCommandFeedbackUpdate(status: interruptedStatus, clearsError: false)
    }
}

enum FullscreenHoverPolicy {
    static let hiddenControlsTopStripHeight: CGFloat = 28
    static let visibleControlsTopStripHeight: CGFloat = 58

    static func isInsideTopStrip(
        locationY: CGFloat,
        isFullscreen: Bool,
        controlsVisible: Bool,
        isOverlayPresented: Bool
    ) -> Bool {
        guard isFullscreen, !isOverlayPresented, locationY >= 0 else { return false }
        let height = controlsVisible
            ? visibleControlsTopStripHeight
            : hiddenControlsTopStripHeight
        return locationY <= height
    }
}

struct RemoteMouseButtonLifecycle<Button: Hashable & Sendable>: Sendable {
    private(set) var pressedButtons: Set<Button> = []

    mutating func press(_ button: Button) {
        pressedButtons.insert(button)
    }

    mutating func release(_ button: Button) -> Bool {
        pressedButtons.remove(button) != nil
    }

    func shouldForwardMovement(ownsPointer: Bool) -> Bool {
        ownsPointer || !pressedButtons.isEmpty
    }

    mutating func takeAllPressedButtons() -> Set<Button> {
        let buttons = pressedButtons
        pressedButtons.removeAll()
        return buttons
    }
}

struct LatestMouseMoveCommandBuffer<Move: Equatable & Sendable>: Equatable, Sendable {
    private(set) var scheduledMove: Move?
    private(set) var pendingMoveAfterFrozenCommand: Move?
    private(set) var isScheduledMoveFrozen = false
    private(set) var isScheduledMoveInFlight = false

    mutating func enqueue(_ move: Move, merge: (Move, Move) -> Move) -> Bool {
        guard scheduledMove != nil else {
            scheduledMove = move
            isScheduledMoveFrozen = false
            isScheduledMoveInFlight = false
            return true
        }

        if isScheduledMoveFrozen || isScheduledMoveInFlight {
            pendingMoveAfterFrozenCommand = pendingMoveAfterFrozenCommand.map {
                merge($0, move)
            } ?? move
            return false
        }

        scheduledMove = scheduledMove.map {
            merge($0, move)
        } ?? move
        return false
    }

    mutating func freezeScheduledMove() {
        guard scheduledMove != nil else { return }
        isScheduledMoveFrozen = true
    }

    mutating func takeScheduledMove() -> Move? {
        guard let scheduledMove else { return nil }
        isScheduledMoveInFlight = true
        return scheduledMove
    }

    mutating func takePendingMoveAfterFrozenCommand() -> Move? {
        let move = pendingMoveAfterFrozenCommand
        pendingMoveAfterFrozenCommand = nil
        return move
    }

    mutating func finishCommand() -> Bool {
        scheduledMove = pendingMoveAfterFrozenCommand
        pendingMoveAfterFrozenCommand = nil
        isScheduledMoveFrozen = false
        isScheduledMoveInFlight = false
        return scheduledMove != nil
    }

    mutating func invalidate() {
        scheduledMove = nil
        pendingMoveAfterFrozenCommand = nil
        isScheduledMoveFrozen = false
        isScheduledMoveInFlight = false
    }

    var hasScheduledMove: Bool {
        scheduledMove != nil
    }

    var hasPendingMoveAfterFrozenCommand: Bool {
        pendingMoveAfterFrozenCommand != nil
    }
}

enum MouseMoveCommandMergePolicy {
    struct RelativeMove: Equatable, Sendable {
        let deltaX: Int
        let deltaY: Int
    }

    static func latestAbsolute<T>(_ old: T, _ new: T) -> T {
        new
    }

    static func mergedRelative(_ old: RelativeMove, _ new: RelativeMove) -> RelativeMove {
        RelativeMove(deltaX: old.deltaX + new.deltaX, deltaY: old.deltaY + new.deltaY)
    }
}

enum ConnectSubmissionPolicy {
    static func canSubmitPassword(_ password: String) -> Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func canSubmitManualConnection(hostPort: String) -> Bool {
        !hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ConnectSubmissionGate: Equatable, Sendable {
    private(set) var hasSubmitted = false

    mutating func begin(when canSubmit: Bool) -> Bool {
        guard canSubmit, !hasSubmitted else { return false }
        hasSubmitted = true
        return true
    }
}

enum ConnectCredentialSnapshot {
    static func takeAndClear(_ password: inout String) -> String {
        let snapshot = password
        password = ""
        return snapshot
    }
}

enum EndpointRecordPolicy {
    static func keepingLast<Record>(
        _ records: [Record],
        endpoint: (Record) -> String
    ) -> [Record] {
        var endpointOrder: [String] = []
        var recordsByEndpoint: [String: Record] = [:]

        for record in records {
            let key = endpoint(record)
            if recordsByEndpoint[key] == nil {
                endpointOrder.append(key)
            }
            recordsByEndpoint[key] = record
        }

        return endpointOrder.compactMap { recordsByEndpoint[$0] }
    }

    static func replacing<Record>(
        _ records: [Record],
        with replacement: Record,
        endpoint: (Record) -> String
    ) -> [Record] {
        var deduplicated = keepingLast(records, endpoint: endpoint)
        let replacementEndpoint = endpoint(replacement)

        if let index = deduplicated.firstIndex(where: { endpoint($0) == replacementEndpoint }) {
            deduplicated[index] = replacement
        } else {
            deduplicated.append(replacement)
        }

        return deduplicated
    }
}

enum CredentialMergePolicy {
    static func preferredToken(current: String, loaded: String) -> String {
        current.isEmpty ? loaded : current
    }
}

/// A small, value-type state machine used to prevent overlapping reconnects and
/// to reject completions from a connection attempt that has since been invalidated.
struct ReconnectGenerationPolicy: Sendable {
    private(set) var generation = 0
    private(set) var activeGeneration: Int?

    mutating func beginIfIdle() -> Int? {
        guard activeGeneration == nil else { return nil }
        generation &+= 1
        activeGeneration = generation
        return generation
    }

    func accepts(generation candidate: Int) -> Bool {
        activeGeneration == candidate && generation == candidate
    }

    @discardableResult
    mutating func finish(generation candidate: Int) -> Bool {
        guard accepts(generation: candidate) else { return false }
        activeGeneration = nil
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        activeGeneration = nil
    }
}

enum ScanGenerationPolicy {
    static func accepts(resultGeneration: Int, currentGeneration: Int) -> Bool {
        resultGeneration == currentGeneration
    }
}

enum ScanPortPolicy {
    struct Endpoint: Hashable, Sendable {
        let host: String
        let port: Int
    }

    static let requiredPort = 443
    static let maximumAutomaticCandidates = 256
    static let maximumConcurrentProbes = 16

    static func portsToProbe(from candidates: [Int]) -> [Int] {
        candidates.contains(requiredPort) ? [requiredPort] : []
    }

    static func allows(port: Int, isOpen: Bool) -> Bool {
        port == requiredPort && isOpen
    }

    static func isPinned(deviceID: String) -> Bool {
        deviceID.hasPrefix("manual-") || deviceID.hasPrefix("saved-")
    }

    static func endpointsToProbe(from candidates: [Endpoint]) -> [Endpoint] {
        var selectedEndpoints: [Endpoint] = []
        var seenEndpoints: Set<Endpoint> = []
        selectedEndpoints.reserveCapacity(min(candidates.count, maximumAutomaticCandidates))

        for endpoint in candidates {
            guard !endpoint.host.isEmpty, endpoint.port == requiredPort else { continue }
            guard seenEndpoints.insert(endpoint).inserted else { continue }
            selectedEndpoints.append(endpoint)
            if selectedEndpoints.count == maximumAutomaticCandidates { break }
        }

        return selectedEndpoints
    }
}

enum RemoteCoordinateValidator {
    struct Coordinates: Equatable, Sendable {
        let x: Int
        let y: Int
    }

    static let validRange = -32_767...32_767

    static func isValid(signedX: Int, signedY: Int) -> Bool {
        validRange.contains(signedX) && validRange.contains(signedY)
    }

    static func validated(signedX: Int, signedY: Int) -> Coordinates? {
        guard isValid(signedX: signedX, signedY: signedY) else { return nil }
        return Coordinates(x: signedX, y: signedY)
    }
}
