import Foundation

struct FrameDeliveryBatch<Payload: Sendable>: Sendable {
    let payload: Payload?
    let firstReceivedAt: TimeInterval
    let receivedAt: TimeInterval
    let frameCount: Int
}

final class LatestFrameDelivery<Payload: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: FrameDeliveryBatch<Payload>?
    private var invalidated = false

    /// True grants the caller one consumer wakeup. A stalled consumer owns
    /// only the latest payload; all arrivals still contribute to its FPS count.
    func offer(_ payload: Payload?, receivedAt: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated, receivedAt.isFinite else { return false }
        if let previous = pending {
            let newest = receivedAt >= previous.receivedAt
            pending = FrameDeliveryBatch(
                payload: newest ? payload : previous.payload,
                firstReceivedAt: min(previous.firstReceivedAt, receivedAt),
                receivedAt: max(previous.receivedAt, receivedAt),
                frameCount: previous.frameCount + 1
            )
            return false
        }
        pending = FrameDeliveryBatch(payload: payload, firstReceivedAt: receivedAt, receivedAt: receivedAt, frameCount: 1)
        return true
    }

    /// Clearing the pending slot also returns wakeup ownership to producers.
    /// A frame arriving during consumption gets exactly one subsequent wakeup.
    func take() -> FrameDeliveryBatch<Payload>? {
        lock.lock()
        defer { lock.unlock() }
        let batch = pending
        pending = nil
        return batch
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidated = true
        pending = nil
    }
}

struct StreamStatsRequest: Sendable {
    let generation: Int
    let requestID = UUID()
    let videoPeerID: ObjectIdentifier
    let audioPeerID: ObjectIdentifier?

    init(generation: Int, videoPeer: AnyObject, audioPeer: AnyObject?) {
        self.generation = generation
        videoPeerID = ObjectIdentifier(videoPeer)
        audioPeerID = audioPeer.map(ObjectIdentifier.init)
    }

    func isCurrent(generation: Int, requestID: UUID?, videoPeer: AnyObject?, audioPeer: AnyObject?) -> Bool {
        generation == self.generation && requestID == self.requestID &&
            videoPeer.map(ObjectIdentifier.init) == videoPeerID &&
            audioPeer.map(ObjectIdentifier.init) == audioPeerID
    }
}

#if canImport(WebRTC)
@preconcurrency import WebRTC

/// Each renderer keeps the identity of the track to which it was attached.
/// A late callback can never acquire the identity of a newer connection.
final class SnapshotVideoRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let sourceID: String
    private let delivery = LatestFrameDelivery<SnapshotFrame>()
    private let onFrame: @MainActor @Sendable (FrameDeliveryBatch<SnapshotFrame>) -> Void
    private let onSize: @Sendable (CGSize) -> Void

    init(
        sourceID: String,
        onFrame: @escaping @MainActor @Sendable (FrameDeliveryBatch<SnapshotFrame>) -> Void,
        onSize: @escaping @Sendable (CGSize) -> Void
    ) {
        self.sourceID = sourceID
        self.onFrame = onFrame
        self.onSize = onSize
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let receivedAt = ProcessInfo.processInfo.systemUptime
        let captured = SnapshotNativeFrame.capture(frame, sourceID: sourceID, receivedAt: receivedAt)
        guard delivery.offer(captured, receivedAt: receivedAt) else { return }
        Task { @MainActor [weak self] in
            guard let self, let batch = self.delivery.take() else { return }
            self.onFrame(batch)
        }
    }

    func invalidate() {
        delivery.invalidate()
    }

    func setSize(_ size: CGSize) {
        onSize(size)
    }
}

#endif
