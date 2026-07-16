import Foundation

@main
struct ControlModeTests {
    static func main() {
        precondition(!OverlookControlMode.manual.showsObserverBadge)
        precondition(OverlookControlMode.codexHeadless.showsObserverBadge)
        precondition(OverlookControlMode(rawValue: "codexHeadless") == .codexHeadless)
        print("ControlModeTests passed")
    }
}
