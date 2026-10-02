import Foundation
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#if canImport(WebRTC)
import WebRTC

enum SnapshotNativeFrame {
    static func capture(_ frame: RTCVideoFrame, sourceID: String, receivedAt: TimeInterval) -> SnapshotFrame? {
        guard let native = frame.buffer as? RTCCVPixelBuffer,
              !native.requiresCropping(),
              Int(frame.width) == CVPixelBufferGetWidth(native.pixelBuffer),
              Int(frame.height) == CVPixelBufferGetHeight(native.pixelBuffer) else { return nil }
        return SnapshotFrame(
            sourceID: sourceID, receivedAt: receivedAt,
            rotationDegrees: Int(frame.rotation.rawValue), pixelBuffer: native.pixelBuffer
        )
    }
}
#endif

enum SnapshotEndpointIdentity {
    /// Internal comparison only. Never include this value in a control response.
    static func from(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        return "\(host):\(port)"
    }
}

struct SnapshotRegion: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    func validated(width: Int, height: Int) throws -> SnapshotRegion {
        guard width > 0, height > 0, x >= 0, y >= 0,
              self.width > 0, self.height > 0,
              x < width, y < height,
              self.width <= width - x, self.height <= height - y else {
            throw RemoteSnapshotError.invalidRegion
        }
        return self
    }

    // Call only after validation against the original, oriented frame geometry.
    func coreImageRect(fullHeight: Int) -> CGRect {
        CGRect(x: x, y: fullHeight - y - height, width: width, height: height)
    }
}

struct RemoteSnapshot: Sendable {
    let sourceID: String
    let frameID: String
    let receivedAt: TimeInterval
    let width: Int
    let height: Int
    let region: SnapshotRegion
    let rotationDegrees: Int
    let pngData: Data
}

enum RemoteSnapshotError: String, Error, LocalizedError, Sendable {
    case notReady = "snapshot_not_ready"
    case busy = "snapshot_busy"
    case sourceChanged = "snapshot_source_changed"
    case timedOut = "snapshot_timed_out"
    case encodingTimedOut = "snapshot_encoding_timed_out"
    case invalidRegion = "snapshot_invalid_region"
    case unsupportedRotation = "snapshot_unsupported_rotation"
    case unsupportedPixelBuffer = "snapshot_unsupported_pixel_buffer"
    case imageTooLarge = "snapshot_image_too_large"
    case pngTooLarge = "snapshot_png_too_large"
    case encodingFailed = "snapshot_encoding_failed"

    var errorDescription: String? { rawValue }
}

struct SnapshotLimits: Sendable {
    static let standard = SnapshotLimits()
    let maximumPixels: Int
    let maximumPNGBytes: Int
    let captureTimeoutNanoseconds: UInt64
    let encodingTimeoutNanoseconds: UInt64

    init(
        maximumPixels: Int = 8_000_000,
        maximumPNGBytes: Int = 4 * 1024 * 1024,
        captureTimeoutNanoseconds: UInt64 = 2_000_000_000,
        encodingTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.maximumPixels = maximumPixels
        self.maximumPNGBytes = maximumPNGBytes
        self.captureTimeoutNanoseconds = captureTimeoutNanoseconds
        self.encodingTimeoutNanoseconds = encodingTimeoutNanoseconds
    }
}

// The retained video buffer is read-only for the lifetime of this envelope.
struct SnapshotFrame: @unchecked Sendable {
    let sourceID: String
    let frameID = UUID().uuidString
    let receivedAt: TimeInterval
    let rotationDegrees: Int
    let pixelBuffer: CVPixelBuffer
}

enum SnapshotPNGEncoder {
    static func encode(_ frame: SnapshotFrame, region: SnapshotRegion?, limits: SnapshotLimits) throws -> RemoteSnapshot {
        try Task.checkCancellation()
        let buffer = frame.pixelBuffer
        let rawWidth = CVPixelBufferGetWidth(buffer)
        let rawHeight = CVPixelBufferGetHeight(buffer)
        guard rawWidth > 0, rawHeight > 0, limits.maximumPixels > 0,
              rawWidth <= limits.maximumPixels / rawHeight else {
            throw RemoteSnapshotError.imageTooLarge
        }
        guard supportedPixelFormats.contains(CVPixelBufferGetPixelFormatType(buffer)) else {
            throw RemoteSnapshotError.unsupportedPixelBuffer
        }
        let orientation = try imageOrientation(rotationDegrees: frame.rotationDegrees)
        let oriented = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let original = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.origin.x, y: -oriented.extent.origin.y
        ))
        let width = Int(original.extent.width)
        let height = Int(original.extent.height)
        let requested = region ?? SnapshotRegion(x: 0, y: 0, width: width, height: height)
        let validRegion = try requested.validated(width: width, height: height)
        let pngData = try png(original, rect: validRegion.coreImageRect(fullHeight: height), limits: limits)
        return RemoteSnapshot(
            sourceID: frame.sourceID, frameID: frame.frameID, receivedAt: frame.receivedAt,
            width: width, height: height, region: validRegion,
            rotationDegrees: frame.rotationDegrees, pngData: pngData
        )
    }

    private static let supportedPixelFormats: Set<OSType> = [
        kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

    private static func imageOrientation(rotationDegrees: Int) throws -> CGImagePropertyOrientation {
        switch rotationDegrees {
        case 0: return .up
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: throw RemoteSnapshotError.unsupportedRotation
        }
    }

    private static func png(_ image: CIImage, rect: CGRect, limits: SnapshotLimits) throws -> Data {
        try Task.checkCancellation()
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let raster = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
            throw RemoteSnapshotError.encodingFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw RemoteSnapshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, raster, nil)
        guard CGImageDestinationFinalize(destination) else { throw RemoteSnapshotError.encodingFailed }
        try Task.checkCancellation()
        guard output.length <= limits.maximumPNGBytes else { throw RemoteSnapshotError.pngTooLarge }
        return output as Data
    }
}

