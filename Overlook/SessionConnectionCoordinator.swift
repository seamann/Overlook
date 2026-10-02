import Foundation
import Combine

enum SessionConnectionError: Error, LocalizedError {
    case previousSessionCleanupFailed

    var errorDescription: String? {
        "The previous KVM session could not confirm HID disconnect. Try connecting again to retry cleanup."
    }
}

/// Owns connection attempts across all UI entry points. Preparation can overlap;
/// published state and remote HID transitions belong to one attempt at a time.
@MainActor
final class SessionConnectionCoordinator: ObservableObject {
    struct Dependencies {
        var prepare: @MainActor (KVMDevice, String?) async throws -> PreparedKVMConnection
        var commit: @MainActor (PreparedKVMConnection) -> KVMDevice
        var invalidateSession: @MainActor () -> Void
        var drainSession: @MainActor () async -> Void
        var installInput: @MainActor (GLKVMClient) -> Void
        var setHIDConnected: @MainActor (GLKVMClient, Bool) async throws -> Void
        var connectVideo: @MainActor (KVMDevice) async throws -> Void
        var setConnectionTransitioning: @MainActor (Bool) -> Void
        var reportTransportError: @MainActor (String, Error) -> Void = { phase, error in
            print("\(phase) session transition failed: \(error)")
        }
    }

    struct Attempt {
        let id: UInt64
        let task: Task<KVMDevice, Error>
    }

    @Published private(set) var isConnecting = false
    private let dependencies: Dependencies
    private var attemptGeneration: UInt64 = 0
    private var connectionTask: Task<KVMDevice, Error>?
    private var lifecycleTail: Task<Void, Error>?
    private var activeClient: GLKVMClient?
    private var cleanupClient: GLKVMClient?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func isCurrent(_ id: UInt64) -> Bool {
        attemptGeneration == id
    }

    @discardableResult
    func startConnection(to device: KVMDevice, password: String? = nil) -> Attempt {
        startConnection(deviceFactory: { device }, password: password)
    }

    /// Factory work (including a manual device's stored-token lookup) is inside
    /// the attempt, so its delayed completion cannot start another connection.
    @discardableResult
    func startConnection(
        deviceFactory: @escaping @MainActor () async throws -> KVMDevice,
        password: String? = nil
    ) -> Attempt {
        let id = invalidateAttempt()
        isConnecting = true
        dependencies.setConnectionTransitioning(true)
        let teardown = beginTeardown()
        let task = Task { @MainActor in
            defer { self.finishAttempt(id) }
            do {
                try self.checkAttempt(id)
                let device = try await deviceFactory()
                try self.checkAttempt(id)
                let prepared = try await self.dependencies.prepare(device, password)
                try self.checkAttempt(id)
                try await teardown.value
                try self.checkAttempt(id)
                return try await self.activate(prepared, attemptID: id)
            } catch {
                if !self.isCurrent(id) || Task.isCancelled || Self.isCancellation(error) {
                    if self.isCurrent(id) {
                        let cleanup = self.beginTeardown()
                        if case .failure(let cleanupError) = await cleanup.result,
                           self.isCurrent(id) {
                            self.dependencies.reportTransportError("HID disconnect", cleanupError)
                        }
                    }
                    throw CancellationError()
                }
                throw error
            }
        }
        connectionTask = task
        return Attempt(id: id, task: task)
    }

    /// Invalidates synchronously; the returned task settles already-sent HID
    /// operations and the old input transport without cancellation propagation.
    @discardableResult
    func disconnect() -> Task<Void, Never> {
        let id = invalidateAttempt()
        isConnecting = false
        dependencies.setConnectionTransitioning(true)
        let teardown = beginTeardown()
        return Task { @MainActor in
            do {
                try await teardown.value
            } catch {
                if self.isCurrent(id) { self.dependencies.reportTransportError("HID disconnect", error) }
            }
            guard self.isCurrent(id) else { return }
            self.dependencies.setConnectionTransitioning(false)
        }
    }

    private func invalidateAttempt() -> UInt64 {
        attemptGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        return attemptGeneration
    }

    private func beginTeardown() -> Task<Void, Error> {
        let previous = lifecycleTail
        let client = activeClient ?? cleanupClient
        activeClient = nil
        cleanupClient = client
        dependencies.invalidateSession()

        let teardown = Task { @MainActor in
            // Wait for settlement even if the prior transition failed. A new
            // explicit attempt may retry the retained cleanup client once.
            _ = await previous?.result
            await self.dependencies.drainSession()
            guard let client, self.cleanupClient === client else { return }
            do {
                try await self.dependencies.setHIDConnected(client, false)
            } catch {
                throw SessionConnectionError.previousSessionCleanupFailed
            }
            if self.cleanupClient === client { self.cleanupClient = nil }
        }
        lifecycleTail = teardown
        return teardown
    }

    private func activate(_ prepared: PreparedKVMConnection, attemptID: UInt64) async throws -> KVMDevice {
        try checkAttempt(attemptID)
        let connected = dependencies.commit(prepared)
        activeClient = prepared.client
        dependencies.installInput(prepared.client)

        // Keep the actual remote call outside the cancellable attempt. A later
        // teardown must observe its completion before issuing HID(false).
        let enable = Task { @MainActor in
            try await self.dependencies.setHIDConnected(prepared.client, true)
        }
        lifecycleTail = Task { _ = await enable.result }
        let enableResult = await enable.result
        try checkAttempt(attemptID)
        if case .failure(let error) = enableResult {
            dependencies.reportTransportError("HID connect", error)
        }

        do {
            try await dependencies.connectVideo(connected)
            try checkAttempt(attemptID)
        } catch {
            try checkAttempt(attemptID)
            if Self.isCancellation(error) { throw CancellationError() }
            dependencies.reportTransportError("WebRTC", error)
        }
        return connected
    }

    private func checkAttempt(_ id: UInt64) throws {
        try Task.checkCancellation()
        guard isCurrent(id) else { throw CancellationError() }
    }

    private func finishAttempt(_ id: UInt64) {
        guard isCurrent(id) else { return }
        connectionTask = nil
        isConnecting = false
        dependencies.setConnectionTransitioning(false)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
