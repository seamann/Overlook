import Foundation
import Combine
import Network

struct ManualConnectionEndpoint: Equatable, Sendable {
    let host: String
    let port: Int

    static func parse(hostPort: String, port: String) throws -> Self {
        var authority = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        var portString = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = authority.range(of: "://") {
            let scheme = authority[..<schemeRange.lowerBound].lowercased()
            guard ["http", "https", "ws", "wss"].contains(scheme) else {
                throw ManualEndpointError.invalidHost
            }
            authority = String(authority[schemeRange.upperBound...])
        }
        guard !authority.isEmpty,
              authority.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@")) == nil else {
            throw ManualEndpointError.invalidHost
        }

        let host: String
        if authority.hasPrefix("[") {
            guard let closingBracket = authority.firstIndex(of: "]") else {
                throw ManualEndpointError.invalidHost
            }
            host = String(authority[...closingBracket])
            let suffix = authority[authority.index(after: closingBracket)...]
            guard IPv6Address(String(host.dropFirst().dropLast())) != nil else {
                throw ManualEndpointError.invalidHost
            }
            if !suffix.isEmpty {
                guard suffix.first == ":" else { throw ManualEndpointError.invalidHost }
                portString = String(suffix.dropFirst())
            }
        } else {
            guard authority.filter({ $0 == ":" }).count <= 1 else {
                throw ManualEndpointError.invalidHost
            }
            if let colon = authority.firstIndex(of: ":") {
                host = String(authority[..<colon])
                portString = String(authority[authority.index(after: colon)...])
            } else {
                host = authority
            }
            guard !host.isEmpty,
                  host.rangeOfCharacter(from: CharacterSet(charactersIn: "[]%\\")) == nil,
                  URLComponents(string: "https://\(host)")?.url != nil else {
                throw ManualEndpointError.invalidHost
            }
        }
        guard host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ManualEndpointError.invalidHost
        }
        guard !portString.isEmpty,
              portString.utf8.allSatisfy({ (48...57).contains($0) }),
              let portNumber = Int(portString), (1...65535).contains(portNumber) else {
            throw ManualEndpointError.invalidPort
        }
        return Self(host: host, port: portNumber)
    }
}

enum ManualEndpointError: Error, Equatable, LocalizedError {
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "Enter a host or IP address without credentials, a path, or query. Use brackets around IPv6 addresses."
        case .invalidPort: return "Enter a port from 1 to 65535 using digits only."
        }
    }
}

struct LocalRecoveryPresentation: Equatable, Sendable {
    let allowsRemoteInput: Bool
    let showsRecovery: Bool
    let canReconnect: Bool

    init(
        mode: OverlookControlMode,
        isVideoConnecting: Bool,
        isStreamStalled: Bool,
        hasEverConnectedToStream: Bool,
        isVideoConnected: Bool,
        hasDevice: Bool,
        isSessionConnecting: Bool,
        isPanelPresented: Bool
    ) {
        allowsRemoteInput = mode == .manual && !isPanelPresented
        showsRecovery = isVideoConnecting || isStreamStalled || (hasEverConnectedToStream && !isVideoConnected)
        canReconnect = hasDevice && !isPanelPresented && !isVideoConnecting && !isSessionConnecting
    }
}

enum InputRecoveryAction: Equatable, Sendable {
    case switchToManual, waitForConnection, reviewPreviousSession, reconnect, releaseInput
}

struct InputRecoveryPresentation: Equatable, Sendable {
    let action: InputRecoveryAction

    init(
        mode: OverlookControlMode, isConnected: Bool, isBusy: Bool,
        hasLiveVideo: Bool, hasRecoveryTransport: Bool,
        hasPendingCleanupReview: Bool, isLocalCaptureAllowed: Bool
    ) {
        if mode != .manual { action = .switchToManual }
        else if isBusy || !isLocalCaptureAllowed { action = .waitForConnection }
        else if hasPendingCleanupReview { action = .reviewPreviousSession }
        else if !isConnected || !hasLiveVideo || !hasRecoveryTransport { action = .reconnect }
        else { action = .releaseInput }
    }

    var buttonTitle: String? {
        switch action {
        case .switchToManual, .waitForConnection: return nil
        case .reviewPreviousSession: return "Alte Sitzung prüfen …"
        case .reconnect: return "Erneut verbinden"
        case .releaseInput: return "Eingabe nach Prüfung freigeben"
        }
    }

    var message: String {
        switch action {
        case .switchToManual:
            return "Für die eigene Prüfung zuerst in Manual wechseln."
        case .waitForConnection:
            return "Verbindung oder Freigabe läuft. Die Eingabe bleibt angehalten."
        case .reviewPreviousSession:
            return "Die alte KVM-Sitzung konnte nicht sauber getrennt werden. Prüfe den alten Zielrechner direkt, bevor du sie lokal abschließt."
        case .reconnect:
            return "Erst neu verbinden und das Remote-Bild prüfen. Danach kannst du die Eingabe freigeben."
        case .releaseInput:
            return "Prüfe das aktuelle Remote-Bild. Bereits übertragener Text wird nicht zurückgenommen."
        }
    }
}

enum InputRecoveryFailure: CaseIterable, Sendable {
    case transportUnavailable, sessionChanged, unauthorized, cancelled, releaseFailed

    var message: String {
        switch self {
        case .transportUnavailable:
            return "Die Eingabeverbindung ist nicht bereit. Bitte erneut verbinden."
        case .sessionChanged:
            return "Die Sitzung hat sich geändert. Prüfe die aktuelle Verbindung erneut."
        case .unauthorized:
            return "Die Freigabe ist nicht mehr gültig. Wechsle nach Manual und prüfe erneut."
        case .cancelled:
            return "Die Freigabe wurde abgebrochen. Die Eingabe bleibt gesperrt."
        case .releaseFailed:
            return "Die Eingabefreigabe konnte nicht übertragen werden. Erneut verbinden und den Remote-Zustand prüfen."
        }
    }
}

enum LocalConnectionAction: Equatable, Sendable {
    case connect(enabled: Bool)
    case cancel
    case disconnect

    init(isConnected: Bool, isConnecting: Bool, hasSelectedDevice: Bool) {
        if isConnecting { self = .cancel }
        else if isConnected { self = .disconnect }
        else { self = .connect(enabled: hasSelectedDevice) }
    }

    var isEnabled: Bool {
        if case .connect(let enabled) = self { return enabled }
        return true
    }
}

enum LocalActionErrorKind: Sendable {
    case connection, credentials, mouseJiggler, controlMode, endpoint, settings

    var title: String {
        switch self {
        case .connection: return "Connection Failed"
        case .credentials: return "Credentials Not Saved"
        case .mouseJiggler: return "Mouse Jiggler Failed"
        case .controlMode: return "Control Mode Change Failed"
        case .endpoint: return "Invalid Connection Address"
        case .settings: return "Settings Unavailable"
        }
    }
}

enum LocalSettingsAccessPolicy {
    static func denialReason(mode: OverlookControlMode, isConnected: Bool) -> String? {
        guard isConnected else { return "Connect to the KVM before opening Settings." }
        guard mode == .manual else { return "Switch to Manual before opening Settings." }
        return nil
    }
}

/// A local presentation request survives menu actions before the main view mounts.
/// It does not own connection or control-mode state.
@MainActor
final class LocalUIRequests: ObservableObject {
    @Published private(set) var settingsRequested = false

    func requestSettings() { settingsRequested = true }

    func consumeSettingsRequest() -> Bool {
        guard settingsRequested else { return false }
        settingsRequested = false
        return true
    }
}
