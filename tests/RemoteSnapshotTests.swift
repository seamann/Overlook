import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
#if canImport(WebRTC)
import WebRTC
#endif

private struct SnapshotTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct RemoteSnapshotTests {
    @MainActor
    static func main() async {
        var tests: [(String, @MainActor () async throws -> Void)] = [
            ("strict region geometry", testRegionGeometry),
            ("native PNG and top-left crop", testPNGAndCrop),
            ("display orientation", testRotation),
            ("explicit output limits", testOutputLimits),
            ("capture requires ready source", testNotReady),
            ("only newer matching-source frames", testFreshFrame),
            ("timeout without cached-frame fallback", testTimeout),
            ("source change cancels waiter", testSourceChange),
            ("cancellation removes waiter", testCancellation),
            ("one capture at a time", testBusy),
            ("encoding off main actor", testDetachedEncoding),
            ("late encoding cannot cross source change", testLateEncoding),
            ("encoding deadline retains resource bound", testEncodingDeadline),
            ("unsupported native buffer reports failure", testUnsupportedFrame),
            ("source endpoint identity is atomic", testEndpointIdentity),
            ("replacement track rejects old callback", testReplacementTrack),
        ]
#if canImport(WebRTC)
        tests.append(("native WebRTC frame geometry", testNativeWebRTCFrame))
#endif
        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        print("RemoteSnapshotTests: \(tests.count - failures)/\(tests.count) passed")
        if failures != 0 { exit(1) }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw SnapshotTestFailure(description: message) }
    }

    private static func expectError(_ expected: RemoteSnapshotError, _ action: () throws -> Void) throws {
        do {
            try action()
            throw SnapshotTestFailure(description: "Expected \(expected.rawValue)")
        } catch let error as RemoteSnapshotError {
            try check(error == expected, "Expected \(expected), received \(error)")
        }
    }

    @MainActor
    private static func expectAsyncError(
        _ expected: RemoteSnapshotError,
        _ action: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await action()
            throw SnapshotTestFailure(description: "Expected \(expected.rawValue)")
        } catch let error as RemoteSnapshotError {
            try check(error == expected, "Expected \(expected), received \(error)")
        }
    }

    private static func testRegionGeometry() throws {
        let region = SnapshotRegion(x: 1, y: 2, width: 3, height: 4)
        try check(try region.validated(width: 8, height: 9) == region, "Valid ROI changed")
        try check(region.coreImageRect(fullHeight: 9) == CGRect(x: 1, y: 3, width: 3, height: 4), "Top-left transform incorrect")
        for invalid in [
            SnapshotRegion(x: -1, y: 0, width: 1, height: 1),
            SnapshotRegion(x: 0, y: 0, width: 0, height: 1),
            SnapshotRegion(x: 7, y: 0, width: 2, height: 1),
            SnapshotRegion(x: Int.max, y: 0, width: Int.max, height: 1),
            SnapshotRegion(x: 0, y: 9, width: 1, height: 1),
        ] {
            try expectError(.invalidRegion) { _ = try invalid.validated(width: 8, height: 9) }
        }
    }

    @MainActor
    private static func testEndpointIdentity() throws {
        let provider = RemoteSnapshotProvider()
        try check(provider.endpointID == nil, "Disconnected provider has an endpoint")
        let first = provider.sourceID
        provider.resetSource(endpointURL: URL(string: "https://SYNTHETIC.invalid/path"))
        try check(provider.endpointID == "synthetic.invalid:443", "Default HTTPS endpoint mismatch")
        try check(provider.sourceID != first, "New endpoint retained old source")
        provider.resetSource(endpointURL: URL(string: "http://synthetic.invalid:8080"))
        try check(provider.endpointID == "synthetic.invalid:8080", "Explicit port mismatch")
        try check(SnapshotEndpointIdentity.from(URL(string: "http://synthetic.invalid")!) == "synthetic.invalid:80", "Default HTTP mismatch")
        try check(SnapshotEndpointIdentity.from(URL(string: "file:///synthetic")!) == nil, "Local URL accepted")
        provider.resetSource()
        try check(provider.endpointID == nil, "Teardown retained endpoint")
    }

    @MainActor
    private static func testReplacementTrack() async throws {
        let provider = readyProvider()
        let oldTrackSource = provider.sourceID
        provider.resetSource(endpointURL: URL(string: "https://synthetic.invalid"))
        provider.setReady(true, sourceID: provider.sourceID)
        let capture = Task { try await provider.capture() }
        try await waitForRequest(provider)
        provider.receive(try frame(sourceID: oldTrackSource))
        try check(provider.isWaitingForFrame, "Old track callback satisfied replacement capture")
        let newFrame = try frame(sourceID: provider.sourceID)
        provider.receive(newFrame)
        try check(try await capture.value.frameID == newFrame.frameID, "Replacement returned old frame")
    }

    // Rows are top-to-bottom; values identify all six locations independently.
    private static let colors: [[UInt8]] = [
        [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255],
        [255, 255, 255, 255], [0, 0, 0, 255], [255, 255, 0, 255],
    ]

    private static func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard result == kCVReturnSuccess, let buffer else {
            throw SnapshotTestFailure(description: "Could not allocate test buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SnapshotTestFailure(description: "Missing test buffer base")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<2 {
            for x in 0..<3 {
                let color = colors[y * 3 + x]
                let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = color[2]; pixel[1] = color[1]; pixel[2] = color[0]; pixel[3] = color[3]
            }
        }
        return buffer
    }

    private static func frame(sourceID: String = "test-source", rotation: Int = 0, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> SnapshotFrame {
        SnapshotFrame(sourceID: sourceID, receivedAt: receivedAt, rotationDegrees: rotation, pixelBuffer: try pixelBuffer())
    }

    private static func rgbaPixels(_ data: Data) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SnapshotTestFailure(description: "Invalid PNG")
        }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try check(drawn, "Could not decode pixels")
        return (image.width, image.height, bytes)
    }

    private static func testPNGAndCrop() throws {
        let input = try frame(receivedAt: 123)
        let full = try SnapshotPNGEncoder.encode(input, region: nil, limits: .standard)
        let decoded = try rgbaPixels(full.pngData)
        try check(full.pngData.count > 28 && full.pngData[24] == 8 && full.pngData[28] == 0,
                  "PNG must remain 8-bit and non-interlaced for the MCP decoder")
        try check(full.width == 3 && full.height == 2 && full.receivedAt == 123, "Original metadata changed")
        try check(full.sourceID == input.sourceID && full.frameID == input.frameID, "Frame provenance changed")
        try check(decoded.bytes == colors.flatMap { $0 }, "Full PNG pixels changed")
        let roi = SnapshotRegion(x: 1, y: 0, width: 2, height: 1)
        let cropped = try SnapshotPNGEncoder.encode(input, region: roi, limits: .standard)
        let cropPixels = try rgbaPixels(cropped.pngData)
        try check(cropped.width == 3 && cropped.height == 2 && cropped.region == roi, "Crop lost original geometry")
        try check(cropPixels.width == 2 && cropPixels.height == 1, "Crop dimensions wrong")
        try check(cropPixels.bytes == colors[1] + colors[2], "Crop used bottom-left instead of top-left")
    }

