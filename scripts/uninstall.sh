#!/bin/bash
# Unload the launchd agent and remove the installed binary.
#
# Usage: scripts/uninstall.sh [--purge] [--all] [--prefix DIR]
#   --purge   Delete every hold imbusy created before uninstalling (runs `imbusy purge`).
#   --all     Also delete the config file and logs.
set -euo pipefail

PURGE=0
ALL=0
PREFIX="$HOME/.local/bin"
LABEL="local.imbusy.sync"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --all) ALL=1; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

BINARY="$PREFIX/imbusy"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/imbusy"
LOG_DIR="$HOME/Library/Logs/imbusy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Unloading agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

if [[ $PURGE -eq 1 ]]; then
  if [[ -x "$BINARY" ]]; then
    echo "==> Removing holds"
    "$BINARY" purge
  else
    echo "cannot purge: $BINARY not found" >&2
    exit 1
  fi
fi

echo "==> Removing $BINARY"
rm -f "$BINARY"

if [[ $ALL -eq 1 ]]; then
  echo "==> Removing config and logs"
  rm -rf "$CONFIG_DIR" "$LOG_DIR"
fi

echo "Done. To revoke calendar access: System Settings > Privacy & Security > Calendars."
