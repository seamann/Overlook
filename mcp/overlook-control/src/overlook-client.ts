import { requestControl, IMAGE_RESPONSE_BYTES, NORMAL_RESPONSE_BYTES, type RequestOptions, type OverlookResponse } from "./control-transport.js";
export type { OverlookResponse } from "./control-transport.js";
import os from "node:os";
import path from "node:path";

const DEFAULT_TOKEN_PATH = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "Overlook",
  "Control",
  "control-token",
);

const MAXIMUM_TEXT_BYTES = 256 * 1024;
const COORDINATE_MINIMUM = -32_767;
const COORDINATE_MAXIMUM = 32_767;
const MAXIMUM_SCREEN_DIMENSION = 16_384;

import {
  REMOTE_SHORTCUT_KEYS, type RemoteShortcutKey, observeInputSchema, actInputSchema,
  actionReferenceSchema, actionResponseSchema, type ObserveInput, type ActInput,
  type ActionReference, type ActionResponse, type Snapshot, validateInput, validateResponse,
} from "./control-contracts.js";
import { validateSnapshot } from "./snapshot-image.js";
import { ControlError, safeErrorCode } from "./control-errors.js";
export { REMOTE_SHORTCUT_KEYS } from "./control-contracts.js";
export type { RemoteShortcutKey } from "./control-contracts.js";

const remoteShortcutKeySet = new Set<string>(REMOTE_SHORTCUT_KEYS);

export type OverlookClientOptions = {
  tokenPath?: string;
  port?: number;
  timeoutMs?: number;
};

export class OverlookClient {
  readonly tokenPath: string;
  readonly host: string;
  readonly port: number;
  readonly timeoutMs: number;

  constructor(options: OverlookClientOptions = {}) {
    this.tokenPath = options.tokenPath ?? DEFAULT_TOKEN_PATH;
    this.host = "127.0.0.1";
    this.port = options.port ?? 17_891;
    this.timeoutMs = options.timeoutMs ?? 35_000;
  }

  status(options: RequestOptions = {}): Promise<OverlookResponse> {
    return this.request({ command: "status" }, options);
  }

  async sendText(text: string, options: RequestOptions = {}): Promise<OverlookResponse> {
    if (Buffer.byteLength(text, "utf8") > MAXIMUM_TEXT_BYTES) {
      throw new Error("Text exceeds the Overlook control API limit");
    }
    assertHeadless(await this.status(options));
    return this.request({ command: "text", value: text }, options);
  }

  async click(
    x: number,
    y: number,
    screenWidth: number,
    screenHeight: number,
    options: RequestOptions = {},
  ): Promise<OverlookResponse> {
    const signedX = screenPixelToSignedHid(x, screenWidth);
    const signedY = screenPixelToSignedHid(y, screenHeight);
    assertHeadless(await this.status(options));
    return this.request({ command: "click", x: signedX, y: signedY }, options);
  }

  async shortcut(keys: RemoteShortcutKey[], options: RequestOptions = {}): Promise<OverlookResponse> {
    if (
      keys.length < 1
      || keys.length > 4
      || new Set(keys).size !== keys.length
      || !keys.every((key) => remoteShortcutKeySet.has(key))
    ) {
      throw new Error("Shortcut keys are missing or unsupported");
    }
    assertHeadless(await this.status(options));
    return this.request({ command: "shortcut", keys }, options);
  }

  async observe(input: ObserveInput = {}, options: RequestOptions = {}): Promise<Snapshot> {
    const deadline = performance.now() + (options.timeoutMs ?? this.timeoutMs);
    const args = validateInput(observeInputSchema, input);
    const response = await this.request({ command: "observe", ...args }, { ...options, maximumBytes: IMAGE_RESPONSE_BYTES });
    const snapshot = validateSnapshot(response);
    if (args.region && Object.keys(args.region).some((key) =>
      args.region![key as keyof typeof args.region] !== snapshot.region[key as keyof typeof snapshot.region])) {
      throw new ControlError("invalid_response");
    }
    if (!args.region && (snapshot.region.x !== 0 || snapshot.region.y !== 0
      || snapshot.region.width !== snapshot.width || snapshot.region.height !== snapshot.height)) {
      throw new ControlError("invalid_response");
    }
    if (options.signal?.aborted) throw new ControlError("cancelled");
    if (performance.now() >= deadline) throw new ControlError("deadline_exceeded");
    return snapshot;
  }

