#!/bin/zsh
# Regenerates the README screenshots in docs/screenshots using the debug build's
# self-capture hook (no Screen Recording permission needed). Uses the demo kit and a
# synthetic input signal, so no microphone access is requested.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
TMP="$(mktemp -d)"
cd "$ROOT"
STRATA_UNSANDBOXED=1 scripts/build-app.sh debug >/dev/null   # capture hook writes outside the sandbox
BIN="build/Strata.app/Contents/MacOS/Strata"

shot() {   # name demo steps
  STRATA_SNAPSHOT="$TMP/$1" STRATA_DEMO="$2" STRATA_STEPS="$3" STRATA_SIZE=1600x1000 STRATA_QUIT=1 "$BIN" >/dev/null 2>&1
  local steps=("${(@s/,/)3}")
  local last=("$TMP/$1-$(( ${#steps} - 1 ))-"*.png)
  cp "${last[1]}" "$OUT/$4.png"
  sips -Z 2000 "$OUT/$4.png" >/dev/null
  echo "✓ $4"
}

mkdir -p "$OUT"
shot empty      0 size,wait                                          empty-project
shot hero       1 size,fit,wait,slice,wait,wait,selslice,play,wait   arrangement
shot slicing    1 size,fit,slice,wait,wait,edzoom,selslice,wait      sample-editor
shot record     1 size,fit,devsource,arm,rec,wait,wait,wait,wait     loop-recording
shot stretch    1 size,fit,tonal,stretchbeats,wait,wait              time-stretch
shot slicetrack 1 size,slice,wait,slicetrack,fit,wait,wait           slices-to-track
cp build/AppIcon-1024.png "$OUT/icon.png" && sips -Z 256 "$OUT/icon.png" >/dev/null
rm -rf "$TMP"
