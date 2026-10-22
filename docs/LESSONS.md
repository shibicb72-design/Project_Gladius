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
