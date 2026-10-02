import AppKit
import Foundation

@main
struct LocalInputCaptureTests {
    @MainActor static func main() async {
        do {
            try testPolicyTruthTable()
            try testReleaseDecisions()
            try testLiveEnvironment()
            try testConnectionAndModeGates()
            try testOverlappingLocalUIOwners()
            try testPreferencesSurviveSuspension()
            try testPreferencesChangedWhileSuspended()
            try testFocusAndRegistration()
            try await testManualDrainCannotOverrideDialog()
            print("LocalInputCaptureTests passed (9 groups; 1024 capture combinations)")
        } catch {
            fputs("LocalInputCaptureTests FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testPolicyTruthTable() throws {
        for bits in 0..<1024 {
            let flags = (0..<10).map { bits & (1 << $0) != 0 }
            let conditions = LocalInputCaptureConditions(
                modeReady: flags[0], sessionAvailable: flags[1],
                connectionTransitioning: flags[2], localUIBlocked: flags[3],
                inputBlocked: flags[4], appActive: flags[5], remoteWindowKey: flags[6],
                remoteKeyboardFocused: flags[7], keyboardRequested: flags[8], mouseRequested: flags[9]
            )
            let decision = LocalInputCapturePolicy.decision(for: conditions)
            let allPrerequisites = [flags[0], flags[1], !flags[2], !flags[3], !flags[4], flags[5], flags[6]]
            let allowed = !allPrerequisites.contains(false)
            try expect(decision.keyboardEnabled == (allowed && flags[7] && flags[8]),
                       "Keyboard permission mismatch for input combination \(bits)")
            try expect(decision.mouseEnabled == (allowed && flags[9]),
                       "Mouse permission mismatch for input combination \(bits)")
        }
    }

    private static func testReleaseDecisions() throws {
        for oldBits in 0..<4 {
            for newBits in 0..<4 {
                let previous = LocalInputCaptureDecision(keyboardEnabled: oldBits & 1 != 0, mouseEnabled: oldBits & 2 != 0)
                let next = LocalInputCaptureDecision(keyboardEnabled: newBits & 1 != 0, mouseEnabled: newBits & 2 != 0)
                let removedCapture = oldBits & ~newBits != 0
                try expect(LocalInputCapturePolicy.revoked(from: previous, to: next) == removedCapture,
                           "Only an effective capture revocation releases local HID (\(oldBits) to \(newBits))")
            }
        }
    }

    @MainActor private static func testLiveEnvironment() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = LocalInputFocusEnvironment.live()
        try expect(environment.isAppActive == NSApp.isActive, "Live focus environment must report current application state")
        try expect(environment.keyWindow === NSApp.keyWindow, "Live focus environment must report current key window")
        try expect(environment.modalWindow === NSApp.modalWindow, "Live focus environment must report current modal window")
    }

    @MainActor private static func testConnectionAndModeGates() throws {
        let fixture = CaptureFixture(connected: false)
        defer { fixture.finish() }
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.setSessionAvailable(true)
        try expectCapture(fixture, keyboard: true, mouse: true)
        fixture.manager.setConnectionTransitioning(true)
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.setConnectionTransitioning(false)
        try expectCapture(fixture, keyboard: true, mouse: true)
        fixture.manager.setLocalInputCaptureAllowed(false)
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.setConnectionTransitioning(true)
        fixture.manager.setConnectionTransitioning(false)
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.setLocalInputCaptureAllowed(true)
        try expectCapture(fixture, keyboard: true, mouse: true)
        fixture.manager.setSessionAvailable(false)
        try expectCapture(fixture, keyboard: false, mouse: false)
    }

    @MainActor private static func testOverlappingLocalUIOwners() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let first = UUID(), second = UUID()
        fixture.manager.setLocalUIBlocked(true, owner: first)
        fixture.manager.setLocalUIBlocked(true, owner: first)
        fixture.manager.setLocalUIBlocked(true, owner: second)
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.setLocalUIBlocked(false, owner: first)
        fixture.manager.setLocalUIBlocked(false, owner: first)
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.setLocalUIBlocked(false, owner: second)
        try expectCapture(fixture, keyboard: true, mouse: true)
        fixture.manager.setLocalUIBlocked(false, owner: UUID())
        try expectCapture(fixture, keyboard: true, mouse: true)
    }

