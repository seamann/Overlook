import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  OverlookClient,
  assertHeadless,
  screenPixelToSignedHid,
} from "../dist/overlook-client.js";
import {
  sanitizeStatusPayload,
  sanitizeToolError,
  sanitizeToolPayload,
} from "../dist/server.js";

test("pins all control requests to loopback", () => {
  const client = new OverlookClient({ host: "192.168.8.1" });
  assert.equal(client.host, "127.0.0.1");
});

test("maps the complete screen-pixel range to signed HID coordinates", () => {
  assert.equal(screenPixelToSignedHid(0, 3), -32_767);
  assert.equal(screenPixelToSignedHid(1, 3), 0);
  assert.equal(screenPixelToSignedHid(2, 3), 32_767);
  assert.throws(
    () => screenPixelToSignedHid(3, 3),
    /inside the supplied frame/,
  );
  assert.throws(
    () => screenPixelToSignedHid(0, 1),
    /Screen dimensions/,
  );
});

test("redacts paths and network addresses from MCP errors", () => {
  assert.equal(
    sanitizeToolError(
      new Error("read /Users/private/secret: connect 192.168.8.1 failed"),
    ),
    "Overlook MCP operation failed",
  );
  const secretError = sanitizeToolError(
    new Error('{"token":"secret-token","password":"secret-password","api_key":"secret-key"}'),
  );
  assert.doesNotMatch(secretError, /secret-token|secret-password|secret-key/);
  assert.equal(secretError, "Overlook MCP operation failed");
  assert.equal(
    sanitizeToolError(new Error('{"token":"prefix\\"MARKER"} password="prefix MARKER"')),
    "Overlook MCP operation failed",
  );
  assert.equal(
    sanitizeToolError(new Error("Headless mode is required for remote input")),
    "Headless mode is required for remote input",
  );
});

test("redacts local details from successful structured payloads", () => {
  assert.deepEqual(
    sanitizeToolPayload({
      ok: true,
      status: "Connected to 192.168.8.1",
      error: "read /Users/private/secret failed",
      local_input_capture_allowed: false,
    }),
    {
      ok: true,
      status: "Connected to [redacted-ip]",
      error: "read [redacted-path] failed",
      local_input_capture_allowed: false,
    },
  );
});

test("status payload uses an explicit safe field allowlist", () => {
  assert.deepEqual(
    sanitizeStatusPayload({
      ok: true,
      mode: "codexHeadless",
      status: "Ready",
      control_api: "Control API ready on 127.0.0.1:17891",
      hid_status: "Connected",
      local_input_capture_allowed: false,
      error: "read /private/secret",
      token: "secret-token",
      password: "secret-password",
      unexpected: { nested: "value" },
    }),
    {
      ok: true,
      mode: "codexHeadless",
      status: "Ready",
      control_api: "Control API ready on [redacted-ip]:17891",
      hid_status: "Connected",
      local_input_capture_allowed: false,
    },
  );
});

test("authenticates a newline-delimited request with the local token", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "overlook-mcp-client-"));
  const tokenPath = path.join(directory, "control-token");
  await writeFile(tokenPath, "test-token\n", { mode: 0o600 });

  const server = net.createServer((socket) => {
    let request = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      request += chunk;
      if (!request.includes("\n")) return;
      const payload = JSON.parse(request.trim());
      assert.deepEqual(payload, { command: "status", token: "test-token" });
      socket.end('{"ok":true,"mode":"codexHeadless","status":"Ready"}\n');
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());

  const address = server.address();
  assert.equal(typeof address, "object");
  const client = new OverlookClient({
    tokenPath,
    port: address.port,
    timeoutMs: 1_000,
  });

  assert.deepEqual(await client.status(), {
    ok: true,
    mode: "codexHeadless",
    status: "Ready",
  });
});

test("converts screen pixels to signed HID coordinates before clicking", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "overlook-mcp-click-"));
  const tokenPath = path.join(directory, "control-token");
  await writeFile(tokenPath, "test-token\n", { mode: 0o600 });
  const requests = [];

  const server = net.createServer((socket) => {
    let request = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      request += chunk;
      if (!request.includes("\n")) return;
      const payload = JSON.parse(request.trim());
      requests.push(payload);
      if (payload.command === "status") {
        socket.end(
          '{"ok":true,"mode":"codexHeadless","local_input_capture_allowed":false}\n',
        );
      } else {
        socket.end('{"ok":true}\n');
      }
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());

  const address = server.address();
  assert.equal(typeof address, "object");
  const client = new OverlookClient({
    tokenPath,
    port: address.port,
    timeoutMs: 1_000,
  });

  await client.click(0, 0, 1_920, 1_080);

  assert.deepEqual(requests, [
    { command: "status", token: "test-token" },
    { command: "click", x: -32_767, y: -32_767, token: "test-token" },
  ]);
});

test("sends a bounded shortcut after the Headless preflight", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "overlook-mcp-shortcut-"));
  const tokenPath = path.join(directory, "control-token");
  await writeFile(tokenPath, "test-token\n", { mode: 0o600 });
  const requests = [];

  const server = net.createServer((socket) => {
    let request = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      request += chunk;
      if (!request.includes("\n")) return;
      const payload = JSON.parse(request.trim());
      requests.push(payload);
      if (payload.command === "status") {
        socket.end(
          '{"ok":true,"mode":"codexHeadless","local_input_capture_allowed":false}\n',
        );
      } else {
        socket.end('{"ok":true}\n');
      }
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());

  const address = server.address();
  assert.equal(typeof address, "object");
  const client = new OverlookClient({
    tokenPath,
    port: address.port,
    timeoutMs: 1_000,
  });

  await client.shortcut(["ControlLeft", "KeyZ"]);

  assert.deepEqual(requests, [
    { command: "status", token: "test-token" },
    {
      command: "shortcut",
      keys: ["ControlLeft", "KeyZ"],
      token: "test-token",
    },
  ]);
});

test("rejects duplicate or unsupported shortcut keys before connecting", async () => {
  const client = new OverlookClient();
  await assert.rejects(
    () => client.shortcut(["ControlLeft", "ControlLeft"]),
    /missing or unsupported/,
  );
  await assert.rejects(
    () => client.shortcut(["ControlLeft", "KeyQ"]),
    /missing or unsupported/,
  );
});

test("headless preflight rejects mutation commands in Manual mode", () => {
  assert.throws(
    () => assertHeadless({ ok: true, mode: "manual", local_input_capture_allowed: true }),
    /Headless mode is required/,
  );
  assert.throws(
    () => assertHeadless({
      ok: true,
      mode: "codexHeadless",
      local_input_capture_allowed: true,
    }),
    /local input must be disabled/,
  );
  assert.doesNotThrow(() => assertHeadless({
    ok: true,
    mode: "codexHeadless",
    local_input_capture_allowed: false,
  }));
});

test("headless preflight delegates legacy status-only responses to the app gate", () => {
  assert.doesNotThrow(() => assertHeadless({
    ok: true,
    status: "Local input released",
  }));
  assert.doesNotThrow(() => assertHeadless({ ok: true, status: "Codex click" }));
  assert.doesNotThrow(() => assertHeadless({ ok: true, status: "Ready" }));
  assert.throws(
    () => assertHeadless({
      ok: true,
      mode: "manual",
      status: "Local input released",
      local_input_capture_allowed: true,
    }),
    /Headless mode is required/,
  );
});
