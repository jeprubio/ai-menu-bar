#!/usr/bin/env bash
# Enable/disable the AI usage menu bar app at login (LaunchAgent).
# Usage: ./login-item.sh on | off | status

set -euo pipefail
plist="$HOME/Library/LaunchAgents/com.local.aimenubar.plist"

case "${1:-}" in
  on)
    launchctl load "$plist"
    echo "Enabled. The menu bar item will launch at login."
    ;;
  off)
    launchctl unload "$plist" 2>/dev/null || true
    echo "Disabled."
    ;;
  status)
    launchctl list | grep -q "com.local.aimenubar" && echo "enabled (loaded)" || echo "not loaded"
    ;;
  *)
    echo "Usage: $0 on|off|status" >&2
    exit 2
    ;;
esac