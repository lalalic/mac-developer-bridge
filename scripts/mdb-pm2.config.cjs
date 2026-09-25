const path = require('path');

const packageDir = process.env.MAC_DEV_BRIDGE_PACKAGE_DIR || path.resolve(__dirname, '..');
const logDir = process.env.MAC_DEV_BRIDGE_LOG_DIR || path.join(process.env.HOME || '.', 'Library/Logs/MacDeveloperBridge');
const port = process.env.MAC_DEV_BRIDGE_HTTP_PORT || '8765';
const cloudflared = process.env.MAC_DEV_BRIDGE_CLOUDFLARED_BIN || 'cloudflared';
const node = process.env.MAC_DEV_BRIDGE_NODE_BIN || process.execPath;
const tunnelName = process.env.MAC_DEV_BRIDGE_TUNNEL_NAME || '';
const origin = `http://127.0.0.1:${port}`;
const tunnelArgs = tunnelName
  ? ['tunnel', '--no-autoupdate', 'run', '--url', origin, tunnelName]
  : ['tunnel', '--url', origin, '--no-autoupdate'];

const inherited = { ...process.env };
delete inherited.MAC_DEV_BRIDGE_FULL_ACCESS_ACK;

module.exports = {
  apps: [
    {
      name: 'mac-dev-bridge-tunnel',
      script: cloudflared,
      interpreter: 'none',
      args: tunnelArgs,
      cwd: packageDir,
      autorestart: true,
      out_file: path.join(logDir, 'tunnel.stdout.log'),
      error_file: path.join(logDir, 'tunnel.stderr.log'),
      merge_logs: true,
      env: inherited,
    },
    {
      name: 'mac-dev-bridge-http',
      script: path.join(packageDir, 'mcp-http.mjs'),
      interpreter: node,
      cwd: packageDir,
      autorestart: true,
      out_file: path.join(logDir, 'http.stdout.log'),
      error_file: path.join(logDir, 'http.stderr.log'),
      merge_logs: true,
      env: inherited,
    },
  ],
};
