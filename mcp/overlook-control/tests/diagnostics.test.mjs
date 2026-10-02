import assert from "node:assert/strict";
import { mkdtemp, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { diagnoseLatestCrash } from "../dist/diagnostics.js";

test("summarizes only the newest Overlook crash without leaking local paths", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "overlook-mcp-crash-"));
  const oldPath = path.join(directory, "Overlook-older.ips");
  const newPath = path.join(directory, "Overlook-newer.ips");
  await writeFile(oldPath, '{"app_name":"Overlook"}\n{"exception":{"type":"OLD"}}');
  await writeFile(
    newPath,
    [
      '{"app_name":"Overlook","incident_id":"incident-1","timestamp":"2026-08-21 12:54:05 +0200"}',
      JSON.stringify({
        exception: { type: "EXC_BAD_ACCESS", signal: "SIGSEGV" },
        termination: { namespace: "SIGNAL", code: 11 },
        faultingThread: 0,
        threads: [
          {
            triggered: true,
            frames: [
              {
                symbol: "ContentView.restoreWindowFrame(for:fallbackToObserverSize:)",
                sourceFile: "/Users/private/Documents/ContentView.swift",
                sourceLine: 637,
              },
              { symbol: "-[NSWindow setFrame:display:animate:]" },
            ],
          },
        ],
        privateNetworkAddress: "192.168.8.1",
      }),
    ].join("\n"),
  );
  await utimes(oldPath, new Date(1_000), new Date(1_000));
  await utimes(newPath, new Date(2_000), new Date(2_000));

  const result = await diagnoseLatestCrash({ directory, maximumBytes: 64 * 1024 });

  assert.equal(result.file, "Overlook-newer.ips");
  assert.equal(result.exceptionType, "EXC_BAD_ACCESS");
  assert.equal(result.signal, "SIGSEGV");
  assert.equal(result.terminationCode, 11);
  assert.deepEqual(result.frames, [
    {
      symbol: "ContentView.restoreWindowFrame(for:fallbackToObserverSize:)",
      sourceFile: "ContentView.swift",
      sourceLine: 637,
    },
    { symbol: "-[NSWindow setFrame:display:animate:]" },
  ]);
  assert.doesNotMatch(JSON.stringify(result), /Users\/private|192\.168\.8\.1/);
});

test("returns a bounded no-crash result when no Overlook report exists", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "overlook-mcp-empty-"));
  await writeFile(path.join(directory, "OtherApp.ips"), "{}");

  assert.deepEqual(
    await diagnoseLatestCrash({ directory, maximumBytes: 1024 }),
    { found: false },
  );
});

test("treats a missing diagnostic directory as no crash report", async () => {
  const directory = path.join(os.tmpdir(), `overlook-mcp-missing-${Date.now()}`);
  assert.deepEqual(
    await diagnoseLatestCrash({ directory, maximumBytes: 1024 }),
    { found: false },
  );
});
