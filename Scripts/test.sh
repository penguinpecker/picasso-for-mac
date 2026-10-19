#!/bin/bash
# GUI self-tests: builds the SELFTEST app, then launches it once per scenario.
#   test.sh               run every scenario
#   test.sh fit click     run a subset
# Results: build/test-results/<scenario>.{json,log,png}
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
FIX="$BUILD/fixtures"
OUT="$BUILD/test-results"
LOCK="$BUILD/.gui-lock"
ALL=(window screen2 fit exif formats large blur opacity click edgeclick esc escearly cmdw cmdq activate argv odoc folder
     panel emptyfolder odocempty panelodoc corrupt rapid screenchange index keys wheel stale secondopen
     zoomkeys zoompoint zoommode pan rotate dblclick bar slideshow autohide label strip thumbs fly flypng flypnghidden gif)
mkdir -p "$BUILD" "$OUT"

# One GUI run at a time (stale locks from dead processes are reclaimed).
while ! mkdir "$LOCK" 2>/dev/null; do
  pid="$(cat "$LOCK/pid" 2>/dev/null)"
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
  echo "waiting for GUI lock (pid ${pid:-?})..."
  sleep 2
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# Fixtures: regenerate when missing or when the generator changed.
STAMP="$(shasum "$ROOT/Scripts/make-fixtures.swift" | cut -d' ' -f1)"
if [ "$(cat "$FIX/.stamp" 2>/dev/null)" != "$STAMP" ]; then
  echo "generating fixtures..."
  rm -rf "$FIX" "$BUILD/fixtures-scratch"
  mkdir -p "$BUILD/tools"
  swiftc -O -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -o "$BUILD/tools/make-fixtures" \
    "$ROOT/Scripts/make-fixtures.swift" || exit 1
  "$BUILD/tools/make-fixtures" "$FIX" "$BUILD/fixtures-scratch" || exit 1
  echo "$STAMP" > "$FIX/.stamp"
fi

APP="$("$ROOT/Scripts/build.sh" selftest)" || { echo "BUILD FAILED"; exit 1; }
BIN="$APP/Contents/MacOS/Picasso"

# Asleep display or locked session: every scenario would fail for no reason, so say that instead.
PICASSO_SELFTEST=preflight perl -e 'alarm shift; exec @ARGV' 10 "$BIN"; rc=$?
if [ $rc -eq 2 ]; then echo "display asleep/locked — GUI tests cannot run"; exit 2; fi
[ $rc -ne 0 ] && { echo "preflight failed (exit $rc)"; exit 1; }

# Files outside the read-only-checked fixtures: LaunchServices stamps com.apple.lastuseddate#PS on
# documents it opens, so LaunchServices scenarios get a copy; plus a non-image named like a JPEG
# and a symlink to the nav folder.
LS_FILE="$BUILD/fixtures-ls/01-landscape.jpg"
rm -rf "$BUILD/fixtures-ls" "$BUILD/fixtures-bad" "$BUILD/empty-folder" "$BUILD/nav-link"
mkdir -p "$BUILD/fixtures-ls" "$BUILD/fixtures-bad" "$BUILD/empty-folder"
cp -X "$FIX/01-landscape.jpg" "$LS_FILE"
printf 'not an image\n' > "$BUILD/fixtures-bad/broken.jpg"
ln -s "$FIX/nav" "$BUILD/nav-link"

snapshot() { find "$FIX" -type f -exec stat -f '%N %z %m %c' {} + | sort; find "$FIX" -type f -exec shasum -a 256 {} + | sort; xattr -lr "$FIX"; }
BEFORE="$(snapshot)"

if [ $# -gt 0 ]; then SCENARIOS=("$@"); else SCENARIOS=("${ALL[@]}"); fi
PASSED=0; FAILED=()
for s in "${SCENARIOS[@]}"; do
  L="$FIX/01-landscape.jpg"; LS_ARG=""; LIMIT=30
  case "$s" in
    exif)   ARGS=("$FIX/04-exif6.jpg") ;;
    large)  ARGS=("$FIX/10-huge.jpg") ;;
    blur)   ARGS=(-backdropStyle blur "$L") ;;
    opacity) ARGS=(-backdropOpacity 0.1 "$L") ;;
    folder|keys|wheel|slideshow|label) ARGS=("$FIX/nav") ;;
    strip)  ARGS=("$FIX/many") ;;
    fly)    ARGS=("$FIX/many"); LIMIT=120 ;; # 1199 keys at 30 Hz
    flypng) ARGS=("$FIX/plain") ;;
    flypnghidden) ARGS=(-showThumbnails NO "$FIX/plain") ;;
    gif)    ARGS=("$FIX/gif/anim.gif") ;;
    zoommode) ARGS=(-scrollWheelAction zoom "$L") ;;
    autohide) ARGS=("$FIX/02-portrait.jpg") ;;
    index)  ARGS=("$FIX/nav/img1.jpg") ;;
    panel|panelodoc) ARGS=() ;;
    odoc)   LS_ARG="$LS_FILE" ;;
    odocempty) LS_ARG="$BUILD/empty-folder" ;;
    corrupt) ARGS=("$BUILD/fixtures-bad/broken.jpg") ;;
    emptyfolder) ARGS=("$BUILD/empty-folder") ;;
    *)      ARGS=("$L") ;;
  esac
  rm -rf "$OUT/$s".* "$OUT/$s"-*
  start=$(date +%s)
  if [ -n "$LS_ARG" ]; then
    # Through LaunchServices like Finder (-g: stay in the background, -W: wait for exit).
    perl -e 'alarm shift; exec @ARGV' 30 open -W -g -n -a "$APP" --env PICASSO_SELFTEST="$s" \
      --env PICASSO_SELFTEST_OUT="$OUT" --env PICASSO_FIXTURES="$FIX" \
      --stdout "$OUT/$s.log" --stderr "$OUT/$s.log" "$LS_ARG"
  else
    PICASSO_SELFTEST="$s" PICASSO_SELFTEST_OUT="$OUT" PICASSO_FIXTURES="$FIX" PICASSO_ODOC_FILE="$LS_FILE" \
      perl -e 'alarm shift; exec @ARGV' "$LIMIT" "$BIN" ${ARGS[@]+"${ARGS[@]}"} > "$OUT/$s.log" 2>&1
  fi
  rc=$?
  # The alarm kills `open -W`, not the app LaunchServices started: never leave a hung test window up.
  [ $rc -ne 0 ] && pkill -f "$BIN"
  verdict="$(plutil -extract pass raw -o - "$OUT/$s.json" 2>/dev/null)"
  if [ $rc -eq 0 ] && [ "$verdict" = true ]; then
    PASSED=$((PASSED + 1)); echo "PASS  $s ($(( $(date +%s) - start ))s)"
  else
    FAILED+=("$s"); echo "FAIL  $s (exit $rc)"; grep -E "FAIL|error|Fatal" "$OUT/$s.log" | sed 's/^/      /' | head -20
  fi
  [ -f "$OUT/$s.png" ] && sips -Z 1400 "$OUT/$s.png" --out "$OUT/$s-1400.png" >/dev/null 2>&1
done

if [ "$BEFORE" = "$(snapshot)" ]; then
  echo "PASS  fixtures untouched (size/mtime/ctime/SHA-256/xattrs)"; PASSED=$((PASSED + 1))
else
  echo "FAIL  fixtures were modified"; FAILED+=(read-only)
fi

echo "SUMMARY: $PASSED passed, ${#FAILED[@]} failed${FAILED[*]:+ (${FAILED[*]})}"
[ ${#FAILED[@]} -eq 0 ]
