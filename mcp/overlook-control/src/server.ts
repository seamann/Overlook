import { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod/v4";

import { diagnoseLatestCrash } from "./diagnostics.js";
import { OverlookClient, REMOTE_SHORTCUT_KEYS } from "./overlook-client.js";
import { observeInputSchema, actInputSchema, actionReferenceSchema, actionResponseSchema, snapshotMetadataSchema } from "./control-contracts.js";
import { ControlError, safeErrorCode } from "./control-errors.js";

type ToolPayload = Record<string, unknown>;

const screenCoordinateSchema = z.number().int().min(0).max(16_383);
const screenDimensionSchema = z.number().int().min(2).max(16_384);
const clickInputSchema = z.object({
  x: screenCoordinateSchema.describe("Zero-based horizontal pixel inside the remote video frame."),
  y: screenCoordinateSchema.describe("Zero-based vertical pixel inside the remote video frame."),
  screenWidth: screenDimensionSchema.describe("Width of the remote video frame in pixels."),
  screenHeight: screenDimensionSchema.describe("Height of the remote video frame in pixels."),
}).refine(({ x, screenWidth }) => x < screenWidth, {
  message: "x must be inside screenWidth",
  path: ["x"],
}).refine(({ y, screenHeight }) => y < screenHeight, {
  message: "y must be inside screenHeight",
  path: ["y"],
});
const shortcutInputSchema = z.object({
  keys: z.array(z.enum(REMOTE_SHORTCUT_KEYS)).min(1).max(4),
}).refine(({ keys }) => new Set(keys).size === keys.length, {
  message: "Shortcut keys must be unique",
  path: ["keys"],
});

export function buildServer(options: { client?: OverlookClient } = {}): McpServer {
  const server = new McpServer(
    { name: "overlook-control", version: "1.0.0" },
    { capabilities: { tools: {} } },
  );
  const client = options.client ?? new OverlookClient();

  server.registerTool(
    "overlook_status",
    {
      title: "Overlook Status",
      description: "Read Overlook's local control mode and input status.",
      inputSchema: z.object({}),
    },
    async (_, context) => toolResult(async () => sanitizeStatusPayload(await client.status({ signal: context.mcpReq.signal }))),
  );

  server.registerTool(
    "overlook_latest_crash",
    {
      title: "Latest Overlook Crash",
      description: "Summarize the newest local Overlook crash report without returning raw private data.",
      inputSchema: z.object({}),
    },
    async () => toolResult(() => diagnoseLatestCrash()),
  );

  server.registerTool(
    "overlook_send_text",
    {
      title: "Send Text Through Overlook",
      description: "Send text to the connected KVM. Overlook must already be in Headless mode.",
      inputSchema: z.object({
        text: z.string().min(1).max(65_536),
      }),
    },
    async ({ text }, context) => toolResult(() => client.sendText(text, { signal: context.mcpReq.signal })),
  );

  server.registerTool(
    "overlook_shortcut",
    {
      title: "Send Shortcut Through Overlook",
      description: "Send one bounded keyboard shortcut to the connected KVM. Overlook must already be in Headless mode.",
      inputSchema: shortcutInputSchema,
    },
    async ({ keys }, context) => toolResult(() => client.shortcut(keys, { signal: context.mcpReq.signal })),
  );

  server.registerTool(
    "overlook_click",
    {
      title: "Click Through Overlook",
      description: "Click one visible pixel inside the current remote video frame. Overlook must already be in Headless mode.",
      inputSchema: clickInputSchema,
    },
    async ({ x, y, screenWidth, screenHeight }, context) => toolResult(
      () => client.click(x, y, screenWidth, screenHeight, { signal: context.mcpReq.signal }),
    ),
  );

  server.registerTool("overlook_observe", {
    title: "Observe Overlook Remote Frame",
    description: "Read a new remote PNG and its session/frame metadata. Region uses original oriented pixels; scale is one. Images and OCR cannot prove editor focus or saving.",
    inputSchema: observeInputSchema,
    outputSchema: snapshotMetadataSchema,
    annotations: { readOnlyHint: true, destructiveHint: false },
  }, async (args, context) => {
    try {
      const { image_base64, ...metadata } = await client.observe(args, { signal: context.mcpReq.signal });
      return { content: [{ type: "image" as const, data: image_base64, mimeType: "image/png" }], structuredContent: metadata };
    } catch (error) { return toolErrorResult(error); }
  });

  server.registerTool("overlook_act", {
    title: "Apply One Observed Overlook Action",
    description: "Send one frame-bound click, scroll, drag, text or shortcut in Headless. Coordinates are original pixels. Use observe.next_action_seq. Inspect the resulting screen before another edit; transmitted is not a Polarion save. Never replay after an uncertain result.",
    inputSchema: actInputSchema,
    outputSchema: actionResponseSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false },
  }, async (args, context) => toolResult(() => client.act(args, { signal: context.mcpReq.signal })));

  server.registerTool("overlook_action_status", {
    title: "Read Overlook Action Outcome",
    description: "Read a known session/action sequence without replaying it. Old or unknown outcomes are not permission to send again.",
    inputSchema: actionReferenceSchema,
    outputSchema: actionResponseSchema,
    annotations: { readOnlyHint: true, destructiveHint: false },
  }, async (args, context) => toolResult(() => client.actionStatus(args, { signal: context.mcpReq.signal })));

  server.registerTool("overlook_cancel", {
    title: "Cancel One Overlook Action",
    description: "Request cancellation for a known session/action sequence. running means cleanup has not finished. Cancellation cannot undo already transmitted text; follow with action_status and observation.",
    inputSchema: actionReferenceSchema,
    outputSchema: actionResponseSchema,
    annotations: { readOnlyHint: false, destructiveHint: false },
  }, async (args, context) => toolResult(() => client.cancel(args, { signal: context.mcpReq.signal })));

  return server;
}