  async act(input: ActInput, options: RequestOptions = {}): Promise<ActionResponse> {
    const args = validateInput(actInputSchema, input);
    const reference = { session_id: args.session_id, action_seq: args.action_seq };
    try {
      return this.validateAction(await this.request({ command: "act", ...args }, options), reference);
    } catch (error) {
      const failure = error instanceof ControlError ? error : new ControlError("internal_error");
      let state = failure.context.state ?? "outcome_unknown";
      if (failure.context.sent && ["cancelled", "deadline_exceeded"].includes(failure.code)) {
        try {
          // Abort uses a fresh connection and independent deadline, never the aborted signal.
          const stopped = await this.cancel(reference, { timeoutMs: Math.min(this.timeoutMs, 2000) });
          state = stopped.state === "not_started" || stopped.state === "transmitted" ? stopped.state : "outcome_unknown";
        } catch { state = "outcome_unknown"; }
      }
      throw new ControlError(failure.code, { ...failure.context, ...reference, state });
    }
  }

  async actionStatus(input: ActionReference, options: RequestOptions = {}): Promise<ActionResponse> {
    const args = validateInput(actionReferenceSchema, input);
    return this.referencedRequest("action_status", args, options);
  }

  async cancel(input: ActionReference, options: RequestOptions = {}): Promise<ActionResponse> {
    const args = validateInput(actionReferenceSchema, input);
    return this.referencedRequest("cancel", args, options);
  }

  private async referencedRequest(command: "cancel" | "action_status", reference: ActionReference, options: RequestOptions): Promise<ActionResponse> {
    try {
      return this.validateAction(await this.request({ command, ...reference }, options), reference);
    } catch (error) {
      const failure = error instanceof ControlError ? error : new ControlError("internal_error");
      throw new ControlError(failure.code, { ...failure.context, ...reference, state: "outcome_unknown" });
    }
  }

  private validateAction(response: OverlookResponse, reference: ActionReference): ActionResponse {
    const action = validateResponse(actionResponseSchema, response);
    if (action.session_id !== reference.session_id || action.action_seq !== reference.action_seq) {
      throw new ControlError("invalid_response");
    }
    return { ...action, ...(action.error_code ? { error_code: safeErrorCode(action.error_code) } : {}) };
  }

  private request(payload: Record<string, unknown>, options: RequestOptions = {}): Promise<OverlookResponse> {
    return requestControl(this, payload, { ...options, maximumBytes: payload.command === "observe" ? IMAGE_RESPONSE_BYTES : NORMAL_RESPONSE_BYTES });
  }

}

export function screenPixelToSignedHid(pixel: number, extent: number): number {
  if (!Number.isInteger(extent) || extent < 2 || extent > MAXIMUM_SCREEN_DIMENSION) {
    throw new Error("Screen dimensions must be integers between 2 and 16384");
  }
  if (!Number.isInteger(pixel) || pixel < 0 || pixel >= extent) {
    throw new Error("Screen coordinates must be integers inside the supplied frame");
  }

  const span = COORDINATE_MAXIMUM - COORDINATE_MINIMUM;
  return Math.round(COORDINATE_MINIMUM + (pixel * span) / (extent - 1));
}

export function assertHeadless(status: OverlookResponse): void {
  // Legacy Overlook builds expose only an activity-status string. They still
  // enforce their own Headless command gate server-side for every mutation.
  const isLegacyStatusOnly = status.mode === undefined
    && status.local_input_capture_allowed === undefined
    && typeof status.status === "string";

  if (isLegacyStatusOnly) return;

  if (status.mode !== "codexHeadless") {
    throw new Error("Headless mode is required for remote input");
  }
  if (status.local_input_capture_allowed !== false) {
    throw new Error("Headless local input must be disabled before remote input");
  }
}

function isOverlookResponse(value: unknown): value is OverlookResponse {
  return typeof value === "object"
    && value !== null
    && typeof (value as Record<string, unknown>).ok === "boolean";
}
