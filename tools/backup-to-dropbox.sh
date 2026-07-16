#!/bin/bash
# Mirrors this repo (source + full git history, no build artifacts) into
# Dropbox under 05_Resources/Code Backups. Run any time; rsync makes it cheap.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Users/luke/Library/CloudStorage/Dropbox/05_Resources/Code Backups/dit-ingest-app"
mkdir -p "$DEST"
rsync -a --delete \
  --exclude ".build" --exclude "dist" --exclude ".DS_Store" \
  "$SRC/" "$DEST/"
echo "Backed up to: $DEST"
du -sh "$DEST"
