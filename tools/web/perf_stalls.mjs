// W1c step 1: the stall analyser (docs/WEB.md "Stall timing (W1c)"). Reads a perf.mjs run JSON (levels[].w1c: every
// rAF gap over 250 ms from page load, the markers and the game's GLADIUS_T phase lines, all on the page clock) and,
// when there is one, the level's Chrome trace (perf.mjs --trace), and prints one markdown table row per stall: start,
// duration, the GLADIUS_T phases and frame lines overlapping it, and from the trace the time inside the stall spent in
// GPU program compile/link, texture uploads, V8 GC, wasm compile, image decode, the renderer waiting on the GPU
// process, and script, with the top event names as evidence.
//
//   node tools/web/perf_stalls.mjs <run.json> [--trace=<trace.json>] [--level=<id>] [--out=<file.md>] [--top=5]
//
// --trace overrides the level's recorded trace (use with --level when the run had several levels). The trace is read
// as a stream (it may be hundreds of MB). Clock: the trace's user-timing events "GT:<label>" (the game's
// performance.measure / mark, scripts/debug/perf_marks.gd) are matched to the GLADIUS_T lines' page= times; the
// median difference maps trace microseconds to the page clock. The "cause" column is a rule over the measured
// buckets (the largest named bucket covering at least CAUSE_SHARE of the stall wins), so it is [inferred from the
// trace]; without a trace it falls back to the game's own frame line (cpu vs draw) and says so.
import fs from 'node:fs';
import path from 'node:path';
import { StringDecoder } from 'node:string_decoder';

const CAUSE_SHARE = 0.3;

// Bucket rules over trace event names (case-insensitive). Order matters only for display.
const BUCKETS = [
  ['shader', /(compile|link)(shader|program)|executabletask|compileevent|linkloadevent|linktaskd3d|program::link|programd3d|shaderd3d|d3dcompile|hlsl|shadertranslat|translateshader|translator|glslang|programbinary|getprogramparameter|getprogramiv|getshaderparameter|getshaderiv|programcache|shadercache|compiletask|linktask|linkprogram|compileshader/i],
  ['texture', /tex(sub)?image|texstorage|compressedtex|textureupload|uploadtexture|texture.*upload|copytex|generatemipmap/i],
  ['gc', /v8\.gc|majorgc|minorgc|scavenge|markcompact|blinkgc|cppgc|gcevent|garbage/i],
  ['wasm', /wasm/i],
  ['decode', /decode(image|lazypixelref|task)|imagedecode|imageframegenerator/i],
  ['gpu_wait', /waitforgetoffset|waitfortoken|commandbufferproxyimpl::(finish|waitfor)|gpuchannelhost::send|synccall|syncipc|readpixels|glfinish|waitsynctoken/i],
  ['script', /^(functioncall|v8\.callfunction|fireanimationframe|evaluatescript|v8\.run|v8\.execute|runmicrotasks|timerfire|v8\.compile|v8\.parse)/i],
  ['task', /^(threadcontrollerimpl::runtask|runtask|sequencemanager|messageloop::runtask|scheduler::|toplevel)/i],
];
// Generic wrappers left out of the "top names" evidence (they contain everything else).
const WRAPPERS = /^(threadcontrollerimpl::runtask|runtask|functioncall|v8\.callfunction|fireanimationframe|evaluatescript|v8\.run|v8\.execute|sequencemanager|toplevel|scheduler|parsehtml|animation frame fired|commandbufferstub::onmessagereceived|gpuchannel::handlemessage|ipc|mojo|simplewatcher|receive mojo|asynctask run|webframewidgetimpl::beginmainframe|blink\.animate|pageanimator::|framerequestcallbackcollection::|threadpool_runtask|angleplatformimpl::runworkertask|waitforvsync|scheduledtask|proxymain::|layertreehost|cc::|viz\.|display::|graphics\.pipeline)/i;

function parseArgs(argv) {
  const out = { run: '', trace: '', level: '', out: '', top: 5 };
  for (const a of argv) {
    const m = /^--([a-z-]+)=(.*)$/.exec(a);
    if (!m) { if (!out.run && !a.startsWith('--')) { out.run = a; continue; } throw new Error(`unknown argument ${a}`); }
    const [, k, v] = m;
    if (k === 'trace') out.trace = v;
    else if (k === 'level') out.level = v;
    else if (k === 'out') out.out = v;
    else if (k === 'top') out.top = Math.max(1, Number(v) || 5);
    else throw new Error(`unknown argument --${k}`);
  }
  if (!out.run) throw new Error('usage: node tools/web/perf_stalls.mjs <run.json> [--trace=<file>] [--level=<id>] [--out=<file.md>] [--top=5]');
  return out;
}

