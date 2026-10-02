import AppKit
import Foundation

@main
struct InputManagerCaptureTests {
    @MainActor static func main() {
        do {
            try testSessionBindingStartsRequestedDefaultCapture()
            try testRemoteKeysReachTransport()
            try testOtherWindowKeepsKeys()
            try testRegisteredWindowsKeepSeparateOwnership()
            try testWindowlessEventStaysLocal()
            try testLocalEditorKeepsKeysWithoutExplicitRefresh()
            try testModifiersAndShortcutsStayLocalInEditor()
            try testBlockedVideoMouseNeverReachesTransport()
            print("InputManagerCaptureTests passed (8 groups)")
        } catch {
            fputs("InputManagerCaptureTests FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func testSessionBindingStartsRequestedDefaultCapture() throws {
        // Mirror the production AppDelegate path: setup and authority setters
        // must install capture without resetting preferences via startFull.
        let fixture = CaptureFixture(connected: false, startCaptureExplicitly: false)
        defer { fixture.finish() }
        NSApp.sendEvent(fixture.event())
        try expect(fixture.fakeHID.events.isEmpty, "A disconnected default session cannot forward keys")
        fixture.manager.setSessionAvailable(true)
        try expectCapture(fixture, keyboard: true, mouse: true)
        NSApp.sendEvent(fixture.event())
        try expect(fixture.fakeHID.events.count == 1,
                   "Session binding must install the real keyboard monitor without startFullInputCapture")
    }

    @MainActor private static func testRegisteredWindowsKeepSeparateOwnership() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let secondSurface = FixtureRemoteSurface(frame: fixture.surface.frame)
        fixture.otherWindow.contentView!.addSubview(secondSurface)
        precondition(fixture.otherWindow.makeFirstResponder(secondSurface))
        fixture.manager.registerRemoteInputSurface(secondSurface)
        defer { fixture.manager.unregisterRemoteInputSurface(secondSurface) }
        fixture.keyWindow = fixture.otherWindow
        fixture.manager.refreshLocalInputFocus()
        NSApp.sendEvent(fixture.event())
        try expect(fixture.fakeHID.events.isEmpty, "An inactive registered window must not steal the active window's input")
        NSApp.sendEvent(fixture.event(window: fixture.otherWindow))
        try expect(fixture.fakeHID.events.count == 1, "The active registered surface must still receive input")
    }

    @MainActor private static func testWindowlessEventStaysLocal() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "x", charactersIgnoringModifiers: "x",
                                    isARepeat: false, keyCode: 7)!
        NSApp.sendEvent(event)
        try expect(fixture.fakeHID.events.isEmpty, "A windowless key event cannot own the remote surface")
    }

    @MainActor private static func testRemoteKeysReachTransport() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        NSApp.sendEvent(fixture.event())
        NSApp.sendEvent(fixture.event(type: .keyUp))
        try expect(fixture.fakeHID.events.count == 2, "Remote surface must receive key down and key up exactly once")
        try expect(fixture.fakeHID.events.allSatisfy { $0.type == "keyboard" }, "Expected keyboard transport events")
        try expect(fixture.fakeHID.events[0].data["isKeyDown"] == .bool(true), "First event must press key")
        try expect(fixture.fakeHID.events[1].data["isKeyDown"] == .bool(false), "Second event must release key")
    }

    @MainActor private static func testOtherWindowKeepsKeys() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        var localEvents = 0
        let spy = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            localEvents += 1
            return event
        }!
        defer { NSEvent.removeMonitor(spy) }
        NSApp.sendEvent(fixture.event(window: fixture.otherWindow))
        NSApp.sendEvent(fixture.event(type: .keyUp, window: fixture.otherWindow))
        try expect(fixture.fakeHID.events.isEmpty, "Another window's keys must never reach remote HID")
        try expect(localEvents == 2, "Another window's keys must pass through the local monitor chain")
    }

    @MainActor private static func testLocalEditorKeepsKeysWithoutExplicitRefresh() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        _ = fixture.focusLocalText()
        var localEvents = 0
        let spy = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            localEvents += 1
            return event
        }!
        defer { NSEvent.removeMonitor(spy) }
        NSApp.sendEvent(fixture.event(characters: "ä🙂'", keyCode: 0))
        try expect(fixture.fakeHID.events.isEmpty, "A real NSTextField field editor must keep its input local")
        try expect(localEvents == 1, "Editor key must not be swallowed")
        precondition(fixture.window.makeFirstResponder(fixture.surface))
        fixture.manager.refreshLocalInputFocus()
        NSApp.sendEvent(fixture.event())
        try expect(fixture.fakeHID.events.count == 1, "Returning focus to remote surface must restore requested capture")
    }

    @MainActor private static func testModifiersAndShortcutsStayLocalInEditor() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        _ = fixture.focusLocalText()
        let toggles = CaptureNotificationRecorder()
        let token = NotificationCenter.default.addObserver(forName: .overlookToggleCopyMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { toggles.record() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        NSApp.sendEvent(fixture.event(type: .flagsChanged, keyCode: 56, modifiers: [.shift]))
        NSApp.sendEvent(fixture.event(characters: "c", keyCode: 8, modifiers: [.command]))
        NSApp.sendEvent(fixture.event(type: .keyUp, characters: "c", keyCode: 8, modifiers: [.command]))
        try expect(fixture.fakeHID.events.isEmpty, "Editor modifier and shortcut events must remain local")
        try expect(toggles.count == 0, "Local Cmd+C must not toggle remote OCR mode")
    }

    @MainActor private static func testBlockedVideoMouseNeverReachesTransport() throws {
        let fixture = CaptureFixture()
        defer { fixture.finish() }
        let owner = UUID()
        fixture.manager.setLocalUIBlocked(true, owner: owner)
        fixture.manager.handleVideoMouseMove(pointInView: CGPoint(x: 10, y: 10), viewSize: CGSize(width: 100, height: 100), videoSize: nil)
        fixture.manager.handleVideoMouseButton(button: .left, isDown: true, pointInView: CGPoint(x: 10, y: 10), viewSize: CGSize(width: 100, height: 100), videoSize: nil)
        fixture.manager.handleVideoMouseScroll(deltaX: 0, deltaY: 1)
        try expect(fixture.fakeHID.events.isEmpty, "Local dialog blocks move, button, and scroll callbacks")
        fixture.manager.setLocalUIBlocked(false, owner: owner)
        fixture.manager.handleVideoMouseButton(button: .left, isDown: true, pointInView: CGPoint(x: 10, y: 10), viewSize: CGSize(width: 100, height: 100), videoSize: nil)
        try expect(fixture.fakeHID.events.count == 1, "Requested mouse capture resumes after the final dialog closes")
    }
}
