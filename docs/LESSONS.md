# Lessons log

## G2b ITERATE, Oct 22 2026

Review of G2b (docs/REVIEW_sprint1.md "## G2b review") found two behaviour changes against 8ffb2da that the G2b tests did not catch.

### 1. Why did the G2b ramp test miss a non-100 class?

1. Why was a class-scaled acceleration shipped? `pawn.gd` used `get_move_speed() / ramp_s` as the rate, so a class with speed_pct != 100 got a different acceleration than the flat 40 m/s^2 at 8ffb2da.
2. Why did no test fail? The ramp test only compared against the 8ffb2da curve for the one pawn it built.
3. Why was that pawn enough to hide it? It was the default class (Hastati, speed_pct 100), so `get_move_speed()` equals `base_speed_mps` and both rate formulas give 40 m/s^2.
4. Why was only the default class driven? The test was written to prove "the ramp matches the old behaviour" and borrowed the existing `_pawn()` helper, which takes no class.
5. Why did nobody add other classes? There was no rule that feel/equivalence tests loop over the enabled classes in data/stats.json, so a single class looked like complete coverage.

### 2. Why did the per-axis to vector ramp change slip through?

1. Why did diagonal movement change? G2b ramped the horizontal velocity as one Vector2 (`Vector2.move_toward`, accel/decel chosen from vector lengths), while 8ffb2da ramped x and z separately.
2. Why did no test fail? The tests only drove straight-line input (forward, sideways, backward).
3. Why are straight lines blind to it? On one axis the vector ramp and the per-axis ramp give identical numbers; they differ only when both axes move at once, or when only one of them reverses or slows.
4. Why was no diagonal input tested? The strafe/back ratio makes the two axes of a diagonal stick reach their targets on different ticks, but the tests were written around the ratio's steady-state value, not the path to it.
5. Why was that not caught in review of the tests? Equivalence with an old formula was checked on the inputs the author thought of, with no rule requiring an input where vector and per-axis forms differ.

### Prevention rule

Ramp/feel equivalence tests must cover every enabled class and a diagonal input.

## G2b2 ITERATE, Oct 22 2026

Review of G2b2 (docs/REVIEW_sprint1.md "## G2b2 review", M1/M2) found that the test-completion flag specified in G2b2.txt item 4 cannot catch runtime script errors: in Godot 4.7.2 a script error aborts only the called test body, the awaiting caller resumes, and `completed` is still set true. The script-error logger was the real guard all along.

### Why was the completion flag specified without checking Godot's runtime error semantics?

1. Why did the flag not work? `run_test` does `await call(method)` then `completed = true`; an aborted awaited call returns to the caller, so the line after the await still runs.
2. Why was it specified that way? The spec assumed an erroring test body would never return to its caller, so "returned" would equal "ran to the end".
3. Why was that assumed? It matches how exceptions behave in many languages, and nobody ran a test body that errors to see what Godot does.
4. Why did nobody probe it? The spec was written as a design guard, not as an experiment, and a probe (one fixture with a null call) looked unnecessary for something that felt obvious.
5. Why did review not catch it? BOTH the spec author (Android Lead) and the approver (Engineering Lead) assumed the semantics without a probe; the approval checked the logic against the assumption, not the assumption against the engine.

### Prevention rule

Verify an engine's error semantics with a probe before specifying a guard.

## GBTN ITERATE, Oct 22 2026

**Problem:** GBTN.txt item 4 asked for "the tracer/muzzle node becomes visible". The test asserted `tracer.visible`, it passed, and the Fold screenshot (buttons_fire_cover_landscape.png) showed no tracer.

**5 Whys**

1. Why did the shot show nothing although the test passed? The tracer node was `visible` and correctly placed (GBTN2 measurement: 116 px long on screen at 2520x1080), but it was drawn behind the pawn capsule, which hid its whole screen span.
2. Why was it hidden? In the third-person view the tracer runs almost along the camera axis, starting beside the pawn and heading past it, and its material was depth-tested, so the closer body occluded it.
3. Why did the test not notice? It asserted a node property (`visible`), which says "the engine may draw this", not "a player can see this". Nothing projected the segment to the screen or checked occlusion.
4. Why was a node property accepted as proof? The item text named the node ("becomes visible"), and the test mirrored the wording of the requirement instead of the player-facing outcome (a readable line on screen).
5. Why did review not catch it? The reviewer read the test against the item text, which matched, and the screenshot was produced but not compared against the claim until the ITERATE review looked at the pixels.

**Fix:** the tracer and flash draw on top (data/ui.json `shot_fx.tracer_draw_on_top`), and tests/test_tracer_visibility.gd projects both endpoints with `Camera3D.unproject_position` and asserts the pixel length is above `tracer_min_screen_px`.

### Prevention rule

Visual feedback tests assert on-screen projection/size, not just visible.
