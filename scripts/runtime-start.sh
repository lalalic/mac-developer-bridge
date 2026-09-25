#!/bin/zsh
set -euo pipefail

# MacDevBridge.app owns this bootstrap. PM2 owns long-running runtime services.
# Keep service definitions here/config-driven so adding services never requires Swift changes.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PM2_HOME="${PM2_HOME:-$HOME/.pm2}"

PM2_BIN="${PM2_BIN:-$(command -v pm2 2>/dev/null || true)}"
if [[ -z "$PM2_BIN" ]]; then
  print -r -- "runtime-start: pm2 not found"
  exit 69
fi

ROOT="${MAC_DEV_BRIDGE_PACKAGE_DIR:-${0:A:h:h}}"
CONFIG="$ROOT/scripts/mdb-pm2.config.cjs"
DATA_DIR="${MAC_DEV_BRIDGE_DATA_DIR:-$HOME/Library/Application Support/MacDeveloperBridge}"
LOG_DIR="${MAC_DEV_BRIDGE_LOG_DIR:-$HOME/Library/Logs/MacDeveloperBridge}"
PUBLIC_URL_FILE="$DATA_DIR/public-url"
TUNNEL_LOG="$LOG_DIR/tunnel.stderr.log"
HTTP_NAME="mac-dev-bridge-http"
TUNNEL_NAME="mac-dev-bridge-tunnel"
ACTION="${1:-bootstrap}"

mkdir -p "$DATA_DIR" "$LOG_DIR"
chmod 700 "$DATA_DIR" "$LOG_DIR" 2>/dev/null || true

pm2_delete_bridge() {
  "$PM2_BIN" delete "$HTTP_NAME" "$TUNNEL_NAME" >/dev/null 2>&1 || true
}

bootstrap_pm2() {
  # Re-parent the PM2 daemon under MacDevBridge.app while preserving all unrelated
  # runtime services. The two bridge services are intentionally recreated below.
  local pid_file="$PM2_HOME/pm2.pid"
  if [[ -f "$pid_file" ]]; then
    local pid="$(<"$pid_file")"
    if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
      pm2_delete_bridge
      "$PM2_BIN" save --force >/dev/null
      "$PM2_BIN" kill >/dev/null
    fi
  fi
  if [[ -f "$PM2_HOME/dump.pm2" ]]; then
    "$PM2_BIN" resurrect >/dev/null
    print -r -- "runtime-start: pm2 resurrected from $PM2_HOME/dump.pm2"
  else
    # Any subsequent pm2 command will create the daemon as a descendant of this script/app.
    print -r -- "runtime-start: no $PM2_HOME/dump.pm2; starting fresh"
  fi
}

start_bridge() {
  [[ -f "$CONFIG" ]] || { print -u2 -- "runtime-start: missing $CONFIG"; return 66; }
  : > "$TUNNEL_LOG"
  rm -f "$PUBLIC_URL_FILE"
  pm2_delete_bridge

  "$PM2_BIN" start "$CONFIG" --only "$TUNNEL_NAME" --update-env >/dev/null

  local url="${MAC_DEV_BRIDGE_PUBLIC_URL:-}"
  if [[ -z "$url" ]]; then
    local i
    for i in {1..180}; do
      url="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | tail -1 || true)"
      [[ -n "$url" ]] && break
      sleep 0.25
    done
  fi
  if [[ -z "$url" ]]; then
    print -u2 -- "runtime-start: cloudflared produced no public URL"
    "$PM2_BIN" delete "$TUNNEL_NAME" >/dev/null 2>&1 || true
    return 70
  fi

  print -r -- "$url" > "$PUBLIC_URL_FILE"
  chmod 600 "$PUBLIC_URL_FILE" 2>/dev/null || true
  export MAC_DEV_BRIDGE_PUBLIC_URL="$url"
  "$PM2_BIN" start "$CONFIG" --only "$HTTP_NAME" --update-env >/dev/null
  print -r -- "runtime-start: bridge services started ($url)"
}

stop_bridge() {
  pm2_delete_bridge
  rm -f "$PUBLIC_URL_FILE"
  print -r -- "runtime-start: bridge services stopped"
}

case "$ACTION" in
  bootstrap) bootstrap_pm2 ;;
  bridge-start) start_bridge ;;
  bridge-stop) stop_bridge ;;
  *) print -u2 -- "usage: runtime-start.sh [bootstrap|bridge-start|bridge-stop]"; exit 64 ;;
esac
