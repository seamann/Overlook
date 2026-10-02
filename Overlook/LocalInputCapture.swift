import AppKit

struct LocalInputFocusEnvironment {
    let isAppActive: Bool
    let keyWindow: NSWindow?
    let modalWindow: NSWindow?

    @MainActor
    static func live() -> LocalInputFocusEnvironment {
        LocalInputFocusEnvironment(
            isAppActive: NSApp.isActive,
            keyWindow: NSApp.keyWindow,
            modalWindow: NSApp.modalWindow
        )
    }
}

struct LocalInputCaptureConditions: Equatable {
    let modeReady: Bool
    let sessionAvailable: Bool
    let connectionTransitioning: Bool
    let localUIBlocked: Bool
    let inputBlocked: Bool
    let appActive: Bool
    let remoteWindowKey: Bool
    let remoteKeyboardFocused: Bool
    let keyboardRequested: Bool
    let mouseRequested: Bool
}

struct LocalInputCaptureDecision: Equatable {
    let keyboardEnabled: Bool
    let mouseEnabled: Bool
}

enum LocalInputCapturePolicy {
    static func decision(for conditions: LocalInputCaptureConditions) -> LocalInputCaptureDecision {
        let commonEligibility = conditions.modeReady
            && conditions.sessionAvailable
            && !conditions.connectionTransitioning
            && !conditions.localUIBlocked
            && !conditions.inputBlocked
            && conditions.appActive
            && conditions.remoteWindowKey

        return LocalInputCaptureDecision(
            keyboardEnabled: commonEligibility
                && conditions.remoteKeyboardFocused
                && conditions.keyboardRequested,
            mouseEnabled: commonEligibility && conditions.mouseRequested
        )
    }

    static func revoked(
        from previous: LocalInputCaptureDecision,
        to next: LocalInputCaptureDecision
    ) -> Bool {
        (previous.keyboardEnabled && !next.keyboardEnabled)
            || (previous.mouseEnabled && !next.mouseEnabled)
    }
}

@MainActor
final class LocalInputCaptureContext {
    var modeReady = true
    var sessionAvailable = false
    var connectionTransitioning = false
    var inputBlocked = false
    var keyboardRequested = true
    var mouseRequested = true

    private(set) var localUIBlockers: Set<UUID> = []
    private var remoteSurfaces: [WeakRemoteInputSurface] = []
    private let focusEnvironment: @MainActor () -> LocalInputFocusEnvironment

    init(focusEnvironment: @escaping @MainActor () -> LocalInputFocusEnvironment) {
        self.focusEnvironment = focusEnvironment
    }

    func setLocalUIBlocked(_ blocked: Bool, owner: UUID) {
        if blocked {
            localUIBlockers.insert(owner)
        } else {
            localUIBlockers.remove(owner)
        }
    }

    func registerRemoteInputSurface(_ surface: NSView) {
        pruneReleasedSurfaces()
        guard !remoteSurfaces.contains(where: { $0.view === surface }) else { return }
        remoteSurfaces.append(WeakRemoteInputSurface(surface))
    }

    func unregisterRemoteInputSurface(_ surface: NSView) {
        remoteSurfaces.removeAll { $0.view == nil || $0.view === surface }
    }

    func decision() -> LocalInputCaptureDecision {
        let environment = focusEnvironment()
        let keyWindow = environment.keyWindow
        let registeredSurfaces = liveRemoteSurfaces()
        let remoteWindowKey = keyWindow.map { window in
            registeredSurfaces.contains { $0.window === window }
        } ?? false
        let remoteKeyboardFocused = keyWindow.map { window in
            isRemoteKeyboardResponder(window.firstResponder, in: registeredSurfaces)
        } ?? false
        let hasSheet = keyWindow?.attachedSheet != nil

        return LocalInputCapturePolicy.decision(
            for: LocalInputCaptureConditions(
                modeReady: modeReady,
                sessionAvailable: sessionAvailable,
                connectionTransitioning: connectionTransitioning,
                localUIBlocked: !localUIBlockers.isEmpty || hasSheet || environment.modalWindow != nil,
                inputBlocked: inputBlocked,
                appActive: environment.isAppActive,
                remoteWindowKey: remoteWindowKey,
                remoteKeyboardFocused: remoteKeyboardFocused,
                keyboardRequested: keyboardRequested,
                mouseRequested: mouseRequested
            )
        )
    }

    func keyboardEventIsEligible(_ event: NSEvent) -> Bool {
        let environment = focusEnvironment()
        guard let eventWindow = event.window,
              eventWindow === environment.keyWindow,
              decision().keyboardEnabled
        else {
            return false
        }
        return true
    }

    private func liveRemoteSurfaces() -> [NSView] {
        pruneReleasedSurfaces()
        return remoteSurfaces.compactMap(\.view)
    }

    private func pruneReleasedSurfaces() {
        remoteSurfaces.removeAll { $0.view == nil }
    }

    private func isRemoteKeyboardResponder(_ responder: NSResponder?, in surfaces: [NSView]) -> Bool {
        guard let view = responder as? NSView, !isEditableTextResponder(view) else { return false }
        return surfaces.contains { surface in
            view === surface || view.isDescendant(of: surface)
        }
    }

    private func isEditableTextResponder(_ view: NSView) -> Bool {
        if let textView = view as? NSTextView {
            return textView.isEditable
        }
        if let textField = view as? NSTextField {
            return textField.isEditable
        }
        return false
    }
}

private final class WeakRemoteInputSurface {
    weak var view: NSView?

    init(_ view: NSView) {
        self.view = view
    }
}
