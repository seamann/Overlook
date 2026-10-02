# Overlook Control MCP

Local stdio MCP server for Overlook diagnostics and controlled KVM input.

## Tools

- `overlook_status`: reads the current Overlook mode and input status.
- `overlook_latest_crash`: summarizes the newest `Overlook*.ips` report.
- `overlook_send_text`: sends text only when Overlook is already in Headless mode.
- `overlook_shortcut`: sends one allowlisted keyboard shortcut only in Headless mode.
- `overlook_click`: accepts a visible pixel plus the current remote-frame size
  and converts it internally to the signed HID coordinate range.

The five existing tools retain their arguments. The MCP cannot switch Overlook from Manual to Headless. It cannot run shell
commands or read arbitrary paths. Crash output is bounded and reduced to a
small allowlisted summary.

## Build

```bash
npm ci
npm test
```

Start with:

```bash
node dist/index.js
```

## Protocol 2: observe, act, inspect

The adapter adds four tools over the same authenticated, loopback-only JSON/TCP
connection. No REST service is required. Registration in a particular agent
client is separate from building and starting this stdio server.

| Tool | Arguments and result |
|---|---|
| `overlook_observe` | Optional `region: {x,y,width,height}`. Returns one native MCP PNG image and separate structured metadata: protocol/session/frame IDs, monotonic receive time, frame age, full original width/height, actual region, scale 1, rotation 0, and next action sequence. |
| `overlook_act` | `session_id`, `frame_id`, positive `action_seq`, and exactly one `action` object. The app checks the bound frame/session and serializes the action. |
| `overlook_action_status` | `session_id`, `action_seq`; reads a known outcome without replaying input. |
| `overlook_cancel` | `session_id`, `action_seq`; requests cancellation. A `running` response means the action/cleanup has not finished. |

Action objects are:

```text
{type: "click",    x, y}
{type: "scroll",   x, y, delta_y: -10..10}
{type: "drag",     x, y, to_x, to_y, duration_ms: 100..2000}
{type: "text",     value}
{type: "shortcut", keys}
```

All new coordinates are **original, oriented remote pixels**, with origin at
the top left. They are neither macOS window pixels nor HID values. An image ROI
retains the original full-frame dimensions; add its origin once to coordinates
measured inside the image. The app enforces the actual frame boundaries.
The existing MCP click still accepts `screenWidth`/`screenHeight` and performs
the HID conversion. The Python bridge's original signed-HID arguments are not
changed by this adapter.

Read `next_action_seq` from a fresh observation. One action is sent once. The
next change requires a fresh observation and, before replacing text, visibly
verified selection boundaries. A new frame cannot establish editor focus or
prove that Polarion finished processing. The app handles replay checking; the
MCP adapter never automatically repeats an action or assigns a new sequence
after an uncertain result.

## Outcomes and cancellation

Protocol 2 action responses carry `ok`, `protocol_version`, `session_id`,
`action_seq`, and `state`:

- `queued` / `running`: not a completed input operation; inspect action status.
- `not_started`: the app reports that this accepted action did not begin.
- `transmitted`: input was sent through the KVM path. This is **not** proof of
  correct Polarion text, selection, formatting, or persistence.
- `outcome_unknown`: inspect the current screen and action status before any
  further input. A retry is not safe merely because the previous reply was lost.

`ok:true` therefore does not mean the requested document change succeeded.
Protocol rejections and local transport failures set MCP `isError:true`, with
an allowlisted `error_code` in `structuredContent`. Uncertain action errors
retain their session/sequence and an `overlook_action_status` follow-up.
Raw server errors and request text are not returned as diagnostic messages.

The installed SDK's `context.mcpReq.signal` cancels pending MCP control requests.
For `overlook_act`, after possible dispatch the adapter uses a **separate** `cancel` connection
with its own bounded deadline, never the already aborted signal. If cleanup or
its acknowledgement is uncertain, the outcome remains unknown. SDK callers may
receive an abort error instead of the final tool result; use the original
session/sequence for the status lookup. Explicit cancellation cannot undo text.
Cancellation/status references share the local token's trust boundary; this
protocol does not claim isolation between agents running as the same user.

The legacy text/click/shortcut tools pass the same cancellation signal through
their status preflight and input request. A stop during preflight prevents the
subsequent input; a stop during input closes its TCP connection so the app can
cancel pending work. Already transmitted input cannot be undone. Legacy calls
have no action sequence for later status lookup; inspect the screen after an
uncertain result and do not automatically retry.

After app restart, old session/action identifiers are not permission to replay.
The app's bounded historical results may be unavailable. Observe the actual
Polarion state before deciding what further work remains.

## Bounds and image handling

- Ordinary responses and serialized requests: 512 KiB.
- Snapshot response wire limit: 6 MiB, allowing Base64/JSON overhead for a PNG
  of at most **4 MiB decoded file bytes**. Original image: at most 8,000,000 pixels.
- PNG must have the correct signature, chunk CRCs, region dimensions, bounded
  decompressed scanlines, and non-interlaced eight-bit encoding. MIME is
  `image/png`; Base64 must be canonical. Invalid/oversized images fail explicitly.
- PNG is emitted only as MCP image content, without text truncation or a second
  Base64 copy in `structuredContent`. Metadata uses a fixed allowlist.
- Text is at most 256 KiB UTF-8 and must also fit the serialized request cap.
  Escaping control characters can make the wire representation larger.
- The transport's default absolute deadline is 35 seconds, including token I/O;
  trickling bytes cannot extend it. An action timeout/abort can use up to two
  additional seconds for the separate cancellation request. Image validation
  checks the overall observation deadline before returning the result.

`overlook_status` retains its legacy fields and exposes validated protocol,
build/session, capabilities, next sequence, input-blocked, and separate
video/text/mouse readiness fields when supplied by the app. Missing data remains
missing; a stale HID activity label is not proof of a failed video connection.

## Verification

`npm test` builds and runs isolated fixtures. Tests use synthetic tokens and
loopback servers, not the user's KVM. Coverage for the compiled adapter:

```bash
node --test --experimental-test-coverage --test-coverage-include='dist/*.js' tests/*.test.mjs
```

The fixtures exercise EOF/partial JSON/slow trickle, cancellation, status errors,
the exact 4-MiB PNG boundary, image/metadata separation and a complete stdio MCP
handshake followed by fake TCP observe/act/status/cancel. This proves adapter
behavior only. Real Polarion editing and saving require separate authorized
visual acceptance checks against the installed app.

## Local build inventory (2026-09-15)

The canonical build sources are `.github/workflows/objective-c-xcode.yml`,
`Overlook/GLKVMClient.swift`, `Overlook/InputManager.swift`,
`Overlook/OverlookApp.swift`, `mcp/overlook-control/src/index.ts`, and
`mcp/overlook-control/tests/server.integration.test.mjs`. Six changed copies
whose names contained ` 2.` were removed from this isolated build and retained
under `/Users/doebber/Documents/Wago/work/overlook-session-refactor-evidence-2026-09-15/excluded-baseline-copies/`;
the SHA-256 inventory is in
`/Users/doebber/Documents/Wago/work/overlook-session-refactor-evidence-2026-09-15/build-inventory-sha256.json`.
Run `cd mcp/overlook-control && npm test` to build and test the local MCP
adapter. This inventory records a local build only; no deployment was performed.
