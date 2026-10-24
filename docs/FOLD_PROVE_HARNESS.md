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

Magenta sky is not fail-clear (P3, 24ed9ca): exact (255,0,255) is the intentional Fold sky/clear colour.
`camera_fail_magenta` is now true only when magenta dominates (>10000 px) AND no pawn colour is visible
(orange and yellow both < 800 px). Magenta without a pawn is still a camera fail.

Move world_FAIL (P3, 24ed9ca, move_center_world_pct 0.8): the game input path works; the held frame was captured
early. `input swipe` interpolates linearly over its 2.2 s, and the capture landed with the knob ~61 px (~0.26 of
the 236 px radius) from its origin, which is ~0.18 speed after the 0.1 radial dead zone; the wall edge moved ~3 px. In
`04_after_move` (after the full swipe) the walls had visibly shifted (~100 px), so the pawn does move. Fix
(harness only): press and HOLD the stick at 0.8 radius straight forward with `input motionevent` (`move_hold_target`)
for 1.5 s before the capture. 0.8 is below the default sprint threshold of 0.84. The summary also records
`move_after_center_world_pct` as a diagnostic.
`tools/fold_prove/measure_move.py` recomputes the center deltas and knob positions from a run's PNGs.

Caveats: thresholds are uncalibrated (no Python run in the authoring session). Run
`python tools/fold_prove/test_fold_prove_detect.py`, then re-run the harness on device. Summaries written
before this fix are unreliable.
