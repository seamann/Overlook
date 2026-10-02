import Foundation
import Combine

enum OverlookControlMode: String, CaseIterable, Identifiable, Sendable {
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

struct ControlModeSnapshot: Equatable, Sendable {
    let mode: OverlookControlMode
    let generation: Int
}

@MainActor
final class ControlModeStore: ObservableObject {
    static let defaultsKey = "overlook.controlMode"

    @Published private(set) var mode: OverlookControlMode
    private(set) var generation = 0
    private let defaults: UserDefaults?
    private var inputCaptureHandler: ((Bool) -> Void)?
    private var waitForRemoteMutations: @MainActor @Sendable () async -> Void = {}
    private var didResumeManualCapture: @MainActor @Sendable () async -> Void = {}
    private var manualCaptureTask: Task<Void, Never>?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        mode = .manual
        defaults?.set(OverlookControlMode.manual.rawValue, forKey: Self.defaultsKey)
    }

    var snapshot: ControlModeSnapshot {
        ControlModeSnapshot(mode: mode, generation: generation)
    }

    func configureInputCapture(
        _ handler: @escaping (Bool) -> Void,
        waitForRemoteMutations: @escaping @MainActor @Sendable () async -> Void = {},
        didResumeManualCapture: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        inputCaptureHandler = handler
        self.waitForRemoteMutations = waitForRemoteMutations
        self.didResumeManualCapture = didResumeManualCapture
        handler(mode != .codexHeadless)
    }

    @discardableResult
    func setMode(_ newMode: OverlookControlMode) -> Bool {
        guard mode != newMode else { return false }

        manualCaptureTask?.cancel()
        manualCaptureTask = nil
        if newMode == .codexHeadless {
            inputCaptureHandler?(false)
        }
        generation += 1
        mode = newMode
        defaults?.set(newMode.rawValue, forKey: Self.defaultsKey)
        if newMode == .manual {
            resumeManualCaptureIfNeeded()
        }
        return true
    }

    func resumeManualCaptureIfNeeded() {
        guard mode == .manual else { return }
        manualCaptureTask?.cancel()
        let targetSnapshot = snapshot
        let waitForRemoteMutations = waitForRemoteMutations
        let didResumeManualCapture = didResumeManualCapture
        manualCaptureTask = Task { [weak self] in
            await waitForRemoteMutations()
            guard !Task.isCancelled, let self, self.snapshot == targetSnapshot else { return }
            self.inputCaptureHandler?(true)
            await didResumeManualCapture()
            guard !Task.isCancelled, self.snapshot == targetSnapshot else { return }
            self.manualCaptureTask = nil
        }
    }
}
