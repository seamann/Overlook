export const ACTION_STATES = ["queued", "running", "not_started", "transmitted", "outcome_unknown"] as const;
export type ActionState = (typeof ACTION_STATES)[number];

const ERROR_CODES = new Set([
  "invalid_request", "unauthorized", "headless_required", "input_unavailable", "input_blocked",
  "session_changed", "stale_frame", "action_conflict", "action_expired", "action_unknown",
  "queue_full", "cancelled", "cleanup_failed", "transport_error", "internal_error",
  "snapshot_busy", "snapshot_source_changed", "snapshot_timed_out", "snapshot_encoding_timed_out",
  "snapshot_invalid_region", "snapshot_unsupported_rotation", "snapshot_unsupported_pixel_buffer",
  "snapshot_image_too_large", "snapshot_png_too_large", "snapshot_encoding_failed",
  "snapshot_not_ready", "busy", "source_changed", "timed_out", "encoding_timed_out",
  "invalid_region", "unsupported_rotation", "unsupported_pixel_buffer", "image_too_large",
  "png_too_large", "encoding_failed", "incomplete_response", "deadline_exceeded",
  "invalid_response", "response_too_large", "request_rejected", "local_file_unavailable",
  "invalid_token_permissions", "empty_token", "outcome_unknown",
]);

export function safeErrorCode(value: unknown): string {
  return typeof value === "string" && ERROR_CODES.has(value) ? value : "request_rejected";
}

export type ErrorContext = {
  sent?: boolean;
  state?: ActionState;
  session_id?: string;
  action_seq?: number;
};

/** Only fixed codes and validated action references cross the MCP boundary. */
export class ControlError extends Error {
  readonly code: string;
  readonly context: ErrorContext;

  constructor(code: string, context: ErrorContext = {}) {
    const safeCode = safeErrorCode(code);
    super(`Overlook control error: ${safeCode}`);
    this.name = "ControlError";
    this.code = safeCode;
    this.context = { ...context };
  }
}