// Streams the trace's event objects (the JSON object format {"traceEvents":[...]} or a bare array) to onEvent.
function readTraceEvents(file, onEvent) {
  const fd = fs.openSync(file, 'r');
  const dec = new StringDecoder('utf8');
  const buf = Buffer.alloc(1 << 24);
  const stack = [];
  let inStr = false;
  let esc = false;
  let capturing = false;
  let pieces = [];
  let eventDepth = -1;
  try {
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, null);
      if (!n) break;
      const s = dec.write(buf.subarray(0, n));
      let start = capturing ? 0 : -1;
      for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (inStr) {
          if (esc) esc = false;
          else if (c === 92) esc = true;
          else if (c === 34) inStr = false;
          continue;
        }
        if (c === 34) { inStr = true; continue; }
        if (c === 123 || c === 91) {
          if (eventDepth < 0) eventDepth = c === 91 ? 1 : 2;  // bare array: events at depth 1
          if (c === 123 && !capturing && stack.length === eventDepth && stack[stack.length - 1] === 91) {
            capturing = true;
            start = i;
            pieces = [];
          }
          stack.push(c);
        } else if (c === 125 || c === 93) {
          stack.pop();
          if (c === 125 && capturing && stack.length === eventDepth) {
            pieces.push(s.slice(start, i + 1));
            capturing = false;
            start = -1;
            const text = pieces.join('');
            pieces = [];
            let ev = null;
            try { ev = JSON.parse(text); } catch { /* a truncated last event */ }
            if (ev) onEvent(ev);
          }
        }
      }
      if (capturing) pieces.push(s.slice(start));
    }
  } finally {
    fs.closeSync(fd);
  }
}

const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
};

// Union length (ms) of [a, b] intervals.
function unionMs(intervals) {
  if (!intervals.length) return 0;
  const s = [...intervals].sort((x, y) => x[0] - y[0]);
  let total = 0;
  let [a, b] = s[0];
  for (let i = 1; i < s.length; i++) {
    if (s[i][0] <= b) b = Math.max(b, s[i][1]);
    else { total += b - a; [a, b] = s[i]; }
  }
  return total + (b - a);
}

// Pass 1: process / thread names and the user-timing events; the trace->page clock offset (ms).
function traceClock(file, timing) {
  const procs = {};
  const threads = {};
  const ut = {}; // name -> [{ts, ph, pid}]
  let docStart = null;
  readTraceEvents(file, (ev) => {
    if (ev.ph === 'M') {
      if (ev.name === 'process_name') procs[ev.pid] = ev.args?.name;
      else if (ev.name === 'thread_name') threads[`${ev.pid}:${ev.tid}`] = ev.args?.name;
      return;
    }
    if (typeof ev.cat === 'string' && ev.cat.includes('blink.user_timing') && typeof ev.name === 'string') {
      if (ev.name === 'gladius_doc_start') docStart = { ts: ev.ts, pid: ev.pid };
      if (!ev.name.startsWith('GT:')) return;
      // a measure ends with its 'e' event (ts = end); a mark is one 'R' / 'I' / 'n' event
      if (ev.ph === 'e' || ev.ph === 'E' || ev.ph === 'R' || ev.ph === 'I' || ev.ph === 'n' || ev.ph === 'i') {
        (ut[ev.name] ||= []).push({ ts: ev.ts, pid: ev.pid });
      }
    }
  });
  // Pair the GLADIUS_T lines (page clock) with the trace events of the same label, in order, where the counts agree.
  const byLabel = {};
  for (const t of timing) (byLabel[`GT:${t.label}`] ||= []).push(t);
  const diffs = [];
  let rendererPid = null;
  for (const [name, lines] of Object.entries(byLabel)) {
    const evs = (ut[name] || []).sort((a, b) => a.ts - b.ts);
    if (!evs.length || evs.length !== lines.length) continue;
    for (let i = 0; i < evs.length; i++) {
      diffs.push(evs[i].ts / 1000 - lines[i].pageMs);
      rendererPid = evs[i].pid;
    }
  }
  let offsetMs = median(diffs);
  let source = `median of ${diffs.length} GT:<label> user-timing events matched to GLADIUS_T page= times`;
  let spreadMs = diffs.length ? Math.max(...diffs) - Math.min(...diffs) : null;
  if (offsetMs == null && docStart) {
    offsetMs = docStart.ts / 1000;
    rendererPid = docStart.pid;
    source = 'gladius_doc_start mark taken as page time 0 (no GT events matched; about +-few ms)';
    spreadMs = null;
  }
  return { procs, threads, offsetMs, source, spreadMs, rendererPid };
}

