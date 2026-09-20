#!/bin/zsh
set -euo pipefail

# MacDevBridge.app runs this file once when the app launches. Keep machine-runtime
# startup here so services inherit the app's macOS privacy grants without hardcoding
# individual services in Swift.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PM2_HOME="${PM2_HOME:-$HOME/.pm2}"

PM2_BIN="${PM2_BIN:-$(command -v pm2 2>/dev/null || true)}"
if [[ -z "$PM2_BIN" ]]; then
  print -r -- "runtime-start: pm2 not found; nothing to start"
  exit 0
fi

# A pm2 CLI normally connects to an already-running daemon. That would preserve
# the old daemon's launch ancestry instead of making MacDevBridge the execution
# root. Save the current process set, stop that daemon, then resurrect it from this
# script so the new daemon is a descendant of MacDevBridge.app.
PM2_PID_FILE="$PM2_HOME/pm2.pid"
if [[ -f "$PM2_PID_FILE" ]]; then
  PM2_PID="$(<"$PM2_PID_FILE")"
  if [[ "$PM2_PID" == <-> ]] && kill -0 "$PM2_PID" 2>/dev/null; then
    "$PM2_BIN" save --force
    "$PM2_BIN" kill
  fi
fi

if [[ -f "$PM2_HOME/dump.pm2" ]]; then
  "$PM2_BIN" resurrect
  print -r -- "runtime-start: pm2 resurrected from $PM2_HOME/dump.pm2"
else
  print -r -- "runtime-start: no $PM2_HOME/dump.pm2; nothing to resurrect"
fi
