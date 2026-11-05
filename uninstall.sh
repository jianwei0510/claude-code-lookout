#!/bin/bash
# Removes Lookout: stops it, deletes the app, its settings and what it remembered.
#
#   ./uninstall.sh
set -euo pipefail

ROOT="$HOME/Library/Application Support/Lookout"

pid=$(cat "$ROOT/instance.lock" 2>/dev/null || true)
if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$(basename "$(ps -p "$pid" -o comm= 2>/dev/null || true)")" = "lookout" ]; then
  kill "$pid"
  echo "Stopped Lookout."
fi

if [ -d "$ROOT" ]; then
  rm -rf "$ROOT"
  echo "Removed $ROOT"
else
  echo "Nothing installed at $ROOT (skipped)."
fi

if defaults read lookout >/dev/null 2>&1; then
  defaults delete lookout
  echo "Removed Lookout's preferences (font size, sound, window position)."
else
  echo "No saved preferences (skipped)."
fi

cat <<'EOF'

To remove the switch from Claude as well:

    claude plugin uninstall lookout@claude-code-lookout
    claude plugin marketplace remove claude-code-lookout
EOF
