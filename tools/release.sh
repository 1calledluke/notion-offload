#!/bin/bash
# Cuts a GitHub release: builds the app, zips it, tags VERSION, uploads.
# Usage: ./tools/release.sh            (uses VERSION file)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
./build.sh
ZIP="dist/DIT-Media-Ingest-v$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "dist/DIT Media Ingest.app" "$ZIP"
git tag -f "v$VERSION"
git push -q origin main --tags
gh release create "v$VERSION" "$ZIP" --title "v$VERSION" --generate-notes 2>/dev/null \
  || gh release upload "v$VERSION" "$ZIP" --clobber
echo "==> Released v$VERSION"
