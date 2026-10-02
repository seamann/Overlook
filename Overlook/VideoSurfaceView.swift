import SwiftUI
import AppKit
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(WebRTC)
import WebRTC
#endif

struct VideoSurfaceView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var ocrManager: OCRManager

    @Binding var isOCRModeEnabled: Bool
    @Binding var selectedText: String
    @Binding var isShowingOCRResult: Bool

    let onReconnect: () -> Void
    let hidesLocalCursor: Bool

    @State private var ocrDragStart: CGPoint?
    @State private var ocrDragCurrent: CGPoint?
    @State private var ocrRegionsTask: Task<Void, Never>?

    private var ocrSelectionRect: CGRect? {
        guard let start = ocrDragStart, let current = ocrDragCurrent else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let width = abs(start.x - current.x)
        let height = abs(start.y - current.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

#if canImport(WebRTC)
                if let videoView = webRTCManager.videoView {
                    VideoViewRepresentable(
                        videoView: videoView,
                        inputManager: inputManager,
                        hidesLocalCursor: hidesLocalCursor,
                        onMouseMove: { pointInView, deltaInView in
                            guard !isOCRModeEnabled else { return }
                            inputManager.handleVideoMouseMove(
                                pointInView: pointInView,
                                deltaInView: deltaInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize()
                            )
                        },
                        onMouseButton: { button, isDown, pointInView in
                            guard !isOCRModeEnabled else { return }
                            inputManager.handleVideoMouseButton(
                                button: button,
                                isDown: isDown,
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize()
                            )
                        },
                        onScrollWheel: { deltaX, deltaY in
                            guard !isOCRModeEnabled else { return }
                            inputManager.handleVideoMouseScroll(deltaX: deltaX, deltaY: deltaY)
                        }
                    )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Text("No Video Stream")
                        .foregroundColor(.white)
                }
#else
                Text("WebRTC not installed")
                    .foregroundColor(.white)
#endif

                if isOCRModeEnabled {
                    OCRSelectionOverlay(
                        regions: ocrManager.recognizedRegions,
                        selectionRectInView: ocrSelectionRect,
                        viewSize: geometry.size,
                        videoSize: currentVideoSize()
                    )
                }

                if isOCRModeEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if ocrDragStart == nil {
                                        ocrDragStart = value.startLocation
                                    }
                                    ocrDragCurrent = value.location
                                }
                                .onEnded { value in
                                    let location = value.location
                                    let start = ocrDragStart ?? value.startLocation
                                    let dx = location.x - start.x
                                    let dy = location.y - start.y
                                    let distance = hypot(dx, dy)

                                    if distance < 8 {
                                        performOCR(at: location, in: geometry)
                                    } else if let rect = ocrSelectionRect, rect.width > 4, rect.height > 4 {
                                        performOCR(inViewRect: rect, in: geometry)
                                    }

                                    ocrDragStart = nil
                                    ocrDragCurrent = nil
                                }
                        )
                }

                if webRTCManager.isConnecting || webRTCManager.isStreamStalled || (webRTCManager.hasEverConnectedToStream && !webRTCManager.isConnected) {
                    VStack(spacing: 10) {
                        Text(webRTCManager.isConnecting ? "Connecting…" : "Connection Lost")
                            .font(.headline)

                        if let reason = webRTCManager.lastDisconnectReason, !reason.isEmpty {
                            Text(reason)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        if let age = webRTCManager.lastVideoFrameAgeSeconds, webRTCManager.isConnecting == false {
                            Text("Last video frame: \(age)s ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Reconnect") {
                            onReconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(webRTCManager.isConnecting)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
        }
        .onChange(of: isOCRModeEnabled) { _, enabled in
            setOCRMode(enabled)
        }
        .onAppear {
            setOCRMode(isOCRModeEnabled)
        }
        .onDisappear {
            ocrRegionsTask?.cancel()
            ocrRegionsTask = nil
        }
    }

    private func setOCRMode(_ enabled: Bool) {
        webRTCManager.setFrameCaptureEnabled(enabled)
        if enabled {
            ocrRegionsTask?.cancel()
            ocrRegionsTask = Task { @MainActor in
                while !Task.isCancelled && isOCRModeEnabled {
                    _ = try? await ocrManager.detectTextRegions(in: webRTCManager.currentFrame)
                    try? await Task.sleep(nanoseconds: 650_000_000)
                }
            }
        } else {
            ocrRegionsTask?.cancel()
            ocrRegionsTask = nil
            ocrDragStart = nil
            ocrDragCurrent = nil
            ocrManager.recognizedRegions = []
        }
    }

    private func currentVideoSize() -> CGSize? {
        if let size = webRTCManager.videoSize, size.width > 0, size.height > 0 {
            return size
        }

        guard let pixelBuffer = webRTCManager.currentFrame else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width <= 0 || height <= 0 {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func performOCR(at location: CGPoint, in geometry: GeometryProxy) {
        let normalized = inputManager.normalizePointInViewToVideo(
            pointInView: location,
            viewSize: geometry.size,
            videoSize: currentVideoSize()
        )
        let videoPoint = CGPoint(x: normalized.x, y: 1.0 - normalized.y)

        Task {
            do {
                let text = try await ocrManager.recognizeText(at: videoPoint, in: webRTCManager.currentFrame)
                await MainActor.run {
                    selectedText = text
                    isShowingOCRResult = true
                }
            } catch {
                print("OCR failed: \(error)")
            }
        }
    }

    private func performOCR(inViewRect rect: CGRect, in geometry: GeometryProxy) {
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

        let n1 = inputManager.normalizePointInViewToVideo(
            pointInView: topLeft,
            viewSize: geometry.size,
            videoSize: currentVideoSize()
        )

        let n2 = inputManager.normalizePointInViewToVideo(
            pointInView: bottomRight,
            viewSize: geometry.size,
            videoSize: currentVideoSize()
        )

        let v1 = CGPoint(x: n1.x, y: 1.0 - n1.y)
        let v2 = CGPoint(x: n2.x, y: 1.0 - n2.y)

        let minX = max(0, min(v1.x, v2.x))
        let minY = max(0, min(v1.y, v2.y))
        let maxX = min(1, max(v1.x, v2.x))
        let maxY = min(1, max(v1.y, v2.y))

        let region = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        guard region.width > 0.001, region.height > 0.001 else { return }

        Task {
            do {
                let text = try await ocrManager.recognizeTextInRegion(region, in: webRTCManager.currentFrame)
                await MainActor.run {
                    selectedText = text
                    isShowingOCRResult = true
                }
            } catch {
                print("OCR failed: \(error)")
            }
        }
    }
}

#if canImport(WebRTC)
struct VideoViewRepresentable: NSViewRepresentable {
    let videoView: RTCMTLNSVideoView
    let inputManager: InputManager
    let hidesLocalCursor: Bool
    let onMouseMove: (CGPoint, CGSize) -> Void
    let onMouseButton: (MouseButton, Bool, CGPoint) -> Void
    let onScrollWheel: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingContainerView {
        let container = TrackingContainerView()
        container.inputManager = inputManager
        container.hidesLocalCursor = hidesLocalCursor
        container.onMouseMove = onMouseMove
        container.onMouseButton = onMouseButton
        container.onScrollWheel = onScrollWheel
        container.embedVideoViewIfNeeded(videoView)
        return container
    }

    static func dismantleNSView(_ nsView: TrackingContainerView, coordinator: ()) {
        nsView.inputManager = nil
    }

    func updateNSView(_ nsView: TrackingContainerView, context: Context) {
        nsView.inputManager = inputManager
        nsView.hidesLocalCursor = hidesLocalCursor
        nsView.onMouseMove = onMouseMove
        nsView.onMouseButton = onMouseButton
        nsView.onScrollWheel = onScrollWheel
        nsView.embedVideoViewIfNeeded(videoView)
    }
}

final class TrackingContainerView: NSView {
    var inputManager: InputManager? {
        get { inputSurface.inputManager }
        set { inputSurface.inputManager = newValue }
    }
    var onMouseMove: ((CGPoint, CGSize) -> Void)? {
        get { inputSurface.onMouseMove }
        set { inputSurface.onMouseMove = newValue }
    }
    var onMouseButton: ((MouseButton, Bool, CGPoint) -> Void)? {
        get { inputSurface.onMouseButton }
        set { inputSurface.onMouseButton = newValue }
    }
    var onScrollWheel: ((CGFloat, CGFloat) -> Void)? {
        get { inputSurface.onScrollWheel }
        set { inputSurface.onScrollWheel = newValue }
    }
    var hidesLocalCursor: Bool {
        get { inputSurface.hidesLocalCursor }
        set { inputSurface.hidesLocalCursor = newValue }
    }

    private weak var embeddedVideoView: RTCMTLNSVideoView?
    private var embeddedConstraints: [NSLayoutConstraint] = []
    private let inputSurface = RemoteInputSurfaceView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInputSurface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInputSurface()
    }

    private func configureInputSurface() {
        wantsLayer = true
        inputSurface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputSurface)
        NSLayoutConstraint.activate([
            inputSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputSurface.topAnchor.constraint(equalTo: topAnchor),
            inputSurface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func embedVideoViewIfNeeded(_ videoView: RTCMTLNSVideoView) {
        guard embeddedVideoView !== videoView else { return }

        if !embeddedConstraints.isEmpty {
            NSLayoutConstraint.deactivate(embeddedConstraints)
            embeddedConstraints.removeAll()
        }

        embeddedVideoView?.removeFromSuperview()
        embeddedVideoView = videoView

        videoView.removeFromSuperview()
        addSubview(videoView, positioned: .below, relativeTo: inputSurface)

        videoView.translatesAutoresizingMaskIntoConstraints = false
        embeddedConstraints = [
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(embeddedConstraints)
    }
}

/// Topmost, transparent owner of local mouse input. Keeping this separate from
/// the WebRTC renderer prevents AppKit from restoring the renderer's cursor
/// after a click or a cursor-rectangle rebuild.
final class RemoteInputSurfaceView: NSView {
    weak var inputManager: InputManager? {
        didSet {
            guard oldValue !== inputManager else { return }
            oldValue?.unregisterRemoteInputSurface(self)
            if window != nil { inputManager?.registerRemoteInputSurface(self) }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.inputManager?.refreshLocalInputFocus() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.inputManager?.refreshLocalInputFocus() }
        return accepted
    }

    var onMouseMove: ((CGPoint, CGSize) -> Void)?
    var onMouseButton: ((MouseButton, Bool, CGPoint) -> Void)?
    var onScrollWheel: ((CGFloat, CGFloat) -> Void)?

    var hidesLocalCursor = false {
        didSet {
            guard oldValue != hidesLocalCursor else { return }
            window?.invalidateCursorRects(for: self)
            refreshPointerState(forceCursorRefresh: true)
        }
    }

    private var trackingAreaRef: NSTrackingArea?
    private var notificationObservers: [NSObjectProtocol] = []
    private var pointerPresence = RemotePointerPresenceState()
    private var ownsCursorHideLease = false
    private var invisibleCursorIsApplied = false
    private var remoteButtonLifecycle = RemoteMouseButtonLifecycle<MouseButton>()
    private var lastOwnedFlippedPoint: CGPoint?

    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    deinit {
        removeNotificationObservers()
        releasePressedRemoteButtonsAtLastOwnedPoint()
        forceShowCursor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        inputManager?.unregisterRemoteInputSurface(self)
        removeNotificationObservers()
        releasePressedRemoteButtonsAtLastOwnedPoint()
        forceShowCursor()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if window != nil { inputManager?.registerRemoteInputSurface(self) }
        installNotificationObservers()
        window?.invalidateCursorRects(for: self)
        refreshPointerState(forceCursorRefresh: true)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard hidesLocalCursor else {
            addCursorRect(bounds, cursor: .arrow)
            return
        }

        let cursorRects = RemotePointerOwnershipPolicy.cursorRects(
            in: bounds,
            topChromeReleaseBandHeight: topChromeReleaseBandHeight
        )
        if !cursorRects.remoteSurface.isEmpty {
            addCursorRect(cursorRects.remoteSurface, cursor: Self.invisibleCursor)
        }
        if !cursorRects.topChromeReleaseBand.isEmpty {
            addCursorRect(cursorRects.topChromeReleaseBand, cursor: .arrow)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseMoved,
            .mouseEnteredAndExited,
            .enabledDuringMouseDrag,
            .cursorUpdate,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updatePointerState(with: event, forceCursorRefresh: true)
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointerState(with: event, forceCursorRefresh: true)
    }

    override func mouseExited(with event: NSEvent) {
        pointerPresence.exit()
        updateCursorVisibility()
    }

    override func mouseMoved(with event: NSEvent) {
        guard updatePointerState(with: event) else { return }
        emitMouseMove(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        emitMouseButton(.left, isPressed: true, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        emitMouseButton(.left, isPressed: false, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        emitMouseButton(.right, isPressed: true, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        emitMouseButton(.right, isPressed: false, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        emitMouseButton(.middle, isPressed: true, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        emitMouseButton(.middle, isPressed: false, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let ownsPointer = updatePointerState(with: event)
        guard remoteButtonLifecycle.shouldForwardMovement(ownsPointer: ownsPointer) else { return }
        emitMouseMove(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let ownsPointer = updatePointerState(with: event)
        guard remoteButtonLifecycle.shouldForwardMovement(ownsPointer: ownsPointer) else { return }
        emitMouseMove(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        let ownsPointer = updatePointerState(with: event)
        guard remoteButtonLifecycle.shouldForwardMovement(ownsPointer: ownsPointer) else { return }
        emitMouseMove(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard updatePointerState(with: event) else { return }
        onScrollWheel?(event.scrollingDeltaX, event.scrollingDeltaY)
    }

    private func emitMouseButton(_ button: MouseButton, isPressed: Bool, event: NSEvent) {
        let ownsPointer = updatePointerState(with: event, forceCursorRefresh: true)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)

        if isPressed {
            guard ownsPointer else { return }
            window?.makeFirstResponder(self)
            inputManager?.refreshLocalInputFocus()
            remoteButtonLifecycle.press(button)
            lastOwnedFlippedPoint = flipped
            onMouseButton?(button, true, flipped)
            return
        }

        let hadRemoteButtonDown = remoteButtonLifecycle.release(button)
        guard ownsPointer || hadRemoteButtonDown else { return }
        onMouseButton?(button, false, ownsPointer ? flipped : lastOwnedFlippedPoint ?? flipped)
    }

    private func emitMouseMove(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        let delta = CGSize(width: event.deltaX, height: -event.deltaY)
        lastOwnedFlippedPoint = flipped
        onMouseMove?(flipped, delta)
    }

    @discardableResult
    private func updatePointerState(with event: NSEvent, forceCursorRefresh: Bool = false) -> Bool {
        let localPoint = convert(event.locationInWindow, from: nil)
        pointerPresence.update(
            isOwnedByRemoteSurface: RemotePointerOwnershipPolicy.ownsCursor(
                localPoint: localPoint,
                visibleRect: visibleRect,
                isTopmostInteractiveSurface: isTopmostInteractiveSurface(at: event.locationInWindow),
                topChromeReleaseBandHeight: topChromeReleaseBandHeight
            )
        )
        updateCursorVisibility(forceCursorRefresh: forceCursorRefresh)
        return pointerPresence.isInsideRemoteSurface
    }

    private func releasePressedRemoteButtonsAtLastOwnedPoint() {
        let buttons = remoteButtonLifecycle.takeAllPressedButtons()
        guard !buttons.isEmpty else { return }
        guard let point = lastOwnedFlippedPoint else {
            return
        }

        for button in buttons.sorted(by: { $0.rawValue < $1.rawValue }) {
            onMouseButton?(button, false, point)
        }
    }

    private func refreshPointerState(forceCursorRefresh: Bool = false) {
        pointerPresence.update(isOwnedByRemoteSurface: pointerIsActuallyInside())
        updateCursorVisibility(forceCursorRefresh: forceCursorRefresh)
    }

    private func pointerIsActuallyInside() -> Bool {
        guard let window, !isHidden, alphaValue > 0 else { return false }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        return RemotePointerOwnershipPolicy.ownsCursor(
            localPoint: localPoint,
            visibleRect: visibleRect,
            isTopmostInteractiveSurface: isTopmostInteractiveSurface(at: windowPoint),
            topChromeReleaseBandHeight: topChromeReleaseBandHeight
        )
    }

    private var topChromeReleaseBandHeight: CGFloat {
        RemotePointerOwnershipPolicy.topChromeReleaseBandHeight(
            isFullscreen: window?.styleMask.contains(.fullScreen) == true
        )
    }

    private func isTopmostInteractiveSurface(at windowPoint: NSPoint) -> Bool {
        guard let contentView = window?.contentView else { return false }
        let contentPoint = contentView.convert(windowPoint, from: nil)
        guard let hitView = contentView.hitTest(contentPoint) else { return false }
        return hitView === self || hitView.isDescendant(of: self)
    }

    private func updateCursorVisibility(forceCursorRefresh: Bool = false) {
        let shouldHide = hidesLocalCursor
            && pointerPresence.isInsideRemoteSurface
            && window?.isKeyWindow == true
            && NSApp.isActive

        if shouldHide {
            let didAcquireHideLease = acquireCursorHideLease()
            if CursorRefreshPolicy.shouldApplyInvisibleCursor(
                isAlreadyApplied: invisibleCursorIsApplied,
                forceRefresh: forceCursorRefresh,
                didAcquireHideLease: didAcquireHideLease
            ) {
                Self.invisibleCursor.set()
                invisibleCursorIsApplied = true
            }
        } else {
            forceShowCursor()
        }
    }

    @discardableResult
    private func acquireCursorHideLease() -> Bool {
        guard !ownsCursorHideLease else { return false }
        NSCursor.hide()
        ownsCursorHideLease = true
        return true
    }

    private func releaseCursorHideLease() {
        guard ownsCursorHideLease else { return }
        NSCursor.unhide()
        ownsCursorHideLease = false
    }

    private func forceShowCursor() {
        guard CursorRefreshPolicy.shouldApplyArrowCursor(
            isInvisibleCursorApplied: invisibleCursorIsApplied,
            ownsHideLease: ownsCursorHideLease
        ) else {
            return
        }
        releaseCursorHideLease()
        invisibleCursorIsApplied = false
        NSCursor.arrow.set()
    }

    private func installNotificationObservers() {
        guard let window else { return }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.releasePressedRemoteButtonsAtLastOwnedPoint()
                self?.forceShowCursor()
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.refreshPointerState(forceCursorRefresh: true)
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                self?.releasePressedRemoteButtonsAtLastOwnedPoint()
                self?.forceShowCursor()
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                self?.refreshPointerState(forceCursorRefresh: true)
            },
        ]
    }

    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        notificationObservers.forEach(center.removeObserver)
        notificationObservers.removeAll()
    }
}
#endif
