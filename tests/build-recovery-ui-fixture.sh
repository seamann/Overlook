#!/bin/bash
# Separate native test app. It neither installs nor launches the real Overlook.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
output_dir="${1:?Usage: build-recovery-ui-fixture.sh OUTPUT_DIR WEBRTC_FRAMEWORK_PARENT}"
framework_parent="${2:?Pass the pinned WebRTC macOS framework parent}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app="$output_dir/OverlookRecoveryFixture.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
sources=()
while IFS= read -r path; do
  [[ "$path" == Overlook/OverlookApp.swift ]] || sources+=("$path")
done < <(rg --files Overlook --glob '*.swift' | sort)
xcrun clang -fobjc-arc -target "$(uname -m)-apple-macos14.0" -F "$framework_parent" -I Overlook \
  -c Overlook/WebRTCFactoryBuilder.m -o "$output_dir/WebRTCFactoryBuilder.o"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -parse-as-library \
  -F "$framework_parent" -framework WebRTC \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -lsandbox -import-objc-header tests/RecoveryUIFixture-Bridging-Header.h \
  "${sources[@]}" tests/RecoveryUIFixture.swift "$output_dir/WebRTCFactoryBuilder.o" \
  -o "$app/Contents/MacOS/RecoveryUIFixture"
ditto "$framework_parent/WebRTC.framework" "$app/Contents/Frameworks/WebRTC.framework"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.overlook.tests.recovery-fixture</string>
<key>CFBundleName</key><string>Overlook Recovery Fixture</string>
<key>CFBundleExecutable</key><string>RecoveryUIFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Frameworks/WebRTC.framework"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/RecoveryUIFixture" --verify-sandbox "$output_dir/sandbox-proof.json"
printf '%s\n' "$app"
