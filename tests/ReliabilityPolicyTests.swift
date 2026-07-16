import Foundation

@main
struct ReliabilityPolicyTests {
    static func main() async throws {
        testHIDCommandOrdering()
        testReconnectBackoff()
        testClipboardPreservesPayloadExactly()
        testWindowFramesUseSeparateKeys()
        print("ReliabilityPolicyTests passed")
    }

    private static func testHIDCommandOrdering() {
        let shiftedDown = HIDCommandSequencer.commands(
            key: "KeyA",
            isPressed: true,
            requiresShift: true
        )
        precondition(shiftedDown == [
            HIDCommand.key("ShiftLeft", isPressed: true),
            HIDCommand.key("KeyA", isPressed: true),
        ])

        let shiftedUp = HIDCommandSequencer.commands(
            key: "KeyA",
            isPressed: false,
            requiresShift: true
        )
        precondition(shiftedUp == [
            HIDCommand.key("KeyA", isPressed: false),
            HIDCommand.key("ShiftLeft", isPressed: false),
        ])

        precondition(HIDCommandSequencer.releaseAll == [.releaseAll])
    }

    private static func testReconnectBackoff() {
        let policy = ReconnectBackoff(
            initialDelay: 0.5,
            multiplier: 2,
            maximumDelay: 8
        )

        precondition(policy.delay(forAttempt: 0) == 0.5)
        precondition(policy.delay(forAttempt: 1) == 1)
        precondition(policy.delay(forAttempt: 4) == 8)
        precondition(policy.delay(forAttempt: 20) == 8)
    }

    private static func testClipboardPreservesPayloadExactly() {
        let payload = "  Erste Zeile\nZweite Zeile  \n"
        precondition(ClipboardPayload(rawText: payload).text == payload)
        precondition(ClipboardPayload(rawText: "").text == "")
    }

    private static func testWindowFramesUseSeparateKeys() {
        precondition(WindowFramePersistence.key(for: .manual) != WindowFramePersistence.key(for: .codexHeadless))
        precondition(WindowFramePersistence.key(for: .manual).contains("manual"))
        precondition(WindowFramePersistence.key(for: .codexHeadless).contains("codexHeadless"))
    }
}
