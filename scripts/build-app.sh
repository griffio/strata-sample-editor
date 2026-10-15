#!/bin/zsh
# Builds Strata.app (release by default) into ./build.
#   scripts/build-app.sh            # release
#   scripts/build-app.sh debug      # debug
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${STRATA_BUILD_DIR:-$ROOT/build}"   # override to build without touching ./build
APP="$BUILD/Strata.app"

cd "$ROOT"
echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Strata"

ICONSET="$BUILD/AppIcon.iconset"
if [[ ! -f "$BUILD/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$BUILD/AppIcon.icns" ]]; then
  echo "▸ Rendering icon…"
  mkdir -p "$ICONSET"
  swift "$ROOT/scripts/make-icon.swift" "$BUILD/AppIcon-1024.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$BUILD/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"
fi

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Strata"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# macOS ties privacy grants (Microphone, Screen & System Audio Recording) to the code
# signature. Ad-hoc signatures change on every build, so grants are lost after each
# rebuild. Set STRATA_SIGN_IDENTITY to a certificate name from
#   security find-identity -v -p codesigning
# (e.g. "Apple Development: you@example.com" or a self-signed "Strata Dev") to keep them.
IDENTITY="${STRATA_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  echo "▸ Signing (ad-hoc — privacy permissions reset on each rebuild; see STRATA_SIGN_IDENTITY)…"
else
  echo "▸ Signing as \"$IDENTITY\"…"
fi
# Sandboxed by default. STRATA_UNSANDBOXED=1 is for scripts/screenshots.sh only (debug builds).
ENTITLEMENTS="$ROOT/Resources/Strata.entitlements"
if [[ "${STRATA_UNSANDBOXED:-0}" == "1" ]]; then
  [[ "$CONFIG" == "debug" ]] || { echo "STRATA_UNSANDBOXED is only allowed for debug builds" >&2; exit 1; }
  ENTITLEMENTS="$ROOT/Resources/Strata-Unsandboxed.entitlements"
  echo "▸ Entitlements: unsandboxed (development only)"
fi
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" --options runtime --timestamp=none "$APP"

echo "✓ $APP"
