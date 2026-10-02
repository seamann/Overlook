import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { Client } from "@modelcontextprotocol/client";
import { InMemoryTransport } from "@modelcontextprotocol/server";
import { OverlookClient } from "../dist/overlook-client.js";
import { buildServer } from "../dist/server.js";
import { fakeControl, reply, settledWithin } from "./fake-control.mjs";
import { png, snapshot, paddedPng } from "./png-fixture.mjs";

const reference = { session_id: "session-1", action_seq: 1 };
const action = { ...reference, frame_id: "frame-1", action: { type: "text", value: "Änderung" } };
const outcome = (state = "transmitted") => ({ ok: true, protocol_version: 2, ...reference, state });

test("native Swift SnapshotPNGEncoder fixture passes the MCP image contract", async (t) => {
  // Generated from six synthetic BGRA pixels by the production Swift encoder.
  const bytes = await readFile(new URL("./fixtures/native-snapshot-3x2.png", import.meta.url));
  const payload = snapshot({ width: 3, region: { x: 0, y: 0, width: 3, height: 2 }, rotation_degrees: 0, image_base64: bytes.toString("base64") });
  const fixture = await fakeControl(t, (_, socket) => reply(socket, payload));
  assert.equal((await new OverlookClient(fixture).observe({})).image_base64, payload.image_base64);
});

test("observe accepts the exact 4MiB PNG boundary without regex recursion", async (t) => {
  const image = paddedPng(4 * 1024 * 1024).toString("base64");
  const fixture = await fakeControl(t, (_, socket) => reply(socket, snapshot({ image_base64: image })));
  assert.equal((await new OverlookClient(fixture).observe({})).image_base64.length, image.length);
});

test("observe validates original geometry and returns full untruncated PNG", async (t) => {
  const image = png(512, 512, true).toString("base64");
  const payload = snapshot({ width: 512, height: 512, region: { x: 0, y: 0, width: 512, height: 512 }, image_base64: image });
  assert.ok(image.length > 524288);
  const fixture = await fakeControl(t, (_, socket) => reply(socket, payload));
  const result = await new OverlookClient(fixture).observe({});
  assert.equal(result.image_base64, image);
  assert.deepEqual(fixture.requests, [{ command: "observe" }]);
});

for (const [label, changes] of [
  ["wrong MIME", { mime_type: "text/plain" }],
  ["invalid base64", { image_base64: "***not base64***" }],
  ["non PNG", { image_base64: Buffer.from("not an image").toString("base64") }],
  ["PNG dimensions disagree with region", { image_base64: png(3, 2).toString("base64") }],
  ["out of bounds region", { region: { x: 1, y: 0, width: 2, height: 2 } }],
  ["silent scaling", { scale: 0.5 }],
  ["too many original pixels", { width: 10000, height: 10000 }],
  ["non finite age", { frame_age_ms: -1 }],
]) {
  test(`observe rejects ${label}`, async (t) => {
    const fixture = await fakeControl(t, (_, socket) => reply(socket, snapshot(changes)));
    const result = await settledWithin(new OverlookClient(fixture).observe({}));
    assert.equal(result.error?.code, "invalid_response");
  });
}

test("MCP observe emits native image once plus safe metadata", async (t) => {
  const payload = snapshot({ password: "PRIVATE_SENTINEL" });
  const fixture = await fakeControl(t, (_, socket) => reply(socket, payload));
  const server = buildServer({ client: new OverlookClient(fixture) });
  const client = new Client({ name: "image-test", version: "1" });
  const [a, b] = InMemoryTransport.createLinkedPair();
  t.after(async () => { await client.close(); await server.close(); });
  await server.connect(b); await client.connect(a);
  const result = await client.callTool({ name: "overlook_observe", arguments: {} });
  assert.equal(result.isError, undefined);
  assert.deepEqual(result.content, [{ type: "image", data: payload.image_base64, mimeType: "image/png" }]);
  assert.equal(result.structuredContent.frame_id, "frame-1");
  assert.equal(result.structuredContent.image_base64, undefined);
  assert.doesNotMatch(JSON.stringify(result), /PRIVATE_SENTINEL/);
});

test("act preserves original pixel coordinates and never retries", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, outcome()));
  const input = { ...action, action: { type: "click", x: 31, y: 20 } };
  assert.deepEqual(await new OverlookClient(fixture).act(input), outcome());
  assert.deepEqual(fixture.requests, [{ command: "act", ...input }]);
});

test("act cancellation sends a distinct cancel request and retains unknown reference", async (t) => {
  const abort = new AbortController();
  const fixture = await fakeControl(t, (request, socket) => {
    if (request.command === "act") abort.abort();
    if (request.command === "cancel") reply(socket, outcome("running"));
  });
  const result = await settledWithin(new OverlookClient(fixture).act(action, { signal: abort.signal }));
  assert.equal(result.error?.context.state, "outcome_unknown");
  assert.equal(result.error?.context.session_id, reference.session_id);
  assert.equal(result.error?.context.action_seq, reference.action_seq);
  assert.deepEqual(fixture.requests.map((r) => r.command), ["act", "cancel"]);
});

test("act EOF carries action identity for status lookup without repeating", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => socket.end());
  const result = await settledWithin(new OverlookClient(fixture).act(action));
  assert.equal(result.error?.code, "incomplete_response");
  assert.equal(result.error?.context.state, "outcome_unknown");
  assert.equal(result.error?.context.action_seq, 1);
  assert.equal(fixture.requests.length, 1);
});

test("unsafe action fields fail before network access", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, outcome()));
  const client = new OverlookClient(fixture);
  for (const invalid of [
    { ...action, action_seq: 0 },
    { ...action, action: { type: "scroll", x: 0, y: 0, delta_y: 11 } },
    { ...action, action: { type: "drag", x: 0, y: 0, to_x: 1, to_y: 1, duration_ms: 3000 } },
    { ...action, action: { type: "click", x: -1, y: 0 } },
    { ...action, action: { type: "text", value: "ok", token: "untrusted" } },
  ]) await assert.rejects(() => client.act(invalid));
  assert.equal(fixture.requests.length, 0);
});
