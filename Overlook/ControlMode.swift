import Foundation

enum OverlookControlMode: String, CaseIterable, Identifiable {
    case manual
    case codexHeadless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .codexHeadless: return "Headless"
        }
    }

    var showsObserverBadge: Bool { self == .codexHeadless }
}
