#!/bin/bash
# All fixtures are local. No connection to the installed Overlook or a KVM.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
suite="${1:-all}"
case "$suite" in swift|mcp|all) ;; *) printf 'Usage: %s [swift|mcp|all]\n' "$0" >&2; exit 2 ;; esac
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/overlook-tests.XXXXXXXX")"
fixture_pid=''
cleanup() {
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

swiftc_bin="${OVERLOOK_SWIFTC:-swiftc}"
swift_flags=(-swift-version 5 -target "${OVERLOOK_SWIFT_TARGET:-$(uname -m)-apple-macos14.0}")
if [[ -n "${OVERLOOK_SWIFT_SDK:-}" ]]; then
  swift_flags+=(-sdk "$OVERLOOK_SWIFT_SDK")
fi

run_swift() {
  local name="$1"
  shift
  "$swiftc_bin" "${swift_flags[@]}" -parse-as-library "$@" -o "$test_dir/$name"
  "$test_dir/$name"
}

if [[ "$suite" != mcp ]]; then
  run_swift ControlMode Overlook/ControlMode.swift tests/ControlModeTests.swift
  run_swift ReliabilityPolicy Overlook/ControlMode.swift Overlook/ReliabilityPolicies.swift tests/ReliabilityPolicyTests.swift
  run_swift MouseJigglerLifecycle Overlook/ControlMode.swift Overlook/ReliabilityPolicies.swift \
    Overlook/JSONValue.swift Overlook/GLKVMClient.swift Overlook/KVMDevice.swift \
    Overlook/KVMDeviceManager.swift tests/MouseJigglerLifecycleTests.swift
  run_swift GLKVMResponse Overlook/JSONValue.swift Overlook/GLKVMClient.swift tests/GLKVMSystemConfigTests.swift
  run_swift CredentialConfig Overlook/ControlMode.swift Overlook/ReliabilityPolicies.swift \
    Overlook/JSONValue.swift Overlook/GLKVMClient.swift Overlook/KVMDevice.swift \
    Overlook/KVMDeviceManager.swift tests/CredentialConfigIntegrationTests.swift
  run_swift StatsGeneration Overlook/FrameDeliveryState.swift tests/StatsGenerationTests.swift
  run_swift RemoteActionState Overlook/RemoteActionState.swift tests/RemoteActionStateTests.swift
  run_swift SessionConnectionCoordinator Overlook/JSONValue.swift Overlook/GLKVMClient.swift \
    Overlook/KVMDevice.swift Overlook/SessionConnectionCoordinator.swift tests/SessionConnectionCoordinatorTests.swift
  capture_sources=(Overlook/ControlMode.swift Overlook/ReliabilityPolicies.swift Overlook/JSONValue.swift
    Overlook/GLKVMClient.swift Overlook/RemoteActionState.swift Overlook/RemoteSnapshot.swift
    Overlook/LocalInputCapture.swift Overlook/InputManager.swift tests/InputCaptureTestSupport.swift)
  run_swift LocalInputCapture "${capture_sources[@]}" tests/LocalInputCaptureTests.swift
  run_swift InputManagerCapture "${capture_sources[@]}" tests/InputManagerCaptureTests.swift
  run_swift InputManagerGLKVM "${capture_sources[@]}" tests/InputManagerGLKVMTests.swift
  "$swiftc_bin" "${swift_flags[@]}" -parse-as-library "${capture_sources[@]}" tests/InputManagerHIDQueueTests.swift -o "$test_dir/HIDQueue"
  node tests/hid-capture-fixture.mjs --self-test
  node tests/hid-capture-fixture.mjs "$test_dir/hid-port" &
  fixture_pid=$!
  for attempt in 1 2 3 4 5; do [[ -s "$test_dir/hid-port" ]] && break; sleep 1; done
  "$test_dir/HIDQueue" "$(cat "$test_dir/hid-port")"
  kill "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" || true
  fixture_pid=''
  "$swiftc_bin" "${swift_flags[@]}" -parse-as-library "${capture_sources[@]}" tests/GLKVMWebSocketSettlementTests.swift -o "$test_dir/WebSocketSettlement"
  node --check tests/ws-settlement-fixture.mjs
  node tests/ws-settlement-fixture.mjs "$test_dir/settlement-port" &
  fixture_pid=$!
  for attempt in 1 2 3 4 5; do [[ -s "$test_dir/settlement-port" ]] && break; sleep 1; done
  "$test_dir/WebSocketSettlement" "$(cat "$test_dir/settlement-port")"
  kill "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" || true
  fixture_pid=''
  framework_parent="${OVERLOOK_WEBRTC_FRAMEWORK_DIR:-$repo_root/.build/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64}"
  if [[ ! -d "$framework_parent/WebRTC.framework" ]]; then
    printf 'Set OVERLOOK_WEBRTC_FRAMEWORK_DIR to the resolved macOS framework parent.\n' >&2
    exit 1
  fi
  run_swift FrameDelivery -F "$framework_parent" -framework WebRTC \
    -Xlinker -rpath -Xlinker "$framework_parent" \
    Overlook/FrameDeliveryState.swift Overlook/RemoteSnapshot.swift tests/FrameDeliveryTests.swift
  run_swift RemoteSnapshot -F "$framework_parent" -framework WebRTC \
    -Xlinker -rpath -Xlinker "$framework_parent" \
    Overlook/RemoteSnapshot.swift tests/RemoteSnapshotTests.swift
  run_swift LocalControlServer Overlook/ControlMode.swift Overlook/ReliabilityPolicies.swift \
    Overlook/RemoteActionState.swift Overlook/RemoteSnapshot.swift Overlook/LocalControlServer.swift \
    tests/LocalControlServerStubs.swift tests/LocalControlServerTests.swift

  "$swiftc_bin" "${swift_flags[@]}" -parse-as-library Overlook/JSONValue.swift Overlook/GLKVMClient.swift \
    tests/GLKVMWebSocketTests.swift -o "$test_dir/WebSocketReadiness"
  node tests/ws-readiness-fixture.mjs "$test_dir/port" &
  fixture_pid=$!
  for attempt in 1 2 3 4 5; do [[ -s "$test_dir/port" ]] && break; sleep 1; done
  "$test_dir/WebSocketReadiness" "$(cat "$test_dir/port")"
  kill "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" || true
  fixture_pid=''
fi

if [[ "$suite" != swift ]]; then
  (cd mcp/overlook-control && npm test)
fi
