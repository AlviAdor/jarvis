#!/bin/sh
# Builds a release binary and wraps it in Jarvis.app, signed with the hardened runtime.
set -e
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
swift build -c release
APP=build/Jarvis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Jarvis "$APP/Contents/MacOS/Jarvis"
cp Sources/Jarvis/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ] || [ scripts/make_icon.swift -nt build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    swift scripts/make_icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/" 2>/dev/null || true

# A stable signature keeps macOS permissions and Keychain access across rebuilds.
IDENTITY=$(./scripts/signing.sh)
codesign --force --options runtime --entitlements scripts/Jarvis.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
ditto -c -k --keepParent "$APP" "build/Jarvis-$VERSION.zip"
echo "Built $APP and build/Jarvis-$VERSION.zip"
