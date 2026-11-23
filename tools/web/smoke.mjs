// W0: the browser smoke test (docs/WEB.md). Serves the web export, opens it in the installed Chrome (HEADED, a
// temporary profile: a real GPU; headless Chrome may fall back to SwiftShader and refuse pointer lock), screenshots the
// menu, starts a solo match through the debug-only URL argument ?autosolo=1&length=12&wait=<s> (scripts/platform/
// web_args.gd), plays 60 s of scripted keyboard and mouse input (move, look, fire, sprint, crouch, Esc pause and
// resume), and writes summary.json plus screenshots to <out_dir>.
//
//   node tools/web/smoke.mjs <out_dir> [--build build/web] [--seconds 60] [--webtools <dir>] [--chrome <exe>]
//
// Exit code: 0 only when the match started and no page error, failed request or unallowed Godot ERROR line appeared;
// 1 = the run failed those checks, 2 = bad arguments / missing build, 3 = the overall hard timeout fired.
// puppeteer-core (Apache-2.0) is NOT in the repo: it is loaded by absolute path from the webtools folder.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { startServer } from './serve.mjs';

// ---- Allowed Godot ERROR / SCRIPT ERROR console lines (binding fix 15). STARTS EMPTY. Every entry needs a pattern,
// ---- a justification comment and a mention in the slice report. Nothing is allowed silently.
const ALLOWED_LINES = [];

const DEFAULTS = {
  build: 'build/web',
  seconds: 60,
  webtools: 'C:\\Users\\shibi\\cc_gladius\\webtools',
  chrome: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
};
const LOBBY_WAIT_S = 6;          // the autosolo lobby wait, so lobby.png can be taken (WebArgs wait=)
const MATCH_LENGTH = '12';       // the brief's 12-minute solo match
const BOOT_TIMEOUT_MS = 240000;  // wasm download + compile + the menu (generous)
const MATCH_TIMEOUT_MS = 300000; // lobby Start -> local pawn spawned (match build, nav, bots)
const HARD_TIMEOUT_MS = 15 * 60 * 1000;
const VIEWPORT = { width: 1280, height: 720 };

