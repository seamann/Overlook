import Foundation
import CoreVideo
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

private struct FrameDeliveryFailure: Error, CustomStringConvertible {
    let description: String
}

private final class RetainedFrame: @unchecked Sendable {
    let identifier: Int
    let buffer: CVPixelBuffer

    init(_ identifier: Int) throws {
        self.identifier = identifier
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw FrameDeliveryFailure(description: "Could not create native test frame") }
        self.buffer = buffer
    }
}

private final class WeakFrame {
    weak var value: RetainedFrame?
    init(_ value: RetainedFrame) { self.value = value }
}

#if canImport(WebRTC)
private final class WeakNativeBuffer {
    weak var value: AnyObject?
    init(_ buffer: CVPixelBuffer) { value = buffer }
}

@MainActor
private final class RenderedBatches {
    var values: [FrameDeliveryBatch<SnapshotFrame>] = []
}
#endif

private final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = 0

    func record(_ shouldSchedule: Bool) {
        guard shouldSchedule else { return }
        lock.lock()
        scheduled += 1
        lock.unlock()
    }

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduled
    }
}

@main
struct FrameDeliveryTests {
    static func main() async {
        var tests: [(String, () async throws -> Void)] = [
            ("slow consumer retains only the newest native buffer", testNativeBufferRetention),
            ("coalescing counts every frame for FPS", testCountsEveryFrame),
            ("arrival during processing wakes the next consumer", testArrivalsDuringConsumption),
            ("unsupported newest frame replaces earlier payload", testUnsupportedLatest),
            ("concurrent callbacks retain one pending frame", testConcurrentCallbacks),
            ("late timestamp cannot replace a newer frame", testTimestampOrdering),
            ("disconnect releases retained buffer and rejects callbacks", testInvalidation),
            ("invalid callback timestamps cannot affect health", testInvalidTimestamps),
            ("legacy callback queues retain the entire stalled burst", testLegacyRetentionMeasurement),
        ]
#if canImport(WebRTC)
        tests.append(("actual WebRTC renderer retains one native pending buffer", testNativeRenderer))
        tests.append(("actual renderer disconnect cancels queued delivery", testRendererInvalidation))
#endif
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("FrameDeliveryTests: \(tests.count - failures)/\(tests.count) passed")
        if failures > 0 { exit(1) }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FrameDeliveryFailure(description: message) }
    }

    private static func offerNativeBurst(_ delivery: LatestFrameDelivery<RetainedFrame>, count: Int) throws -> (weak: [WeakFrame], wakeups: Int) {
        var weakFrames: [WeakFrame] = []
        var wakeups = 0
        for identifier in 0..<count {
            let frame = try RetainedFrame(identifier)
            weakFrames.append(WeakFrame(frame))
            if delivery.offer(frame, receivedAt: 100 + Double(identifier) / 60) { wakeups += 1 }
        }
        return (weakFrames, wakeups)
    }

    private static func testNativeBufferRetention() async throws {
        let delivery = LatestFrameDelivery<RetainedFrame>()
        let burst = try offerNativeBurst(delivery, count: 120)
        let retained = burst.weak.filter { $0.value != nil }.count
        print("MEASURE bounded stalled consumer: \(retained) native buffers, \(burst.wakeups) wakeups for 120 arrivals")
        try check(retained == 1, "Stalled consumer retained \(retained) buffers instead of one")
        try check(burst.wakeups == 1, "Stalled consumer queued \(burst.wakeups) wakeups")
        let batch = delivery.take()
        try check(batch?.payload?.identifier == 119, "Consumer received a stale frame")
        try check(batch?.payload?.buffer === burst.weak.last?.value?.buffer, "Native pixel buffer was copied")
        try check(delivery.take() == nil, "Consumer had additional retained frames")
    }

    private static func testCountsEveryFrame() async throws {
        let delivery = LatestFrameDelivery<Int>()
        for identifier in 0..<120 { _ = delivery.offer(identifier, receivedAt: 100 + Double(identifier) / 60) }
        guard let batch = delivery.take() else { throw FrameDeliveryFailure(description: "Missing burst") }
        try check(batch.frameCount == 120, "FPS lost coalesced arrivals")
        try check(batch.firstReceivedAt == 100, "FPS window started at the delayed delivery time")
        try check(abs(batch.receivedAt - (100 + 119.0 / 60)) < 0.0001, "Health timestamp lost the newest arrival")
        let fps = Double(batch.frameCount) / (batch.receivedAt - batch.firstReceivedAt)
        try check(abs(fps - 60.5042) < 0.01, "FPS measures consumer dispatches instead of decoded frame arrivals")
    }

    private static func testArrivalsDuringConsumption() async throws {
        let delivery = LatestFrameDelivery<Int>()
        try check(delivery.offer(1, receivedAt: 1), "First frame did not wake consumer")
        let processing = delivery.take()
        try check(delivery.offer(2, receivedAt: 2), "Frame arriving during processing was stranded")
        try check(!delivery.offer(3, receivedAt: 3), "Second pending frame scheduled another wakeup")
        try check(processing?.payload == 1, "In-flight delivery changed")
        let next = delivery.take()
        try check(next?.payload == 3 && next?.frameCount == 2, "Pending delivery lost latest frame or FPS count")
        try check(delivery.take() == nil, "Empty delivery retained a wakeup")
        try check(delivery.offer(4, receivedAt: 4), "Drained delivery could not wake again")
    }

    private static func testUnsupportedLatest() async throws {
        let delivery = LatestFrameDelivery<Int>()
        _ = delivery.offer(1, receivedAt: 1)
        _ = delivery.offer(nil, receivedAt: 2)
        let batch = delivery.take()
        try check(batch?.payload == nil && batch?.receivedAt == 2 && batch?.frameCount == 2,
                  "Unsupported latest frame left an earlier supported snapshot visible")
    }

    private static func testConcurrentCallbacks() async throws {
        let delivery = LatestFrameDelivery<Int>()
        let recorder = CallbackRecorder()
        DispatchQueue.concurrentPerform(iterations: 2_000) { identifier in
            recorder.record(delivery.offer(identifier, receivedAt: Double(identifier)))
        }
        try check(recorder.scheduledCount == 1, "Concurrent callbacks scheduled more than one pending consumer")
        let batch = delivery.take()
        try check(batch?.frameCount == 2_000, "Concurrent callbacks lost arrivals")
        try check(batch?.payload == 1_999 && batch?.receivedAt == 1_999, "Callback lock order replaced newest timestamp with older frame")
    }

    private static func testTimestampOrdering() async throws {
        let delivery = LatestFrameDelivery<Int>()
        _ = delivery.offer(2, receivedAt: 2)
        _ = delivery.offer(1, receivedAt: 1)
        let batch = delivery.take()
        try check(batch?.payload == 2 && batch?.receivedAt == 2 && batch?.firstReceivedAt == 1 && batch?.frameCount == 2,
                  "Out-of-order callback regressed current frame or stream health")
    }

    private static func testInvalidation() async throws {
        let delivery = LatestFrameDelivery<RetainedFrame>()
        let burst = try offerNativeBurst(delivery, count: 3)
        delivery.invalidate()
        try check(burst.weak.allSatisfy { $0.value == nil }, "Disconnect retained a pending native frame")
        try check(delivery.take() == nil, "Scheduled old-source consumer returned a frame after disconnect")
        let lateFrame = try RetainedFrame(4)
        try check(!delivery.offer(lateFrame, receivedAt: 4), "Old renderer accepted a frame after disconnect")
        delivery.invalidate()
        try check(delivery.take() == nil, "Repeated disconnect revived delivery")
    }

    private static func testInvalidTimestamps() async throws {
        let delivery = LatestFrameDelivery<Int>()
        for timestamp in [Double.nan, Double.infinity, -Double.infinity] {
            try check(!delivery.offer(1, receivedAt: timestamp), "Non-finite timestamp accepted")
        }
        try check(delivery.take() == nil, "Invalid arrival poisoned pending frame")
        try check(delivery.offer(nil, receivedAt: 0), "Valid unsupported frame could not wake consumer")
    }

    // This deliberately stalled callback queue reproduces the prior production
    // closure: every queued MainActor task owned its received native buffer.
    private static func testLegacyRetentionMeasurement() async throws {
        var queuedCallbacks: [() -> Void] = []
        var weakFrames: [WeakFrame] = []
        for identifier in 0..<120 {
            let frame = try RetainedFrame(identifier)
            weakFrames.append(WeakFrame(frame))
            queuedCallbacks.append { _ = frame.buffer }
        }
        let retained = weakFrames.filter { $0.value != nil }.count
        print("MEASURE prior stalled callback queue: \(retained) native buffers, \(queuedCallbacks.count) callbacks for 120 arrivals")
        try check(retained == 120, "Legacy experiment did not retain the received buffers")
        queuedCallbacks.removeAll()
        try check(weakFrames.allSatisfy { $0.value == nil }, "Fixture kept buffers after draining the old queue")
    }