function threadRole(clock, pid, tid) {
  const tname = clock.threads[`${pid}:${tid}`] || '';
  const pname = clock.procs[pid] || '';
  if (pid === clock.rendererPid && tname === 'CrRendererMain') return 'renderer main';
  if (pid === clock.rendererPid) return `renderer ${tname || tid}`;
  if (/gpu/i.test(pname)) return tname === 'CrGpuMain' ? 'gpu main' : `gpu ${tname || tid}`;
  return `${pname || pid} ${tname || tid}`;
}

// Pass 2: every duration event overlapping a stall window, clipped into per-stall buckets and names.
function traceStalls(file, clock, stalls) {
  const acc = stalls.map(() => ({ buckets: {}, names: {}, via: {}, links: 0, compiles: 0, longestLinkMs: 0, linkTimes: [] }));
  const windows = stalls.map((s) => [s.startMs, s.endMs]);
  const open = {}; // pid:tid -> stack of B events
  const add = (name, cat, pid, tid, ts, dur) => {
    const a = ts / 1000 - clock.offsetMs;
    const b = a + dur / 1000;
    for (let i = 0; i < windows.length; i++) {
      const [w0, w1] = windows[i];
      if (b <= w0 || a >= w1) continue;
      const lo = Math.max(a, w0);
      const hi = Math.min(b, w1);
      const role = threadRole(clock, pid, tid);
      const key = `${role}|${name}`;
      if (a >= w0) {  // counted where it starts
        if (/DoLinkProgram/.test(name)) {
          acc[i].links += 1;
          acc[i].longestLinkMs = Math.max(acc[i].longestLinkMs, dur / 1000);
          if (acc[i].linkTimes.length < 20) acc[i].linkTimes.push(Number((a / 1000).toFixed(2)));
        } else if (name === 'D3DCompile') acc[i].compiles += 1;
      }
      acc[i].names[key] = (acc[i].names[key] || 0) + (hi - lo);
      for (const [bucket, re] of BUCKETS) {
        if (re.test(name)) {
          const bk = `${bucket}|${role.startsWith('gpu') ? 'gpu' : role}`;
          (acc[i].buckets[bk] ||= []).push([lo, hi]);
          const via = (acc[i].via[bucket] ||= {});
          via[key] = (via[key] || 0) + (hi - lo);
        }
      }
    }
  };
  readTraceEvents(file, (ev) => {
    if (typeof ev.name !== 'string' || typeof ev.ts !== 'number') return;
    if (ev.ph === 'X') { if (ev.dur > 0) add(ev.name, ev.cat, ev.pid, ev.tid, ev.ts, ev.dur); return; }
    const k = `${ev.pid}:${ev.tid}`;
    if (ev.ph === 'B') (open[k] ||= []).push(ev);
    else if (ev.ph === 'E') {
      const b = open[k]?.pop();
      if (b) add(b.name, b.cat, b.pid, b.tid, b.ts, ev.ts - b.ts);
    }
  });
  return acc.map((x) => {
    const buckets = {};
    for (const [k, list] of Object.entries(x.buckets)) buckets[k] = unionMs(list);
    return { buckets, names: x.names, via: x.via, links: x.links, compiles: x.compiles, longestLinkMs: x.longestLinkMs, linkTimes: x.linkTimes };
  });
}

const fmt = (ms) => `${Math.round(ms)}`;

