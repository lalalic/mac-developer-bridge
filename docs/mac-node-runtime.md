# Mac Node Runtime Contract

## Goal

All Mac execution nodes expose the same user-space runtime contract while allowing different lifecycle adapters.

## Canonical layout

- `~/.local/share/neo-node/`
  - `bootstrap-mac-node.sh` — lifecycle-neutral runtime entrypoint
  - `mac-node-server.py` — loopback-only MCP server
  - `logs/` — runtime logs
  - `run/` — ephemeral pid/state files
- `~/.config/neo-node/node.env` — per-node non-secret configuration
- `~/.config/neo-node/id_ed25519` — node tunnel credential
- `~/.local/bin/neo-node` — stable CLI entrypoint

## Lifecycle modes

### session

For managed/corporate machines. No LaunchAgent is installed or required.

- no system-level persistence
- no administrator privileges
- no writes to /Library
- MCP listens only on 127.0.0.1
- the reverse SSH tunnel is the only remote exposure
- runtime can be started/stopped entirely from the user account
- a legacy host launcher may invoke `neo-node run`, but contains no runtime logic

### persistent

For user-owned always-on machines.

- same server, configuration, CLI and tunnel contract
- may use a per-user LaunchAgent as a lifecycle adapter
- LaunchD is not part of the core runtime contract

## Configuration

Required:
- `NODE_NAME`
- `HUB_SSH_TARGET`
- `HUB_MCP_PORT`

Optional:
- `NODE_MODE=session|persistent` (default: session)
- `LOCAL_MCP_PORT` (default: 8789)
- `NODE_ROOT` (default: ~/.local/share/neo-node)
- `PYTHON_BIN`
- `SSH_BIN`

## CLI contract

```
neo-node install
neo-node run
neo-node start
neo-node stop
neo-node restart
neo-node status
neo-node doctor
neo-node uninstall-persistence
```

`install` is mode-aware: session mode installs no persistence; persistent mode may install the per-user LaunchAgent.

## Compatibility

Old launchers such as `~/.local/share/learn/experience.mjs` may remain temporarily, but must only delegate to the canonical `neo-node` runtime and must not contain separate lifecycle/configuration logic.
