import AppKit

@MainActor
enum MainWindowLifecycle {
    private static weak var mainWindow: NSWindow?

    static func register(_ window: NSWindow) {
        mainWindow = window
        window.isReleasedWhenClosed = false
    }

    @discardableResult
    static func show(in windows: [NSWindow]) -> NSWindow? {
        guard let window = mainWindow, windows.contains(where: { $0 === window }) else { return nil }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func shouldClose(_ window: NSWindow, forwardingTo delegate: NSWindowDelegate?) -> Bool {
        guard window === mainWindow else {
            return delegate?.windowShouldClose?(window) ?? true
        }
        // A single scene owns the video renderer and UI/session state. Keep that
        // scene alive for Menu Bar and Headless control when its window is hidden.
        window.orderOut(nil)
        return false
    }
}

final class MainWindowAttachmentView: NSView {
    var onWindowAttached: (@MainActor (NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onWindowAttached?(window)
    }
}
