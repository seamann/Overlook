import { z } from "zod/v4";
import { ACTION_STATES, ControlError } from "./control-errors.js";

export const MAXIMUM_PNG_BYTES = 4 * 1024 * 1024;
export const MAXIMUM_FRAME_PIXELS = 8_000_000;
export const REMOTE_SHORTCUT_KEYS = [
  "ControlLeft", "ShiftLeft", "AltLeft", "MetaLeft", "KeyA", "KeyC", "KeyV", "KeyX", "KeyZ",
  "Enter", "Escape", "Tab", "Backspace", "Delete", "Home", "End",
  "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
] as const;
export type RemoteShortcutKey = (typeof REMOTE_SHORTCUT_KEYS)[number];
const identifier = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/);
const coordinate = z.number().int().min(0).max(16_383);
const dimension = z.number().int().min(1).max(16_384);
const sequence = z.number().int().min(1).max(Number.MAX_SAFE_INTEGER);
export const regionSchema = z.strictObject({ x: coordinate, y: coordinate, width: dimension, height: dimension });
export const observeInputSchema = z.strictObject({ region: regionSchema.optional() });
export const shortcutKeysSchema = z.array(z.enum(REMOTE_SHORTCUT_KEYS)).min(1).max(4)
  .refine((keys) => new Set(keys).size === keys.length, "Shortcut keys must be unique");
export const actionReferenceSchema = z.strictObject({ session_id: identifier, action_seq: sequence });
export const actInputSchema = actionReferenceSchema.extend({
  frame_id: identifier,
  action: z.discriminatedUnion("type", [
    z.strictObject({ type: z.literal("click"), x: coordinate, y: coordinate }),
    z.strictObject({ type: z.literal("scroll"), x: coordinate, y: coordinate, delta_y: z.number().int().min(-10).max(10) }),
    z.strictObject({ type: z.literal("drag"), x: coordinate, y: coordinate, to_x: coordinate, to_y: coordinate, duration_ms: z.number().int().min(100).max(2000) }),
    z.strictObject({ type: z.literal("text"), value: z.string().min(1).max(262_144).refine((value) => Buffer.byteLength(value, "utf8") <= 262_144, "Text is too large") }),
    z.strictObject({ type: z.literal("shortcut"), keys: shortcutKeysSchema }),
  ]),
});
export type ObserveInput = z.infer<typeof observeInputSchema>;
export type ActionReference = z.infer<typeof actionReferenceSchema>;
export type ActInput = z.infer<typeof actInputSchema>;

export const snapshotSchema = z.object({
  ok: z.literal(true), protocol_version: z.literal(2), session_id: identifier, frame_id: identifier,
  received_at: z.number().finite().nonnegative(), frame_age_ms: z.number().finite().nonnegative(),
  width: dimension, height: dimension, region: regionSchema, scale: z.literal(1),
  rotation_degrees: z.literal(0).optional(),
  next_action_seq: sequence,
  mime_type: z.literal("image/png"),
  image_base64: z.string().min(1).max(Math.ceil(MAXIMUM_PNG_BYTES / 3) * 4),
}).refine((value) => value.width * value.height <= MAXIMUM_FRAME_PIXELS
  && value.region.x + value.region.width <= value.width
  && value.region.y + value.region.height <= value.height);
export type Snapshot = z.infer<typeof snapshotSchema>;
const { image_base64: _imageField, ...metadataFields } = snapshotSchema.shape;
export const snapshotMetadataSchema = z.object(metadataFields);

export const actionResponseSchema = z.object({
  ok: z.literal(true), protocol_version: z.literal(2), session_id: identifier, action_seq: sequence,
  state: z.enum(ACTION_STATES), error_code: z.string().max(64).optional(),
  next_action_seq: sequence.optional(),
});
export type ActionResponse = z.infer<typeof actionResponseSchema>;

export function validateInput<T>(schema: z.ZodType<T>, input: unknown): T {
  const parsed = schema.safeParse(input);
  if (!parsed.success) throw new ControlError("invalid_request", { state: "not_started" });
  return parsed.data;
}

export function validateResponse<T>(schema: z.ZodType<T>, input: unknown): T {
  const parsed = schema.safeParse(input);
  if (!parsed.success) throw new ControlError("invalid_response");
  return parsed.data;
}
