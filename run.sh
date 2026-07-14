#!/bin/sh
# Run TypeAhead standalone with logs, the way that makes Accessibility work.
#
# Why `open` and not just running the binary: macOS attributes Accessibility permission
# to the "responsible process". A binary exec'd from a shell makes Terminal responsible
# (and Terminal usually isn't granted AX) → cross-process reads fail with -25204, even
# though the app reports trusted=true. `open` launches via LaunchServices, so TypeAhead
# is its own responsible process and its own grant applies. (Cmd+R is worse still — the
# debugger becomes responsible.)
#
# Usage:
#   1. Build once: Cmd+B in Xcode (NOT Cmd+R), or `xcodebuild -scheme TypeAhead build`.
#   2. ./run.sh        # launches the app and tails its log here
#   (Ctrl+C stops tailing; the app keeps running. Quit it from the menu bar.)

APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/TypeAhead-*/Build/Products/Debug/TypeAhead.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  echo "No built app found. Build it first (Cmd+B in Xcode)."
  exit 1
fi

# Guard: refuse to launch a build that isn't signed for Accessibility. A build
# produced by the headless CODE_SIGNING_ALLOWED=NO compile-check (see CLAUDE.md)
# is ad-hoc signed, not signed "Apple Development". Launching that build grants
# Accessibility to the wrong code identity and poisons the TCC record, forcing
# a re-grant on every subsequent (properly signed) rebuild.
if ! codesign -dv "$APP" 2>&1 | grep -q "Authority=Apple Development"; then
  echo "⚠️  This build is ad-hoc signed, not signed for Accessibility."
  echo "    Launching it would break the Accessibility permission for the real app."
  echo "    Fix: open Xcode, press Cmd+B to rebuild, then run ./run.sh again."
  exit 1
fi

LOG="${TMPDIR:-/tmp}/typeahead.log"
: > "$LOG"   # truncate

# Stop any previously-launched standalone instance (leaves Xcode-run ones alone).
pkill -x TypeAhead 2>/dev/null || true
sleep 0.5

# LaunchServices launch (correct responsible process) with output redirected to LOG.
open -n --stdout "$LOG" --stderr "$LOG" "$APP"

echo "Launched: $APP"
echo "Log: $LOG  (tailing — Ctrl+C to stop; app keeps running)"
echo "----------------------------------------------------------------"
exec tail -f "$LOG"