function causeFromTrace(stall, t, top) {
  const b = t.buckets;
  const get = (k) => b[k] || 0;
  const gpuShader = get('shader|gpu');
  const rendShader = get('shader|renderer main');
  const named = [
    ['GPU program compile/link', Math.max(gpuShader, rendShader)],
    ['texture upload', Math.max(get('texture|gpu'), get('texture|renderer main'))],
    ['V8 GC', get('gc|renderer main')],
    ['wasm compile', get('wasm|renderer main')],
    ['image decode', Math.max(get('decode|renderer main'), get('decode|renderer Compositor'))],
  ].sort((x, y) => y[1] - x[1]);
  const wait = get('gpu_wait|renderer main');
  const script = get('script|renderer main');
  const rendBusy = get('task|renderer main');
  const gpuBusy = get('task|gpu');
  let cause;
  if (named[0][1] >= CAUSE_SHARE * stall.ms) cause = `${named[0][0]} [inferred from trace]`;
  else if (wait >= CAUSE_SHARE * stall.ms) cause = 'renderer blocked on the GPU process (sync wait); GPU work not named by the rules [inferred from trace]';
  else if (script >= 0.5 * stall.ms) cause = 'script / wasm on the main thread (Godot main loop; see phases) [inferred from trace]';
  else cause = 'unattributed by the trace rules [unknown]';
  const names = Object.entries(t.names)
    .filter(([k]) => !WRAPPERS.test(k.split('|')[1]))
    .sort((x, y) => y[1] - x[1]).slice(0, top)
    .map(([k, ms]) => { const [role, name] = k.split('|'); return `${name} (${role}) ${fmt(ms)}`; });
  const ev = `programs linked ${t.links} (GLES2DecoderPassthroughImpl::DoLinkProgram), D3DCompile ${t.compiles}; trace ms: shader gpu ${fmt(gpuShader)} / renderer ${fmt(rendShader)}, texture ${fmt(named.find((n) => n[0] === 'texture upload')[1])}, ` +
    `gc ${fmt(get('gc|renderer main'))}, wasm ${fmt(get('wasm|renderer main'))}, decode ${fmt(named.find((n) => n[0] === 'image decode')[1])}, ` +
    `renderer waits on GPU ${fmt(wait)}, script ${fmt(script)}, renderer busy ${fmt(rendBusy)}, gpu busy ${fmt(gpuBusy)}; top: ${names.join('; ') || '-'}`;
  // Which events fed the buckets that decide the cause (summed per name, nested events counted again).
  const via = ['shader', 'texture', 'gc', 'gpu_wait'].map((bucket) => {
    const list = Object.entries(t.via[bucket] || {}).sort((x, y) => y[1] - x[1]).slice(0, 2)
      .map(([k, ms]) => { const [role, name] = k.split('|'); return `${name} (${role}) ${fmt(ms)}`; });
    return list.length ? `${bucket} via ${list.join(', ')}` : '';
  }).filter(Boolean);
  return { cause, evidence: via.length ? `${ev}; ${via.join('; ')}` : ev };
}

function overlapping(timing, stall) {
  const phases = [];
  const frames = [];
  for (const t of timing) {
    if (t.durMs == null) {
      if (t.pageMs >= stall.startMs && t.pageMs <= stall.endMs) phases.push(`${t.label}@${(t.pageMs / 1000).toFixed(2)}s`);
      continue;
    }
    const a = t.pageMs - t.durMs;
    const b = t.pageMs;
    if (b <= stall.startMs || a >= stall.endMs) continue;
    if (t.label === 'frame') frames.push(t);
    else phases.push(`${t.label} ${fmt(t.durMs)}`);
  }
  return { phases, frames };
}

function causeFromFrames(stall, frames) {
  if (!frames.length) return { cause: 'no trace and no game frame line overlaps [unknown]', evidence: '' };
  // The game frame that ENDED inside the stall is the one that made it (a long earlier frame may only touch its start).
  const near = (t) => Math.abs(t.pageMs - stall.endMs);
  const f = frames.reduce((x, y) => (near(y) < near(x) ? y : x));
  const cpu = Number(f.extra.cpu || 0);
  const draw = Number(f.extra.draw || 0);
  const cause = draw >= cpu
    ? 'renderer draw (GL calls: first-use shader compile or texture upload; not separable without a trace) [inferred]'
    : 'CPU before the draw (scripts / scene build; see phases) [inferred]';
  return { cause, evidence: `game frame ${fmt(f.durMs)} ms: cpu ${fmt(cpu)}, draw ${fmt(draw)}` };
}

