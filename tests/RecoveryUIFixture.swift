import AppKit
import Combine
import Darwin
import SwiftUI

/// Renders the production recovery UI with local, inert session dependencies.
/// Applies a network-denied sandbox before creating application objects.
@main
@MainActor
enum RecoveryUIFixture {
    private static var delegate: RecoveryFixtureDelegate?

    static func main() {
        do {
            try enterNetworkSandbox()
            if CommandLine.arguments.dropFirst().first == "--verify-sandbox" {
                try verifySandbox()
                return
            }
        } catch {
            FileHandle.standardError.write(Data("Recovery fixture sandbox failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
        let application = NSApplication.shared
        let fixtureDelegate = RecoveryFixtureDelegate()
        delegate = fixtureDelegate
        application.delegate = fixtureDelegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    private static func enterNetworkSandbox() throws {
        let result = RecoveryFixtureEnterNetworkSandbox()
        guard result == 0 else { throw FixtureSandboxError.initializationFailed }
    }

    /// A denied socket/connect must produce a permission error, not merely an
    /// unavailable server. File output also proves fixture evidence remains writable.
    private static func verifySandbox() throws {
        guard CommandLine.arguments.count == 3 else { throw FixtureSandboxError.invalidArguments }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        let failureCode: Int32
        if descriptor == -1 {
            failureCode = errno
        } else {
            defer { Darwin.close(descriptor) }
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = UInt16(9).bigEndian
            target.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            failureCode = result == -1 ? errno : 0
        }
        guard failureCode == EPERM || failureCode == EACCES else {
            throw FixtureSandboxError.networkWasNotDenied(failureCode)
        }
        let evidence: [String: Any] = ["networkDenied": true, "permissionError": failureCode,
                                       "profile": "deny network*", "fixtureFileWritable": true]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Recovery fixture sandbox verified; local evidence file written")
    }

    private enum FixtureSandboxError: Error {
        case initializationFailed
        case invalidArguments
        case networkWasNotDenied(Int32)
    }
}

@MainActor
private final class RecoveryFixtureDelegate: NSObject, NSApplicationDelegate {
    private let fixture = RecoveryFixtureModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await fixture.seedFailedDisconnect()
                showWindow()
            } catch {
                fixture.record("fixture_setup_failed")
                NSApp.terminate(nil)
            }
        }
    }

    private func showWindow() {
        let content = RecoveryFixtureView(fixture: fixture, input: fixture.input,
                                          coordinator: fixture.coordinator)
            .environmentObject(fixture.video)
            .environmentObject(fixture.input)
            .environmentObject(fixture.ocr)
            .environmentObject(fixture.devices)
            .environmentObject(fixture.mode)
            .environmentObject(fixture.coordinator)
            .environmentObject(fixture.requests)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Overlook Recovery Fixture"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        fixture.attachWindow(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
private final class RecoveryFixtureModel: ObservableObject {
    let video = WebRTCManager()
    let input = InputManager(clipboardText: { nil })
    let ocr = OCRManager()
    let devices = KVMDeviceManager(
        startsServices: false, persistsConnections: false,
        persistence: KVMDevicePersistence(readRecords: { nil }, writeRecords: { _ in },
                                          saveToken: { _, _, _ in false })
    )
    let mode = ControlModeStore(defaults: nil)
    let requests = LocalUIRequests()
    private let runID = UUID().uuidString
    @Published private(set) var simulatedHIDTransitions = 0
    private var seeded = false
    private var observers = Set<AnyCancellable>()
    private weak var window: NSWindow?

    func attachWindow(_ window: NSWindow) {
        self.window = window
        record("window_ready")
    }

    func resizeWindow(width: Int) {
        window?.setContentSize(NSSize(width: width, height: 740))
        record("window_resized")
    }

    lazy var coordinator = SessionConnectionCoordinator(dependencies: .init(
        prepare: { device, _ in
            PreparedKVMConnection(device: device,
                                  client: try GLKVMClient(host: device.host, port: device.port))
        },
        commit: { [unowned self] prepared in
            devices.connectedDevice = prepared.device
            return prepared.device
        },
        invalidateSession: { [unowned self] in
            devices.connectedDevice = nil
            input.setSessionAvailable(false)
        },
        drainSession: {},
        blockInputForRecovery: { [unowned self] in input.blockInputAfterUnconfirmedSession() },
        installInput: { [unowned self] _ in input.setSessionAvailable(true) },
        setHIDConnected: { [unowned self] _, connected in
            simulatedHIDTransitions += 1
            if !connected { throw FixtureError.unconfirmedDisconnect }
        },
        connectVideo: { _ in },
        setConnectionTransitioning: { [unowned self] in input.setConnectionTransitioning($0) },
        reportTransportError: { _, _ in }
    ))

    func seedFailedDisconnect() async throws {
        input.setup(with: video)
        mode.configureInputCapture { [weak input] in input?.setLocalInputCaptureAllowed($0) }
        let device = KVMDevice(id: "fixture-old-session", name: "Fixture KVM",
                               host: "old-kvm.invalid", port: 443, type: .glinetComet,
                               authToken: "", capabilities: [.videoStreaming, .keyboardInput])
        _ = try await coordinator.startConnection(to: device).task.value
        await coordinator.disconnect().value
        precondition(input.inputBlocked && coordinator.pendingCleanupReview != nil)
        precondition(simulatedHIDTransitions == 2 && devices.connectedDevice == nil)
        seeded = true
        observe(input.objectWillChange)
        observe(coordinator.objectWillChange)
        record("ready")
    }

    private func observe(_ publisher: ObservableObjectPublisher) {
        publisher.sink { [weak self] in
            Task { @MainActor in self?.record("state_changed") }
        }.store(in: &observers)
    }

    func record(_ event: String) {
        guard seeded || event == "fixture_setup_failed" else { return }
        // Confirmation may remove local ownership, but may never release input
        // or generate a third simulated HID transition in this isolated journey.
        if seeded { precondition(input.inputBlocked && simulatedHIDTransitions == 2) }
        let state: [String: Any] = [
            "runID": runID,
            "event": event,
            "inputBlocked": input.inputBlocked,
            "reviewPending": coordinator.pendingCleanupReview != nil,
            "connected": devices.connectedDevice != nil,
            "simulatedHIDTransitions": simulatedHIDTransitions,
            "windowContentWidth": window?.contentLayoutRect.width ?? 0,
            "networkAccess": "denied_in_process"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let file = CommandLine.arguments.count == 2
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("state.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            assertionFailure("The fixture could not record its local state")
        }
    }

    private enum FixtureError: Error { case unconfirmedDisconnect }
}

private struct RecoveryFixtureView: View {
    @ObservedObject var fixture: RecoveryFixtureModel
    @ObservedObject var input: InputManager
    @ObservedObject var coordinator: SessionConnectionCoordinator

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Test-App · Eingabe: \(input.inputBlocked ? "gesperrt" : "frei") · Alt-Sitzung: \(coordinator.pendingCleanupReview == nil ? "abgeschlossen" : "Prüfung offen") · simulierte HID-Aufrufe: \(fixture.simulatedHIDTransitions) · Netzwerk gesperrt")
                    .font(.caption)
                    .accessibilityIdentifier("recovery-fixture-state")
                HStack {
                    Text("Fensterbreite:").font(.caption)
                    ForEach([1100, 720, 480], id: \.self) { width in
                        Button("\(width) px") {
                            fixture.resizeWindow(width: width)
                        }
                        .accessibilityIdentifier("recovery-fixture-width-\(width)")
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.18))
            ContentView()
        }
    }
}
