#!/bin/bash
# Regenerates distribution/dmg/background.tiff from scripts/dmg-background.swift.
#
# Run this after editing the background design, then commit the .tiff. CI does
# not run this — it consumes the committed artwork so releases stay reproducible.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/distribution/dmg"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUT_DIR"

swift "$REPO_ROOT/scripts/dmg-background.swift" "$WORK_DIR"

# Pack 1x and 2x into a single multi-representation TIFF so Finder picks the
# right one on Retina displays.
tiffutil -cathidpicheck \
  "$WORK_DIR/background.png" \
  "$WORK_DIR/background@2x.png" \
  -out "$OUT_DIR/background.tiff"

# Keep the flat PNGs around for previewing the design without mounting a DMG.
cp "$WORK_DIR/background.png" "$OUT_DIR/background-preview.png"

echo "wrote $OUT_DIR/background.tiff"