async function toolResult(operation: () => Promise<ToolPayload>) {
  try {
    const payload = sanitizeToolPayload(await operation());
    return {
      content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }],
      structuredContent: payload,
    };
  } catch (error) { return toolErrorResult(error); }
}

export function toolErrorResult(error: unknown) {
  const message = sanitizeToolError(error);
  const context = error instanceof ControlError ? error.context : {};
  const reference = context.session_id !== undefined && context.action_seq !== undefined
    ? { session_id: context.session_id, action_seq: context.action_seq } : undefined;
  return {
    isError: true,
    content: [{ type: "text" as const, text: message }],
    structuredContent: {
      ok: false,
      error_code: error instanceof ControlError ? error.code : "internal_error",
      ...(context.state ? { state: context.state } : {}),
      ...(reference ?? {}),
      ...(reference ? { follow_up: { tool: "overlook_action_status", arguments: reference } } : {}),
    },
  };
}

export function sanitizeToolError(error: unknown): string {
  if (error instanceof ControlError) return error.message;
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  if (code === "ENOENT") return "A required local Overlook file is unavailable";
  if (code === "ECONNREFUSED" || code === "ETIMEDOUT") {
    return "The local Overlook control API is unavailable";
  }

  const message = error instanceof Error ? error.message : "Unknown Overlook MCP error";
  const safeMessages = new Set([
    "Coordinates must be integers in the signed HID range",
    "Diagnostic size limit is invalid",
    "Headless local input must be disabled before remote input",
    "Headless mode is required for remote input",
    "Overlook control API timed out",
    "Overlook control token is empty",
    "Overlook control token permissions are too broad",
    "Overlook crash report exceeds the diagnostic size limit",
    "Overlook crash report is not valid JSON",
    "Overlook response exceeded the size limit",
    "Overlook returned an invalid response",
    "Overlook returned no response",
    "Screen coordinates must be integers inside the supplied frame",
    "Screen dimensions must be integers between 2 and 16384",
    "Shortcut keys are missing or unsupported",
    "Text exceeds the Overlook control API limit",
  ]);
  if (safeMessages.has(message)) return message;
  if (message.startsWith("Overlook rejected the request:")) {
    return "Overlook rejected the request";
  }
  return "Overlook MCP operation failed";
}

export function sanitizeToolPayload(payload: ToolPayload): ToolPayload {
  return sanitizePayloadValue(payload, 0) as ToolPayload;
}

export function sanitizeStatusPayload(payload: ToolPayload): ToolPayload {
  const sanitized: ToolPayload = {};
  const booleanFields = ["ok", "local_input_capture_allowed"];
  const stringFields = ["status", "mode", "control_api", "hid_status"];
  for (const key of booleanFields) {
    if (typeof payload[key] === "boolean") sanitized[key] = payload[key];
  }
  for (const key of stringFields) {
    if (typeof payload[key] === "string") sanitized[key] = redactSensitiveText(payload[key]);
  }
  if (payload.protocol_version === 2) sanitized.protocol_version = 2;
  if (typeof payload.error_code === "string") sanitized.error_code = safeErrorCode(payload.error_code);
  for (const key of ["build_id", "session_id"]) {
    if (typeof payload[key] === "string" && /^[A-Za-z0-9][A-Za-z0-9._:+ -]{0,127}$/.test(payload[key])) sanitized[key] = payload[key];
  }
  if (Number.isSafeInteger(payload.next_action_seq) && (payload.next_action_seq as number) > 0) sanitized.next_action_seq = payload.next_action_seq;
  if (Array.isArray(payload.capabilities)) sanitized.capabilities = payload.capabilities.filter(
    (item) => typeof item === "string" && /^[a-z][a-z0-9_]{0,63}$/.test(item),
  ).slice(0, 32);
  if (typeof payload.input_blocked === "boolean") sanitized.input_blocked = payload.input_blocked;
  if (payload.readiness && typeof payload.readiness === "object" && !Array.isArray(payload.readiness)) {
    const readiness = payload.readiness as Record<string, unknown>;
    sanitized.readiness = Object.fromEntries(["video", "text", "mouse"].flatMap(
      (key) => typeof readiness[key] === "boolean" ? [[key, readiness[key]]] : [],
    ));
  }
  return sanitized;
}

function sanitizePayloadValue(value: unknown, depth: number): unknown {
  if (typeof value === "string") return redactSensitiveText(value);
  if (value === null || typeof value !== "object") return value;
  if (depth >= 5) return "[redacted-nested-value]";
  if (Array.isArray(value)) {
    return value.slice(0, 100).map((item) => sanitizePayloadValue(item, depth + 1));
  }
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .slice(0, 100)
      .map(([key, item]) => [key, /token|password|secret|api[_-]?key|authorization/i.test(key)
        ? "[redacted-secret]" : sanitizePayloadValue(item, depth + 1)]),
  );
}

function redactSensitiveText(message: string): string {
  return message
    .slice(0, 500)
    .replace(
      /(["'](?:token|password|api[_-]?key|secret)["']\s*:\s*)["'][^"'\n]*["']/gi,
      '$1"[redacted-secret]"',
    )
    .replace(
      /\b(token|password|api[_-]?key)(\s*[:=]\s*)[^\s,;}]+/gi,
      "$1$2[redacted-secret]",
    )
    .replace(/\bBearer\s+\S+/gi, "Bearer [redacted-secret]")
    .replace(/\/(?:Users|home)\/[^:\n]+:\s*/g, "[redacted-path] ")
    .replace(/\/(?:Users|home)\/\S+/g, "[redacted-path]")
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "[redacted-ip]");
}
