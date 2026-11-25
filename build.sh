#!/usr/bin/env bash
# Build the AI usage menu bar app into a proper .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="$(pwd)/AIMenuBar.app"
BIN="$APP/Contents/MacOS/AIMenuBar"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile the status item (info.plist already in place).
swiftc -o "$BIN" main.swift -framework AppKit

# Ad-hoc codesign so macOS treats it as a real app (needed to show menu bar UI reliably).
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Launch it with: sh '$(pwd)/run.sh'"