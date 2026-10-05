import Foundation

private struct MicroTestFailure: Error, CustomStringConvertible { let description: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw MicroTestFailure(description: message) }
}

@main
struct MicroMouseJigglerTests {
    static func main() throws {
        try idleAndExtent()
        try boundaries()
        try ownershipAndActivity()
        try eligibility()
        try relativeAndOverlap()
        try enablingPreservesRealOrigin()
        try staleExtentCompletion()
        print("MicroMouseJigglerTests passed (7 deterministic groups)")
    }

    private static func ready() -> MicroMouseJiggler {
        var state = MicroMouseJiggler()
        state.setEnabled(true, now: 0)
        return state
    }

    private static func idleAndExtent() throws {
        var state = ready()
        try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60) == nil, "No absolute pulse without real origin")
        state.recordAbsoluteOrigin(owner: "one", x: 0, y: 17, width: nil, currentWidth: nil, now: 0)
        try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60) == nil, "No absolute pulse without known extent")
        state.recordAbsoluteOrigin(owner: "one", x: 0, y: 17, width: 1920, currentWidth: 1920, now: 0)
        try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 59) == nil, "59s must stay idle")
        guard let pulse = state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60) else { throw MicroTestFailure(description: "60s must produce pulse") }
        try require(pulse.outward == .absolute(x: 34, y: 17), "1920px must move one pixel, preserve Y")
        try require(pulse.returning == .absolute(x: 0, y: 17), "Return must restore original position")
    }

    private static func boundaries() throws {
        for (x, expected) in [(-32767, -32733), (32767, 32733), (32766, 32732)] {
            var state = ready()
            state.recordAbsoluteOrigin(owner: "one", x: x, y: -1234, width: 1920, currentWidth: 1920, now: 0)
            let pulse = state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60)
            try require(pulse?.outward == .absolute(x: expected, y: -1234), "Edge must move inward and preserve Y")
        }
        for width in [0, 1, -1, 100000] {
            var state = ready()
            state.recordAbsoluteOrigin(owner: "one", x: 0, y: 0, width: width, currentWidth: width, now: 0)
            try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60) == nil, "Unsupported width must not dispatch")
        }
        var minimal = ready()
        minimal.recordAbsoluteOrigin(owner: "one", x: 0, y: 0, width: 2, currentWidth: 2, now: 0)
        try require(minimal.beginPulse(owner: "one", absolute: true, eligible: true, now: 60)?.outward
                    == .absolute(x: -32767, y: 0), "Minimal extent may move less than one pixel but cannot overflow HID")
        for (x, y) in [(32768, 0), (0, -32768)] {
            var state = ready()
            state.recordAbsoluteOrigin(owner: "one", x: x, y: y, width: 1920, currentWidth: 1920, now: 0)
            try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60) == nil,
                        "Out-of-range actual coordinates cannot become an anchor")
        }
    }

    private static func ownershipAndActivity() throws {
        var state = ready()
        state.recordAbsoluteOrigin(owner: "one", x: 0, y: 0, width: 3840, currentWidth: 3840, now: 0)
        let pulse = state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60)!
        try require(pulse.outward == .absolute(x: 17, y: 0), "4k pixel delta must be 17")
        try require(state.isCurrent(pulse, owner: "one"), "Original owner can dispatch")
        try require(!state.isCurrent(pulse, owner: "two"), "Replacement transport cannot dispatch old return")
        state.recordActivity(now: 60)
        try require(!state.isCurrent(pulse, owner: "one"), "Real activity between steps must prevent stale return")
        state.finish(pulse)
        try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 119) == nil, "Activity restarts complete idle period")
        let newer = state.beginPulse(owner: "one", absolute: true, eligible: true, now: 120)!
        state.invalidate(now: 120)
        try require(!state.isCurrent(newer, owner: "one"), "Session/mode/mouse-mode invalidation cancels old pair")
        try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 180) == nil, "Invalidation clears absolute origin")
    }

    private static func eligibility() throws {
        var state = ready()
        try require(state.beginPulse(owner: "one", absolute: false, eligible: false, now: 60) == nil, "Manual/session/connection/input/held/print guards must prevent dispatch")
        let pulse = state.beginPulse(owner: "one", absolute: false, eligible: true, now: 60)!
        state.setEnabled(false, now: 60)
        try require(!state.isCurrent(pulse, owner: "one"), "Disable must synchronously revoke pending return")
        try require(state.beginPulse(owner: "one", absolute: false, eligible: true, now: 1000) == nil, "Disabled never dispatches")
    }

    private static func enablingPreservesRealOrigin() throws {
        var state = MicroMouseJiggler()
        state.recordAbsoluteOrigin(owner: "one", x: 100, y: 77, width: 1920, currentWidth: 1920, now: 0)
        state.setEnabled(true, now: 1)
        try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60) == nil,
                    "Enable starts a fresh complete60s idle period")
        let pulse = state.beginPulse(owner: "one", absolute: true, eligible: true, now: 61)
        try require(pulse?.outward == .absolute(x: 134, y: 77), "Toolbar enable must retain real same-transport origin")
        state.setEnabled(false, now: 62)
        state.setEnabled(true, now: 63)
        try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 123) != nil,
                    "Pure toggle preserves valid origin while revoking active pulse")
    }

    private static func staleExtentCompletion() throws {
        var state = ready()
        state.recordAbsoluteOrigin(owner: "one", x: 100, y: 77, width: 1920, currentWidth: 3840, now: 0)
        try require(state.beginPulse(owner: "one", absolute: true, eligible: true, now: 60) == nil,
                    "Completion of old-width send cannot establish anchor for new video extent")
    }

    private static func relativeAndOverlap() throws {
        var state = ready()
        let pulse = state.beginPulse(owner: "one", absolute: false, eligible: true, now: 60)!
        try require(pulse.outward == .relative(x: 1, y: 0) && pulse.returning == .relative(x: -1, y: 0), "Relative impulse must be plus/minus one HID unit")
        try require(state.beginPulse(owner: "one", absolute: false, eligible: true, now: 1000) == nil, "Pairs cannot overlap even after long stall")
        state.finish(pulse)
        let delayed = state.beginPulse(owner: "one", absolute: false, eligible: true, now: 1000)!
        state.finish(delayed)
        try require(state.beginPulse(owner: "one", absolute: false, eligible: true, now: 1000) == nil, "Delayed timer must not catch up ticks")
        try require(state.delayUntilNextPulse(now: 1000) == 60, "Reschedule from current time")
    }
}
