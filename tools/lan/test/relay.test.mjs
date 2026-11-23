import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createRequire } from 'node:module';
import { startRelay } from '../gladius_lan.mjs';

const webtools = process.env.GLADIUS_WEBTOOLS || 'C:\\Users\\shibi\\cc_gladius\\webtools';
const { WebSocket } = createRequire(path.join(path.resolve(webtools), 'noop.js'))('ws');

let tmp;
let relay;

before(async () => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gladius_lan_test_'));
  fs.mkdirSync(path.join(tmp, 'web'));
  fs.writeFileSync(path.join(tmp, 'web', 'index.html'), '<html>tiny</html>');
  fs.writeFileSync(path.join(tmp, 'secret.txt'), 'outside');
  relay = await startRelay({ buildDir: path.join(tmp, 'web'), bind: '127.0.0.1', port: 0, hostPort: 0, certDir: path.join(tmp, 'cert') });
});

after(async () => {
  if (relay) await relay.close();
  fs.rmSync(tmp, { recursive: true, force: true });
});

function request(method, urlPath, port = relay.hostPort) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: urlPath, method, agent: false }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

// A ws client with a message queue.
function client(url, opts) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, opts);
    const queue = [];
    const waiters = [];
    ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      const w = waiters.shift();
      if (w) w(m); else queue.push(m);
    });
    const c = {
      ws,
      send: (o) => ws.send(JSON.stringify(o)),
      next: () => new Promise((res, rej) => {
        if (queue.length) { res(queue.shift()); return; }
        const t = setTimeout(() => rej(new Error('timeout waiting for a message')), 5000);
        waiters.push((m) => { clearTimeout(t); res(m); });
      }),
      closed: new Promise((r) => ws.on('close', (code) => r(code))),
    };
    ws.once('open', () => resolve(c));
    ws.once('error', reject);
  });
}

const hostOrigin = () => ({ origin: `http://127.0.0.1:${relay.hostPort}` });

test('GET / on the loopback listener returns the build; HEAD works; other files 404', async () => {
  const r = await request('GET', '/');
  assert.equal(r.status, 200);
  assert.equal(r.body, '<html>tiny</html>');
  assert.match(r.headers['content-type'], /text\/html/);
  const h = await request('HEAD', '/index.html');
  assert.equal(h.status, 200);
  assert.equal(h.body, '');
  assert.equal((await request('GET', '/missing.js')).status, 404);
});

test('/lan.json has the protocol shape', async () => {
  const r = await request('GET', '/lan.json');
  assert.equal(r.status, 200);
  assert.match(r.headers['content-type'], /^application\/json/);
  assert.equal(r.headers['cache-control'], 'no-store');
  const j = JSON.parse(r.body);
  assert.deepEqual(Object.keys(j).sort(), ['lan', 'max_peers', 'proto', 'urls']);
  assert.equal(j.lan, true);
  assert.equal(j.proto, 1);
  assert.equal(j.max_peers, 8);
  assert.deepEqual(j.urls, [`https://127.0.0.1:${relay.port}/`]);
  assert.deepEqual(relay.urls, j.urls);
});

test('POST is 405 and path traversal is refused', async () => {
  assert.equal((await request('POST', '/')).status, 405);
  assert.equal((await request('PUT', '/lan.json')).status, 405);
  const t = await request('GET', '/..%2Fsecret.txt');
  assert.ok(t.status === 403 || t.status === 404);
  assert.notEqual(t.body, 'outside');
  const t2 = await request('GET', '/%2e%2e/secret.txt');
  assert.notEqual(t2.body, 'outside');
  assert.equal((await request('GET', '/..%5Csecret.txt')).body === 'outside', false);
});

