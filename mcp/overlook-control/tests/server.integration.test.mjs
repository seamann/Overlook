import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";

import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

test("serves the bounded Overlook tool surface over stdio", async (t) => {
  const client = new Client({ name: "overlook-mcp-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [path.resolve("dist/index.js")],
    stderr: "pipe",
  });
  t.after(async () => client.close());
  await client.connect(transport);

  const listed = await client.listTools();
  assert.deepEqual(
    listed.tools.map((tool) => tool.name).sort(),
    [
      "overlook_act",
      "overlook_action_status",
      "overlook_cancel",
      "overlook_click",
      "overlook_latest_crash",
      "overlook_observe",
      "overlook_send_text",
      "overlook_shortcut",
      "overlook_status",
    ],
  );

  const clickTool = listed.tools.find((tool) => tool.name === "overlook_click");
  assert.deepEqual(
    Object.keys(clickTool.inputSchema.properties).sort(),
    ["screenHeight", "screenWidth", "x", "y"],
  );
  assert.equal(clickTool.inputSchema.properties.x.minimum, 0);
  assert.equal(clickTool.inputSchema.properties.y.minimum, 0);

  // Discovery only: diagnostics against real user data are not a test fixture.
});
