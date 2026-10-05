import Foundation

/// A small, transport-independent planner. InputManager owns its timer and HID queue.
struct MicroMouseJiggler {
    enum Move: Equatable, Sendable {
        case absolute(x: Int, y: Int)
        case relative(x: Int, y: Int)
    }

    struct Pulse: Sendable {
        let id: UUID
        let owner: String
        let generation: UInt64
        let activityGeneration: UInt64
        let outward: Move
        let returning: Move
    }

    private struct Origin {
        let owner: String
        let x: Int
        let y: Int
        let width: Int
    }

    private(set) var enabled = false
    private var generation: UInt64 = 0
    private var activityGeneration: UInt64 = 0
    private var lastActivity: TimeInterval = 0
    private var lastPulse: TimeInterval = 0
    private var origin: Origin?
    private var activePulse: UUID?

    mutating func setEnabled(_ value: Bool, now: TimeInterval) {
        guard enabled != value else { return }
        enabled = value
        generation &+= 1
        activePulse = nil
        lastActivity = now
        lastPulse = now
    }

    mutating func invalidate(now: TimeInterval) {
        generation &+= 1
        origin = nil
        activePulse = nil
        lastActivity = now
        lastPulse = now
    }

    mutating func recordActivity(now: TimeInterval) {
        activityGeneration &+= 1
        lastActivity = now
    }

    mutating func recordAbsoluteOrigin(owner: String, x: Int, y: Int, width: Int?, currentWidth: Int?, now: TimeInterval) {
        recordActivity(now: now)
        guard (-32767...32767).contains(x), (-32767...32767).contains(y),
              let width, width == currentWidth, (2...65535).contains(width) else {
            origin = nil
            return
        }
        origin = Origin(owner: owner, x: x, y: y, width: width)
    }

    func delayUntilNextPulse(now: TimeInterval) -> TimeInterval {
        max(0, 60 - (now - max(lastActivity, lastPulse)))
    }

    mutating func beginPulse(owner: String, absolute: Bool, eligible: Bool, now: TimeInterval) -> Pulse? {
        guard enabled, eligible, activePulse == nil, delayUntilNextPulse(now: now) == 0 else { return nil }
        let outward: Move
        let returning: Move
        if absolute {
            guard let origin, origin.owner == owner else { return nil }
            let delta = Int((65534.0 / Double(origin.width - 1)).rounded())
            let target = origin.x + delta <= 32767 ? origin.x + delta : max(-32767, origin.x - delta)
            outward = .absolute(x: target, y: origin.y)
            returning = .absolute(x: origin.x, y: origin.y)
        } else {
            outward = .relative(x: 1, y: 0)
            returning = .relative(x: -1, y: 0)
        }
        let pulse = Pulse(id: UUID(), owner: owner, generation: generation,
                          activityGeneration: activityGeneration, outward: outward, returning: returning)
        activePulse = pulse.id
        lastPulse = now
        return pulse
    }

    func isCurrent(_ pulse: Pulse, owner: String) -> Bool {
        enabled && activePulse == pulse.id && pulse.owner == owner
            && pulse.generation == generation && pulse.activityGeneration == activityGeneration
    }

    mutating func finish(_ pulse: Pulse) {
        if activePulse == pulse.id { activePulse = nil }
    }
}
