import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif
import Vision
import Network

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
    let localControlServer = LocalControlServer()
    private var isTerminating = false
    private var controlModeObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices and the Dock can retain the generic icon for locally
        // replaced development builds. Set the compiled bundle icon explicitly
        // so the running application always uses the WAGO monitor artwork.
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }

        menuBarAgent = MenuBarAgent(
            kvmDeviceManager: kvmDeviceManager,
            webRTCManager: webRTCManager,
            inputManager: inputManager,
            showMainWindow: { [weak self] in
                self?.showMainWindow()
            }
        )
        menuBarAgent?.setup()
        localControlServer.setCommandGate {
            let raw = UserDefaults.standard.string(forKey: "overlook.controlMode") ?? ""
            let mode = OverlookControlMode(rawValue: raw) ?? .manual
            return ControlMutationPolicy.allows(.mutation, in: mode)
        }
        let currentMode = OverlookControlMode(
            rawValue: UserDefaults.standard.string(forKey: "overlook.controlMode") ?? ""
        ) ?? .manual
        if currentMode == .codexHeadless {
            localControlServer.start(inputManager: inputManager)
        }
        controlModeObserver = NotificationCenter.default.addObserver(
            forName: .overlookControlModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                let raw = note.object as? String ?? ""
                self.localControlServer.stop()
                if OverlookControlMode(rawValue: raw) == .codexHeadless {
                    self.localControlServer.start(inputManager: self.inputManager)
                }
            }
        }
        
        // Configure app for KVM control
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        if let controlModeObserver {
            NotificationCenter.default.removeObserver(controlModeObserver)
            self.controlModeObserver = nil
        }
        localControlServer.stop()
        Task { @MainActor in
            kvmDeviceManager.cancelScan()
            await inputManager.shutdown()
            webRTCManager.disconnect()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
