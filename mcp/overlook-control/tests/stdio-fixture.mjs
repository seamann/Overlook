import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { buildServer } from "../dist/server.js";
import { OverlookClient } from "../dist/overlook-client.js";

// Test-only injection. Production index.js accepts neither token paths nor hosts.
serveStdio(() => buildServer({ client: new OverlookClient({ tokenPath: process.argv[2], port: Number(process.argv[3]), timeoutMs: 500 }) }));
