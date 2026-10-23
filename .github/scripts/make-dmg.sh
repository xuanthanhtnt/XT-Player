#!/usr/bin/env bash
# Builds a drag-to-install DMG: XT-Player.app + Applications shortcut on a branded background.
# Usage: make-dmg.sh <path/to/XTPlayer.app> <output.dmg>
set -euo pipefail

APP="$1"
OUT="$2"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/stage" "$(dirname "$OUT")"
cp -R "$APP" "$WORK/stage/XT-Player.app"
rm -f "$OUT"

# Retina-aware background: @1x + @2x combined into one multi-resolution TIFF.
BG="$WORK/background.tiff"
tiffutil -cathidpicheck "$ROOT/Assets/Branding/dmg-background.png" "$ROOT/Assets/Branding/dmg-background@2x.png" -out "$BG"
VOLICON="$APP/Contents/Resources/AppIcon.icns"

if command -v create-dmg >/dev/null 2>&1 || brew install create-dmg >/dev/null 2>&1; then
  ARGS=(--volname "XT-Player" --background "$BG" --window-pos 200 120 --window-size 660 400
        --icon-size 112 --text-size 13 --icon "XT-Player.app" 170 196 --hide-extension "XT-Player.app"
        --app-drop-link 490 196 --hdiutil-retries 6)
  [ -f "$VOLICON" ] && ARGS+=(--volicon "$VOLICON")
  # Finder lays the window out through AppleScript; on a headless runner that can fail, so fall back.
  if create-dmg "${ARGS[@]}" "$OUT" "$WORK/stage" || create-dmg --skip-jenkins "${ARGS[@]}" "$OUT" "$WORK/stage"; then
    echo "DMG created with create-dmg"
  fi
fi

if [ ! -f "$OUT" ]; then
  echo "create-dmg unavailable or failed — plain hdiutil DMG"
  ln -s /Applications "$WORK/stage/Applications"
  hdiutil create -volname "XT-Player" -srcfolder "$WORK/stage" -ov -format UDZO "$OUT"
fi

hdiutil verify "$OUT"
echo "::notice title=macOS DMG::$(basename "$OUT") · $(du -h "$OUT" | cut -f1)"
