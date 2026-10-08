import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var ocrManager: OCRManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    @EnvironmentObject var controlModeStore: ControlModeStore
    @EnvironmentObject var sessionCoordinator: SessionConnectionCoordinator
    @EnvironmentObject var localUIRequests: LocalUIRequests
    
    @State private var selectedDevice: KVMDevice?
    @State private var isOCRModeEnabled = false
    @State private var isShowingOCRResult = false
    @State private var showingSettings = false
    @State private var selectedText = ""
    @State private var transferStatus: String?

    @State private var showingManualConnect = false
    @State private var manualHostPort = ""
    @State private var manualPort = "443"

    @State private var manualPassword = ""

    @State private var showingPasswordPrompt = false
    @State private var pendingPasswordDevice: KVMDevice?
    @State private var pendingPasswordAttemptID: UInt64?
    @State private var pendingManualEndpoint: (host: String, port: Int)?
    @State private var pendingPassword = ""
    @State private var connectionErrorMessage: String?
    @State private var errorKind: LocalActionErrorKind = .connection
    @State private var isChangingControlMode = false
    @State private var isRecoveringInput = false
    @State private var inputRecoveryErrorMessage: String?
    @State private var cleanupReviewConfirmation: CleanupReviewConfirmation?

    private struct CleanupReviewConfirmation {
        let review: SessionConnectionCoordinator.PendingCleanupReview
        let modeSnapshot: ControlModeSnapshot
    }

    @State private var showingConnections = false
    @State private var didAutoOpenConnections = false

    @State private var inputCaptureOwner = UUID()

    @State private var windowRef: NSWindow?

    @State private var isFullscreen: Bool = false
    @State private var showFullscreenControls: Bool = false
    @State private var isHoveringFullscreenTopStrip: Bool = false
    @State private var fullscreenHoverTask: Task<Void, Never>?
    @State private var activeWindowMode: OverlookControlMode = .manual
    @State private var didApplyControlMode = false

    @AppStorage("overlook.appAppearance") private var appAppearance: String = "system"

    private var isConnected: Bool { kvmDeviceManager.connectedDevice != nil }
    private var isEstablishingConnection: Bool { sessionCoordinator.isConnecting }

    private var controlMode: OverlookControlMode {
        controlModeStore.mode
    }

    private var settingsAccessReason: String? {
        LocalSettingsAccessPolicy.denialReason(mode: controlMode, isConnected: isConnected)
    }

    private var recoveryPresentation: LocalRecoveryPresentation {
        LocalRecoveryPresentation(
            mode: controlMode,
            isVideoConnecting: webRTCManager.isConnecting,
            isStreamStalled: webRTCManager.isStreamStalled,
            hasEverConnectedToStream: webRTCManager.hasEverConnectedToStream,
            isVideoConnected: webRTCManager.isConnected,
            hasDevice: kvmDeviceManager.connectedDevice != nil,
            isSessionConnecting: isEstablishingConnection,
            isPanelPresented: showingSettings || showingConnections || showingManualConnect
                || showingPasswordPrompt || isShowingOCRResult || connectionErrorMessage != nil
                || cleanupReviewConfirmation != nil
        )
    }

    private var inputRecoveryPresentation: InputRecoveryPresentation {
        InputRecoveryPresentation(
            mode: controlMode, isConnected: isConnected,
            isBusy: isEstablishingConnection || webRTCManager.isConnecting || isRecoveringInput,
            hasLiveVideo: webRTCManager.isConnected && webRTCManager.videoSize != nil
                && !webRTCManager.isStreamStalled,
            hasRecoveryTransport: inputManager.hasInputRecoveryTransport,
            hasPendingCleanupReview: sessionCoordinator.pendingCleanupReview != nil,
            isLocalCaptureAllowed: inputManager.isLocalInputCaptureAllowed
        )
    }

    private var videoRecoveryOverlay: some View {
        VStack(spacing: 10) {
            Text(webRTCManager.isConnecting ? "Connecting…" : "Connection Lost")
                .font(.headline)
            if let reason = webRTCManager.lastDisconnectReason, !reason.isEmpty {
                Text(reason).font(.subheadline).foregroundColor(.secondary)
            }
            if let age = webRTCManager.lastVideoFrameAgeSeconds, !webRTCManager.isConnecting {
                Text("Last video frame: \(age)s ago").font(.caption).foregroundColor(.secondary)
            }
            Button("Reconnect") {
                guard recoveryPresentation.canReconnect,
                      let device = kvmDeviceManager.connectedDevice else { return }
                connectToDevice(device)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!recoveryPresentation.canReconnect)
            .accessibilityIdentifier("local-video-reconnect")
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .allowsHitTesting(!showingSettings && !showingConnections)
    }

    private var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }

    private var shouldHideLocalCursor: Bool {
        CursorVisibilityPolicy.shouldHideLocalCursor(
            in: CursorVisibilityContext(
                mode: controlMode,
                isConnected: isConnected,
                hasVideo: webRTCManager.videoSize != nil
                    && webRTCManager.isConnected
                    && !webRTCManager.isStreamStalled,
                isMouseCaptureEnabled: inputManager.isMouseCaptureEnabled,
                showingSettings: showingSettings,
                showingConnections: showingConnections,
                showingManualConnect: showingManualConnect,
                showingPasswordPrompt: showingPasswordPrompt,
                showingOCRResult: isShowingOCRResult,
                isOCRModeEnabled: isOCRModeEnabled,
                hasConnectionError: connectionErrorMessage != nil
            )
        )
    }

    private var windowTitle: String {
        guard controlMode == .codexHeadless else {
            return ""
        }

        let device = kvmDeviceManager.connectedDevice
        let deviceLabel: String
        if let device {
            deviceLabel = device.type == .glinetComet ? "GLKVM" : device.type.displayName
        } else {
            deviceLabel = "Overlook"
        }

        let connectionState = device == nil || !isConnected ? "Disconnected" : "Connected"
        let resolution = webRTCManager.videoSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "—"
        let kbps = webRTCManager.inboundVideoKbps.map { "\($0) kbps" } ?? "— kbps"
        let fps = webRTCManager.inboundFps.map { "\(Int($0.rounded())) fps dynamic" } ?? "— fps dynamic"

        return "Overlook - \(deviceLabel) / \(connectionState) / \(resolution) / \(kbps) / \(fps)"
    }

    private var canToggleMouseJiggler: Bool {
        MouseJigglerPolicy.canToggle(
            mode: controlMode,
            isConnected: isConnected,
            isAvailable: kvmDeviceManager.mouseJigglerEnabled != nil,
            isUpdating: kvmDeviceManager.isMouseJigglerUpdating,
            isTransitioning: isChangingControlMode
        ) && !showingSettings && !showingConnections
    }

    private var mouseJigglerHelp: String {
        if kvmDeviceManager.isMouseJigglerUpdating {
            return "Updating mouse jiggler"
        }
        guard let isEnabled = kvmDeviceManager.mouseJigglerEnabled else {
            return "Mouse jiggler state unavailable"
        }
        return isEnabled
            ? "Disable tiny mouse movements"
            : "Keep the remote display awake with a tiny movement after 60 seconds without input"
    }

    private var mouseJigglerButton: some View {
        Button(action: toggleMouseJiggler) {
            Group {
                if kvmDeviceManager.isMouseJigglerUpdating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.left.and.right")
                        .foregroundStyle(kvmDeviceManager.mouseJigglerEnabled == true ? Color.green : Color.primary)
                }
            }
            .frame(width: 16, height: 16)
        }
        .disabled(!canToggleMouseJiggler)
        .help(mouseJigglerHelp)
        .accessibilityLabel("Mouse Jiggler")
        .accessibilityValue(
            kvmDeviceManager.mouseJigglerEnabled.map { $0 ? "On" : "Off" } ?? "Unavailable"
        )
    }

    private var inputRecoveryBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Eingabe angehalten: Remote-Zustand prüfen", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(inputRecoveryPresentation.message)
                .font(.caption)
            if let message = inputRecoveryErrorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let title = inputRecoveryPresentation.buttonTitle {
                Button(title, action: performInputRecoveryAction)
                    .disabled(showingPasswordPrompt || connectionErrorMessage != nil)
                    .accessibilityIdentifier("local-input-recovery")
            }
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
        .frame(maxWidth: .infinity, alignment: .center)
        .alert(
            "Alte KVM-Sitzung lokal abschließen?",
            isPresented: Binding(
                get: { cleanupReviewConfirmation != nil },
                set: { if !$0 { cleanupReviewConfirmation = nil } }
            ),
            presenting: cleanupReviewConfirmation
        ) { confirmation in
            Button("Geprüft, Sitzung abschließen") {
                finishReviewedPreviousSession(confirmation)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { confirmation in
            Text("Prüfe den alten Zielrechner \(confirmation.review.endpoint) direkt. Läuft dort keine unerwartete Eingabe mehr, kannst du die alte Sitzung lokal abschließen. Die Eingabe bleibt bis zur Prüfung und Freigabe der neuen Verbindung gesperrt. Der alte HID-Disconnect bleibt unbestätigt.")
        }
    }

    private func performInputRecoveryAction() {
        inputRecoveryErrorMessage = nil
        switch inputRecoveryPresentation.action {
        case .reconnect:
            showingSettings = false
            showingConnections = true
        case .reviewPreviousSession:
            guard let review = sessionCoordinator.pendingCleanupReview else { return }
            cleanupReviewConfirmation = CleanupReviewConfirmation(
                review: review, modeSnapshot: controlModeStore.snapshot
            )
        case .releaseInput:
            releaseReviewedInput()
        case .switchToManual, .waitForConnection:
            break
        }
    }

    private func releaseReviewedInput() {
        guard inputRecoveryPresentation.action == .releaseInput else { return }
        let expectedMode = controlModeStore.snapshot
        isRecoveringInput = true
        Task { @MainActor in
            defer { isRecoveringInput = false }
            do {
                try await inputManager.recoverInputAfterManualReview {
                    controlModeStore.snapshot == expectedMode && expectedMode.mode == .manual
                }
                inputRecoveryErrorMessage = nil
            } catch {
                inputRecoveryErrorMessage = recoveryMessage(for: error)
            }
        }
    }

    private func finishReviewedPreviousSession(_ confirmation: CleanupReviewConfirmation) {
        isRecoveringInput = true
        Task { @MainActor in
            defer { isRecoveringInput = false }
            do {
                try await sessionCoordinator.acknowledgeUnconfirmedCleanup(reviewID: confirmation.review.id) {
                    controlModeStore.snapshot == confirmation.modeSnapshot
                        && confirmation.modeSnapshot.mode == .manual
                }
                inputRecoveryErrorMessage = nil
                showingSettings = false
                showingConnections = true
            } catch {
                inputRecoveryErrorMessage = recoveryMessage(for: error)
            }
        }
    }

    private func recoveryMessage(for error: Error) -> String {
        if error is CancellationError { return InputRecoveryFailure.cancelled.message }
        if let error = error as? RemoteActionError {
            switch error {
            case .inputUnavailable: return InputRecoveryFailure.transportUnavailable.message
            case .sessionChanged: return InputRecoveryFailure.sessionChanged.message
            case .unauthorized: return InputRecoveryFailure.unauthorized.message
            default: return InputRecoveryFailure.releaseFailed.message
            }
        }
        if let error = error as? SessionConnectionError, case .manualReviewExpired = error {
            return InputRecoveryFailure.sessionChanged.message
        }
        return InputRecoveryFailure.releaseFailed.message
    }

    private func applyAppAppearance() {
        switch appAppearance {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    private func setFullscreenTopStripHover(_ isHovering: Bool) {
        guard isFullscreen, !showingSettings, !showingConnections else {
            guard isHoveringFullscreenTopStrip || showFullscreenControls || fullscreenHoverTask != nil else {
                return
            }
            fullscreenHoverTask?.cancel()
            fullscreenHoverTask = nil
            isHoveringFullscreenTopStrip = false
            if showFullscreenControls {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showFullscreenControls = false
                }
            }
            return
        }

        guard isHoveringFullscreenTopStrip != isHovering else { return }
        isHoveringFullscreenTopStrip = isHovering
        fullscreenHoverTask?.cancel()
        fullscreenHoverTask = nil

        if isHovering {
            fullscreenHoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if isFullscreen && isHoveringFullscreenTopStrip && !showingSettings && !showingConnections {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showFullscreenControls = true
                    }
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                showFullscreenControls = false
            }
        }
    }
    
    private var videoContent: some View {
        ZStack(alignment: .trailing) {
            if isFullscreen {
                VideoSurfaceView(
                    isOCRModeEnabled: $isOCRModeEnabled,
                    selectedText: $selectedText,
                    isShowingOCRResult: $isShowingOCRResult,
                    hidesLocalCursor: shouldHideLocalCursor
                )
                .ignoresSafeArea()
                .allowsHitTesting(recoveryPresentation.allowsRemoteInput)
            } else {
                VideoSurfaceView(
                    isOCRModeEnabled: $isOCRModeEnabled,
                    selectedText: $selectedText,
                    isShowingOCRResult: $isShowingOCRResult,
                    hidesLocalCursor: shouldHideLocalCursor
                )
                .allowsHitTesting(recoveryPresentation.allowsRemoteInput)
            }

            if recoveryPresentation.showsRecovery {
                videoRecoveryOverlay
            }

            if let transferStatus {
                Text(transferStatus)
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding()
                    .allowsHitTesting(false)
            }

            if isFullscreen && !showingSettings && !showingConnections {
                VStack(spacing: 0) {
                    if showFullscreenControls {
                        HStack(spacing: 10) {
                            Button(action: { showingConnections.toggle() }) {
                                Image(systemName: "personalhotspot")
                            }
                            .help("Connections")

                            Button(action: { fitWindowToGuest() }) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .disabled(webRTCManager.videoSize == nil)
                            .help("Fit window to guest")

                            Button(action: { toggleOCR() }) {
                                Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
                            }
                            .disabled(!isConnected)
                            .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")

                            mouseJigglerButton

                            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                                Image(systemName: "gearshape")
                            }
                            .disabled(settingsAccessReason != nil)
                            .help("Settings")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 6)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(showFullscreenControls)
            }

            if showingSettings || showingConnections {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSettings = false
                            showingConnections = false
                        }
                    }
            }

            WebUISettingsPanel(isPresented: $showingSettings)
                .frame(width: 360)
                .offset(x: showingSettings ? 0 : 360)
                .animation(Animation.easeInOut(duration: 0.2), value: showingSettings)
                .allowsHitTesting(showingSettings)

            VStack(spacing: 0) {
                ConnectionsPopoverView(
                    selectedDevice: $selectedDevice,
                    isConnected: isConnected,
                    isConnecting: isEstablishingConnection,
                    isScanning: kvmDeviceManager.isScanning,
                    devices: kvmDeviceManager.availableDevices,
                    connectedDeviceName: kvmDeviceManager.connectedDevice?.name,
                    latency: webRTCManager.latency,
                    videoSize: webRTCManager.videoSize,
                    inboundVideoKbps: webRTCManager.inboundVideoKbps,
                    inboundFps: webRTCManager.inboundFps,
                    inboundVideoPlayoutDelayMs: webRTCManager.inboundVideoPlayoutDelayMs,
                    inboundVideoJitterMs: webRTCManager.inboundVideoJitterMs,
                    inboundVideoDecodeMs: webRTCManager.inboundVideoDecodeMs,
                    inboundVideoPacketsLost: webRTCManager.inboundVideoPacketsLost,
                    iceCurrentRoundTripTimeMs: webRTCManager.iceCurrentRoundTripTimeMs,
                    inboundAudioKbps: webRTCManager.inboundAudioKbps,
                    inboundAudioPlayoutDelayMs: webRTCManager.inboundAudioPlayoutDelayMs,
                    inboundAudioJitterMs: webRTCManager.inboundAudioJitterMs,
                    inboundAudioPacketsLost: webRTCManager.inboundAudioPacketsLost,
                    audioIceCurrentRoundTripTimeMs: webRTCManager.audioIceCurrentRoundTripTimeMs,
                    onScan: {
                        kvmDeviceManager.scanForDevices()
                    },
                    onManualConnect: {
                        showingManualConnect = true
                    },
                    onToggleConnection: {
                        toggleConnection()
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingConnections = false
                        }
                    },
                    onForgetSelectedDevice: {
                        guard let device = selectedDevice else { return }
                        guard device.id.hasPrefix("saved-") else { return }
                        if sessionCoordinator.isConnecting || kvmDeviceManager.connectedDevice.map({
                            $0.host == device.host && $0.port == device.port
                        }) == true {
                            sessionCoordinator.disconnect()
                        }
                        kvmDeviceManager.forgetDevice(device)
                        selectedDevice = nil
                    }
                )
                .frame(width: 360)
                .background(.ultraThinMaterial)
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .offset(x: showingConnections ? 0 : 360)
            .animation(.easeInOut(duration: 0.2), value: showingConnections)
            .allowsHitTesting(showingConnections)

        }
    }

    private var windowContent: some View {
        videoContent
        .safeAreaInset(edge: .top, spacing: 0) {
            if inputManager.inputBlocked || sessionCoordinator.pendingCleanupReview != nil {
                inputRecoveryBanner
            }
        }
        .background(WindowAspectRatioSetter(videoSize: webRTCManager.videoSize))
        .background(WindowTitleSetter(title: windowTitle))
        .background(WindowReferenceSetter(window: $windowRef))
        .preferredColorScheme(preferredColorScheme)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                setFullscreenTopStripHover(
                    FullscreenHoverPolicy.isInsideTopStrip(
                        locationY: location.y,
                        isFullscreen: isFullscreen,
                        controlsVisible: showFullscreenControls,
                        isOverlayPresented: showingSettings || showingConnections
                    )
                )
            case .ended:
                setFullscreenTopStripHover(false)
            }
        }
        .onAppear {
            applyAppAppearance()
            updateInputCaptureForUIOverlays()
            applyControlMode()

            if !didAutoOpenConnections, !isConnected {
                didAutoOpenConnections = true
                showingConnections = true
            }
        }
        .onChange(of: showingSettings) { _, _ in
            updateInputCaptureForUIOverlays()
            setFullscreenTopStripHover(false)
        }
        .onChange(of: showingConnections) { _, _ in
            updateInputCaptureForUIOverlays()
            setFullscreenTopStripHover(false)
        }
        .onChange(of: showingManualConnect) { _, _ in updateInputCaptureForUIOverlays() }
        .onChange(of: showingPasswordPrompt) { _, _ in updateInputCaptureForUIOverlays() }
        .onChange(of: isShowingOCRResult) { _, _ in updateInputCaptureForUIOverlays() }
        .onChange(of: isOCRModeEnabled) { _, _ in updateInputCaptureForUIOverlays() }
        .onChange(of: connectionErrorMessage) { _, _ in updateInputCaptureForUIOverlays() }
        .onChange(of: cleanupReviewConfirmation != nil) { _, _ in updateInputCaptureForUIOverlays() }
        .onChange(of: inputManager.inputBlocked) { _, blocked in
            if !blocked { inputRecoveryErrorMessage = nil }
        }
        .onChange(of: kvmDeviceManager.mouseJigglerErrorMessage) { _, message in
            if let message { showLocalError(message, kind: .mouseJiggler) }
        }
        .onChange(of: kvmDeviceManager.credentialStorageWarningGeneration, initial: true) { _, _ in
            if let message = kvmDeviceManager.credentialStorageWarning { showLocalError(message, kind: .credentials) }
        }
        .onDisappear {
            inputManager.setLocalUIBlocked(false, owner: inputCaptureOwner)
        }
    }

    private var sessionContent: some View {
        windowContent
        .onChange(of: sessionCoordinator.isConnecting) { _, connecting in
            if connecting {
                showingPasswordPrompt = false
                pendingPasswordDevice = nil
                pendingManualEndpoint = nil
                pendingPasswordAttemptID = nil
                pendingPassword = ""
            }
        }
        .onChange(of: controlModeStore.mode) { _, _ in
            applyControlMode()
        }
        .onChange(of: windowRef) { _, newValue in
            isFullscreen = newValue?.styleMask.contains(.fullScreen) ?? false
            showFullscreenControls = false
            setFullscreenTopStripHover(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            guard windowRef === window else { return }
            isFullscreen = true
            showFullscreenControls = false
            setFullscreenTopStripHover(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            guard windowRef === window else { return }
            isFullscreen = false
            showFullscreenControls = false
            setFullscreenTopStripHover(false)
        }
        .onChange(of: kvmDeviceManager.connectedDevice) { _, device in
            showingSettings = false
            if let device { selectedDevice = device }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlookToggleCopyMode)) { _ in
            Task { @MainActor in
                isOCRModeEnabled.toggle()
            }
        }
        .onChange(of: localUIRequests.settingsRequested, initial: true) { _, requested in
            guard requested, localUIRequests.consumeSettingsRequest() else { return }
            if let reason = settingsAccessReason {
                showingSettings = false
                showLocalError(reason, kind: .settings)
                return
            }
            showingConnections = false
            showingSettings = true
        }
        .onChange(of: appAppearance) { _, _ in
            applyAppAppearance()
        }
    }

    var body: some View {
        sessionContent
        .sheet(isPresented: $isShowingOCRResult) {
            OCRResultView(selectedText: $selectedText)
        }
        .sheet(isPresented: $showingManualConnect) {
            ManualConnectSheet(
                isPresented: $showingManualConnect,
                hostPort: $manualHostPort,
                port: $manualPort,
                password: $manualPassword,
                onConnect: { password in
                    manualConnect(password: password)
                }
            )
        }
        .sheet(isPresented: $showingPasswordPrompt) {
            PasswordPromptSheet(
                isPresented: $showingPasswordPrompt,
                password: $pendingPassword,
                onCancel: {
                    pendingPasswordDevice = nil
                    pendingManualEndpoint = nil
                    pendingPasswordAttemptID = nil
                    pendingPassword = ""
                },
                onConnect: { password in
                    if let id = pendingPasswordAttemptID, sessionCoordinator.isCurrent(id) {
                        if let device = pendingPasswordDevice {
                            connectToDevice(device, password: password)
                        } else if let endpoint = pendingManualEndpoint {
                            connectManually(host: endpoint.host, port: endpoint.port, password: password)
                        }
                    }
                    pendingPasswordDevice = nil
                    pendingManualEndpoint = nil
                    pendingPasswordAttemptID = nil
                    pendingPassword = ""
                }
            )
        }
        .alert(
            errorKind.title,
            isPresented: Binding(
                get: { connectionErrorMessage != nil },
                set: { if !$0 { connectionErrorMessage = nil } }
            )
        ) {
            Button("OK") {
                connectionErrorMessage = nil
            }
        } message: {
            Text(connectionErrorMessage ?? "")
        }
        .toolbar {
            if isFullscreen == false {
                ToolbarItemGroup(placement: .automatic) {
                    Picker(
                        "Control mode",
                        selection: Binding(
                            get: { controlModeStore.mode },
                            set: { requestedMode in
                                RunLoop.main.perform(inModes: [.default]) {
                                    MainActor.assumeIsolated {
                                        requestControlMode(requestedMode)
                                    }
                                }
                            }
                        )
                    ) {
                        ForEach(OverlookControlMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isChangingControlMode || kvmDeviceManager.isMouseJigglerUpdating)
                    .help("Choose who controls the remote computer")

                    Button(action: { showingConnections.toggle() }) {
                        Image(systemName: "personalhotspot")
                    }
                    .help("Connections")

                    Button(action: { fitWindowToGuest() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(webRTCManager.videoSize == nil)
                    .help("Fit window to guest")

                    Button(action: { toggleOCR() }) {
                        Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
                    }
                    .disabled(!isConnected || controlMode != .manual)
                    .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")

                    Button(action: { pasteMacClipboardToRemote() }) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .disabled(!isConnected || controlMode != .manual)
                    .disabled(!inputManager.isKeyboardCaptureEnabled)
                    .help("Paste Mac clipboard into the remote computer")

                    mouseJigglerButton

                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                        Image(systemName: "gearshape")
                    }
                    .disabled(settingsAccessReason != nil)
                    .help("Settings")

                    Button(role: .destructive, action: { NSApp.terminate(nil) }) {
                        Image(systemName: "power")
                    }
                    .help("Quit Overlook")
                    .accessibilityLabel("Quit Overlook")
                }
            }
        }
    }

    private func connectToDevice(_ device: KVMDevice, password: String? = nil) {
        let attempt = sessionCoordinator.startConnection(to: device, password: password)
        observeConnection(attempt, passwordDevice: device)
    }

    private func observeConnection(
        _ attempt: SessionConnectionCoordinator.Attempt,
        passwordDevice: KVMDevice?,
        manualEndpoint: (host: String, port: Int)? = nil
    ) {
        Task { @MainActor in
            do {
                let device = try await attempt.task.value
                guard sessionCoordinator.isCurrent(attempt.id) else { return }
                selectedDevice = device
                showingConnections = false
                if let warning = kvmDeviceManager.credentialStorageWarning {
                    showLocalError(warning, kind: .credentials)
                } else {
                    connectionErrorMessage = nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard sessionCoordinator.isCurrent(attempt.id) else { return }
                if let error = error as? KVMError, error == .authenticationFailed {
                    pendingPasswordDevice = passwordDevice
                    pendingManualEndpoint = manualEndpoint
                    pendingPasswordAttemptID = attempt.id
                    showingPasswordPrompt = true
                } else {
                    showLocalError(describeConnectionError(error), kind: .connection)
                }
            }
        }
    }

    private func manualConnect(password: String) {
        do {
            let endpoint = try ManualConnectionEndpoint.parse(hostPort: manualHostPort, port: manualPort)
            connectManually(host: endpoint.host, port: endpoint.port, password: password)
        } catch {
            showLocalError(error.localizedDescription, kind: .endpoint)
        }
    }

    private func showLocalError(_ message: String, kind: LocalActionErrorKind) {
        errorKind = kind
        connectionErrorMessage = message
    }

    private func connectManually(host: String, port: Int, password: String) {
        let normalizedPassword = password
        let attempt = sessionCoordinator.startConnection(
            deviceFactory: {
                try await kvmDeviceManager.makeManualDeviceUsingStoredToken(
                    host: host, port: port, type: .glinetComet
                )
            },
            password: normalizedPassword.isEmpty ? nil : normalizedPassword
        )
        observeConnection(attempt, passwordDevice: nil, manualEndpoint: (host, port))
    }

    private func describeConnectionError(_ error: Error) -> String {
        error.localizedDescription
    }

    private func toggleConnection() {
        if isConnected || isEstablishingConnection {
            sessionCoordinator.disconnect()
            showingConnections = true
        } else if let device = selectedDevice {
            connectToDevice(device)
        }
    }

    @MainActor
    private func toggleOCR() {
        isOCRModeEnabled.toggle()
    }

    @MainActor
    private func toggleMouseJiggler() {
        guard canToggleMouseJiggler, let current = kvmDeviceManager.mouseJigglerEnabled else { return }
        Task { @MainActor in
            do {
                try await kvmDeviceManager.setMouseJigglerEnabled(!current)
            } catch is CancellationError {
                return
            } catch {
                showLocalError(error.localizedDescription, kind: .mouseJiggler)
            }
        }
    }

    @MainActor
    private func requestControlMode(_ requestedMode: OverlookControlMode) {
        guard requestedMode != controlMode, !isChangingControlMode else { return }
        guard requestedMode == .codexHeadless else {
            controlModeStore.setMode(requestedMode)
            return
        }
        guard isConnected else {
            showLocalError("Connect to the KVM before enabling Headless mode.", kind: .controlMode)
            return
        }
        guard MouseJigglerPolicy.canEnterHeadless(
            supportsMouseJiggler: kvmDeviceManager.mouseJigglerSupported,
            enabledState: kvmDeviceManager.mouseJigglerEnabled
        ) else {
            showLocalError("Wait until the KVM mouse jiggler state is available before enabling Headless mode.", kind: .controlMode)
            return
        }

        isChangingControlMode = true
        showingSettings = false
        let expectedClient = kvmDeviceManager.glkvmClient
        let lockOwner = kvmDeviceManager.beginHeadlessConfigurationTransition()
        Task { @MainActor in
            defer {
                kvmDeviceManager.endHeadlessConfigurationTransition(lockOwner)
                isChangingControlMode = false
                if controlModeStore.mode == .manual {
                    controlModeStore.resumeManualCaptureIfNeeded()
                }
            }
            do {
                try await kvmDeviceManager.pauseMouseJigglerForHeadless()
                guard kvmDeviceManager.glkvmClient === expectedClient,
                      !sessionCoordinator.isConnecting else { return }
                isOCRModeEnabled = false
                controlModeStore.setMode(.codexHeadless)
            } catch is CancellationError {
                return
            } catch {
                showLocalError(error.localizedDescription, kind: .controlMode)
            }
        }
    }

    @MainActor
    private func applyControlMode() {
        let window = windowRef ?? NSApp.keyWindow
        if didApplyControlMode, let window {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: WindowFramePersistence.key(for: activeWindowMode))
        }
        activeWindowMode = controlMode
        didApplyControlMode = true
        if controlMode == .codexHeadless {
            isOCRModeEnabled = false
        }
        scheduleWindowFrameRestore(for: controlMode)
    }

    @MainActor
    private func scheduleWindowFrameRestore(for mode: OverlookControlMode) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                guard controlMode == mode else { return }
                restoreWindowFrame(for: mode, fallbackToObserverSize: mode == .codexHeadless)
            }
        }
    }

    @MainActor
    private func restoreWindowFrame(for mode: OverlookControlMode, fallbackToObserverSize: Bool) {
        guard let window = windowRef ?? NSApp.keyWindow else { return }
        let key = WindowFramePersistence.key(for: mode)
        if let value = UserDefaults.standard.string(forKey: key) {
            var frame = NSRectFromString(value)
            if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                frame.size.width = min(max(frame.width, 480), visible.width)
                frame.size.height = min(max(frame.height, 320), visible.height)
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            }
            window.setFrame(
                frame,
                display: true,
                animate: ControlModeWindowTransitionPolicy.animatesFrameChanges
            )
        } else if fallbackToObserverSize {
            resizeForObserverMode()
        }
    }

    @MainActor
    private func resizeForObserverMode() {
        guard let window = windowRef ?? NSApp.keyWindow else { return }
        let currentFrame = window.frame
        let contentWidth: CGFloat = 640
        let videoAspect = (webRTCManager.videoSize?.width ?? 16) / (webRTCManager.videoSize?.height ?? 9)
        let contentHeight = contentWidth / max(videoAspect, 0.1)
        let chromeWidth = currentFrame.width - window.contentLayoutRect.width
        let chromeHeight = currentFrame.height - window.contentLayoutRect.height
        var newFrame = currentFrame
        newFrame.size = NSSize(width: contentWidth + chromeWidth, height: contentHeight + chromeHeight)
        newFrame.origin.y += currentFrame.height - newFrame.height
        window.setFrame(
            newFrame,
            display: true,
            animate: ControlModeWindowTransitionPolicy.animatesFrameChanges
        )
    }

    @MainActor
    private func pasteMacClipboardToRemote() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            transferStatus = "The Mac clipboard contains no text."
            return
        }
        let authorization = inputManager.makeLocalKeyboardAuthorization()
        Task { @MainActor in
            do {
                try await inputManager.sendTextToRemote(value, authorization: authorization)
                transferStatus = "\(value.count) characters transferred"
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if transferStatus == "\(value.count) characters transferred" {
                        transferStatus = nil
                    }
                }
            } catch {
                transferStatus = error.localizedDescription
            }
        }
    }

    @MainActor
    private func fitWindowToGuest() {
        guard let videoSize = webRTCManager.videoSize,
              videoSize.width > 0,
              videoSize.height > 0 else { return }
        guard let window = windowRef ?? NSApp.keyWindow else { return }

        let currentFrame = window.frame
        let currentLayout = window.contentLayoutRect

        let deltaW = currentFrame.size.width - currentLayout.size.width
        let deltaH = currentFrame.size.height - currentLayout.size.height

        var desiredLayoutW = CGFloat(videoSize.width)
        var desiredLayoutH = CGFloat(videoSize.height)

        if let screen = window.screen ?? NSScreen.main {
            let maxLayoutW = max(100, screen.visibleFrame.size.width - deltaW)
            let maxLayoutH = max(100, screen.visibleFrame.size.height - deltaH)
            let scale = min(1.0, maxLayoutW / desiredLayoutW, maxLayoutH / desiredLayoutH)
            desiredLayoutW = floor(desiredLayoutW * scale)
            desiredLayoutH = floor(desiredLayoutH * scale)
        }

        var newFrame = currentFrame
        newFrame.size = NSSize(width: desiredLayoutW + deltaW, height: desiredLayoutH + deltaH)
        newFrame.origin.y += currentFrame.size.height - newFrame.size.height
        window.setFrame(newFrame, display: true, animate: true)
    }

    @MainActor
    private func updateInputCaptureForUIOverlays() {
        inputManager.setLocalUIBlocked(
            showingSettings || showingConnections || showingManualConnect
                || showingPasswordPrompt || isShowingOCRResult || isOCRModeEnabled
                || connectionErrorMessage != nil || cleanupReviewConfirmation != nil,
            owner: inputCaptureOwner
        )
    }
}

