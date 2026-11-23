// W2: the home-network relay for Project Gladius in the browser. Node built-ins plus the MIT `ws` package.
//
//   node tools/lan/gladius_lan.mjs [buildDir=build/web] [--bind <ip>=0.0.0.0] [--port N] [--host-port N] [--cert-dir <dir>]
//
// Serves the web build over HTTPS (self-signed) on <bind>:<port> for other PCs, and over plain HTTP on 127.0.0.1:<host_port>
// for this PC. WebSocket path /signal carries WebRTC signaling only (docs: relay protocol v1). It makes no outbound connection.
// `ws` lives outside the repo: folder from env GLADIUS_WEBTOOLS, default C:\Users\shibi\cc_gladius\webtools.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { MIME, resolveInside } from '../web/serve.mjs';
import { buildLanJson } from './lan_protocol.mjs';
import { Room } from './room.mjs';
import { makeSelfSigned } from './self_signed.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const DEFAULT_WEBTOOLS = 'C:\\Users\\shibi\\cc_gladius\\webtools';

function loadWs() {
  const dir = process.env.GLADIUS_WEBTOOLS || DEFAULT_WEBTOOLS;
  try {
    return createRequire(path.join(path.resolve(dir), 'noop.js'))('ws');
  } catch (e) {
    const err = new Error(`the "ws" package could not be loaded from ${dir} (${e.code || e.message}). Set GLADIUS_WEBTOOLS to the folder that has node_modules/ws.`);
    err.exitCode = 2;
    throw err;
  }
}

export function lanIPv4s() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      const fam = typeof a.family === 'string' ? a.family === 'IPv4' : a.family === 4;
      if (fam && !a.internal && !a.address.startsWith('169.254.')) out.push(a.address);
    }
  }
  return [...new Set(out)];
}

function readJson(rel) {
  try { return JSON.parse(fs.readFileSync(path.join(REPO, rel), 'utf8')); } catch { return {}; }
}

export function relayDefaults() {
  const lan = readJson('data/net.json').lan_relay || {};
  const match = readJson('data/match.json');
  return {
    port: lan.port ?? 47443,
    hostPort: lan.host_port ?? 47480,
    maxMessageBytes: lan.max_message_bytes ?? 16384,
    maxPeers: Number.isInteger(match.max_humans) ? match.max_humans : (lan.max_peers ?? 8),
    heartbeatMs: lan.heartbeat_ms ?? 20000,
    socketsPerPeer: lan.sockets_per_peer ?? 4,
    certDays: lan.cert_days ?? 825,
    certRenewDays: lan.cert_renew_days ?? 7,
  };
}

// Reuses key.pem + cert.pem in certDir while the certificate is valid for renewDays more days and covers every wanted
// address (net.json lan_relay cert_days / cert_renew_days, OQ-W2-RELAY-LIMITS).
export function ensureCert(certDir, ips, { days = 825, renewDays = 7 } = {}) {
  const keyFile = path.join(certDir, 'key.pem');
  const certFile = path.join(certDir, 'cert.pem');
  try {
    const keyPem = fs.readFileSync(keyFile, 'utf8');
    const certPem = fs.readFileSync(certFile, 'utf8');
    const x = new crypto.X509Certificate(certPem);
    const ok = new Date(x.validTo).getTime() - Date.now() > renewDays * 24 * 3600 * 1000
      && new Date(x.validFrom).getTime() < Date.now()
      && x.checkHost('localhost') && ips.every((ip) => x.checkIP(ip))
      && x.checkPrivateKey(crypto.createPrivateKey(keyPem));
    if (ok) return { keyPem, certPem, reused: true };
  } catch { /* missing or unreadable: make a new one */ }
  const made = makeSelfSigned({ ips, dnsNames: ['localhost'], days });
  fs.mkdirSync(certDir, { recursive: true });
  fs.writeFileSync(keyFile, made.keyPem, { mode: 0o600 });
  fs.writeFileSync(certFile, made.certPem);
  return { ...made, reused: false };
}

