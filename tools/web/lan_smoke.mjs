// W2: the two-browser LAN proof (docs/WEB.md). Starts the LAN relay in-process (tools/lan/gladius_lan.mjs startRelay) on
// the web build, bound to this PC's LAN IPv4, and opens TWO headed Chrome instances with separate temporary profiles:
//   HOST  at the relay's loopback http URL   http://127.0.0.1:<hostPort>/?autohost=1&mode=squads
//   GUEST at the relay's LAN https URL       https://<LAN IPv4>:<port>/?autojoin=1   (NOT 127.0.0.1)
// The guest gets past the self-signed certificate the way a harness can (puppeteer acceptInsecureCerts; a human sees a
// warning page once instead). The debug-only URL arguments (scripts/platform/web_args.gd parse_lan) make the host press
// Host and Start once the guest is in, and the guest press Join. Both play `seconds` of scripted keyboard and mouse
// input after the match starts; then the HOST Chrome is closed and the time until the guest prints
// GLADIUS_LAN_HOST_LOST is measured. Markers come from scripts/net/net_debug_ping.gd (debug web builds only).
//
//   node tools/web/lan_smoke.mjs [--build build/web] [--out build/lan_smoke] [--seconds 60] [--bind <LAN IPv4>]
//                                [--port N] [--host-port N] [--cert-flag] [--webtools <dir>] [--chrome <exe>]
//
// Exit code: 0 only when both pages reached GLADIUS_MATCH_STARTED, the guest counted snapshots > 0, neither page logged
// an RPC error and no uncaught page error happened. 1 = those checks failed, 2 = bad arguments / missing build / no LAN
// IPv4, 3 = the overall hard timeout fired. Chrome, the relay and the temp profiles are always cleaned up.
// Numbers are "this PC, Chrome <version>, not a performance or LAN claim": both browsers run on the same PC.
import fs from 'node:fs';
import path from 'node:path';
import { lanIPv4s, relayDefaults, startRelay } from '../lan/gladius_lan.mjs';
import { DEFAULT_CHROME, DEFAULT_WEBTOOLS, frameStats, loadPuppeteer, makeProfileDir, removeProfile, sleep } from './chrome.mjs';

const DEFAULTS = { build: 'build/web', out: 'build/lan_smoke', seconds: 60, webtools: DEFAULT_WEBTOOLS, chrome: DEFAULT_CHROME };
const VIEWPORT = { width: 960, height: 540 };
const BOOT_TIMEOUT_MS = 240000;       // wasm download + compile + the menu
const CONNECT_TIMEOUT_MS = 180000;    // relay detection, Host, the guest's Join retries, the WebRTC handshake
const MATCH_TIMEOUT_MS = 300000;      // lobby Start -> both pawns spawned
const HOST_LOST_TIMEOUT_MS = 30000;   // host closed -> guest's GLADIUS_LAN_HOST_LOST
const HARD_TIMEOUT_MS = 20 * 60 * 1000;
const FREEZE_MS = 2000;               // a requestAnimationFrame gap this long is recorded as a freeze

// SceneMultiplayer / SceneRPCInterface / SceneCacheInterface complaints (Godot 4.7 wording) that mean an RPC did not
// arrive or did not match: counted as RPC errors on either page.
export const RPC_ERROR_RE = new RegExp([
  'Invalid packet received',
  'Requested node was not found',
  'RPC \'[^\']*\' is not allowed',
  'Unable to get the RPC configuration',
  'Attempt to call RPC',
  'Invalid RPC',
  'RPC .*not found',
  'path cache',
  'checksum',
  'scene_rpc_interface',
  'scene_cache_interface',
  'scene_multiplayer',
].join('|'), 'i');

