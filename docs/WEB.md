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
- The Chrome launcher, the puppeteer-core loader, the WebGL probe and the rAF statistics live in `tools/web/chrome.mjs`
  (W1a), shared with the frame-rate harness; smoke.mjs behaves and exits as before.
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
| `perf=1` | W1a: the frame-rate harness hook (Boot adds `scripts/debug/perf_route.gd`; "Frame-rate harness" below). |
| `quality=<id>` | With perf=1 only: the graphics preset for this page (`default`, `pc_medium`, `pc_high`), applied at boot, not saved. Anything else: the platform's own pick. |
| `seed=<n>` | With perf=1 only: the match seed (a whole non-zero number; anything else is ignored), so loot, bots' seeded streams and the look variant are fixed. |

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

## Look parity with Mobile (W1a)

The browser runs the Compatibility renderer (WebGL 2); the look was authored on Mobile. Compatibility shades in sRGB
space: `source_color` uniforms and light colours reach a shader unconverted, `OUTPUT_IS_SRGB` is true, and a shader's
ALBEDO / EMISSION / sky COLOR is taken as sRGB. Our shaders mix colours in linear (vertex paint through `to_linear`,
contrast, grime and wet factors, the sky's added energies), which drew walls and gates near black, stones in clutter
black, stars and the moon's halo invisible and the glow strips too hot on the web. Each affected shader
(world_surface, soldier_armor, ground, world_foliage, world_cloth, sky_astra) now has, under
`#if CURRENT_RENDERER == RENDERER_COMPATIBILITY` only, a `W1A_LIN()` that turns a `source_color` to linear and a
`W1A_OUT()` (sky: `w1a_to_srgb`) that hands the Mobile-identical result over in sRGB. Mobile and Forward+ compile them
as `(c)`: their output is unchanged (tests/test_w1a_renderer_look.gd pins the Mobile Environment, sky, sun and world
material against tests/fixtures/w1a_mobile_look_golden.json, recorded from base c9b385a).

Per-renderer numbers go in `data/art_look.json` "compatibility" (read only on gl_compatibility; `GreyboxArt.renderer_override`
injects the renderer in tests). It is empty: no W1a fix needed a number (OQ-WEB-GFX-PARITY). AgX works on Compatibility (measured with
`tools/compat_probe.gd`: an unshaded pure red reads (1.0, 0.0, 0.0) with the linear tonemapper and (0.871, 0.251,
0.110) with AgX, Mobile (0.894, 0.231, 0.086)), so the tonemapper stays AgX. Open differences: OQ-WEB-GFX-SKYLIGHT,
OQ-WEB-GFX-GLOW, OQ-WEB-GFX-DISC (docs/OPEN_QUESTIONS.md).

Tools: `tools/parity_capture.gd` (Mobile / Compatibility captures and side-by-side sheets; `--left-dir`, `--right`,
`--env` for before/after and A/B runs; `--quality=<preset id>` captures under that preset, file names
`<view>_<variant>_<renderer>_<quality>.png`) and `tools/compat_probe.gd` (a row of quads per material under ambient, sun,
omni and sky light, printing each renderer's pixel values).

## PC graphics settings (W1a)

A browser (and a desktop build) is a PC (`PlatformServices.is_pc()`, by platform, never by touchscreen; a headless run
is not). On a PC Boot picks the saved Quality, or Auto = High ("pc_high", OQ-WEB-GFX-AUTO); anywhere else the
"default" preset (Low) stays. Settings shows a GRAPHICS section on a PC only: Quality (Auto / Low / Medium / High) and
Frame cap (60 / 120 fps). Field of view, Render scale (50-100 percent) and the 144 / Unlimited caps are built but hidden
until `data/graphics_presets.json` `show_advanced_graphics` is true (OQ-WEB-GFX-ADVANCED). Every value is a placeholder
for Shibi (OQ-WEB-GFX-PRESETS, -SHADOWS, -AA, -FPS, -SCALE; OQ-WEB-FOV; OQ-WEB-FAR).

| Setting / key | Low (default) | Medium (pc_medium) | High (pc_high) | Applies | API |
|---|---|---|---|---|---|
| max_fps (preset) | 60 | 0 | 0 | live | Engine.max_fps |
| frame_cap (profile, PC) | - | 60 default; 60/120 (+144/0) | same | live, replaces max_fps | Engine.max_fps |
| vsync | (project: on) | on | on | live | DisplayServer.window_set_vsync_mode |
| msaa_3d | 0 | 2 | 4 | live | Viewport.msaa_3d |
| anisotropic_level | (project: 4x) | 4 | 8 | live | Viewport.anisotropic_filtering_level |
| directional_shadow_size | (project: 4096) | 2048 | 4096 | live | RenderingServer.directional_shadow_atlas_set_size |
| shadow_mode | (art_astra: orthogonal) | pssm2 | pssm4 | next match | DirectionalLight3D.directional_shadow_mode |
| shadow_max_distance_m | (art_astra: 70) | 120 | 200 | next match | DirectionalLight3D.directional_shadow_max_distance |
| scale_3d | 1.0 | 1.0 | 1.0 | live | Viewport.scaling_3d_scale |
| render_scale (profile, PC) | - | 1.0 default; 0.5-1.0 | same | live, times scale_3d | Viewport.scaling_3d_scale |
| fov (profile, PC) | - | "" (Auto) or 60-95 deg | same | live (CameraRig.GROUP) | CameraRig.base_fov |

In a browser the frame is paced by requestAnimationFrame: vsync cannot be turned off there. Engine.max_fps, measured
by the frame-rate harness's cap probe (below): 30 gave a median frame of 32.9-33.3 ms, 60 and 0 gave 17.4-18.6 ms, the
display's rAF cadence (about 57 Hz on the page) [measured, this PC, Chrome 157.0.8103.80, not a performance claim]. Whether the Compatibility renderer honours each value (MSAA,
anisotropy, PSSM splits, 3D scale) is [unknown] until the parity captures show it.

The rig camera's far plane is `data/camera.json` `far_m` (4000 m, OQ-WEB-FAR): the 1 km map's far hill ring reaches
3922 m from a ground corner (measured; tests/test_w1a_gfx_settings.gd prints `W1A_FAR`), so it cannot be shorter. Depth
precision on WebGL 2's 24-bit buffer is set by the near plane (0.05 m), not the far one [inferred].

## Frame-rate harness (W1a)

Measures the debug web export in the real browser (Compatibility renderer, WebGL 2) along a fixed camera route on
alesia_500, once per quality level. Every number it writes is "[measured] this PC, Chrome <version>, not a performance
claim"; no budget or preset is tuned to it (OQ-WEB-PERF-ROUTE).

```
godot.cmd --headless --path . --import
godot.cmd --headless --path . --export-debug Web build/web/index.html
node tools/web/perf.mjs --out=<file.json> [--levels=default,pc_medium,pc_high] [--seconds=90] [--size=1280x720]
node tools/web/perf.mjs --shots=<dir> [--levels=pc_high] [--seconds=30] [--variants=dusk,night,storm] [--shot-view=porta_aquilae]
```

- Same server, Chrome and puppeteer-core as the smoke test (`serve.mjs`, `chrome.mjs`; `--build`, `--webtools`,
  `--chrome` as there). Headed Chrome, temporary profile (so the profile is the default one: frame cap 60 on a PC).
- Per level it opens `?autosolo=1&length=12&wait=0&perf=1&quality=<id>&seed=<perf_route.json seed>`, injects
  `tools/web/perf_route.json` (scaled to `--seconds`) as `window.GLADIUS_PERF_ROUTE`, waits for `GLADIUS_MATCH_STARTED`
  (300 s) and `GLADIUS_PERF_DONE <json>` (route + probe + 180 s). The match is W0's autosolo solo match: 17 bots at the
  lobby's bot difficulty, the local player idle in the drop; the harness's own camera does not depend on them.
- In the game (`scripts/debug/perf_route.gd`, debug web builds only): after the director runs and 60 warmup frames, the
  route: drop (150 m over the south edge looking north over the town), market (the forum_stall cluster), Porta Aquilae,
  the Arx top; 90 s of route clock (real time, but one frame advances it by at most 0.1 s, so a freeze stalls the camera
  instead of skipping a view; `route_wall_s` is the real duration). Markers: `GLADIUS_PERF_ARMED`,
  `GLADIUS_PERF_ROUTE_START <json>`, `GLADIUS_PERF_VIEW <name>` (a hold begins), `GLADIUS_PERF_PROBE <cap>`,
  `GLADIUS_PERF_DONE <json>` (also `window.GLADIUS_PERF_RESULT`), `GLADIUS_PERF_ERROR <text>`.
- Numbers (game side, real frame deltas from `Time.get_ticks_usec` between consecutive frames): frame count, median
  (middle value; mean of the two middle ones for an even count), p99 (nearest rank), 1 percent low (the MEAN of the
  slowest 1 percent of frames, at least one; also as fps), frames over 33 ms, the longest frame, per-segment medians
  (a delta counts for the segment the camera was in while that frame rendered), every frame over 250 ms with its route
  time, the active preset, Engine.max_fps, the rendering method, the window and content-scale sizes, MSAA, 3D scale.
- Cap probe: after the route, Engine.max_fps = 30, 60, then 0, 0.5 s settle + 5 s each, the median frame time of each;
  then the previous value is restored. It reports what the cap did, it assumes nothing.
- Harness side: the Chrome version, the WebGL renderer string, devicePixelRatio, window and screen size, the display
  refresh (rAF on about:blank for 2 s), seconds from navigation to the match start, the page's own rAF cadence over the
  route (a cross-check) and every rAF gap over 250 ms from the match start (`secondsAfterMatchStart`, phase).
- Output: the `--out` JSON (default `build/perf/perf.json`) with the top-level `label` "this PC, Chrome <version>, not a
  performance claim", one entry per level, `<out>_console.log`, and a markdown table on stdout. Exit 0 only when every
  requested level produced a result; 1 otherwise; 2 bad arguments / missing build; 3 the hard timeout.
- `--shots`: one page per look variant (`variant_seeds` in perf_route.json: dusk 20261123, storm 20261122, night
  20261124; art_look.json picks by seed modulo 5), HUD hidden, a screenshot 1.5 s after `GLADIUS_PERF_VIEW <shot view>`:
  `web_<view>_<variant>.png` plus `shots.json`. Storm lightning is not switched off (a flash may land in the shot).
- Seen on the first runs [measured, this PC, Chrome 157.0.8103.80, not a performance claim]: multi-second single frames
  right after the match start (about 1 s and 2 s at 8-10 s), at the route's first frame (about 10 s, the drop view) and
  on the first flight over the town (about 3 s, three times); the route's later views had none. Cause unknown [inferred:
  first-time shader / pipeline compilation for newly visible materials]; not fixed here.
