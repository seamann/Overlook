import { inflateSync } from "node:zlib";
import { MAXIMUM_PNG_BYTES, type Snapshot, snapshotSchema, validateResponse } from "./control-contracts.js";
import { ControlError } from "./control-errors.js";

const SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

export function validateSnapshot(value: unknown): Snapshot {
  const snapshot = validateResponse(snapshotSchema, value);
  const encoded = snapshot.image_base64;
  // Buffer.from alone tolerates malformed characters and incomplete padding.
  if (encoded.length % 4 !== 0 || /[^A-Za-z0-9+/=]/.test(encoded)) invalid();
  const bytes = Buffer.from(encoded, "base64");
  if (bytes.length > MAXIMUM_PNG_BYTES || bytes.toString("base64") !== encoded) invalid();
  try { validatePng(bytes, snapshot.region.width, snapshot.region.height); }
  catch { invalid(); }
  return snapshot;
}

function validatePng(bytes: Buffer, width: number, height: number): void {
  if (bytes.length < 57 || !bytes.subarray(0, 8).equals(SIGNATURE)) invalid();
  let offset = 8;
  let channels = 0;
  let ended = false;
  let palette = false;
  let color = 0;
  let idatClosed = false;
  const compressed: Buffer[] = [];
  while (offset < bytes.length) {
    if (offset + 12 > bytes.length) invalid();
    const length = bytes.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (end > bytes.length) invalid();
    const kind = bytes.toString("ascii", offset + 4, offset + 8);
    const data = bytes.subarray(offset + 8, end - 4);
    if (crc32(bytes.subarray(offset + 4, end - 4)) !== bytes.readUInt32BE(end - 4)) invalid();
    if (offset === 8) {
      if (kind !== "IHDR" || length !== 13 || data.readUInt32BE(0) !== width || data.readUInt32BE(4) !== height) invalid();
      color = data[9]!;
      channels = ({ 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 } as Record<number, number>)[color] ?? 0;
      // The native snapshot encoder emits non-interlaced, eight-bit PNG.
      if (!channels || data[8] !== 8 || data[10] !== 0 || data[11] !== 0 || data[12] !== 0) invalid();
    } else if (kind === "IHDR") invalid();
    else if (kind === "IDAT") {
      if (idatClosed || (color === 3 && !palette)) invalid();
      compressed.push(data);
    } else {
      if (compressed.length) idatClosed = true;
      if (kind === "PLTE") {
        if (palette || compressed.length || length === 0 || length > 768 || length % 3 !== 0) invalid();
        palette = true;
      } else if (kind === "IEND") {
        if (length !== 0 || end !== bytes.length || !compressed.length) invalid();
        ended = true;
      } else if ((bytes[offset + 4]! & 32) === 0) invalid(); // Unknown critical chunk.
    }
    offset = end;
  }
  if (!ended) invalid();
  const rowBytes = width * channels + 1;
  const pixels = inflateSync(Buffer.concat(compressed), { maxOutputLength: rowBytes * height });
  if (pixels.length !== rowBytes * height) invalid();
  for (let row = 0; row < height; row++) if (pixels[row * rowBytes]! > 4) invalid();
}

function crc32(data: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function invalid(): never { throw new ControlError("invalid_response"); }
