// Loopback-only GLKVM recording fixture. It never forwards HID or contacts a KVM.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer, request as httpsRequest } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { connect as tlsConnect } from 'node:tls';
import { once } from 'node:events';

const MAX_PAYLOAD = 256 * 1024;

function maskedFrame(opcode, payload, final = true) {
  const mask = Buffer.from([0x13, 0x57, 0x9b, 0xdf]);
  const header = payload.length < 126
    ? Buffer.from([(final ? 0x80 : 0) | opcode, 0x80 | payload.length])
    : payload.length < 65536
      ? Buffer.from([(final ? 0x80 : 0) | opcode, 0xfe, payload.length >> 8, payload.length & 255])
      : Buffer.from([(final ? 0x80 : 0) | opcode, 0xff, 0, 0, 0, 0,
        payload.length >>> 24, payload.length >>> 16 & 255, payload.length >>> 8 & 255, payload.length & 255]);
  return Buffer.concat([header, mask, payload.map((byte, index) => byte ^ mask[index % 4])]);
}

function decodeClientFrame(buffer) {
  assert.ok(Buffer.isBuffer(buffer), 'frame input must be a Buffer');
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 15;
  const final = (buffer[0] & 0x80) !== 0;
  if ((buffer[0] & 0x70) !== 0 || ![0, 1, 2, 8, 9, 10].includes(opcode)) {
    throw new Error('Invalid WebSocket opcode or reserved bits');
  }
  if ((buffer[1] & 0x80) === 0) throw new Error('Client frame must be masked');
  let length = buffer[1] & 127;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
    if (length < 126) throw new Error('Non-minimal WebSocket length');
  } else if (length === 127) {
    if (buffer.length < 10) return null;
    const extended = buffer.readBigUInt64BE(2);
    if (extended > BigInt(MAX_PAYLOAD)) throw new Error('WebSocket payload too large');
    length = Number(extended);
    offset = 10;
    if (length < 65536) throw new Error('Non-minimal WebSocket length');
  }
  if (length > MAX_PAYLOAD) throw new Error('WebSocket payload too large');
  if (opcode >= 8 && (!final || length > 125)) throw new Error('Invalid control frame');
  if (buffer.length < offset + 4 + length) return null;
  const mask = buffer.subarray(offset, offset + 4);
  const payload = buffer.subarray(offset + 4, offset + 4 + length)
    .map((byte, index) => byte ^ mask[index % 4]);
  return { opcode, final, payload, consumed: offset + 4 + length };
}

function serverFrame(opcode, payload) {
  assert.ok(payload.length <= 125, 'fixture responses must fit a short frame');
  return Buffer.concat([Buffer.from([0x80 | opcode, payload.length]), payload]);
}

function binaryEvent(payload) {
  if (payload.length >= 2 && [1, 2].includes(payload[0]) && payload[1] <= 1) {
    return payload[0] === 1
      ? { type: 'key', key: payload.subarray(2).toString('utf8'), state: payload[1] === 1 }
      : { type: 'button', button: payload.subarray(2).toString('utf8'), state: payload[1] === 1 };
  }
  if (payload[0] === 3 && payload.length === 5) {
    return { type: 'move', x: payload.readInt16BE(1), y: payload.readInt16BE(3) };
  }
  if ([4, 5].includes(payload[0]) && payload.length === 4 && payload[1] <= 1) {
    return { type: payload[0] === 4 ? 'relative' : 'wheel', squash: payload[1] === 1,
      x: payload.readInt8(2), y: payload.readInt8(3) };
  }
  return { type: 'unknown' };
}

function receiveFrames(socket, record, firstBytes) {
  let buffer = Buffer.alloc(0);
  let fragmented = null;
  let closing = false;
  function deliver(opcode, payload) {
    record(opcode === 1 ? { type: 'json', json: JSON.parse(payload.toString('utf8')) }
      : binaryEvent(payload), payload);
    if (opcode === 1 && JSON.parse(payload.toString('utf8'))?.event_type === 'ping') {
      socket.write(serverFrame(1, Buffer.from('{"event_type":"pong","event":{}}')));
    }
  }
  function consume(chunk) {
    if (closing) return;
    try {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > 2 * MAX_PAYLOAD) throw new Error('Buffered input too large');
      let frame;
      while ((frame = decodeClientFrame(buffer))) {
        buffer = buffer.subarray(frame.consumed);
        if (frame.opcode === 8) {
          if (frame.payload.length === 1) throw new Error('Invalid close frame');
          closing = true;
          socket.removeListener('data', consume);
          socket.end(serverFrame(8, frame.payload));
          return;
        }
        if (frame.opcode === 9) { socket.write(serverFrame(10, frame.payload)); continue; }
        if (frame.opcode === 10) continue;
        if (frame.opcode === 0) {
          if (!fragmented) throw new Error('Unexpected continuation');
          fragmented = { opcode: fragmented.opcode, payload: Buffer.concat([fragmented.payload, frame.payload]) };
        } else {
          if (fragmented) throw new Error('Fragmented message interrupted');
          fragmented = { opcode: frame.opcode, payload: frame.payload };
        }
        if (fragmented.payload.length > MAX_PAYLOAD) throw new Error('Fragmented input too large');
        if (frame.final) { deliver(fragmented.opcode, fragmented.payload); fragmented = null; }
      }
    } catch (error) {
      closing = true;
      socket.removeListener('data', consume);
      process.stderr.write(`hid-capture-fixture: ${error.message}\n`);
      socket.end(serverFrame(8, Buffer.from([3, 234])));
    }
  }
  socket.on('data', consume);
  if (firstBytes.length > 0) consume(firstBytes);
}

