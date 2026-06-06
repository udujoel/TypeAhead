#!/bin/sh
# Run TypeAhead standalone (NOT under Xcode's debugger) with logs in this terminal.
#
# Why: TypeAhead reads other apps' text via the Accessibility API. When the app is
# launched with Cmd+R, Xcode's debugger attaches and macOS denies those cross-process
# AX reads (error -25204) — so ghost text can't find the caret and Tab is flaky.
# Launching from a terminal attaches no debugger (AX works) and is a TTY (logs stream).
#
# Usage:
#   1. Build in Xcode once with Cmd+B (NOT Cmd+R), or: xcodebuild -scheme TypeAhead build
#   2. ./run.sh
#   3. Grant Accessibility if prompted, then type in any app.

set -e

APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/TypeAhead-*/Build/Products/Debug/TypeAhead.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  echo "No built app found. Build it first: open the project and press Cmd+B."
  exit 1
fi

# Stop any standalone instance we previously launched (leaves Xcode-run instances alone;
# stop those with Xcode's Stop button / Cmd+.).
pkill -x TypeAhead 2>/dev/null || true
sleep 0.5

echo "Launching: $APP"
echo "(Press Ctrl+C here to quit. Logs stream below.)"
exec "$APP/Contents/MacOS/TypeAhead"