test('host and a guest exchange an offer over ws on the loopback listener', async () => {
  const url = `ws://127.0.0.1:${relay.hostPort}/signal`;
  const host = await client(url, hostOrigin());
  host.send({ type: 'host' });
  const hid = await host.next();
  assert.equal(hid.type, 'id');
  assert.equal(hid.id, 1);
  assert.deepEqual(hid.urls, relay.urls);

  const guest = await client(url, hostOrigin());
  guest.send({ type: 'join' });
  assert.equal((await guest.next()).id, 2);
  assert.deepEqual(await host.next(), { type: 'peer_joined', id: 2 });

  guest.send({ type: 'offer', to: 1, sdp: 'v=0 offer' });
  assert.deepEqual(await host.next(), { type: 'offer', from: 2, sdp: 'v=0 offer' });
  host.send({ type: 'answer', to: 2, sdp: 'v=0 answer' });
  assert.deepEqual(await guest.next(), { type: 'answer', from: 1, sdp: 'v=0 answer' });

  guest.send({ type: 'nonsense' });
  assert.deepEqual(await guest.next(), { type: 'error', code: 'bad_message' });

  guest.ws.close();
  assert.deepEqual(await host.next(), { type: 'peer_left', id: 2 });
  const g2 = await client(url, hostOrigin());
  g2.send({ type: 'join' });
  assert.equal((await g2.next()).id, 3);
  assert.equal((await host.next()).type, 'peer_joined');

  host.ws.close();
  assert.deepEqual(await g2.next(), { type: 'host_gone' });
  await g2.closed;
});

test('a message over the cap gets too_large and the socket stays open; only a huge frame closes it', async () => {
  const c = await client(`ws://127.0.0.1:${relay.hostPort}/signal`, hostOrigin());
  c.ws.send('x'.repeat(20000)); // over the 16 KB message cap, under the transport cap (4x)
  assert.deepEqual(await c.next(), { type: 'error', code: 'too_large' });
  c.send({ type: 'join' });
  assert.deepEqual(await c.next(), { type: 'error', code: 'no_host' });
  c.ws.send('x'.repeat(16384 * 4 + 1)); // over the transport cap
  assert.equal(await c.closed, 1009);
});

test('upgrade with a foreign or missing Origin is refused, other paths are 404', async () => {
  const refused = (url, opts) => new Promise((resolve) => {
    const ws = new WebSocket(url, opts);
    ws.once('unexpected-response', (req, res) => { res.resume(); resolve(res.statusCode); });
    ws.once('open', () => { ws.close(); resolve('open'); });
    ws.once('error', () => {});
  });
  const url = `ws://127.0.0.1:${relay.hostPort}/signal`;
  assert.equal(await refused(url, { origin: 'http://evil.example' }), 403);
  assert.equal(await refused(url, { origin: `http://127.0.0.1:${relay.hostPort + 1}` }), 403);
  assert.equal(await refused(url, {}), 403);
  assert.equal(await refused(`ws://127.0.0.1:${relay.hostPort}/other`, hostOrigin()), 404);
});

test('wss on the https listener works with the pinned certificate', async () => {
  const c = await client(`wss://127.0.0.1:${relay.port}/signal`, { ca: relay.certPem, origin: `https://127.0.0.1:${relay.port}` });
  c.send({ type: 'join' });
  assert.deepEqual(await c.next(), { type: 'error', code: 'no_host' });
  c.ws.close();
  await c.closed;
  const r = await new Promise((resolve, reject) => {
    import('node:https').then(({ default: https }) => {
      https.get({ host: '127.0.0.1', port: relay.port, path: '/lan.json', ca: relay.certPem, agent: false }, (res) => {
        let b = '';
        res.on('data', (d) => { b += d; });
        res.on('end', () => resolve(JSON.parse(b)));
      }).on('error', reject);
    });
  });
  assert.equal(r.lan, true);
});

test('close() stops both listeners', async () => {
  const dir = path.join(tmp, 'web');
  const r2 = await startRelay({ buildDir: dir, bind: '127.0.0.1', port: 0, hostPort: 0, certDir: path.join(tmp, 'cert') });
  assert.ok(r2.port > 0 && r2.hostPort > 0 && r2.port !== r2.hostPort);
  const c = await client(`ws://127.0.0.1:${r2.hostPort}/signal`, { origin: `http://127.0.0.1:${r2.hostPort}` });
  await r2.close();
  await c.closed;
  await assert.rejects(request('GET', '/', r2.hostPort));
});
