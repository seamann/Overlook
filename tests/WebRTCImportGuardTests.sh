#!/bin/bash
# The negative framework is an installed/runtime-only bundle without module headers.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'Usage: %s <importable framework parent> [runtime-only framework parent]\n' "$0" >&2
  exit 2
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/overlook-import-guard.XXXXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

runtime_framework="${2:-$test_dir/runtime-only}"
if [[ $# -eq 1 ]]; then mkdir -p "$runtime_framework/WebRTC.framework"; fi
if ! bash "$repo_root/scripts/test-webrtc-compatibility.sh" --preflight "$1" "$test_dir/valid" > "$test_dir/valid.log" 2>&1; then
  cat "$test_dir/valid.log" >&2
  printf 'FAIL valid development framework rejected\n' >&2
  exit 1
fi
if bash "$repo_root/scripts/test-webrtc-compatibility.sh" --preflight "$runtime_framework" "$test_dir/stripped" > "$test_dir/stripped.log" 2>&1; then
  printf 'FAIL runtime-only framework silently accepted\n' >&2
  exit 1
fi
if ! /usr/bin/grep -q 'WebRTC is not importable' "$test_dir/stripped.log"; then
  cat "$test_dir/stripped.log" >&2
  printf 'FAIL missing actionable import diagnostic\n' >&2
  exit 1
fi
if env OVERLOOK_WEBRTC_FRAMEWORK_DIR="$runtime_framework" bash "$repo_root/scripts/test-agent-control.sh" swift > "$test_dir/driver.log" 2>&1; then
  printf 'FAIL Swift driver accepted runtime-only framework\n' >&2
  exit 1
fi
if ! /usr/bin/grep -q 'WebRTC is not importable' "$test_dir/driver.log" || /usr/bin/grep -q '^PASS ' "$test_dir/driver.log"; then
  cat "$test_dir/driver.log" >&2
  printf 'FAIL Swift driver did not reject before running tests\n' >&2
  exit 1
fi
printf 'WebRTCImportGuardTests: 3/3 passed (valid import, stripped rejection, early driver rejection)\n'