#if canImport(WebRTC)
    private static func testNativeWebRTCFrame() throws {
        let buffer = try pixelBuffer()
        let original = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._90, timeStampNs: 42)
        let native = SnapshotNativeFrame.capture(original, sourceID: "synthetic-track", receivedAt: 123)
        try check(native?.sourceID == "synthetic-track" && native?.receivedAt == 123 && native?.rotationDegrees == 90,
                  "Actual WebRTC frame metadata changed")
        let adapted = RTCVideoFrame(buffer: RTCCVPixelBuffer(
            pixelBuffer: buffer, adaptedWidth: 1, adaptedHeight: 1,
            cropWidth: 2, cropHeight: 1, cropX: 1, cropY: 0
        ), rotation: ._0, timeStampNs: 43)
        try check(SnapshotNativeFrame.capture(adapted, sourceID: "synthetic-track", receivedAt: 124) == nil,
                  "Adapted WebRTC geometry was misrepresented as native pixels")
    }
#endif

    private static func testRotation() throws {
        let cases: [(Int, Int, Int, [Int])] = [
            (0, 3, 2, [0, 1, 2, 3, 4, 5]),
            (90, 2, 3, [3, 0, 4, 1, 5, 2]),
            (180, 3, 2, [5, 4, 3, 2, 1, 0]),
            (270, 2, 3, [2, 5, 1, 4, 0, 3]),
        ]
        for (rotation, width, height, order) in cases {
            let result = try SnapshotPNGEncoder.encode(try frame(rotation: rotation), region: nil, limits: .standard)
            let pixels = try rgbaPixels(result.pngData)
            try check(result.width == width && result.height == height && result.rotationDegrees == rotation, "Rotation metadata incorrect")
            try check(pixels.width == width && pixels.height == height, "Rotated PNG dimensions incorrect")
            try check(pixels.bytes == order.flatMap { colors[$0] }, "Clockwise rotation \(rotation) incorrect")
        }
        try expectError(.unsupportedRotation) {
            _ = try SnapshotPNGEncoder.encode(try frame(rotation: 45), region: nil, limits: .standard)
        }
    }

    private static func testOutputLimits() throws {
        try expectError(.pngTooLarge) {
            _ = try SnapshotPNGEncoder.encode(try frame(), region: nil, limits: SnapshotLimits(maximumPNGBytes: 1))
        }
        try expectError(.imageTooLarge) {
            _ = try SnapshotPNGEncoder.encode(try frame(), region: nil, limits: SnapshotLimits(maximumPixels: 5))
        }
        try expectError(.invalidRegion) {
            _ = try SnapshotPNGEncoder.encode(try frame(), region: SnapshotRegion(x: 3, y: 0, width: 1, height: 1), limits: .standard)
        }
    }

    @MainActor
    private static func readyProvider(limits: SnapshotLimits = .standard, encoder: @escaping RemoteSnapshotProvider.Encoder = { try SnapshotPNGEncoder.encode($0, region: $1, limits: $2) }) -> RemoteSnapshotProvider {
        let provider = RemoteSnapshotProvider(limits: limits, encoder: encoder)
        provider.setReady(true, sourceID: provider.sourceID)
        return provider
    }

    @MainActor
    private static func waitForRequest(_ provider: RemoteSnapshotProvider) async throws {
        for _ in 0..<1000 {
            if provider.isWaitingForFrame { return }
            await Task.yield()
        }
        throw SnapshotTestFailure(description: "Capture never started waiting")
    }

    @MainActor
    private static func testNotReady() async throws {
        let provider = RemoteSnapshotProvider()
        try await expectAsyncError(.notReady) { _ = try await provider.capture() }
    }

    @MainActor
    private static func testFreshFrame() async throws {
        let provider = readyProvider()
        provider.receive(try frame(sourceID: provider.sourceID))
        let capture = Task { try await provider.capture() }
        try await waitForRequest(provider)
        provider.receive(try frame(sourceID: "old-source"))
        provider.receive(try frame(sourceID: provider.sourceID, receivedAt: 1))
        try check(provider.isWaitingForFrame, "Old frame satisfied a fresh request")
        let valid = try frame(sourceID: provider.sourceID)
        provider.receive(valid)
        let result = try await capture.value
        try check(result.frameID == valid.frameID && result.receivedAt == valid.receivedAt, "Wrong frame accepted")
    }

    @MainActor
    private static func testTimeout() async throws {
        let provider = readyProvider(limits: SnapshotLimits(captureTimeoutNanoseconds: 20_000_000))
        provider.receive(try frame(sourceID: provider.sourceID))
        try await expectAsyncError(.timedOut) { _ = try await provider.capture() }
        try check(!provider.isWaitingForFrame, "Timed-out waiter retained")
    }

    @MainActor
    private static func testSourceChange() async throws {
        let provider = readyProvider()
        let oldSource = provider.sourceID
        let capture = Task { try await provider.capture() }
        try await waitForRequest(provider)
        provider.resetSource()
        try check(provider.sourceID != oldSource && !provider.isReady, "Teardown did not invalidate source")
        try await expectAsyncError(.sourceChanged) { _ = try await capture.value }
        provider.setReady(true, sourceID: oldSource)
        try check(!provider.isReady, "Late ready callback reactivated source")
    }

    @MainActor
    private static func testCancellation() async throws {
        let provider = readyProvider()
        let capture = Task { try await provider.capture() }
        try await waitForRequest(provider)
        capture.cancel()
        do {
            _ = try await capture.value
            throw SnapshotTestFailure(description: "Cancelled capture succeeded")
        } catch is CancellationError { }
        try check(!provider.isWaitingForFrame, "Cancelled waiter retained")
    }

    @MainActor
    private static func testBusy() async throws {
        let provider = readyProvider()
        let first = Task { try await provider.capture() }
        try await waitForRequest(provider)
        try await expectAsyncError(.busy) { _ = try await provider.capture() }
        first.cancel()
        _ = await first.result
    }

    @MainActor
    private static func testDetachedEncoding() async throws {
        let provider = readyProvider { input, region, limits in
            try check(!Thread.isMainThread, "PNG encoding ran on main thread")
            return try SnapshotPNGEncoder.encode(input, region: region, limits: limits)
        }
        let capture = Task { try await provider.capture() }
        try await waitForRequest(provider)
        provider.receive(try frame(sourceID: provider.sourceID))
        _ = try await capture.value
    }

    @MainActor
    private static func testLateEncoding() async throws {
        let gate = ControlledSnapshotEncoder()
        defer { gate.release() }
        let provider = readyProvider { try gate.encode($0, $1, $2) }
        let capture = Task { try await provider.capture() }
        try await waitForRequest(provider)
        provider.receive(try frame(sourceID: provider.sourceID))
        await gate.waitUntilStarted()
        provider.resetSource()
        try await expectAsyncError(.sourceChanged) { _ = try await capture.value }
        gate.release()
        await provider.waitForEncodingSettlement()
        try check(!provider.isReady && !provider.isWaitingForFrame, "Late encoding reactivated old source")
        provider.setReady(true, sourceID: provider.sourceID)
        let replacement = Task { try await provider.capture() }
        try await waitForRequest(provider)
        let freshFrame = try frame(sourceID: provider.sourceID)
        provider.receive(freshFrame)
        try check(try await replacement.value.frameID == freshFrame.frameID, "Encoder slot did not settle for replacement source")
    }

    @MainActor
    private static func testEncodingDeadline() async throws {
        let limits = SnapshotLimits(encodingTimeoutNanoseconds: 10_000_000)
        let gate = ControlledSnapshotEncoder()
        defer { gate.release() }
        let provider = readyProvider(limits: limits) { try gate.encode($0, $1, $2) }
        let capture = Task { try await provider.capture() }
        try await waitForRequest(provider)
        provider.receive(try frame(sourceID: provider.sourceID))
        await gate.waitUntilStarted()
        try await expectAsyncError(.encodingTimedOut) { _ = try await capture.value }
        try await expectAsyncError(.busy) { _ = try await provider.capture() }
        gate.release()
        await provider.waitForEncodingSettlement()
        let replacement = Task { try await provider.capture() }
        try await waitForRequest(provider)
        // Starting a new waiter proves slot release. Encoding that request under
        // the deliberately tiny deadline would test scheduler speed instead.
        replacement.cancel()
        do {
            _ = try await replacement.value
            throw SnapshotTestFailure(description: "Cancelled replacement capture succeeded")
        } catch is CancellationError { }
    }

    @MainActor
    private static func testUnsupportedFrame() async throws {
        let provider = readyProvider()
        let capture = Task { try await provider.capture() }
        try await waitForRequest(provider)
        provider.receiveUnsupportedFrame(sourceID: provider.sourceID, receivedAt: ProcessInfo.processInfo.systemUptime)
        try await expectAsyncError(.unsupportedPixelBuffer) { _ = try await capture.value }
    }
}

// NSCondition protects the release state; NSLock protects the async start signal.
// The synchronous encoder intentionally ignores cancellation while gated, matching
// ImageIO work that can outlive the capture deadline. No scheduler delay is assumed.
private final class ControlledSnapshotEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseCondition = NSCondition()
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func encode(_ input: SnapshotFrame, _ region: SnapshotRegion?, _ limits: SnapshotLimits) throws -> RemoteSnapshot {
        let snapshot: RemoteSnapshot
        do {
            snapshot = try SnapshotPNGEncoder.encode(input, region: region, limits: limits)
        } catch {
            signalStarted()
            throw error
        }
        signalStarted()
        releaseCondition.lock()
        while !released { releaseCondition.wait() }
        releaseCondition.unlock()
        return snapshot
    }

    private func signalStarted() {
        lock.lock()
        started = true
        let waiters = startWaiters
        startWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func release() {
        releaseCondition.lock()
        released = true
        releaseCondition.broadcast()
        releaseCondition.unlock()
    }
}
