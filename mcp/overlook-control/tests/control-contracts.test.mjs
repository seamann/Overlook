import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  actionReferenceSchema, actInputSchema, actionResponseSchema, snapshotMetadataSchema,
} from "../dist/control-contracts.js";
import { OverlookClient } from "../dist/overlook-client.js";
import { fakeControl, reply } from "./fake-control.mjs";

// The native RemoteActionStateTests consume this same JSON without coercion.
const fixture = JSON.parse(await readFile(new URL("./fixtures/action-contract-boundaries.json", import.meta.url), "utf8"));
const reference = { session_id: "session-1", action_seq: 1 };
const click = { ...reference, frame_id: "frame-1", action: { type: "click", x: 0, y: 0 } };
const snapshot = {
  ok: true, protocol_version: 2, session_id: "session-1", frame_id: "frame-1",
  received_at: 1, frame_age_ms: 0, width: 2, height: 2,
  region: { x: 0, y: 0, width: 2, height: 2 }, scale: 1, mime_type: "image/png",
};

for (const { name, value, accepted } of fixture.sequence_cases) {
  test(`shared native sequence contract: ${name}`, () => {
    const cases = [
      [actionReferenceSchema, { ...reference, action_seq: value }],
      [actInputSchema, { ...click, action_seq: value }],
      [actionResponseSchema, { ok: true, protocol_version: 2, ...reference, action_seq: value, state: "transmitted" }],
      [snapshotMetadataSchema, { ...snapshot, next_action_seq: value }],
    ];
    for (const [schema, input] of cases) assert.equal(schema.safeParse(input).success, accepted);
    // Receipt next_action_seq is optional but has the same boundary when present.
    if (value !== undefined) {
      const receipt = { ok: true, protocol_version: 2, ...reference, next_action_seq: value, state: "transmitted" };
      assert.equal(actionResponseSchema.safeParse(receipt).success, accepted);
    }
  });
}

for (const { name, action, accepted } of fixture.action_cases) {
  test(`shared native action contract: ${name}`, () => {
    assert.equal(actInputSchema.safeParse({ ...click, action }).success, accepted);
  });
}

test("native-invalid sequence and zero scroll fail before opening a control connection", async (t) => {
  const control = await fakeControl(t, (request, socket) => reply(socket, {
    ok: true, protocol_version: 2, session_id: request.session_id, action_seq: request.action_seq, state: "transmitted",
  }));
  const client = new OverlookClient(control);
  for (const input of [
    { ...click, action_seq: fixture.maximum_action_sequence + 1 },
    { ...click, action: { type: "scroll", x: 0, y: 0, delta_y: 0 } },
  ]) {
    await assert.rejects(client.act(input), (error) => error.code === "invalid_request" && error.context.state === "not_started");
  }
  assert.equal(control.requests.length, 0);
});
