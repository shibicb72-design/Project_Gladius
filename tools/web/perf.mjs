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
// W1c step 1 (stall attribution; docs/WEB.md "Stall timing (W1c)"):
//   node tools/web/perf.mjs --profile-dir=<profiles root> [--cold [--keep-profiles] | --profile-name=warm]
//                           [--trace=<trace.json>] [--levels=...] [--seconds=...] [--out=...]
// --profile-dir: every level in its OWN Chrome launch; --cold = a fresh profile per level under the root plus
// --disable-gpu-shader-disk-cache (removed after the level unless --keep-profiles); without --cold the named reused
// profile <root>/<profile-name> (warm once an earlier run used it). --trace: a Chrome trace per level (TRACE_CATEGORIES;
// "_<level>" is added before the extension when several levels run). Every level entry gets "w1c": the page-clock
// times of GLADIUS_MATCH_STARTED and GLADIUS_CAN_MOVE, every rAF gap over 250 ms from page load (before / after
// CAN_MOVE), median and 1 percent low after CAN_MOVE, the markers and the parsed GLADIUS_T lines; tools/web/
// perf_stalls.mjs turns that and the trace into the stall table.
// W1c fix pass 1: "w1c.action" = the action step after the probe (perf_route.json "action": switch weapon, fire, swing
// through the player's input actions): every rAF gap over 250 ms inside GLADIUS_T action.start .. action.end with the
// actions it overlaps, and the longest frame in that window (also under 250 ms), apart from the stalls of the route.
// --warm-skip=<kind>[,<kind>...] adds warm_skip= to the page URL: the shader warm-up leaves those data/warmup.json
// "listed" kinds out (debug web + perf=1 only; scripts/debug/perf_marks.gd warm_skip): the "before" of a warm entry
// on the same commit.
// Exit code: 0 only when every requested level produced a result (shots: every variant a PNG); 1 otherwise; 2 bad
// arguments / missing build; 3 the overall hard timeout fired. Chrome and the server are always closed.
// Every number is "[measured] this PC, Chrome <version>, not a performance claim".
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startServer } from './serve.mjs';
import {
  DEFAULT_CHROME, DEFAULT_WEBTOOLS, frameStats, freshProfileDir, launchChrome, loadPuppeteer, makeProfileDir,
  namedProfileDir, removeProfile, sleep, webglRenderer,
} from './chrome.mjs';

const ROUTE_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'perf_route.json');
const MATCH_LENGTH = '12';
const BOOT_TIMEOUT_MS = 240000;   // wasm download + compile + boot + menu
const MATCH_TIMEOUT_MS = 300000;  // navigation -> GLADIUS_MATCH_STARTED
const DONE_MARGIN_MS = 180000;    // route + probe + this margin -> GLADIUS_PERF_DONE
const FREEZE_MS = 250;
const SHOT_SETTLE_MS = 1500;
const LAUNCH_RETRY_MS = 20000;

// W1c: Chrome trace categories for --trace (GPU process and ANGLE, V8 and GC, user timing = the game's GLADIUS_T
// spans, main-thread tasks).
const TRACE_CATEGORIES = [
  '-*', 'gpu', 'gpu.service', 'disabled-by-default-gpu.service', 'gpu.angle', 'v8', 'v8.wasm', 'disabled-by-default-v8.gc',
  'blink.user_timing', 'devtools.timeline', 'toplevel', 'blink', 'loading', '__metadata',
];
const COLD_ARGS = ['--disable-gpu-shader-disk-cache'];