@MainActor
final class RemoteSnapshotProvider {
    typealias Encoder = @Sendable (SnapshotFrame, SnapshotRegion?, SnapshotLimits) throws -> RemoteSnapshot
    private(set) var sourceID = UUID().uuidString
    private(set) var endpointID: String?
    private(set) var isReady = false
    var isWaitingForFrame: Bool { request != nil && encodingTask == nil }
    private let limits: SnapshotLimits
    private let encoder: Encoder
    private var request: PendingCapture?
    private var deadlineTask: Task<Void, Never>?
    private var encodingTask: Task<Void, Never>?
    private var encodingID: UUID?

    private struct PendingCapture {
        let id: UUID
        let sourceID: String
        let requestedAt: TimeInterval
        let region: SnapshotRegion?
        let continuation: CheckedContinuation<RemoteSnapshot, Error>
    }

    init(
        limits: SnapshotLimits = .standard,
        encoder: @escaping Encoder = { try SnapshotPNGEncoder.encode($0, region: $1, limits: $2) }
    ) {
        self.limits = limits
        self.encoder = encoder
    }

    func resetSource(endpointURL: URL? = nil) {
        sourceID = UUID().uuidString
        endpointID = endpointURL.flatMap(SnapshotEndpointIdentity.from)
        isReady = false
        failCurrentRequest(.sourceChanged)
    }

    func setReady(_ ready: Bool, sourceID: String) {
        guard sourceID == self.sourceID else { return }
        isReady = ready
        if !ready { failCurrentRequest(.notReady) }
    }

    func receive(_ frame: SnapshotFrame) {
        guard let request = matchingRequest(sourceID: frame.sourceID, receivedAt: frame.receivedAt) else { return }
        startEncoding(frame, request: request)
    }

    func receiveUnsupportedFrame(sourceID: String, receivedAt: TimeInterval) {
        guard matchingRequest(sourceID: sourceID, receivedAt: receivedAt) != nil else { return }
        failCurrentRequest(.unsupportedPixelBuffer)
    }

    func capture(region: SnapshotRegion? = nil) async throws -> RemoteSnapshot {
        try Task.checkCancellation()
        guard isReady else { throw RemoteSnapshotError.notReady }
        guard request == nil, encodingTask == nil else { throw RemoteSnapshotError.busy }
        let id = UUID()
        let requestedAt = ProcessInfo.processInfo.systemUptime
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                request = PendingCapture(
                    id: id, sourceID: sourceID, requestedAt: requestedAt,
                    region: region, continuation: continuation
                )
                scheduleDeadline(id: id, nanoseconds: limits.captureTimeoutNanoseconds, error: .timedOut)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, result: .failure(CancellationError()))
            }
        }
    }

    private func matchingRequest(sourceID: String, receivedAt: TimeInterval) -> PendingCapture? {
        guard isReady, isWaitingForFrame, let request,
              sourceID == self.sourceID, sourceID == request.sourceID,
              receivedAt.isFinite, receivedAt > request.requestedAt else { return nil }
        return request
    }

    private func startEncoding(_ frame: SnapshotFrame, request: PendingCapture) {
        let encoder = encoder
        let limits = limits
        encodingID = request.id
        scheduleDeadline(id: request.id, nanoseconds: limits.encodingTimeoutNanoseconds, error: .encodingTimedOut)
        encodingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<RemoteSnapshot, Error>
            do {
                try Task.checkCancellation()
                result = .success(try encoder(frame, request.region, limits))
            } catch {
                result = .failure(error)
            }
            await self?.encodingFinished(id: request.id, result: result)
        }
    }

    private func encodingFinished(id: UUID, result: Result<RemoteSnapshot, Error>) {
        guard encodingID == id else { return }
        encodingTask = nil
        encodingID = nil
        guard let request, request.id == id else { return }
        guard isReady, request.sourceID == sourceID else {
            finish(id: id, result: .failure(RemoteSnapshotError.sourceChanged))
            return
        }
        finish(id: id, result: result)
    }

    private func scheduleDeadline(id: UUID, nanoseconds: UInt64, error: RemoteSnapshotError) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            guard !Task.isCancelled else { return }
            self?.finish(id: id, result: .failure(error))
        }
    }

    private func failCurrentRequest(_ error: RemoteSnapshotError) {
        if let request { finish(id: request.id, result: .failure(error)) }
    }

    private func finish(id: UUID, result: Result<RemoteSnapshot, Error>) {
        guard let pending = request, pending.id == id else { return }
        request = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        if case .failure = result { encodingTask?.cancel() }
        // Keep the encoder slot occupied until synchronous ImageIO work really ends.
        pending.continuation.resume(with: result)
    }
}
