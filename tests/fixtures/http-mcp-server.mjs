import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";

const PORT = Number(process.env.HTTP_MCP_PORT || 0);
const COLLIDE = process.env.HTTP_MCP_COLLIDE === "1";
const TOOLS = [
  { name: "media.search", description: "Find matching media.", inputSchema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } },
  { name: "media_search", description: "Ambiguous with the dotted name after aliasing.", inputSchema: { type: "object" } },
  { name: "plain", description: "Return a deterministic value.", inputSchema: { type: "object" } },
];
if (!COLLIDE) TOOLS.splice(1, 1);

let initialized = false;
let currentSession;

const server = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    if (currentSession) response.setHeader("Mcp-Session-Id", currentSession);
    if (request.method !== "POST") {
      response.writeHead(405).end();
      return;
    }
    let message;
    try {
      message = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      response.writeHead(400).end();
      return;
    }
    const reply = (result) => {
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
    };
    if (message.method === "initialize") {
      initialized = true;
      currentSession = `session-${Date.now()}-${Math.random().toString(16).slice(2)}`;
      reply({ protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "http-stub", version: "0.0.1" } });
      return;
    }
    if (message.method === "notifications/initialized") {
      response.writeHead(202).end();
      return;
    }
    if (!initialized) {
      response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({
        jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "not initialized" },
      }));
      return;
    }
    if (message.method === "tools/list") {
      reply({ tools: TOOLS });
      return;
    }
    if (message.method === "tools/call") {
      const name = message.params?.name;
      reply({
        content: [{ type: "text", text: name === "media.search" ? `search:${message.params.arguments?.query}` : `called:${name}` }],
      });
      return;
    }
    response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({
      jsonrpc: "2.0", id: message.id, error: { code: -32601, message: `Method not found: ${message.method}` },
    }));
  });
});

server.listen(PORT, "127.0.0.1", () => {
  const { address, port } = server.address();
  assert.equal(address, "127.0.0.1");
  if (process.env.HTTP_MCP_PORT_FILE) {
    fs.writeFileSync(process.env.HTTP_MCP_PORT_FILE, `${port}\n`, { mode: 0o600 });
  }
});

function stop() {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500).unref();
}
process.once("SIGTERM", stop);
process.once("SIGINT", stop);
