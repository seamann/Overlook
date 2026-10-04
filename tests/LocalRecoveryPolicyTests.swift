import Foundation

@main
struct LocalRecoveryPolicyTests {
    @MainActor static func main() throws {
        let tests: [(String, @MainActor () throws -> Void)] = [
            ("explicit and embedded ports keep their original endpoint", validEndpoints),
            ("invalid ports are rejected rather than redirected to 443", invalidPorts),
            ("hosts reject URL credentials paths and malformed IPv6", invalidHosts),
            ("Headless local recovery remains available without remote input", headlessRecovery),
            ("an active attempt offers cancel even before a selected device", connectionCancellation),
            ("action alerts describe their failed operation", actionErrors),
            ("preferences requested before mount are retained and consumed once", preferencesBeforeMount),
            ("preferences require the same connected Manual state as the toolbar", settingsAccess),
        ]
        var failures: [String] = []
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)") }
        }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        try expect(failures.isEmpty, "\(failures.count) local recovery regressions")
        print("LocalRecoveryPolicyTests: \(tests.count) groups passed")
    }

    private static func validEndpoints() throws {
        for (raw, port, expectedHost, expectedPort) in [
            ("kvm.local", "443", "kvm.local", 443),
            (" 192.0.2.7 ", " 8443 ", "192.0.2.7", 8443),
            ("https://kvm.local:9443", "443", "kvm.local", 9443),
            ("kvm.local:1", "bad", "kvm.local", 1),
            ("kvm.local", "65535", "kvm.local", 65535),
            ("[2001:db8::1]", "443", "[2001:db8::1]", 443),
            ("[::1]", "443", "[::1]", 443),
            ("[2001:db8::1]:8443", "443", "[2001:db8::1]", 8443),
        ] {
            let endpoint = try ManualConnectionEndpoint.parse(hostPort: raw, port: port)
            try expect(endpoint.host == expectedHost && endpoint.port == expectedPort,
                       "Wrong endpoint for \(raw): \(endpoint)")
        }
    }

    private static func invalidPorts() throws {
        for port in ["", " ", "bad", "0", "-1", "+443", "65536", "443.0", "4 43", "４４３", "999999999999999999999"] {
            try expectFailure("kvm.local", port: port, expected: .invalidPort)
            try expectFailure("kvm.local:\(port)", port: "443", expected: .invalidPort)
        }
    }

    private static func invalidHosts() throws {
        for host in ["", " ", "https://", "https://u:p@kvm.local", "kvm.local/path", "kvm.local?token=x", "kvm.local#x", "kvm local", "kvm\n.local", "ftp://kvm.local", "2001:db8::1", "[2001:db8::1", "[not-ipv6]", "[foo:bar]"] {
            do {
                _ = try ManualConnectionEndpoint.parse(hostPort: host, port: "443")
                throw Failure.message("Accepted invalid host \(host)")
            } catch is ManualEndpointError {}
        }
    }

    private static func headlessRecovery() throws {
        for mode in OverlookControlMode.allCases {
            let state = LocalRecoveryPresentation(
                mode: mode, isVideoConnecting: false, isStreamStalled: true,
                hasEverConnectedToStream: true, isVideoConnected: true,
                hasDevice: true, isSessionConnecting: false, isPanelPresented: false
            )
            try expect(state.showsRecovery && state.canReconnect, "Local recovery unavailable in \(mode)")
            try expect(state.allowsRemoteInput == (mode == .manual), "Remote input gate changed in \(mode)")
        }
        let panel = LocalRecoveryPresentation(
            mode: .manual, isVideoConnecting: false, isStreamStalled: true,
            hasEverConnectedToStream: true, isVideoConnected: false,
            hasDevice: true, isSessionConnecting: false, isPanelPresented: true
        )
        try expect(!panel.allowsRemoteInput && !panel.canReconnect, "Recovery overlaps local panel")
        let busy = LocalRecoveryPresentation(
            mode: .codexHeadless, isVideoConnecting: true, isStreamStalled: false,
            hasEverConnectedToStream: false, isVideoConnected: false,
            hasDevice: true, isSessionConnecting: true, isPanelPresented: false
        )
        try expect(busy.showsRecovery && !busy.canReconnect && !busy.allowsRemoteInput,
                   "Connecting state permits duplicate reconnect or remote input")
        let healthy = LocalRecoveryPresentation(
            mode: .manual, isVideoConnecting: false, isStreamStalled: false,
            hasEverConnectedToStream: true, isVideoConnected: true,
            hasDevice: true, isSessionConnecting: false, isPanelPresented: false
        )
        try expect(!healthy.showsRecovery, "Recovery shown over healthy stream")
    }

    private static func connectionCancellation() throws {
        for hasDevice in [false, true] {
            let action = LocalConnectionAction(isConnected: false, isConnecting: true, hasSelectedDevice: hasDevice)
            try expect(action == .cancel && action.isEnabled, "Cannot cancel connecting attempt")
        }
        try expect(LocalConnectionAction(isConnected: true, isConnecting: false, hasSelectedDevice: false) == .disconnect,
                   "Connected state lost disconnect")
        try expect(!LocalConnectionAction(isConnected: false, isConnecting: false, hasSelectedDevice: false).isEnabled,
                   "Connect allowed without endpoint")
    }

    private static func actionErrors() throws {
        try expect(LocalActionErrorKind.mouseJiggler.title == "Mouse Jiggler Failed", "Jiggler has a connection title")
        try expect(LocalActionErrorKind.controlMode.title == "Control Mode Change Failed", "Mode has a connection title")
        try expect(LocalActionErrorKind.credentials.title == "Credentials Not Saved", "Credential warning changed")
        try expect(LocalActionErrorKind.connection.title == "Connection Failed", "Connection title changed")
    }

    @MainActor private static func preferencesBeforeMount() throws {
        let requests = LocalUIRequests()
        requests.requestSettings()
        try expect(requests.settingsRequested, "Request lost before view mount")
        try expect(requests.consumeSettingsRequest(), "Mounted view cannot consume request")
        try expect(!requests.settingsRequested && !requests.consumeSettingsRequest(), "Request repeated after consumption")
        requests.requestSettings()
        try expect(requests.consumeSettingsRequest(), "A later menu request is lost")
    }

    private static func settingsAccess() throws {
        try expect(LocalSettingsAccessPolicy.denialReason(mode: .manual, isConnected: true) == nil,
                   "Connected Manual cannot open Settings")
        try expect(LocalSettingsAccessPolicy.denialReason(mode: .manual, isConnected: false) ==
                   "Connect to the KVM before opening Settings.", "Disconnected request has no connection explanation")
        try expect(LocalSettingsAccessPolicy.denialReason(mode: .codexHeadless, isConnected: true) ==
                   "Switch to Manual before opening Settings.", "Headless request bypasses the Manual requirement")
        try expect(LocalSettingsAccessPolicy.denialReason(mode: .codexHeadless, isConnected: false) != nil,
                   "Disconnected Headless opens Settings")
        try expect(LocalActionErrorKind.settings.title == "Settings Unavailable", "Settings rejection has wrong operation title")
    }

    private static func expectFailure(_ host: String, port: String, expected: ManualEndpointError) throws {
        do {
            _ = try ManualConnectionEndpoint.parse(hostPort: host, port: port)
            throw Failure.message("Accepted \(host) with port \(port)")
        } catch let error as ManualEndpointError {
            try expect(error == expected, "Unexpected validation error: \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.message(message) }
    }

    private enum Failure: Error { case message(String) }
}
