#!/bin/sh
# Builds Jarvis, installs it in /Applications (so Spotlight, Launchpad and the Dock find it) and opens it.
set -e
cd "$(dirname "$0")/.."
./scripts/bundle.sh
DEST=/Applications/Jarvis.app

# Quit a running copy so the new one replaces it cleanly.
osascript -e 'tell application id "app.jarvis" to quit' >/dev/null 2>&1 || true
sleep 1

# Permissions given to builds signed differently no longer apply, yet still show as switched on in
# System Settings. Clear them once whenever the signing identity changes, so macOS asks cleanly.
MARK="$HOME/Library/Application Support/JarvisSigning/permissions-reset-for"
REQ=$(codesign -d -r- build/Jarvis.app 2>&1 | sed -n 's/^designated => //p')
if [ "$(cat "$MARK" 2>/dev/null)" != "$REQ" ]; then
    tccutil reset All app.jarvis >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$MARK")"
    echo "$REQ" > "$MARK"
    echo "Cleared old permission records; macOS will ask once more."
fi

rm -rf "$DEST"
ditto build/Jarvis.app "$DEST"
open "$DEST"
echo "Installed $DEST"
