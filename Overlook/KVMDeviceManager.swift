import Foundation
import Network
import Combine
import CryptoKit
import Security
import LocalAuthentication

@MainActor
final class KVMDeviceManager: NSObject, ObservableObject {
    @Published var availableDevices: [KVMDevice] = []
    @Published var connectedDevice: KVMDevice?
    @Published var glkvmClient: GLKVMClient?
    @Published var isScanning = false
    @Published var scanProgress: Double = 0.0
    @Published var autoScanEnabled: Bool = false
    @Published private(set) var mouseJigglerEnabled: Bool?
    @Published private(set) var mouseJigglerSupported: Bool?
    @Published private(set) var isMouseJigglerUpdating = false
    @Published private(set) var mouseJigglerErrorMessage: String?
    @Published private(set) var connectionSessionID: UUID?
    @Published private(set) var credentialStorageWarning: String?
    @Published private(set) var credentialStorageWarningGeneration: UInt64 = 0
    
    private var networkMonitor: NWPathMonitor?
    private var scanTimer: Timer?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var deviceDiscoverySessions: [NWBrowser] = []
    private var persistedDeviceLoadTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var configurationGeneration = 0
    private var mouseJigglerRefreshTask: Task<Void, Never>?
    private var mouseJigglerRefreshOwner: UUID?
    private var mouseJigglerResumeIntent: MouseJigglerResumeIntent?
    private var headlessConfigurationLockState = HeadlessConfigurationLockState()
    private var mouseJigglerOperationState = OperationOwnershipState()
    private let systemConfigMutationGate = RemoteMutationGate(maximumPendingMutations: 4)
    private let persistsConnections: Bool
    private let persistence: KVMDevicePersistence
    private let microJigglerPreference: MicroJigglerPreference
    private var microJigglerUserIntent: Bool?

    private struct MouseJigglerResumeIntent {
        let id = UUID()
        let client: GLKVMClient
        let deviceID: String
        let connectionGeneration: Int
    }

