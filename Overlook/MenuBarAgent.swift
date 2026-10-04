import SwiftUI
import AppKit
import Combine

@MainActor
class MenuBarAgent: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var popover: NSPopover?
    private var monitoringWindow: NSWindow?
    private var globalKeyMonitor: Any?

    private let kvmDeviceManager: KVMDeviceManager
    private let inputManager: InputManager
    private let sessionCoordinator: SessionConnectionCoordinator
    private let showMainWindow: () -> Void
    private let openSettings: () -> Void
    
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var currentDevice: KVMDevice?
    @Published var availableDevices: [KVMDevice] = []
    
    private var cancellables = Set<AnyCancellable>()

    init(
        kvmDeviceManager: KVMDeviceManager,
        inputManager: InputManager,
        sessionCoordinator: SessionConnectionCoordinator,
        showMainWindow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.kvmDeviceManager = kvmDeviceManager
        self.inputManager = inputManager
        self.sessionCoordinator = sessionCoordinator
        self.showMainWindow = showMainWindow
        self.openSettings = openSettings
        super.init()
    }
    
    func setup() {
        createStatusItem()
        createMenu()
        setupKeyboardShortcuts()

        bindManagers()
    }

    private func bindManagers() {
        availableDevices = kvmDeviceManager.availableDevices
        currentDevice = kvmDeviceManager.connectedDevice
        isConnected = (kvmDeviceManager.connectedDevice != nil)
        isConnecting = sessionCoordinator.isConnecting
        updateStatusIcon()
        updateDeviceMenu()

        kvmDeviceManager.$availableDevices
            .sink { [weak self] devices in
                guard let self else { return }
                self.availableDevices = devices
                self.updateDeviceMenu()
            }
            .store(in: &cancellables)

        kvmDeviceManager.$connectedDevice
            .sink { [weak self] device in
                guard let self else { return }
                self.currentDevice = device
                self.isConnected = (device != nil)
                self.updateStatusIcon()
                self.updateStatusMenuItem()
                self.updateDeviceMenu()
            }
            .store(in: &cancellables)

        sessionCoordinator.$isConnecting
            .sink { [weak self] connecting in
                guard let self else { return }
                self.isConnecting = connecting
                self.updateStatusMenuItem(isConnecting: connecting)
            }
            .store(in: &cancellables)
    }
    
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        updateStatusIcon()
    }
    
    private func createMenu() {
        menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Overlook", action: #selector(showMainWindowAction), keyEquivalent: "")
        showItem.target = self
        menu?.addItem(showItem)
        menu?.addItem(NSMenuItem.separator())
        
        // Device section
        let deviceItem = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        deviceItem.submenu = createDeviceMenu()
        menu?.addItem(deviceItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Connection status
        let statusItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
        statusItem.tag = 100
        menu?.addItem(statusItem)

        let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectAction), keyEquivalent: "")
        disconnectItem.target = self
        disconnectItem.tag = 101
        disconnectItem.isEnabled = false
        menu?.addItem(disconnectItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Quick actions
        let connectItem = NSMenuItem(title: "Quick Connect", action: #selector(showQuickConnect), keyEquivalent: "k")
        connectItem.target = self
        menu?.addItem(connectItem)
        
        let scanItem = NSMenuItem(title: "Scan for Devices", action: #selector(scanForDevices), keyEquivalent: "r")
        scanItem.target = self
        menu?.addItem(scanItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // OCR toggle
        let ocrItem = NSMenuItem(title: "Enable OCR", action: #selector(toggleOCR), keyEquivalent: "o")
        ocrItem.target = self
        ocrItem.tag = 200
        menu?.addItem(ocrItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu?.addItem(prefsItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit Overlook", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu?.addItem(quitItem)

        updateStatusMenuItem()
    }
    
    private func createDeviceMenu() -> NSMenu {
        let deviceMenu = NSMenu()
        
        let noDevicesItem = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
        noDevicesItem.tag = 300
        deviceMenu.addItem(noDevicesItem)
        
        return deviceMenu
    }
    
    private func updateDeviceMenu() {
        guard let deviceMenuItem = menu?.items.first(where: { $0.title == "Devices" }),
              let deviceMenu = deviceMenuItem.submenu else { return }
        
        deviceMenu.removeAllItems()
        
        if availableDevices.isEmpty {
            let noDevicesItem = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
            noDevicesItem.tag = 300
            deviceMenu.addItem(noDevicesItem)
        } else {
            for device in availableDevices {
                let deviceItem = NSMenuItem(title: device.name, action: #selector(connectToDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = device
                
                if currentDevice?.host == device.host, currentDevice?.port == device.port {
                    deviceItem.state = .on
                }
                
                deviceMenu.addItem(deviceItem)
            }
        }
        
        deviceMenu.addItem(NSMenuItem.separator())

        // Forget saved devices
        let savedDevices = availableDevices.filter { $0.id.hasPrefix("saved-") }
        let forgetItem = NSMenuItem(title: "Forget Saved Device", action: nil, keyEquivalent: "")
        let forgetMenu = NSMenu()
        if savedDevices.isEmpty {
            forgetMenu.addItem(NSMenuItem(title: "No saved devices", action: nil, keyEquivalent: ""))
        } else {
            for device in savedDevices {
                let item = NSMenuItem(title: device.name, action: #selector(forgetDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                forgetMenu.addItem(item)
            }
        }
        forgetItem.submenu = forgetMenu
        deviceMenu.addItem(forgetItem)

        // Remove manual devices
        let manualDevices = availableDevices.filter { $0.id.hasPrefix("manual-") }
        let removeItem = NSMenuItem(title: "Remove Manual Device", action: nil, keyEquivalent: "")
        let removeMenu = NSMenu()
        if manualDevices.isEmpty {
            removeMenu.addItem(NSMenuItem(title: "No manual devices", action: nil, keyEquivalent: ""))
        } else {
            for device in manualDevices {
                let item = NSMenuItem(title: device.name, action: #selector(removeManualDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                removeMenu.addItem(item)
            }
        }
        removeItem.submenu = removeMenu
        deviceMenu.addItem(removeItem)
        
        deviceMenu.addItem(NSMenuItem.separator())
        
        let addDeviceItem = NSMenuItem(title: "Add Manual Device...", action: #selector(showAddDevice), keyEquivalent: "")
        addDeviceItem.target = self
        deviceMenu.addItem(addDeviceItem)
    }
    
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            // Show context menu
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            // Show popover
            togglePopover(nil)
        }
    }

    private func updateStatusMenuItem(isConnecting: Bool? = nil) {
        let connecting = isConnecting ?? self.isConnecting
        if let statusItem = menu?.items.first(where: { $0.tag == 100 }) {
            if connecting {
                statusItem.title = "Connecting..."
            } else if let device = currentDevice {
                statusItem.title = "Connected to \(device.name)"
            } else {
                statusItem.title = "Status: Disconnected"
            }
        }
        if let disconnectItem = menu?.items.first(where: { $0.tag == 101 }) {
            disconnectItem.isEnabled = connecting || currentDevice != nil
        }
    }

    private func runLocalModal(alert: NSAlert, owner: UUID) -> NSApplication.ModalResponse {
        inputManager.setLocalUIBlocked(true, owner: owner)
        defer { inputManager.setLocalUIBlocked(false, owner: owner) }
        return alert.runModal()
    }

    private func promptForPassword(deviceName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Password Required"
        alert.informativeText = "Enter password for \(deviceName)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        passwordField.placeholderString = "Password"
        alert.accessoryView = passwordField

        let response = runLocalModal(alert: alert, owner: UUID())
        guard response == .alertFirstButtonReturn else { return nil }

        let pw = passwordField.stringValue
        return pw.isEmpty ? nil : pw
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = runLocalModal(alert: alert, owner: UUID())
    }
    
    @objc private func togglePopover(_ sender: Any?) {
        if let popover = popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }
    
    private func showPopover() {
        guard let statusItem = statusItem else { return }
        
        if popover == nil {
            popover = NSPopover()
            popover?.contentSize = NSSize(width: 300, height: 400)
            popover?.behavior = .transient
            popover?.contentViewController = NSHostingController(
                rootView: MenuBarView(
                    kvmDeviceManager: kvmDeviceManager,
                    onShowWindow: { [weak self] in self?.showMainWindow() },
                    onScan: { [weak self] in self?.kvmDeviceManager.scanForDevices() },
                    onConnect: { [weak self] device in
                        self?.connectSession(to: device)
                    },
                    onDisconnect: { [weak self] in
                        self?.disconnectSession()
                    },
                    onForget: { [weak self] device in
                        self?.forgetSavedDevice(device)
                    },
                    onRemove: { [weak self] device in
                        self?.removeManualEntry(device)
                    }
                )
            )
        }
        
        popover?.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
    }
    
    private func closePopover() {
        popover?.performClose(nil)
    }
    
    @objc private func connectToDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }

        connectSession(to: device)
    }

    private func connectSession(to device: KVMDevice) {
        showMainWindow()
        let attempt = sessionCoordinator.startConnection(to: device)
        handleConnection(
            attempt,
            deviceName: device.name,
            retry: { [sessionCoordinator] password in
                sessionCoordinator.startConnection(to: device, password: password)
            }
        )
    }

    private func handleConnection(
        _ attempt: SessionConnectionCoordinator.Attempt,
        deviceName: String,
        retry: @escaping @MainActor (String) -> SessionConnectionCoordinator.Attempt
    ) {
        Task { @MainActor [weak self] in
            await self?.awaitConnection(attempt, deviceName: deviceName, retry: retry)
        }
    }

    private func awaitConnection(
        _ attempt: SessionConnectionCoordinator.Attempt,
        deviceName: String,
        retry: @escaping @MainActor (String) -> SessionConnectionCoordinator.Attempt
    ) async {
        do {
            _ = try await attempt.task.value
            guard sessionCoordinator.isCurrent(attempt.id) else { return }
            closePopover()
        } catch {
            if Self.isCancellation(error) { return }
            guard sessionCoordinator.isCurrent(attempt.id) else { return }

            if let kvmError = error as? KVMError, kvmError == .authenticationFailed {
                guard let password = promptForPassword(deviceName: deviceName) else { return }
                guard sessionCoordinator.isCurrent(attempt.id) else { return }
                let retryAttempt = retry(password)
                await awaitConnection(retryAttempt, deviceName: deviceName, retry: retry)
                return
            }

            guard sessionCoordinator.isCurrent(attempt.id) else { return }
            showError(title: "Failed to connect", message: error.localizedDescription)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    @objc private func disconnectAction() {
        disconnectSession()
    }

    private func disconnectSession() {
        _ = sessionCoordinator.disconnect()
        closePopover()
    }
    
    @objc private func showQuickConnect() {
        let alert = NSAlert()
        alert.messageText = "Quick Connect"
        alert.informativeText = "Enter the IP/host and port of your KVM device"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 86)

        let hostField = NSTextField(frame: NSRect(x: 0, y: 56, width: 260, height: 22))
        hostField.placeholderString = "Host or IP (optionally host:port)"

        let portField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 22))
        portField.placeholderString = "Port"
        portField.stringValue = "443"
        portField.integerValue = 443

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        passwordField.placeholderString = "Password (optional)"

        view.addSubview(hostField)
        view.addSubview(portField)
        view.addSubview(passwordField)
        alert.accessoryView = view

        let response = runLocalModal(alert: alert, owner: UUID())
        guard response == .alertFirstButtonReturn else { return }

        let endpoint: ManualConnectionEndpoint
        do {
            endpoint = try ManualConnectionEndpoint.parse(
                hostPort: hostField.stringValue, port: portField.stringValue
            )
        } catch {
            showError(title: LocalActionErrorKind.endpoint.title, message: error.localizedDescription)
            return
        }
        let host = endpoint.host
        let port = endpoint.port
        let password = passwordField.stringValue
        let deviceName = "Manual KVM @ \(host):\(port)"
        let deviceFactory: @MainActor () async throws -> KVMDevice = { [kvmDeviceManager] in
            try await kvmDeviceManager.makeManualDeviceUsingStoredToken(
                host: host,
                port: port,
                type: .glinetComet
            )
        }

        showMainWindow()
        let attempt = sessionCoordinator.startConnection(
            deviceFactory: deviceFactory,
            password: password.isEmpty ? nil : password
        )
        handleConnection(
            attempt,
            deviceName: deviceName,
            retry: { [sessionCoordinator] password in
                sessionCoordinator.startConnection(deviceFactory: deviceFactory, password: password)
            }
        )
    }
    
    @objc private func scanForDevices() {
        kvmDeviceManager.scanForDevices()
    }
    
    @objc private func toggleOCR() {
        NotificationCenter.default.post(name: .overlookToggleCopyMode, object: nil)
        
        // Update menu item
        if let ocrItem = menu?.items.first(where: { $0.tag == 200 }) {
            ocrItem.title = ocrItem.title.contains("Enable") ? "Disable OCR" : "Enable OCR"
        }
    }
    
    @objc private func showPreferences() {
        closePopover()
        openSettings()
    }
    
    @objc private func showAddDevice() {
        // Show add device dialog
        let alert = NSAlert()
        alert.messageText = "Add Manual Device"
        alert.informativeText = "Enter the IP address and port of your KVM device"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        // Add text fields for IP and port
        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        
        let ipField = NSTextField(frame: NSRect(x: 0, y: 30, width: 200, height: 20))
        ipField.placeholderString = "IP Address"
        ipField.stringValue = ""
        
        let portField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        portField.placeholderString = "Port"
        portField.stringValue = "8443"
        portField.integerValue = 8443
        
        view.addSubview(ipField)
        view.addSubview(portField)
        
        alert.accessoryView = view
        
        let response = runLocalModal(alert: alert, owner: UUID())
        if response == .alertFirstButtonReturn {
            do {
                let endpoint = try ManualConnectionEndpoint.parse(
                    hostPort: ipField.stringValue, port: portField.stringValue
                )
                _ = kvmDeviceManager.addManualDevice(host: endpoint.host, port: endpoint.port, type: .glinetComet)
            } catch {
                showError(title: LocalActionErrorKind.endpoint.title, message: error.localizedDescription)
            }
        }
    }

    @objc private func forgetDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }
        disconnectIfNeeded(for: device)
        kvmDeviceManager.forgetDevice(device)
    }

    @objc private func removeManualDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }
        disconnectIfNeeded(for: device)
        kvmDeviceManager.removeDevice(device)
    }

    private func forgetSavedDevice(_ device: KVMDevice) {
        disconnectIfNeeded(for: device)
        kvmDeviceManager.forgetDevice(device)
    }

    private func removeManualEntry(_ device: KVMDevice) {
        disconnectIfNeeded(for: device)
        kvmDeviceManager.removeDevice(device)
    }

    private func disconnectIfNeeded(for device: KVMDevice) {
        let matchesCurrentEndpoint = kvmDeviceManager.connectedDevice?.host == device.host
            && kvmDeviceManager.connectedDevice?.port == device.port
        if isConnecting || matchesCurrentEndpoint {
            disconnectSession()
        }
    }

    @objc private func showMainWindowAction() {
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        
        if isConnected {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook - Connected")
            button.contentTintColor = .systemGreen
        } else {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook - Disconnected")
            button.contentTintColor = .labelColor
        }
    }
    
    private func setupKeyboardShortcuts() {
        // Global keyboard shortcuts for quick actions
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyEvent(event)
        }
    }
    
    private func handleGlobalKeyEvent(_ event: NSEvent) {
        let mode = OverlookControlMode(
            rawValue: UserDefaults.standard.string(forKey: "overlook.controlMode") ?? ""
        ) ?? .manual
        guard mode == .manual else { return }
        guard event.modifierFlags.contains([.command, .shift]) else { return }
        
        switch event.keyCode {
        case 9: // V key - Quick connect
            showQuickConnect()
        case 31: // O key - Toggle OCR
            toggleOCR()
        case 15: // R key - Scan devices
            scanForDevices()
        default:
            break
        }
    }
    
    func updateConnectionStatus(_ connected: Bool, device: KVMDevice?) {
        isConnected = connected
        currentDevice = device
        
        Task { @MainActor in
            updateStatusIcon()
            
            if let statusItem = menu?.items.first(where: { $0.tag == 100 }) {
                if connected, let device = device {
                    statusItem.title = "Connected to \(device.name)"
                } else {
                    statusItem.title = "Status: Disconnected"
                }
            }
            
            updateDeviceMenu()
        }
    }
    
    func updateAvailableDevices(_ devices: [KVMDevice]) {
        availableDevices = devices
        
        Task { @MainActor in
            updateDeviceMenu()
        }
    }
    
    func cleanup() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        statusItem = nil
        menu = nil
        popover = nil
        monitoringWindow = nil
        cancellables.removeAll()
    }
}