// Starts the relay. Resolves to { close(), urls, hostUrl, port, hostPort, room, certPem }.
export async function startRelay(options = {}) {
  const { WebSocketServer } = loadWs();
  const d = relayDefaults();
  const buildDir = path.resolve(options.buildDir ?? path.join(REPO, 'build', 'web'));
  const bind = options.bind ?? '0.0.0.0';
  const maxMessageBytes = options.maxMessageBytes ?? d.maxMessageBytes;
  const maxPeers = options.maxPeers ?? d.maxPeers;
  const certDir = path.resolve(options.certDir ?? path.join(REPO, 'build', 'lan_cert'));
  const log = options.log ?? (() => {});

  const wildcard = bind === '0.0.0.0';
  const joinIps = options.lanIps ?? (wildcard ? lanIPv4s() : [bind]);
  const certIps = [...new Set([...joinIps, ...(wildcard ? lanIPv4s() : []), '127.0.0.1'])];
  const { keyPem, certPem } = ensureCert(certDir, certIps, { days: d.certDays, renewDays: d.certRenewDays });

  let urls = [];
  const room = new Room({
    maxPeers, maxMessageBytes,
    onChange: () => log(`relay: ${room.open.size} connected, ${room.size} in room, dropped ${room.counters.dropped}`),
  });

  const lanJson = () => buildLanJson(urls, maxPeers);

  function onRequest(req, res) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { Allow: 'GET, HEAD' });
      res.end();
      return;
    }
    const urlPath = (req.url || '/').split('?')[0].split('#')[0];
    if (urlPath === '/lan.json') {
      const body = lanJson();
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(body) });
      res.end(req.method === 'HEAD' ? undefined : body);
      return;
    }
    const file = resolveInside(buildDir, req.url || '/');
    if (file === null) {
      res.writeHead(403);
      res.end('forbidden');
      return;
    }
    fs.stat(file, (err, st) => {
      if (err || !st.isFile()) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('not found');
        return;
      }
      const type = MIME[path.extname(file).toLowerCase()] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': type, 'Content-Length': st.size, 'Cache-Control': 'no-store' });
      if (req.method === 'HEAD') {
        res.end();
        return;
      }
      const stream = fs.createReadStream(file);
      stream.on('error', () => res.destroy());
      stream.pipe(res);
    });
  }

  // maxPayload is above the message cap so an oversized message reaches Room, which replies too_large and counts it,
  // instead of ws closing the socket (review S2).
  const wss = new WebSocketServer({ noServer: true, maxPayload: maxMessageBytes * 4 });
  const refuseUpgrade = (socket, code, text) => {
    socket.write(`HTTP/1.1 ${code} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    socket.destroy();
  };
  function onUpgrade(req, socket, head) {
    socket.on('error', () => {});
    const urlPath = (req.url || '/').split('?')[0];
    if (urlPath !== '/signal') { refuseUpgrade(socket, 404, 'Not Found'); return; }
    let originHost = null;
    try { originHost = new URL(req.headers.origin || '').host.toLowerCase(); } catch { /* no usable Origin */ }
    const host = String(req.headers.host || '').toLowerCase();
    if (originHost === null || originHost !== host) { refuseUpgrade(socket, 403, 'Forbidden'); return; }
    if (wss.clients.size >= maxPeers * d.socketsPerPeer) { refuseUpgrade(socket, 503, 'Service Unavailable'); return; }
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.isAlive = true;
      const sock = {
        send: (text) => { if (ws.readyState === 1) ws.send(text); },
        close: () => {
          try { ws.close(1000); } catch { /* closing */ }
          setTimeout(() => ws.terminate(), 2000).unref();
        },
      };
      room.onOpen(sock);
      ws.on('pong', () => { ws.isAlive = true; });
      ws.on('message', (data, isBinary) => {
        if (isBinary) room.noteDropped(sock);
        else room.onMessage(sock, data.toString('utf8'));
      });
      ws.on('error', () => room.noteDropped(sock));
      ws.on('close', () => room.onClose(sock));
    });
  }

  const httpsServer = https.createServer({ key: keyPem, cert: certPem }, onRequest);
  const httpServer = http.createServer(onRequest);
  for (const s of [httpsServer, httpServer]) s.on('upgrade', onUpgrade);

  const listen = (server, port, addr) => new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, addr, () => { server.off('error', reject); resolve(server.address().port); });
  });
  let port;
  let hostPort;
  try {
    port = await listen(httpsServer, options.port ?? d.port, bind);
    hostPort = await listen(httpServer, options.hostPort ?? d.hostPort, '127.0.0.1');
  } catch (e) {
    httpsServer.close();
    httpServer.close();
    throw e;
  }
  const hostUrl = `http://127.0.0.1:${hostPort}/`;
  urls = (joinIps.length ? joinIps : ['127.0.0.1']).map((ip) => `https://${ip}:${port}/`);
  room.urls = urls;

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.isAlive === false) { ws.terminate(); continue; }
      ws.isAlive = false;
      try { ws.ping(); } catch { /* closing */ }
    }
  }, d.heartbeatMs);
  heartbeat.unref();

  let closing = null;
  const close = () => {
    if (closing) return closing;
    clearInterval(heartbeat);
    room.shutdown();
    closing = new Promise((resolve) => {
      let pending = 2;
      const done = () => { if (--pending === 0) resolve(); };
      for (const ws of wss.clients) ws.terminate();
      wss.close();
      for (const s of [httpsServer, httpServer]) {
        s.close(done);
        s.closeAllConnections?.();
      }
    });
    return closing;
  };

  return { close, urls, hostUrl, port, hostPort, room, certPem };
}

