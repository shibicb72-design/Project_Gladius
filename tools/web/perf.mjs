// W1a commit 4: the browser frame-rate harness (docs/WEB.md "Frame-rate harness"). Reuses W0's server (serve.mjs)
// and Chrome launcher (chrome.mjs): the installed Chrome, HEADED, temporary profile, puppeteer-core from the webtools
// folder (not in the repo). For each quality level it opens the debug web export with
//   ?autosolo=1&length=12&wait=0&perf=1&quality=<preset id>&seed=<route seed>
// injects tools/web/perf_route.json (scaled to --seconds) as window.GLADIUS_PERF_ROUTE, waits for
// GLADIUS_MATCH_STARTED and GLADIUS_PERF_DONE <json> (scripts/debug/perf_route.gd: the fixed camera route, frame
// statistics and the Engine.max_fps 30 / 60 / 0 probe), and records the page's own requestAnimationFrame cadence, every
// frame over 250 ms (time after the match start), the Chrome version, WebGL renderer, viewport, devicePixelRatio and
// the display refresh rate (rAF on a blank page for 2 s).
//
//   node tools/web/perf.mjs [--levels=default,pc_medium,pc_high] [--seconds=90] [--out=build/perf/perf.json]
//                           [--size=1280x720] [--build=build/web] [--webtools=<dir>] [--chrome=<exe>]
//   node tools/web/perf.mjs --shots=<dir> [--levels=pc_high] [--seconds=30] [--shot-view=porta_aquilae] [--variants=dusk,night,storm]
//
// --shots: web capture mode instead of the perf runs: one page per look variant (perf_route.json variant_seeds), the
// HUD hidden, a screenshot 1.5 s after GLADIUS_PERF_VIEW <shot view>, saved as web_<view>_<variant>.png, at the
// quality of the first --levels entry; writes <dir>/shots.json.
// Exit code: 0 only when every requested level produced a result (shots: every variant a PNG); 1 otherwise; 2 bad
// arguments / missing build; 3 the overall hard timeout fired. Chrome and the server are always closed.
// Every number is "[measured] this PC, Chrome <version>, not a performance claim".
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startServer } from './serve.mjs';
import {
  DEFAULT_CHROME, DEFAULT_WEBTOOLS, frameStats, launchChrome, loadPuppeteer, makeProfileDir, removeProfile, sleep,
  webglRenderer,
} from './chrome.mjs';

const ROUTE_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'perf_route.json');
const MATCH_LENGTH = '12';
const BOOT_TIMEOUT_MS = 240000;   // wasm download + compile + boot + menu
const MATCH_TIMEOUT_MS = 300000;  // navigation -> GLADIUS_MATCH_STARTED
const DONE_MARGIN_MS = 180000;    // route + probe + this margin -> GLADIUS_PERF_DONE
const FREEZE_MS = 250;
const SHOT_SETTLE_MS = 1500;

function parseArgs(argv) {
  const out = {
    levels: null, variants: null, seconds: null, out: path.join('build', 'perf', 'perf.json'), shots: '', shotView: '',
    size: { width: 1280, height: 720 }, build: 'build/web', webtools: DEFAULT_WEBTOOLS, chrome: DEFAULT_CHROME,
  };
  for (const a of argv) {
    const m = /^--([a-z-]+)=(.*)$/.exec(a);
    if (!m) throw new Error(`unknown argument ${a} (use --name=value)`);
    const [, k, v] = m;
    if (k === 'levels') out.levels = v.split(',').map((s) => s.trim()).filter(Boolean);
    else if (k === 'seconds') out.seconds = Number(v);
    else if (k === 'out') out.out = v;
    else if (k === 'shots') out.shots = v;
    else if (k === 'shot-view') out.shotView = v;
    else if (k === 'variants') out.variants = v.split(',').map((x) => x.trim()).filter(Boolean);
    else if (k === 'build') out.build = v;
    else if (k === 'webtools') out.webtools = v;
    else if (k === 'chrome') out.chrome = v;
    else if (k === 'size') {
      const s = /^(\d+)x(\d+)$/.exec(v);
      if (!s) throw new Error('--size must be <W>x<H>');
      out.size = { width: Number(s[1]), height: Number(s[2]) };
    } else throw new Error(`unknown argument --${k}`);
  }
  if (out.levels === null) out.levels = out.shots ? ['pc_high'] : ['default', 'pc_medium', 'pc_high'];
  if (out.levels.length === 0) throw new Error('--levels is empty');
  if (out.seconds === null) out.seconds = out.shots ? 30 : 90;
  if (!Number.isFinite(out.seconds) || out.seconds < 5 || out.seconds > 900) throw new Error('--seconds must be 5..900');
  return out;
}