// Two headed windows on one desktop: at most one holds OS focus, and Chrome refuses pointer lock to the other with a
// WrongDocumentError. Godot's web JS calls canvas.requestPointerLock() without handling the returned promise (engine
// code, index.js lockPointer), so every refused click surfaces as an unhandled rejection. This one message is counted
// apart (summary.pointerLockRefusals) and does not fail the run; any other page error does. One player per PC with a
// focused window does not hit it [inferred].
const POINTER_LOCK_REFUSAL_RE = /WrongDocumentError: The root document of this element is not valid for pointer lock/;

function parseArgs(argv) {
  const out = { ...DEFAULTS, bind: null, port: null, hostPort: null, certFlag: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === '--build') out.build = next();
    else if (a === '--out') out.out = next();
    else if (a === '--seconds') out.seconds = Number(next());
    else if (a === '--bind') out.bind = next();
    else if (a === '--port') out.port = Number(next());
    else if (a === '--host-port') out.hostPort = Number(next());
    else if (a === '--cert-flag') out.certFlag = true;
    else if (a === '--webtools') out.webtools = next();
    else if (a === '--chrome') out.chrome = next();
    else throw new Error(`unknown argument ${a}`);
  }
  if (!Number.isFinite(out.seconds) || out.seconds < 10) throw new Error('--seconds must be a number >= 10');
  for (const k of ['port', 'hostPort']) {
    if (out[k] !== null && !(Number.isInteger(out[k]) && out[k] >= 0 && out[k] < 65536)) throw new Error(`bad --${k}`);
  }
  return out;
}

// Starts the relay on the data/net.json ports; if one is busy (and no override was given) falls back to free ports.
async function startRelayWithFallback(opts, log) {
  const d = relayDefaults();
  const port = opts.port ?? d.port;
  const hostPort = opts.hostPort ?? d.hostPort;
  try {
    return { relay: await startRelay({ ...opts.relayBase, port, hostPort }), portsFrom: 'data/net.json lan_relay (or overrides)' };
  } catch (e) {
    if (e?.code !== 'EADDRINUSE' || (opts.port !== null && opts.hostPort !== null)) throw e;
    log(`port busy (${e.message}); falling back to free ports`);
    return {
      relay: await startRelay({ ...opts.relayBase, port: opts.port ?? 0, hostPort: opts.hostPort ?? 0 }),
      portsFrom: 'fallback: a data/net.json port was busy',
    };
  }
}

// Headed Chrome with a temporary profile (chrome.mjs's flags), placed at `x` so the two windows sit side by side.
function launch(puppeteer, { chrome, profileDir, x, insecure, certFlag }) {
  const args = [
    `--window-size=${VIEWPORT.width + 20},${VIEWPORT.height + 140}`,
    `--window-position=${x},0`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-timer-throttling',
    '--disable-renderer-backgrounding',
    '--disable-backgrounding-occluded-windows',
  ];
  if (insecure && certFlag) args.push('--ignore-certificate-errors');
  return puppeteer.launch({
    executablePath: chrome,
    headless: false,
    userDataDir: profileDir,
    defaultViewport: VIEWPORT,
    protocolTimeout: 120000,
    acceptInsecureCerts: Boolean(insecure),
    args,
  });
}

// Runs in the page before any script: frame timestamps, and a wrapper that keeps Godot's RTCPeerConnections (the
// export calls `new RTCPeerConnection(config)` on the global) so the harness can read local candidates and getStats.
function pageProbe() {
  window.__lan = { frames: [], cands: [], pcs: [] };
  const tick = (ts) => { window.__lan.frames.push(ts); requestAnimationFrame(tick); };
  requestAnimationFrame(tick);
  const Orig = window.RTCPeerConnection;
  if (typeof Orig === 'function') {
    const Wrapped = function (...a) {
      const pc = new Orig(...a);
      window.__lan.pcs.push(pc);
      pc.addEventListener('icecandidate', (e) => { if (e.candidate) window.__lan.cands.push(e.candidate.candidate); });
      return pc;
    };
    Wrapped.prototype = Orig.prototype;
    Object.setPrototypeOf(Wrapped, Orig);
    window.RTCPeerConnection = Wrapped;
  }
}