    @MainActor private static func testPreferencesSurviveSuspension() throws {
        for keyboard in [false, true] {
            for mouse in [false, true] {
                let fixture = CaptureFixture()
                defer { fixture.finish() }
                if !keyboard { fixture.manager.stopKeyboardCapture() }
                if !mouse { fixture.manager.stopMouseCapture() }
                let owner = UUID()
                fixture.manager.setLocalUIBlocked(true, owner: owner)
                fixture.manager.setLocalInputCaptureAllowed(false)
                fixture.manager.setLocalInputCaptureAllowed(true)
                try expectCapture(fixture, keyboard: false, mouse: false)
                fixture.manager.setLocalUIBlocked(false, owner: owner)
                try expectCapture(fixture, keyboard: keyboard, mouse: mouse)
                fixture.manager.setSessionAvailable(false)
                fixture.manager.setSessionAvailable(true)
                try expectCapture(fixture, keyboard: keyboard, mouse: mouse)
            }
        }
    }

    @MainActor private static func testPreferencesChangedWhileSuspended() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let owner = UUID()
        fixture.manager.setLocalUIBlocked(true, owner: owner)
        fixture.manager.toggleKeyboardCapture()
        fixture.manager.toggleMouseCapture()
        fixture.manager.setLocalUIBlocked(false, owner: owner)
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.setLocalUIBlocked(true, owner: owner)
        fixture.manager.toggleKeyboardCapture()
        fixture.manager.setLocalUIBlocked(false, owner: owner)
        try expectCapture(fixture, keyboard: true, mouse: false)
    }

    @MainActor private static func testFocusAndRegistration() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        fixture.appIsActive = false
        fixture.manager.refreshLocalInputFocus()
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.appIsActive = true
        fixture.keyWindow = nil
        fixture.manager.refreshLocalInputFocus()
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.keyWindow = fixture.otherWindow
        fixture.manager.refreshLocalInputFocus()
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.keyWindow = fixture.window
        fixture.modalWindow = fixture.otherWindow
        fixture.manager.refreshLocalInputFocus()
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.modalWindow = nil
        fixture.manager.refreshLocalInputFocus()
        try expectCapture(fixture, keyboard: true, mouse: true)
        let localField = fixture.focusLocalText()
        fixture.manager.refreshLocalInputFocus()
        try expect(!fixture.manager.isKeyboardCaptureEnabled, "A local text field must keep keyboard ownership")
        try expect(localField.window === fixture.window, "Test editor must belong to the remote window")
        precondition(fixture.window.makeFirstResponder(fixture.surface))
        fixture.manager.refreshLocalInputFocus()
        try expectCapture(fixture, keyboard: true, mouse: true)
        fixture.manager.unregisterRemoteInputSurface(NSView())
        try expectCapture(fixture, keyboard: true, mouse: true)
        fixture.manager.unregisterRemoteInputSurface(fixture.surface)
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.registerRemoteInputSurface(fixture.surface)
        fixture.manager.registerRemoteInputSurface(fixture.surface)
        try expectCapture(fixture, keyboard: true, mouse: true)
    }

    @MainActor private static func testManualDrainCannotOverrideDialog() async throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let suiteName = "LocalInputCaptureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ControlModeStore(defaults: defaults)
        let drain = CaptureBarrier()
        let resumed = CaptureBarrier()
        var awaitingManualResume = false
        store.configureInputCapture({ allowed in
            fixture.manager.setLocalInputCaptureAllowed(allowed)
            if allowed && awaitingManualResume { resumed.release() }
        }, waitForRemoteMutations: { await drain.wait() })
        store.setMode(.codexHeadless)
        let owner = UUID()
        fixture.manager.setLocalUIBlocked(true, owner: owner)
        awaitingManualResume = true
        store.setMode(.manual)
        await drain.waitUntilEntered()
        try expectCapture(fixture, keyboard: false, mouse: false)
        drain.release()
        await resumed.wait()
        try expect(fixture.manager.isLocalInputCaptureAllowed, "Manual drain must complete in fixture")
        try expectCapture(fixture, keyboard: false, mouse: false)
        fixture.manager.setLocalUIBlocked(false, owner: owner)
        try expectCapture(fixture, keyboard: true, mouse: true)
    }
}
