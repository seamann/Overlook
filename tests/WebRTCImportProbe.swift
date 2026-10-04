import WebRTC

// Unconditional import prevents #if canImport(WebRTC) from hiding native cases.
func requiresNativeWebRTC(_ frame: RTCVideoFrame) -> Int32 {
    frame.width
}