const r2 = (v) => Number(Number(v).toFixed(2));

async function main() {
  let args;
  let route;
  try {
    args = parseArgs(process.argv.slice(2));
    route = JSON.parse(fs.readFileSync(ROUTE_FILE, 'utf8'));
  } catch (e) {
    console.error(e.message);
    return 2;
  }
  const buildDir = path.resolve(args.build);
  if (!fs.existsSync(path.join(buildDir, 'index.html'))) {
    console.error(`no ${path.join(buildDir, 'index.html')}: export the Web preset first (docs/WEB.md)`);
    return 2;
  }
  const shotView = args.shotView || route.shot_view || 'porta_aquilae';
  const allSeeds = route.variant_seeds || {};
  for (const v of args.variants || []) if (!(v in allSeeds)) { console.error(`unknown variant ${v} (have ${Object.keys(allSeeds).join(', ')})`); return 2; }
  const variantSeeds = Object.fromEntries(Object.entries(allSeeds).filter(([v]) => !args.variants || args.variants.includes(v)));
  const outFile = args.shots ? path.join(args.shots, 'shots.json') : path.resolve(args.out);
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  if (args.shots) fs.mkdirSync(args.shots, { recursive: true });
  const puppeteer = loadPuppeteer(args.webtools);

  const t0 = Date.now();
  const log = (m) => console.log(`[perf ${((Date.now() - t0) / 1000).toFixed(1)}s] ${m}`);
  const report = {
    label: 'this PC, Chrome <version>, not a performance claim',
    tag: '[measured]',
    startedAt: new Date().toISOString(),
    mode: args.shots ? 'shots' : 'perf',
    chromeVersion: null,
    chromeMode: 'headed, temporary profile (real GPU; headless may use SwiftShader)',
    webglRenderer: null,
    viewport: args.size,
    page: null,
    refreshRate: null,
    routeFile: 'tools/web/perf_route.json',
    routeSeconds: args.seconds,
    routeTotalS: route.total_s,
    seed: route.seed,
    levels: [],
    shots: [],
    failures: [],
    timedOut: false,
    exitCode: null,
  };

  const consoleLines = []; // { t (ms since t0), type, text }
  const profileDir = makeProfileDir('gladius-perf-');
  let server = null;
  let browser = null;
  let hardTimer = null;
  const routeMs = args.seconds * 1000;
  const probe = route.probe || {};
  const probeMs = ((probe.caps || [30, 60, 0]).length) * ((probe.settle_s ?? 0.5) + (probe.seconds ?? 5)) * 1000;
  const runs = args.shots ? Object.keys(variantSeeds).length : args.levels.length;
  const HARD_TIMEOUT_MS = 5 * 60 * 1000 + runs * (BOOT_TIMEOUT_MS + MATCH_TIMEOUT_MS + routeMs + probeMs + DONE_MARGIN_MS);

  const cleanup = async () => {
    if (hardTimer) clearTimeout(hardTimer);
    try { if (browser) await Promise.race([browser.close(), sleep(15000)]); } catch { /* closing anyway */ }
    try { browser?.process()?.kill('SIGKILL'); } catch { /* already gone */ }
    try { if (server) await Promise.race([server.close(), sleep(5000)]); } catch { /* closing anyway */ }
    await removeProfile(profileDir);
  };
  const hardTimeout = new Promise((resolve) => { hardTimer = setTimeout(() => resolve('timeout'), HARD_TIMEOUT_MS); });

  const waitForLine = async (needle, timeoutMs, fromIndex = 0) => {
    const end = Date.now() + timeoutMs;
    while (Date.now() < end) {
      for (let i = fromIndex; i < consoleLines.length; i++) if (consoleLines[i].text.includes(needle)) return consoleLines[i];
      await sleep(100);
    }
    return null;
  };

  // One page load: inject the route config + an rAF recorder, open the URL, wait for the match start.
  const openRun = async (page, query, cfg) => {
    const { identifier } = await page.evaluateOnNewDocument((c) => {
      window.GLADIUS_PERF_ROUTE = c;
      window.__perf = { frames: [] };
      const tick = (ts) => { window.__perf.frames.push(ts); requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
    }, cfg);
    const from = consoleLines.length;
    const url = `${server.url}?${query}`;
    const navT = Date.now();
    await page.goto(url, { waitUntil: 'load', timeout: BOOT_TIMEOUT_MS });
    const started = await waitForLine('GLADIUS_MATCH_STARTED', MATCH_TIMEOUT_MS, from);
    return { identifier, from, url: url.replace(server.url, '/'), navT, started };
  };

  const godotLines = (from, to) => {
    const errors = [];
    const warnings = [];
    for (const c of consoleLines.slice(from, to)) {
      for (const line of c.text.split('\n')) {
        if (/\b(SCRIPT )?ERROR:/.test(line)) errors.push(line.trim());
        else if (/WARNING:/.test(line)) warnings.push(line.trim());
      }
    }
    return { errors, warnings };
  };

  const runLevel = async (page, level) => {
    const entry = { level, url: null, ok: false, secondsToMatchStart: null, game: null, raf: null, freezes: [], errors: [], warnings: [], failure: null };
    report.levels.push(entry);
    const cfg = { route, seconds: args.seconds, shots: false };
    const query = `autosolo=1&length=${MATCH_LENGTH}&wait=0&perf=1&quality=${encodeURIComponent(level)}&seed=${route.seed}`;
    const run = await openRun(page, query, cfg);
    entry.url = run.url;
    try {
      if (!run.started) {
        entry.failure = `no GLADIUS_MATCH_STARTED within ${MATCH_TIMEOUT_MS / 1000} s`;
        return;
      }
      const matchT = t0 + run.started.t;
      entry.secondsToMatchStart = r2((matchT - run.navT) / 1000);
      log(`${level}: match started ${entry.secondsToMatchStart} s after navigation`);
      const startLine = await waitForLine('GLADIUS_PERF_ROUTE_START', MATCH_TIMEOUT_MS, run.from);
      if (!startLine) {
        entry.failure = 'no GLADIUS_PERF_ROUTE_START (the director never ran?)';
        return;
      }
      log(`${level}: route started ${r2((t0 + startLine.t - matchT) / 1000)} s after the match start`);
      const done = await waitForLine('GLADIUS_PERF_DONE', routeMs + probeMs + DONE_MARGIN_MS, run.from);
      if (!done) {
        entry.failure = 'no GLADIUS_PERF_DONE before the timeout';
        return;
      }
      const json = done.text.slice(done.text.indexOf('GLADIUS_PERF_DONE') + 'GLADIUS_PERF_DONE'.length).trim();
      try { entry.game = JSON.parse(json); } catch (e) { entry.failure = `GLADIUS_PERF_DONE json: ${e.message}`; return; }
      if (!entry.game.ok) { entry.failure = `game: ${entry.game.error}`; return; }
      const probeLine = consoleLines.slice(run.from).find((c) => c.text.includes('GLADIUS_PERF_PROBE'));
      // The page's own rAF cadence, mapped to Node's clock through performance.timeOrigin (both epoch ms).
      const page_ = await page.evaluate(() => ({ origin: performance.timeOrigin, frames: window.__perf.frames }));
      const epoch = page_.frames.map((ts) => page_.origin + ts);
      // Route window: the game's page-clock stamps (perf_route.gd page_epoch_ms); the console arrival times as a fallback
      // (they lag while the page is busy).
      const routeA = entry.game.page_epoch_ms > 0 ? entry.game.page_epoch_ms : t0 + startLine.t;
      const routeB = entry.game.probe_page_epoch_ms > 0 ? entry.game.probe_page_epoch_ms : (probeLine ? t0 + probeLine.t : t0 + done.t);
      entry.raf = {
        source: 'requestAnimationFrame timestamps in the page; route = the game\'s page-clock route start .. probe start (a cross-check of the game\'s numbers); matchStartToDone starts at the console arrival of GLADIUS_MATCH_STARTED',
        route: frameStats([epoch.filter((e) => e >= routeA && e <= routeB)]),
        matchStartToDone: frameStats([epoch.filter((e) => e >= matchT && e <= t0 + done.t)]),
      };
      for (let i = 1; i < epoch.length; i++) {
        const dt = epoch[i] - epoch[i - 1];
        if (dt > FREEZE_MS && epoch[i] >= matchT - 1000) {
          // A gap is placed by its end: the frame that finally came is the one the stall belonged to (a route-start
          // freeze begins one rAF before the route's own stamp).
          const at = epoch[i - 1];
          const end = epoch[i];
          entry.freezes.push({
            ms: Math.round(dt),
            secondsAfterMatchStart: r2((at - matchT) / 1000),
            phase: at < matchT ? 'match build (gap began before GLADIUS_MATCH_STARTED arrived)'
              : end <= routeA ? 'before route' : end <= routeB ? 'route' : 'probe',
          });
        }
      }
      entry.ok = true;
      log(`${level}: done (median ${entry.game.route?.median_ms} ms, ${entry.freezes.length} rAF gaps > ${FREEZE_MS} ms)`);
    } finally {
      Object.assign(entry, godotLines(run.from, consoleLines.length));
      await page.removeScriptToEvaluateOnNewDocument(run.identifier).catch(() => {});
    }
  };

  const runShot = async (page, variant, seed) => {
    const level = args.levels[0];
    const file = `web_${shotView}_${variant}.png`;
    const entry = { variant, seed, level, file: null, url: null, secondsAfterView: null, failure: null };
    report.shots.push(entry);
    const cfg = { route, seconds: args.seconds, shots: true };
    const query = `autosolo=1&length=${MATCH_LENGTH}&wait=0&perf=1&quality=${encodeURIComponent(level)}&seed=${seed}`;
    const run = await openRun(page, query, cfg);
    entry.url = run.url;
    try {
      if (!run.started) { entry.failure = 'no GLADIUS_MATCH_STARTED'; return; }
      const view = await waitForLine(`GLADIUS_PERF_VIEW ${shotView}`, MATCH_TIMEOUT_MS + routeMs, run.from);
      if (!view) { entry.failure = `no GLADIUS_PERF_VIEW ${shotView}`; return; }
      const startLine = consoleLines.slice(run.from).find((c) => c.text.includes('GLADIUS_PERF_ROUTE_START'));
      if (startLine) {
        try { entry.game = JSON.parse(startLine.text.slice(startLine.text.indexOf('{'))); } catch { /* recorded below */ }
      }
      await sleep(SHOT_SETTLE_MS);
      await page.screenshot({ path: path.join(args.shots, file) });
      entry.file = file;
      entry.secondsAfterView = r2((Date.now() - (t0 + view.t)) / 1000);
      log(`shot ${file} (${entry.secondsAfterView} s after the view marker; variant in game: ${entry.game?.variant ?? '?'})`);
    } finally {
      await page.removeScriptToEvaluateOnNewDocument(run.identifier).catch(() => {});
    }
  };

  const run = async () => {
    server = await startServer(buildDir, 0);
    log(`serving ${buildDir} at ${server.url}`);
    browser = await launchChrome(puppeteer, { chrome: args.chrome, profileDir, viewport: args.size });
    const raw = await browser.version(); // "Chrome/<version>"
    report.chromeVersion = raw.replace(/^[A-Za-z]*Chrome\//, '');
    report.label = `this PC, Chrome ${report.chromeVersion}, not a performance claim`;
    const page = (await browser.pages())[0] ?? (await browser.newPage());
    await page.bringToFront();
    page.on('console', (msg) => consoleLines.push({ t: Date.now() - t0, type: msg.type(), text: msg.text() }));
    page.on('pageerror', (err) => report.failures.push(`page error: ${String(err?.message || err)}`));

    await page.goto('about:blank');
    report.webglRenderer = await webglRenderer(page);
    report.page = await page.evaluate(() => ({
      devicePixelRatio: window.devicePixelRatio,
      inner: [window.innerWidth, window.innerHeight],
      outer: [window.outerWidth, window.outerHeight],
      screen: [screen.width, screen.height],
    }));
    // Display refresh: rAF cadence on the blank page for 2 s (Chrome paces rAF to the display it is on).
    report.refreshRate = await page.evaluate(() => new Promise((resolve) => {
      const stamps = [];
      const tick = (ts) => {
        stamps.push(ts);
        if (ts - stamps[0] < 2000) requestAnimationFrame(tick);
        else {
          const d = stamps.slice(1).map((s, i) => s - stamps[i]).sort((a, b) => a - b);
          const med = d[Math.floor(d.length / 2)];
          resolve({ frames: stamps.length, medianFrameMs: Number(med.toFixed(3)), hz: Number((1000 / med).toFixed(1)),
            note: 'rAF on about:blank for 2 s' });
        }
      };
      requestAnimationFrame(tick);
    }));
    log(`Chrome ${report.chromeVersion}; WebGL ${report.webglRenderer}; display ~${report.refreshRate.hz} Hz; dpr ${report.page.devicePixelRatio}`);

    if (args.shots) {
      for (const [variant, seed] of Object.entries(variantSeeds)) await runShot(page, variant, seed);
    } else {
      for (const level of args.levels) await runLevel(page, level);
    }
  };

  try {
    const result = await Promise.race([run().then(() => 'done'), hardTimeout]);
    if (result === 'timeout') {
      report.timedOut = true;
      report.failures.push(`hard timeout ${Math.round(HARD_TIMEOUT_MS / 1000)} s`);
    }
  } catch (e) {
    report.failures.push(`exception: ${e?.stack || e}`);
  }
  if (args.shots) {
    const want = Object.keys(variantSeeds).length;
    const made = report.shots.filter((s) => s.file).length;
    if (made !== want || want === 0) report.failures.push(`${made} of ${want} shots`);
  } else {
    for (const level of args.levels) {
      const e = report.levels.find((x) => x.level === level);
      if (!e || !e.ok) report.failures.push(`level ${level}: ${e?.failure ?? 'not run'}`);
    }
  }
  report.exitCode = report.timedOut ? 3 : (report.failures.length === 0 ? 0 : 1);
  fs.writeFileSync(outFile, JSON.stringify(report, null, 2));
  fs.writeFileSync(outFile.replace(/\.json$/, '') + '_console.log',
    consoleLines.map((c) => `${(c.t / 1000).toFixed(1)}s [${c.type}] ${c.text}`).join('\n') + '\n');
  if (!args.shots) console.log('\n' + markdownTable(report));
  await cleanup();
  log(`wrote ${outFile}; exit ${report.exitCode}${report.failures.length ? ': ' + report.failures.join('; ') : ''}`);
  return report.exitCode;
}

function markdownTable(report) {
  const rows = [
    `[measured] ${report.label}; WebGL: ${report.webglRenderer}; viewport ${report.viewport.width}x${report.viewport.height}, dpr ${report.page?.devicePixelRatio}; display ~${report.refreshRate?.hz} Hz; route ${report.routeSeconds} s`,
    '',
    '| level | active preset | max_fps | frames | median ms | 1% low ms (fps) | p99 ms | > 33 ms | max ms | cap probe 30 / 60 / 0 median ms | rAF gaps > 250 ms | match start s |',
    '|---|---|---|---|---|---|---|---|---|---|---|---|',
  ];
  for (const e of report.levels) {
    const g = e.game || {};
    const s = g.route || {};
    const probe = (g.cap_probe || []).map((p) => p.median_ms).join(' / ');
    rows.push(`| ${e.level} | ${g.preset_active ?? '-'} | ${g.max_fps ?? '-'} | ${s.frames ?? '-'} | ${s.median_ms ?? '-'} | ` +
      `${s.one_percent_low_ms ?? '-'} (${s.one_percent_low_fps ?? '-'}) | ${s.p99_ms ?? '-'} | ${s.over_33ms ?? '-'} | ${s.max_ms ?? '-'} | ` +
      `${probe || '-'} | ${e.ok ? e.freezes.length : '-'} | ${e.secondsToMatchStart ?? '-'} |${e.ok ? '' : ' FAILED: ' + e.failure}`);
  }
  return rows.join('\n');
}

main().then((code) => process.exit(code), (e) => { console.error(e); process.exit(1); });