function credentials(directory) {
  const keyFile = join(directory, 'key.pem');
  const certFile = join(directory, 'cert.pem');
  execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', keyFile, '-out', certFile, '-days', '1', '-subj', '/CN=localhost'],
  { stdio: 'ignore', timeout: 5_000 });
  chmodSync(keyFile, 0o600);
  return { key: readFileSync(keyFile), cert: readFileSync(certFile) };
}

async function startFixture() {
  const directory = mkdtempSync(join(tmpdir(), 'overlook-hid-fixture-'));
  chmodSync(directory, 0o700);
  let events = [];
  let connections = new Set();
  let webSockets = new Set();
  let waiters = new Set();
  let shutdown;
  let timer;
  const respond = (response, status, value) => response.writeHead(status,
    { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify(value));
  let server;
  try {
    server = createServer(credentials(directory), (request, response) => {
      let url;
      try { url = new URL(request.url, 'https://127.0.0.1'); }
      catch { respond(response, 400, { error: 'Invalid request target' }); return; }
      if (url.pathname === '/fixture/health' && request.method === 'GET') {
        respond(response, 200, { fixture: 'overlook-hid-capture-fixture', loopback: true });
      } else if (url.pathname === '/fixture/events' && request.method === 'GET') {
        if (url.searchParams.get('wait_closed') === '1' && webSockets.size > 0) {
          const waiter = () => respond(response, 200, events);
          waiters = new Set([...waiters, waiter]);
          const expiry = setTimeout(() => respond(response, 504, { error: 'WebSockets still open after 5 seconds' }), 5_000);
          response.once('close', () => {
            clearTimeout(expiry);
            waiters = new Set([...waiters].filter(item => item !== waiter));
          });
        } else respond(response, 200, events);
      } else if (url.pathname === '/fixture/reset') {
        if (request.method !== 'POST') respond(response, 405, { error: 'POST required' });
        else { events = []; respond(response, 200, { ok: true }); }
      } else if (url.pathname === '/api/system/get_config' && request.method === 'GET') {
        respond(response, 200, { ok: true, result: { config: { is_absolute_mouse: true } } });
      } else respond(response, 404, { error: 'Unknown fixture endpoint' });
    });
    server.on('connection', socket => {
      connections = new Set([...connections, socket]);
      socket.on('error', () => socket.destroy());
      socket.once('close', () => { connections = new Set([...connections].filter(item => item !== socket)); });
    });
    server.on('upgrade', (request, socket, head) => {
      const key = request.headers['sec-websocket-key'];
      let path;
      try { path = new URL(request.url, 'https://127.0.0.1').pathname; }
      catch { socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); return; }
      if (!['/api/ws', '/ws'].includes(path) || typeof key !== 'string'
        || !/^[A-Za-z0-9+/]{22}==$/.test(key) || request.headers['sec-websocket-version'] !== '13') {
        socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
        return;
      }
      webSockets = new Set([...webSockets, socket]);
      socket.on('error', () => socket.destroy());
      socket.once('close', () => {
        webSockets = new Set([...webSockets].filter(item => item !== socket));
        if (webSockets.size === 0) for (const waiter of waiters) waiter();
      });
      const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
      socket.write(serverFrame(1, Buffer.from('{"event_type":"state","event":{}}')));
      receiveFrames(socket, (event, payload) => {
        if (events.length >= 20_000) throw new Error('Fixture event limit reached');
        events = [...events, { seq: events.length + 1, ...event, raw: payload.toString('hex') }];
      }, head);
    });
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
  } catch (error) {
    server?.close();
    rmSync(directory, { recursive: true, force: true });
    throw error;
  }
  function finish() {
    if (shutdown) return shutdown;
    clearTimeout(timer);
    shutdown = new Promise(resolve => {
      for (const connection of connections) connection.destroy();
      server.close(() => { rmSync(directory, { recursive: true, force: true }); resolve(); });
    });
    return shutdown;
  }
  timer = setTimeout(() => { void finish(); }, 60_000).unref();
  return { port: server.address().port, finish, pendingWaiterCount: () => waiters.size };
}

