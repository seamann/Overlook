import Foundation
import CoreFoundation
import CryptoKit

enum RemoteActionError: String, Error, LocalizedError, Sendable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case headlessRequired = "headless_required"
    case inputUnavailable = "input_unavailable"
    case inputBlocked = "input_blocked"
    case sessionChanged = "session_changed"
    case staleFrame = "stale_frame"
    case actionConflict = "action_conflict"
    case actionExpired = "action_expired"
    case actionUnknown = "action_unknown"
    case queueFull = "queue_full"
    case cancelled
    case cleanupFailed = "cleanup_failed"
    case transportError = "transport_error"
    case internalError = "internal_error"

    var errorDescription: String? { rawValue }
}

enum RemoteActionPhase: String, Sendable {
    case queued, running, transmitted
    case notStarted = "not_started"
    case outcomeUnknown = "outcome_unknown"

    var isTerminal: Bool { self != .queued && self != .running }
}

enum RemoteActionCommand: Equatable, Sendable {
    case click(x: Int, y: Int)
    case scroll(x: Int, y: Int, deltaY: Int)
    case drag(x: Int, y: Int, toX: Int, toY: Int, durationMS: Int)
    case text(String)
    case shortcut([String])

    static let maximumTextBytes = 256 * 1024
    static let maximumSequence = 9_007_199_254_740_990
    static let shortcutKeys: Set<String> = [
        "ControlLeft", "ShiftLeft", "AltLeft", "MetaLeft", "KeyA", "KeyC", "KeyV", "KeyX", "KeyZ",
        "Enter", "Escape", "Tab", "Backspace", "Delete", "Home", "End",
        "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"
    ]

