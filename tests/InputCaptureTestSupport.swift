// Local-only fixture: real InputManager and AppKit event monitors, no transports.
import AppKit
import Foundation

struct KVMDevice {
    let host: String
    let port: Int
    let authToken: String
}

struct InputEvent {
    let type: String
    let data: [String: JSONValue]
}

@MainActor
final class WebRTCManager {
    private(set) var events: [InputEvent] = []
    func sendInputEvent(_ event: InputEvent) { events = events + [event] }
}

@MainActor
final class CaptureNotificationRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
final class FixtureRemoteSurface: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class CaptureFixture {
    let window: NSWindow
    let surface: FixtureRemoteSurface
    let otherWindow: NSWindow
    let fakeHID = WebRTCManager()
    var appIsActive = true
    var keyWindow: NSWindow?
    var modalWindow: NSWindow?
    private(set) var manager: InputManager!

    init(connected: Bool = true, startCaptureExplicitly: Bool = false, clipboardText: String? = nil) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        window = Self.makeWindow()
        otherWindow = Self.makeWindow()
        surface = FixtureRemoteSurface(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView!.addSubview(surface)
        precondition(window.makeFirstResponder(surface))
        keyWindow = window
        manager = InputManager(inputFocusEnvironment: { [weak self] in
            LocalInputFocusEnvironment(
                isAppActive: self?.appIsActive ?? false,
                keyWindow: self?.keyWindow,
                modalWindow: self?.modalWindow
            )
        }, clipboardText: { clipboardText })
        manager.setup(with: fakeHID)
        manager.setTransportMode(.webRTC)
        manager.registerRemoteInputSurface(surface)
        manager.setSessionAvailable(connected)
        manager.setLocalInputCaptureAllowed(true)
        if startCaptureExplicitly { manager.startFullInputCapture() }
        manager.refreshLocalInputFocus()
    }

    func finish() {
        manager.setSessionAvailable(false)
        manager.setGLKVMClient(nil)
        manager.unregisterRemoteInputSurface(surface)
        manager.stopFullInputCapture()
    }

    func event(type: NSEvent.EventType = .keyDown, window: NSWindow? = nil,
               characters: String = "x", keyCode: UInt16 = 7,
               modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: (window ?? self.window).windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }

    func focusLocalText() -> NSTextField {
        let field = NSTextField(string: "local")
        window.contentView!.addSubview(field)
        precondition(window.makeFirstResponder(field))
        return field
    }

    private static func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                 styleMask: [.titled], backing: .buffered, defer: false)
    }
}

struct CaptureTestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String,
            file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition() else { throw CaptureTestFailure(description: "\(file):\(line): \(message)") }
}

@MainActor
func expectCapture(_ fixture: CaptureFixture, keyboard: Bool, mouse: Bool) throws {
    try expect(fixture.manager.isKeyboardCaptureEnabled == keyboard,
               "keyboard capture expected \(keyboard), actual \(fixture.manager.isKeyboardCaptureEnabled)")
    try expect(fixture.manager.isMouseCaptureEnabled == mouse,
               "mouse capture expected \(mouse), actual \(fixture.manager.isMouseCaptureEnabled)")
}

@MainActor
final class CaptureBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func wait() async {
        entered = true
        let observers = entryWaiters
        entryWaiters = []
        observers.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { waiters = waiters + [$0] }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters = entryWaiters + [$0] }
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
