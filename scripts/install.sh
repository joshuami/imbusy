#!/bin/bash
# Build imbusy in release mode, install the binary, and load the launchd user agent.
#
# Usage: scripts/install.sh [--interval SECONDS] [--prefix DIR]
#
# Environment:
#   CODESIGN_IDENTITY  Optional. Sign the binary with this identity (for example an
#                      "Apple Development" certificate) so the calendar permission survives rebuilds.
set -euo pipefail

INTERVAL=600
PREFIX="$HOME/.local/bin"
LABEL="local.imbusy.sync"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$PREFIX/imbusy"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/imbusy"
CONFIG="$CONFIG_DIR/config.json"
LOG_DIR="$HOME/Library/Logs/imbusy"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"

echo "==> Building release binary"
(cd "$REPO" && swift build -c release 2>&1 | grep -v "^warning: 'imbusy'" || true)
BUILT="$(cd "$REPO" && swift build -c release --show-bin-path)/imbusy"
[[ -x "$BUILT" ]] || { echo "build failed: $BUILT not found" >&2; exit 1; }

echo "==> Installing to $BINARY"
mkdir -p "$PREFIX" "$LOG_DIR" "$CONFIG_DIR"
# Unload first so we never overwrite a running binary.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
cp "$BUILT" "$BINARY"
chmod 755 "$BINARY"

# SwiftPM leaves the binary "linker-signed", which does not bind the embedded Info.plist to the
# signature. Re-sign so TCC can read the usage description from the code signature. Ad-hoc by
# default; a real identity keeps the permission grant stable across rebuilds.
echo "==> Signing (${CODESIGN_IDENTITY:-ad-hoc})"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier local.imbusy "$BINARY"

if [[ ! -f "$CONFIG" ]]; then
  cp "$REPO/config.example.json" "$CONFIG"
  cat <<MSG

A starter config was written to:
  $CONFIG

It contains placeholder names. Edit it before the agent is loaded:
  1. Run:  $BINARY list-calendars
  2. Copy the exact account and calendar names into the config.
  3. Check the plan:  $BINARY sync --dry-run --verbose
  4. Re-run this installer to load the launchd agent.
MSG
  exit 0
fi

echo "==> Writing $PLIST (every $INTERVAL seconds)"
mkdir -p "$AGENTS_DIR"
sed -e "s|__BINARY__|$BINARY|g" \
    -e "s|__INTERVAL__|$INTERVAL|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$REPO/launchd/$LABEL.plist.template" > "$PLIST"

echo "==> Loading agent"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<MSG

Installed. The agent runs once now and then every $INTERVAL seconds.

If this is the first run, macOS will show a calendar permission prompt for "imbusy"
within a few seconds. Click "Allow Full Access". The prompt attaches to the binary at
  $BINARY
so rebuilding or moving it may trigger the prompt again.

Logs:
  tail -f $LOG_DIR/imbusy.log $LOG_DIR/imbusy.err.log
Run now:
  launchctl kickstart -k gui/$(id -u)/$LABEL
MSG
