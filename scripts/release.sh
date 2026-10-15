#!/bin/sh
# Usage: scripts/release.sh 0.3.0
# Bumps VERSION, commits, tags and pushes; the Release workflow then builds and publishes the app.
set -e
cd "$(dirname "$0")/.."
[ -n "$1" ] || { echo "usage: $0 <version>"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree not clean."; exit 1; }
echo "$1" > VERSION
git add VERSION
git commit -m "Release $1"
git tag "v$1"
git push origin main "v$1"
