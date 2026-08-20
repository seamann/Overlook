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
    let hidesLocalCursor: Bool
    let onMouseMove: (CGPoint, CGSize) -> Void
    let onMouseButton: (MouseButton, Bool, CGPoint) -> Void
    let onScrollWheel: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingContainerView {
        let container = TrackingContainerView()
        container.hidesLocalCursor = hidesLocalCursor
        container.onMouseMove = onMouseMove
        container.onMouseButton = onMouseButton
        container.onScrollWheel = onScrollWheel
        container.embedVideoViewIfNeeded(videoView)
        return container
    }

    func updateNSView(_ nsView: TrackingContainerView, context: Context) {
        nsView.hidesLocalCursor = hidesLocalCursor
        nsView.onMouseMove = onMouseMove
        nsView.onMouseButton = onMouseButton
        nsView.onScrollWheel = onScrollWheel
        nsView.embedVideoViewIfNeeded(videoView)
    }
}

final class TrackingContainerView: NSView {
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
    var onMouseMove: ((CGPoint, CGSize) -> Void)?
    var onMouseButton: ((MouseButton, Bool, CGPoint) -> Void)?
    var onScrollWheel: ((CGFloat, CGFloat) -> Void)?

    var hidesLocalCursor = false {
        didSet {
            guard oldValue != hidesLocalCursor else { return }
            window?.invalidateCursorRects(for: self)
            refreshPointerState()
        }
    }

    private var trackingAreaRef: NSTrackingArea?
    private var notificationObservers: [NSObjectProtocol] = []
    private var pointerPresence = RemotePointerPresenceState()
    private var ownsCursorHideLease = false

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
        removeNotificationObservers()
        forceShowCursor()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        installNotificationObservers()
        window?.invalidateCursorRects(for: self)
        refreshPointerState()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: hidesLocalCursor ? Self.invisibleCursor : .arrow)
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
        updatePointerState(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointerState(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerPresence.exit()
        updateCursorVisibility()
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointerState(with: event)
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
        updatePointerState(with: event)
        emitMouseMove(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        updatePointerState(with: event)
        emitMouseMove(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        updatePointerState(with: event)
        emitMouseMove(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        updatePointerState(with: event)
        onScrollWheel?(event.scrollingDeltaX, event.scrollingDeltaY)
    }

    private func emitMouseButton(_ button: MouseButton, isPressed: Bool, event: NSEvent) {
        updatePointerState(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(button, isPressed, flipped)
    }

    private func emitMouseMove(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        let delta = CGSize(width: event.deltaX, height: -event.deltaY)
        onMouseMove?(flipped, delta)
    }

    private func updatePointerState(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        pointerPresence.update(
            isOwnedByRemoteSurface: RemotePointerOwnershipPolicy.ownsCursor(
                localPoint: localPoint,
                visibleRect: visibleRect,
                isTopmostInteractiveSurface: isTopmostInteractiveSurface(at: event.locationInWindow)
            )
        )
        updateCursorVisibility()
    }

    private func refreshPointerState() {
        pointerPresence.update(isOwnedByRemoteSurface: pointerIsActuallyInside())
        updateCursorVisibility()
    }

    private func pointerIsActuallyInside() -> Bool {
        guard let window, !isHidden, alphaValue > 0 else { return false }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        return RemotePointerOwnershipPolicy.ownsCursor(
            localPoint: localPoint,
            visibleRect: visibleRect,
            isTopmostInteractiveSurface: isTopmostInteractiveSurface(at: windowPoint)
        )
    }

    private func isTopmostInteractiveSurface(at windowPoint: NSPoint) -> Bool {
        guard let contentView = window?.contentView else { return false }
        let contentPoint = contentView.convert(windowPoint, from: nil)
        guard let hitView = contentView.hitTest(contentPoint) else { return false }
        return hitView === self || hitView.isDescendant(of: self)
    }

    private func updateCursorVisibility() {
        let shouldHide = hidesLocalCursor
            && pointerPresence.isInsideRemoteSurface
            && window?.isKeyWindow == true
            && NSApp.isActive

        if shouldHide {
            acquireCursorHideLease()
            Self.invisibleCursor.set()
        } else {
            forceShowCursor()
        }
    }

    private func acquireCursorHideLease() {
        guard !ownsCursorHideLease else { return }
        NSCursor.hide()
        ownsCursorHideLease = true
    }

    private func releaseCursorHideLease() {
        guard ownsCursorHideLease else { return }
        NSCursor.unhide()
        ownsCursorHideLease = false
    }

    private func forceShowCursor() {
        releaseCursorHideLease()
        NSCursor.arrow.set()
    }

    private func installNotificationObservers() {
        guard let window else { return }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.forceShowCursor()
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.refreshPointerState()
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                self?.forceShowCursor()
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                self?.refreshPointerState()
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
