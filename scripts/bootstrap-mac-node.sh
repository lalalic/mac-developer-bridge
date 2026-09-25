#!/bin/zsh
set -euo pipefail

# Generic Neo Mac node bootstrap.
#
# Important naming rule:
#   A federation provider key identifies ONE specific physical/logical node.
#   If NODE_NAME=home98, its tools appear as home98__shell_exec,
#   home98__fs_read, etc. In documentation, "xxxnode_*" means tools that are
#   specific to that one node; it does NOT mean a shared/global Mac tool.
#
# Required per-node config:
#   NODE_NAME=home98
#   HUB_SSH_TARGET=chengli@10.0.0.111
#   HUB_MCP_PORT=28798
#
# Optional:
#   LOCAL_MCP_PORT=8789
#   NODE_ROOT=~/.local/share/neo-node

CONFIG_FILE="${NEO_NODE_CONFIG:-$HOME/.config/neo-node/node.env}"
[[ -f "$CONFIG_FILE" ]] || { print -u2 -- "missing config: $CONFIG_FILE"; exit 64; }
set -a
source "$CONFIG_FILE"
set +a

: "${NODE_NAME:?NODE_NAME is required}"
: "${HUB_SSH_TARGET:?HUB_SSH_TARGET is required}"
: "${HUB_MCP_PORT:?HUB_MCP_PORT is required}"

LOCAL_MCP_PORT="${LOCAL_MCP_PORT:-8789}"
NODE_ROOT="${NODE_ROOT:-$HOME/.local/share/neo-node}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
SSH_BIN="${SSH_BIN:-/usr/bin/ssh}"
SERVER="$NODE_ROOT/mac-node-server.py"
LOG_DIR="$NODE_ROOT/logs"
PID_DIR="$NODE_ROOT/run"
mkdir -p "$LOG_DIR" "$PID_DIR"

start_server() {
  if [[ -f "$PID_DIR/server.pid" ]] && kill -0 "$(cat "$PID_DIR/server.pid")" 2>/dev/null; then
    return 0
  fi
  MAC_NODE_NAME="$NODE_NAME" MAC_NODE_PORT="$LOCAL_MCP_PORT" MAC_NODE_HOST=127.0.0.1 \
    nohup "$PYTHON_BIN" "$SERVER" >>"$LOG_DIR/server.log" 2>&1 &
  echo $! > "$PID_DIR/server.pid"
}

start_tunnel() {
  if [[ -f "$PID_DIR/tunnel.pid" ]] && kill -0 "$(cat "$PID_DIR/tunnel.pid")" 2>/dev/null; then
    return 0
  fi
  nohup "$SSH_BIN" \
    -N \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=accept-new \
    -i "$HOME/.config/neo-node/id_ed25519" \
    -R "127.0.0.1:$HUB_MCP_PORT:127.0.0.1:$LOCAL_MCP_PORT" \
    "$HUB_SSH_TARGET" >>"$LOG_DIR/tunnel.log" 2>&1 &
  echo $! > "$PID_DIR/tunnel.pid"
}

stop_all() {
  for f in "$PID_DIR/tunnel.pid" "$PID_DIR/server.pid"; do
    if [[ -f "$f" ]]; then
      kill "$(cat "$f")" 2>/dev/null || true
      rm -f "$f"
    fi
  done
}

run_foreground() {
  local server_pid tunnel_pid
  trap 'kill "$server_pid" "$tunnel_pid" 2>/dev/null || true' EXIT INT TERM

  MAC_NODE_NAME="$NODE_NAME" MAC_NODE_PORT="$LOCAL_MCP_PORT" MAC_NODE_HOST=127.0.0.1 \
    "$PYTHON_BIN" "$SERVER" >>"$LOG_DIR/server.log" 2>&1 &
  server_pid=$!
  echo "$server_pid" > "$PID_DIR/server.pid"

  for _ in {1..20}; do
    curl -fsS "http://127.0.0.1:$LOCAL_MCP_PORT/healthz" >/dev/null 2>&1 && break
    sleep 0.25
  done
  curl -fsS "http://127.0.0.1:$LOCAL_MCP_PORT/healthz" >/dev/null

  "$SSH_BIN" \
    -N \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=accept-new \
    -i "$HOME/.config/neo-node/id_ed25519" \
    -R "127.0.0.1:$HUB_MCP_PORT:127.0.0.1:$LOCAL_MCP_PORT" \
    "$HUB_SSH_TARGET" >>"$LOG_DIR/tunnel.log" 2>&1 &
  tunnel_pid=$!
  echo "$tunnel_pid" > "$PID_DIR/tunnel.pid"

  while kill -0 "$server_pid" 2>/dev/null && kill -0 "$tunnel_pid" 2>/dev/null; do
    sleep 5
  done
  return 1
}

install_launchd() {
  local label="com.neo.mac-node.$NODE_NAME"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/zsh</string>
    <string>$NODE_ROOT/bootstrap-mac-node.sh</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/launchd.err.log</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

case "${1:-start}" in
  install) install_launchd ;;
  run) run_foreground ;;
  start)
    start_server
    sleep 0.5
    curl -fsS "http://127.0.0.1:$LOCAL_MCP_PORT/healthz" >/dev/null
    start_tunnel
    ;;
  stop) stop_all ;;
  restart) stop_all; sleep 0.5; start_server; sleep 0.5; start_tunnel ;;
  status)
    curl -fsS "http://127.0.0.1:$LOCAL_MCP_PORT/healthz" || true
    print -- "server pid: $(cat "$PID_DIR/server.pid" 2>/dev/null || print missing)"
    print -- "tunnel pid: $(cat "$PID_DIR/tunnel.pid" 2>/dev/null || print missing)"
    ;;
  *) print -u2 -- "usage: $0 [install|run|start|stop|restart|status]"; exit 64 ;;
esac
