#!/bin/bash
# Development script: builds and installs JamCon to /Applications

set -e

SIGNING_IDENTITY="Apple Development: James Turnshek (FY9D4ZL9L8)"

echo "🔨 Building JamCon (Release)..."
xcodebuild -scheme JamCon -configuration Release -derivedDataPath build -quiet

echo "🛑 Stopping any running JamCon..."
pkill -x JamCon 2>/dev/null || true

echo "📦 Installing to /Applications..."
rm -rf /Applications/JamCon.app
cp -R build/Build/Products/Release/JamCon.app /Applications/
xattr -cr /Applications/JamCon.app

echo "🔏 Signing with Developer ID..."
codesign --force --sign "$SIGNING_IDENTITY" --entitlements Resources/JamCon.entitlements --options runtime /Applications/JamCon.app

echo "🚀 Launching JamCon..."
open /Applications/JamCon.app

echo "✅ Done!"
