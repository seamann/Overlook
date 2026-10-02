#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <macOS WebRTC framework parent> <evidence output directory>" >&2
  exit 2
fi

TASK_FRAMEWORK_DIR="$1"
TASK_EVIDENCE_DIR="$2"
TASK_SDK="${OVERLOOK_TEST_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
TASK_CLT="/Library/Developer/CommandLineTools/usr/bin"
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_EVIDENCE_DIR"
cd "$TASK_ROOT"

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
sys.exit(result.returncode)
PY
}

TASK_NATIVE_SOURCES=(
  Overlook/WebRTCManager.swift Overlook/WebRTCAudioDevice.swift
  Overlook/CoreAudioDevices.swift Overlook/RemoteSnapshot.swift Overlook/FrameDeliveryState.swift
  Overlook/JSONValue.swift Overlook/KVMDevice.swift Overlook/GLKVMClient.swift
  Overlook/ReliabilityPolicies.swift Overlook/ControlMode.swift
)
TASK_SWIFT_FLAGS=(
  -swift-version 5 -parse-as-library -target arm64-apple-macos14.0
  -sdk "$TASK_SDK" -F "$TASK_FRAMEWORK_DIR"
)
TASK_LINK_FLAGS=(
  -framework WebRTC -Xlinker -rpath -Xlinker "$TASK_FRAMEWORK_DIR"
)

"$TASK_CLT/swiftc" "${TASK_SWIFT_FLAGS[@]}" -typecheck \
  -module-name OverlookWebRTCSpike \
  -import-objc-header Overlook/Overlook-Bridging-Header.h \
  "${TASK_NATIVE_SOURCES[@]}" > "$TASK_EVIDENCE_DIR/native-subset-typecheck.log" 2>&1

"$TASK_CLT/clang" -target arm64-apple-macos14.0 -isysroot "$TASK_SDK" \
  -fobjc-arc -fmodules -F "$TASK_FRAMEWORK_DIR" \
  -c Overlook/WebRTCFactoryBuilder.m \
  -o "$TASK_EVIDENCE_DIR/WebRTCFactoryBuilder.o" \
  > "$TASK_EVIDENCE_DIR/factory-object-compile.log" 2>&1

"$TASK_CLT/swiftc" "${TASK_SWIFT_FLAGS[@]}" "${TASK_LINK_FLAGS[@]}" \
  -module-name OverlookWebRTCCompatibilityTests \
  -import-objc-header Overlook/Overlook-Bridging-Header.h \
  "${TASK_NATIVE_SOURCES[@]}" tests/WebRTCCompatibilityTests.swift \
  "$TASK_EVIDENCE_DIR/WebRTCFactoryBuilder.o" \
  -o "$TASK_EVIDENCE_DIR/WebRTCCompatibilityTests" \
  > "$TASK_EVIDENCE_DIR/native-subset-build.log" 2>&1
run_local_probe "$TASK_EVIDENCE_DIR/WebRTCCompatibilityTests" "$TASK_EVIDENCE_DIR/native-subset-run.log"
cat "$TASK_EVIDENCE_DIR/native-subset-run.log"

"$TASK_CLT/swiftc" "${TASK_SWIFT_FLAGS[@]}" "${TASK_LINK_FLAGS[@]}" \
  -module-name OverlookWebRTCSnapshotTests \
  Overlook/RemoteSnapshot.swift tests/RemoteSnapshotTests.swift \
  -o "$TASK_EVIDENCE_DIR/RemoteSnapshotTests" \
  > "$TASK_EVIDENCE_DIR/native-snapshot-build.log" 2>&1
run_local_probe "$TASK_EVIDENCE_DIR/RemoteSnapshotTests" "$TASK_EVIDENCE_DIR/native-snapshot-run.log"
cat "$TASK_EVIDENCE_DIR/native-snapshot-run.log"

"$TASK_CLT/swiftc" "${TASK_SWIFT_FLAGS[@]}" "${TASK_LINK_FLAGS[@]}" \
  -module-name OverlookWebRTCFrameDeliveryTests \
  Overlook/FrameDeliveryState.swift Overlook/RemoteSnapshot.swift tests/FrameDeliveryTests.swift \
  -o "$TASK_EVIDENCE_DIR/FrameDeliveryTests" \
  > "$TASK_EVIDENCE_DIR/frame-delivery-build.log" 2>&1
run_local_probe "$TASK_EVIDENCE_DIR/FrameDeliveryTests" "$TASK_EVIDENCE_DIR/frame-delivery-run.log"
cat "$TASK_EVIDENCE_DIR/frame-delivery-run.log"

"$TASK_CLT/swiftc" "${TASK_SWIFT_FLAGS[@]}" "${TASK_LINK_FLAGS[@]}" \
  -module-name OverlookWebRTCStatsGenerationTests \
  Overlook/FrameDeliveryState.swift Overlook/RemoteSnapshot.swift tests/StatsGenerationTests.swift \
  -o "$TASK_EVIDENCE_DIR/StatsGenerationTests" \
  > "$TASK_EVIDENCE_DIR/stats-generation-build.log" 2>&1
run_local_probe "$TASK_EVIDENCE_DIR/StatsGenerationTests" "$TASK_EVIDENCE_DIR/stats-generation-run.log"
cat "$TASK_EVIDENCE_DIR/stats-generation-run.log"
