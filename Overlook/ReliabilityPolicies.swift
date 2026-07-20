import Foundation

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
