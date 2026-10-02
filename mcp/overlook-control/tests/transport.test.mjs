import assert from "node:assert/strict";
import test from "node:test";
import net from "node:net";
import { EventEmitter } from "node:events";
import { OverlookClient } from "../dist/overlook-client.js";
import { requestControl } from "../dist/control-transport.js";
import { fakeControl, reply, settledWithin } from "./fake-control.mjs";

for (const [label, bytes] of [["empty EOF", ""], ["partial JSON EOF", '{"ok":']]) {
  test(`settles ${label} immediately as an incomplete response`, async (t) => {
    const fixture = await fakeControl(t, (_, socket) => socket.end(bytes));
    const result = await settledWithin(new OverlookClient({ ...fixture, timeoutMs: 60 }).status());
    assert.equal(result.error?.code, "incomplete_response");
  });
}

test("a valid response followed by end/close settles successfully once", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: true }));
  assert.deepEqual(await new OverlookClient(fixture).status(), { ok: true });
});

test("slow trickle cannot extend the absolute deadline", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => {
    const interval = setInterval(() => socket.write(" "), 10);
    socket.once("close", () => clearInterval(interval));
  });
  const result = await settledWithin(new OverlookClient({ ...fixture, timeoutMs: 60 }).status());
  assert.equal(result.error?.code, "deadline_exceeded");
});

test("aborting an active read closes its socket and returns cancelled", async (t) => {
  const abort = new AbortController();
  const fixture = await fakeControl(t, () => abort.abort());
  const result = await settledWithin(new OverlookClient(fixture).status({ signal: abort.signal }));
  assert.equal(result.error?.code, "cancelled");
});

test("pre-aborted requests send no bytes", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: true }));
  const result = await settledWithin(new OverlookClient(fixture).status({ signal: AbortSignal.abort() }));
  assert.equal(result.error?.code, "cancelled");
  assert.equal(fixture.requests.length, 0);
});

test("malformed replies and server errors never expose raw peer strings", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => socket.end('SECRET_BAD_JSON\n'));
  const result = await settledWithin(new OverlookClient(fixture).status());
  assert.equal(result.error?.code, "invalid_response");
  assert.doesNotMatch(String(result.error), /SECRET_BAD_JSON/);
});

test("ordinary status replies retain the 512KiB wire cap", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => socket.end(JSON.stringify({ ok: true, padding: "x".repeat(524288) }) + "\n"));
  const result = await settledWithin(new OverlookClient(fixture).status());
  assert.equal(result.error?.code, "response_too_large");
});

test("a connect callback delayed past the deadline never dispatches mutation bytes", async (t) => {
  const fixture = await fakeControl(t, (_, socket) => reply(socket, { ok: true }));
  const original = net.createConnection;
  let writes = 0;
  t.after(() => { net.createConnection = original; });
  net.createConnection = () => {
    const socket = new EventEmitter();
    socket.destroy = () => socket.emit("close");
    socket.write = () => { writes++; return true; };
    process.nextTick(() => {
      const until = performance.now() + 80;
      while (performance.now() < until) { /* controlled event-loop stall */ }
      socket.emit("connect");
    });
    return socket;
  };
  const result = await settledWithin(requestControl({ ...fixture, timeoutMs: 40 }, { command: "act" }));
  assert.equal(result.error?.code, "deadline_exceeded");
  assert.equal(result.error?.context.state, "not_started");
  assert.equal(writes, 0);
});
