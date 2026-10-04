import Foundation
import AudioUnit

private struct AudioInitializationFailure: Error, CustomStringConvertible {
    let description: String
}

private enum AudioDirection: String, CaseIterable {
    case output, input

    func initialize(_ device: WebRTCAudioDevice) -> Bool {
        self == .output ? device.initializePlayout() : device.initializeRecording()
    }

    func isInitialized(_ device: WebRTCAudioDevice) -> Bool {
        self == .output ? device.isPlayoutInitialized : device.isRecordingInitialized
    }
}

private enum InitializationStage: String, CaseIterable {
    case find, create, enableIO, disableIO, device, format, callback, initialize
}

/// Fake opaque handles never reach CoreAudio. Initialization does not start I/O.
private final class AudioUnitFixture {
    var failure: InitializationStage?
    var returnHandleOnCreateFailure = false
    private(set) var events: [String] = []
    private(set) var created: [AudioComponentInstance] = []
    private var propertyIndex = 0

    init(failure: InitializationStage? = nil) { self.failure = failure }

    func operations() -> AudioUnitOperations {
        AudioUnitOperations(
            find: { _ in
                self.events.append("find")
                return self.fail(.find) ? nil : OpaquePointer(bitPattern: 0x1000)
            },
            create: { _, unit in
                self.events.append("create")
                self.propertyIndex = 0
                let failed = self.fail(.create)
                if !failed || self.returnHandleOnCreateFailure {
                    unit = AudioComponentInstance(bitPattern: 0x2000 + self.created.count * 0x100)
                    self.created.append(unit!)
                }
                return failed ? kAudio_ParamError : noErr
            },
            setProperty: { _, _, _, _, _, _ in
                let stages: [InitializationStage] = [.enableIO, .disableIO, .device, .format, .callback]
                let stage = stages[self.propertyIndex]
                self.propertyIndex += 1
                self.events.append(stage.rawValue)
                return self.fail(stage) ? kAudio_ParamError : noErr
            },
            initialize: { _ in
                self.events.append("initialize")
                return self.fail(.initialize) ? kAudio_ParamError : noErr
            },
            uninitialize: { unit in
                self.events.append("uninitialize:\(UInt(bitPattern: unit))")
                return noErr
            },
            dispose: { unit in
                self.events.append("dispose:\(UInt(bitPattern: unit))")
                return noErr
            }
        )
    }

    private func fail(_ stage: InitializationStage) -> Bool {
        guard failure == stage else { return false }
        failure = nil
        return true
    }

    func count(_ event: String) -> Int { events.filter { $0 == event }.count }
}

private final class IdleAudioDelegate: NSObject, RTCAudioDeviceDelegate {
    let preferredInputSampleRate = 48_000.0
    let preferredInputIOBufferDuration = 0.01
    let preferredOutputSampleRate = 48_000.0
    let preferredOutputIOBufferDuration = 0.01
    let getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock = { _, _, _, _, _ in noErr }
    let deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock = { _, _, _, _, _, _, _ in noErr }
    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func dispatchAsync(_ block: @escaping () -> Void) { block() }
    func dispatchSync(_ block: () -> Void) { block() }
}

