import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { fakeControl, reply } from "./fake-control.mjs";
import { png, snapshot } from "./png-fixture.mjs";

test("stdio MCP completes image/act/status/cancel over fake TCP without live input", { timeout: 5000 }, async (t) => {
  const image = png(512, 512, true).toString("base64");
  const payload = snapshot({ width: 512, height: 512, region: { x: 0, y: 0, width: 512, height: 512 }, image_base64: image });
  const fixture = await fakeControl(t, (request, socket) => {
    if (request.command === "observe") return reply(socket, payload);
    if (request.command === "status") return reply(socket, { ok: true, protocol_version: 2, build_id: "test-build", session_id: "session-1", next_action_seq: 1, capabilities: ["observe", "act"], readiness: { video: true, text: true, mouse: false }, input_blocked: false, password: "PRIVATE_SENTINEL" });
    return reply(socket, { ok: true, protocol_version: 2, session_id: request.session_id, action_seq: request.action_seq, state: "not_started", error_code: "cancelled" });
  });
  const client = new Client({ name: "stdio-fake-review", version: "1" });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.resolve("tests/stdio-fixture.mjs"), fixture.tokenPath, String(fixture.port)], stderr: "pipe" });
  t.after(() => client.close());
  await client.connect(transport);
  const tools = (await client.listTools()).tools;
  assert.equal(tools.length, 9);
  const observed = await client.callTool({ name: "overlook_observe", arguments: {} });
  assert.equal(observed.content[0].type, "image");
  assert.equal(observed.content[0].data, image);
  assert.equal(observed.structuredContent.image_base64, undefined);
  const status = await client.callTool({ name: "overlook_status", arguments: {} });
  assert.equal(status.structuredContent.build_id, "test-build");
  assert.deepEqual(status.structuredContent.readiness, { video: true, text: true, mouse: false });
  assert.doesNotMatch(JSON.stringify(status), /PRIVATE_SENTINEL/);
  const reference = { session_id: "session-1", action_seq: 1 };
  for (const name of ["overlook_act", "overlook_action_status", "overlook_cancel"]) {
    const args = name === "overlook_act" ? { ...reference, frame_id: "frame-1", action: { type: "click", x: 1, y: 1 } } : reference;
    const result = await client.callTool({ name, arguments: args });
    assert.equal(result.structuredContent.state, "not_started");
  }
  assert.deepEqual(fixture.requests.map((r) => r.command), ["observe", "status", "act", "action_status", "cancel"]);
});

test("SDK cancellation signal issues one distinct cancel, then status remains readable", { timeout: 5000 }, async (t) => {
  let sawAct;
  const actReceived = new Promise((resolve) => { sawAct = resolve; });
  let sawCancel;
  const cancelReceived = new Promise((resolve) => { sawCancel = resolve; });
  const fixture = await fakeControl(t, (request, socket) => {
    if (request.command === "act") { sawAct(); return; }
    if (request.command === "cancel") sawCancel();
    reply(socket, { ok: true, protocol_version: 2, session_id: request.session_id, action_seq: request.action_seq, state: "outcome_unknown" });
  });
  const client = new Client({ name: "cancel-test", version: "1" });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.resolve("tests/stdio-fixture.mjs"), fixture.tokenPath, String(fixture.port)], stderr: "pipe" });
  t.after(() => client.close());
  await client.connect(transport);
  const abort = new AbortController();
  const reference = { session_id: "session-1", action_seq: 1 };
  const pending = client.callTool({ name: "overlook_act", arguments: { ...reference, frame_id: "frame-1", action: { type: "text", value: "synthetic" } } }, { signal: abort.signal });
  const rejected = assert.rejects(pending);
  await actReceived;
  abort.abort();
  await rejected;
  await cancelReceived;
  const status = await client.callTool({ name: "overlook_action_status", arguments: reference });
  assert.equal(status.structuredContent.state, "outcome_unknown");
  assert.deepEqual(fixture.requests.map((r) => r.command), ["act", "cancel", "action_status"]);
});
