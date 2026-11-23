# Project Gladius in the browser (W0)

Since Nov 22 2026 the PC web browser (keyboard and mouse) is the only target (docs/DESIGN.md "Platform pivot").
This page says how to export the web build, serve it, run the browser smoke test, and what the browser changes.

## Export

The "Web" preset is appended to `export_presets.cfg` (the Android and iOS presets are unchanged):

- platform Web, single-threaded (`variant/thread_support=false`): no SharedArrayBuffer, so the page needs **no**
  COOP/COEP headers and any static server works.
- `vram_texture_compression/for_desktop=true` (S3TC/BPTC), `for_mobile=false`.
- `include_filter="data/*.json"` (the data files are read at runtime), `exclude_filter="tests/*, tools/*"`.
  `build/` has a `.gdignore`, so nothing under it (logs, probes, earlier exports) is ever packed.
- `html/canvas_resize_policy=2` (adaptive: the canvas fills the tab and follows resizes),
  `html/focus_canvas_on_start=true` (keys reach the game without a first click).
- Renderer: `project.godot` sets `rendering/renderer/rendering_method.web="gl_compatibility"` explicitly (WebGL2);
  desktop and Android keep `mobile`. Compatibility ignores some environment effects; fixing the look is slice W1.

Commands (Godot 4.7.2 with the 4.7.2 export templates installed):

```
godot.cmd --headless --path . --import
godot.cmd --headless --path . --export-debug Web build/web/index.html
```

The export writes `build/web/index.html`, `index.js`, `index.wasm`, `index.pck` and the icons. A release export
(`--export-release Web ...`) ignores every debug URL argument below.

## Serve and play

```
node tools/web/serve.mjs build/web 8060
```

then open http://127.0.0.1:8060/ in Chrome. `tools/web/serve.mjs` uses Node built-ins only, binds 127.0.0.1 only,
sends `application/wasm` for `.wasm` and `application/octet-stream` for `.pck`, and refuses paths outside the root.
Port 0 picks a free port.

## Browser smoke test (gate step)

```
node tools/web/smoke.mjs <out_dir> [--build build/web] [--seconds 60]
```

- Needs puppeteer-core 25.18.1 (Apache-2.0), which is **not** in the repo. It lives in
  `C:\Users\shibi\cc_gladius\webtools` and smoke.mjs loads it from there by absolute path (`--webtools <dir>` to
  change). For reference only, it was installed with `npm install puppeteer-core@25.18.1` inside that folder.
- Uses the installed Chrome (`C:\Program Files\Google\Chrome\Application\chrome.exe`, `--chrome` to change),
  **headed**, with a temporary profile that is deleted afterwards: a real GPU (headless Chrome may fall back to
  SwiftShader and may refuse pointer lock).
- Steps: serve the build on a free port; open the page with no arguments and wait for `GLADIUS_MENU_READY`
  (menu.png); open `?autosolo=1&length=12&wait=6` and wait for `GLADIUS_LOBBY_READY` (lobby.png); wait for
  `GLADIUS_MATCH_STARTED`; screenshot at 5 s (match_5s.png); then scripted input until 60 s: click the canvas
  (pointer lock), W/A/S/D, mouse look, left-click fire, Shift sprint, C crouch on/off, Esc (expects
  `GLADIUS_PAUSE_OPENED`; pause.png), Esc again (expects `GLADIUS_PAUSE_CLOSED`), wait 1.7 s, click to recapture,
  more move/look/fire; match_60s.png at 60 s.
- Writes `<out_dir>/summary.json` and `<out_dir>/console.log` (every console line). The summary holds page errors,
  failed requests and HTTP errors, Godot `ERROR:` / `SCRIPT ERROR:` lines, `WARNING:` lines (recorded, not failing),
  whether and how fast the match started, `document.pointerLockElement` before and after each step, how Esc behaved,
  frame statistics from `requestAnimationFrame` (whole 60 s and with the paused seconds removed), the Chrome version,
  the WebGL renderer string and the viewport. Frame rates are "[measured] this PC, Chrome <version>, not a
  performance claim".
