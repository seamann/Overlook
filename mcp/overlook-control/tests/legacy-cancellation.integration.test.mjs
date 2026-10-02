import assert from "node:assert/strict";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { fakeControl, reply, settledWithin } from "./fake-control.mjs";

const headless = { ok: true, mode: "codexHeadless", local_input_capture_allowed: false };
const legacyTools = [
  { name: "overlook_send_text", arguments: { text: "synthetic" }, command: "text" },
  { name: "overlook_click", arguments: { x: 2, y: 3, screenWidth: 10, screenHeight: 10 }, command: "click" },
  { name: "overlook_shortcut", arguments: { keys: ["ControlLeft", "KeyA"] }, command: "shortcut" },
];

for (const tool of legacyTools) {
  for (const stage of ["status", "mutation"]) {
    test(`${tool.name}: SDK stop during ${stage} closes TCP and never dispatches a later input`, { timeout: 5000 }, async (t) => {
      let sawPending;
      const pendingReceived = new Promise((resolve) => { sawPending = resolve; });
      let sawClose;
      const connectionClosed = new Promise((resolve) => { sawClose = resolve; });
      const fixture = await fakeControl(t, (request, socket) => {
        if (request.command === "status" && stage === "mutation") return reply(socket, headless);
        socket.once("close", sawClose);
        sawPending();
        if (request.command === "status") {
          const delayedReply = setTimeout(() => reply(socket, headless), 100);
          t.after(() => clearTimeout(delayedReply));
        }
      });
      const client = new Client({ name: "legacy-cancel-test", version: "1" });
      const transport = new StdioClientTransport({ command: process.execPath, args: [path.resolve("tests/stdio-fixture.mjs"), fixture.tokenPath, String(fixture.port)], stderr: "pipe" });
      t.after(() => client.close());
      await client.connect(transport);
      const abort = new AbortController();
      const pending = client.callTool({ name: tool.name, arguments: tool.arguments }, { signal: abort.signal });
      const rejected = assert.rejects(pending);
      await pendingReceived;
      abort.abort();
      await rejected;
      if (stage === "status") await delay(200);
      assert.deepEqual(fixture.requests.map((request) => request.command), stage === "status" ? ["status"] : ["status", tool.command]);
      assert.equal((await settledWithin(connectionClosed, 200)).unsettled, undefined, "SDK cancellation must close the pending control socket before its request deadline");
    });
  }
}
