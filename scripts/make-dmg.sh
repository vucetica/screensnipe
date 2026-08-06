#!/bin/bash
# Builds the styled drag-to-install DMG.
#
#   scripts/make-dmg.sh <path-to-.app> <output.dmg>
#
# Layout: the app sits on the left, the /Applications alias on the right, with
# the annotated background (distribution/dmg/background.tiff) drawn behind them.
# See distribution/dmg/dmgbuild-settings.py for the window geometry.
#
# Uses dmgbuild, which writes the .DS_Store directly rather than driving Finder
# over AppleScript. That matters because GitHub runners (and any sandboxed local
# shell) are not authorized to send Apple events to Finder.

set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh <path-to-.app> <output.dmg>}"
OUTPUT_DMG="${2:?usage: make-dmg.sh <path-to-.app> <output.dmg>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_ASSETS="$REPO_ROOT/distribution/dmg"
VOLUME_NAME="${VOLUME_NAME:-Screen Snipe}"

test -d "$APP_PATH" || { echo "no such app: $APP_PATH" >&2; exit 1; }
test -f "$DMG_ASSETS/background.tiff" || {
  echo "missing $DMG_ASSETS/background.tiff — run scripts/build-dmg-background.sh" >&2
  exit 1
}

if ! command -v dmgbuild >/dev/null 2>&1; then
  echo "dmgbuild not found. Install it with:  pipx install dmgbuild" >&2
  exit 1
fi

# dmgbuild needs an absolute path; it resolves the app relative to its own cwd.
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"

rm -f "$OUTPUT_DMG"
dmgbuild \
  -s "$DMG_ASSETS/dmgbuild-settings.py" \
  -D app_path="$APP_PATH" \
  -D assets_dir="$DMG_ASSETS" \
  "$VOLUME_NAME" \
  "$OUTPUT_DMG"

echo "wrote $OUTPUT_DMG"
