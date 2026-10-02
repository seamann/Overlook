import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif
import Vision
import Network
import Combine

@main
struct OverlookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.webRTCManager)
                .environmentObject(appDelegate.inputManager)
                .environmentObject(appDelegate.ocrManager)
                .environmentObject(appDelegate.kvmDeviceManager)
                .environmentObject(appDelegate.controlModeStore)
                .environmentObject(appDelegate.sessionCoordinator)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarAgent: MenuBarAgent?

    let webRTCManager = WebRTCManager()
    let inputManager = InputManager()
    let ocrManager = OCRManager()
    let kvmDeviceManager = KVMDeviceManager()
    let controlModeStore = ControlModeStore()
    let localControlServer = LocalControlServer()
    lazy var sessionCoordinator = SessionConnectionCoordinator(dependencies: .init(
        prepare: { [unowned self] device, password in
            try await kvmDeviceManager.prepareConnection(device, password: password)
        },
        commit: { [unowned self] prepared in kvmDeviceManager.commitConnection(prepared) },
        invalidateSession: { [unowned self] in
            controlModeStore.setMode(.manual)
            inputManager.setSessionAvailable(false)
            webRTCManager.disconnect()
            kvmDeviceManager.disconnectFromDevice()
        },
        drainSession: { [unowned self] in
            await localControlServer.waitForMutationsToDrain()
            await inputManager.disconnectInputForSession()
        },
        installInput: { [unowned self] client in
            inputManager.setGLKVMClient(client)
            inputManager.setSessionAvailable(true)
        },
        setHIDConnected: { client, connected in try await client.setHidConnected(connected) },
        connectVideo: { [unowned self] device in try await webRTCManager.connect(to: device) },
        setConnectionTransitioning: { [unowned self] transitioning in
            inputManager.setConnectionTransitioning(transitioning)
        }
    ))
    private var isTerminating = false
    private var observedClientIdentity: ObjectIdentifier?
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices and the Dock can retain the generic icon for locally
        // replaced development builds. Set the compiled bundle icon explicitly
        // so the running application always uses the WAGO monitor artwork.
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }

        inputManager.setup(with: webRTCManager)
        menuBarAgent = MenuBarAgent(
            kvmDeviceManager: kvmDeviceManager,
            inputManager: inputManager,
            sessionCoordinator: sessionCoordinator,
            showMainWindow: { [weak self] in
                self?.showMainWindow()
            }
        )
        menuBarAgent?.setup()
        bindControlSafetyState()
        controlModeStore.configureInputCapture(
            { [weak self] allowed in
                self?.inputManager.setLocalInputCaptureAllowed(allowed)
            },
            waitForRemoteMutations: { [weak self] in
                await self?.localControlServer.waitForMutationsToDrain()
            }
        )
        localControlServer.setModeProvider { [weak self] in
            self?.controlModeStore.snapshot ?? ControlModeSnapshot(mode: .manual, generation: 0)
        }
        localControlServer.setSnapshotProvider(webRTCManager)
        localControlServer.start(inputManager: inputManager)
        
        // Configure app for KVM control
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bindControlSafetyState() {
        controlModeStore.$mode
            .sink { [weak self] mode in
                self?.kvmDeviceManager.setHeadlessModeActive(mode == .codexHeadless)
            }
            .store(in: &cancellables)

        kvmDeviceManager.$glkvmClient
            .sink { [weak self] client in
                guard let self else { return }
                let nextIdentity = client.map(ObjectIdentifier.init)
                defer { self.observedClientIdentity = nextIdentity }
                guard self.observedClientIdentity != nextIdentity else { return }
                self.controlModeStore.setMode(.manual)
            }
            .store(in: &cancellables)
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let windows = NSApp.windows
        let candidate = windows.first(where: { $0.canBecomeKey && $0.isVisible }) ?? windows.first(where: { $0.canBecomeKey })
        candidate?.makeKeyAndOrderFront(nil)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        menuBarAgent?.cleanup()
        localControlServer.stop()
        Task { @MainActor in
            kvmDeviceManager.cancelScan()
            await sessionCoordinator.disconnect().value
            await inputManager.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