- Allowed Godot error lines: the `ALLOWED_LINES` list in smoke.mjs, which starts empty; every entry needs a
  justification comment there and a mention in the slice report.
- Exit code 0 only when the match started and no page error, failed request, HTTP error or unallowed Godot error
  appeared; 1 otherwise; 2 for bad arguments or a missing build; 3 when the 15-minute hard timeout fired. Chrome and
  the server are always closed.

## Debug-only URL arguments

Read by `scripts/platform/web_args.gd` (`WebArgs`) through `JavaScriptBridge`, and ONLY in a debug build running in the
browser (`OS.is_debug_build()` and the `web` feature tag). Release builds and every other platform ignore the URL.

| Argument | Meaning |
|---|---|
| `autosolo=1` | Play solo straight from the URL: the main menu presses Play solo, the solo lobby presses Start. Taken once per page load (the menu after the match does not restart it). |
| `length=<id>` | A data/br.json `match_length` option id (`12`, `15`, `20`). Unknown or missing: the data default (`15`). Not saved to the profile. |
| `wait=<s>` | Seconds in the lobby before Start (0 to 30; default 0), so a script can screenshot the lobby. |

Console markers for automation, all printed only in a debug web build (`WebArgs.debug_marker`): `GLADIUS_MATCH_STARTED`
(MatchRoot.begin, once the local player exists), `GLADIUS_MENU_READY`, `GLADIUS_LOBBY_READY`, `GLADIUS_PAUSE_OPENED`,
`GLADIUS_PAUSE_CLOSED` and `GLADIUS_PAUSE_PATH key|capture_lost` (which MouseCapture path opened the menu)
(`WebArgs.debug_marker`).

Timing note: the page's main thread stays busy for several seconds after `GLADIUS_MATCH_STARTED` (the rest of the
match setup), so the "5 s" screenshot is taken as soon as the page answers after 5 s; summary.json records the real
seconds after the match start for every screenshot (`screenshotSecondsAfterMatchStart`) and the busy time
(`pageBusyAfterMatchStartSeconds`). The 60 s of input start once the page answers.

## Key map

| Action | Keys / buttons |
|---|---|
| move | W / A / S / D |
| look | mouse (after the click that captures it) |
| fire / aim | left / right mouse button |
| sprint | Shift (hold) |
| jump | Space |
| crouch | C, Ctrl |
| prone | Z (bound only; no behaviour yet) |
| interact (pick up, revive hold) | E |
| cover | F |
| swap shoulder | V |
| reload | R |
| swap weapon | Q, 1, 2, mouse wheel (each toggles; no slot select) |
| pause | Esc |

The full table with the code paths is docs/ARCHITECTURE.md 4.13 "W0: PC keyboard and mouse". The key map is a
guess for Shibi (OQ-WEB-KEYS).

## Browser caveats

- Pointer lock needs a click: the first click in a match captures the mouse (and also fires).
- Esc is the browser's: while the pointer is locked Chrome ends the lock on Esc and may not pass the key to the page.
  The game treats "capture lost" as Esc and opens the pause menu. Esc with the menu open resumes; the next click
  recaptures. Chrome refuses a re-lock right after Esc (about a second), so a too-fast click just asks again.
- Ctrl is the browser's shortcut key: Ctrl+W closes the tab, Ctrl+T / Ctrl+N open new ones; a page cannot block
  them. Crouching on Ctrl while pressing W can close the tab. Crouch on C.
- The build is single-threaded: no COOP/COEP headers, no SharedArrayBuffer. Audio starts after the first click or key
  (browser autoplay rule).
- LAN (Host / Join) is disabled in the browser (ENet does not exist there); the home-network relay is slice W2.
