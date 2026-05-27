#!/bin/bash
# Usage: ./scripts/notarize.sh path/to/TypeAhead.app
set -e
APP="$1"
BUNDLE_ID="app.typeahead.TypeAhead"
TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID env var}"
APPLE_ID="${APPLE_ID:?Set APPLE_ID env var}"
APP_PASSWORD="${APP_PASSWORD:?Set APP_PASSWORD env var}"

echo "Creating zip for notarization…"
ditto -c -k --keepParent "$APP" TypeAhead-notarize.zip

echo "Submitting for notarization…"
xcrun notarytool submit TypeAhead-notarize.zip \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

echo "Stapling ticket…"
xcrun stapler staple "$APP"
rm TypeAhead-notarize.zip
echo "Done."
