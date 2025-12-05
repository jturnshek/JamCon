#!/bin/bash
# Development script: builds and installs PSVR2Gyro to /Applications

set -e

cd "$(dirname "$0")"

SIGNING_IDENTITY="Apple Development: James Turnshek (FY9D4ZL9L8)"

# Generate Xcode project if needed
if [ ! -f "PSVR2Gyro.xcodeproj/project.pbxproj" ]; then
    echo "Generating Xcode project..."
    xcodegen generate
fi

echo "Building PSVR2Gyro (Release)..."
xcodebuild -scheme PSVR2Gyro -configuration Release -derivedDataPath build -quiet

echo "Stopping any running PSVR2Gyro..."
pkill -x PSVR2Gyro 2>/dev/null || true

echo "Installing to /Applications..."
rm -rf /Applications/PSVR2Gyro.app
cp -R build/Build/Products/Release/PSVR2Gyro.app /Applications/
xattr -cr /Applications/PSVR2Gyro.app

echo "Signing with Developer ID..."
codesign --force --sign "$SIGNING_IDENTITY" --entitlements Resources/PSVR2Gyro.entitlements --options runtime /Applications/PSVR2Gyro.app

echo "Launching PSVR2Gyro..."
open /Applications/PSVR2Gyro.app

echo "Done!"
