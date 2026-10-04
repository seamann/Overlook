import Foundation

/// Registers a Janus response and its deadline before dispatching the request.
@MainActor
final class JanusRequestCoordinator {
    typealias Sleep = @MainActor (UInt64) async throws -> Void
    private let sleep: Sleep
    private struct PendingRequest {
        let id: UUID
        let continuation: CheckedContinuation<[String: Any], Error>
        let abortTransport: @MainActor () -> Void
        let cancellation: JanusRequestCancellation
        var timeoutTask: Task<Void, Never>?
        var sendTask: Task<Void, Never>?
    }
    private var pending: [String: PendingRequest] = [:]
    var pendingRequestCount: Int { pending.count }

    init(sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }) {
        self.sleep = sleep
    }

    func request(
        transaction: String, timeoutNanoseconds: UInt64, timeoutError: Error,
        send: @escaping @MainActor () async throws -> Void,
        abortTransport: @escaping @MainActor () -> Void
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard pending[transaction] == nil else { throw JanusRequestCoordinatorError.duplicateTransaction }
        let id = UUID()
        let cancellation = JanusRequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[transaction] = PendingRequest(
                    id: id, continuation: continuation, abortTransport: abortTransport,
                    cancellation: cancellation
                )
                pending[transaction]?.timeoutTask = Task { [weak self, sleep] in
                    do {
                        try await sleep(timeoutNanoseconds)
                        try Task.checkCancellation()
                    } catch { return }
                    self?.finish(transaction: transaction, id: id, result: .failure(timeoutError))
                }
                pending[transaction]?.sendTask = Task { [weak self] in
                    guard self?.pending[transaction]?.id == id else { return }
                    do {
                        try Task.checkCancellation()
                        guard cancellation.beginDispatch() else { throw CancellationError() }
                        try await send()
                    } catch {
                        self?.finish(transaction: transaction, id: id, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            // The synchronous mark covers cancellation while MainActor is still
            // registering the request, before its queued send/cancel tasks run.
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.finish(transaction: transaction, id: id, result: .failure(CancellationError()))
            }
        }
    }

    /// ACK only confirms dispatch; a success/error/event supplies the final answer.
    @discardableResult
    func receive(_ message: [String: Any]) -> Bool {
        guard let transaction = message["transaction"] as? String,
              let request = pending[transaction],
              let type = message["janus"] as? String else { return false }
        guard type != "ack" else { return true }
        finish(transaction: transaction, id: request.id, result: .success(message))
        return true
    }

    func cancelAll(throwing error: Error) {
        for (transaction, request) in pending {
            finish(transaction: transaction, id: request.id, result: .failure(error))
        }
    }

    private func finish(transaction: String, id: UUID, result: Result<[String: Any], Error>) {
        guard let request = pending[transaction], request.id == id else { return }
        pending.removeValue(forKey: transaction)
        request.timeoutTask?.cancel()
        let resolved = request.cancellation.isCancelled
            ? Result<[String: Any], Error>.failure(CancellationError()) : result
        if case .failure = resolved {
            request.sendTask?.cancel()
            // Task cancellation alone need not settle a native WebSocket send.
            // The caller closes only the transport captured for this request.
            request.abortTransport()
        }
        request.continuation.resume(with: resolved)
    }
}

enum JanusRequestCoordinatorError: Error {
    case duplicateTransaction
}

/// Cancellation callbacks are synchronous and may run away from MainActor.
/// A lock makes cancellation admission atomic with the send task's dispatch.
final class JanusRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func beginDispatch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
}

/// Debounce and keepalive completions belong to one generation and socket.
@MainActor
struct WebRTCConnectionTaskScope {
    let generation: Int
    private let socketID: ObjectIdentifier?

    init(generation: Int, socket: AnyObject?) {
        self.generation = generation
        socketID = socket.map(ObjectIdentifier.init)
    }

    func isCurrent(generation: Int, socket: AnyObject?) -> Bool {
        self.generation == generation && socketID == socket.map(ObjectIdentifier.init)
    }

    func run(
        afterNanoseconds: UInt64 = 0,
        sleep: @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        isCurrent: @MainActor () -> Bool,
        operation: @MainActor () async throws -> Void,
        onFailure: @MainActor (Error) -> Void
    ) async {
        do {
            if afterNanoseconds > 0 { try await sleep(afterNanoseconds) }
            try Task.checkCancellation()
            guard isCurrent() else { return }
            try await operation()
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, isCurrent() else { return }
            onFailure(error)
        }
    }
}