// MARK: - Menu Bar View
struct MenuBarView: View {
    @ObservedObject var kvmDeviceManager: KVMDeviceManager

    let onShowWindow: () -> Void
    let onScan: () -> Void
    let onConnect: (KVMDevice) -> Void
    let onDisconnect: () -> Void
    let onForget: (KVMDevice) -> Void
    let onRemove: (KVMDevice) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "display.2")
                    .font(.title2)
                Text("Overlook")
                    .font(.headline)
                Spacer()
                Button("Show") {
                    onShowWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            
            Divider()
            
            // Device list
            ScrollView {
                LazyVStack(spacing: 8) {
                    if kvmDeviceManager.availableDevices.isEmpty {
                        Text("No devices found")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(kvmDeviceManager.availableDevices) { device in
                            MenuBarDeviceRow(
                                device: device,
                                isConnected: kvmDeviceManager.connectedDevice?.host == device.host && kvmDeviceManager.connectedDevice?.port == device.port,
                                onConnect: {
                                    onConnect(device)
                                },
                                onDisconnect: {
                                    onDisconnect()
                                },
                                onForget: {
                                    onForget(device)
                                },
                                onRemoveManual: {
                                    onRemove(device)
                                }
                            )
                        }
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Scan") {
                    onScan()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 300, height: 400)
    }
}

struct MenuBarDeviceRow: View {
    let device: KVMDevice

    let isConnected: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onForget: () -> Void
    let onRemoveManual: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(device.connectionString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()

            if device.id.hasPrefix("saved-") {
                Button {
                    onForget()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget saved device")
                .disabled(isConnected)
            } else if device.id.hasPrefix("manual-") {
                Button {
                    onRemoveManual()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove manual device")
                .disabled(isConnected)
            }
            
            Button(isConnected ? "Disconnect" : "Connect") {
                if isConnected {
                    onDisconnect()
                } else {
                    onConnect()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}
