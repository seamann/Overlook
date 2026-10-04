#!/bin/bash
set -euo pipefail

TASK_PREFLIGHT_ONLY=false
if [[ "${1:-}" == --preflight ]]; then
  TASK_PREFLIGHT_ONLY=true
  shift
fi
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 [--preflight] <macOS WebRTC framework parent> <evidence output directory>" >&2
  exit 2
fi

TASK_FRAMEWORK_DIR="$1"
TASK_EVIDENCE_DIR="$2"
TASK_SWIFTC="${OVERLOOK_SWIFTC:-$(xcrun --find swiftc)}"
TASK_CLANG="${OVERLOOK_CLANG:-$(xcrun --find clang)}"
TASK_SDK="${OVERLOOK_SWIFT_SDK:-${OVERLOOK_TEST_SDK:-$(xcrun --sdk macosx --show-sdk-path)}}"
TASK_TARGET="${OVERLOOK_SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_EVIDENCE_DIR"
cd "$TASK_ROOT"

if [[ ! -d "$TASK_FRAMEWORK_DIR/WebRTC.framework" ]]; then
  printf 'Set OVERLOOK_WEBRTC_FRAMEWORK_DIR to the resolved macOS development framework parent.\n' >&2
  exit 1
fi
if ! "$TASK_SWIFTC" -swift-version 5 -target "$TASK_TARGET" -sdk "$TASK_SDK" \
  -F "$TASK_FRAMEWORK_DIR" -typecheck tests/WebRTCImportProbe.swift \
  > "$TASK_EVIDENCE_DIR/webrtc-import-preflight.log" 2>&1; then
  printf 'WebRTC is not importable. Use the resolved development framework with Headers/Modules and a matching compiler/SDK.\n' >&2
  cat "$TASK_EVIDENCE_DIR/webrtc-import-preflight.log" >&2
  exit 1
fi
printf 'PASS native WebRTC module import preflight\n'
if [[ "$TASK_PREFLIGHT_ONLY" == true ]]; then exit 0; fi

run_compiler() {
  local log_path="$TASK_EVIDENCE_DIR/$1"
  shift
  if "$@" > "$log_path" 2>&1; then
    return 0
  else
    local status=$?
    cat "$log_path" >&2
    return "$status"
  fi
}

run_local_probe() {
  python3 - "$1" "$2" <<'PY'
import subprocess
import sys

with open(sys.argv[2], "w", encoding="utf-8") as output:
    try:
        result = subprocess.run([sys.argv[1]], stdout=output, stderr=subprocess.STDOUT, timeout=30)
    except subprocess.TimeoutExpired:
        print("Local WebRTC probe exceeded its 30-second deadline", file=sys.stderr)
        sys.exit(124)
if result.returncode:
    with open(sys.argv[2], encoding="utf-8") as output:
        print(output.read(), file=sys.stderr)
sys.exit(result.returncode)
PY
}

TASK_NATIVE_SOURCES=(
  Overlook/WebRTCManager.swift Overlook/WebRTCAudioDevice.swift
  Overlook/CoreAudioDevices.swift Overlook/RemoteSnapshot.swift Overlook/FrameDeliveryState.swift
  Overlook/JSONValue.swift Overlook/KVMDevice.swift Overlook/GLKVMClient.swift
  Overlook/ReliabilityPolicies.swift Overlook/ControlMode.swift
  Overlook/JanusRequestCoordinator.swift
)
TASK_SWIFT_FLAGS=(
  -swift-version 5 -parse-as-library -target "$TASK_TARGET"
  -sdk "$TASK_SDK" -F "$TASK_FRAMEWORK_DIR"
)
TASK_LINK_FLAGS=(
  -framework WebRTC -Xlinker -rpath -Xlinker "$TASK_FRAMEWORK_DIR"
)

run_compiler native-subset-typecheck.log "$TASK_SWIFTC" "${TASK_SWIFT_FLAGS[@]}" -typecheck \
  -module-name OverlookWebRTCSpike \
  -import-objc-header Overlook/Overlook-Bridging-Header.h \
  "${TASK_NATIVE_SOURCES[@]}"

run_compiler factory-object-compile.log "$TASK_CLANG" -target "$TASK_TARGET" -isysroot "$TASK_SDK" \
  -fobjc-arc -fmodules -F "$TASK_FRAMEWORK_DIR" \
  -c Overlook/WebRTCFactoryBuilder.m \
  -o "$TASK_EVIDENCE_DIR/WebRTCFactoryBuilder.o"

run_compiler native-subset-build.log "$TASK_SWIFTC" "${TASK_SWIFT_FLAGS[@]}" "${TASK_LINK_FLAGS[@]}" \
  -module-name OverlookWebRTCCompatibilityTests \
  -import-objc-header Overlook/Overlook-Bridging-Header.h \
  "${TASK_NATIVE_SOURCES[@]}" tests/WebRTCCompatibilityTests.swift \
  "$TASK_EVIDENCE_DIR/WebRTCFactoryBuilder.o" \
  -o "$TASK_EVIDENCE_DIR/WebRTCCompatibilityTests"
run_local_probe "$TASK_EVIDENCE_DIR/WebRTCCompatibilityTests" "$TASK_EVIDENCE_DIR/native-subset-run.log"
cat "$TASK_EVIDENCE_DIR/native-subset-run.log"

run_compiler native-snapshot-build.log "$TASK_SWIFTC" "${TASK_SWIFT_FLAGS[@]}" "${TASK_LINK_FLAGS[@]}" \
  -module-name OverlookWebRTCSnapshotTests \
  Overlook/RemoteSnapshot.swift tests/RemoteSnapshotTests.swift \
  -o "$TASK_EVIDENCE_DIR/RemoteSnapshotTests"
run_local_probe "$TASK_EVIDENCE_DIR/RemoteSnapshotTests" "$TASK_EVIDENCE_DIR/native-snapshot-run.log"
cat "$TASK_EVIDENCE_DIR/native-snapshot-run.log"

run_compiler frame-delivery-build.log "$TASK_SWIFTC" "${TASK_SWIFT_FLAGS[@]}" "${TASK_LINK_FLAGS[@]}" \
  -module-name OverlookWebRTCFrameDeliveryTests \
  Overlook/FrameDeliveryState.swift Overlook/RemoteSnapshot.swift tests/FrameDeliveryTests.swift \
  -o "$TASK_EVIDENCE_DIR/FrameDeliveryTests"
run_local_probe "$TASK_EVIDENCE_DIR/FrameDeliveryTests" "$TASK_EVIDENCE_DIR/frame-delivery-run.log"
cat "$TASK_EVIDENCE_DIR/frame-delivery-run.log"

run_compiler stats-generation-build.log "$TASK_SWIFTC" "${TASK_SWIFT_FLAGS[@]}" "${TASK_LINK_FLAGS[@]}" \
  -module-name OverlookWebRTCStatsGenerationTests \
  Overlook/FrameDeliveryState.swift Overlook/RemoteSnapshot.swift tests/StatsGenerationTests.swift \
  -o "$TASK_EVIDENCE_DIR/StatsGenerationTests"
run_local_probe "$TASK_EVIDENCE_DIR/StatsGenerationTests" "$TASK_EVIDENCE_DIR/stats-generation-run.log"
cat "$TASK_EVIDENCE_DIR/stats-generation-run.log"