    private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: InsecureTLSDelegate(), delegateQueue: nil)
    }()

    private let commonProbeTargets: [(host: String, port: Int)] = [
        ("192.168.200.5", ScanPortPolicy.requiredPort),
        ("192.168.200.1", ScanPortPolicy.requiredPort),
    ]

    private struct PersistedDevice: Codable, Hashable, Sendable {
        let host: String
        let port: Int
        let name: String
        let type: KVMDeviceType
        let authToken: String?
        let capabilities: Set<KVMCapability>
    }

    private struct ScanProbeResult: Sendable {
        let candidateIndex: Int
        let isOpen: Bool
    }

    private actor DiscoveredDeviceCollector {
        private var devicesByEndpoint: [String: KVMDevice] = [:]

        func add(_ device: KVMDevice) {
            let endpointKey = "\(device.host):\(device.port)"
            guard devicesByEndpoint[endpointKey] == nil else { return }
            devicesByEndpoint[endpointKey] = device
        }

        func all() -> [KVMDevice] {
            Array(devicesByEndpoint.values)
        }
    }
    
    override convenience init() {
        self.init(startsServices: true, persistsConnections: true, microJigglerPreference: .live())
    }

    init(startsServices: Bool, persistsConnections: Bool, persistence: KVMDevicePersistence = .live,
         microJigglerPreference: MicroJigglerPreference = .disabled) {
        self.persistsConnections = persistsConnections
        self.persistence = persistence
        self.microJigglerPreference = microJigglerPreference
        super.init()
        if startsServices {
            setupNetworkMonitoring()
            loadPersistedDevices()
        }
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                if path.status == .satisfied, self?.autoScanEnabled == true {
                    self?.scanForDevices()
                }
            }
        }
        
        let queue = DispatchQueue(label: "com.overlook.network")
        networkMonitor?.start(queue: queue)
    }
    
    func scanForDevices() {
        scanTask?.cancel()
        scanTimer?.invalidate()
        scanTimer = nil
        scanGeneration += 1
        let generation = scanGeneration
        
        isScanning = true
        scanProgress = 0.0
        let pinnedDevices = availableDevices.filter { ScanPortPolicy.isPinned(deviceID: $0.id) }
        availableDevices = pinnedDevices
        
        // Start multiple discovery methods
        scanTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: [KVMDevice].self) { group in
                // GL.iNet Comet discovery
                group.addTask {
                    await self.discoverGLiNetDevices()
                }
                
                // Generic KVM discovery
                group.addTask {
                    await self.discoverGenericKVMDevices()
                }
                
                // Network scan for known ports
                group.addTask {
                    await self.scanKnownPorts()
                }

                // Quick probe for common/default KVM addresses
                group.addTask {
                    await self.probeCommonTargets()
                }
                
                // Tailscale network discovery
                group.addTask {
                    await self.discoverTailscaleDevices()
                }
                
                // Collect results
                var allCandidates: [KVMDevice] = []

                for await devices in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    allCandidates.append(contentsOf: devices)
                }

                let eligibleDevices = await self.devicesWithOpenRequiredScanPort(allCandidates)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.scanGeneration == generation else { return }
                    let pinnedDevices = self.availableDevices.filter {
                        ScanPortPolicy.isPinned(deviceID: $0.id)
                    }
                    let combined = self.removeDuplicates(from: pinnedDevices + eligibleDevices)
                    self.availableDevices = combined.sorted { $0.name < $1.name }
                }

                await MainActor.run {
                    guard self.scanGeneration == generation else { return }
                    self.isScanning = false
                    self.scanProgress = 1.0
                    self.scanTimer?.invalidate()
                    self.scanTimer = nil
                }
            }
        }
        
        // Update progress
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if self.scanProgress < 0.9 {
                    self.scanProgress += 0.05
                }
            }
        }
    }

    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        scanTimer?.invalidate()
        scanTimer = nil
        isScanning = false
    }
    
    private func discoverGLiNetDevices() async -> [KVMDevice] {
        let collector = DiscoveredDeviceCollector()
        
        // GL.iNet Comet uses mDNS/Bonjour discovery
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_comet._tcp", domain: nil), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, changes in
                for result in results {
                    let device = Self.createGLiNetDevice(from: result.endpoint)
                    Task {
                        await collector.add(device)
                    }
                }
            }
            
            browser.start(queue: DispatchQueue(label: "com.overlook.glinet"))
            
            // Stop after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task {
                    let devices = await collector.all()
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }
    
    nonisolated private static func createGLiNetDevice(from endpoint: NWEndpoint) -> KVMDevice {
        var name = "GL.iNet Comet"
        var host = ""
        let port = ScanPortPolicy.requiredPort
        
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        
        return KVMDevice(
            id: "glinet-\(UUID().uuidString)",
            name: name,
            host: host,
            port: port,
            type: .glinetComet,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
        )
    }
    
    private func discoverGenericKVMDevices() async -> [KVMDevice] {
        let collector = DiscoveredDeviceCollector()
        
        // Generic KVM discovery via mDNS
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_kvm._tcp", domain: nil), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, changes in
                for result in results {
                    let device = Self.createGenericKVMDevice(from: result.endpoint)
                    Task {
                        await collector.add(device)
                    }
                }
            }
            
            browser.start(queue: DispatchQueue(label: "com.overlook.generic"))
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task {
                    let devices = await collector.all()
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }
    
    nonisolated private static func createGenericKVMDevice(from endpoint: NWEndpoint) -> KVMDevice {
        var name = "Generic KVM"
        var host = ""
        let port = ScanPortPolicy.requiredPort
        
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        
        return KVMDevice(
            id: "generic-\(UUID().uuidString)",
            name: name,
            host: host,
            port: port,
            type: .generic,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
    }
    
    private func scanKnownPorts() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        
        let knownPorts = ScanPortPolicy.portsToProbe(from: [443, 8443, 80, 8080])
        let localNetwork = getLocalNetworkRange()

        let maxConcurrent = ScanPortPolicy.maximumConcurrentProbes
        var targets: [(host: String, port: Int)] = []
        targets.reserveCapacity(localNetwork.count * knownPorts.count)
        for host in localNetwork {
            for port in knownPorts {
                targets.append((host: host, port: port))
            }
        }
        
        await withTaskGroup(of: KVMDevice?.self) { group in
            var nextIndex = 0
            var inFlight = 0

            while nextIndex < targets.count || inFlight > 0 {
                while inFlight < maxConcurrent && nextIndex < targets.count {
                    let target = targets[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        await self.checkKVMService(host: target.host, port: target.port)
                    }
                }

                if let device = await group.next() {
                    inFlight -= 1
                    if let device {
                        devices.append(device)
                    }
                }
            }
        }
        
        return devices
    }
    
    private func getLocalNetworkRange() -> [String] {
        var prefixes: Set<String> = []
        var hosts: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }

            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let p = ptr {
                defer { ptr = p.pointee.ifa_next }
                guard let addr = p.pointee.ifa_addr else { continue }
                if addr.pointee.sa_family != UInt8(AF_INET) { continue }

                let flags = Int32(p.pointee.ifa_flags)
                if (flags & IFF_LOOPBACK) != 0 { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result != 0 { continue }
                let ip = String(cString: hostname)

                let parts = ip.split(separator: ".")
                guard parts.count == 4 else { continue }

                // Only scan typical private IPv4 ranges.
                let p0 = Int(parts[0]) ?? 0
                let p1 = Int(parts[1]) ?? 0
                let isPrivate = (p0 == 10) || (p0 == 192 && p1 == 168) || (p0 == 172 && (16...31).contains(p1))
                guard isPrivate else { continue }

                // Pragmatic /24 scan based on the interface IP.
                prefixes.insert("\(parts[0]).\(parts[1]).\(parts[2])")
            }
        }

        if prefixes.isEmpty {
            prefixes = [
                "192.168.1",
                "192.168.0",
                "10.0.0",
            ]
        }

        prefixes.insert("192.168.200")

        for prefix in prefixes {
            for i in 1...254 {
                hosts.append("\(prefix).\(i)")
            }
        }

        return hosts
    }

    private func probeCommonTargets() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        for target in commonProbeTargets {
            if let device = await checkKVMService(host: target.host, port: target.port) {
                devices.append(device)
                continue
            }

            // If the port is open but the HTTP probe didn't identify the service,
            // still surface it for the common/default targets (helps with devices
            // that redirect/behave oddly on probe endpoints).
            if await Self.probeTCPPortOpen(host: target.host, port: target.port) {
                devices.append(
                    KVMDevice(
                        id: "scanned-\(target.host)-\(target.port)",
                        name: "KVM @ \(target.host):\(target.port)",
                        host: target.host,
                        port: target.port,
                        type: .glinetComet,
                        authToken: "",
                        capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
                    )
                )
            }
        }
        return devices
    }

    private func devicesWithOpenRequiredScanPort(_ devices: [KVMDevice]) async -> [KVMDevice] {
        let endpoints = ScanPortPolicy.endpointsToProbe(
            from: devices.map {
                ScanPortPolicy.Endpoint(host: $0.host, port: $0.port)
            }
        )
        let selectedEndpoints = Set(endpoints)
        var firstDeviceByEndpoint: [ScanPortPolicy.Endpoint: KVMDevice] = [:]
        firstDeviceByEndpoint.reserveCapacity(endpoints.count)
        for device in devices {
            let endpoint = ScanPortPolicy.Endpoint(host: device.host, port: device.port)
            guard selectedEndpoints.contains(endpoint), firstDeviceByEndpoint[endpoint] == nil else {
                continue
            }
            firstDeviceByEndpoint[endpoint] = device
            if firstDeviceByEndpoint.count == endpoints.count { break }
        }
        let candidates = endpoints.compactMap { firstDeviceByEndpoint[$0] }
        guard !candidates.isEmpty else { return [] }

        var openCandidateIndices: Set<Int> = []
        await withTaskGroup(of: ScanProbeResult.self) { group in
            var nextCandidateIndex = 0
            var inFlightProbeCount = 0

            while nextCandidateIndex < candidates.count || inFlightProbeCount > 0 {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                while inFlightProbeCount < ScanPortPolicy.maximumConcurrentProbes,
                      nextCandidateIndex < candidates.count {
                    let candidateIndex = nextCandidateIndex
                    let host = candidates[candidateIndex].host
                    nextCandidateIndex += 1
                    inFlightProbeCount += 1

                    group.addTask {
                        let isOpen = await Self.probeTCPPortOpen(
                            host: host,
                            port: ScanPortPolicy.requiredPort
                        )
                        return ScanProbeResult(
                            candidateIndex: candidateIndex,
                            isOpen: isOpen
                        )
                    }
                }

                guard let result = await group.next() else { break }
                inFlightProbeCount -= 1
                if ScanPortPolicy.allows(
                    port: candidates[result.candidateIndex].port,
                    isOpen: result.isOpen
                ) {
                    openCandidateIndices.insert(result.candidateIndex)
                }
            }
        }

        return candidates.enumerated().compactMap { index, device in
            openCandidateIndices.contains(index) ? device : nil
        }
    }

    nonisolated private static func probeTCPPortOpen(host: String, port: Int) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        final class Flag {
            var value: Bool = false
        }

        let queue = DispatchQueue(label: "com.overlook.probe.port")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            let timeoutWorkItem = DispatchWorkItem {
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + 0.7, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
    
    private func checkKVMService(host: String, port: Int) async -> KVMDevice? {
        if await probeGLKVM(host: host, port: port) {
            return KVMDevice(
                id: "scanned-\(host)-\(port)",
                name: "GLKVM @ \(host):\(port)",
                host: host,
                port: port,
                type: .glinetComet,
                authToken: "",
                capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
            )
        }

        if await probeWebUIKeywords(host: host, port: port) {
            return KVMDevice(
                id: "scanned-\(host)-\(port)",
                name: "KVM @ \(host):\(port)",
                host: host,
                port: port,
                type: .generic,
                authToken: "",
                capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
            )
        }

        return nil
    }

    private func probeGLKVM(host: String, port: Int) async -> Bool {
        let preferredSchemes: [String] = (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]

        let paths = [
            "api/auth/check",
            "api/init/is_inited",
        ]

        for scheme in preferredSchemes {
            for path in paths {
                guard let url = URL(string: "\(scheme)://\(host):\(port)/\(path)") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 3

                do {
                    let (_, response) = try await probeSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else { continue }

                    switch http.statusCode {
                    case 200, 401, 403, 301, 302, 307, 308:
                        return true
                    default:
                        continue
                    }
                } catch {
                    continue
                }
            }
        }

        return false
    }

    private func probeWebUIKeywords(host: String, port: Int) async -> Bool {
        let preferredSchemes: [String] = (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]

        for scheme in preferredSchemes {
            guard let url = URL(string: "\(scheme)://\(host):\(port)/") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 2

            do {
                let (data, response) = try await probeSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200...399).contains(http.statusCode) else { continue }
                let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()

                if text.contains("kvmd") || text.contains("glkvm") || text.contains("comet") || text.contains("kvm") {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }
    
    private func discoverTailscaleDevices() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        
        // Check if Tailscale is available and discover devices on Tailscale network
        let tailscaleHosts = await getTailscaleHosts()
        
        for host in tailscaleHosts {
            if let device = await checkTailscaleKVM(host: host) {
                devices.append(device)
            }
        }
        
        return devices
    }
    
    private func getTailscaleHosts() async -> [String] {
        // Get Tailscale network hosts
        // This would typically involve calling tailscale API or parsing status output
        return []
    }
    
    private func checkTailscaleKVM(host: String) async -> KVMDevice? {
        let ports = ScanPortPolicy.portsToProbe(from: [8443, 8080, 443])
        
        for port in ports {
            if let device = await checkKVMService(host: host, port: port) {
                var tailscaleDevice = device
                tailscaleDevice.type = .tailscale
                tailscaleDevice.name = "\(device.name) (Tailscale)"
                return tailscaleDevice
            }
        }
        
        return nil
    }
    
    private func removeDuplicates(from devices: [KVMDevice]) -> [KVMDevice] {
        var uniqueDevices: [KVMDevice] = []
        var seenHosts: Set<String> = []
        
        for device in devices {
            let hostKey = "\(device.host):\(device.port)"
            if !seenHosts.contains(hostKey) {
                seenHosts.insert(hostKey)
                uniqueDevices.append(device)
            }
        }
        
        return uniqueDevices
    }
    
    @discardableResult
    func addManualDevice(host: String, port: Int, type: KVMDeviceType, authToken: String = "") -> KVMDevice {
        let device = KVMDevice(
            id: "manual-\(UUID().uuidString)",
            name: "Manual KVM @ \(host):\(port)",
            host: host,
            port: port,
            type: type,
            authToken: authToken,
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
        
        availableDevices.append(device)
        return device
    }

    func makeManualDeviceUsingStoredToken(host: String, port: Int, type: KVMDeviceType) async throws -> KVMDevice {
        try Task.checkCancellation()
        let storedToken = await Task.detached(priority: .userInitiated) {
            KVMTokenStore.load(host: host, port: port)
        }.value
        try Task.checkCancellation()
        return KVMDevice(
            id: "manual-\(UUID().uuidString)",
            name: "Manual KVM @ \(host):\(port)",
            host: host,
            port: port,
            type: type,
            authToken: storedToken ?? "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
    }

    func removeDevice(_ device: KVMDevice) {
        availableDevices.removeAll { $0.id == device.id }
        
        if connectedDevice?.id == device.id {
            clearConnectedDevice()
        }
    }

    func forgetDevice(_ device: KVMDevice) {
        let host = device.host
        let port = device.port

        var current = EndpointRecordPolicy.keepingLast(readPersistedDevices()) {
            "\($0.host):\($0.port)"
        }
        current.removeAll { $0.host == host && $0.port == port }
        writePersistedDevices(current)

        availableDevices.removeAll { $0.host == host && $0.port == port }
        if connectedDevice?.host == host, connectedDevice?.port == port {
            clearConnectedDevice()
        }
    }
    
    // Preparation may overlap a newer attempt. Publication and persistence are
    // reserved for the coordinator's synchronous, generation-checked commit.
    func prepareConnection(
        _ device: KVMDevice,
        authToken: String? = nil,
        password: String? = nil,
        user: String = "admin"
    ) async throws -> PreparedKVMConnection {
        try Task.checkCancellation()
        let isValid = try await validateDeviceConnection(device)
        try Task.checkCancellation()
        guard isValid else { throw KVMError.connectionFailed }

        let candidate = KVMDevice(
            id: device.id, name: device.name, host: device.host, port: device.port,
            type: device.type, authToken: authToken ?? device.authToken,
            capabilities: device.capabilities
        )
        let client = try GLKVMClient(device: candidate, allowInsecureTLS: true)
        do {
            try await client.authCheck()
            try Task.checkCancellation()
            return PreparedKVMConnection(device: candidate, client: client)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            guard let password, !password.isEmpty else { throw KVMError.authenticationFailed }
            let token = try await client.authLogin(user: user, password: password)
            try Task.checkCancellation()
            client.authToken = token
            let authenticated = KVMDevice(
                id: candidate.id, name: candidate.name, host: candidate.host, port: candidate.port,
                type: candidate.type, authToken: token, capabilities: candidate.capabilities
            )
            return PreparedKVMConnection(device: authenticated, client: client)
        }
    }

    @discardableResult
    func commitConnection(_ prepared: PreparedKVMConnection) -> KVMDevice {
        let persisted = persistsConnections ? persistDevice(prepared.device) : prepared.device
        connectionGeneration &+= 1
        configurationGeneration &+= 1
        invalidateMouseJigglerRefresh()
        mouseJigglerResumeIntent = nil
        mouseJigglerErrorMessage = nil
        mouseJigglerOperationState.reset()
        connectionSessionID = UUID()
        connectedDevice = persisted
        glkvmClient = prepared.client
        microJigglerUserIntent = microJigglerPreference.read(preferenceKey(for: persisted))
        mouseJigglerEnabled = nil
        mouseJigglerSupported = nil
        isMouseJigglerUpdating = false
        scheduleMouseJigglerRefresh(client: prepared.client, deviceID: persisted.id, generation: connectionGeneration)
        return persisted
    }

    func refreshMouseJigglerState() async {
        guard let client = glkvmClient, let deviceID = connectedDevice?.id else {
            mouseJigglerEnabled = nil
            mouseJigglerSupported = nil
            return
        }

        mouseJigglerEnabled = false
        configurationGeneration &+= 1
        invalidateMouseJigglerRefresh()
        let owner = UUID()
        mouseJigglerRefreshOwner = owner
        await refreshMouseJigglerState(
            client: client,
            deviceID: deviceID,
            generation: connectionGeneration,
            configurationGeneration: configurationGeneration,
            owner: owner
        )
        if mouseJigglerRefreshOwner == owner { mouseJigglerRefreshOwner = nil }
    }

    func setMouseJigglerEnabled(_ enabled: Bool) async throws {
        try await setMouseJigglerEnabled(enabled, preservesResumeIntent: false)
    }

    private func setMouseJigglerEnabled(_ enabled: Bool, preservesResumeIntent: Bool) async throws {
        guard MouseJigglerPolicy.allowsRequestedState(
            enabled, isHeadlessConfigurationLocked: headlessConfigurationLockState.isLocked
        ) else { throw MouseJigglerError.settingsLockedForHeadless }
        guard let client = glkvmClient, let device = connectedDevice else {
            throw MouseJigglerError.unavailable
        }
        try Task.checkCancellation()
        let deviceID = device.id
        if !preservesResumeIntent {
            mouseJigglerResumeIntent = nil
            microJigglerUserIntent = enabled
            microJigglerPreference.write(enabled, preferenceKey(for: device))
        }
        mouseJigglerEnabled = false
        mouseJigglerErrorMessage = nil
        invalidateMouseJigglerRefresh()
        let generation = connectionGeneration
        configurationGeneration &+= 1
        let operationGeneration = configurationGeneration
        let operationOwner = mouseJigglerOperationState.begin()
        isMouseJigglerUpdating = true
        defer {
            mouseJigglerOperationState.end(operationOwner)
            isMouseJigglerUpdating = mouseJigglerOperationState.isActive
        }
        func isCurrentOperation() -> Bool {
            !Task.isCancelled
                && isCurrentConnection(client: client, deviceID: deviceID, generation: generation)
                && configurationGeneration == operationGeneration
        }
        do {
            try await systemConfigMutationGate.perform { [self] in
                guard isCurrentOperation() else { throw CancellationError() }
                let current = try await client.getSystemConfig()
                guard isCurrentOperation() else { throw CancellationError() }
                guard current.supportsMouseJiggle else { throw MouseJigglerError.unavailable }
                // Both endpoints must be supported and readable before changing the firmware.
                _ = try await client.getHIDJigglerState()
                guard isCurrentOperation() else { throw CancellationError() }
                try await disableFirmwareJiggler(client: client, config: current,
                                                  isCurrentOperation: isCurrentOperation)
            }
            guard isCurrentOperation() else { throw CancellationError() }
            guard MouseJigglerPolicy.allowsRequestedState(
                enabled, isHeadlessConfigurationLocked: headlessConfigurationLockState.isLocked
            ) else { throw MouseJigglerError.settingsLockedForHeadless }
            mouseJigglerSupported = true
            mouseJigglerEnabled = enabled
        } catch {
            if isCurrentConnection(client: client, deviceID: deviceID, generation: generation),
               configurationGeneration == operationGeneration {
                mouseJigglerEnabled = nil
                mouseJigglerErrorMessage = "The KVM's large mouse jiggler could not be confirmed off. Micro movement remains stopped."
            }
            throw error
        }
    }

    /// Config and HID daemon are independent. Never send true to either firmware endpoint.
    private func disableFirmwareJiggler(
        client: GLKVMClient, config: GLKVMSystemConfig,
        isCurrentOperation: () -> Bool
    ) async throws {
        guard isCurrentOperation() else { throw CancellationError() }
        try await client.setHIDParams(["jiggler": "false"])
        guard isCurrentOperation() else { throw CancellationError() }
        var disabled = config
        disabled.mouseJiggle = false
        _ = try await client.setSystemConfig(disabled)
        guard isCurrentOperation() else { throw CancellationError() }
        let readback = try await client.getSystemConfig()
        guard isCurrentOperation() else { throw CancellationError() }
        guard readback.supportsMouseJiggle, !readback.mouseJiggle else {
            throw MouseJigglerError.readbackMismatch
        }
        let daemonActive = try await client.getHIDJigglerState()
        guard isCurrentOperation() else { throw CancellationError() }
        guard !daemonActive else { throw MouseJigglerError.readbackMismatch }
    }

    private func preferenceKey(for device: KVMDevice) -> String {
        MicroJigglerPreference.endpointKey(host: device.host, port: device.port)
    }

    func applySystemConfig(
        _ config: GLKVMSystemConfig, editedFields: Set<String>,
        connectionSessionID expectedSessionID: UUID
    ) async throws -> GLKVMSystemConfig {
        guard MouseJigglerPolicy.allowsSettingsApply(
            isHeadlessConfigurationLocked: headlessConfigurationLockState.isLocked
        ) else { throw MouseJigglerError.settingsLockedForHeadless }
        guard connectionSessionID == expectedSessionID,
              let client = glkvmClient, let device = connectedDevice
        else { throw MouseJigglerError.unavailable }
        let generation = connectionGeneration
        let operationGeneration = configurationGeneration
        let wasLocallyEnabled = mouseJigglerEnabled == true
        func isCurrentOperation() -> Bool {
            !Task.isCancelled && connectionSessionID == expectedSessionID
                && isCurrentConnection(client: client, deviceID: device.id, generation: generation)
                && configurationGeneration == operationGeneration
                && !headlessConfigurationLockState.isLocked
        }
        do {
            let updated = try await systemConfigMutationGate.perform { [self] in
                guard isCurrentOperation() else { throw CancellationError() }
                let current = try await client.getSystemConfig()
                guard isCurrentOperation() else { throw CancellationError() }
                var merged = try current.mergingSettingsEdits(from: config, editedFields: editedFields)
                if current.supportsMouseJiggle {
                    let daemonActive = try await client.getHIDJigglerState()
                    guard isCurrentOperation() else { throw CancellationError() }
                    // A fresh settings merge must never restore the firmware's large loop.
                    if current.mouseJiggle || daemonActive {
                        mouseJigglerEnabled = false
                        try await client.setHIDParams(["jiggler": "false"])
                        guard isCurrentOperation() else { throw CancellationError() }
                    }
                    merged.mouseJiggle = false
                }
                let updated = try await client.setSystemConfig(merged)
                guard isCurrentOperation() else { throw CancellationError() }
                if current.supportsMouseJiggle {
                    let readback = try await client.getSystemConfig()
                    guard isCurrentOperation() else { throw CancellationError() }
                    guard readback.supportsMouseJiggle, !readback.mouseJiggle else {
                        throw MouseJigglerError.readbackMismatch
                    }
                    let daemonActive = try await client.getHIDJigglerState()
                    guard isCurrentOperation() else { throw CancellationError() }
                    guard !daemonActive else { throw MouseJigglerError.readbackMismatch }
                }
                return updated
            }
            guard isCurrentOperation() else { throw CancellationError() }
            mouseJigglerSupported = updated.supportsMouseJiggle
            if updated.supportsMouseJiggle {
                mouseJigglerEnabled = wasLocallyEnabled && microJigglerUserIntent == true
            } else {
                mouseJigglerEnabled = nil
            }
            return updated
        } catch {
            if isCurrentOperation() {
                mouseJigglerEnabled = nil
                mouseJigglerErrorMessage = "The KVM's large mouse jiggler could not be confirmed off. Micro movement remains stopped."
            }
            throw error
        }
    }

    func beginHeadlessConfigurationTransition() -> UUID {
        if mouseJigglerResumeIntent == nil, microJigglerUserIntent == true,
           let client = glkvmClient, let deviceID = connectedDevice?.id {
            mouseJigglerResumeIntent = MouseJigglerResumeIntent(
                client: client, deviceID: deviceID, connectionGeneration: connectionGeneration
            )
        }
        mouseJigglerEnabled = false
        configurationGeneration &+= 1
        invalidateMouseJigglerRefresh()
        return headlessConfigurationLockState.beginTransition()
    }

    func pauseMouseJigglerForHeadless() async throws {
        guard let supported = mouseJigglerSupported else { throw MouseJigglerError.unavailable }
        if supported {
            try await setMouseJigglerEnabled(false, preservesResumeIntent: true)
            guard mouseJigglerEnabled == false else { throw MouseJigglerError.readbackMismatch }
        }
    }

    func resumeMouseJigglerAfterHeadless() async throws {
        guard let intent = mouseJigglerResumeIntent else { return }
        guard isCurrentConnection(client: intent.client, deviceID: intent.deviceID, generation: intent.connectionGeneration) else {
            mouseJigglerResumeIntent = nil
            return
        }
        guard !headlessConfigurationLockState.isLocked else { return }
        do {
            try await setMouseJigglerEnabled(true, preservesResumeIntent: true)
            if mouseJigglerResumeIntent?.id == intent.id { mouseJigglerResumeIntent = nil }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if mouseJigglerResumeIntent?.id == intent.id,
               isCurrentConnection(client: intent.client, deviceID: intent.deviceID, generation: intent.connectionGeneration),
               !headlessConfigurationLockState.isLocked {
                mouseJigglerErrorMessage = "The KVM could not restore the mouse jiggler. Check its state before enabling it again."
            }
            throw error
        }
    }

    func endHeadlessConfigurationTransition(_ owner: UUID) {
        headlessConfigurationLockState.endTransition(owner)
    }

    func setHeadlessModeActive(_ isActive: Bool) {
        if isActive {
            if mouseJigglerResumeIntent == nil, microJigglerUserIntent == true,
               let client = glkvmClient, let deviceID = connectedDevice?.id {
                mouseJigglerResumeIntent = MouseJigglerResumeIntent(
                    client: client, deviceID: deviceID, connectionGeneration: connectionGeneration
                )
            }
            mouseJigglerEnabled = false
        }
        configurationGeneration &+= 1
        invalidateMouseJigglerRefresh()
        headlessConfigurationLockState.setHeadlessModeActive(isActive)
    }

    private func invalidateMouseJigglerRefresh() {
        mouseJigglerRefreshOwner = nil
        mouseJigglerRefreshTask?.cancel()
        mouseJigglerRefreshTask = nil
    }

    private func scheduleMouseJigglerRefresh(client: GLKVMClient, deviceID: String, generation: Int) {
        invalidateMouseJigglerRefresh()
        let owner = UUID()
        let configurationGeneration = configurationGeneration
        mouseJigglerRefreshOwner = owner
        mouseJigglerRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshMouseJigglerState(
                client: client, deviceID: deviceID, generation: generation,
                configurationGeneration: configurationGeneration, owner: owner
            )
            if self.mouseJigglerRefreshOwner == owner {
                self.mouseJigglerRefreshOwner = nil
                self.mouseJigglerRefreshTask = nil
            }
        }
    }

    private func refreshMouseJigglerState(
        client: GLKVMClient, deviceID: String, generation: Int,
        configurationGeneration expectedConfigurationGeneration: Int, owner: UUID
    ) async {
        func isCurrentRefresh() -> Bool {
            !Task.isCancelled && mouseJigglerRefreshOwner == owner
                && configurationGeneration == expectedConfigurationGeneration
                && isCurrentConnection(client: client, deviceID: deviceID, generation: generation)
        }
        for attempt in 0..<3 {
            guard isCurrentRefresh() else { return }
            do {
                let supported = try await systemConfigMutationGate.perform { [self] in
                    guard isCurrentRefresh() else { throw CancellationError() }
                    let config = try await client.getSystemConfig()
                    guard isCurrentRefresh() else { throw CancellationError() }
                    guard config.supportsMouseJiggle else { return false }
                    let daemonActive = try await client.getHIDJigglerState()
                    guard isCurrentRefresh() else { throw CancellationError() }
                    let intent = microJigglerUserIntent ?? (config.mouseJiggle || daemonActive)
                    if config.mouseJiggle || daemonActive {
                        try await disableFirmwareJiggler(client: client, config: config,
                                                          isCurrentOperation: isCurrentRefresh)
                    }
                    guard isCurrentRefresh() else { throw CancellationError() }
                    microJigglerUserIntent = intent
                    if let device = connectedDevice {
                        microJigglerPreference.write(intent, preferenceKey(for: device))
                    }
                    return true
                }
                guard isCurrentRefresh() else { return }
                mouseJigglerSupported = supported
                mouseJigglerEnabled = supported
                    ? (microJigglerUserIntent == true && !headlessConfigurationLockState.isLocked
                       && mouseJigglerResumeIntent == nil)
                    : nil
                return
            } catch {
                guard isCurrentRefresh(), !(error is CancellationError) else { return }
                let isTransportFailure: Bool
                if case GLKVMClient.ClientError.transportFailed = error { isTransportFailure = true }
                else if let urlError = error as? URLError {
                    isTransportFailure = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                        .cannotFindHost, .notConnectedToInternet].contains(urlError.code)
                } else { isTransportFailure = false }
                if isTransportFailure, attempt < 2 {
                    do { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 100_000_000) }
                    catch { return }
                    continue
                }
                mouseJigglerEnabled = nil
                mouseJigglerErrorMessage = "The KVM's large mouse jiggler could not be confirmed off. Micro movement remains stopped."
                return
            }
        }
    }

    private func isCurrentConnection(client: GLKVMClient, deviceID: String, generation: Int) -> Bool {
        connectionGeneration == generation
            && glkvmClient === client
            && connectedDevice?.id == deviceID
    }

    private func clearConnectedDevice() {
        connectionGeneration &+= 1
        configurationGeneration &+= 1
        invalidateMouseJigglerRefresh()
        mouseJigglerResumeIntent = nil
        mouseJigglerErrorMessage = nil
        microJigglerUserIntent = nil
        mouseJigglerEnabled = nil
        mouseJigglerSupported = nil
        mouseJigglerOperationState.reset()
        isMouseJigglerUpdating = false
        headlessConfigurationLockState.reset()
        connectionSessionID = nil
        connectedDevice = nil
        glkvmClient = nil
    }

    private func persistDevice(_ device: KVMDevice) -> KVMDevice {
        let existing = readPersistedDevices()
        let previous = existing.last { $0.host == device.host && $0.port == device.port }
        let tokenStored = !device.authToken.isEmpty && persistence.saveToken(device.authToken, device.host, device.port)
        credentialStorageWarning = device.authToken.isEmpty || tokenStored ? nil : "Der Zugangstoken konnte nicht sicher im Schlüsselbund gespeichert werden. Die Verbindung funktioniert für diese Sitzung; bei der nächsten Anmeldung kann der Token erneut erforderlich sein."
        if credentialStorageWarning != nil { credentialStorageWarningGeneration &+= 1 }
        let record = PersistedDevice(
            host: device.host,
            port: device.port,
            name: device.name,
            type: device.type,
            authToken: tokenStored ? nil : previous?.authToken,
            capabilities: device.capabilities
        )

        let current = EndpointRecordPolicy.replacing(
            existing,
            with: record
        ) { "\($0.host):\($0.port)" }
        writePersistedDevices(current)

        var saved = device
        saved.id = Self.savedDeviceId(host: device.host, port: device.port)

        availableDevices.removeAll { $0.host == device.host && $0.port == device.port }
        availableDevices.append(saved)
        availableDevices = removeDuplicates(from: availableDevices).sorted { $0.name < $1.name }
        return saved
    }

    private func loadPersistedDevices() {
        let records = EndpointRecordPolicy.keepingLast(readPersistedDevices()) {
            "\($0.host):\($0.port)"
        }
        guard !records.isEmpty else { return }

        mergePersistedDevices(records.map { record in
            persistedKVMDevice(from: record, authToken: record.authToken ?? "")
        })

        persistedDeviceLoadTask?.cancel()
        persistedDeviceLoadTask = Task { @MainActor [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                records.map { record in
                    let keychainToken = KVMTokenStore.load(host: record.host, port: record.port)
                    let token = keychainToken ?? record.authToken ?? ""
                    return KVMDevice(
                        id: Self.savedDeviceId(host: record.host, port: record.port),
                        name: record.name,
                        host: record.host,
                        port: record.port,
                        type: record.type,
                        authToken: token,
                        capabilities: record.capabilities
                    )
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.mergePersistedDevices(loaded)
            self.persistedDeviceLoadTask = nil
        }
    }

    private func persistedKVMDevice(from record: PersistedDevice, authToken: String) -> KVMDevice {
        KVMDevice(
            id: Self.savedDeviceId(host: record.host, port: record.port),
            name: record.name,
            host: record.host,
            port: record.port,
            type: record.type,
            authToken: authToken,
            capabilities: record.capabilities
        )
    }

    private func mergePersistedDevices(_ loadedDevices: [KVMDevice]) {
        var merged = availableDevices

        for loaded in loadedDevices {
            if let index = merged.firstIndex(where: { $0.host == loaded.host && $0.port == loaded.port }) {
                let current = merged[index]
                merged[index] = KVMDevice(
                    id: loaded.id,
                    name: current.name,
                    host: current.host,
                    port: current.port,
                    type: current.type,
                    authToken: CredentialMergePolicy.preferredToken(
                        current: current.authToken,
                        loaded: loaded.authToken
                    ),
                    capabilities: current.capabilities.union(loaded.capabilities)
                )
            } else {
                merged.append(loaded)
            }
        }

        availableDevices = removeDuplicates(from: merged).sorted { $0.name < $1.name }
    }

    private nonisolated static func savedDeviceId(host: String, port: Int) -> String {
        let safeHost = host.replacingOccurrences(of: ":", with: "_")
        return "saved-\(safeHost)-\(port)"
    }

    private func readPersistedDevices() -> [PersistedDevice] {
        guard let data = persistence.readRecords() else { return [] }
        return (try? JSONDecoder().decode([PersistedDevice].self, from: data)) ?? []
    }

    private func writePersistedDevices(_ devices: [PersistedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        persistence.writeRecords(data)
    }
    
    private func validateDeviceConnection(_ device: KVMDevice) async throws -> Bool {
        guard let rawPort = UInt16(exactly: device.port),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            return false
        }

        final class Flag {
            var value: Bool = false
        }

        let queue = DispatchQueue(label: "com.overlook.validate")
        let connection = NWConnection(host: device.networkHost, port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            let timeoutWorkItem = DispatchWorkItem {
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + 5, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
    
    func disconnectFromDevice() {
        clearConnectedDevice()
    }
    
    deinit {
        scanTask?.cancel()
        persistedDeviceLoadTask?.cancel()
        mouseJigglerRefreshTask?.cancel()
        networkMonitor?.cancel()
        scanTimer?.invalidate()
        deviceDiscoverySessions.forEach { $0.cancel() }
    }
}

// Injected in local tests to avoid reading or writing real credentials/defaults.
struct KVMDevicePersistence {
    let readRecords: () -> Data?
    let writeRecords: (Data) -> Void
    let saveToken: (String, String, Int) -> Bool

    static let live = KVMDevicePersistence(
        readRecords: { UserDefaults.standard.data(forKey: "overlook.saved_devices.v1") },
        writeRecords: { UserDefaults.standard.set($0, forKey: "overlook.saved_devices.v1") },
        saveToken: { KVMTokenStore.save($0, host: $1, port: $2) }
    )
}

private enum KVMTokenStore {
    private static let service = "com.overlook.app.kvm-token"

    private static func account(host: String, port: Int) -> String { "\(host):\(port)" }

    @discardableResult
    static func save(_ token: String, host: String, port: Int) -> Bool {
        let account = account(host: host, port: port)
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var updateQuery = baseQuery
        updateQuery[kSecUseAuthenticationContext as String] = authenticationContext
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        } else if updateStatus != errSecSuccess {
            return false
        }

        return load(host: host, port: port) == token
    }

    static func load(host: String, port: Int) -> String? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(host: host, port: port),
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationContext as String: authenticationContext]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum KVMError: Error, LocalizedError {
    case deviceNotFound
    case connectionFailed
    case authenticationFailed
    case unsupportedCapability
    case networkUnavailable
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "KVM device not found"
        case .connectionFailed:
            return "Failed to connect to KVM device"
        case .authenticationFailed:
            return "Authentication failed"
        case .unsupportedCapability:
            return "Device does not support this capability"
        case .networkUnavailable:
            return "Network is not available"
        }
    }
}

enum MouseJigglerError: Error, LocalizedError {
    case unavailable
    case operationInProgress
    case readbackMismatch
    case settingsLockedForHeadless

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Mouse jiggler is unavailable for the current connection"
        case .operationInProgress:
            return "Mouse jiggler is already being updated"
        case .readbackMismatch:
            return "The KVM did not confirm that its large mouse jiggler is off"
        case .settingsLockedForHeadless:
            return "KVM settings are locked while Headless mode is active"
        }
    }
}
