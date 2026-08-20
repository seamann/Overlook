import Foundation
import CoreGraphics

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
        testAutomaticScanRequiresReachableTCP443AndPreservesPinnedDevices()
        testRemoteCoordinatesAreValidatedWithoutClamping()
        testLocalCursorVisibilityPolicy()
        testRemoteCursorOwnershipRequiresTopmostVideoSurface()
        testRemotePointerExitReleasesOwnershipImmediately()
        testConnectSubmissionRequiresUsableInput()
        testConnectSubmissionGateAllowsOnlyOneAttempt()
        testCredentialSnapshotClearsSourceImmediately()
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

    private static func testAutomaticScanRequiresReachableTCP443AndPreservesPinnedDevices() {
        precondition(ScanPortPolicy.requiredPort == 443)
        precondition(ScanPortPolicy.maximumAutomaticCandidates == 256)
        precondition(ScanPortPolicy.maximumConcurrentProbes == 16)
        precondition(ScanPortPolicy.portsToProbe(from: [80, 443, 8443, 8080, 443]) == [443])
        precondition(ScanPortPolicy.allows(port: 443, isOpen: true))
        precondition(!ScanPortPolicy.allows(port: 443, isOpen: false))
        precondition(!ScanPortPolicy.allows(port: 8443, isOpen: true))
        precondition(ScanPortPolicy.isPinned(deviceID: "manual-device"))
        precondition(ScanPortPolicy.isPinned(deviceID: "saved-kvm.local-80"))
        precondition(!ScanPortPolicy.isPinned(deviceID: "scanned-192.168.1.5-443"))
        precondition(!ScanPortPolicy.isPinned(deviceID: "generic-device"))

        let endpoints = [
            ScanPortPolicy.Endpoint(host: "kvm.local", port: 443),
            ScanPortPolicy.Endpoint(host: "kvm.local", port: 443),
            ScanPortPolicy.Endpoint(host: "legacy.local", port: 8443),
            ScanPortPolicy.Endpoint(host: "", port: 443),
        ] + (0..<300).map {
            ScanPortPolicy.Endpoint(host: "192.168.1.\($0)", port: 443)
        }
        let selectedEndpoints = ScanPortPolicy.endpointsToProbe(from: endpoints)
        precondition(selectedEndpoints.count == ScanPortPolicy.maximumAutomaticCandidates)
        precondition(selectedEndpoints.first == .init(host: "kvm.local", port: 443))
        precondition(Set(selectedEndpoints).count == selectedEndpoints.count)
        precondition(selectedEndpoints.allSatisfy { $0.port == 443 && !$0.host.isEmpty })
    }

    private static func testRemoteCoordinatesAreValidatedWithoutClamping() {
        precondition(RemoteCoordinateValidator.isValid(signedX: -32_767, signedY: 32_767))
        precondition(RemoteCoordinateValidator.isValid(signedX: 0, signedY: 0))
        precondition(!RemoteCoordinateValidator.isValid(signedX: -32_768, signedY: 0))
        precondition(!RemoteCoordinateValidator.isValid(signedX: 0, signedY: 32_768))
        precondition(RemoteCoordinateValidator.validated(signedX: 12, signedY: -34) == .init(x: 12, y: -34))
        precondition(RemoteCoordinateValidator.validated(signedX: Int.max, signedY: 0) == nil)
    }

    private static func testLocalCursorVisibilityPolicy() {
        let activeManualSession = CursorVisibilityContext(
            mode: .manual,
            isConnected: true,
            hasVideo: true,
            isMouseCaptureEnabled: true,
            showingSettings: false,
            showingConnections: false,
            showingManualConnect: false,
            showingPasswordPrompt: false,
            showingOCRResult: false,
            isOCRModeEnabled: false,
            hasConnectionError: false
        )

        precondition(CursorVisibilityPolicy.shouldHideLocalCursor(in: activeManualSession))

        let blockedSessions = [
            CursorVisibilityContext(copying: activeManualSession, mode: .codexHeadless),
            CursorVisibilityContext(copying: activeManualSession, isConnected: false),
            CursorVisibilityContext(copying: activeManualSession, hasVideo: false),
            CursorVisibilityContext(copying: activeManualSession, isMouseCaptureEnabled: false),
            CursorVisibilityContext(copying: activeManualSession, showingSettings: true),
            CursorVisibilityContext(copying: activeManualSession, showingConnections: true),
            CursorVisibilityContext(copying: activeManualSession, showingManualConnect: true),
            CursorVisibilityContext(copying: activeManualSession, showingPasswordPrompt: true),
            CursorVisibilityContext(copying: activeManualSession, showingOCRResult: true),
            CursorVisibilityContext(copying: activeManualSession, isOCRModeEnabled: true),
            CursorVisibilityContext(copying: activeManualSession, hasConnectionError: true),
        ]

        precondition(blockedSessions.allSatisfy {
            !CursorVisibilityPolicy.shouldHideLocalCursor(in: $0)
        })
    }

    private static func testRemoteCursorOwnershipRequiresTopmostVideoSurface() {
        let visibleRemoteArea = CGRect(x: 0, y: 0, width: 1_280, height: 720)

        precondition(
            RemotePointerOwnershipPolicy.ownsCursor(
                localPoint: CGPoint(x: 640, y: 360),
                visibleRect: visibleRemoteArea,
                isTopmostInteractiveSurface: true
            )
        )
        precondition(
            !RemotePointerOwnershipPolicy.ownsCursor(
                localPoint: CGPoint(x: 640, y: 360),
                visibleRect: visibleRemoteArea,
                isTopmostInteractiveSurface: false
            )
        )
        precondition(
            !RemotePointerOwnershipPolicy.ownsCursor(
                localPoint: CGPoint(x: 640, y: 721),
                visibleRect: visibleRemoteArea,
                isTopmostInteractiveSurface: true
            )
        )
    }

    private static func testRemotePointerExitReleasesOwnershipImmediately() {
        var state = RemotePointerPresenceState()
        state.update(isOwnedByRemoteSurface: true)
        precondition(state.isInsideRemoteSurface)

        state.exit()
        precondition(!state.isInsideRemoteSurface)

        state.exit()
        precondition(!state.isInsideRemoteSurface)
    }

    private static func testConnectSubmissionRequiresUsableInput() {
        precondition(ConnectSubmissionPolicy.canSubmitPassword("entered test value"))
        precondition(!ConnectSubmissionPolicy.canSubmitPassword(""))
        precondition(!ConnectSubmissionPolicy.canSubmitPassword(" \n\t "))

        precondition(ConnectSubmissionPolicy.canSubmitManualConnection(hostPort: "kvm.local"))
        precondition(!ConnectSubmissionPolicy.canSubmitManualConnection(hostPort: " \n "))
    }

    private static func testConnectSubmissionGateAllowsOnlyOneAttempt() {
        var gate = ConnectSubmissionGate()
        precondition(!gate.begin(when: false))
        precondition(gate.begin(when: true))
        precondition(!gate.begin(when: true))
    }

    private static func testCredentialSnapshotClearsSourceImmediately() {
        var inputField = "  entered test value  "
        let snapshot = ConnectCredentialSnapshot.takeAndClear(&inputField)
        precondition(snapshot == "  entered test value  ")
        precondition(inputField.isEmpty)
    }
}