function parseArgs(argv) {
  const out = { ...DEFAULTS, outDir: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    if (a === '--build') out.build = next();
    else if (a === '--seconds') out.seconds = Number(next());
    else if (a === '--webtools') out.webtools = next();
    else if (a === '--chrome') out.chrome = next();
    else if (!a.startsWith('--') && out.outDir === '') out.outDir = a;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!out.outDir) throw new Error('usage: node tools/web/smoke.mjs <out_dir> [--build build/web] [--seconds 60]');
  if (!Number.isFinite(out.seconds) || out.seconds < 20) throw new Error('--seconds must be a number >= 20');
  return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- frame statistics from requestAnimationFrame timestamps (ms) ----
// `segments` is an array of timestamp arrays; frame deltas are taken inside each segment only (a removed pause adds
// no delta), and the seconds are the sum of the segment spans.
function frameStats(segments) {
  const dts = [];
  let span = 0;
  let frames = 0;
  for (const stamps of segments) {
    frames += stamps.length;
    for (let i = 1; i < stamps.length; i++) dts.push(stamps[i] - stamps[i - 1]);
    if (stamps.length > 1) span += stamps[stamps.length - 1] - stamps[0];
  }
  if (dts.length < 2) return { frames };
  const sorted = [...dts].sort((a, b) => a - b);
  const pct = (p) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
  const worstN = Math.max(1, Math.floor(sorted.length * 0.01));
  const worst = sorted.slice(sorted.length - worstN);
  const worstAvg = worst.reduce((s, v) => s + v, 0) / worst.length;
  const r = (v, d = 2) => Number(v.toFixed(d));
  return {
    frames,
    seconds: r(span / 1000, 2),
    hitchesOver250ms: dts.filter((d) => d > 250).length,
    hitchesOver1s: dts.filter((d) => d > 1000).map((d) => r(d, 0)),
    avgFps: r((dts.length / span) * 1000, 1),
    onePercentLowFps: r(1000 / worstAvg, 1),
    medianFrameMs: r(pct(0.5)),
    p95FrameMs: r(pct(0.95)),
    p99FrameMs: r(pct(0.99)),
    maxFrameMs: r(sorted[sorted.length - 1]),
  };
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    return 2;
  }
  const buildDir = path.resolve(args.build);
  if (!fs.existsSync(path.join(buildDir, 'index.html'))) {
    console.error(`no ${path.join(buildDir, 'index.html')}: export the Web preset first (docs/WEB.md)`);
    return 2;
  }
  fs.mkdirSync(args.outDir, { recursive: true });
  const requireFromWebtools = createRequire(path.join(args.webtools, 'package.json'));
  const pptrModule = requireFromWebtools('puppeteer-core');
  const puppeteer = pptrModule.default ?? pptrModule;

  const t0 = Date.now();
  const log = (m) => console.log(`[smoke ${((Date.now() - t0) / 1000).toFixed(1)}s] ${m}`);
  const summary = {
    label: '[measured] this PC, Chrome <version>, not a performance claim',
    startedAt: new Date().toISOString(),
    chromeVersion: null,
    chromeMode: 'headed, temporary profile (real GPU; headless may use SwiftShader and refuse pointer lock)',
    webglRenderer: null,
    viewport: VIEWPORT,
    url: null,
    matchStarted: false,
    secondsToMenu: null,
    secondsToMatchStart: null,
    pageErrors: [],
    failedRequests: [],
    httpErrors: [],
    godotErrors: [],
    allowedErrorLines: [],
    warnings: [],
    browserConsoleErrors: [],
    browserWarnings: [],
    pointerLock: [],
    escape: {},
    pauseObserved: false,
    pauseClosedObserved: false,
    inputLog: [],
    fps: null,
    screenshots: [],
    screenshotSecondsAfterMatchStart: {},
    allowedLines: ALLOWED_LINES.map((a) => ({ pattern: String(a.pattern), why: a.why })),
    timedOut: false,
    failures: [],
    exitCode: null,
  };

  const consoleLines = []; // { t, type, text }
  const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gladius-smoke-'));
  let server = null;
  let browser = null;
  let hardTimer = null;
  const outFile = path.join(args.outDir, 'summary.json');
  const writeSummary = () => fs.writeFileSync(outFile, JSON.stringify(summary, null, 2));

  const cleanup = async () => {
    if (hardTimer) clearTimeout(hardTimer);
    try { if (browser) await Promise.race([browser.close(), sleep(15000)]); } catch { /* closing anyway */ }
    try { browser?.process()?.kill('SIGKILL'); } catch { /* already gone */ }
    try { if (server) await Promise.race([server.close(), sleep(5000)]); } catch { /* closing anyway */ }
    for (let i = 0; i < 10; i++) {
      try { fs.rmSync(profileDir, { recursive: true, force: true }); break; } catch { await sleep(500); }
    }
  };

  const hardTimeout = new Promise((resolve) => {
    hardTimer = setTimeout(() => resolve('timeout'), HARD_TIMEOUT_MS);
  });

  const run = async () => {
    server = await startServer(buildDir, 0);
    log(`serving ${buildDir} at ${server.url}`);
    browser = await puppeteer.launch({
      executablePath: args.chrome,
      headless: false,
      userDataDir: profileDir,
      defaultViewport: VIEWPORT,
      protocolTimeout: 120000,
      args: [
        `--window-size=${VIEWPORT.width + 40},${VIEWPORT.height + 180}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-background-timer-throttling',
        '--disable-renderer-backgrounding',
        '--disable-backgrounding-occluded-windows',
      ],
    });
    summary.chromeVersion = await browser.version();
    summary.label = `[measured] this PC, ${summary.chromeVersion}, not a performance claim`;
    const page = (await browser.pages())[0] ?? (await browser.newPage());
    await page.bringToFront();

    page.on('console', (msg) => {
      const text = msg.text();
      const entry = { t: Date.now() - t0, type: msg.type(), text };
      consoleLines.push(entry);
      for (const line of text.split('\n')) {
        if (/\b(SCRIPT )?ERROR:/.test(line)) {
          const allowed = ALLOWED_LINES.find((a) => (a.pattern instanceof RegExp ? a.pattern.test(line) : line.includes(a.pattern)));
          (allowed ? summary.allowedErrorLines : summary.godotErrors).push(line.trim());
        } else if (/WARNING:/.test(line)) {
          summary.warnings.push(line.trim());
        } else if (msg.type() === 'error' && line.trim() !== '' && !/^\s+at:/.test(line)) {
          summary.browserConsoleErrors.push(line.trim());
        } else if (msg.type() === 'warn' && line.trim() !== '') {
          summary.browserWarnings.push(line.trim()); // not failing (e.g. Chrome's autoplay notice)
        }
      }
    });
    page.on('pageerror', (err) => summary.pageErrors.push(String(err?.stack || err?.message || err)));
    page.on('requestfailed', (req) => summary.failedRequests.push(`${req.url()} ${req.failure()?.errorText ?? ''}`.trim()));
    page.on('response', (res) => { if (res.status() >= 400) summary.httpErrors.push(`${res.status()} ${res.url()}`); });

    const waitForLine = async (needle, timeoutMs, fromIndex = 0) => {
      const end = Date.now() + timeoutMs;
      while (Date.now() < end) {
        const hit = consoleLines.slice(fromIndex).find((c) => c.text.includes(needle));
        if (hit) return hit;
        await sleep(100);
      }
      return null;
    };
    let matchT = null; // Date.now() when GLADIUS_MATCH_STARTED arrived
    const shot = async (name) => {
      const file = path.join(args.outDir, name);
      await page.screenshot({ path: file });
      const at = matchT === null ? null : Number(((Date.now() - matchT) / 1000).toFixed(1));
      summary.screenshots.push(name);
      summary.screenshotSecondsAfterMatchStart[name] = at;
      log(`screenshot ${name}${at === null ? '' : ` (${at} s after match start)`}`);
    };
    const lockState = async (step) => {
      const v = await page.evaluate(() => {
        const el = document.pointerLockElement;
        return el ? (el.id || el.tagName) : null;
      }).catch((e) => `evaluate failed: ${e.message}`);
      summary.pointerLock.push({ step, t: Number(((Date.now() - t0) / 1000).toFixed(1)), pointerLockElement: v });
      return v;
    };

    // WebGL renderer string from a throwaway canvas (webgl2 context).
    await page.goto('about:blank');
    summary.webglRenderer = await page.evaluate(() => {
      const c = document.createElement('canvas');
      const gl = c.getContext('webgl2');
      if (!gl) return 'no webgl2 context';
      const ext = gl.getExtension('WEBGL_debug_renderer_info');
      const r = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
      const v = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
      return `${v} | ${r}`;
    });
    log(`chrome ${summary.chromeVersion}; webgl ${summary.webglRenderer}`);

    // 1. The menu, no URL arguments.
    let navT = Date.now();
    await page.goto(server.url, { waitUntil: 'load', timeout: BOOT_TIMEOUT_MS });
    const menu = await waitForLine('GLADIUS_MENU_READY', BOOT_TIMEOUT_MS);
    if (!menu) {
      summary.failures.push('the main menu never reported ready (GLADIUS_MENU_READY)');
      return;
    }
    summary.secondsToMenu = Number(((Date.now() - navT) / 1000).toFixed(1));
    await sleep(2000); // the menu fade-in
    await shot('menu.png');

    // 2. Autosolo: the solo lobby (wait LOBBY_WAIT_S), then the match.
    const url = `${server.url}?autosolo=1&length=${MATCH_LENGTH}&wait=${LOBBY_WAIT_S}`;
    summary.url = url.replace(server.url, '/');
    const from = consoleLines.length;
    navT = Date.now();
    await page.goto(url, { waitUntil: 'load', timeout: BOOT_TIMEOUT_MS });
    const lobby = await waitForLine('GLADIUS_LOBBY_READY', BOOT_TIMEOUT_MS, from);
    if (!lobby) {
      summary.failures.push('the solo lobby never reported ready (GLADIUS_LOBBY_READY)');
      return;
    }
    await sleep(2500);
    await shot('lobby.png');
    const started = await waitForLine('GLADIUS_MATCH_STARTED', MATCH_TIMEOUT_MS, from);
    if (!started) {
      summary.failures.push(`no GLADIUS_MATCH_STARTED within ${MATCH_TIMEOUT_MS / 1000} s of the lobby`);
      return;
    }
    summary.matchStarted = true;
    matchT = t0 + started.t;
    summary.secondsToMatchStart = Number(((started.t - (navT - t0)) / 1000).toFixed(1));
    log(`match started ${summary.secondsToMatchStart}s after navigation`);

    // Frame timing and input evidence, collected in the page. The page can be busy right after the marker (the rest
    // of the match setup), so this evaluate may take seconds; its duration is recorded.
    const setupT = Date.now();
    await page.evaluate(() => {
      window.__smoke = { frames: [], marks: [], keys: { Escape: 0 }, moves: 0, movesWithDelta: 0 };
      const tick = (ts) => { window.__smoke.frames.push(ts); requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
      document.addEventListener('keydown', (e) => { if (e.key === 'Escape') window.__smoke.keys.Escape++; }, true);
      document.addEventListener('mousemove', (e) => {
        window.__smoke.moves++;
        if (e.movementX !== 0 || e.movementY !== 0) window.__smoke.movesWithDelta++;
      }, true);
    });
    const mark = (name) => page.evaluate((n) => window.__smoke.marks.push({ n, ts: performance.now() }), name);
    const inputT0 = Date.now();
    const note = (what) => summary.inputLog.push({ t: Number(((Date.now() - inputT0) / 1000).toFixed(1)), what });
    await mark('input_start');
    summary.pageBusyAfterMatchStartSeconds = Number(((Date.now() - setupT) / 1000).toFixed(1));

    await sleep(Math.max(0, matchT + 5000 - Date.now()));
    await shot('match_5s.png');

    const cx = VIEWPORT.width / 2;
    const cy = VIEWPORT.height / 2;
    const hold = async (key, ms) => { await page.keyboard.down(key); await sleep(ms); await page.keyboard.up(key); };
    const look = async (dx, dy, steps = 20) => {
      await page.mouse.move(cx, cy);
      await page.mouse.move(cx + dx, cy + dy, { steps });
    };
    const fire = async (n) => {
      for (let i = 0; i < n; i++) {
        await page.mouse.down({ button: 'left' });
        await sleep(90);
        await page.mouse.up({ button: 'left' });
        await sleep(160);
      }
    };

    // Capture: a click on the canvas asks Godot for the mouse (pointer lock needs a user gesture).
    await lockState('before first click');
    await page.mouse.click(cx, cy);
    note('click canvas (capture)');
    await sleep(800);
    await lockState('after first click');

    note('W 3 s + look right'); await page.keyboard.down('KeyW'); await look(250, 0); await sleep(2500); await page.keyboard.up('KeyW');
    note('A 1.5 s'); await hold('KeyA', 1500);
    note('S 1.5 s + look left/up'); await page.keyboard.down('KeyS'); await look(-300, -60); await sleep(1000); await page.keyboard.up('KeyS');
    note('D 1.5 s'); await hold('KeyD', 1500);
    note('fire x4'); await fire(4);
    note('Shift+W sprint 3 s'); await page.keyboard.down('ShiftLeft'); await page.keyboard.down('KeyW'); await sleep(3000);
    await page.keyboard.up('KeyW'); await page.keyboard.up('ShiftLeft');
    note('C crouch on'); await page.keyboard.press('KeyC'); await sleep(1500);
    note('W crouched 1.5 s'); await hold('KeyW', 1500);
    note('C crouch off'); await page.keyboard.press('KeyC'); await sleep(800);

    // Esc -> pause. Record whether Chrome released the lock itself and whether the key reached the page.
    const escBefore = await page.evaluate(() => window.__smoke.keys.Escape);
    const lockBeforeEsc = await lockState('before Esc #1');
    const pauseFrom = consoleLines.length;
    await mark('pause_start');
    await page.keyboard.press('Escape');
    note('Esc #1 (expect pause)');
    const opened = await waitForLine('GLADIUS_PAUSE_OPENED', 4000, pauseFrom);
    const lockAfterEsc = await lockState('after Esc #1');
    const escAfter = await page.evaluate(() => window.__smoke.keys.Escape);
    summary.pauseObserved = Boolean(opened);
    const pathLine = consoleLines.slice(pauseFrom).find((c) => c.text.includes('GLADIUS_PAUSE_PATH'));
    summary.escape.first = {
      pointerLockBefore: lockBeforeEsc,
      pointerLockAfter: lockAfterEsc,
      keydownReachedPage: escAfter > escBefore,
      pauseOpened: Boolean(opened),
      // From the game (MouseCapture, debug web build): "key" = Godot got the Esc key event; "capture_lost" = the lock
      // ended without a key event (Chrome ate Esc), the capture-lost path.
      gamePath: pathLine ? pathLine.text.replace('GLADIUS_PAUSE_PATH', '').trim() : null,
    };
    await sleep(1000);
    await shot('pause.png');
    await sleep(1000);

    // Esc again -> resume; then wait >= 1.5 s before clicking to recapture (Chrome refuses an immediate re-lock).
    const closeFrom = consoleLines.length;
    await page.keyboard.press('Escape');
    note('Esc #2 (expect resume)');
    const closed = await waitForLine('GLADIUS_PAUSE_CLOSED', 4000, closeFrom);
    summary.pauseClosedObserved = Boolean(closed);
    summary.escape.second = { pauseClosed: Boolean(closed), pointerLockAfter: await lockState('after Esc #2') };
    await mark('pause_end');
    await sleep(1700);
    await page.mouse.click(cx, cy);
    note('click canvas (recapture after 1.7 s)');
    await sleep(800);
    await lockState('after recapture click');

    // The rest of the 60 s: move, look, fire in a loop.
    const endAt = inputT0 + args.seconds * 1000;
    let i = 0;
    while (Date.now() < endAt - 1500) {
      const key = ['KeyW', 'KeyD', 'KeyW', 'KeyA'][i % 4];
      note(`${key} + look + fire`);
      await page.keyboard.down(key);
      await look(i % 2 ? -200 : 200, i % 3 ? 30 : -30, 15);
      await fire(2);
      await page.keyboard.up(key);
      i++;
    }
    while (Date.now() < endAt) await sleep(100);
    await lockState('at 60 s');
    await shot('match_60s.png');
    await mark('input_end');

    const smoke = await page.evaluate(() => window.__smoke);
    summary.mouseMoves = { events: smoke.moves, withMovement: smoke.movesWithDelta };
    const m = Object.fromEntries(smoke.marks.map((x) => [x.n, x.ts]));
    const inWindow = smoke.frames.filter((ts) => ts >= m.input_start && ts <= m.input_end);
    const before = inWindow.filter((ts) => ts < m.pause_start);
    const after = inWindow.filter((ts) => ts > m.pause_end);
    summary.fps = {
      label: summary.label,
      source: 'requestAnimationFrame timestamps in the page, from the input start (match start + setup) to the 60 s screenshot',
      whole: frameStats([inWindow]),
      excludingPause: { ...frameStats([before, after]), note: 'the seconds between Esc #1 and Esc #2 removed (no delta across the gap)' },
      pausedSeconds: Number(((m.pause_end - m.pause_start) / 1000).toFixed(1)),
    };
  };

  let exitCode = 1;
  try {
    const result = await Promise.race([run().then(() => 'done'), hardTimeout]);
    if (result === 'timeout') {
      summary.timedOut = true;
      summary.failures.push(`hard timeout ${HARD_TIMEOUT_MS / 1000} s`);
    }
  } catch (e) {
    summary.failures.push(`exception: ${e?.stack || e}`);
  }
  if (!summary.matchStarted) summary.failures.push('match did not start');
  if (summary.pageErrors.length) summary.failures.push(`${summary.pageErrors.length} page error(s)`);
  if (summary.failedRequests.length) summary.failures.push(`${summary.failedRequests.length} failed request(s)`);
  if (summary.httpErrors.length) summary.failures.push(`${summary.httpErrors.length} HTTP error response(s)`);
  if (summary.godotErrors.length) summary.failures.push(`${summary.godotErrors.length} unallowed Godot ERROR line(s)`);
  summary.failures = [...new Set(summary.failures)];
  exitCode = summary.timedOut ? 3 : (summary.failures.length === 0 ? 0 : 1);
  summary.exitCode = exitCode;
  summary.consoleLineCount = consoleLines.length;
  fs.writeFileSync(path.join(args.outDir, 'console.log'),
    consoleLines.map((c) => `${(c.t / 1000).toFixed(1)}s [${c.type}] ${c.text}`).join('\n') + '\n');
  writeSummary();
  await cleanup();
  log(`exit ${exitCode}${summary.failures.length ? ': ' + summary.failures.join('; ') : ''}`);
  return exitCode;
}

main().then((code) => process.exit(code), (e) => { console.error(e); process.exit(1); });
