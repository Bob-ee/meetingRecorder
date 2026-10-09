#!/bin/sh
# Generates Apps/iOS/MeetingRecorder.xcodeproj from Apps/iOS/project.yml and opens it.
#   scripts/ios-project.sh            # generate and open in Xcode
#   scripts/ios-project.sh --no-open  # just generate
# Needs XcodeGen:  brew install xcodegen
set -eu
cd "$(dirname "$0")/../Apps/iOS"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen isn't installed. Run:  brew install xcodegen"
  exit 1
fi

xcodegen generate --quiet
echo "Generated Apps/iOS/MeetingRecorder.xcodeproj"
[ "${1:-}" = "--no-open" ] || open MeetingRecorder.xcodeproj
