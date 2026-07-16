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
