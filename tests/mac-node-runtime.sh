#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
NODE_ROOT="$HOME/.local/share/neo-node"
mkdir -p "$HOME/.config/neo-node" "$NODE_ROOT/logs" "$NODE_ROOT/run"
cp "$ROOT/scripts/bootstrap-mac-node.sh" "$NODE_ROOT/bootstrap-mac-node.sh"
cp "$ROOT/scripts/mac-node-server.py" "$NODE_ROOT/mac-node-server.py"
touch "$HOME/.config/neo-node/id_ed25519"
port="$(( 20000 + ($$ % 20000) ))"
cat > "$HOME/.config/neo-node/node.env" <<CFG
NODE_NAME=test_node
NODE_MODE=session
HUB_SSH_TARGET=test@example.invalid
HUB_MCP_PORT=29999
LOCAL_MCP_PORT=$port
NODE_ROOT=$NODE_ROOT
PYTHON_BIN=/usr/bin/python3
SSH_BIN=$TMP/fake-ssh
CFG
cat > "$TMP/fake-ssh" <<'SH'
#!/bin/zsh
f="$HOME/.local/share/neo-node/ssh-count"
n="$(cat "$f" 2>/dev/null || print 0)"
(( n += 1 ))
print -- "$n" > "$f"
(( n == 1 )) && exit 1
while true; do sleep 1; done
SH
chmod +x "$TMP/fake-ssh"
print -- 999999 > "$NODE_ROOT/run/server.pid"
print -- 999998 > "$NODE_ROOT/run/tunnel.pid"
out="$(/bin/zsh "$NODE_ROOT/bootstrap-mac-node.sh" status)"
print -- "$out" | grep -q 'local MCP: unavailable'
print -- "$out" | grep -q 'server pid: 999999 (stale)'
print -- "$out" | grep -q 'tunnel pid: 999998 (stale)'
/bin/zsh "$NODE_ROOT/bootstrap-mac-node.sh" start
for _ in {1..120}; do
  n="$(cat "$NODE_ROOT/ssh-count" 2>/dev/null || print 0)"
  (( n >= 2 )) && break
  sleep 0.1
done
(( $(cat "$NODE_ROOT/ssh-count") >= 2 ))
curl -fsS "http://127.0.0.1:$port/healthz" | grep -q 'ok test_node'
out="$(/bin/zsh "$NODE_ROOT/bootstrap-mac-node.sh" status)"
print -- "$out" | grep -q 'local MCP: healthy'
print -- "$out" | grep -Eq 'supervisor pid: [0-9]+ \(alive\)'
print -- "$out" | grep -Eq 'server pid: [0-9]+ \(alive\)'
print -- "$out" | grep -Eq 'tunnel pid: [0-9]+ \(alive\)'

supervisor_before="$(cat "$NODE_ROOT/run/supervisor.pid")"
server_before="$(cat "$NODE_ROOT/run/server.pid")"
tunnel_before="$(cat "$NODE_ROOT/run/tunnel.pid")"
kill "$tunnel_before"
for _ in {1..120}; do
  n="$(cat "$NODE_ROOT/ssh-count" 2>/dev/null || print 0)"
  if (( n >= 3 )) && [[ -f "$NODE_ROOT/run/tunnel.pid" ]]; then
    tunnel_after="$(cat "$NODE_ROOT/run/tunnel.pid")"
    if [[ "$tunnel_after" != "$tunnel_before" ]] && kill -0 "$tunnel_after" 2>/dev/null; then
      break
    fi
  fi
  sleep 0.1
done
[[ "$(cat "$NODE_ROOT/run/supervisor.pid")" == "$supervisor_before" ]]
[[ "$(cat "$NODE_ROOT/run/server.pid")" == "$server_before" ]]
[[ "$(cat "$NODE_ROOT/run/tunnel.pid")" != "$tunnel_before" ]]
kill -0 "$(cat "$NODE_ROOT/run/tunnel.pid")" 2>/dev/null

/bin/zsh "$NODE_ROOT/bootstrap-mac-node.sh" stop
print -- "mac-node runtime tests passed"
