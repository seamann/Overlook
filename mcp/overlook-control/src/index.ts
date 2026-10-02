import { serveStdio } from "@modelcontextprotocol/server/stdio";

import { buildServer, sanitizeToolError } from "./server.js";

serveStdio(() => buildServer(), {
  onerror: (error) => console.error(`Overlook MCP: ${sanitizeToolError(error)}`),
});