// ---- command line
function parseArgs(argv) {
  const o = { buildDir: 'build/web' };
  const num = (v, name) => {
    const n = Number(v);
    if (!Number.isInteger(n) || n < 0 || n > 65535) throw new Error(`${name} must be a port number 0-65535`);
    return n;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      return argv[++i];
    };
    if (a === '--bind') o.bind = val();
    else if (a === '--port') o.port = num(val(), '--port');
    else if (a === '--host-port') o.hostPort = num(val(), '--host-port');
    else if (a === '--cert-dir') o.certDir = val();
    else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
    else o.buildDir = a;
  }
  return o;
}

async function main() {
  let opts;
  try { opts = parseArgs(process.argv.slice(2)); } catch (e) {
    console.error(`gladius_lan: ${e.message}`);
    process.exit(2);
  }
  if (!fs.existsSync(path.join(opts.buildDir, 'index.html'))) {
    console.error(`gladius_lan: ${path.join(opts.buildDir, 'index.html')} not found (export the Web preset first, docs/WEB.md)`);
    process.exit(2);
  }
  let relay;
  try {
    relay = await startRelay({ ...opts, log: (m) => console.log(m) });
  } catch (e) {
    console.error(`gladius_lan: ${e.message}`);
    process.exit(e.exitCode || 1);
  }
  console.log('Gladius LAN relay is running.');
  console.log(`Host (this PC): ${relay.hostUrl}`);
  console.log('Other PCs on your home network:');
  for (const u of relay.urls) console.log(`  ${u}`);
  console.log('Other PCs see a certificate warning once. On that page choose Advanced -> Continue.');
  console.log('If Windows asks about the firewall, allow Node on Private networks.');
  console.log('Press Ctrl+C to stop.');
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    const c = relay.room.counters;
    console.log(`Stopping. connections ${c.connections}, disconnections ${c.disconnections}, dropped ${c.dropped}, forwarded ${c.forwarded}.`);
    relay.close().then(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

const isMain = process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) main();
