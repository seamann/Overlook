import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { fakeControl, reply, settledWithin } from "./fake-control.mjs";

async function legacyStdio(t, fixture) {
  const child = spawn(process.execPath, [path.resolve("tests/stdio-fixture.mjs"), fixture.tokenPath, String(fixture.port)], { stdio: ["pipe", "pipe", "pipe"] });
  const lines = createInterface({ input: child.stdout });
  const replies = new Map();
  const waiters = new Map();
  lines.on("line", (line) => {
    const message = JSON.parse(line);
    replies.set(message.id, message);
    waiters.get(message.id)?.(message);
  });
  child.stderr.resume();
  const exited = once(child, "exit");
  t.after(async () => {
    lines.close();
    if (child.exitCode === null && child.signalCode === null) child.kill();
    await exited;
  });
  const send = (message) => child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  const response = (id) => replies.has(id) ? Promise.resolve(replies.get(id)) : new Promise((resolve) => waiters.set(id, resolve));
  send({ id: "initialize", method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "stdio-lifecycle-test", version: "1" } } });
  assert.equal((await response("initialize")).error, undefined);
  send({ method: "notifications/initialized" });
  return { child, exited, send, response };
}

test("stdio cancellation of request id zero stops a pending preflight before input dispatch", { timeout: 5000 }, async (t) => {
  let sawPreflight;
  const preflight = new Promise((resolve) => { sawPreflight = resolve; });
  let sawClose;
  const closed = new Promise((resolve) => { sawClose = resolve; });
  const fixture = await fakeControl(t, (request, socket) => {
    socket.once("close", sawClose);
    sawPreflight();
    assert.equal(request.command, "status");
  });
  const wire = await legacyStdio(t, fixture);
  wire.send({ id: 0, method: "tools/call", params: { name: "overlook_send_text", arguments: { text: "synthetic" } } });
  await preflight;
  wire.send({ method: "notifications/cancelled", params: { requestId: 0, reason: "test stop" } });
  assert.equal((await settledWithin(closed, 250)).unsettled, undefined, "request id zero must abort before the 500 ms TCP deadline");
  assert.deepEqual(fixture.requests.map((request) => request.command), ["status"]);
});

test("stdio EOF cancels an in-flight action once and exits without replaying input", { timeout: 5000 }, async (t) => {
  let sawAct;
  const acted = new Promise((resolve) => { sawAct = resolve; });
  let sawCancel;
  const cancelled = new Promise((resolve) => { sawCancel = resolve; });
  const fixture = await fakeControl(t, (request, socket) => {
    if (request.command === "act") { sawAct(); return; }
    assert.equal(request.command, "cancel");
    reply(socket, { ok: true, protocol_version: 2, session_id: request.session_id, action_seq: request.action_seq, state: "not_started", error_code: "cancelled" });
    sawCancel();
  });
  const wire = await legacyStdio(t, fixture);
  wire.send({ id: 1, method: "tools/call", params: { name: "overlook_act", arguments: { session_id: "session-1", action_seq: 1, frame_id: "frame-1", action: { type: "text", value: "synthetic" } } } });
  await acted;
  wire.child.stdin.end();
  assert.equal((await settledWithin(cancelled, 250)).unsettled, undefined, "stdin EOF must abort the action before its TCP deadline");
  assert.deepEqual(fixture.requests.map((request) => request.command), ["act", "cancel"]);
  const exit = await settledWithin(wire.exited, 500);
  assert.deepEqual(exit.value, [0, null], "EOF cleanup must exit cleanly after the cancellation receipt");
});

test("a tool request after SDK connection close rejects promptly without TCP dispatch", { timeout: 5000 }, async (t) => {
  const fixture = await fakeControl(t, () => assert.fail("closed MCP client must not dispatch TCP"));
  const client = new Client({ name: "closed-connection-test", version: "1" });
  const transport = new StdioClientTransport({ command: process.execPath, args: [path.resolve("tests/stdio-fixture.mjs"), fixture.tokenPath, String(fixture.port)], stderr: "pipe" });
  t.after(() => client.close());
  await client.connect(transport);
  await client.close();
  const result = await settledWithin(client.callTool({ name: "overlook_status", arguments: {} }), 250);
  assert.ok(result.error instanceof Error, "closed connection must reject instead of hanging");
  assert.deepEqual(fixture.requests, []);
});
