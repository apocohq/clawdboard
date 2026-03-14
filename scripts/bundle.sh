#!/bin/bash
# Creates a proper .app bundle from the built binary.
# Usage: ./scripts/bundle.sh
set -euo pipefail

APP_NAME="Clawdboard"
BUILD_DIR=".build/release"
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# Copy hook script
cp hooks/clawdboard-hook.py "${RESOURCES_DIR}/clawdboard-hook.py"
chmod +x "${RESOURCES_DIR}/clawdboard-hook.py"

# Write Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << 'PLIST'
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
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
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
