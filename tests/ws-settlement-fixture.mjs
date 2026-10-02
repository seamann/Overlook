// Loopback-only TLS fixture with a deliberately suspended WebSocket handshake.
import { createServer } from 'node:https';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';

const directory = mkdtempSync(join(tmpdir(), 'overlook-ws-settlement-'));
chmodSync(directory, 0o700);
const key = join(directory, 'key.pem');
const cert = join(directory, 'cert.pem');
execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
  '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost'], { stdio: 'ignore', timeout: 5000 });
chmodSync(key, 0o600);
let mode = 'stall-handshake';
let records = [];
const sockets = new Map();
const transportSockets = new Set();
const respond = (response, code, body) => response.writeHead(code,
  { 'Content-Type': 'application/json' }).end(JSON.stringify(body));
const server = createServer({ key: readFileSync(key), cert: readFileSync(cert) }, (request, response) => {
  let url;
  try { url = new URL(request.url, 'https://127.0.0.1'); }
  catch { respond(response, 400, { error: 'Invalid target' }); return; }
  if (url.pathname === '/fixture/health') {
    respond(response, 200, { fixture: 'overlook-ws-settlement', loopback: true });
  } else if (url.pathname === '/fixture/status') {
    respond(response, 200, { connections: records });
  } else if (url.pathname === '/fixture/mode' && request.method === 'POST') {
    const next = url.searchParams.get('value');
    if (!['normal', 'stall-handshake'].includes(next)) respond(response, 400, { error: 'Invalid mode' });
    else { mode = next; respond(response, 200, { mode }); }
  } else if (url.pathname === '/fixture/close' && request.method === 'POST') {
    sockets.get(Number(url.searchParams.get('id')))?.destroy();
    respond(response, 200, { ok: true });
  } else if (url.pathname === '/api/system/get_config') {
    respond(response, 200, { ok: true, result: { config: { is_absolute_mouse: true } } });
  } else respond(response, 404, { error: 'Unknown fixture endpoint' });
});

server.on('connection', socket => {
  transportSockets.add(socket);
  socket.on('error', () => socket.destroy());
  socket.once('close', () => transportSockets.delete(socket));
});
server.on('upgrade', (request, socket) => {
  const id = records.length + 1;
  const record = { id, mode, upgraded: false, closed: false, bytes: 0, events: [] };
  records = [...records, record];
  const update = change => { records = records.map(item => item.id === id ? { ...item, ...change } : item); };
  sockets.set(id, socket);
  socket.on('error', () => socket.destroy());
  socket.once('close', () => { update({ closed: true }); sockets.delete(id); });
  if (mode === 'stall-handshake') { socket.pause(); return; }
  const clientKey = request.headers['sec-websocket-key'];
  if (typeof clientKey !== 'string') { socket.destroy(); return; }
  const accept = createHash('sha1').update(clientKey + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  const state = Buffer.from('{"event_type":"state","event":{}}');
  socket.write(Buffer.concat([Buffer.from([0x81, state.length]), state]));
  update({ upgraded: true });
  let pending = Buffer.alloc(0);
  socket.on('data', chunk => {
    const previous = records.find(item => item.id === id);
    update({ bytes: previous.bytes + chunk.length });
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 2) {
      const opcode = pending[0] & 15;
      let length = pending[1] & 127;
      let offset = 2;
      if (length === 126) { if (pending.length < 4) return; length = pending.readUInt16BE(2); offset = 4; }
      if (length === 127) { if (pending.length < 10) return; length = Number(pending.readBigUInt64BE(2)); offset = 10; }
      if (length > 64 * 1024) { socket.destroy(); return; }
      const masked = (pending[1] & 128) !== 0;
      const payloadStart = offset + (masked ? 4 : 0);
      if (pending.length < payloadStart + length) return;
      const payload = Buffer.from(pending.subarray(payloadStart, payloadStart + length));
      if (masked) for (let index = 0; index < payload.length; index++) payload[index] ^= pending[offset + (index % 4)];
      pending = pending.subarray(payloadStart + length);
      if (opcode === 8) { socket.end(Buffer.from([0x88, 0])); return; }
      if (opcode === 1) {
        try {
          const type = JSON.parse(payload.toString('utf8')).event_type;
          const current = records.find(item => item.id === id);
          update({ events: [...current.events, String(type)] });
        } catch { socket.destroy(); return; }
      }
    }
  });
});

let closing = false;
async function finish() {
  if (closing) return;
  closing = true;
  for (const socket of sockets.values()) socket.destroy();
  for (const socket of transportSockets) socket.destroy();
  await new Promise(resolve => server.close(resolve));
  rmSync(directory, { recursive: true, force: true });
}
process.once('SIGTERM', () => { void finish(); });
process.once('SIGINT', () => { void finish(); });
setTimeout(() => { void finish(); }, 60_000).unref();
try {
  if (!process.argv[2]) throw new Error('Port file required');
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  writeFileSync(process.argv[2], String(server.address().port), { mode: 0o600 });
} catch (error) {
  await finish();
  throw error;
}
