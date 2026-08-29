#!/bin/zsh
# Builds MeetingRecorder.app with SwiftPM (no Xcode project needed).
#   scripts/build-app.sh            # release build → build/MeetingRecorder.app
#   scripts/build-app.sh debug      # debug build
#   SIGN_IDENTITY="Apple Development: You (TEAMID)" scripts/build-app.sh   # real signing (stable TCC permissions)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/MeetingRecorder.app"
BIN=".build/$CONFIG/MeetingRecorder"

swift build -c "$CONFIG" --product MeetingRecorder

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MeetingRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (FluidAudio ships one)
for bundle in .build/"$CONFIG"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Signing identity: $SIGN_IDENTITY if set, else the first valid "Apple Development" identity, else ad-hoc.
# (A real identity keeps Microphone / System Audio Recording permissions stable across rebuilds.)
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements Resources/MeetingRecorder.entitlements \
  --options runtime --timestamp=none "$APP" 2>/dev/null \
|| codesign --force --sign "$SIGN_IDENTITY" --entitlements Resources/MeetingRecorder.entitlements "$APP"

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "Built $APP (ad-hoc signed — macOS will re-ask for permissions after every rebuild)"
else
  echo "Built $APP (signed: $SIGN_IDENTITY)"
fi
