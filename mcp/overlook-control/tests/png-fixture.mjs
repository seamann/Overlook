import { deflateSync } from "node:zlib";

export function png(width = 2, height = 2, noisy = false) {
  const data = Buffer.alloc((width * 4 + 1) * height);
  let random = 0x13572468;
  for (let row = 0; row < height; row++) {
    for (let column = 1; column <= width * 4; column++) {
      random ^= random << 13; random ^= random >>> 17; random ^= random << 5;
      data[row * (width * 4 + 1) + column] = noisy ? random & 255 : 128;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header), chunk("IDAT", deflateSync(data)), chunk("IEND", Buffer.alloc(0)),
  ]);
}

function chunk(type, data) {
  const name = Buffer.from(type);
  const result = Buffer.alloc(12 + data.length);
  result.writeUInt32BE(data.length); name.copy(result, 4); data.copy(result, 8);
  let crc = 0xffffffff;
  for (const byte of Buffer.concat([name, data])) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  result.writeUInt32BE((crc ^ 0xffffffff) >>> 0, result.length - 4);
  return result;
}

export function paddedPng(totalBytes) {
  const original = png();
  const padding = chunk("tEXt", Buffer.alloc(totalBytes - original.length - 12, 65));
  return Buffer.concat([original.subarray(0, 33), padding, original.subarray(33)]);
}

export function snapshot(overrides = {}) {
  return {
    ok: true, protocol_version: 2, session_id: "session-1", frame_id: "frame-1",
    received_at: 1234.5, frame_age_ms: 0, width: 2, height: 2,
    region: { x: 0, y: 0, width: 2, height: 2 }, scale: 1,
    mime_type: "image/png", image_base64: png().toString("base64"), next_action_seq: 1,
    ...overrides,
  };
}
