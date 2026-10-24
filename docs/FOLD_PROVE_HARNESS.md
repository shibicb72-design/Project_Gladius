# Fold prove harness: menu false-positive fix

The device harness `build/fold_prove_0070099.py` (git-ignored) scored the Sensitivity settings menu as a
match: `fold_prove_01_rest`, `06_after_look` and `c_final` were Back / Low-Medium-High / Gyro / sliders,
yet the summary said `in_match=true, looks_like_menu=false`.

Fix (harness only, no game code): `tools/fold_prove/fold_prove_detect.py`
- `detect_menu`: pixel chrome (maroon Back block, maroon button rows, near-black bg, gold text) plus optional
  OCR for `Sensitivity`, `Gyro:`, `Invert X/Y`.
- `compute_gates`: a menu rest/scored/final frame forces `in_match=false`, `looks_like_menu=true`, all gates FAIL
  (`FAIL_menu` / `FAIL_no_match_hud`).
- Harness taps Back (`back_button_xy`) until the dual-stick HUD shows before scoring.
- `fold_prove_summary.json` schema v2: `schema_version`, `in_match`, `looks_like_menu`, `menu_frames`,
  `frame_menu`, `frame_menu_reasons`, `dismiss_attempts`.

Match-entry root cause (c1fb249 FAIL_menu): the game never auto-opens Sensitivity. The harness's blind tap sweep
(y=720..960 at x=1092) hit the main-menu "Sensitivity" button; Back there returns to the main menu, never the match.
Fix: `host_button_xy` / `start_button_xy` locate the maroon Host (first band) and Start (middle of bottom row) buttons
from a screenshot and tap each once; `looks_like_match` requires dual-stick knobs; dismiss uses up to 10 Back taps.

Caveats: thresholds are uncalibrated (no Python run in the authoring session). Run
`python tools/fold_prove/test_fold_prove_detect.py`, then re-run the harness on device. Summaries written
before this fix are unreliable.
