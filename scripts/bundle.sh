#!/bin/bash
# Creates a proper .app bundle from the built binary.
# Usage: ./scripts/bundle.sh
# Environment variables:
#   APP_VERSION  — version string (default: 0.1.0)
#   SKIP_BUILD   — set to 1 to skip the build step (CI builds separately)
set -euo pipefail

APP_NAME="Clawdboard"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_DIR="${BUILD_DIR:-.build/release}"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo "Building release..."
    swift build -c release
fi

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# Copy SPM resource bundle (contains hook scripts for HookManager)
BUNDLE_PATH="${BUILD_DIR}/Clawdboard_ClawdboardLib.bundle"
if [ -d "$BUNDLE_PATH" ]; then
    cp -R "$BUNDLE_PATH" "${RESOURCES_DIR}/"
fi

# Write Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Clawdboard</string>
    <key>CFBundleDisplayName</key>
    <string>Clawdboard</string>
    <key>CFBundleIdentifier</key>
    <string>com.clawdboard.app</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>Clawdboard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

echo "Bundle created: ${APP_DIR}"
echo "Run with: open ${APP_DIR}"