@main
struct AudioUnitInitializationTests {
    static func main() {
        var failures = 0
        var count = 0
        func run(_ name: String, _ test: () throws -> Void) {
            count += 1
            do { try test(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }

        run("uninitialized and idle audio does not acquire units", testIdleLifecycle)
        for direction in AudioDirection.allCases {
            for stage in InitializationStage.allCases {
                run("\(direction.rawValue) \(stage.rawValue) failure cleanup and real retry") {
                    try testFailureAndRetry(direction: direction, stage: stage)
                }
            }
            run("\(direction.rawValue) failed creation with handle disposes it") {
                try testFailedCreationHandle(direction: direction)
            }
            run("\(direction.rawValue) success is idempotent and terminates exactly once") {
                try testSuccessfulLifecycle(direction: direction)
            }
        }
        run("input failure preserves initialized output", testDirectionIsolation)
        print("AudioUnitInitializationTests: \(count - failures)/\(count) passed")
        if failures > 0 { exit(1) }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AudioInitializationFailure(description: message) }
    }

    private static func makeDevice(_ fixture: AudioUnitFixture) -> WebRTCAudioDevice {
        let device = WebRTCAudioDevice(inputDeviceUID: nil, outputDeviceUID: nil,
                                      audioUnits: fixture.operations())
        _ = device.initialize(with: IdleAudioDelegate())
        return device
    }

    private static func testIdleLifecycle() throws {
        let fixture = AudioUnitFixture()
        let device = WebRTCAudioDevice(inputDeviceUID: nil, outputDeviceUID: nil,
                                      audioUnits: fixture.operations())
        try check(!device.initializePlayout() && !device.initializeRecording(), "Uninitialized device accepted audio initialization")
        try check(device.terminateDevice(), "Idle termination failed")
        try check(fixture.events.isEmpty, "Idle lifecycle touched an AudioUnit")
    }

    private static func testFailureAndRetry(direction: AudioDirection, stage: InitializationStage) throws {
        let fixture = AudioUnitFixture(failure: stage)
        let device = makeDevice(fixture)
        defer { _ = device.terminateDevice() }
        try check(!direction.initialize(device), "Injected failure reported success")
        try check(!direction.isInitialized(device), "Failed direction was published as initialized")
        try check(!device.isPlaying && !device.isRecording, "Initialization started I/O")

        if let failedUnit = fixture.created.first {
            let id = UInt(bitPattern: failedUnit)
            try check(fixture.count("dispose:\(id)") == 1, "Failed unit was not disposed exactly once")
            let expectedUninitialize = stage == .initialize ? 1 : 0
            try check(fixture.count("uninitialize:\(id)") == expectedUninitialize,
                      "Cleanup did not match the initialization stage")
        } else {
            try check(fixture.events.allSatisfy { !$0.hasPrefix("dispose:") && !$0.hasPrefix("uninitialize:") },
                      "Cleanup used an uncreated handle")
        }

        try check(direction.initialize(device), "Retry did not succeed")
        try check(fixture.count("find") == 2, "Retry reused a failed unit instead of constructing a new one")
        try check(fixture.count("initialize") == (stage == .initialize ? 2 : 1), "Retry skipped AudioUnitInitialize")
        try check(direction.isInitialized(device), "Successful retry was not published")
        try check(!device.isPlaying && !device.isRecording, "Retry started I/O")
    }

    private static func testFailedCreationHandle(direction: AudioDirection) throws {
        let fixture = AudioUnitFixture(failure: .create)
        fixture.returnHandleOnCreateFailure = true
        let device = makeDevice(fixture)
        defer { _ = device.terminateDevice() }
        try check(!direction.initialize(device), "Failed creation reported success")
        let unit = fixture.created[0]
        try check(fixture.count("dispose:\(UInt(bitPattern: unit))") == 1, "Creation failure leaked its returned handle")
        try check(direction.initialize(device), "Retry after failed creation did not succeed")
        try check(fixture.created.count == 2, "Retry reused failed creation handle")
    }

    private static func testSuccessfulLifecycle(direction: AudioDirection) throws {
        let fixture = AudioUnitFixture()
        let device = makeDevice(fixture)
        try check(direction.initialize(device), "Successful direction failed initialization")
        let initialEvents = fixture.events
        try check(direction.initialize(device), "Repeated initialization failed")
        try check(fixture.events == initialEvents, "Repeated initialization acquired or configured another unit")
        try check(!device.isPlaying && !device.isRecording, "Initialization started I/O")
        let unit = fixture.created[0]
        let id = UInt(bitPattern: unit)
        try check(device.terminateDevice() && device.terminateDevice(), "Termination failed")
        try check(fixture.count("uninitialize:\(id)") == 1 && fixture.count("dispose:\(id)") == 1,
                  "Initialized unit did not terminate exactly once")
        try check(!device.isInitialized && !direction.isInitialized(device), "Termination left initialization state published")
    }

    private static func testDirectionIsolation() throws {
        let fixture = AudioUnitFixture()
        let device = makeDevice(fixture)
        defer { _ = device.terminateDevice() }
        try check(device.initializePlayout(), "Output setup failed")
        fixture.failure = .format
        try check(!device.initializeRecording(), "Input fault did not fail")
        try check(device.isPlayoutInitialized && !device.isRecordingInitialized, "Input failure corrupted output state")
        let output = fixture.created[0]
        try check(fixture.count("dispose:\(UInt(bitPattern: output))") == 0, "Input failure disposed output")
        try check(device.initializeRecording(), "Input retry failed")
        try check(fixture.created.count == 3, "Input retry did not construct another unit")
    }
}