private struct WindowReferenceSetter: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> MainWindowAttachmentView {
        let view = MainWindowAttachmentView(frame: .zero)
        let binding = $window
        view.onWindowAttached = { attachedWindow in
            DispatchQueue.main.async {
                if binding.wrappedValue !== attachedWindow { binding.wrappedValue = attachedWindow }
            }
        }
        return view
    }

    func updateNSView(_ nsView: MainWindowAttachmentView, context: Context) {
        guard let w = nsView.window else { return }
        if window !== w {
            DispatchQueue.main.async {
                window = w
            }
        }
    }
}

private struct WindowAspectRatioSetter: NSViewRepresentable {
    let videoSize: CGSize?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MainWindowAttachmentView {
        let view = MainWindowAttachmentView(frame: .zero)
        let coordinator = context.coordinator
        view.onWindowAttached = { coordinator.attach(to: $0) }
        return view
    }

    func updateNSView(_ nsView: MainWindowAttachmentView, context: Context) {
        guard let window = nsView.window else { return }
        context.coordinator.attach(to: window)

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            if context.coordinator.lastAspect != nil {
                context.coordinator.lastAspect = nil
                context.coordinator.didInitialResizeForAspect = false
                context.coordinator.videoAspect = nil
            }
            return
        }

        let aspect = NSSize(width: videoSize.width, height: videoSize.height)
        if let last = context.coordinator.lastAspect {
            let dw = abs(last.width - aspect.width)
            let dh = abs(last.height - aspect.height)
            if dw < 1, dh < 1 {
                return
            }
        }