function parseArgs(argv) {
  const out = {
    levels: null, variants: null, seconds: null, out: path.join('build', 'perf', 'perf.json'), shots: '', shotView: '',
    size: { width: 1280, height: 720 }, build: 'build/web', webtools: DEFAULT_WEBTOOLS, chrome: DEFAULT_CHROME,
    profileDir: '', profileName: 'warm', cold: false, keepProfiles: false, trace: '', warmSkip: '',
  };
  for (const a of argv) {
    if (a === '--cold') { out.cold = true; continue; }
    if (a === '--keep-profiles') { out.keepProfiles = true; continue; }
    const m = /^--([a-z-]+)=(.*)$/.exec(a);
    if (!m) throw new Error(`unknown argument ${a} (use --name=value)`);
    const [, k, v] = m;
    if (k === 'profile-dir') out.profileDir = v;
    else if (k === 'profile-name') out.profileName = v;
    else if (k === 'trace') out.trace = v;
    else if (k === 'warm-skip') {
      if (!/^[a-z_]+(,[a-z_]+)*$/.test(v)) throw new Error('--warm-skip: comma-separated data/warmup.json listed kinds');
      out.warmSkip = v;
    }
    else if (k === 'levels') out.levels = v.split(',').map((s) => s.trim()).filter(Boolean);
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
  if (out.cold && !out.profileDir) throw new Error('--cold needs --profile-dir=<profiles root>');
  if (!/^[A-Za-z0-9_.-]+$/.test(out.profileName)) throw new Error('--profile-name: letters, digits, _ . - only');
  if (out.shots && (out.trace || out.profileDir || out.cold)) throw new Error('--trace / --profile-dir / --cold are for perf runs, not --shots');
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
    warmSkip: args.warmSkip || null,
    levels: [],
    shots: [],
    failures: [],
    timedOut: false,
    exitCode: null,
  };
  // W1c: with --profile-dir every level runs in its OWN Chrome launch: --cold = a fresh profile per level under the
  // root plus COLD_ARGS (the GPU driver's own shader cache survives: "cold" is [inferred] partial); otherwise the named
  // reused profile <root>/<--profile-name> (warm). Without --profile-dir: W1a's one temporary profile, one browser.
  const perLaunch = Boolean(args.profileDir);
  const profileRoot = perLaunch ? path.resolve(args.profileDir) : '';
  report.profile = !perLaunch
    ? { mode: 'temporary', note: 'W1a: one temporary profile, every level in the same browser (caches carry over)' }
    : args.cold
      ? { mode: 'cold', root: profileRoot, chromeArgs: COLD_ARGS, kept: args.keepProfiles,
        note: 'a fresh Chrome profile per level, own browser launch; GPU driver caches survive ([inferred] partial cold)' }
      : { mode: 'warm', root: profileRoot, name: args.profileName,
        note: 'one named reused profile, own browser launch per level; warm only if an earlier run used it (existedBefore)' };
  if (perLaunch) report.chromeMode = `headed, ${report.profile.mode} profile (real GPU)`;

  const consoleLines = []; // { t (ms since t0), type, text }
  const profileDir = perLaunch ? '' : makeProfileDir('gladius-perf-');
  let server = null;
  let browser = null;
  let browserProfile = null; // { dir, existedBefore, remove } of the current per-level launch
  let hardTimer = null;
  const routeMs = args.seconds * 1000;
  const probe = route.probe || {};
  const probeMs = ((probe.caps || [30, 60, 0]).length) * ((probe.settle_s ?? 0.5) + (probe.seconds ?? 5)) * 1000;
  const runs = args.shots ? Object.keys(variantSeeds).length : args.levels.length;
  const HARD_TIMEOUT_MS = 5 * 60 * 1000 + runs * (BOOT_TIMEOUT_MS + MATCH_TIMEOUT_MS + routeMs + probeMs + DONE_MARGIN_MS);

  const closeBrowser = async () => {
    try { if (browser) await Promise.race([browser.close(), sleep(15000)]); } catch { /* closing anyway */ }
    try { browser?.process()?.kill('SIGKILL'); } catch { /* already gone */ }
    browser = null;
    if (browserProfile?.remove) await removeProfile(browserProfile.dir);
    browserProfile = null;
  };
  const cleanup = async () => {
    if (hardTimer) clearTimeout(hardTimer);
    await closeBrowser();
    try { if (server) await Promise.race([server.close(), sleep(5000)]); } catch { /* closing anyway */ }
    if (profileDir) await removeProfile(profileDir);
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

  // One page load: inject the route config + an rAF recorder (from the document's start, so the match-build stall is
  // seen) + a console hook that stamps every GLADIUS_* line with the page clock (performance.now() when the game
  // called console.*, not when the line reached Node), open the URL, wait for the match start. With `tracePath` the
  // Chrome trace starts before the navigation (stopped by stopTrace).
  const openRun = async (page, query, cfg, tracePath = '') => {
    const { identifier } = await page.evaluateOnNewDocument((c) => {
      window.GLADIUS_PERF_ROUTE = c;
      window.__perf = { frames: [], lines: [], docStart: performance.now() };
      try { performance.mark('gladius_doc_start'); } catch { /* old browser */ }
      for (const k of ['log', 'info', 'warn', 'error', 'debug']) {
        const orig = console[k];
        console[k] = function (...a) {
          try {
            const s = a.map(String).join(' ');
            if (s.indexOf('GLADIUS_') >= 0) window.__perf.lines.push([performance.now(), s]);
          } catch { /* never break the page's logging */ }
          return orig.apply(this, a);
        };
      }
      const tick = (ts) => { window.__perf.frames.push(ts); requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
    }, cfg);
    const from = consoleLines.length;
    const url = `${server.url}?${query}`;
    if (tracePath) {
      fs.mkdirSync(path.dirname(tracePath), { recursive: true });
      await page.tracing.start({ path: tracePath, categories: TRACE_CATEGORIES });
    }
    const navT = Date.now();
    await page.goto(url, { waitUntil: 'load', timeout: BOOT_TIMEOUT_MS });
    const started = await waitForLine('GLADIUS_MATCH_STARTED', MATCH_TIMEOUT_MS, from);
    return { identifier, from, url: url.replace(server.url, '/'), navT, started };
  };

  // W1c: a fresh browser for one level (per-level launches), with the page set up like the shared one.
  const launchFor = async (level) => {
    if (args.cold) browserProfile = { ...freshProfileDir(profileRoot, `cold_${level}_`), remove: !args.keepProfiles };
    else browserProfile = { ...namedProfileDir(profileRoot, args.profileName), remove: false };
    // Another slice may hold Chrome: three tries, LAUNCH_RETRY_MS apart.
    for (let attempt = 1; ; attempt++) {
      try {
        browser = await launchChrome(puppeteer, {
          chrome: args.chrome, profileDir: browserProfile.dir, viewport: args.size, extraArgs: args.cold ? COLD_ARGS : [],
        });
        break;
      } catch (e) {
        if (attempt >= 3) throw e;
        log(`${level}: Chrome did not start (${e?.message || e}); retry ${attempt} of 2 in ${LAUNCH_RETRY_MS / 1000} s`);
        await sleep(LAUNCH_RETRY_MS);
      }
    }
    const page = await setupPage();
    return { page, profile: { dir: browserProfile.dir, existedBefore: browserProfile.existedBefore, removedAfter: browserProfile.remove } };
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

  const traceFileFor = (level) => {
    if (!args.trace) return '';
    const file = path.resolve(args.trace);
    if (args.levels.length === 1) return file;
    const ext = path.extname(file) || '.json';
    return file.slice(0, file.length - path.extname(file).length) + `_${level}${ext}`;
  };

  const runLevel = async (sharedPage, level) => {
    const entry = { level, url: null, ok: false, secondsToMatchStart: null, game: null, raf: null, freezes: [], errors: [], warnings: [], failure: null,
      profile: null, trace: null };
    report.levels.push(entry);
    let page = sharedPage;
    if (perLaunch) {
      const l = await launchFor(level);
      page = l.page;
      entry.profile = l.profile;
      log(`${level}: own Chrome launch, ${report.profile.mode} profile ${l.profile.dir}${l.profile.existedBefore ? ' (reused)' : ' (new)'}`);
    }
    const cfg = { route, seconds: args.seconds, shots: false };
    const query = `autosolo=1&length=${MATCH_LENGTH}&wait=0&perf=1&quality=${encodeURIComponent(level)}&seed=${route.seed}` +
      (args.warmSkip ? `&warm_skip=${args.warmSkip}` : '');
    const tracePath = traceFileFor(level);
    let run;
    try {
      run = await openRun(page, query, cfg, tracePath);
    } catch (e) {
      if (tracePath) await page.tracing.stop().catch(() => {});
      if (perLaunch) await closeBrowser();
      throw e;
    }
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
      // W1c: the stall list from page load, the markers on the page clock, the GLADIUS_T timing lines.
      try {
        const pg = await page.evaluate(() => ({ origin: performance.timeOrigin, frames: window.__perf.frames, lines: window.__perf.lines }));
        entry.w1c = stallAnalysis(pg, entry.game);
        const s = entry.w1c.stallSummary;
        log(`${level}: CAN_MOVE at ${entry.w1c.canMovePageS ?? '?'} s (page clock); rAF gaps > ${FREEZE_MS} ms: ${s.beforeCanMove} before, ${s.afterCanMove} after (longest after ${s.longestAfterMs ?? '-'} ms)`);
        const act = entry.w1c.action;
        log(`${level}: action step ${act?.ran ? `ran: ${act.stallCount} gaps > ${FREEZE_MS} ms (longest ${act.longestStallMs ?? '-'}), longest frame ${act.longestFrame?.ms ?? '-'} ms` : `did not run (${act?.skipped ?? 'no marks'})`}`);
      } catch (e) {
        entry.w1cError = String(e?.message || e);
      }
      if (tracePath) {
        try {
          await page.tracing.stop();
          entry.trace = tracePath;
          log(`${level}: trace ${tracePath} (${(fs.statSync(tracePath).size / 1e6).toFixed(1)} MB)`);
        } catch (e) { entry.traceError = String(e?.message || e); }
      }
      await page.removeScriptToEvaluateOnNewDocument(run.identifier).catch(() => {});
      if (perLaunch) await closeBrowser();
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

  // The current browser's page: console capture, the Chrome version, WebGL renderer, page sizes and display refresh
  // (each launch re-measures; the report keeps the last).
  const setupPage = async () => {
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
    return page;
  };

  const run = async () => {
    server = await startServer(buildDir, 0);
    log(`serving ${buildDir} at ${server.url}`);
    if (perLaunch && !args.shots) {
      for (const level of args.levels) {
        try {
          await runLevel(null, level);
        } catch (e) {
          report.failures.push(`level ${level} exception: ${e?.stack || e}`);
          await closeBrowser();
        }
      }
      return;
    }
    browser = await launchChrome(puppeteer, { chrome: args.chrome, profileDir, viewport: args.size });
    const page = await setupPage();
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

// W1c: one GLADIUS_T line (scripts/debug/perf_marks.gd) -> { label, ticksMs, durMs (null for a mark), pageMs (end of the
// span on the page clock, ms since performance.timeOrigin), extra {k: v} }. hookMs = when the console hook saw it.
function parseTimingLine(text, hookMs, origin) {
  const m = /^GLADIUS_T (\S+) (\d+) (\S+) page=(-?[\d.]+)(.*)$/.exec(text.trim());
  if (!m) return null;
  const extra = {};
  for (const kv of m[5].trim().split(/\s+/).filter(Boolean)) {
    const i = kv.indexOf('=');
    if (i > 0) extra[kv.slice(0, i)] = kv.slice(i + 1);
  }
  const page = Number(m[4]);
  return {
    label: m[1], ticksMs: Number(m[2]), durMs: m[3] === '-' ? null : Number(m[3]),
    pageMs: Number((page > 0 ? page - origin : hookMs).toFixed(1)), hookMs: Number(Number(hookMs).toFixed(1)), extra,
  };
}

// W1c: from the page's own data (rAF stamps since the document started, the hooked GLADIUS_* lines): the marker times,
// every rAF gap over FREEZE_MS from page load (placed before / after / across GLADIUS_CAN_MOVE), the frame statistics
// from CAN_MOVE to the frame-cap probe (or the last frame), and the parsed GLADIUS_T lines. Page clock = ms since
// performance.timeOrigin (about the navigation start).
function stallAnalysis(pg, game) {
  const r1 = (v) => Number(Number(v).toFixed(1));
  const lines = [];
  for (const [t, s] of pg.lines || []) for (const x of String(s).split('\n')) if (x.includes('GLADIUS_')) lines.push([t, x.trim()]);
  const firstAt = (needle) => { const l = lines.find(([, s]) => s.startsWith(needle)); return l ? l[0] : null; };
  const matchStartedMs = firstAt('GLADIUS_MATCH_STARTED');
  const canMoveMs = firstAt('GLADIUS_CAN_MOVE');
  const routeStartMs = game?.page_epoch_ms > 0 ? game.page_epoch_ms - pg.origin : firstAt('GLADIUS_PERF_ROUTE_START');
  const probeMs = game?.probe_page_epoch_ms > 0 ? game.probe_page_epoch_ms - pg.origin : firstAt('GLADIUS_PERF_PROBE');
  const timing = lines.filter(([, s]) => s.startsWith('GLADIUS_T ')).map(([t, s]) => parseTimingLine(s, t, pg.origin)).filter(Boolean);
  const markers = lines.filter(([, s]) => !s.startsWith('GLADIUS_T '))
    .map(([t, s]) => ({ pageMs: r1(t), text: s.length > 120 ? s.slice(0, 120) + ' ...' : s }));
  const f = pg.frames || [];
  // W1c fix pass 1: the action step after the probe (from its camera mark on) is its own phase, reported in
  // `action` and kept out of the after-CAN_MOVE count, so the route's numbers stay comparable with earlier runs.
  const actionAt = timing.find((t) => t.label === 'action.camera' || t.label === 'action.skipped');
  const actionMs = actionAt ? actionAt.pageMs : null;
  const stalls = [];
  for (let i = 1; i < f.length; i++) {
    const dt = f[i] - f[i - 1];
    if (dt <= FREEZE_MS) continue;
    let when = 'unknown (no GLADIUS_CAN_MOVE)';
    if (canMoveMs != null) when = f[i] <= canMoveMs ? 'before_can_move' : f[i - 1] >= canMoveMs ? 'after_can_move' : 'spans_can_move';
    stalls.push({
      startMs: r1(f[i - 1]), endMs: r1(f[i]), ms: Math.round(dt),
      sinceCanMoveMs: canMoveMs != null ? Math.round(f[i - 1] - canMoveMs) : null,
      phase: actionMs != null && f[i] > actionMs ? 'action' : probeMs != null && f[i - 1] >= probeMs ? 'probe'
        : routeStartMs != null && f[i - 1] >= routeStartMs ? 'route'
          : matchStartedMs != null && f[i] > matchStartedMs ? 'match start .. route' : 'boot / menu / match build',
      when,
    });
  }
  const before = stalls.filter((s) => s.when === 'before_can_move');
  const after = stalls.filter((s) => (s.when === 'after_can_move' || s.when === 'spans_can_move') && s.phase !== 'action');
  const longest = (list) => (list.length ? Math.max(...list.map((s) => s.ms)) : null);
  const end = probeMs ?? (f.length ? f[f.length - 1] : 0);
  const win = canMoveMs != null ? f.filter((x) => x >= canMoveMs && x <= end) : [];
  const stats = canMoveMs != null ? frameStats([win]) : null;
  if (stats && win.length > 2) {
    // the mean of the slowest 1 percent of frame deltas (at least one), in ms (frameStats gives it only as rounded fps)
    const d = win.slice(1).map((x, i) => x - win[i]).sort((a, b) => b - a);
    const n = Math.max(1, Math.floor(d.length * 0.01));
    stats.onePercentLowMs = r1(d.slice(0, n).reduce((s, v) => s + v, 0) / n);
  }
  return {
    action: actionWindow(f, timing, game),
    clock: 'page clock: ms since performance.timeOrigin of the game document (about the navigation start); GLADIUS_* times are when the game called console.*, GLADIUS_T pageMs the end of the span',
    pageOrigin: pg.origin,
    matchStartedPageS: matchStartedMs != null ? r1(matchStartedMs / 1000) : null,
    canMovePageS: canMoveMs != null ? r1(canMoveMs / 1000) : null,
    routeStartPageS: routeStartMs != null ? r1(routeStartMs / 1000) : null,
    probeStartPageS: probeMs != null ? r1(probeMs / 1000) : null,
    stallSummary: {
      thresholdMs: FREEZE_MS, total: stalls.length, beforeCanMove: before.length, afterCanMove: after.length,
      spanningCanMove: stalls.filter((s) => s.when === 'spans_can_move').length,
      longestBeforeMs: longest(before), longestAfterMs: longest(after),
      actionPhase: stalls.filter((s) => s.phase === 'action').length,
      note: 'afterCanMove counts gaps that end after GLADIUS_CAN_MOVE (a gap spanning it is the player\'s first frame stalling), up to the action step (its gaps: actionPhase and `action`)',
    },
    afterCanMove: stats ? { window: 'GLADIUS_CAN_MOVE .. frame-cap probe start (or the last frame)', ...stats } : null,
    stalls,
    markers,
    timing,
  };
}

// W1c fix pass 1: the action step (scripts/debug/perf_route.gd, after the probe): the rAF gaps inside GLADIUS_T
// action.start .. action.end, each with the actions (switch / fire / swing : weapon id) whose span it overlaps (an
// action's span runs from its press mark to the next mark), the longest frame in the window (also under 250 ms) and
// per action; plus the camera settle before it (action.camera .. action.start: the match camera drawn again after the
// route camera), reported apart. Page clock as stallAnalysis.
function actionWindow(f, timing, game) {
  const r1 = (v) => Number(Number(v).toFixed(1));
  const at = (label) => { const t = timing.find((x) => x.label === label); return t ? t.pageMs : null; };
  const cam = at('action.camera');
  const start = at('action.start');
  const end = at('action.end');
  const skipped = timing.find((x) => x.label === 'action.skipped');
  if (start == null || end == null) {
    return { ran: false, skipped: skipped ? (skipped.extra.why || 'yes') : (game?.action?.skipped ?? null), game: game?.action ?? null };
  }
  const marks = timing.filter((x) => /^action\.(switch|fire|swing)$/.test(x.label));
  const spans = marks.map((m, i) => ({ action: m.label.slice('action.'.length), weapon: m.extra.weapon || '', fromMs: m.pageMs,
    toMs: i + 1 < marks.length ? marks[i + 1].pageMs : end }));
  const gapsIn = (a, b) => {
    const out = [];
    for (let i = 1; i < f.length; i++) {
      if (f[i] <= a || f[i - 1] >= b) continue;
      out.push({ startMs: r1(f[i - 1]), endMs: r1(f[i]), ms: Math.round(f[i] - f[i - 1]) });
    }
    return out;
  };
  const longestOf = (list) => list.reduce((m, g) => (m && m.ms >= g.ms ? m : g), null);
  const overlaps = (g) => spans.filter((s) => g.startMs < s.toMs && g.endMs > s.fromMs).map((s) => `${s.action}:${s.weapon}`);
  const inWin = gapsIn(start, end);
  const stalls = inWin.filter((g) => g.ms > FREEZE_MS).map((g) => ({ ...g, actions: overlaps(g) }));
  const longest = longestOf(inWin);
  const camGaps = cam != null ? gapsIn(cam, start) : [];
  return {
    ran: true,
    window: 'GLADIUS_T action.start .. action.end (page clock ms)',
    startPageS: r1(start / 1000), endPageS: r1(end / 1000), frames: inWin.length,
    thresholdMs: FREEZE_MS, stallCount: stalls.length, longestStallMs: stalls.length ? Math.max(...stalls.map((s) => s.ms)) : null,
    stalls,
    longestFrame: longest ? { ...longest, actions: overlaps(longest) } : null,
    perAction: spans.map((s) => {
      const g = gapsIn(s.fromMs, s.toMs);
      const l = longestOf(g);
      return { ...s, frames: g.length, longestFrameMs: l ? l.ms : null, stalls: g.filter((x) => x.ms > FREEZE_MS).length };
    }),
    cameraSettle: cam != null ? {
      window: 'action.camera .. action.start: the match camera drawn again after the route camera (not part of the action window)',
      longestFrameMs: longestOf(camGaps)?.ms ?? null, stalls: camGaps.filter((x) => x.ms > FREEZE_MS).length,
    } : null,
    game: game?.action ?? null,
  };
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
  // W1c: page-clock times and the stalls around GLADIUS_CAN_MOVE (tools/web/perf_stalls.mjs attributes them).
  rows.push('', `W1c (profile: ${report.profile?.mode ?? '-'}; page clock = seconds since the game page's timeOrigin; stalls = rAF gaps > ${FREEZE_MS} ms from page load)`, '',
    '| level | profile reused | MATCH_STARTED s | CAN_MOVE s | stalls before CAN_MOVE (longest ms) | stalls after CAN_MOVE (longest ms) | median ms after | 1% low ms (fps) after | trace |',
    '|---|---|---|---|---|---|---|---|---|');
  for (const e of report.levels) {
    const w = e.w1c;
    if (!w) { rows.push(`| ${e.level} | - | - | - | - | - | - | - | - |${e.w1cError ? ' ' + e.w1cError : ''}`); continue; }
    const s = w.stallSummary;
    const a = w.afterCanMove || {};
    rows.push(`| ${e.level} | ${e.profile ? e.profile.existedBefore : '-'} | ${w.matchStartedPageS ?? '-'} | ${w.canMovePageS ?? '-'} | ` +
      `${s.beforeCanMove} (${s.longestBeforeMs ?? '-'}) | ${s.afterCanMove} (${s.longestAfterMs ?? '-'}) | ${a.medianFrameMs ?? '-'} | ` +
      `${a.onePercentLowMs ?? '-'} (${a.onePercentLowFps ?? '-'}) | ${e.trace ? path.basename(e.trace) : '-'} |`);
  }
  // W1c fix pass 1: the action step after the probe (switch / fire / swing through the input actions).
  rows.push('', `W1c action step (after the probe; rAF gaps > ${FREEZE_MS} ms inside action.start .. action.end; warm_skip: ${report.warmSkip ?? '-'})`, '',
    '| level | ran | stalls in window (longest ms) | longest frame ms (actions) | per action: longest frame ms | camera settle longest ms | pawn before |',
    '|---|---|---|---|---|---|---|');
  for (const e of report.levels) {
    const x = e.w1c?.action;
    if (!x) { rows.push(`| ${e.level} | - | - | - | - | - | - |`); continue; }
    const sb = x.game?.state_before || {};
    const pawn = sb.pawn ? `${sb.life} ${sb.drop} hp ${sb.health} shown ${sb.shown}` : '-';
    if (!x.ran) { rows.push(`| ${e.level} | no: ${x.skipped ?? '?'} | - | - | - | - | ${pawn} |`); continue; }
    const per = x.perAction.map((p) => `${p.action}:${p.weapon} ${p.longestFrameMs ?? '-'}`).join('; ');
    rows.push(`| ${e.level} | yes | ${x.stallCount} (${x.longestStallMs ?? '-'}) | ${x.longestFrame?.ms ?? '-'} (${(x.longestFrame?.actions || []).join(', ')}) | ` +
      `${per} | ${x.cameraSettle?.longestFrameMs ?? '-'} | ${pawn} |`);
  }
  return rows.join('\n');
}

main().then((code) => process.exit(code), (e) => { console.error(e); process.exit(1); });
