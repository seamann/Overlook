#!/bin/bash
# Produce an identifiable local app artifact. Does not install or restart Overlook.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
: "${OVERLOOK_SIGN_IDENTITY:?Set OVERLOOK_SIGN_IDENTITY to an Apple Development signing identity before building}"
output_dir="${1:-$repo_root/.build/agent-release}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
derived_data="${OVERLOOK_DERIVED_DATA_PATH:-$output_dir/DerivedData}"
source_packages="${OVERLOOK_SOURCE_PACKAGES_PATH:-$output_dir/SourcePackages}"
mkdir -p "$derived_data" "$source_packages"
derived_data="$(cd "$derived_data" && pwd)"
source_packages="$(cd "$source_packages" && pwd)"

source_revision="$(git rev-parse HEAD)"
source_fingerprint() {
  rg --files Overlook Overlook.xcodeproj scripts mcp/overlook-control/src \
    mcp/overlook-control/skills mcp/overlook-control/package-lock.json \
    mcp/overlook-control/package.json mcp/overlook-control/tsconfig.json \
    | LC_ALL=C sort \
    | while IFS= read -r source_file; do shasum -a 256 "$source_file"; done \
    | shasum -a 256 | awk '{print $1}'
}
source_digest="$(source_fingerprint)"
build_id="${source_revision:0:12}-${source_digest:0:16}-devsigned"

xcodebuild build \
  -project Overlook.xcodeproj -scheme Overlook -configuration Release \
  -sdk macosx -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" \
  -onlyUsePackageVersionsFromResolvedFile \
  CC="$repo_root/scripts/clang-pipe-compat" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  > "$output_dir/build.log" 2>&1

if [[ "$source_digest" != "$(source_fingerprint)" || "$source_revision" != "$(git rev-parse HEAD)" ]]; then
  printf 'Source changed during build; artifact is not released. Run again after edits finish.\n' >&2
  exit 1
fi

app_path="$derived_data/Build/Products/Release/Overlook.app"
plist_path="$app_path/Contents/Info.plist"
set_plist_value() {
  /usr/libexec/PlistBuddy -c "Set :$1 $3" "$plist_path" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$plist_path"
}
set_plist_value OverlookBuildID string "$build_id"
set_plist_value OverlookBuildMethod string xcodebuild
set_plist_value OverlookSigningMethod string apple-development
set_plist_value OverlookControlProtocolVersion integer 2
set_plist_value OverlookSourceRevision string "$source_revision"
set_plist_value OverlookSourceDigest string "$source_digest"
xattr -cr "$app_path"
framework_path="$app_path/Contents/Frameworks/WebRTC.framework"
test -d "$framework_path"
codesign --force --sign "$OVERLOOK_SIGN_IDENTITY" --timestamp=none "$framework_path"
codesign --force --sign "$OVERLOOK_SIGN_IDENTITY" --timestamp=none --options runtime \
  --entitlements Overlook/Overlook.entitlements "$app_path"
framework_team="$(codesign -dvvv "$framework_path" 2>&1 \
  | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
app_team="$(codesign -dvvv "$app_path" 2>&1 \
  | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
test -n "$framework_team"
test -n "$app_team"
test "$app_team" != 'not set'
test "$framework_team" = "$app_team"
codesign --verify --deep --strict "$app_path"

manifest="$output_dir/build-manifest.txt"
{
  printf 'build_id=%s\nsource_revision=%s\nsource_digest=%s\n' "$build_id" "$source_revision" "$source_digest"
  printf 'build_method=xcodebuild\nsigning_method=apple-development\nteam_identifier=%s\n' "$app_team"
  printf 'configuration=Release\ncontrol_protocol=2\napp_path=%s\n' "$app_path"
  printf 'built_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  xcodebuild -version
  swift --version
  shasum -a 256 "$app_path/Contents/MacOS/Overlook"
  shasum -a 256 "$plist_path"
} > "$manifest"
printf 'Built %s\nManifest: %s\nApp: %s\n' "$build_id" "$manifest" "$app_path"
