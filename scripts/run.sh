#!/bin/zsh
# Build and launch the app.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${1:-release}"
pkill -x MeetingRecorder 2>/dev/null || true
open build/MeetingRecorder.app
