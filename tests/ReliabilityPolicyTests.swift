import Foundation

@main
struct ReliabilityPolicyTests {
    static func main() async throws {
        testHIDCommandOrdering()
        testReconnectBackoff()
        testClipboardPreservesPayloadExactly()
        testWindowFramesUseSeparateKeys()
        testControlMutationsRequireHeadlessMode()
        testReconnectIsSingleFlightAndGenerationSafe()
        testScanResultsRequireCurrentGeneration()
        testRemoteCoordinatesAreValidatedWithoutClamping()
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

    private static func testControlMutationsRequireHeadlessMode() {
        precondition(ControlMutationPolicy.allows(.status, in: .manual))
        precondition(ControlMutationPolicy.allows(.status, in: .codexHeadless))
        precondition(!ControlMutationPolicy.allows(.mutation, in: .manual))
        precondition(ControlMutationPolicy.allows(.mutation, in: .codexHeadless))
    }

    private static func testReconnectIsSingleFlightAndGenerationSafe() {
        var policy = ReconnectGenerationPolicy()

        let first = policy.beginIfIdle()
        precondition(first == 1)
        precondition(policy.beginIfIdle() == nil)
        precondition(policy.accepts(generation: 1))

        policy.invalidate()
        precondition(!policy.accepts(generation: 1))
        precondition(!policy.finish(generation: 1))

        let second = policy.beginIfIdle()
        precondition(second == 3)
        precondition(policy.finish(generation: 3))
        precondition(policy.beginIfIdle() == 4)
    }

    private static func testScanResultsRequireCurrentGeneration() {
        precondition(ScanGenerationPolicy.accepts(resultGeneration: 7, currentGeneration: 7))
        precondition(!ScanGenerationPolicy.accepts(resultGeneration: 6, currentGeneration: 7))
        precondition(!ScanGenerationPolicy.accepts(resultGeneration: 8, currentGeneration: 7))
    }

    private static func testRemoteCoordinatesAreValidatedWithoutClamping() {
        precondition(RemoteCoordinateValidator.isValid(signedX: -32_767, signedY: 32_767))
        precondition(RemoteCoordinateValidator.isValid(signedX: 0, signedY: 0))
        precondition(!RemoteCoordinateValidator.isValid(signedX: -32_768, signedY: 0))
        precondition(!RemoteCoordinateValidator.isValid(signedX: 0, signedY: 32_768))
        precondition(RemoteCoordinateValidator.validated(signedX: 12, signedY: -34) == .init(x: 12, y: -34))
        precondition(RemoteCoordinateValidator.validated(signedX: Int.max, signedY: 0) == nil)
    }
}
