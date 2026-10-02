import Foundation

@main
struct ControlModeTests {
    static func main() async {
        precondition(!OverlookControlMode.manual.showsObserverBadge)
        precondition(OverlookControlMode.codexHeadless.showsObserverBadge)
        precondition(OverlookControlMode(rawValue: "codexHeadless") == .codexHeadless)

        await MainActor.run {
            let suiteName = "ControlModeTests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated defaults")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let store = ControlModeStore(defaults: defaults)
            precondition(store.mode == .manual)
            precondition(store.snapshot == ControlModeSnapshot(mode: .manual, generation: 0))

            var captureTransitions: [(Bool, OverlookControlMode)] = []
            store.configureInputCapture { allowed in
                captureTransitions.append((allowed, store.mode))
            }
            precondition(captureTransitions.count == 1)
            precondition(captureTransitions[0].0)
            precondition(captureTransitions[0].1 == .manual)

            precondition(store.setMode(.codexHeadless))
            precondition(store.mode == .codexHeadless)
            precondition(store.snapshot == ControlModeSnapshot(mode: .codexHeadless, generation: 1))
            precondition(captureTransitions.count == 2)
            precondition(!captureTransitions[1].0)
            precondition(captureTransitions[1].1 == .manual)
            precondition(defaults.string(forKey: ControlModeStore.defaultsKey) == "codexHeadless")
            precondition(!store.setMode(.codexHeadless))
            precondition(store.snapshot.generation == 1)

            let restartedStore = ControlModeStore(defaults: defaults)
            precondition(restartedStore.mode == .manual)
            precondition(defaults.string(forKey: ControlModeStore.defaultsKey) == "manual")
        }
        await testManualCaptureWaitsForRemoteMutationsToDrain()
        print("ControlModeTests passed")
    }

    private static func testManualCaptureWaitsForRemoteMutationsToDrain() async {
        let suiteName = "ControlModeTests.Drain.\(UUID().uuidString)"
        let barrier = ManualTransitionBarrier()
        let setup = await MainActor.run { () -> (ControlModeStore, CaptureRecorder) in
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Could not create isolated defaults")
            }
            let store = ControlModeStore(defaults: defaults)
            let recorder = CaptureRecorder()
            store.configureInputCapture(
                { allowed in recorder.values.append(allowed) },
                waitForRemoteMutations: { await barrier.wait() }
            )
            precondition(store.setMode(.codexHeadless))
            precondition(store.setMode(.manual))
            precondition(store.mode == .manual)
            precondition(store.snapshot == ControlModeSnapshot(mode: .manual, generation: 2))
            precondition(recorder.values == [true, false])
            return (store, recorder)
        }

        await barrier.release()
        for _ in 0..<100 {
            if await MainActor.run(body: { setup.1.values == [true, false, true] }) {
                break
            }
            await Task.yield()
        }
        await MainActor.run {
            precondition(setup.1.values == [true, false, true])
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }
}

@MainActor
private final class CaptureRecorder {
    var values: [Bool] = []
}

private actor ManualTransitionBarrier {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
