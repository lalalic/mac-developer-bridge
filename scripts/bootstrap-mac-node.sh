#!/bin/zsh
set -euo pipefail

CONFIG_FILE="${NEO_NODE_CONFIG:-$HOME/.config/neo-node/node.env}"
[[ -f "$CONFIG_FILE" ]] || { print -u2 -- "missing config: $CONFIG_FILE"; exit 64; }
set -a
source "$CONFIG_FILE"
set +a

: "${NODE_NAME:?NODE_NAME is required}"
: "${HUB_SSH_TARGET:?HUB_SSH_TARGET is required}"
: "${HUB_MCP_PORT:?HUB_MCP_PORT is required}"

NODE_MODE="${NODE_MODE:-session}"
LOCAL_MCP_PORT="${LOCAL_MCP_PORT:-8789}"
NODE_ROOT="${NODE_ROOT:-$HOME/.local/share/neo-node}"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
SSH_BIN="${SSH_BIN:-/usr/bin/ssh}"
SERVER="$NODE_ROOT/mac-node-server.py"
LOG_DIR="$NODE_ROOT/logs"
PID_DIR="$NODE_ROOT/run"
KEY_FILE="$HOME/.config/neo-node/id_ed25519"
LAUNCH_LABEL="com.neo.mac-node.$NODE_NAME"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
CLI_PATH="$HOME/.local/bin/neo-node"

case "$NODE_MODE" in
  session|persistent) ;;
  *) print -u2 -- "invalid NODE_MODE=$NODE_MODE (expected session|persistent)"; exit 64 ;;
esac

mkdir -p "$LOG_DIR" "$PID_DIR"

install_cli() {
  mkdir -p "$HOME/.local/bin"
  cat > "$CLI_PATH" <<EOF
#!/bin/zsh
exec /bin/zsh "$NODE_ROOT/bootstrap-mac-node.sh" "\$@"
EOF
  chmod 755 "$CLI_PATH"
}

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
    -i "$KEY_FILE" \
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
    -i "$KEY_FILE" \
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
  [[ "$NODE_MODE" == "persistent" ]] || {
    print -- "NODE_MODE=$NODE_MODE: LaunchD installation skipped"
    return 0
  }
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LAUNCH_LABEL</string>
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
  launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
  launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
  if ! launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PLIST" 2>/dev/null; then
    launchctl load -w "$LAUNCH_PLIST"
  fi
}

uninstall_persistence() {
  launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
  launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
  rm -f "$LAUNCH_PLIST"
}

status() {
  print -- "node: $NODE_NAME"
  print -- "mode: $NODE_MODE"
  print -- "root: $NODE_ROOT"
  if curl -fsS "http://127.0.0.1:$LOCAL_MCP_PORT/healthz" 2>/dev/null; then :; else print -- "health: unavailable"; fi
  print -- "server pid: $(cat "$PID_DIR/server.pid" 2>/dev/null || print missing)"
  print -- "tunnel pid: $(cat "$PID_DIR/tunnel.pid" 2>/dev/null || print missing)"
  if [[ -f "$LAUNCH_PLIST" ]]; then
    print -- "launchd plist: present"
  else
    print -- "launchd plist: absent"
  fi
}

doctor() {
  local failed=0
  print -- "neo-node doctor"
  print -- "node=$NODE_NAME mode=$NODE_MODE"

  for f in "$CONFIG_FILE" "$SERVER" "$KEY_FILE"; do
    if [[ -e "$f" ]]; then print -- "ok file $f"; else print -- "missing $f"; failed=1; fi
  done
  for b in "$PYTHON_BIN" "$SSH_BIN" /usr/bin/curl; do
    if [[ -x "$b" ]]; then print -- "ok executable $b"; else print -- "missing executable $b"; failed=1; fi
  done

  if [[ "$NODE_MODE" == "session" && -f "$LAUNCH_PLIST" ]]; then
    print -- "warning: session node has legacy LaunchD plist: $LAUNCH_PLIST"
  fi

  if curl -fsS "http://127.0.0.1:$LOCAL_MCP_PORT/healthz" >/dev/null 2>&1; then
    print -- "ok local MCP health"
  else
    print -- "info local MCP is not currently reachable"
  fi
  return "$failed"
}

case "${1:-status}" in
  install)
    install_cli
    install_launchd
    ;;
  run) run_foreground ;;
  start)
    start_server
    sleep 0.5
    curl -fsS "http://127.0.0.1:$LOCAL_MCP_PORT/healthz" >/dev/null
    start_tunnel
    ;;
  stop) stop_all ;;
  restart) stop_all; sleep 0.5; start_server; sleep 0.5; start_tunnel ;;
  status) status ;;
  doctor) doctor ;;
  uninstall-persistence) uninstall_persistence ;;
  *) print -u2 -- "usage: neo-node [install|run|start|stop|restart|status|doctor|uninstall-persistence]"; exit 64 ;;
esac