// The selected ICE pair's local / remote candidate types and addresses (first connected pc), or null.
function selectedPair() {
  return (async () => {
    for (const pc of window.__lan?.pcs ?? []) {
      let stats;
      try { stats = await pc.getStats(); } catch { continue; }
      const byId = new Map();
      stats.forEach((s) => byId.set(s.id, s));
      for (const s of byId.values()) {
        if (s.type === 'candidate-pair' && (s.nominated || s.selected) && s.state === 'succeeded') {
          const l = byId.get(s.localCandidateId) || {};
          const r = byId.get(s.remoteCandidateId) || {};
          return {
            local: { type: l.candidateType, address: l.address ?? l.ip ?? null, protocol: l.protocol },
            remote: { type: r.candidateType, address: r.address ?? r.ip ?? null, protocol: r.protocol },
            currentRoundTripTimeMs: typeof s.currentRoundTripTime === 'number' ? Number((s.currentRoundTripTime * 1000).toFixed(2)) : null,
          };
        }
      }
    }
    return null;
  })();
}

function candidateKind(c) {
  const m = /\s(\S+)\s+\d+\s+typ\s+(\S+)/.exec(c || '');
  if (!m) return { raw: c };
  return { address: m[1].endsWith('.local') ? '<uuid>.local (mDNS)' : m[1], type: m[2] };
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    console.error('usage: node tools/web/lan_smoke.mjs [--build build/web] [--out build/lan_smoke] [--seconds 60] [--bind <ip>] [--port N] [--host-port N] [--cert-flag]');
    return 2;
  }
  const buildDir = path.resolve(args.build);
  if (!fs.existsSync(path.join(buildDir, 'index.html'))) {
    console.error(`no ${path.join(buildDir, 'index.html')}: export the Web preset first (docs/WEB.md)`);
    return 2;
  }
  const lanIp = args.bind ?? lanIPv4s()[0];
  if (!lanIp) {
    console.error('no non-internal IPv4 on this PC (pass --bind <ip>)');
    return 2;
  }
  const outDir = path.resolve(args.out);
  fs.mkdirSync(outDir, { recursive: true });
  const puppeteer = loadPuppeteer(args.webtools);

  const t0 = Date.now();
  const secs = (ms) => Number((ms / 1000).toFixed(2));
  const log = (m) => console.log(`[lan_smoke ${((Date.now() - t0) / 1000).toFixed(1)}s] ${m}`);
  const summary = {
    label: 'this PC, Chrome <version>, not a performance or LAN claim (both browsers on one PC)',
    startedAt: new Date().toISOString(),
    chromeVersion: null,
    lanIPv4: lanIp,
    lanIPv4Choice: args.bind ? '--bind' : 'the first non-internal IPv4 of this PC (os.networkInterfaces order)',
    allLanIPv4s: lanIPv4s(),
    relay: null,
    hostUrl: null,
    guestUrl: null,
    certificate: null,
    guestIsSecureContext: null,
    hostIsSecureContext: null,
    reached: { hostMenu: false, guestMenu: false, hostReady: false, guestConnected: false, hostMatch: false, guestMatch: false },
    seconds: {},
    guestSnapshots: null,
    hostSnapshots: null,
    ping: null,
    ice: null,
    rpcErrors: { host: [], guest: [] },
    godotErrors: { host: [], guest: [] },
    pageErrors: { host: [], guest: [] },
    pointerLockRefusals: { host: 0, guest: 0, note: 'unhandled requestPointerLock rejections (WrongDocumentError) in a window without OS focus; two windows on one desktop; not failing' },
    failedRequests: { host: [], guest: [] },
    freezes: { note: 'requestAnimationFrame gaps >= 2 s during play; W1a saw 2-12 s Chrome freezes (inferred shader compiles), not this slice\'s bug', host: [], guest: [] },
    fps: { host: null, guest: null },
    inputLog: { host: [], guest: [] },
    hostLost: null,
    screenshots: [],
    relayLog: [],
    relayCounters: null,
    firewall: 'no dialog can be clicked in this session; both browsers are on this PC',
    timedOut: false,
    failures: [],
    exitCode: null,
  };
  const lines = { host: [], guest: [] }; // { t, type, text }
  const profiles = { host: makeProfileDir('gladius-lan-host-'), guest: makeProfileDir('gladius-lan-guest-') };
  const browsers = { host: null, guest: null };
  let relay = null;
  let hardTimer = null;

  const cleanup = async () => {
    if (hardTimer) clearTimeout(hardTimer);
    for (const k of ['host', 'guest']) {
      const b = browsers[k];
      if (!b) continue;
      try { await Promise.race([b.close(), sleep(15000)]); } catch { /* closing anyway */ }
      try { b.process()?.kill('SIGKILL'); } catch { /* already gone */ }
      browsers[k] = null;
    }
    try { if (relay) await Promise.race([relay.close(), sleep(5000)]); } catch { /* closing anyway */ }
    for (const k of ['host', 'guest']) await removeProfile(profiles[k]);
  };

  const watch = (page, who) => {
    page.on('console', (msg) => {
      const text = msg.text();
      lines[who].push({ t: Date.now() - t0, type: msg.type(), text });
      for (const line of text.split('\n')) {
        if (RPC_ERROR_RE.test(line)) summary.rpcErrors[who].push(line.trim());
        if (/\b(SCRIPT )?ERROR:/.test(line)) summary.godotErrors[who].push(line.trim());
      }
    });
    page.on('pageerror', (err) => {
      const text = String(err?.stack || err?.message || err);
      if (POINTER_LOCK_REFUSAL_RE.test(text)) summary.pointerLockRefusals[who]++;
      else summary.pageErrors[who].push(text);
    });
    page.on('requestfailed', (req) => summary.failedRequests[who].push(`${req.url()} ${req.failure()?.errorText ?? ''}`.trim()));
  };
  const waitFor = async (who, needle, timeoutMs, from = 0) => {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      const hit = lines[who].slice(from).find((c) => c.text.includes(needle));
      if (hit) return hit;
      await sleep(100);
    }
    return null;
  };
  const lastLine = (who, prefix) => [...lines[who]].reverse().find((c) => c.text.startsWith(prefix))?.text ?? null;
  const shot = async (page, name) => {
    try {
      await page.screenshot({ path: path.join(outDir, name) });
      summary.screenshots.push(name);
      log(`screenshot ${name}`);
    } catch (e) {
      log(`screenshot ${name} failed: ${e.message}`);
    }
  };

  // Scripted play on one page for `ms` (move, look, fire, sprint, crouch), like smoke.mjs without the pause steps.
  const play = async (page, who, ms) => {
    const t1 = Date.now();
    const note = (what) => summary.inputLog[who].push({ t: secs(Date.now() - t1), what });
    const cx = VIEWPORT.width / 2;
    const cy = VIEWPORT.height / 2;
    const look = async (dx, dy, steps = 15) => { await page.mouse.move(cx, cy); await page.mouse.move(cx + dx, cy + dy, { steps }); };
    const fire = async (n) => {
      for (let i = 0; i < n; i++) { await page.mouse.down({ button: 'left' }); await sleep(90); await page.mouse.up({ button: 'left' }); await sleep(160); }
    };
    await page.mouse.click(cx, cy);
    note('click canvas (capture)');
    await sleep(600);
    note('pointer lock: ' + await page.evaluate(() => (document.pointerLockElement ? (document.pointerLockElement.id || document.pointerLockElement.tagName) : null)).catch(() => 'n/a'));
    let i = 0;
    while (Date.now() - t1 < ms - 1500) {
      const key = ['KeyW', 'KeyD', 'KeyW', 'KeyA', 'KeyS'][i % 5];
      note(`${key} + look + fire${i % 4 === 3 ? ' + sprint' : ''}`);
      if (i % 4 === 3) await page.keyboard.down('ShiftLeft');
      await page.keyboard.down(key);
      await look(i % 2 ? -220 : 220, i % 3 ? 30 : -30);
      await fire(2);
      await page.keyboard.up(key);
      if (i % 4 === 3) await page.keyboard.up('ShiftLeft');
      if (i % 6 === 5) { note('C crouch toggle'); await page.keyboard.press('KeyC'); }
      i++;
    }
    while (Date.now() - t1 < ms) await sleep(100);
  };

  const run = async () => {
    const relayLog = (m) => { if (summary.relayLog.length < 200) summary.relayLog.push(`${secs(Date.now() - t0)}s ${m}`); };
    const started = await startRelayWithFallback({ port: args.port, hostPort: args.hostPort,
      relayBase: { buildDir, bind: lanIp, log: relayLog } }, log);
    relay = started.relay;
    summary.relay = { bind: lanIp, port: relay.port, hostPort: relay.hostPort, urls: relay.urls, portsFrom: started.portsFrom };
    summary.hostUrl = `${relay.hostUrl}?autohost=1&mode=squads`;
    summary.guestUrl = `https://${lanIp}:${relay.port}/?autojoin=1`;
    summary.certificate = args.certFlag
      ? 'self-signed; guest Chrome launched with acceptInsecureCerts AND --ignore-certificate-errors'
      : 'self-signed; guest Chrome launched with puppeteer acceptInsecureCerts (a human sees a warning page once instead [inferred])';
    log(`relay on ${lanIp}: guests ${relay.urls.join(', ')}, host ${relay.hostUrl}`);

    // HOST
    browsers.host = await launch(puppeteer, { chrome: args.chrome, profileDir: profiles.host, x: 0, insecure: false });
    summary.chromeVersion = await browsers.host.version();
    summary.label = `this PC, ${summary.chromeVersion}, not a performance or LAN claim (both browsers on one PC)`;
    const host = (await browsers.host.pages())[0] ?? (await browsers.host.newPage());
    watch(host, 'host');
    await host.evaluateOnNewDocument(pageProbe);
    let navT = Date.now();
    await host.goto(summary.hostUrl, { waitUntil: 'load', timeout: BOOT_TIMEOUT_MS });
    summary.hostIsSecureContext = await host.evaluate(() => window.isSecureContext).catch(() => null);
    if (!(await waitFor('host', 'GLADIUS_MENU_READY', BOOT_TIMEOUT_MS))) { summary.failures.push('host menu never ready'); return; }
    summary.reached.hostMenu = true;
    summary.seconds.hostMenu = secs(Date.now() - navT);
    if (!(await waitFor('host', 'GLADIUS_LAN_HOST_READY', CONNECT_TIMEOUT_MS))) {
      summary.failures.push(`host never hosted (no GLADIUS_LAN_HOST_READY; last LAN line: ${lastLine('host', 'GLADIUS_LAN') ?? 'none'})`);
      return;
    }
    summary.reached.hostReady = true;
    await sleep(1000);
    await shot(host, 'host_lobby.png');

    // GUEST
    browsers.guest = await launch(puppeteer, { chrome: args.chrome, profileDir: profiles.guest, x: VIEWPORT.width + 30, insecure: true, certFlag: args.certFlag });
    const guest = (await browsers.guest.pages())[0] ?? (await browsers.guest.newPage());
    watch(guest, 'guest');
    await guest.evaluateOnNewDocument(pageProbe);
    navT = Date.now();
    await guest.goto(summary.guestUrl, { waitUntil: 'load', timeout: BOOT_TIMEOUT_MS });
    summary.guestIsSecureContext = await guest.evaluate(() => window.isSecureContext).catch((e) => `evaluate failed: ${e.message}`);
    log(`guest isSecureContext=${summary.guestIsSecureContext}`);
    if (!(await waitFor('guest', 'GLADIUS_MENU_READY', BOOT_TIMEOUT_MS))) {
      const notice = await guest.evaluate(() => document.querySelector('#status-notice')?.innerText ?? null).catch(() => null);
      summary.failures.push(`guest menu never ready${notice ? ` (page notice: ${notice})` : ''}`);
      await shot(guest, 'guest_failed.png');
      return;
    }
    summary.reached.guestMenu = true;
    summary.seconds.guestMenu = secs(Date.now() - navT);
    const conn = await waitFor('guest', 'GLADIUS_LAN_CONNECTED', CONNECT_TIMEOUT_MS);
    if (!conn) {
      summary.failures.push(`guest never connected (last LAN line: ${lastLine('guest', 'GLADIUS_LAN') ?? 'none'})`);
      await shot(guest, 'guest_failed.png');
      return;
    }
    summary.reached.guestConnected = true;
    summary.seconds.guestNavToConnected = secs(t0 + conn.t - navT);
    await sleep(800);
    await shot(guest, 'guest_lobby.png');

    const [hs, gs] = await Promise.all([waitFor('host', 'GLADIUS_MATCH_STARTED', MATCH_TIMEOUT_MS), waitFor('guest', 'GLADIUS_MATCH_STARTED', MATCH_TIMEOUT_MS)]);
    summary.reached.hostMatch = Boolean(hs);
    summary.reached.guestMatch = Boolean(gs);
    if (!hs || !gs) { summary.failures.push(`match did not start on ${!hs ? 'host' : ''}${!hs && !gs ? ' and ' : ''}${!gs ? 'guest' : ''}`); return; }
    summary.seconds.guestConnectedToMatchStart = secs(gs.t - conn.t);
    log('match started on both');

    // ICE: local candidates seen and the selected pair (cheap: from the wrapped RTCPeerConnection).
    const ice = {};
    for (const [who, page] of [['host', host], ['guest', guest]]) {
      const cands = await page.evaluate(() => window.__lan?.cands ?? []).catch(() => []);
      ice[who] = { localCandidates: cands.slice(0, 4).map(candidateKind), selectedPair: await page.evaluate(selectedPair).catch(() => null) };
    }
    summary.ice = ice;

    await guest.bringToFront().catch(() => {}); // the remote player's window gets the focus (pointer lock) if any does
    const playFrom = await Promise.all([host, guest].map((p) => p.evaluate(() => performance.now()).catch(() => 0)));
    await Promise.all([play(host, 'host', args.seconds * 1000), play(guest, 'guest', args.seconds * 1000)]);
    await shot(host, 'host_match.png');
    await shot(guest, 'guest_match.png');
    for (const [i, [who, page]] of [['host', host], ['guest', guest]].entries()) {
      const frames = await page.evaluate((from) => (window.__lan?.frames ?? []).filter((ts) => ts >= from), playFrom[i]).catch(() => []);
      summary.fps[who] = frameStats([frames]);
      for (let k = 1; k < frames.length; k++) {
        const dt = frames[k] - frames[k - 1];
        if (dt >= FREEZE_MS) summary.freezes[who].push({ atSecondsIntoPlay: secs(frames[k - 1] - playFrom[i]), seconds: secs(dt) });
      }
    }
    await sleep(5500); // one more GLADIUS_LAN_SNAPSHOTS / _PING report
    const snap = (who) => { const l = lastLine(who, 'GLADIUS_LAN_SNAPSHOTS'); return l ? Number(l.split(/\s+/)[1]) : null; };
    summary.guestSnapshots = snap('guest');
    summary.hostSnapshots = snap('host');
    const pl = lastLine('guest', 'GLADIUS_LAN_PING');
    const m = pl && /median_ms=([\d.]+) max_ms=([\d.]+) n=(\d+)(?: min_ms=([\d.]+))?/.exec(pl);
    summary.ping = m ? {
      medianMs: Number(m[1]), maxMs: Number(m[2]), minMs: m[4] !== undefined ? Number(m[4]) : null, samples: Number(m[3]),
      source: 'guest -> host unreliable RPC round trip at the game level (NetDebugPing): includes both pages\' frame times and freezes, not only the network',
    } : null;

    // Close the HOST Chrome; time until the guest notices.
    const from = lines.guest.length;
    const closeT = Date.now();
    log('closing the host Chrome');
    try { await Promise.race([browsers.host.close(), sleep(15000)]); } catch { /* closing anyway */ }
    try { browsers.host.process()?.kill('SIGKILL'); } catch { /* gone */ }
    browsers.host = null;
    const lost = await waitFor('guest', 'GLADIUS_LAN_HOST_LOST', HOST_LOST_TIMEOUT_MS, from);
    summary.hostLost = lost
      ? { detected: true, seconds: secs(t0 + lost.t - closeT), line: lost.text }
      : { detected: false, seconds: null, note: `no GLADIUS_LAN_HOST_LOST within ${HOST_LOST_TIMEOUT_MS / 1000} s` };
    const menu = await waitFor('guest', 'GLADIUS_MENU_READY', 15000, from);
    summary.hostLost.guestBackAtMenu = Boolean(menu);
    await sleep(1500);
    await shot(guest, 'guest_after_host_left.png');
  };

  const hardTimeout = new Promise((resolve) => { hardTimer = setTimeout(() => resolve('timeout'), HARD_TIMEOUT_MS); });
  try {
    const result = await Promise.race([run().then(() => 'done'), hardTimeout]);
    if (result === 'timeout') { summary.timedOut = true; summary.failures.push(`hard timeout ${HARD_TIMEOUT_MS / 1000} s`); }
  } catch (e) {
    summary.failures.push(`exception: ${e?.stack || e}`);
  }
  summary.relayCounters = relay ? { ...relay.room.counters } : null;
  if (!summary.reached.hostMatch || !summary.reached.guestMatch) summary.failures.push('both pages must reach GLADIUS_MATCH_STARTED');
  if (!(summary.guestSnapshots > 0)) summary.failures.push(`guest snapshots must be > 0 (got ${summary.guestSnapshots})`);
  const rpc = summary.rpcErrors.host.length + summary.rpcErrors.guest.length;
  if (rpc) summary.failures.push(`${rpc} RPC error line(s)`);
  const pe = summary.pageErrors.host.length + summary.pageErrors.guest.length;
  if (pe) summary.failures.push(`${pe} uncaught page error(s)`);
  summary.failures = [...new Set(summary.failures)];
  summary.exitCode = summary.timedOut ? 3 : (summary.failures.length === 0 ? 0 : 1);
  for (const who of ['host', 'guest']) {
    fs.writeFileSync(path.join(outDir, `${who}_console.log`),
      lines[who].map((c) => `${(c.t / 1000).toFixed(1)}s [${c.type}] ${c.text}`).join('\n') + '\n');
  }
  fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 2));
  await cleanup();
  // stdout: the summary without the long input logs (summary.json has everything).
  const { inputLog, relayLog, ...brief } = summary;
  console.log(JSON.stringify({ ...brief, inputLogSteps: { host: inputLog.host.length, guest: inputLog.guest.length } }, null, 2));
  log(`exit ${summary.exitCode}${summary.failures.length ? ': ' + summary.failures.join('; ') : ''}`);
  return summary.exitCode;
}

main().then((code) => process.exit(code), (e) => { console.error(e); process.exit(1); });
