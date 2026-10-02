// Local WebSocket handshake fixture. It never forwards HID or contacts a KVM.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const portFile = process.argv[2];
if (!portFile) throw new Error('Port file required');
const connections = new Set();
const server = createServer((_request, response) => response.writeHead(404).end());
server.on('upgrade', (request, socket) => {
  connections.add(socket);
  socket.on('error', () => socket.destroy());
  socket.on('close', () => connections.delete(socket));
  const key = request.headers['sec-websocket-key'];
  if (typeof key !== 'string') { socket.destroy(); return; }
  const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  if (request.url === '/events') {
    const payload = Buffer.from('{"event_type":"state","event":{}}');
    socket.write(Buffer.concat([Buffer.from([0x81, payload.length]), payload]));
  }
  socket.on('data', () => {});
});
server.listen(0, '127.0.0.1', () => {
  writeFileSync(portFile, String(server.address().port), { mode: 0o600 });
});
function finish() {
  for (const connection of connections) connection.destroy();
  server.close();
}
process.on('SIGTERM', finish);
setTimeout(finish, 15_000).unref();
