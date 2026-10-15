#!/bin/sh
# Builds a release binary and wraps it in Jarvis.app so macOS permissions attach to a stable identity.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Jarvis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Jarvis "$APP/Contents/MacOS/Jarvis"
cp Sources/Jarvis/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
