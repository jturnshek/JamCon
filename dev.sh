#!/bin/bash
# Development script: builds and installs JamCon to /Applications

set -euo pipefail

cd "$(dirname "$0")"

SIGNING_IDENTITY="Apple Development: James Turnshek (FY9D4ZL9L8)"
BUILD_LOG="${BUILD_LOG:-/tmp/jamcon-build.log}"

# Generate Xcode project if needed
if [ ! -f "JamCon.xcodeproj/project.pbxproj" ]; then
    echo "Generating Xcode project..."
    xcodegen generate
fi

# Clean build directory to avoid stale artifacts
echo "Cleaning build directory..."
rm -rf build

echo "Building JamCon (Release)... (log: $BUILD_LOG)"
xcodebuild -scheme JamCon -configuration Release -derivedDataPath build -quiet 2>&1 | tee "$BUILD_LOG"

APP_PATH="build/Build/Products/Release/JamCon.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build artifact missing at $APP_PATH"
    exit 1
fi

echo "Stopping any running JamCon..."
pkill -x JamCon 2>/dev/null || true
sleep 1  # Wait for process to fully terminate

echo "Installing to /Applications..."
rm -rf /Applications/JamCon.app
cp -R "$APP_PATH" /Applications/
xattr -cr /Applications/JamCon.app

echo "Signing with Developer ID..."
codesign --force --sign "$SIGNING_IDENTITY" --entitlements Resources/JamCon.entitlements --options runtime /Applications/JamCon.app

echo "Launching JamCon..."
open -a /Applications/JamCon.app

# Verify the app started
sleep 2
if pgrep -x JamCon > /dev/null; then
    echo "Done! JamCon is running."
else
    echo "Warning: JamCon may have crashed on startup. Check crash reports."
    exit 1
fi
