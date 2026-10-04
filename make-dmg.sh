#!/bin/bash
set -euo pipefail

APP_NAME="Quota Monitor"
DMG_NAME="QuotaMonitor-1.0.0b"
STAGING_DIR="/tmp/aiquota-dmg-staging"
DMG_PATH="${DMG_NAME}.dmg"

echo "Creating DMG..."

rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_NAME}.app" "${STAGING_DIR}/"

ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"

hdiutil create -volname "Quota Monitor" \
    -srcfolder "${STAGING_DIR}" \
    -ov -format UDZO \
    -fs HFS+ \
    "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

echo "✅ DMG created: ${DMG_PATH}"
echo "   SHA-256: $(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"
echo ""
echo "Install instructions:"
echo "  1. Open ${DMG_PATH}"
echo "  2. Drag Quota Monitor.app to Applications"
echo "  3. Right-click Quota Monitor.app → Open (first launch only)"
echo ""
echo "This app is unsigned. Apple will block it on first launch."
echo "Use 'Privacy & Security → Still Open' to bypass, or run:"
echo "    xattr -d com.apple.quarantine '/Applications/${APP_NAME}.app'"
