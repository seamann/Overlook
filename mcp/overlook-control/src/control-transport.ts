import { readFile, stat } from "node:fs/promises";
import net from "node:net";
import { ControlError, safeErrorCode } from "./control-errors.js";

export const NORMAL_RESPONSE_BYTES = 512 * 1024;
export const IMAGE_RESPONSE_BYTES = 6 * 1024 * 1024;
export type OverlookResponse = Record<string, unknown> & { ok: boolean; mode?: string };
export type RequestOptions = { signal?: AbortSignal | undefined; maximumBytes?: number; timeoutMs?: number };
type ConnectionOptions = { tokenPath: string; port: number; timeoutMs: number };

export function requestControl(
  connection: ConnectionOptions,
  payload: Record<string, unknown>,
  options: RequestOptions = {},
): Promise<OverlookResponse> {
  const mutation = ["act", "text", "click", "shortcut"].includes(String(payload.command));
  const maximumBytes = options.maximumBytes ?? NORMAL_RESPONSE_BYTES;
  const deadline = performance.now() + (options.timeoutMs ?? connection.timeoutMs);
  return new Promise((resolve, reject) => {
    let socket: net.Socket | undefined;
    let settled = false;
    let sent = false;
    let bytes = 0;
    const chunks: Buffer[] = [];
    const timeout = setTimeout(() => fail("deadline_exceeded"), options.timeoutMs ?? connection.timeoutMs);
    const onAbort = () => fail("cancelled");
    function finish(error?: ControlError, value?: OverlookResponse) {
      if (settled) return;
      if (!error && performance.now() >= deadline) { fail("deadline_exceeded"); return; }
      settled = true;
      clearTimeout(timeout);
      options.signal?.removeEventListener("abort", onAbort);
      socket?.destroy();
      if (error) reject(error);
      else resolve(value!);
    }
    function fail(code: string) {
      finish(new ControlError(code, {
        sent,
        ...(mutation ? { state: sent ? "outcome_unknown" as const : "not_started" as const } : {}),
      }));
    }
    function receive(chunk: Buffer) {
      if (settled) return;
      bytes += chunk.length;
      if (bytes > maximumBytes) { fail("response_too_large"); return; }
      const newline = chunk.indexOf(0x0a);
      chunks.push(newline < 0 ? chunk : chunk.subarray(0, newline));
      if (newline < 0) return;
      try {
        const response: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (!isResponse(response)) { fail("invalid_response"); return; }
        if (!response.ok) {
          // Never preserve raw server error prose, which can contain private data.
          finish(new ControlError(safeErrorCode(response.error_code), {
            sent,
            ...(mutation ? { state: "outcome_unknown" as const } : {}),
          }));
        } else finish(undefined, response);
      } catch { fail("invalid_response"); }
    }
    options.signal?.addEventListener("abort", onAbort, { once: true });
    if (options.signal?.aborted) { onAbort(); return; }
    // The absolute deadline also covers credential I/O; late reads never dispatch.
    void readToken(connection.tokenPath).then((token) => {
      if (settled) return;
      if (performance.now() >= deadline) { fail("deadline_exceeded"); return; }
      const message = `${JSON.stringify({ ...payload, token })}\n`;
      if (Buffer.byteLength(message, "utf8") > NORMAL_RESPONSE_BYTES) { fail("invalid_request"); return; }
      socket = net.createConnection({ host: "127.0.0.1", port: connection.port });
      socket.once("connect", () => {
        if (settled) return;
        if (performance.now() >= deadline) { fail("deadline_exceeded"); return; }
        sent = true; // Conservatively possibly dispatched before write completion.
        socket!.write(message);
      });
      socket.on("data", receive);
      socket.on("error", () => fail("transport_error"));
      socket.once("end", () => fail("incomplete_response"));
      socket.once("close", () => fail("incomplete_response"));
    }).catch((error: unknown) => fail(error instanceof ControlError ? error.code : "local_file_unavailable"));
  });
}

async function readToken(tokenPath: string): Promise<string> {
  const metadata = await stat(tokenPath);
  if ((metadata.mode & 0o077) !== 0) throw new ControlError("invalid_token_permissions");
  const token = (await readFile(tokenPath, "utf8")).trim();
  if (!token) throw new ControlError("empty_token");
  return token;
}

function isResponse(value: unknown): value is OverlookResponse {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    && typeof (value as Record<string, unknown>).ok === "boolean";
}
