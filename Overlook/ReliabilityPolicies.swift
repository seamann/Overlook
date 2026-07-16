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