        context.coordinator.lastAspect = aspect
        context.coordinator.videoAspect = Double(aspect.width / aspect.height)

        if context.coordinator.didInitialResizeForAspect == false {
            context.coordinator.didInitialResizeForAspect = true

            let currentFrame = window.frame
            let currentLayout = window.contentLayoutRect.size
            let deltaH = currentFrame.size.height - currentLayout.height

            if currentLayout.width > 0 {
                let desiredLayoutHeight = currentLayout.width * (aspect.height / aspect.width)
                if desiredLayoutHeight.isFinite, desiredLayoutHeight > 0 {
                    var newFrame = currentFrame
                    newFrame.size.height = desiredLayoutHeight + deltaH
                    DispatchQueue.main.async {
                        window.setFrame(newFrame, display: true)
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject {
        var lastAspect: NSSize?
        var didInitialResizeForAspect: Bool = false

        weak var window: NSWindow?
        weak var forwardedDelegate: NSWindowDelegate?
        var videoAspect: Double?

        private var storedWindowedTitlebarAppearsTransparent: Bool?
        private var storedWindowedStyleMaskHadFullSizeContentView: Bool?
        private var storedWindowedTitleVisibility: NSWindow.TitleVisibility?
        private var storedWindowedToolbarIsVisible: Bool?

        @MainActor func attach(to window: NSWindow) {
            if self.window === window {
                return
            }

            if let previous = self.window, previous.delegate === self {
                previous.delegate = forwardedDelegate
            }

            self.window = window
            window.titlebarAppearsTransparent = false
            window.styleMask.remove(.fullSizeContentView)
            MainWindowLifecycle.register(window)
            forwardedDelegate = window.delegate
            window.delegate = self

            storedWindowedTitlebarAppearsTransparent = window.titlebarAppearsTransparent
            storedWindowedStyleMaskHadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
            storedWindowedTitleVisibility = window.titleVisibility
            storedWindowedToolbarIsVisible = window.toolbar?.isVisible
        }

        private func applyFullscreenChrome(window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar?.isVisible = false
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
        }

        private func restoreWindowedChrome(window: NSWindow) {
            if let stored = storedWindowedTitlebarAppearsTransparent {
                window.titlebarAppearsTransparent = stored
            }
            if let hadFullSize = storedWindowedStyleMaskHadFullSizeContentView {
                if hadFullSize {
                    window.styleMask.insert(.fullSizeContentView)
                } else {
                    window.styleMask.remove(.fullSizeContentView)
                }
            }
            if let stored = storedWindowedTitleVisibility {
                window.titleVisibility = stored
            }
            if let stored = storedWindowedToolbarIsVisible {
                window.toolbar?.isVisible = stored
            }
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .automatic
            }
        }

        private func adjustFrameToVideoAspect(window: NSWindow) {
            guard let aspect = videoAspect, aspect.isFinite, aspect > 0 else { return }

            let currentFrame = window.frame
            let currentLayout = window.contentLayoutRect.size

            let deltaH = currentFrame.size.height - currentLayout.height

            guard currentLayout.width > 0 else { return }

            let desiredLayoutH = currentLayout.width / aspect
            guard desiredLayoutH.isFinite, desiredLayoutH > 0 else { return }

            var newFrame = currentFrame
            newFrame.size.height = desiredLayoutH + deltaH
            newFrame.origin.y += currentFrame.size.height - newFrame.size.height
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}

extension WindowAspectRatioSetter.Coordinator: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainWindowLifecycle.shouldClose(sender, forwardingTo: forwardedDelegate)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return forwardedDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwardedDelegate
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let aspect = videoAspect else { return frameSize }

        let currentFrame = sender.frame.size
        let currentLayout = sender.contentLayoutRect.size

        let deltaW = currentFrame.width - currentLayout.width
        let deltaH = currentFrame.height - currentLayout.height

        let proposedLayoutW = frameSize.width - deltaW
        let proposedLayoutH = frameSize.height - deltaH

        guard proposedLayoutW > 0, proposedLayoutH > 0 else { return frameSize }

        let dw = abs(frameSize.width - currentFrame.width)
        let dh = abs(frameSize.height - currentFrame.height)

        let constrained: NSSize
        if dw >= dh {
            let desiredLayoutH = proposedLayoutW / aspect
            constrained = NSSize(width: frameSize.width, height: desiredLayoutH + deltaH)
        } else {
            let desiredLayoutW = proposedLayoutH * aspect
            constrained = NSSize(width: desiredLayoutW + deltaW, height: frameSize.height)
        }

        if let forwardedDelegate,
           forwardedDelegate.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))) {
            return forwardedDelegate.windowWillResize?(sender, to: constrained) ?? constrained
        }

        return constrained
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            forwardedDelegate?.windowDidEnterFullScreen?(notification)
            return
        }
        applyFullscreenChrome(window: window)
        forwardedDelegate?.windowDidEnterFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            forwardedDelegate?.windowDidExitFullScreen?(notification)
            return
        }
        restoreWindowedChrome(window: window)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.adjustFrameToVideoAspect(window: window)
        }

        forwardedDelegate?.windowDidExitFullScreen?(notification)
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        DispatchQueue.main.async {
            if window.title != title {
                window.title = title
            }
            if window.styleMask.contains(.fullScreen) == false {
                window.titleVisibility = .visible
            }
        }
    }
}