#if canImport(WebRTC)
    @MainActor
    private static func nativeRendererBurst(_ renderer: SnapshotVideoRenderer) throws -> [WeakNativeBuffer] {
        try (0..<120).map { identifier in
            try autoreleasepool {
                let frame = try RetainedFrame(identifier)
                let weakBuffer = WeakNativeBuffer(frame.buffer)
                renderer.renderFrame(RTCVideoFrame(
                    buffer: RTCCVPixelBuffer(pixelBuffer: frame.buffer),
                    rotation: ._0, timeStampNs: Int64(identifier)
                ))
                return weakBuffer
            }
        }
    }

    @MainActor
    private static func testNativeRenderer() async throws {
        let received = RenderedBatches()
        let sizeChanges = CallbackRecorder()
        let renderer = SnapshotVideoRenderer(sourceID: "test-source", onFrame: { received.values.append($0) }, onSize: { _ in sizeChanges.record(true) })
        renderer.renderFrame(nil)
        renderer.setSize(CGSize(width: 320, height: 180))
        try check(sizeChanges.scheduledCount == 1, "Actual renderer lost video geometry callback")
        let weakBuffers = try nativeRendererBurst(renderer)
        try check(received.values.isEmpty, "MainActor consumer ran inside its synchronous producer")
        let retained = weakBuffers.filter { $0.value != nil }.count
        print("MEASURE actual WebRTC renderer before MainActor drain: \(retained) native buffers for 120 callbacks")
        try check(retained == 1, "Actual renderer retained \(retained) pending native buffers")
        for _ in 0..<100 where received.values.isEmpty { await Task.yield() }
        try check(received.values.count == 1 && received.values.first?.frameCount == 120,
                  "Actual renderer lost coalesced FPS count or scheduled redundant consumers")
        try check(received.values.first?.payload?.sourceID == "test-source", "Actual renderer lost source identity")
        renderer.invalidate()
    }

    @MainActor
    private static func testRendererInvalidation() async throws {
        let received = RenderedBatches()
        let renderer = SnapshotVideoRenderer(sourceID: "old-source", onFrame: { received.values.append($0) }, onSize: { _ in })
        let weakBuffers = try nativeRendererBurst(renderer)
        renderer.invalidate()
        try check(weakBuffers.allSatisfy { $0.value == nil }, "Invalidated renderer retained pending native buffers")
        for _ in 0..<10 { await Task.yield() }
        try check(received.values.isEmpty, "Queued old renderer published after disconnect")
    }
#endif
}
