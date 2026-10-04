#!/bin/bash
set -euo pipefail

PROJECT="AIQuota"
BUILD_DIR=".build"
APP_NAME="Quota Monitor"
APP_BUNDLE="${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_RESOURCES="${APP_CONTENTS}/Resources"

echo "Building ${PROJECT}..."
swift build -c release

BINARY="${BUILD_DIR}/release/${PROJECT}"

if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at ${BINARY}"
    exit 1
fi

echo "Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_MACOS}"
mkdir -p "${APP_RESOURCES}"

cp "${BINARY}" "${APP_MACOS}/${PROJECT}"
cp Sources/AIQuota/Resources/Info.plist "${APP_CONTENTS}/"

# Ad-hoc sign: binary first, then bundle
codesign --force --sign - --verbose "${APP_MACOS}/${PROJECT}"
codesign --force --sign - --verbose "${APP_BUNDLE}"

echo ""
echo "✅ App bundle created: ${APP_BUNDLE}"
echo "   open \"${APP_BUNDLE}\""
echo ""
echo "If Gatekeeper blocks it:"
echo "   System Settings → Privacy & Security → scroll down → Open Anyway"
