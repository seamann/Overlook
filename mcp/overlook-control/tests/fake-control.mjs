import { mkdtemp, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";

export async function fakeControl(t, handle) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "overlook-contract-"));
  const tokenPath = path.join(directory, "control-token");
  await writeFile(tokenPath, "synthetic-control-token", { mode: 0o600 });
  const sockets = new Set();
  const requests = [];
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on("error", () => {});
    socket.once("close", () => sockets.delete(socket));
    let received = "";
    socket.on("data", (chunk) => {
      received += chunk.toString();
      if (!received.includes("\n")) return;
      socket.removeAllListeners("data");
      const { token, ...request } = JSON.parse(received.split("\n")[0]);
      if (token !== "synthetic-control-token") throw new Error("Unexpected test credential");
      requests.push(request);
      handle(request, socket);
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  return { tokenPath, port: server.address().port, requests };
}

export function reply(socket, payload) {
  socket.end(`${JSON.stringify(payload)}\n`);
}

export async function settledWithin(promise, milliseconds = 600) {
  let deadline;
  try {
    return await Promise.race([
      promise.then((value) => ({ value }), (error) => ({ error })),
      new Promise((resolve) => { deadline = setTimeout(() => resolve({ unsettled: true }), milliseconds); }),
    ]);
  } finally {
    clearTimeout(deadline);
  }
}
