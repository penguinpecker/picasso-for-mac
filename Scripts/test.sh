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
ALL=(window screen2 fit exif formats large blur click esc cmdw cmdq activate argv odoc folder panel emptyfolder odocempty
     panelodoc corrupt rapid screenchange)
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
BIN="$APP/Contents/MacOS/Lightbox"

# Files outside the read-only-checked fixtures: LaunchServices stamps com.apple.lastuseddate#PS on
# documents it opens, so LaunchServices scenarios get a copy; plus a non-image named like a JPEG.
LS_FILE="$BUILD/fixtures-ls/01-landscape.jpg"
rm -rf "$BUILD/fixtures-ls" "$BUILD/fixtures-bad" "$BUILD/empty-folder"
mkdir -p "$BUILD/fixtures-ls" "$BUILD/fixtures-bad" "$BUILD/empty-folder"
cp -X "$FIX/01-landscape.jpg" "$LS_FILE"
printf 'not an image\n' > "$BUILD/fixtures-bad/broken.jpg"

snapshot() { find "$FIX" -type f -exec stat -f '%N %z %m %c' {} + | sort; xattr -lr "$FIX"; }
BEFORE="$(snapshot)"

if [ $# -gt 0 ]; then SCENARIOS=("$@"); else SCENARIOS=("${ALL[@]}"); fi
PASSED=0; FAILED=()
for s in "${SCENARIOS[@]}"; do
  L="$FIX/01-landscape.jpg"; LS_ARG=""
  case "$s" in
    exif)   ARGS=("$FIX/04-exif6.jpg") ;;
    large)  ARGS=("$FIX/10-huge.jpg") ;;
    blur)   ARGS=(-backdropStyle blur "$L") ;;
    folder) ARGS=("$FIX") ;;
    panel|panelodoc) ARGS=() ;;
    odoc)   LS_ARG="$LS_FILE" ;;
    odocempty) LS_ARG="$BUILD/empty-folder" ;;
    corrupt) ARGS=("$BUILD/fixtures-bad/broken.jpg") ;;
    emptyfolder) ARGS=("$BUILD/empty-folder") ;;
    *)      ARGS=("$L") ;;
  esac
  rm -f "$OUT/$s".* "$OUT/$s"-*
  start=$(date +%s)
  if [ -n "$LS_ARG" ]; then
    # Through LaunchServices like Finder (-g: stay in the background, -W: wait for exit).
    perl -e 'alarm shift; exec @ARGV' 30 open -W -g -n -a "$APP" --env LIGHTBOX_SELFTEST="$s" \
      --env LIGHTBOX_SELFTEST_OUT="$OUT" --env LIGHTBOX_FIXTURES="$FIX" \
      --stdout "$OUT/$s.log" --stderr "$OUT/$s.log" "$LS_ARG"
  else
    LIGHTBOX_SELFTEST="$s" LIGHTBOX_SELFTEST_OUT="$OUT" LIGHTBOX_FIXTURES="$FIX" LIGHTBOX_ODOC_FILE="$LS_FILE" \
      perl -e 'alarm shift; exec @ARGV' 30 "$BIN" ${ARGS[@]+"${ARGS[@]}"} > "$OUT/$s.log" 2>&1
  fi
  rc=$?
  verdict="$(plutil -extract pass raw -o - "$OUT/$s.json" 2>/dev/null)"
  if [ $rc -eq 0 ] && [ "$verdict" = true ]; then
    PASSED=$((PASSED + 1)); echo "PASS  $s ($(( $(date +%s) - start ))s)"
  else
    FAILED+=("$s"); echo "FAIL  $s (exit $rc)"; grep -E "FAIL|error|Fatal" "$OUT/$s.log" | sed 's/^/      /' | head -20
  fi
  [ -f "$OUT/$s.png" ] && sips -Z 1400 "$OUT/$s.png" --out "$OUT/$s-1400.png" >/dev/null 2>&1
done

if [ "$BEFORE" = "$(snapshot)" ]; then
  echo "PASS  fixtures untouched (size/mtime/ctime/xattrs)"; PASSED=$((PASSED + 1))
else
  echo "FAIL  fixtures were modified"; FAILED+=(read-only)
fi

echo "SUMMARY: $PASSED passed, ${#FAILED[@]} failed${FAILED[*]:+ (${FAILED[*]})}"
[ ${#FAILED[@]} -eq 0 ]
