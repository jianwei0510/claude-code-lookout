#!/bin/bash
# Lookout installer: builds the app from source and installs it for the current user.
#
#   ./install.sh
#
# Building locally (instead of downloading a binary) means macOS never quarantines it,
# so there is no "unidentified developer" warning and nothing to notarize.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$HOME/Library/Application Support/Lookout"
DEST="$ROOT/app"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "Lookout is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "Lookout needs macOS 13 or later (this Mac runs $(sw_vers -productVersion))."
xcrun --find swiftc >/dev/null 2>&1 || fail "The Swift compiler is missing. Install Apple's Command Line Tools with:
    xcode-select --install
then run ./install.sh again."

# The pid of a running Lookout, from its lock file — only if that pid really is Lookout.
running_pid() {
  local pid
  pid=$(cat "$ROOT/instance.lock" 2>/dev/null || true)
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [ "$(basename "$(ps -p "$pid" -o comm= 2>/dev/null || true)")" = "lookout" ] || return 1
  echo "$pid"
}

say "Building Lookout (about 30 seconds)…"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -swift-version 5 -parse-as-library \
  app/Lookout.swift app/MonoSharpTokens.swift app/Logo.swift \
  -o "$BUILD/lookout"
[ -s "$BUILD/lookout" ] || fail "The build produced no program."

was_running=""
if pid=$(running_pid); then
  say "Stopping the running Lookout so the new version can take its place…"
  was_running=1
  kill "$pid"
  for _ in $(seq 1 20); do running_pid >/dev/null || break; sleep 0.2; done
fi

say "Installing to $DEST"
mkdir -p "$DEST/sounds"
cp "$BUILD/lookout" "$DEST/lookout.new"
mv -f "$DEST/lookout.new" "$DEST/lookout"
cp app/sounds/*.wav "$DEST/sounds/"

# Prove the install, rather than assume it: the program runs and both sounds are there.
[ -x "$DEST/lookout" ] || fail "$DEST/lookout is not executable."
sounds=$(find "$DEST/sounds" -name '*.wav' | wc -l | tr -d ' ')
[ "$sounds" -eq 2 ] || fail "Expected 2 sound files in $DEST/sounds, found $sounds."
say "Installed: the program and $sounds of 2 sounds."

if [ -n "$was_running" ]; then
  nohup "$DEST/lookout" >/dev/null 2>&1 &
  say "Restarted Lookout."
fi

cat <<'EOF'

Lookout is installed. One more step — add the switch to Claude.
Run these two commands in Terminal:

    claude plugin marketplace add jianwei0510/claude-code-lookout
    claude plugin install lookout@claude-code-lookout

Then open a new chat in Claude. Above the chat box you'll see
"○ Lookout 關著 [打開]" — press it, or type /lookout.
EOF
