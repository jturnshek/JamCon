#!/bin/bash
# Opt-in build for Apple-approved Virtual HID development provisioning.
# The normal dev.sh intentionally remains entitlement-free.

set -euo pipefail

cd "$(dirname "$0")"

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-3EZHX57W9Y}"
BUILD_LOG="${BUILD_LOG:-/tmp/jamcon-virtual-gamepad-build.log}"
BUILD_ROOT="$PWD/build/VirtualHID"
APP_PATH="$BUILD_ROOT/Build/Products/Release/JamCon.app"
ENTITLEMENTS_PATH="$PWD/Resources/JamCon.VirtualHID.entitlements"

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ]; then
    echo "Virtual gamepads require macOS 15 or later."
    exit 1
fi

if [ -z "$DEVELOPMENT_TEAM" ]; then
    echo "Set DEVELOPMENT_TEAM to the Apple Developer Team ID approved for Virtual HID."
    exit 1
fi

echo "Generating Xcode project..."
xcodegen generate

echo "Building the Virtual HID configuration... (log: $BUILD_LOG)"
xcodebuild \
    -project JamCon.xcodeproj \
    -scheme JamCon \
    -configuration Release \
    -derivedDataPath "$BUILD_ROOT" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS_PATH" \
    clean build 2>&1 | tee "$BUILD_LOG"

if [ ! -d "$APP_PATH" ]; then
    echo "Build artifact missing at $APP_PATH"
    exit 1
fi

signature_entitlements="$(mktemp)"
profile_plist="$(mktemp)"
trap 'rm -f "$signature_entitlements" "$profile_plist"' EXIT

codesign --verify --deep --strict "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" > "$signature_entitlements" 2>/dev/null
signed_value=$(
    /usr/libexec/PlistBuddy \
        -c "Print :com.apple.developer.hid.virtual.device" \
        "$signature_entitlements" 2>/dev/null || true
)
if [ "$signed_value" != "true" ]; then
    echo "The built app is not signed with com.apple.developer.hid.virtual.device."
    echo "The existing /Applications/JamCon.app was not changed."
    exit 1
fi

embedded_profile="$APP_PATH/Contents/embedded.provisionprofile"
if [ ! -f "$embedded_profile" ]; then
    echo "The built app has no embedded provisioning profile."
    echo "The existing /Applications/JamCon.app was not changed."
    exit 1
fi
security cms -D -i "$embedded_profile" > "$profile_plist"
profile_value=$(
    /usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.developer.hid.virtual.device" \
        "$profile_plist" 2>/dev/null || true
)
if [ "$profile_value" != "true" ]; then
    echo "The provisioning profile does not authorize Virtual HID."
    echo "Apple approval may not have propagated to this team/profile yet."
    echo "The existing /Applications/JamCon.app was not changed."
    exit 1
fi

echo "Verified Virtual HID in both the code signature and provisioning profile."
echo "Stopping any running JamCon..."
pkill -x JamCon 2>/dev/null || true
sleep 1

echo "Installing the verified build to /Applications..."
rm -rf /Applications/JamCon.app
ditto "$APP_PATH" /Applications/JamCon.app
xattr -cr /Applications/JamCon.app

echo "Launching JamCon..."
open -a /Applications/JamCon.app
sleep 2
if pgrep -x JamCon > /dev/null; then
    echo "Done. JamCon is running with Apple-authorized Virtual HID."
else
    echo "JamCon did not remain running. Check Console and $BUILD_LOG."
    exit 1
fi
