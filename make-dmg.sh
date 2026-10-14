#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TAG="${1:-v0.1.0-beta.1}"
APP_BUNDLE="$PWD/dist/AI-Quota.app"
DIST_DIR="$PWD/dist"
STAGING_DIR="$(mktemp -d /tmp/aiquota-dmg.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]] || { echo 'Expected vX.Y.Z-beta.N'; exit 1; }
codesign --verify --strict --deep "$APP_BUNDLE"
BASE_NAME="AI-Quota-${TAG#v}-universal"
ditto "$APP_BUNDLE" "$STAGING_DIR/AI-Quota.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp docs/USAGE.zh-CN.md "$STAGING_DIR/使用说明.md"
hdiutil create -volname "AI-Quota ${TAG#v}" -srcfolder "$STAGING_DIR" -ov -format UDZO -fs HFS+ "$DIST_DIR/$BASE_NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$DIST_DIR/$BASE_NAME.zip"
(cd "$DIST_DIR" && shasum -a 256 "$BASE_NAME.dmg" "$BASE_NAME.zip" > SHA256SUMS)
printf 'Packages: %s/%s.{dmg,zip}\n' "$DIST_DIR" "$BASE_NAME"
