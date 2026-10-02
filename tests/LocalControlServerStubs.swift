// Test-only substitutes. Compile with the real LocalControlServer and policy
// sources, excluding the app's InputManager and WebRTCManager.
import Foundation
import Combine
import CoreVideo

@MainActor
final class FixtureLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class InputManager {
    enum RemoteTextInputError: Error {
        case notConnected, authorizationExpired, emptyText, invalidShortcut
    }

    var transportID = "fixture-transport"
    var controlEndpointID: String? = "fixture-endpoint"
    var inputBlocked = false
    var isLocalInputCaptureAllowed = false
    var activityStatus = "fixture ready"
    var hidStatus = "fixture connected"
    private(set) var dispatched: [RemoteActionCommand] = []
    var waitForCancellation = false
    var cleanupFails = false
    private(set) var cleanupStarted = false
    private(set) var cleanupCompleted = false
    let cleanup = FixtureLatch()

    func inputReadiness() async -> (text: Bool, mouse: Bool) {
        (!inputBlocked, !inputBlocked)
    }

    func performRemoteAction(
        _ action: RemoteActionCommand, width: Int, height: Int,
        authorization: @escaping @MainActor @Sendable () -> Bool,
        willDispatch: @escaping @MainActor @Sendable () throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !inputBlocked else { throw RemoteActionError.inputBlocked }
        guard authorization() else { throw RemoteTextInputError.authorizationExpired }
        try action.validate(width: width, height: height)
        try willDispatch()
        dispatched.append(action)
        guard waitForCancellation else { return }
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw RemoteActionError.internalError
        } catch {
            cleanupStarted = true
            // Deliberately ignores cancellation, like required release cleanup.
            await cleanup.wait()
            cleanupCompleted = true
            if cleanupFails {
                inputBlocked = true
                throw RemoteActionError.cleanupFailed
            }
            throw error
        }
    }

    func sendTextToRemote(
        _ text: String,
        authorization: @escaping @MainActor @Sendable () -> Bool,
        willDispatch: @escaping @MainActor @Sendable () throws -> Void = {}
    ) async throws {
        guard !text.isEmpty else { throw RemoteTextInputError.emptyText }
        try legacy(.text(text), authorization: authorization, willDispatch: willDispatch)
    }

    func sendCodexClick(
        signedX: Int, signedY: Int,
        authorization: @escaping @MainActor @Sendable () -> Bool,
        willDispatch: @escaping @MainActor @Sendable () throws -> Void = {}
    ) async throws {
        try legacy(.click(x: signedX, y: signedY), authorization: authorization, willDispatch: willDispatch)
    }

    func sendCodexShortcut(
        keys: [String],
        authorization: @escaping @MainActor @Sendable () -> Bool,
        willDispatch: @escaping @MainActor @Sendable () throws -> Void = {}
    ) async throws {
        try legacy(.shortcut(keys), authorization: authorization, willDispatch: willDispatch)
    }

    private func legacy(
        _ action: RemoteActionCommand,
        authorization: @MainActor @Sendable () -> Bool,
        willDispatch: @MainActor @Sendable () throws -> Void
    ) throws {
        try Task.checkCancellation()
        guard !inputBlocked else { throw RemoteActionError.inputBlocked }
        guard authorization() else { throw RemoteTextInputError.authorizationExpired }
        try willDispatch()
        dispatched.append(action)
    }
}

@MainActor
final class WebRTCManager {
    var snapshotSourceID = "fixture-source"
    var snapshotEndpointID: String? = "fixture-endpoint"
    var snapshotReady = true
    var frameAge: TimeInterval = 0
    var captureBarrier: FixtureLatch?
    private(set) var captureCount = 0

    func captureRemoteSnapshot(region: SnapshotRegion? = nil) async throws -> RemoteSnapshot {
        guard snapshotReady else { throw RemoteSnapshotError.notReady }
        captureCount += 1
        let source = snapshotSourceID
        let receivedAt = ProcessInfo.processInfo.systemUptime - frameAge
        if let captureBarrier { await captureBarrier.wait() }
        try Task.checkCancellation()
        let frame = SnapshotFrame(sourceID: source, receivedAt: receivedAt,
                                  rotationDegrees: 0, pixelBuffer: try Self.pixels())
        return try SnapshotPNGEncoder.encode(frame, region: region, limits: .standard)
    }

    private static func pixels() throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA,
                                  attributes, &output) == kCVReturnSuccess, let buffer = output else {
            throw RemoteSnapshotError.encodingFailed
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw RemoteSnapshotError.encodingFailed }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<24 {
            for x in 0..<32 {
                let offset = y * stride + x * 4
                bytes[offset] = UInt8(x * 7)
                bytes[offset + 1] = UInt8(y * 9)
                bytes[offset + 2] = 128
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }
}