    static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) <= Double(maximumSequence) else { throw RemoteActionError.invalidRequest }
        return number.intValue
    }

    static func parse(_ value: [String: Any]) throws -> Self {
        guard let type = value["type"] as? String else { throw RemoteActionError.invalidRequest }
        let expected: Set<String>
        switch type {
        case "click": expected = ["type", "x", "y"]
        case "scroll": expected = ["type", "x", "y", "delta_y"]
        case "drag": expected = ["type", "x", "y", "to_x", "to_y", "duration_ms"]
        case "text": expected = ["type", "value"]
        case "shortcut": expected = ["type", "keys"]
        default: throw RemoteActionError.invalidRequest
        }
        guard Set(value.keys) == expected else { throw RemoteActionError.invalidRequest }
        if type == "text" {
            guard let text = value["value"] as? String, !text.isEmpty,
                  text.utf8.count <= maximumTextBytes else { throw RemoteActionError.invalidRequest }
            return .text(text)
        }
        if type == "shortcut" {
            guard let keys = value["keys"] as? [String], (1...4).contains(keys.count),
                  Set(keys).count == keys.count, keys.allSatisfy(shortcutKeys.contains) else {
                throw RemoteActionError.invalidRequest
            }
            return .shortcut(keys)
        }
        let x = try integer(value["x"]), y = try integer(value["y"])
        guard (0..<16_384).contains(x), (0..<16_384).contains(y) else { throw RemoteActionError.invalidRequest }
        if type == "click" { return .click(x: x, y: y) }
        if type == "scroll" {
            let delta = try integer(value["delta_y"])
            guard (-10...10).contains(delta), delta != 0 else { throw RemoteActionError.invalidRequest }
            return .scroll(x: x, y: y, deltaY: delta)
        }
        let toX = try integer(value["to_x"]), toY = try integer(value["to_y"])
        let duration = try integer(value["duration_ms"])
        guard (0..<16_384).contains(toX), (0..<16_384).contains(toY), (100...2000).contains(duration) else {
            throw RemoteActionError.invalidRequest
        }
        return .drag(x: x, y: y, toX: toX, toY: toY, durationMS: duration)
    }

    func validate(width: Int, height: Int) throws {
        guard (2...16_384).contains(width), (2...16_384).contains(height) else { throw RemoteActionError.invalidRequest }
        let points: [(Int, Int)]
        switch self {
        case .click(let x, let y), .scroll(let x, let y, _): points = [(x, y)]
        case .drag(let x, let y, let toX, let toY, _): points = [(x, y), (toX, toY)]
        case .text, .shortcut: points = []
        }
        guard points.allSatisfy({ (0..<width).contains($0.0) && (0..<height).contains($0.1) }) else {
            throw RemoteActionError.invalidRequest
        }
    }

    static func signedHID(pixel: Int, extent: Int) -> Int {
        Int((-32_767 + Double(pixel) * 65_534 / Double(extent - 1)).rounded())
    }

    func digest(frameID: String) -> String {
        var fields: [String: Any] = ["frame_id": frameID]
        switch self {
        case .click(let x, let y): fields.merge(["type": "click", "x": x, "y": y]) { _, new in new }
        case .scroll(let x, let y, let delta):
            fields.merge(["type": "scroll", "x": x, "y": y, "delta_y": delta]) { _, new in new }
        case .drag(let x, let y, let toX, let toY, let duration):
            fields.merge(["type": "drag", "x": x, "y": y, "to_x": toX, "to_y": toY, "duration_ms": duration]) { _, new in new }
        case .text(let value): fields.merge(["type": "text", "value": value]) { _, new in new }
        case .shortcut(let keys): fields.merge(["type": "shortcut", "keys": keys]) { _, new in new }
        }
        // All entries above are JSON primitives created by validated cases.
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct RemoteObservedFrame: Sendable {
    let id: String
    let width: Int
    let height: Int
    let receivedAt: TimeInterval
    let mutationGeneration: UInt64
}

struct RemoteActionRecord: Sendable {
    let digest: String
    var state: RemoteActionPhase = .queued
    var didDispatch = false
    var error: RemoteActionError?
}

@MainActor
final class RemoteActionLedger {
    private let bootID: String
    private let maximumRecords: Int
    private let frameTTL: TimeInterval
    private var identity = ""
    private(set) var sessionID = ""
    private(set) var highwater = 0
    private(set) var mutationGeneration: UInt64 = 0
    private var latestFrame: RemoteObservedFrame?
    private var records: [Int: RemoteActionRecord] = [:]
    private var retired: [String: [Int: RemoteActionRecord]] = [:]
    private var retiredOrder: [String] = []

    init(maximumRecords: Int = 64, frameTTL: TimeInterval = 30, bootID: String = UUID().uuidString) {
        self.maximumRecords = max(1, maximumRecords)
        self.frameTTL = max(0.001, frameTTL)
        self.bootID = bootID
    }

    var nextActionSequence: Int { min(highwater + 1, RemoteActionCommand.maximumSequence) }

    @discardableResult
    func synchronize(sourceID: String, transportID: String, modeGeneration: Int) -> String {
        let newIdentity = "\(bootID)|\(sourceID)|\(transportID)|\(modeGeneration)"
        if identity != newIdentity {
            if !sessionID.isEmpty, !records.isEmpty {
                retired[sessionID] = records
                retiredOrder.append(sessionID)
                while retiredOrder.count > 2 { retired.removeValue(forKey: retiredOrder.removeFirst()) }
            }
            identity = newIdentity
            sessionID = SHA256.hash(data: Data(newIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
            highwater = 0
            records.removeAll()
            invalidateFrames()
        }
        return sessionID
    }

    func registerFrame(id: String, width: Int, height: Int, receivedAt: TimeInterval) {
        latestFrame = RemoteObservedFrame(id: id, width: width, height: height,
                                         receivedAt: receivedAt, mutationGeneration: mutationGeneration)
    }

    func frame(id: String, now: TimeInterval) throws -> RemoteObservedFrame {
        guard let frame = latestFrame, frame.id == id, frame.mutationGeneration == mutationGeneration,
              now >= frame.receivedAt, now - frame.receivedAt <= frameTTL else { throw RemoteActionError.staleFrame }
        return frame
    }

    func consumeFrame(id: String, now: TimeInterval) throws -> RemoteObservedFrame {
        let result = try frame(id: id, now: now)
        invalidateFrames()
        return result
    }

    func invalidateFrames() {
        latestFrame = nil
        mutationGeneration &+= 1
    }

    func reserve(sessionID: String, sequence: Int, digest: String) throws -> Bool {
        guard sessionID == self.sessionID else { throw RemoteActionError.sessionChanged }
        guard (1...RemoteActionCommand.maximumSequence).contains(sequence) else { throw RemoteActionError.invalidRequest }
        if let old = records[sequence] {
            guard old.digest == digest else { throw RemoteActionError.actionConflict }
            return false
        }
        guard sequence > highwater else { throw RemoteActionError.actionExpired }
        while records.count >= maximumRecords {
            guard let oldest = records.keys.sorted().first(where: { records[$0]?.state.isTerminal == true }) else {
                throw RemoteActionError.queueFull
            }
            records.removeValue(forKey: oldest)
        }
        highwater = sequence
        records[sequence] = RemoteActionRecord(digest: digest)
        return true
    }

    func record(sessionID: String, sequence: Int) throws -> RemoteActionRecord {
        if sessionID != self.sessionID {
            guard let old = retired[sessionID]?[sequence] else { throw RemoteActionError.sessionChanged }
            return old
        }
        guard let record = records[sequence] else {
            throw sequence <= highwater ? RemoteActionError.actionExpired : .actionUnknown
        }
        return record
    }

    func markRunning(sessionID: String, sequence: Int) {
        guard sessionID == self.sessionID, var record = records[sequence], !record.state.isTerminal else { return }
        record.state = .running
        records[sequence] = record
    }

    func markDispatched(sessionID: String, sequence: Int) throws {
        guard sessionID == self.sessionID else { throw RemoteActionError.sessionChanged }
        var record = try self.record(sessionID: sessionID, sequence: sequence)
        guard !record.state.isTerminal else { throw RemoteActionError.actionConflict }
        record.state = .running
        record.didDispatch = true
        records[sequence] = record
    }

    func finish(sessionID: String, sequence: Int, state: RemoteActionPhase, error: RemoteActionError? = nil) {
        if sessionID != self.sessionID {
            guard var old = retired[sessionID]?[sequence] else { return }
            old.state = state
            old.error = error
            retired[sessionID]?[sequence] = old
            return
        }
        guard var record = records[sequence] else { return }
        record.state = state
        record.error = error
        records[sequence] = record
    }
}

/// Runs release outside cancellation and waits until it ends or its absolute deadline.
/// A successful release means transport completion, never a remote application acknowledgement.
enum RemoteGestureCleanup {
    static func perform(
        press: @escaping @Sendable () async throws -> Void,
        body: @escaping @Sendable () async throws -> Void,
        release: @escaping @Sendable () async throws -> Void,
        timeout: TimeInterval = 2
    ) async throws {
        try Task.checkCancellation()
        var originalError: Error?
        do { try await press(); try await body() } catch { originalError = error }
        let released = await boundedRelease(timeout: timeout, operation: release)
        guard released else { throw RemoteActionError.cleanupFailed }
        if let originalError { throw originalError }
        try Task.checkCancellation()
    }

    private static func boundedRelease(
        timeout: TimeInterval, operation: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        let completion = RemoteReleaseCompletion()
        return await withCheckedContinuation { continuation in
            completion.install(continuation)
            let release = Task.detached {
                do { try await operation(); completion.finish(true) }
                catch { completion.finish(false) }
            }
            let deadline = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                release.cancel()
                completion.finish(false)
            }
            completion.setDeadline(deadline)
        }
    }
}

private final class RemoteReleaseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var deadline: Task<Void, Never>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func setDeadline(_ deadline: Task<Void, Never>) {
        lock.lock()
        let done = completed
        if !done { self.deadline = deadline }
        lock.unlock()
        if done { deadline.cancel() }
    }

    func finish(_ success: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let result = continuation
        let timer = deadline
        continuation = nil
        deadline = nil
        lock.unlock()
        timer?.cancel()
        result?.resume(returning: success)
    }
}
