#!/bin/sh
# Installs the Meeting Hub on this machine and runs first-time setup.
#
#   curl -fsSL https://raw.githubusercontent.com/Bob-ee/meetingRecorder/main/scripts/install-hub.sh | sh
#
# What it does:
#   1. builds `meetinghub` from source into ~/.meetinghub (needs the Swift toolchain:
#      on macOS `xcode-select --install`, on Linux https://swift.org/install)
#   2. puts a `meetinghub` command on your PATH (~/.local/bin)
#   3. runs `meetinghub setup`, which creates your account, prints a pairing code
#      for your devices and starts the hub as a background service
#
# Re-run it any time to update: it pulls the latest code and rebuilds.
set -eu

REPO="${MEETINGHUB_REPO:-https://github.com/Bob-ee/meetingRecorder.git}"
BRANCH="${MEETINGHUB_BRANCH:-main}"
HOME_DIR="${HOME:?}"
ROOT="$HOME_DIR/.meetinghub"
SRC="$ROOT/src"
BIN="$ROOT/bin"
LINK_DIR="$HOME_DIR/.local/bin"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift isn't installed."
  case "$(uname)" in
    Darwin) echo "Run:  xcode-select --install   (Command Line Tools are enough), then run this script again." ;;
    *)      echo "Install a Swift toolchain from https://swift.org/install and run this script again." ;;
  esac
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then echo "git is required."; exit 1; fi

mkdir -p "$ROOT" "$BIN" "$LINK_DIR"

if [ -d "$SRC/.git" ]; then
  say "Updating source…"
  # The clone is shallow and single-branch, so widen it before fetching — otherwise asking for any branch
  # other than the one it was cloned with fails with "pathspec ... did not match any file(s) known to git".
  git -C "$SRC" remote set-branches origin '*' 2>/dev/null || true
  git -C "$SRC" fetch -q --depth 1 origin "$BRANCH"
  git -C "$SRC" checkout -q -B "$BRANCH" FETCH_HEAD
else
  say "Fetching source…"
  git clone -q --depth 1 -b "$BRANCH" "$REPO" "$SRC"
fi

say "Building meetinghub (first build takes several minutes)…"
cd "$SRC"
# If Xcode is installed but its license isn't accepted, fall back to the Command Line Tools.
if [ "$(uname)" = "Darwin" ] && ! swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release --product meetinghub 2>&1 | grep -E "error:|warning: unre|Compiling|Build" | tail -3

# Install the binary next to its resource bundles.
# New inode, so a running service keeps executing the old file until it restarts.
rm -f "$BIN/meetinghub"
cp ".build/release/meetinghub" "$BIN/meetinghub"
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] && rm -rf "$BIN/$(basename "$bundle")" && cp -R "$bundle" "$BIN/"
done
cat > "$LINK_DIR/meetinghub" <<WRAP
#!/bin/sh
exec "$BIN/meetinghub" "\$@"
WRAP
chmod +x "$LINK_DIR/meetinghub"

case ":$PATH:" in
  *":$LINK_DIR:"*) ;;
  *) echo "Note: add $LINK_DIR to your PATH to run 'meetinghub' directly." ;;
esac

say "Installed $BIN/meetinghub"
if [ "${MEETINGHUB_NO_SETUP:-}" = "1" ]; then
  echo "Skipping setup (MEETINGHUB_NO_SETUP=1). Run: meetinghub setup"
else
  # Restart an already-installed service so it picks up the new build; otherwise run setup.
  if "$BIN/meetinghub" service status 2>/dev/null | grep -q "installed, running"; then
    "$BIN/meetinghub" service restart
    say "Updated and restarted the running hub."
  else
    exec "$BIN/meetinghub" setup "$@"
  fi
fi
