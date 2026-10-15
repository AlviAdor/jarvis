#!/bin/sh
# Builds a release binary and wraps it in Jarvis.app so macOS permissions attach to a stable identity.
set -e
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
swift build -c release
APP=build/Jarvis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Jarvis "$APP/Contents/MacOS/Jarvis"
cp Sources/Jarvis/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "build/Jarvis-$VERSION.zip"
echo "Built $APP and build/Jarvis-$VERSION.zip"
