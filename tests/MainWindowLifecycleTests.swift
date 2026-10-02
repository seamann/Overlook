import AppKit

@main
struct MainWindowLifecycleTests {
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let tests: [(String, @MainActor () throws -> Void)] = [
            ("close and reopen preserve the video view", testCloseAndReopen),
            ("menu reopen ignores a visible dialog", testDialogIsNotSelected),
            ("menu reopen restores a minimized main window", testMinimizedMainWindow),
            ("menu reopen without a main window is harmless", testMissingMainWindow),
            ("foreign windows keep their delegate close decision", testForeignClose),
            ("main window close does not close through its delegate", testMainCloseBypassesForwardedDelegate),
            ("cold mount attaches lifecycle without a later view update", testColdMount),
            ("registration preserves SwiftUI scene identity", testSceneIdentity),
            ("attachment follows a view moving between windows", testMovedAttachment),
        ]
        var failures: [String] = []
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)") }
        }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        guard failures.isEmpty else { throw WindowTestFailure.message("\(failures.count) window lifecycle regressions") }
        print("MainWindowLifecycleTests: \(tests.count) scenarios passed; isolated offscreen AppKit windows")
    }

    @MainActor private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor private static func testCloseAndReopen() throws {
        let main = makeWindow()
        MainWindowLifecycle.register(main)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let renderer = NSView(frame: content.bounds)
        content.addSubview(renderer)
        main.contentView = content
        let delegate = LifecycleDelegate()
        main.delegate = delegate
        defer { main.delegate = nil; main.orderOut(nil) }
        MainWindowLifecycle.show(in: [main])
        try expect(main.isVisible, "Main window did not become visible")

        main.performClose(nil)
        try expect(delegate.closeRequests == 1, "Native close did not reach lifecycle delegate")
        try expect(!main.isVisible, "Closing main window did not hide it")
        try expect(delegate.didCloseCount == 0, "Main window was closed instead of retained")
        try expect(main.contentView === content && renderer.superview === content,
                   "Closing main window detached the retained video view")

        let reopened = MainWindowLifecycle.show(in: [main])
        try expect(reopened === main && main.isVisible, "Menu reopen did not reuse the retained main window")
        try expect(main.contentView === content && renderer.superview === content,
                   "Menu reopen replaced the video view")
    }

    @MainActor private static func testDialogIsNotSelected() throws {
        let dialog = makeWindow()
        let main = makeWindow()
        MainWindowLifecycle.register(main)
        dialog.identifier = NSUserInterfaceItemIdentifier("SyntheticSettingsDialog")
        dialog.orderFront(nil)
        defer { dialog.orderOut(nil); main.orderOut(nil) }
        try expect(MainWindowLifecycle.show(in: [dialog, main]) === main,
                   "Menu reopen chose a dialog instead of the tagged main window")
        try expect(main.isVisible, "Main window remained hidden behind dialog")
    }

    @MainActor private static func testMinimizedMainWindow() throws {
        let main = makeWindow()
        MainWindowLifecycle.register(main)
        defer { main.orderOut(nil) }
        main.orderFront(nil)
        main.miniaturize(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try expect(main.isMiniaturized, "Fixture main window did not minimize")
        try expect(MainWindowLifecycle.show(in: [main]) === main, "Minimized main window was not selected")
        try expect(!main.isMiniaturized && main.isVisible, "Menu reopen left main window minimized")
    }

    @MainActor private static func testMissingMainWindow() throws {
        let dialog = makeWindow()
        defer { dialog.orderOut(nil) }
        try expect(MainWindowLifecycle.show(in: []) == nil, "Empty window list created a window")
        try expect(MainWindowLifecycle.show(in: [dialog]) == nil,
                   "Missing main window activated a foreign window")
        try expect(!dialog.isVisible, "Foreign window was shown by menu reopen")
    }

    @MainActor private static func testForeignClose() throws {
        let foreign = makeWindow()
        let forwarded = ForwardedDelegate(allowsClose: false)
        defer { foreign.orderOut(nil) }
        try expect(!MainWindowLifecycle.shouldClose(foreign, forwardingTo: forwarded),
                   "Foreign delegate refusal was ignored")
        try expect(forwarded.closeRequests == 1, "Foreign close was not forwarded")
        forwarded.allowsClose = true
        try expect(MainWindowLifecycle.shouldClose(foreign, forwardingTo: forwarded),
                   "Foreign delegate approval was ignored")
        try expect(forwarded.closeRequests == 2, "Foreign close was not forwarded twice")
        try expect(MainWindowLifecycle.shouldClose(foreign, forwardingTo: nil),
                   "Unowned foreign window could not close")
        try expect(MainWindowLifecycle.shouldClose(foreign, forwardingTo: NSObjectDelegate()),
                   "Foreign delegate without a close hook could not close")
    }

    @MainActor private static func testMainCloseBypassesForwardedDelegate() throws {
        let main = makeWindow()
        MainWindowLifecycle.register(main)
        let forwarded = ForwardedDelegate(allowsClose: true)
        defer { main.orderOut(nil) }
        main.orderFront(nil)
        try expect(!MainWindowLifecycle.shouldClose(main, forwardingTo: forwarded),
                   "Main window close delegated to SwiftUI and destroyed the scene")
        try expect(!main.isVisible && forwarded.closeRequests == 0,
                   "Main window close did not retain scene independently of foreign delegates")
        try expect(!main.isReleasedWhenClosed, "Main window is not retained by AppKit")
    }

    @MainActor private static func testColdMount() throws {
        let main = makeWindow()
        main.identifier = NSUserInterfaceItemIdentifier("main")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        main.contentView = content
        let probe = MainWindowAttachmentView(frame: .zero)
        let delegate = LifecycleDelegate()
        var attachedWindows: [NSWindow] = []
        probe.onWindowAttached = { window in
            attachedWindows.append(window)
            MainWindowLifecycle.register(window)
            window.delegate = delegate
        }
        defer { main.delegate = nil; main.orderOut(nil) }
        // SwiftUI can update the representable before AppKit mounts its NSView.
        // The subsequent mount must work without another update or video frame.
        try expect(probe.window == nil && attachedWindows.isEmpty, "Fixture was not a cold unattached view")
        content.addSubview(probe)
        try expect(attachedWindows.count == 1 && attachedWindows.first === main,
                   "Cold mount never attached the lifecycle without a later SwiftUI update")
        try expect(main.delegate === delegate, "Cold mount did not install the close delegate")
        MainWindowLifecycle.show(in: NSApp.windows)
        main.performClose(nil)
        try expect(delegate.closeRequests == 1 && delegate.didCloseCount == 0 && !main.isVisible,
                   "First cold window close destroyed its scene")
        try expect(MainWindowLifecycle.show(in: NSApp.windows) === main && main.contentView === content,
                   "Cold window could not reopen its retained scene")
    }

    @MainActor private static func testSceneIdentity() throws {
        let main = makeWindow()
        let dialog = makeWindow()
        let sceneID = NSUserInterfaceItemIdentifier("main")
        main.identifier = sceneID
        dialog.identifier = sceneID
        defer { main.orderOut(nil); dialog.orderOut(nil) }
        MainWindowLifecycle.register(main)
        try expect(main.identifier == sceneID, "Lifecycle registration overwrote SwiftUI scene identity")
        try expect(MainWindowLifecycle.show(in: [dialog, main]) === main,
                   "A matching scene identifier selected an unregistered dialog")
        try expect(MainWindowLifecycle.shouldClose(dialog, forwardingTo: nil),
                   "A foreign matching-identifier window was treated as the lifecycle owner")
    }

    @MainActor private static func testMovedAttachment() throws {
        let first = makeWindow()
        let second = makeWindow()
        let probe = MainWindowAttachmentView(frame: .zero)
        var attachedWindows: [NSWindow] = []
        probe.onWindowAttached = { attachedWindows.append($0) }
        defer { first.orderOut(nil); second.orderOut(nil) }
        first.contentView?.addSubview(probe)
        probe.removeFromSuperview()
        try expect(probe.window == nil, "Detached probe still owns its old window")
        second.contentView?.addSubview(probe)
        try expect(attachedWindows.count == 2 && attachedWindows[0] === first && attachedWindows[1] === second,
                   "Attachment callback did not follow the real window transition")
        let quietProbe = MainWindowAttachmentView(frame: .zero)
        second.contentView?.addSubview(quietProbe)
        try expect(quietProbe.window === second, "Probe without callback did not mount safely")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw WindowTestFailure.message(message) }
    }
}

private enum WindowTestFailure: Error {
    case message(String)
}

@MainActor private final class LifecycleDelegate: NSObject, NSWindowDelegate {
    var closeRequests = 0
    var didCloseCount = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeRequests += 1
        return MainWindowLifecycle.shouldClose(sender, forwardingTo: nil)
    }
    func windowWillClose(_ notification: Notification) { didCloseCount += 1 }
}

@MainActor private final class ForwardedDelegate: NSObject, NSWindowDelegate {
    var allowsClose: Bool
    var closeRequests = 0
    init(allowsClose: Bool) { self.allowsClose = allowsClose }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeRequests += 1
        return allowsClose
    }
}

@MainActor private final class NSObjectDelegate: NSObject, NSWindowDelegate {}
