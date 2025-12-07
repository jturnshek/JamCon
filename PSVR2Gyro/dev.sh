#!/bin/bash
# Development script: builds and installs PSVR2Gyro to /Applications

set -euo pipefail

cd "$(dirname "$0")"

SIGNING_IDENTITY="Apple Development: James Turnshek (FY9D4ZL9L8)"
BUILD_LOG="${BUILD_LOG:-/tmp/psvr2gyro-build.log}"

# Generate Xcode project if needed
if [ ! -f "PSVR2Gyro.xcodeproj/project.pbxproj" ]; then
    echo "Generating Xcode project..."
    xcodegen generate
fi

# Clean build directory to avoid stale artifacts
echo "Cleaning build directory..."
rm -rf build

echo "Building PSVR2Gyro (Release)... (log: $BUILD_LOG)"
xcodebuild -scheme PSVR2Gyro -configuration Release -derivedDataPath build -quiet 2>&1 | tee "$BUILD_LOG"

APP_PATH="build/Build/Products/Release/PSVR2Gyro.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build artifact missing at $APP_PATH"
    exit 1
fi

echo "Stopping any running PSVR2Gyro..."
pkill -x PSVR2Gyro 2>/dev/null || true
sleep 1  # Wait for process to fully terminate

echo "Installing to /Applications..."
rm -rf /Applications/PSVR2Gyro.app
cp -R "$APP_PATH" /Applications/
xattr -cr /Applications/PSVR2Gyro.app

echo "Signing with Developer ID..."
codesign --force --sign "$SIGNING_IDENTITY" --entitlements Resources/PSVR2Gyro.entitlements --options runtime /Applications/PSVR2Gyro.app

echo "Launching PSVR2Gyro..."
open -a /Applications/PSVR2Gyro.app

# Verify the app started
sleep 2
if pgrep -x PSVR2Gyro > /dev/null; then
    echo "Done! PSVR2Gyro is running."
else
    echo "Warning: PSVR2Gyro may have crashed on startup. Check crash reports."
    exit 1
fi
