#!/usr/bin/env bash
# Launch the AI usage menu bar app (detached, no terminal needed after).
set -euo pipefail
cd "$(dirname "$0")"
APP="$(pwd)/AIMenuBar.app"
open "$APP"
echo "AIMenuBar.app opened."