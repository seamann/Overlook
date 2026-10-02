import assert from "node:assert/strict";
import { chmod, writeFile } from "node:fs/promises";
import test from "node:test";
import { OverlookClient } from "../dist/overlook-client.js";
import { ControlError } from "../dist/control-errors.js";
import { sanitizeToolPayload, toolErrorResult } from "../dist/server.js";
import { fakeControl, reply, settledWithin } from "./fake-control.mjs";

const ref = { session_id: "session-1", action_seq: 1 };
const act = { ...ref, frame_id: "frame-1", action: { type: "text", value: "synthetic" } };

for (const error_code of ["snapshot_invalid_region", "unauthorized", "queue_full", "PRIVATE_SENTINEL"]) {
  test(`peer code ${error_code} is allowlisted without raw error leakage`, async (t) => {
    const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: false, error_code, error: "SECRET_RAW_ERROR" }));
    const result = await settledWithin(new OverlookClient(fixture).status());
    assert.equal(result.error.code, error_code === "PRIVATE_SENTINEL" ? "request_rejected" : error_code);
    assert.doesNotMatch(String(result.error), /PRIVATE_SENTINEL|SECRET_RAW_ERROR/);
  });
}

for (const [label, prepare, code] of [
  ["broad token rights", (file) => chmod(file, 0o644), "invalid_token_permissions"],
  ["empty token", (file) => writeFile(file, ""), "empty_token"],
]) {
  test(`${label} is rejected before connecting`, async (t) => {
    const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: true }));
    await prepare(fixture.tokenPath);
    const result = await settledWithin(new OverlookClient(fixture).status());
    assert.equal(result.error.code, code);
    assert.equal(fixture.requests.length, 0);
  });
}

test("missing local file cannot reveal its path", async () => {
  const result = await settledWithin(new OverlookClient({ tokenPath: "/missing/PRIVATE_SENTINEL/control-token" }).status());
  assert.equal(result.error.code, "local_file_unavailable");
  assert.doesNotMatch(String(result.error), /PRIVATE_SENTINEL/);
});

test("status cannot opt into the image wire limit", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: true, extra: "x".repeat(524288) }));
  const result = await settledWithin(new OverlookClient(fixture).status({ maximumBytes: 6 * 1024 * 1024 }));
  assert.equal(result.error?.code, "response_too_large");
});

test("escaped text exceeding the TCP request cap is rejected before dispatch", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: true, protocol_version: 2, ...ref, state: "transmitted" }));
  const result = await settledWithin(new OverlookClient(fixture).act({ ...act, action: { type: "text", value: "\u0001".repeat(100000) } }));
  assert.equal(result.error?.code, "invalid_request");
  assert.equal(result.error?.context.state, "not_started");
  assert.equal(fixture.requests.length, 0);
});

test("deadline invokes cancel and preserves definitive not_started outcome", async (t) => {
  const fixture = await fakeControl(t, (request, socket) => {
    if (request.command === "cancel") reply(socket, { ok: true, protocol_version: 2, ...ref, state: "not_started", error_code: "cancelled" });
  });
  const result = await settledWithin(new OverlookClient({ ...fixture, timeoutMs: 40 }).act(act));
  assert.equal(result.error.code, "deadline_exceeded");
  assert.equal(result.error.context.state, "not_started");
  assert.deepEqual(fixture.requests.map((r) => r.command), ["act", "cancel"]);
});

test("lost cancel acknowledgement remains unknown and never repeats act", async (t) => {
  const abort = new AbortController();
  const fixture = await fakeControl(t, (request, socket) => {
    if (request.command === "act") abort.abort();
    else socket.end();
  });
  const result = await settledWithin(new OverlookClient(fixture).act(act, { signal: abort.signal }));
  assert.equal(result.error.context.state, "outcome_unknown");
  assert.deepEqual(fixture.requests.map((r) => r.command), ["act", "cancel"]);
});

test("unknown historical action retains lookup identity", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: false, error_code: "action_unknown" }));
  const result = await settledWithin(new OverlookClient(fixture).actionStatus(ref));
  assert.equal(result.error.context.session_id, ref.session_id);
  assert.equal(result.error.context.action_seq, 1);
  assert.equal(result.error.context.state, "outcome_unknown");
});

test("result identity mismatch is not accepted", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: true, protocol_version: 2, ...ref, action_seq: 2, state: "transmitted" }));
  const result = await settledWithin(new OverlookClient(fixture).act(act));
  assert.equal(result.error.code, "invalid_response");
  assert.equal(result.error.context.state, "outcome_unknown");
});

test("tool errors preserve safe follow-up references and redact secret-valued keys", () => {
  const result = toolErrorResult(new ControlError("incomplete_response", { ...ref, state: "outcome_unknown" }));
  assert.equal(result.isError, true);
  assert.deepEqual(result.structuredContent.follow_up, { tool: "overlook_action_status", arguments: ref });
  assert.doesNotMatch(JSON.stringify(sanitizeToolPayload({ ok: true, token: "PRIVATE_SENTINEL", nested: { password: "PRIVATE_SENTINEL" } })), /PRIVATE_SENTINEL/);
});
