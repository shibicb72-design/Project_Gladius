// W0 / W1a: the Chrome side shared by the browser harnesses (smoke.mjs, perf.mjs; docs/WEB.md). Loads puppeteer-core
// from the webtools folder (NOT in the repo), launches the installed Chrome HEADED with a temporary profile (a real GPU;
// headless Chrome may fall back to SwiftShader and refuse pointer lock), reads the WebGL renderer string, and computes
// frame statistics from requestAnimationFrame timestamps. The static server is serve.mjs (startServer).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

export const DEFAULT_WEBTOOLS = 'C:\\Users\\shibi\\cc_gladius\\webtools';
export const DEFAULT_CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// puppeteer-core (Apache-2.0) by absolute path from the webtools folder.
export function loadPuppeteer(webtools) {
  const requireFromWebtools = createRequire(path.join(webtools, 'package.json'));
  const pptrModule = requireFromWebtools('puppeteer-core');
  return pptrModule.default ?? pptrModule;
}

// A fresh temporary Chrome profile directory (removed by removeProfile).
export function makeProfileDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

export async function removeProfile(profileDir) {
  for (let i = 0; i < 10; i++) {
    try { fs.rmSync(profileDir, { recursive: true, force: true }); break; } catch { await sleep(500); }
  }
}

// The installed Chrome, headed, temporary profile, background throttling off (W0's flags).
export function launchChrome(puppeteer, { chrome, profileDir, viewport }) {
  return puppeteer.launch({
    executablePath: chrome,
    headless: false,
    userDataDir: profileDir,
    defaultViewport: viewport,
    protocolTimeout: 120000,
    args: [
      `--window-size=${viewport.width + 40},${viewport.height + 180}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-timer-throttling',
      '--disable-renderer-backgrounding',
      '--disable-backgrounding-occluded-windows',
    ],
  });
}

// "<vendor> | <renderer>" from a throwaway webgl2 canvas (WEBGL_debug_renderer_info when Chrome exposes it).
export function webglRenderer(page) {
  return page.evaluate(() => {
    const c = document.createElement('canvas');
    const gl = c.getContext('webgl2');
    if (!gl) return 'no webgl2 context';
    const ext = gl.getExtension('WEBGL_debug_renderer_info');
    const r = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    const v = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
    return `${v} | ${r}`;
  });
}

// ---- frame statistics from requestAnimationFrame timestamps (ms) ----
// `segments` is an array of timestamp arrays; frame deltas are taken inside each segment only (a removed pause adds
// no delta), and the seconds are the sum of the segment spans.
export function frameStats(segments) {
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
