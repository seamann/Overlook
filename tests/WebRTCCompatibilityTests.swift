import Foundation
import AppKit
import ObjectiveC
import WebRTC

/// Local binary compatibility checks. No window, signaling connection or
/// AudioUnit is started; the full manager is compiled and linked alongside this.
@main
struct WebRTCCompatibilityTests {
    @MainActor
    static func main() async {
        do {
            try testMetalRendererType()
            try testNativeAudioProtocol()
            try testCustomAudioFactory()
            try await testPeerAndStatistics()
            print("WebRTCCompatibilityTests: 4/4 passed")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "WebRTCCompatibilityTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func testMetalRendererType() throws {
        try check(RTCMTLNSVideoView.isSubclass(of: NSView.self), "Metal view lost its NSView base")
        try check(RTCMTLNSVideoView.instancesRespond(to: NSSelectorFromString("renderFrame:")),
                  "Metal view no longer implements native frame rendering")
        print("PASS linked Metal renderer class and selector")
    }

    private static func testNativeAudioProtocol() throws {
        guard let audioProtocol = objc_getProtocol("RTCAudioDevice") else {
            throw NSError(domain: "WebRTCCompatibilityTests", code: 2)
        }
        try check(class_conformsToProtocol(WebRTCAudioDevice.self, audioProtocol),
                  "Production audio device lost Objective-C protocol conformance")
        let device = WebRTCAudioDevice(inputDeviceUID: nil, outputDeviceUID: nil)
        try check(!device.isInitialized && !device.isPlaying && !device.isRecording,
                  "An uninitialized production audio device started I/O")
        try check(device.deviceInputSampleRate == 48_000 && device.deviceOutputSampleRate == 48_000,
                  "Audio protocol sample-rate properties cannot be read")
        try check(device.terminateDevice(), "Idle audio device could not terminate")
        print("PASS production audio shim conformance and idle lifecycle")
    }

    private static func testCustomAudioFactory() throws {
        let device = WebRTCAudioDevice(inputDeviceUID: nil, outputDeviceUID: nil)
        let factory = WebRTCFactoryBuilder.makeFactory(with: device)
        try check(factory.isKind(of: RTCPeerConnectionFactory.self),
                  "Custom Objective-C audio factory did not return a native factory")
        try check(!device.isPlaying && !device.isRecording,
                  "Creating a factory unexpectedly started audio I/O")
        // Keep factory alive until the state assertions have run.
        withExtendedLifetime(factory) {}
        print("PASS linked custom-audio Objective-C factory")
    }

    private static func testPeerAndStatistics() async throws {
        let delegate = LocalPeerDelegate()
        let factory = WebRTCFactoryBuilder.makeFactory(with: nil)
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: delegate) else {
            throw NSError(domain: "WebRTCCompatibilityTests", code: 3)
        }
        defer { peer.close() }
        // No SDP is applied: no ICE gathering or remote network session starts.
        try check(peer.signalingState == .stable, "Fresh native peer is not stable")
        let statistics = await peer.statistics()
        try check(statistics.timestamp_us >= 0, "Native statistics timestamp is invalid")
        try check(peer.remoteDescription == nil && peer.localDescription == nil,
                  "A local-only peer acquired an SDP unexpectedly")
        print("PASS native peer creation, Swift async statistics and close")
    }
}

private final class LocalPeerDelegate: NSObject, RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