function requestJSON(port, path, method = 'GET') {
  return new Promise((resolve, reject) => {
    const request = httpsRequest({ host: '127.0.0.1', port, path, method,
      rejectUnauthorized: false, agent: false }, response => {
      let body = Buffer.alloc(0);
      response.on('data', chunk => { body = Buffer.concat([body, chunk]); });
      response.on('end', () => {
        try { resolve({ status: response.statusCode, value: JSON.parse(body.toString()) }); }
        catch (error) { reject(error); }
      });
      response.on('error', reject);
    });
    request.on('error', reject);
    request.setTimeout(2_000, () => request.destroy(new Error('HTTP test timeout')));
    request.end();
  });
}

async function until(predicate) {
  const deadline = Date.now() + 2_000;
  while (!(await predicate())) {
    if (Date.now() >= deadline) throw new Error('Fixture test timeout');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

async function openWebSocket(port, allowHalfOpen = false) {
  const socket = tlsConnect({ host: '127.0.0.1', port, rejectUnauthorized: false, allowHalfOpen });
  let received = Buffer.alloc(0);
  socket.on('data', chunk => { received = Buffer.concat([received, chunk]); });
  await once(socket, 'secureConnect');
  socket.write('GET /api/ws?stream=0 HTTP/1.1\r\nHost: localhost\r\n' +
    'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n' +
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n');
  await until(() => received.includes(Buffer.from('"event_type":"state"')));
  assert.ok(received.includes(Buffer.from('101 Switching Protocols')));
  return { socket, received: () => received };
}

async function malformedTargetResponse(port, upgrade) {
  const socket = tlsConnect({ host: '127.0.0.1', port, rejectUnauthorized: false });
  let received = '';
  socket.on('data', chunk => { received += chunk.toString(); });
  socket.setTimeout(2_000, () => socket.destroy(new Error('Malformed target test timeout')));
  await once(socket, 'secureConnect');
  const headers = upgrade
    ? 'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    : 'Connection: close\r\n';
  const closed = once(socket, 'close');
  socket.write('GET http://[ HTTP/1.1\r\nHost: localhost\r\n' + headers + '\r\n');
  await closed;
  return received;
}

async function testServer() {
  const fixture = await startFixture();
  try {
    assert.deepEqual(await requestJSON(fixture.port, '/fixture/health'), {
      status: 200, value: { fixture: 'overlook-hid-capture-fixture', loopback: true },
    });
    assert.deepEqual(await requestJSON(fixture.port, '/api/system/get_config'), {
      status: 200, value: { ok: true, result: { config: { is_absolute_mouse: true } } },
    });
    assert.deepEqual((await requestJSON(fixture.port, '/fixture/events')).value, []);
    const client = await openWebSocket(fixture.port);
    const payloads = [Buffer.from([1, 1, ...Buffer.from('KeyA')]), Buffer.from([1, 0]),
      Buffer.from([2, 0, ...Buffer.from('left')]), Buffer.from([3, 0x80, 0, 0x7f, 0xff]),
      Buffer.from([4, 1, 0x80, 127]), Buffer.from([5, 0, 1, 0xff])];
    client.socket.write(Buffer.concat(payloads.map(payload => maskedFrame(2, payload))));
    await until(async () => (await requestJSON(fixture.port, '/fixture/events')).value.length === 6);
    const recorded = (await requestJSON(fixture.port, '/fixture/events')).value;
    assert.deepEqual(recorded, [
      { seq: 1, type: 'key', key: 'KeyA', state: true, raw: '01014b657941' },
      { seq: 2, type: 'key', key: '', state: false, raw: '0100' },
      { seq: 3, type: 'button', button: 'left', state: false, raw: '02006c656674' },
      { seq: 4, type: 'move', x: -32768, y: 32767, raw: '0380007fff' },
      { seq: 5, type: 'relative', squash: true, x: -128, y: 127, raw: '0401807f' },
      { seq: 6, type: 'wheel', squash: false, x: 1, y: -1, raw: '050001ff' },
    ]);
    const json = { event_type: 'ping', event: { text: 'ä😀; DROP TABLE' } };
    const encoded = Buffer.from(JSON.stringify(json));
    client.socket.write(maskedFrame(1, encoded.subarray(0, 10), false));
    client.socket.write(maskedFrame(9, Buffer.from('probe')));
    client.socket.write(maskedFrame(0, encoded.subarray(10)));
    await until(() => client.received().includes(Buffer.from('"event_type":"pong"')));
    assert.ok(client.received().includes(Buffer.from([0x8a, 5, ...Buffer.from('probe')])));
    assert.deepEqual((await requestJSON(fixture.port, '/fixture/events')).value.at(-1),
      { seq: 7, type: 'json', json, raw: encoded.toString('hex') });
    assert.equal((await requestJSON(fixture.port, '/fixture/reset')).status, 405);
    assert.deepEqual(await requestJSON(fixture.port, '/fixture/reset', 'POST'), { status: 200, value: { ok: true } });
    assert.deepEqual((await requestJSON(fixture.port, '/fixture/events')).value, []);
    const waiting = requestJSON(fixture.port, '/fixture/events?wait_closed=1');
    await until(() => fixture.pendingWaiterCount() === 1);
    client.socket.write(maskedFrame(8, Buffer.from([3, 232])));
    await once(client.socket, 'close');
    assert.deepEqual(await waiting, { status: 200, value: [] });
    for (const upgrade of [false, true]) {
      assert.match(await malformedTargetResponse(fixture.port, upgrade), /HTTP\/1.1 400 Bad Request/);
      assert.equal((await requestJSON(fixture.port, '/fixture/health')).status, 200,
        'invalid request target must not terminate the fixture');
    }
    await requestJSON(fixture.port, '/fixture/reset', 'POST');
    const halfOpen = await openWebSocket(fixture.port, true);
    const serverEnded = once(halfOpen.socket, 'end');
    halfOpen.socket.write(maskedFrame(8, Buffer.from([3, 232])));
    await serverEnded;
    // Wait for the server's FIN, then transmit a key before the client's own FIN.
    const fullyClosed = once(halfOpen.socket, 'close');
    halfOpen.socket.end(maskedFrame(2, Buffer.from([1, 1, ...Buffer.from('KeyAfterClose')])));
    await fullyClosed;
    assert.deepEqual((await requestJSON(fixture.port, '/fixture/events?wait_closed=1')).value, [],
      'HID after a WebSocket close must never be recorded');
  } finally {
    await fixture.finish();
  }
}

async function selfTest() {
  const payload = Buffer.from([1, 1, ...Buffer.from('KeyA')]);
  const original = maskedFrame(2, payload);
  const preserved = Buffer.from(original);
  assert.deepEqual(decodeClientFrame(original), {
    opcode: 2, final: true, payload, consumed: original.length,
  });
  assert.deepEqual(original, preserved, 'decoder must preserve input');
  for (let length = 0; length < original.length; length += 1) {
    assert.equal(decodeClientFrame(original.subarray(0, length)), null, `partial frame ${length}`);
  }
  for (const length of [0, 125, 126, 65535, 65536, MAX_PAYLOAD]) {
    const large = maskedFrame(2, Buffer.alloc(length, 42));
    assert.equal(decodeClientFrame(large).payload.length, length);
    assert.equal(decodeClientFrame(large.subarray(0, large.length - 1)), null);
  }
  for (const input of [null, undefined, '', [], 0]) assert.throws(() => decodeClientFrame(input));
  assert.throws(() => decodeClientFrame(Buffer.from([0x82, 0])), /masked/);
  assert.throws(() => decodeClientFrame(Buffer.from([0xf2, 0x80])), /opcode/);
  assert.throws(() => decodeClientFrame(maskedFrame(9, Buffer.alloc(126))), /control/);
  assert.throws(() => decodeClientFrame(maskedFrame(2, Buffer.alloc(MAX_PAYLOAD + 1))), /large/);
  for (let index = 0; index < 10_001; index += 1) {
    assert.deepEqual(decodeClientFrame(original).payload, payload);
  }
  await testServer();
  process.stdout.write('hid-capture-fixture: self-test passed\n');
}

if (process.argv[2] === '--self-test' || (!process.argv[2] && process.env.NODE_TEST_CONTEXT)) {
  await selfTest();
} else {
  const portFile = process.argv[2];
  if (!portFile) throw new Error('Port file required');
  const fixture = await startFixture();
  process.once('SIGTERM', () => { void fixture.finish(); });
  process.once('SIGINT', () => { void fixture.finish(); });
  try {
    writeFileSync(portFile, String(fixture.port), { mode: 0o600 });
    chmodSync(portFile, 0o600);
  } catch (error) {
    await fixture.finish();
    throw error;
  }
}
