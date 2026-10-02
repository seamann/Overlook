import Foundation

private struct StatsGenerationFailure: Error, CustomStringConvertible {
    let description: String
}

private actor SuspendedReport {
    private var continuation: CheckedContinuation<Int, Never>?
    private var requested = false
    func read() async -> Int {
        requested = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func hasRequest() -> Bool { requested }
    func complete() { continuation?.resume(returning: 42); continuation = nil }
}

@MainActor
private final class StatsConsumer {
    var generation = 1
    var videoPeer: NSObject? = NSObject()
    var audioPeer: NSObject? = NSObject()
    var activeRequestID: UUID?
    var published: Int?

    func read(_ report: SuspendedReport) async {
        guard let videoPeer else { return }
        let request = StreamStatsRequest(generation: generation, videoPeer: videoPeer, audioPeer: audioPeer)
        activeRequestID = request.requestID
        let result = await report.read()
        guard request.isCurrent(generation: generation, requestID: activeRequestID, videoPeer: self.videoPeer, audioPeer: audioPeer) else { return }
        published = result
    }
}

@main
struct StatsGenerationTests {
    @MainActor
    static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("current peer and request publish", testCurrentRequest),
            ("disconnect rejects suspended report", testDisconnect),
            ("reconnect rejects earlier generation", testReconnect),
            ("replacement video peer rejects old report", testVideoPeerReplacement),
            ("replacement audio peer rejects old report", testAudioPeerReplacement),
            ("newer same-peer request supersedes earlier report", testOverlappingRequests),
            ("video-only session has stable identity", testVideoOnlyIdentity),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("StatsGenerationTests: \(tests.count - failures)/\(tests.count) passed")
        if failures > 0 { exit(1) }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw StatsGenerationFailure(description: message) }
    }

    @MainActor
    private static func withSuspendedRequest(_ change: @MainActor (StatsConsumer) -> Void) async throws -> StatsConsumer {
        let consumer = StatsConsumer()
        let report = SuspendedReport()
        let task = Task { await consumer.read(report) }
        while !(await report.hasRequest()) { await Task.yield() }
        change(consumer)
        await report.complete()
        await task.value
        return consumer
    }

    @MainActor
    private static func testCurrentRequest() async throws {
        let consumer = try await withSuspendedRequest { _ in }
        try check(consumer.published == 42, "Current report was discarded")
    }

    @MainActor
    private static func testDisconnect() async throws {
        let consumer = try await withSuspendedRequest { $0.videoPeer = nil; $0.audioPeer = nil; $0.activeRequestID = nil }
        try check(consumer.published == nil, "Disconnected session received old statistics")
    }

    @MainActor
    private static func testReconnect() async throws {
        let consumer = try await withSuspendedRequest { $0.generation += 1 }
        try check(consumer.published == nil, "New generation received old statistics")
    }

    @MainActor
    private static func testVideoPeerReplacement() async throws {
        let consumer = try await withSuspendedRequest { $0.videoPeer = NSObject() }
        try check(consumer.published == nil, "Replacement video peer received old statistics")
    }

    @MainActor
    private static func testAudioPeerReplacement() async throws {
        let consumer = try await withSuspendedRequest { $0.audioPeer = NSObject() }
        try check(consumer.published == nil, "Replacement audio peer received old statistics")
    }

    @MainActor
    private static func testOverlappingRequests() async throws {
        let consumer = StatsConsumer()
        let older = SuspendedReport()
        let newer = SuspendedReport()
        let first = Task { await consumer.read(older) }
        while !(await older.hasRequest()) { await Task.yield() }
        let second = Task { await consumer.read(newer) }
        while !(await newer.hasRequest()) { await Task.yield() }
        await newer.complete()
        await second.value
        consumer.published = 99
        await older.complete()
        await first.value
        try check(consumer.published == 99, "Older same-peer request overwrote newer statistics")
    }

    private static func testVideoOnlyIdentity() async throws {
        let video = NSObject()
        let request = StreamStatsRequest(generation: 5, videoPeer: video, audioPeer: nil)
        try check(request.isCurrent(generation: 5, requestID: request.requestID, videoPeer: video, audioPeer: nil), "Video-only current report discarded")
        try check(!request.isCurrent(generation: 5, requestID: request.requestID, videoPeer: video, audioPeer: NSObject()), "New audio peer matched earlier video-only report")
        try check(!request.isCurrent(generation: 5, requestID: nil, videoPeer: video, audioPeer: nil), "Unowned request matched")
    }
}
