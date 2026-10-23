# Jolt physics switch (G1)

`project.godot` `[physics] 3d/physics_engine="Jolt Physics"` (built into Godot 4.7.2; no plugin, no GDExtension, so
the same engine runs on Android and iOS).

Before this change the key was **absent** from `project.godot` (unset). Unset is not a baseline
(`docs/engine-reference/godot/breaking-changes.md:50`: Jolt is the default for new projects), so the baseline
below was measured with the key explicitly set to `"GodotPhysics3D"`. What the unset key resolved to in 4.7.2 was not measured.

## Movement: GodotPhysics3D vs Jolt

Measured by `tests/test_physics_baseline.gd` on the test map (`scenes/test/weapon_range.tscn` plus a course of step
boxes and ramps built by the test). The pawn is driven with `InputFrame`s through `Pawn.set_frame` (the output of
`scripts/input/`) at the fixed 60 Hz physics tick, using `data/stats.json` `movement` (`base_speed_mps` 5.0,
`jump_velocity` 7.0, `gravity` 20.0) and the pawn's default `floor_max_angle` (45 deg). Nothing is estimated.

| Metric | GodotPhysics3D | Jolt | % diff |
|---|---|---|---|
| Walk speed, steady state (m/s) | 5.000005 | 5.000005 | 0.00 |
| Jump apex height (m) | 1.284160 | 1.284204 | 0.003 |
| Jump to land time (s) | 0.716667 | 0.716667 | 0.00 |
| Largest step-up that passes (m) | 0.12 | 0.12 | 0.00 |
| Largest slope angle that passes (deg) | 45.5 | 45.5 | 0.00 |

Walk speed update (G2c): Shibi asked on Oct 22 2026 for +5-10% walk speed, so `base_speed_mps` became 5.375 (+7.5%) and the baseline `walk_speed_mps` line was re-measured as 5.37500381469727; every other metric is unchanged. (The table above is the original G1 comparison at 5.0 m/s.)

All differences are far below 5%, so no code or data change was needed (no `floor_snap_length`, `safe_margin`,
collision-shape or step-logic edits). The pawn has no step-up logic: the 0.12 m step is the capsule's rounded
bottom riding over a lip (about `0.4 * (1 - cos 45)` = 0.117 m). Step heights are swept at 0.005 m up to 0.20 m and
slopes at 0.5 to 2 deg, so those two figures are quantised to that resolution.

The baseline lives in `data/physics_baseline.json` (`tolerance_pct` 5.0; the test also asserts it never exceeds 5).
`tests/test_physics_baseline.gd` asserts Jolt stays within it, and that the engine setting is `"Jolt Physics"`.
Run `godot --headless --path . --script res://tests/run_tests.gd -- --only=test_physics_baseline` to see the
measured numbers (`PHYSICS_METRICS` line).

## Breaking-change audit (`docs/engine-reference/godot/breaking-changes.md`)

| Change | Ours |
|---|---|
| `:25` `WorldBoundaryShape3D` plane sign | None in `scenes/` or `scripts/` (grep for `WorldBoundary`: no matches). The floor is a `BoxShape3D` (`scenes/test/weapon_range.tscn:6-7`). |
| `:26` `SoftBody3D` mass and stiffness | None (grep for `SoftBody`: no matches). |
| `:27` `Area3D` now reports `SoftBody3D` overlaps | No `SoftBody3D`, so no effect. Head hitbox `scenes/player/pawn.tscn:33-36`: layer 4, mask 0 (detects nothing; it is only ever hit by rays, `scripts/weapons/hitscan.gd:25,30`). Hill `scripts/systems/hill_zone.gd:9-10`: layer 0, mask 2 (pawn bodies only). Pinned by `test_head_and_hill_area_layers`. |
| `:50` `HingeJoint3D` `damp` only on GodotPhysics | None (grep for `HingeJoint`: no matches). |

## Collision, hitscan and area tests (`tests/test_physics_collisions.gd`, all pass on Jolt)

Wall stops a walking pawn; pawns do not block each other (current layout, `scenes/player/pawn.tscn:21-22`: pawn mask is
the world layer only); `Hitscan.cast` hits the body (not a headshot), the head `Area3D` (headshot), the world
only (floor), misses upward, and excludes the shooter's own body and head; `HillZone.occupancy()` counts a pawn
inside, drops it when inactive, ignores it outside.

## Screenshots

`build/shots/` (not committed) from `tools/touch_capture.tscn` at the Galaxy Z Fold 7 sizes: `cover_*.png` 2520x1080 (dpi 420) and
`inner_*.png` 2184x1968 (dpi 373), each lobby before/after and HUD rest/walk/look. The game is landscape-only
(`project.godot` `window/handheld/orientation=4`), so no portrait captures were taken.
