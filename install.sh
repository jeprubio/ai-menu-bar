#!/usr/bin/env bash
# Install the AI usage menu bar app (Claude Code credit + LiteLLM budget) on this Mac.
# - Asks for LITELLM_BASE_URL / LITELLM_API_KEY if missing from ~/.config/litellm/env.
# - Builds AIMenuBar.app, registers it to launch at login, and starts it.
# Safe to re-run (e.g. after editing main.swift). Undo login launch with: ./login-item.sh off
# Env: LITELLM_ENV_FILE (optional, default ~/.config/litellm/env)

set -euo pipefail
cd "$(dirname "$0")"

APP="$(pwd)/AIMenuBar.app"
LABEL="com.local.aimenubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
ENV_FILE="${LITELLM_ENV_FILE:-$HOME/.config/litellm/env}"

# --- prerequisites ------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode command line tools first:  xcode-select --install" >&2
  exit 1
fi
if [ ! -f "$APP/Contents/Info.plist" ]; then
  echo "Missing $APP/Contents/Info.plist (copy the whole ai-menu-bar folder)." >&2
  exit 1
fi

# --- LiteLLM credentials (private file, chmod 600) ----------------------------
LITELLM_BASE_URL=""; LITELLM_API_KEY=""
[ -r "$ENV_FILE" ] && . "$ENV_FILE"
base_url="$LITELLM_BASE_URL"; api_key="$LITELLM_API_KEY"

if [ -z "$base_url" ] || [ -z "$api_key" ]; then
  echo "LiteLLM credentials not found in $ENV_FILE"
  while [ -z "$base_url" ]; do read -r -p "LITELLM_BASE_URL (e.g. https://litellm.example.com): " base_url; done
  while [ -z "$api_key" ]; do read -r -s -p "LITELLM_API_KEY (input hidden): " api_key; echo; done

  mkdir -p "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  # Keep any other lines, replace these two.
  others=$(grep -vE '^(export )?LITELLM_(BASE_URL|API_KEY)=' "$ENV_FILE" || true)
  {
    [ -n "$others" ] && printf '%s\n' "$others"
    printf "export LITELLM_BASE_URL='%s'\n" "$base_url"
    printf "export LITELLM_API_KEY='%s'\n" "$api_key"
  } > "$ENV_FILE"
  echo "Saved to $ENV_FILE"
else
  echo "LiteLLM credentials: found in $ENV_FILE"
fi

# --- Claude Code login (only checked; the app reads it from the Keychain) -----
if /usr/bin/security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  echo "Claude Code login: found in Keychain"
else
  echo "Claude Code login: not found. Log in to Claude Code, or the CC part will show '—'."
fi

# --- build --------------------------------------------------------------------
./build.sh

# --- launch at login + start now ----------------------------------------------
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

# Quit a running copy so the freshly built binary is the one that starts.
pkill -x AIMenuBar 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed. The menu bar item is running and will launch at login."