struct ConnectionsPopoverView: View {
    @Binding var selectedDevice: KVMDevice?

    let isConnected: Bool
    let isConnecting: Bool
    let isScanning: Bool
    let devices: [KVMDevice]
    let connectedDeviceName: String?
    let latency: Int

    let videoSize: CGSize?
    let inboundVideoKbps: Int?
    let inboundFps: Double?
    let inboundVideoPlayoutDelayMs: Int?
    let inboundVideoJitterMs: Int?
    let inboundVideoDecodeMs: Int?
    let inboundVideoPacketsLost: Int?
    let iceCurrentRoundTripTimeMs: Int?

    let inboundAudioKbps: Int?
    let inboundAudioPlayoutDelayMs: Int?
    let inboundAudioJitterMs: Int?
    let inboundAudioPacketsLost: Int?
    let audioIceCurrentRoundTripTimeMs: Int?

    let onScan: () -> Void
    let onManualConnect: () -> Void
    let onToggleConnection: () -> Void
    let onClose: () -> Void
    let onForgetSelectedDevice: () -> Void

    var body: some View {
        let connectionAction = LocalConnectionAction(
            isConnected: isConnected, isConnecting: isConnecting, hasSelectedDevice: selectedDevice != nil
        )
        let resolutionText: String = {
            guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return "—" }
            return "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }()

        let kbpsText = inboundVideoKbps.map { "\($0) kbps" } ?? "— kbps"
        let fpsText = inboundFps.map { "\(Int($0.rounded())) fps" } ?? "— fps"
        let playoutDelayText = inboundVideoPlayoutDelayMs.map { "\($0) ms" } ?? "—"
        let jitterText = inboundVideoJitterMs.map { "\($0) ms" } ?? "—"
        let decodeText = inboundVideoDecodeMs.map { "\($0) ms" } ?? "—"
        let lossText = inboundVideoPacketsLost.map { String($0) } ?? "—"
        let rttText = iceCurrentRoundTripTimeMs.map { "\($0) ms" } ?? "—"

        let audioKbpsText = inboundAudioKbps.map { "\($0) kbps" } ?? "— kbps"
        let audioPlayoutDelayText = inboundAudioPlayoutDelayMs.map { "\($0) ms" } ?? "—"
        let audioJitterText = inboundAudioJitterMs.map { "\($0) ms" } ?? "—"
        let audioLossText = inboundAudioPacketsLost.map { String($0) } ?? "—"
        let audioRttText = audioIceCurrentRoundTripTimeMs.map { "\($0) ms" } ?? "—"

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connections")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Connections")
                .accessibilityLabel("Close Connections")
            }

            Picker("Device", selection: $selectedDevice) {
                Text("Select Device").tag(nil as KVMDevice?)
                ForEach(devices) { device in
                    Text(device.name).tag(device as KVMDevice?)
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(isConnected || isConnecting)

            if connectionAction == .cancel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                    Spacer()
                    Button("Cancel", action: onToggleConnection)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("cancel-connection-attempt")
                }
            } else if connectionAction == .disconnect {
                Button(role: .destructive, action: onToggleConnection) {
                    Text("Disconnect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button(action: onToggleConnection) {
                    HStack(spacing: 8) {
                        Text("Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!connectionAction.isEnabled)
                .keyboardShortcut(.defaultAction)
            }

            HStack {
                Button("Scan") { onScan() }
                    .disabled(isScanning || isConnecting)

                Button("Manual Connect…") { onManualConnect() }
                    .disabled(isConnected || isConnecting)

                Button("Forget") { onForgetSelectedDevice() }
                    .disabled(isConnected || isConnecting || selectedDevice?.id.hasPrefix("saved-") != true)

                Spacer()

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(connectedDeviceName ?? (selectedDevice?.name ?? "No Device"))
                    .font(.caption)

                HStack {
                    Text(isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundColor(isConnected ? .green : .red)

                    Spacer()

                    Text("Latency: \(latency)ms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WebRTC")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Video")
                        .font(.caption)
                    Spacer()
                    Text("\(resolutionText) · \(fpsText) · \(kbpsText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Playout")
                        .font(.caption)
                    Spacer()
                    Text(playoutDelayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Jitter")
                        .font(.caption)
                    Spacer()
                    Text(jitterText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Decode")
                        .font(.caption)
                    Spacer()
                    Text(decodeText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Lost")
                        .font(.caption)
                    Spacer()
                    Text(lossText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("ICE RTT")
                        .font(.caption)
                    Spacer()
                    Text(rttText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if inboundAudioKbps != nil || inboundAudioJitterMs != nil || inboundAudioPacketsLost != nil || audioIceCurrentRoundTripTimeMs != nil {
                    HStack {
                        Text("Audio")
                            .font(.caption)
                        Spacer()
                        Text(audioKbpsText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Audio Playout")
                            .font(.caption)
                        Spacer()
                        Text(audioPlayoutDelayText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Audio Jitter")
                            .font(.caption)
                        Spacer()
                        Text(audioJitterText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Audio Lost")
                            .font(.caption)
                        Spacer()
                        Text(audioLossText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Audio ICE RTT")
                            .font(.caption)
                        Spacer()
                        Text(audioRttText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(14)
    }
}

#Preview {
    ContentView()
        .environmentObject(WebRTCManager())
        .environmentObject(InputManager())
        .environmentObject(OCRManager())
        .environmentObject(KVMDeviceManager())
}
