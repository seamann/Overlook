import Foundation
import CoreGraphics

@main
struct ReliabilityPolicyTests {
    static func main() async throws {
        testHIDCommandOrdering()
        testReconnectBackoff()
        testClipboardPreservesPayloadExactly()
        testWindowFramesUseSeparateKeys()
        testControlModeWindowChangesDoNotAnimate()
        testHeadlessConfigurationLocksHaveIndependentOwners()
        testOperationOwnershipTracksOverlappingTasks()
        testControlMutationsRequireHeadlessMode()
        testRemoteShortcutValidationIsStrictAndBounded()
        testMouseJigglerRequiresManualConnectedOwnership()
        testMouseJigglerReadbackAndHeadlessPreflight()
        testControlServerRetriesContinueWithBoundedBackoff()
        testControlServerConnectionLimitsBoundUnauthenticatedClients()
        try await testRemoteMutationsAreSerializedAndDrainable()
        try await testCancelledQueuedMutationNeverExecutes()
        try await testCommandContinuationCancellationIsImmediateAndOneShot()
        testReconnectIsSingleFlightAndGenerationSafe()
        testScanResultsRequireCurrentGeneration()
        testAutomaticScanRequiresReachableTCP443AndPreservesPinnedDevices()
        testRemoteCoordinatesAreValidatedWithoutClamping()
        testLocalCursorVisibilityPolicy()
        testRemoteCursorOwnershipRequiresTopmostVideoSurface()
        testRemotePointerExitReleasesOwnershipImmediately()
        testCursorRectsExcludeFullscreenReleaseBand()
        testCursorRefreshPolicyAvoidsRedundantCursorWork()
        testMouseMoveCoalescingKeepsOnlyOneQueuedCommand()
        testHighFrequencyHIDCommandsDoNotPublishSuccessFeedback()
        testFullscreenHoverPolicyRunsOnlyInUsableFullscreenChrome()
        testRemoteDragLifecyclePreservesDragUntilMouseUp()
        testConnectSubmissionRequiresUsableInput()
        testConnectSubmissionGateAllowsOnlyOneAttempt()
        testCredentialSnapshotClearsSourceImmediately()
        testEndpointRecordDeduplication()
        testCredentialMergePolicy()
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

    private static func testControlModeWindowChangesDoNotAnimate() {
        precondition(!ControlModeWindowTransitionPolicy.animatesFrameChanges)
        precondition(ControlModeWindowTransitionPolicy.defersPickerSelection)
    }

    private static func testHeadlessConfigurationLocksHaveIndependentOwners() {
        var state = HeadlessConfigurationLockState()
        precondition(!state.isLocked)

        let first = state.beginTransition()
        let second = state.beginTransition()
        precondition(state.isLocked)
        state.endTransition(first)
        precondition(state.isLocked)
        state.endTransition(second)
        precondition(!state.isLocked)

        state.setHeadlessModeActive(true)
        let transition = state.beginTransition()
        state.endTransition(transition)
        precondition(state.isLocked)
        state.setHeadlessModeActive(false)
        precondition(!state.isLocked)
    }

    private static func testOperationOwnershipTracksOverlappingTasks() {
        var state = OperationOwnershipState()
        precondition(!state.isActive)

        let first = state.begin()
        let second = state.begin()
        precondition(state.isActive)
        state.end(first)
        precondition(state.isActive)
        state.end(second)
        precondition(!state.isActive)

        _ = state.begin()
        state.reset()
        precondition(!state.isActive)
    }

    private static func testControlMutationsRequireHeadlessMode() {
        precondition(ControlMutationPolicy.allows(.status, in: .manual))
        precondition(ControlMutationPolicy.allows(.status, in: .codexHeadless))
        precondition(!ControlMutationPolicy.allows(.mutation, in: .manual))
        precondition(ControlMutationPolicy.allows(.mutation, in: .codexHeadless))
        precondition(LocalControlCommand(rawValue: "status")?.kind == .status)
        precondition(LocalControlCommand(rawValue: "set_mode") == nil)
        precondition(LocalControlCommand(rawValue: "click")?.kind == .mutation)
        precondition(LocalControlCommand(rawValue: "text")?.kind == .mutation)
        precondition(LocalControlCommand(rawValue: "shortcut")?.kind == .mutation)
    }

    private static func testRemoteShortcutValidationIsStrictAndBounded() {
        precondition(RemoteShortcutPolicy.accepts(["ControlLeft", "KeyA"]))
        precondition(RemoteShortcutPolicy.accepts(["Enter"]))
        precondition(!RemoteShortcutPolicy.accepts([]))
        precondition(!RemoteShortcutPolicy.accepts([
            "ControlLeft", "ShiftLeft", "AltLeft", "KeyA", "Enter",
        ]))
        precondition(!RemoteShortcutPolicy.accepts(["ControlLeft", "KeyQ"]))
        precondition(!RemoteShortcutPolicy.accepts(["ControlLeft", "ControlLeft"]))
        precondition(!RemoteShortcutPolicy.accepts([String(repeating: "A", count: 17)]))
    }

    private static func testMouseJigglerRequiresManualConnectedOwnership() {
        precondition(
            MouseJigglerPolicy.canToggle(
                mode: .manual,
                isConnected: true,
                isAvailable: true,
                isUpdating: false,
                isTransitioning: false
            )
        )
        precondition(
            !MouseJigglerPolicy.canToggle(
                mode: .codexHeadless,
                isConnected: true,
                isAvailable: true,
                isUpdating: false,
                isTransitioning: false
            )
        )
        precondition(
            !MouseJigglerPolicy.canToggle(
                mode: .manual,
                isConnected: false,
                isAvailable: true,
                isUpdating: false,
                isTransitioning: false
            )
        )
        precondition(
            !MouseJigglerPolicy.canToggle(
                mode: .manual,
                isConnected: true,
                isAvailable: false,
                isUpdating: false,
                isTransitioning: false
            )
        )
        precondition(
            !MouseJigglerPolicy.canToggle(
                mode: .manual,
                isConnected: true,
                isAvailable: true,
                isUpdating: true,
                isTransitioning: false
            )
        )
        precondition(
            !MouseJigglerPolicy.canToggle(
                mode: .manual,
                isConnected: true,
                isAvailable: true,
                isUpdating: false,
                isTransitioning: true
            )
        )
    }

    private static func testMouseJigglerReadbackAndHeadlessPreflight() {
        precondition(MouseJigglerPolicy.acceptsReadback(requested: true, returned: true))
        precondition(MouseJigglerPolicy.acceptsReadback(requested: false, returned: false))
        precondition(!MouseJigglerPolicy.acceptsReadback(requested: true, returned: false))
        precondition(!MouseJigglerPolicy.acceptsReadback(requested: false, returned: true))
        precondition(MouseJigglerPolicy.requiresDisableBeforeHeadless(isEnabled: true))
        precondition(!MouseJigglerPolicy.requiresDisableBeforeHeadless(isEnabled: false))
        precondition(MouseJigglerPolicy.allowsSettingsApply(isHeadlessConfigurationLocked: false))
        precondition(!MouseJigglerPolicy.allowsSettingsApply(isHeadlessConfigurationLocked: true))
        precondition(MouseJigglerPolicy.allowsRequestedState(true, isHeadlessConfigurationLocked: false))
        precondition(!MouseJigglerPolicy.allowsRequestedState(true, isHeadlessConfigurationLocked: true))
        precondition(MouseJigglerPolicy.allowsRequestedState(false, isHeadlessConfigurationLocked: true))
        precondition(!MouseJigglerPolicy.canEnterHeadless(supportsMouseJiggler: nil, enabledState: nil))
        precondition(MouseJigglerPolicy.canEnterHeadless(supportsMouseJiggler: false, enabledState: nil))
        precondition(!MouseJigglerPolicy.canEnterHeadless(supportsMouseJiggler: true, enabledState: nil))
        precondition(MouseJigglerPolicy.canEnterHeadless(supportsMouseJiggler: true, enabledState: false))
        precondition(MouseJigglerPolicy.canEnterHeadless(supportsMouseJiggler: true, enabledState: true))
    }

    private static func testControlServerRetriesContinueWithBoundedBackoff() {
        precondition(ControlServerRetryPolicy.delay(forAttempt: 0) == 0.5)
        precondition(ControlServerRetryPolicy.delay(forAttempt: 1) == 1.0)
        precondition(ControlServerRetryPolicy.delay(forAttempt: 2) == 2.0)
        precondition(ControlServerRetryPolicy.delay(forAttempt: 3) == 4.0)
        precondition(ControlServerRetryPolicy.delay(forAttempt: 6) == 30.0)
        precondition(ControlServerRetryPolicy.delay(forAttempt: 100) == 30.0)
    }

    private static func testControlServerConnectionLimitsBoundUnauthenticatedClients() {
        precondition(ControlServerConnectionPolicy.maximumConnections == 16)
        precondition(ControlServerConnectionPolicy.requestReadTimeout == 2)
        precondition(ControlServerConnectionPolicy.commandTimeout == 30)
    }

    private static func testRemoteMutationsAreSerializedAndDrainable() async throws {
        let gate = await MainActor.run { RemoteMutationGate() }
        let recorder = await MainActor.run { MutationEventRecorder() }
        let first = Task { @MainActor in
            try await gate.perform {
                recorder.events.append("first-start")
                try await Task.sleep(nanoseconds: 50_000_000)
                recorder.events.append("first-end")
            }
        }

        for _ in 0..<100 {
            if await MainActor.run(body: { recorder.events == ["first-start"] }) { break }
            await Task.yield()
        }
        let second = Task { @MainActor in
            try await gate.perform {
                recorder.events.append("second-start")
                recorder.events.append("second-end")
            }
        }
        for _ in 0..<100 {
            if await MainActor.run(body: { gate.pendingMutationCount == 1 }) { break }
            await Task.yield()
        }
        let drained = Task { @MainActor in
            await gate.waitUntilIdle()
            recorder.events.append("drained")
        }

        try await first.value
        try await second.value
        await drained.value
        await MainActor.run {
            precondition(recorder.events == [
                "first-start", "first-end", "second-start", "second-end", "drained",
            ])
        }
    }

    private static func testCancelledQueuedMutationNeverExecutes() async throws {
        let gate = await MainActor.run { RemoteMutationGate() }
        let recorder = await MainActor.run { MutationEventRecorder() }
        let barrier = MutationBarrier()
        let first = Task { @MainActor in
            try await gate.perform {
                recorder.events.append("active-start")
                await barrier.wait()
                recorder.events.append("active-end")
            }
        }

        for _ in 0..<100 {
            if await MainActor.run(body: { recorder.events == ["active-start"] }) { break }
            await Task.yield()
        }
        let cancelled = Task { @MainActor in
            try await gate.perform {
                recorder.events.append("cancelled-ran")
            }
        }
        for _ in 0..<100 {
            if await MainActor.run(body: { gate.pendingMutationCount == 1 }) { break }
            await Task.yield()
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            preconditionFailure("Cancelled mutation unexpectedly completed")
        } catch is CancellationError {
            // Expected: cancellation removes the queued continuation.
        }

        await barrier.release()
        try await first.value
        await MainActor.run {
            precondition(recorder.events == ["active-start", "active-end"])
            precondition(gate.pendingMutationCount == 0)
        }
    }

    private static func testCommandContinuationCancellationIsImmediateAndOneShot() async throws {
        let commandContinuation = CancellableCommandContinuation()
        commandContinuation.cancel()
        let waiter = Task {
            try await withCheckedThrowingContinuation { continuation in
                commandContinuation.install(continuation)
            }
        }
        do {
            try await waiter.value
            preconditionFailure("Cancelled command continuation unexpectedly succeeded")
        } catch is CancellationError {
            // Expected even when cancellation wins the race before installation.
        }
        commandContinuation.resume(with: .success(()))
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

        precondition(RemotePointerOwnershipPolicy.topChromeReleaseBandHeight(isFullscreen: false) == 0)
        precondition(
            RemotePointerOwnershipPolicy.topChromeReleaseBandHeight(isFullscreen: true)
                == RemotePointerOwnershipPolicy.fullscreenChromeReleaseBandHeight
        )

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
        precondition(
            RemotePointerOwnershipPolicy.ownsCursor(
                localPoint: CGPoint(x: 640, y: 713),
                visibleRect: visibleRemoteArea,
                isTopmostInteractiveSurface: true
            )
        )
        precondition(
            RemotePointerOwnershipPolicy.ownsCursor(
                localPoint: CGPoint(x: 640, y: 714),
                visibleRect: visibleRemoteArea,
                isTopmostInteractiveSurface: true
            )
        )
        precondition(
            !RemotePointerOwnershipPolicy.ownsCursor(
                localPoint: CGPoint(x: 640, y: 714),
                visibleRect: visibleRemoteArea,
                isTopmostInteractiveSurface: true,
                topChromeReleaseBandHeight: RemotePointerOwnershipPolicy.fullscreenChromeReleaseBandHeight
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

    private static func testCursorRectsExcludeFullscreenReleaseBand() {
        let bounds = CGRect(x: 0, y: 0, width: 1_280, height: 720)

        precondition(
            RemotePointerOwnershipPolicy.cursorRects(
                in: bounds,
                topChromeReleaseBandHeight: 0
            ) == RemoteCursorRects(remoteSurface: bounds, topChromeReleaseBand: .zero)
        )
        precondition(
            RemotePointerOwnershipPolicy.cursorRects(
                in: bounds,
                topChromeReleaseBandHeight: 6
            ) == RemoteCursorRects(
                remoteSurface: CGRect(x: 0, y: 0, width: 1_280, height: 714),
                topChromeReleaseBand: CGRect(x: 0, y: 714, width: 1_280, height: 6)
            )
        )
    }

    private static func testCursorRefreshPolicyAvoidsRedundantCursorWork() {
        precondition(
            CursorRefreshPolicy.shouldApplyInvisibleCursor(
                isAlreadyApplied: false,
                forceRefresh: false,
                didAcquireHideLease: false
            )
        )
        precondition(
            !CursorRefreshPolicy.shouldApplyInvisibleCursor(
                isAlreadyApplied: true,
                forceRefresh: false,
                didAcquireHideLease: false
            )
        )
        precondition(
            CursorRefreshPolicy.shouldApplyInvisibleCursor(
                isAlreadyApplied: true,
                forceRefresh: true,
                didAcquireHideLease: false
            )
        )
        precondition(
            CursorRefreshPolicy.shouldApplyInvisibleCursor(
                isAlreadyApplied: true,
                forceRefresh: false,
                didAcquireHideLease: true
            )
        )
        precondition(
            CursorRefreshPolicy.shouldApplyArrowCursor(
                isInvisibleCursorApplied: true,
                ownsHideLease: false
            )
        )
        precondition(
            CursorRefreshPolicy.shouldApplyArrowCursor(
                isInvisibleCursorApplied: false,
                ownsHideLease: true
            )
        )
        precondition(
            !CursorRefreshPolicy.shouldApplyArrowCursor(
                isInvisibleCursorApplied: false,
                ownsHideLease: false
            )
        )
    }

    private static func testMouseMoveCoalescingKeepsOnlyOneQueuedCommand() {
        var buffer = LatestMouseMoveCommandBuffer<Int>()

        precondition(buffer.enqueue(1, merge: MouseMoveCommandMergePolicy.latestAbsolute))
        precondition(!buffer.enqueue(2, merge: MouseMoveCommandMergePolicy.latestAbsolute))
        precondition(buffer.takeScheduledMove() == 2)
        precondition(!buffer.enqueue(3, merge: MouseMoveCommandMergePolicy.latestAbsolute))
        precondition(buffer.finishCommand())
        precondition(buffer.takeScheduledMove() == 3)
        precondition(!buffer.finishCommand())

        buffer.invalidate()
        precondition(buffer.enqueue(10, merge: MouseMoveCommandMergePolicy.latestAbsolute))
        buffer.freezeScheduledMove()
        precondition(!buffer.enqueue(11, merge: MouseMoveCommandMergePolicy.latestAbsolute))
        precondition(buffer.takePendingMoveAfterFrozenCommand() == 11)
        precondition(buffer.takeScheduledMove() == 10)
        precondition(!buffer.finishCommand())

        var relativeBuffer = LatestMouseMoveCommandBuffer<MouseMoveCommandMergePolicy.RelativeMove>()
        precondition(
            relativeBuffer.enqueue(
                .init(deltaX: 5, deltaY: -2),
                merge: MouseMoveCommandMergePolicy.mergedRelative
            )
        )
        precondition(
            !relativeBuffer.enqueue(
                .init(deltaX: 7, deltaY: 3),
                merge: MouseMoveCommandMergePolicy.mergedRelative
            )
        )
        precondition(relativeBuffer.takeScheduledMove() == .init(deltaX: 12, deltaY: 1))
    }

    private static func testHighFrequencyHIDCommandsDoNotPublishSuccessFeedback() {
        precondition(
            HIDCommandFeedbackPolicy.successUpdate(
                currentStatus: "Ready",
                currentError: nil,
                nextStatus: "Mouse move",
                mode: .errorsOnly
            ) == nil
        )

        precondition(
            HIDCommandFeedbackPolicy.successUpdate(
                currentStatus: "Input interrupted; reconnecting",
                currentError: "connection lost",
                nextStatus: "Mouse move",
                mode: .errorsOnly
            ) == HIDCommandFeedbackUpdate(status: "Mouse move", clearsError: true)
        )

        precondition(
            HIDCommandFeedbackPolicy.failureUpdate(
                currentStatus: "Input interrupted; reconnecting",
                currentError: "connection lost",
                nextError: "connection lost"
            ) == nil
        )

        precondition(
            HIDCommandFeedbackPolicy.failureUpdate(
                currentStatus: "Ready",
                currentError: nil,
                nextError: "connection lost"
            ) == HIDCommandFeedbackUpdate(
                status: "Input interrupted; reconnecting",
                clearsError: false
            )
        )

        precondition(
            HIDCommandFeedbackPolicy.successUpdate(
                currentStatus: "Key down",
                currentError: nil,
                nextStatus: "Key down",
                mode: .publishChanges
            ) == nil
        )

        precondition(
            HIDCommandFeedbackPolicy.successUpdate(
                currentStatus: "Input interrupted; reconnecting",
                currentError: "connection lost",
                nextStatus: "Key down",
                mode: .publishChanges
            ) == HIDCommandFeedbackUpdate(status: "Key down", clearsError: true)
        )
    }

    private static func testFullscreenHoverPolicyRunsOnlyInUsableFullscreenChrome() {
        precondition(
            !FullscreenHoverPolicy.isInsideTopStrip(
                locationY: 8,
                isFullscreen: false,
                controlsVisible: false,
                isOverlayPresented: false
            )
        )
        precondition(
            FullscreenHoverPolicy.isInsideTopStrip(
                locationY: 27,
                isFullscreen: true,
                controlsVisible: false,
                isOverlayPresented: false
            )
        )
        precondition(
            !FullscreenHoverPolicy.isInsideTopStrip(
                locationY: 29,
                isFullscreen: true,
                controlsVisible: false,
                isOverlayPresented: false
            )
        )
        precondition(
            FullscreenHoverPolicy.isInsideTopStrip(
                locationY: 57,
                isFullscreen: true,
                controlsVisible: true,
                isOverlayPresented: false
            )
        )
        precondition(
            !FullscreenHoverPolicy.isInsideTopStrip(
                locationY: 8,
                isFullscreen: true,
                controlsVisible: true,
                isOverlayPresented: true
            )
        )
    }

    private static func testRemoteDragLifecyclePreservesDragUntilMouseUp() {
        var lifecycle = RemoteMouseButtonLifecycle<Int>()

        precondition(!lifecycle.shouldForwardMovement(ownsPointer: false))
        lifecycle.press(1)
        precondition(lifecycle.shouldForwardMovement(ownsPointer: false))
        precondition(lifecycle.release(1))
        precondition(!lifecycle.shouldForwardMovement(ownsPointer: false))
        precondition(!lifecycle.release(1))

        lifecycle.press(1)
        lifecycle.press(2)
        precondition(lifecycle.takeAllPressedButtons() == Set([1, 2]))
        precondition(lifecycle.takeAllPressedButtons().isEmpty)
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

    private static func testEndpointRecordDeduplication() {
        struct Record: Equatable {
            let endpoint: String
            let value: String
        }

        let records = [
            Record(endpoint: "kvm-a:443", value: "old"),
            Record(endpoint: "kvm-b:443", value: "only"),
            Record(endpoint: "kvm-a:443", value: "new"),
        ]
        let deduplicated = EndpointRecordPolicy.keepingLast(records) { $0.endpoint }

        precondition(deduplicated == [
            Record(endpoint: "kvm-a:443", value: "new"),
            Record(endpoint: "kvm-b:443", value: "only"),
        ])

        let replaced = EndpointRecordPolicy.replacing(
            records,
            with: Record(endpoint: "kvm-a:443", value: "current")
        ) { $0.endpoint }
        precondition(replaced == [
            Record(endpoint: "kvm-a:443", value: "current"),
            Record(endpoint: "kvm-b:443", value: "only"),
        ])
    }

    private static func testCredentialMergePolicy() {
        precondition(CredentialMergePolicy.preferredToken(current: "fresh", loaded: "stale") == "fresh")
        precondition(CredentialMergePolicy.preferredToken(current: "", loaded: "loaded") == "loaded")
        precondition(CredentialMergePolicy.preferredToken(current: "", loaded: "") == "")
    }
}

@MainActor
private final class MutationEventRecorder {
    var events: [String] = []
}

private actor MutationBarrier {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
