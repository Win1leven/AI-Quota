#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT_DIR="$PWD"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${2:-1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected version X.Y.Z"; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Expected numeric build number"; exit 1; }
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/AI-Quota.app"
BUILD_ROOT="$(mktemp -d /tmp/aiquota-release.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
mkdir -p "$DIST_DIR" "$BUILD_ROOT/AI-Quota.app/Contents/MacOS" "$BUILD_ROOT/AI-Quota.app/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swift-cache"

# Build both slices from current source; do not reuse historical binaries.
for ARCH in arm64 x86_64; do
    swift build -c release --disable-sandbox --scratch-path "$BUILD_ROOT/$ARCH" --triple "$ARCH-apple-macosx13.0"
    BINARY_DIR="$(swift build -c release --disable-sandbox --scratch-path "$BUILD_ROOT/$ARCH" --triple "$ARCH-apple-macosx13.0" --show-bin-path)"
    cp "$BINARY_DIR/AIQuota" "$BUILD_ROOT/AIQuota-$ARCH"
done
lipo -create "$BUILD_ROOT/AIQuota-arm64" "$BUILD_ROOT/AIQuota-x86_64" -output "$BUILD_ROOT/AI-Quota.app/Contents/MacOS/AIQuota"
cp Sources/AIQuota/Resources/Info.plist "$BUILD_ROOT/AI-Quota.app/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUILD_ROOT/AI-Quota.app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUILD_ROOT/AI-Quota.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUILD_ROOT/AI-Quota.app/Contents/Info.plist"
codesign --force --sign - "$BUILD_ROOT/AI-Quota.app/Contents/MacOS/AIQuota"
codesign --force --sign - "$BUILD_ROOT/AI-Quota.app"
codesign --verify --strict --deep "$BUILD_ROOT/AI-Quota.app"
# Only replace this script's generated output; never touch an installed app.
rm -rf "$APP_BUNDLE"
ditto "$BUILD_ROOT/AI-Quota.app" "$APP_BUNDLE"
printf 'Built %s\n' "$APP_BUNDLE"