function analyseLevel(entry, tracePath, top) {
  const w = entry.w1c;
  if (!w) return { header: `## ${entry.level}: no w1c data (${entry.w1cError || entry.failure || 'old run JSON?'})`, rows: [], clock: null };
  const stalls = w.stalls || [];
  let traced = null;
  let clock = null;
  let afterLinks = null;
  if (tracePath && fs.existsSync(tracePath)) {
    clock = traceClock(tracePath, w.timing || []);
    if (clock.offsetMs != null) {
      // W1c commit 2: one more window, CAN_MOVE to the end of the trace: every program linked after the player can act,
      // stall or not.
      const extra = w.canMovePageS != null ? [{ startMs: w.canMovePageS * 1000, endMs: Number.MAX_SAFE_INTEGER }] : [];
      const all = traceStalls(tracePath, clock, stalls.concat(extra));
      traced = all.slice(0, stalls.length);
      if (extra.length) afterLinks = all[stalls.length];
    }
  }
  const rows = stalls.map((s, i) => {
    const { phases, frames } = overlapping(w.timing || [], s);
    const fromFrames = causeFromFrames(s, frames);
    const c = traced ? causeFromTrace(s, traced[i], top) : fromFrames;
    const evidence = [c.evidence, traced ? fromFrames.evidence : '', phases.length ? `phases: ${phases.join(', ')}` : '']
      .filter(Boolean).join(' | ');
    return `| ${i + 1} | ${(s.startMs / 1000).toFixed(2)} | ${s.sinceCanMoveMs != null ? (s.sinceCanMoveMs / 1000).toFixed(2) : '-'} | ${s.ms} | ${s.when} / ${s.phase} | ${c.cause} | ${evidence.replace(/\|/g, '/')} |`;
  });
  const sum = w.stallSummary || {};
  const after = w.afterCanMove || {};
  const header = [
    `## ${entry.level} (profile ${entry.profile ? (entry.profile.existedBefore ? 'reused' : 'new') : 'temporary/shared'})`,
    '',
    `[measured] page clock (s since the game page's timeOrigin): GLADIUS_MATCH_STARTED ${w.matchStartedPageS ?? '-'}, GLADIUS_CAN_MOVE ${w.canMovePageS ?? '-'}, route start ${w.routeStartPageS ?? '-'}; ` +
      `rAF gaps > ${sum.thresholdMs} ms: ${sum.beforeCanMove} before CAN_MOVE (longest ${sum.longestBeforeMs ?? '-'} ms), ${sum.afterCanMove} after (longest ${sum.longestAfterMs ?? '-'} ms); ` +
      `after CAN_MOVE median ${after.medianFrameMs ?? '-'} ms, 1% low ${after.onePercentLowMs ?? '-'} ms (${after.onePercentLowFps ?? '-'} fps).`,
    traced ? `Trace ${path.basename(tracePath)}: clock = ${clock.source}${clock.spreadMs != null ? `, spread ${clock.spreadMs.toFixed(1)} ms` : ''}. ` +
      'Texture uploads have no named event in these categories (a 0 is "not seen", not "none"); their upper bound is the stall minus the named buckets.'
      : tracePath ? `Trace ${tracePath}: ${fs.existsSync(tracePath) ? 'no clock match (no GT events)' : 'missing'}; causes from the game frame lines only.`
        : 'No trace: causes from the game frame lines only.',
    afterLinks ? `[measured] From CAN_MOVE to the end of the trace: programs linked ${afterLinks.links} (longest link ${fmt(afterLinks.longestLinkMs)} ms` +
      `${afterLinks.linkTimes.length ? `; at page s ${afterLinks.linkTimes.join(', ')}` : ''}), D3DCompile ${afterLinks.compiles}.` : '',
    '',
    '| # | start s | vs CAN_MOVE s | duration ms | when / phase | cause | evidence |',
    '|---|---|---|---|---|---|---|',
  ].join('\n');
  return { header, rows, clock };
}

function main() {
  let args;
  try { args = parseArgs(process.argv.slice(2)); } catch (e) { console.error(e.message); return 2; }
  let report;
  try { report = JSON.parse(fs.readFileSync(args.run, 'utf8')); } catch (e) { console.error(`cannot read ${args.run}: ${e.message}`); return 2; }
  const levels = (report.levels || []).filter((e) => !args.level || e.level === args.level);
  if (!levels.length) { console.error('no matching level in the run JSON'); return 2; }
  const out = [`# W1c stall table (${report.label || 'this PC'}; profile mode ${report.profile?.mode ?? '-'}; run ${path.basename(args.run)})`, ''];
  for (const e of levels) {
    const tracePath = args.trace || e.trace || '';
    const r = analyseLevel(e, tracePath, args.top);
    out.push(r.header, ...r.rows, '');
  }
  const text = out.join('\n');
  console.log(text);
  if (args.out) {
    fs.mkdirSync(path.dirname(path.resolve(args.out)), { recursive: true });
    fs.writeFileSync(args.out, text + '\n');
  }
  return 0;
}

process.exit(main());
