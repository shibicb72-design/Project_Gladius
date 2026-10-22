# Sprint 1 plan: Milestone 1 FIRST PLAYABLE

Source: docs/DESIGN.md "Milestones" item 1 only: rough Alesia section, fixed hill, Pilum BR + Gladius Lux,
Hastati + Sagittarii, a few bots, touch + controller, hotspot. Nothing from later milestones.
System design: docs/ARCHITECTURE.md. Gaps and placeholders: docs/OPEN_QUESTIONS.md (OQ-xx / T-xx ids).

Each story is sized for one Sonnet session (at most 50 turns, $2.50). Stories run in order; each one
leaves the project importable, exportable and green.

## Definition of done (applies to every story)

Run from the repo root, each as a separate command:

1. `mkdir -p build`
2. `godot --headless --path . --import`
3. `godot --headless --path . --export-debug "Android" build/gladius-debug.apk`
4. `godot --headless --path . --script res://tests/run_tests.gd`

Passes only if every command exits 0, there are no `SCRIPT ERROR`, `Parse Error` or `ERROR:` lines
caused by project files, and Glob finds `build/gladius-debug.apk`. Also:

- `git status` shows only intended files; nothing under build/ or .godot/, no APK/AAB/keys
  except android/debug.keystore.
- New tunable numbers live in data/*.json. Placeholders carry `"_placeholder": true` and a
  `"_todo": "OQ-xx"` that points at docs/OPEN_QUESTIONS.md.
- Rules code (anything that decides damage, scoring, spawns, payouts) is a pure `RefCounted` script
  under scripts/systems/. It has no Node/scene dependency and has tests in tests/.
- Gameplay code never reads raw touch/InputEventScreen*; it reads InputMap actions or the
  InputRouter's `InputFrame` (scripts/input/).
- Tests use `preload()` of the scripts they test; they do not rely on autoloads. Expected-failure
  paths must not call `push_error` (it prints `ERROR:` and would fail the gate). Report validation
  problems through return values instead.
- If a story runs out of budget, the last commit must still pass the gate. Write what remains in the
  commit message.

Test convention (set up in S1): `tests/test_*.gd` files extend `res://tests/test_case.gd`. Every
method named `test_*` is a test and may `await`. The runner prints `PASS <file>::<test>` /
`FAIL <file>::<test>: <msg>` lines and a final `TESTS: <n> passed, <m> failed`. It exits 1 on any
failure, or if it finds zero tests.

## S1: Project scaffold, data table, test runner, Android preset [DONE]

Notes: built project.godot, icon, boot scene, folders, data/stats.json (weapon numbers are placeholders, OQ-06/07/11 already listed), test runner and Android preset; import, export and tests pass.

Goal: an empty but importable, exportable Godot 4.7.2 project with the modular folder layout, the
core class table as data, a headless test runner and the Android debug export preset.

Files:
- `project.godot`:
  - `config_version=5`
  - `config/name="Project Gladius"` (OQ-02)
  - `config/features` includes "4.7" and "Mobile"
  - `application/config/icon="res://icon.svg"`
  - `run/main_scene` set to `res://scenes/boot/boot.tscn`
  - `rendering/renderer/rendering_method="mobile"`
  - `rendering/textures/vram_compression/import_etc2_astc=true`
  - `display/window/handheld/orientation=4` (sensor landscape, OQ-04)
  - no autoloads yet
- `icon.svg`: simple placeholder icon (OQ-03). Commit the `.import` file Godot generates.
- `scenes/boot/boot.tscn` + `scripts/ui/boot.gd`: minimal Control with a centered Label
  "Project Gladius". Anchors only, no game code.
- `.gitignore`: keep `build/` and `.godot/`. Add:
  - `*.apk`, `*.aab`, `*.idsig`, `*.jks`, `*.keystore`
  - `!android/debug.keystore` (must come after `*.keystore`)
  - `android/build/`
- Folders, each kept with a `.gdkeep` file: `data/`, `scenes/`, `scripts/systems/`, `scripts/classes/`,
  `scripts/weapons/`, `scripts/net/`, `scripts/ui/`, `scripts/input/`, `scripts/platform/`, `tests/`.
- `data/stats.json` (schema below).
- `tests/run_tests.gd` (`extends SceneTree`; discovers `res://tests/test_*.gd`; runs tests in
  `_initialize()`, then `quit(code)`). `tests/test_case.gd` provides assert helpers that record failures
  without push_error. `tests/test_stats_data.gd` holds the first test.
- `export_presets.cfg` with exactly one preset `[preset.0]`:
  - `name="Android"`, `platform="Android"`, `runnable=true`
  - `export_filter="all_resources"`
  - `include_filter="data/*.json"`: required, because non-resource JSON files are not exported otherwise
  - `exclude_filter=""`: must be present even if empty
  - `export_path="build/gladius-debug.apk"`
  - In `[preset.0.options]`:
    - `gradle_build/use_gradle_build=false`
    - `architectures/arm64-v8a=true`, every other architecture false
    - `package/unique_name="com.placeholder.gladius"` (OQ-01)
    - `permissions/internet=true`, `permissions/access_network_state=true`,
      `permissions/access_wifi_state=true`
    - no `CHANGE_WIFI_MULTICAST_STATE` (OQ-41)
    - no release keystore: `keystore/release*` empty
  - Write every option key Godot 4.7.2 expects; missing keys print `ERROR:` lines. Check with the
    export output and add any key it reports.
  - Debug signing comes from the editor settings or the `GODOT_ANDROID_KEYSTORE_DEBUG_*` environment
    variables (shared android/debug.keystore, user `androiddebugkey`, password `android`). Never commit
    another key.

`data/stats.json` schema (version 1):
```json
{
  "version": 1,
  "classes": {
    "hastati":    {"display_name": "Hastati",    "shield": 100, "health": 100, "speed_pct": 100, "enabled": true},
    "principes":  {"display_name": "Principes",  "shield": 110, "health": 110, "speed_pct": 100, "enabled": false},
    "triarii":    {"display_name": "Triarii",    "shield": 140, "health": 130, "speed_pct": 85,  "enabled": false},
    "velites":    {"display_name": "Velites",    "shield": 70,  "health": 80,  "speed_pct": 115, "enabled": false, "skill": "mark"},
    "sagittarii": {"display_name": "Sagittarii", "shield": 80,  "health": 90,  "speed_pct": 95,  "enabled": true},
    "equites":    {"display_name": "Equites",    "shield": 90,  "health": 100, "speed_pct": 100, "enabled": false, "vehicle_speed_pct": 200, "role": "mobile support: vehicle, heal, ammo, cover"},
    "gladiator":  {"display_name": "Gladiator",  "shield": 60,  "health": 120, "speed_pct": 110, "enabled": false, "role": "melee"}
  },
  "weapons": {
    "pilum_br":    {"display_name": "Pilum BR",    "_placeholder": true, "_todo": "OQ-06 OQ-07", "kind": "hitscan", "tier": "standard", "damage": 0, "headshot_multiplier": 0, "fire_interval_s": 0, "burst_count": 0, "burst_interval_s": 0, "magazine": 0, "reserve_ammo": 0, "reload_s": 0, "range_m": 0, "spread_deg": 0},
    "gladius_lux": {"display_name": "Gladius Lux", "_placeholder": true, "_todo": "OQ-06 OQ-07", "kind": "hitscan", "tier": "standard", "...": "same keys, burst_count 1"}
  }
}
```
Class numbers must match the DESIGN.md table exactly. `enabled` scopes the milestone-1 build only.
Weapon zeros above stand for "fill in a playable placeholder number". S1 picks playable numbers and keeps
`_placeholder`.

Acceptance:
- Definition of done passes. `test_stats_data.gd` checks:
  - data/stats.json parses
  - all 7 class ids are present with positive shield/health/speed_pct
  - exactly hastati and sagittarii have `enabled: true`
  - pilum_br and gladius_lux exist with every required numeric key > 0 and `_placeholder == true`
- Grep finds in project.godot: `rendering_method="mobile"`, `import_etc2_astc=true`,
  `config/icon="res://icon.svg"`.
- Grep finds in export_presets.cfg: `include_filter=`, `exclude_filter=`,
  `use_gradle_build=false`, `arm64-v8a=true`, `com.placeholder.gladius`.
- Glob finds every listed folder.
- `git status` after `git add -A` shows no build/ or .godot/ paths.

Placeholders: OQ-01, OQ-02, OQ-03, OQ-04, OQ-05, OQ-06, OQ-07, OQ-11.

## S2: CI workflow (GitHub Actions Android debug build) [DONE]

Notes: Added `.github/workflows/android.yml` (static acceptance checked; local gate passes). SDK packages set to build-tools 36.0.0 / android-36 (matches local apksigner), still unconfirmed by a CI run (T-02, already in OPEN_QUESTIONS).

Goal: every push/PR builds the debug APK in CI with the same commands as the local gate.

Files: `.github/workflows/android.yml` (only).

Content:
- `on: [push, pull_request]`. One job on `ubuntu-latest` (or a pinned ubuntu version).
- Actions pinned to a major version or SHA: `actions/checkout@v4`, `actions/setup-java@v4`
  (temurin, 17), `actions/cache@v4`, `actions/upload-artifact@v4`, and an Android SDK setup
  (`android-actions/setup-android@v3`, or `sdkmanager` directly).
- Install the Android SDK packages: `platform-tools`, `build-tools;<ver>` (provides apksigner) and
  `platforms;android-<api>`, matching what Godot 4.7.2 targets. Add a comment that the version must be
  confirmed on the first CI run (T-02).
- Env `GODOT_VERSION: 4.7.2`, `GODOT_RELEASE: 4.7.2-stable`. Download from
  `https://github.com/godotengine/godot/releases/download/4.7.2-stable/`:
  - `Godot_v4.7.2-stable_linux.x86_64.zip`
  - `Godot_v4.7.2-stable_export_templates.tpz`
  - `SHA512-SUMS.txt`
- Verify both downloads with `sha512sum -c` against the lines for those two files. The step fails on
  mismatch.
- Cache the downloads with `actions/cache`, keyed on `godot-4.7.2-stable` (version in the key).
- Install the templates: unzip the .tpz (it holds a `templates/` folder) and move its contents to
  `~/.local/share/godot/export_templates/4.7.2.stable/`.
- Write `~/.config/godot/editor_settings-4.7.tres` with `export/android/android_sdk_path` and
  `export/android/java_sdk_path` (from `$ANDROID_SDK_ROOT` / `$JAVA_HOME`).
- Job env for signing with the committed key (no secrets):
  - `GODOT_ANDROID_KEYSTORE_DEBUG_PATH: ${{ github.workspace }}/android/debug.keystore`
  - `GODOT_ANDROID_KEYSTORE_DEBUG_USER: androiddebugkey`
  - `GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD: android`
- Steps, each with `--headless`:
  - `mkdir -p build`
  - `--import`
  - `--script res://tests/run_tests.gd`
  - `--export-debug "Android" build/gladius-debug.apk`
  - `test -f build/gladius-debug.apk` (fails if the APK is missing)
  - `actions/upload-artifact` of `build/gladius-debug.apk`
- No `secrets.*`, no release export, no release keystore.

Acceptance (static, because CI cannot run locally):
- Glob finds `.github/workflows/android.yml`.
- Grep in the file finds each of:
  - `4.7.2-stable`
  - `Godot_v4.7.2-stable_linux.x86_64.zip`
  - `Godot_v4.7.2-stable_export_templates.tpz`
  - `SHA512-SUMS.txt`
  - `sha512sum`
  - `actions/cache@`
  - `export_templates/4.7.2.stable`
  - `editor_settings-4.7.tres`
  - `android_sdk_path`
  - `java_sdk_path`
  - `java-version`, together with `17`
  - `build-tools`
  - `platform-tools`
  - `GODOT_ANDROID_KEYSTORE_DEBUG_PATH`
  - `GODOT_ANDROID_KEYSTORE_DEBUG_USER`
  - `GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD`
  - `run_tests.gd`
  - `--export-debug`
  - `upload-artifact@`
- Grep finds no `secrets.` and no `export-release` in the file.
- Definition of done still passes locally. The first real CI run happens only after Shibi pushes.

Placeholders: T-02.

## S3: Data registry and damage rules [DONE]
Notes: Added DataRegistry, ClassDef, WeaponDef, HealthState, DamageRules plus tests; `combat` placeholders in data/stats.json (OQ-12/13/14, already listed in OPEN_QUESTIONS.md; regen numbers 5 s / 25 per s are placeholders; only shield regenerates, health does not).

Goal: one typed way to load data/*.json, plus the pure, tested Halo-style damage rules.

Files:
- `scripts/systems/data_registry.gd`: `class_name DataRegistry`, RefCounted. Its API:
  - `load_file(path) -> Dictionary` (with cache)
  - `get_class_def(id)`, `get_weapon_def(id)`
  - `validate() -> PackedStringArray` (returns problems, no push_error)
- `scripts/classes/class_def.gd`: typed wrapper built from a class entry.
- `scripts/weapons/weapon_def.gd`: typed wrapper built from a weapon entry.
- `scripts/systems/health_state.gd`: shield, health, max values, regen timer.
- `scripts/systems/damage_rules.gd`, pure functions:
  - `apply_hit(target_state, weapon_def, is_headshot, attacker_squad, target_squad, target_protected) -> HitResult`
  - `tick_regen(state, delta, combat_cfg)`
- `data/stats.json`: add a `combat` section, all `_placeholder` (OQ-12/13/14):
  - `shield_regen_delay_s`
  - `shield_regen_rate_per_s`
  - `overflow_to_health: true`
- `tests/test_data_registry.gd`, `tests/test_damage_rules.gd`.

Rules (design): shield absorbs first, then health; headshots deal extra damage; no friendly fire
(same squad → no damage); a spawn-protected target takes no damage. Placeholders: headshot multiplier
semantics, overflow, regen numbers.

Acceptance: Definition of done passes. Named tests pass:
- `test_shield_then_health`
- `test_overflow_carries_into_health`
- `test_headshot_multiplier_applied`
- `test_no_friendly_fire`
- `test_spawn_protected_takes_no_damage`
- `test_kill_reported_when_health_zero`
- `test_regen_waits_for_delay_then_refills`
- `test_registry_class_def_matches_json`
- `test_registry_validate_clean`

Placeholders: OQ-12, OQ-13, OQ-14.

## S4: King of the Hill and spawn rules (pure)

Goal: the match rules for a fixed-hill KotH, runnable headless with no scene.

Files:
- `data/modes.json`: `koth` entry. Design values:
  - `points_per_second: 1`, `score_to_win: 100`, `time_limit_s: 600`
  - `hill_modes: ["fixed","moving"]`, `default_hill_mode: "fixed"`
  - `moving_warn_s: 5` (stored, unused in milestone 1)
  - placeholder `contest_rule: "any_other_squad"` (OQ-21), `scoring_unit: "squad"` (OQ-20),
    `tie_result: "draw"` (OQ-22)
- `data/match.json`, design values: `respawn_s: 5`, `spawn_protection_s: 5`, `squad_size: 3`,
  `max_players: 18`, `min_humans: 2`, `max_humans: 6`.
- `scripts/systems/game_mode_rules.gd`: base class with `setup(cfg)`, `tick(delta, occupancy) -> Array[events]`,
  `is_over()`, `result()`.
- `scripts/systems/koth_rules.gd`: extends the base.
- `scripts/systems/spawn_rules.gd`: assigns each squad a random fixed spot for the whole match from a
  seeded RNG; tracks respawn timers; tracks spawn protection, which ends on firing and not on pickup.
- `scripts/systems/mode_registry.gd`: maps mode `rules` id → script.
- `tests/test_koth_rules.gd`, `tests/test_spawn_rules.gd`.

Acceptance: Definition of done passes. Named tests pass:
- `test_uncontested_scores_one_per_second`
- `test_contested_scores_nothing`
- `test_empty_hill_scores_nothing`
- `test_first_to_100_wins`
- `test_timer_ends_highest_wins`
- `test_timer_tie_is_draw`
- `test_squad_spot_fixed_for_match`
- `test_spots_unique_per_squad`
- `test_respawn_after_5s`
- `test_protection_ends_on_fire`
- `test_protection_survives_pickup_event`
- `test_protection_expires_after_5s`
- `test_mode_registry_resolves_koth`

Placeholders: OQ-15, OQ-20, OQ-21, OQ-22.

## S5: Input abstraction, providers and touch HUD

Goal: all input flows through InputMap actions and one router; touch and gamepad work; the touch HUD is
its own layer.

Files:
- `project.godot` `[input]`: actions `move_left/right/forward/back`, `look_left/right/up/down`, `fire`,
  `aim`, `reload`, `swap_weapon`, `jump`, `pause`. Keyboard and gamepad default events go here; no
  touch events.
- `scripts/input/input_frame.gd`: `move: Vector2`, `look: Vector2`, plus pressed/just_pressed per action.
  It can be serialized to/from Array for networking.
- `scripts/input/input_router.gd`: Node, later an autoload. Holds an ordered list of providers, merges
  them into one `InputFrame` per physics tick, exposes `get_frame()`.
- `scripts/input/input_provider.gd`: base class.
- Providers:
  - `providers/keyboard_mouse_provider.gd`
  - `providers/gamepad_provider.gd`
  - `providers/touch_provider.gd`: gets values from the touch HUD controls, never from gameplay
  - `providers/gyro_provider.gd`: asks PlatformServices; no-op by default (OQ-34)
- `scripts/platform/platform_services.gd`: `OS.get_name()` switch, safe no-op fallbacks:
  - `is_touch_device()`, `has_gyro()`, `get_gyro_rate()`, `vibrate(ms)`
- `scenes/ui/touch_hud.tscn` + `scripts/ui/touch_hud.gd`: left move stick, right backup aim stick where
  a tap fires, plus buttons for aim, reload, swap and jump. Laid out with anchors/containers; it
  feeds TouchProvider and presses actions via `Input.action_press`. Shown only when
  `is_touch_device()` or a setting forces it.
- `data/input.json`: sensitivities, dead zones, invert_y false, layout anchors; placeholders (OQ-35/36).
- `tests/test_input.gd`.

Acceptance: Definition of done passes. Named tests pass:
- `test_actions_exist_in_inputmap`: every action above.
- `test_router_merges_providers`: fake providers, summed move clamped to length 1.
- `test_action_press_reaches_frame`: `Input.action_press("fire")` → `frame.fire_pressed`.
- `test_input_frame_roundtrip_serialization`
- `test_touch_hud_scene_instantiates`
- `test_platform_services_noop_on_headless`: no gyro, vibrate is a no-op.

Grep finds no `InputEventScreenTouch` or `InputEventScreenDrag` outside `scripts/input/` and
`scripts/ui/touch_hud*`.

Placeholders: OQ-34, OQ-35, OQ-36.

## S6: Player pawn, third-person camera and the two weapons

Goal: an offline test scene where a Hastati or Sagittarii pawn moves, aims, swaps between Pilum BR and
Gladius Lux, and damages a target dummy through DamageRules.

Files:
- `scenes/player/pawn.tscn` + `scripts/classes/pawn.gd`: CharacterBody3D with a capsule placeholder
  mesh (OQ-25). Driven only by an `InputFrame`, so humans, bots and network peers share it. Applies the
  class's `speed_pct` to base speed. Pawns are tagged with squad id and class id.
- `scripts/classes/pawn_rules_bridge.gd`: wraps HealthState + DamageRules for the pawn.
- `scripts/weapons/weapon.gd`: fire timing, burst, magazine/reserve, reload, from WeaponDef.
- `scripts/weapons/hitscan.gd`: physics raycast; head hitbox via a separate collision shape; reports
  hits to an injected "authority" callable, so S9 can route hits to the host.
- `scripts/weapons/loadout.gd`: two slots + swap; sidearm slot exists, empty (OQ-09).
- `data/loadouts.json`: per-class spawn loadout, placeholder (OQ-08/10).
- `data/stats.json`: add `movement` (base_speed_mps, gravity, accel, jump_enabled, jump_velocity:
  placeholders, OQ-17/18) and `aim_assist` (all 0, placeholder, OQ-19).
- `scripts/systems/camera_rig.gd` + `scenes/player/camera_rig.tscn`: third-person SpringArm3D +
  Camera3D. FOV comes from `data/camera.json` by viewport aspect ratio; a wider inner-screen entry
  covers near-square aspects (Z Fold7). Placeholder (OQ-37). Re-applies on viewport `size_changed`.
- `scenes/test/weapon_range.tscn`: floor, a pawn and a dummy target.
- `tests/test_weapons.gd`, `tests/test_camera.gd`, `tests/test_pawn.gd`.

Acceptance: Definition of done passes. Named tests pass:
- `test_fire_interval_respected`: weapon logic with injected time.
- `test_burst_fires_burst_count`
- `test_reload_refills_from_reserve`
- `test_swap_switches_active_slot`
- `test_loadout_from_data_for_hastati_and_sagittarii`
- `test_fov_for_aspect_picks_table_row`: 19.5:9 phone vs ~1:1 Fold inner.
- `test_pawn_speed_scales_with_class`: Sagittarii is 95% of Hastati.
- `test_hitscan_damages_dummy`: instantiates weapon_range.tscn, awaits physics frames, fires, and
  checks the dummy's shield dropped.

Placeholders: OQ-06–OQ-10, OQ-17, OQ-18, OQ-19, OQ-25, OQ-37.

## S7: Alesia section map, fixed hill and offline match loop

Goal: a playable offline match on a greybox section of Alesia: the hill scores, players respawn at
their squad spot with protection, and the match ends at 100 points or 10 minutes.

Files:
- `scenes/maps/alesia_section.tscn`: greybox of the hilltop citadel, part of the inner wall and part
  of the legion-camp ring (OQ-24). Static collision plus a NavigationRegion3D baked in the editor or at
  load, for S8. Marker3D nodes for squad spawns and the hill center.
- `data/maps/alesia_section.json`: map id, scene path, hill (center, radius, height), spawn spot
  positions, `modes: ["koth"]` (OQ-23, OQ-26).
- `scripts/systems/hill_zone.gd`: Area3D presentation node. It reports occupancy (squad ids inside)
  to the rules; it scores nothing itself.
- `scripts/systems/match_director.gd`: Node that owns KothRules + SpawnRules. It feeds them
  occupancy and time, spawns and respawns pawns, applies protection, and emits signals for the HUD
  (`score_changed`, `time_changed`, `match_over`).
- `scenes/match/match.tscn`: loads the map from data, MatchDirector, a local player and a debug Label
  with scores and timer (real HUD in S10).
- `tests/test_match_scene.gd`.

Acceptance: Definition of done passes. Named tests pass:
- `test_map_json_matches_scene_markers`: every spawn in JSON has a marker, and vice versa.
- `test_match_scene_instantiates`
- `test_pawn_in_hill_scores`: place a pawn in the hill, step physics about 2 s, check the squad
  score is ≥ 1.
- `test_dead_pawn_respawns_at_squad_spot_protected`: shortened timers via a test-only override of
  the loaded config dict.
- `test_match_over_signal_at_score_to_win`: config override with a low score.

Placeholders: OQ-23, OQ-24, OQ-25, OQ-26.

## S8: Bots that play the hill

Goal: "a few bots" fill the squads, move to the hill and fight using the same pawn and weapons.

Files:
- `data/bots.json`:
  - profiles `tiro`, `miles`, `centurion`, `legatus` with fields accuracy, reaction_time_s,
    damage_mult, health_mult, aim_smartness and grenade_freq, all placeholder (OQ-31)
  - `match_fill: {"squads": 2, "squad_size": 3, "profile": "tiro"}` (OQ-30)
  - `class_rotation: ["hastati","sagittarii"]` (OQ-32)
- `scripts/systems/bot_brain.gd`: produces an `InputFrame` each tick from perception (move to the
  hill via NavigationAgent3D, target the nearest visible enemy, aim error from the profile, react after
  `reaction_time_s`). Bots never read player input.
- `scripts/systems/bot_spawner.gd`: fills empty squad slots up to `match_fill`. Host-only.
- `scripts/systems/bot_targeting.gd`: pure, tested target selection and aim-error math.
- `scripts/systems/bot_commands.gd`: stub enum + data hook only; no commands in milestone 1 (OQ-33).
- `tests/test_bots.gd`.

Acceptance: Definition of done passes. Named tests pass:
- `test_fill_counts_from_data`: 1 human → 5 bots for 2×3.
- `test_bots_alternate_classes`
- `test_targeting_picks_nearest_visible_enemy_not_teammate`
- `test_aim_error_scales_with_accuracy`: seeded RNG.
- `test_bot_moves_toward_hill`: match scene, step ~3 s, distance to the hill decreased.
- `test_bot_profile_fields_present`

Placeholders: OQ-30, OQ-31, OQ-32, OQ-33.

## S9: Hotspot multiplayer with host authority

Goal: two phones on the host's hotspot play the same match. The host decides hits, damage, score and
respawns; clients send input and fire requests.

Files:
- `data/net.json`: port, max_clients (from `match.json` max_humans), snapshot rate, connect timeout
  (T-01).
- `scripts/net/net_session.gd`: ENetMultiplayerPeer host/join/leave; signals `peer_joined`,
  `peer_left`, `connected`, `failed`, `host_lost`. Uses the high-level multiplayer API only.
- `scripts/net/lobby_state.gd`: pure. Players, squad auto-assignment (humans first, bots fill; OQ-28),
  class choice per player, start flag. Serializable.
- `scripts/net/net_match_bridge.gd`: connects MatchDirector to the network:
  - clients send `InputFrame` (unreliable_ordered) and fire requests (origin, direction, weapon,
    client tick)
  - the host validates and raycasts on its own state and applies DamageRules
  - the host replicates pawn transforms/health and score/timer, using MultiplayerSynchronizer or
    snapshots
  - events (kill, respawn, match over) are reliable RPCs
- Movement: client-owned, with a host speed sanity check (T-03).
- Host drop → `host_lost` → return to main menu (OQ-27).
- `tests/test_net.gd`.

Acceptance: Definition of done passes. Named tests pass:
- `test_lobby_assigns_humans_then_bots`
- `test_lobby_state_roundtrip_serialization`
- `test_fire_request_validation_rejects_wrong_weapon_or_rate`: pure host-side validator.
- `test_loopback_host_and_client_connect`: two SceneMultiplayer branches in one process on
  127.0.0.1 with the port from net.json; the client connects within the timeout; then both close
  cleanly.
- `test_host_authoritative_damage`: a client fire request over loopback reduces the target's shield on
  the host, and the client receives the replicated value.

Grep finds no Android-only APIs and no `OS.get_name() == "Android"` outside `scripts/platform/`.

Placeholders: OQ-27, OQ-28, OQ-41, T-01, T-03.

## S10: Main menu, lobby, gameplay HUD and end screen (first-playable wrap-up)

Goal: a complete loop on device: main menu → Host or Join → lobby → match → end screen → main menu.

Files:
- `scenes/ui/main_menu.tscn` + `scripts/ui/main_menu.gd`:
  - Host, Join (IP field pre-filled from the save, OQ-41), name field (OQ-39)
  - Loadout/Profile/Shop/Tutorials/Settings shown disabled with a "later" tag, so the design's menu is
    visible without being built
- `scenes/ui/lobby.tscn`: player list by squad, class toggle Hastati/Sagittarii (OQ-29), host Start
  button, host IPs shown on the host.
- `scenes/ui/hud.tscn` + `scripts/ui/hud.gd`: presentation only. Binds to MatchDirector/local-pawn
  signals. Shows shield/health bars, ammo, active weapon, squad scores in Roman numerals, timer,
  hill indicator and a respawn countdown. Red/gold theme in `scenes/ui/theme.tres`. Anchors/containers
  only. touch_hud.tscn layers above it.
- `scenes/ui/end_screen.tscn`: winner/draw and per-squad scores.
- `scripts/ui/roman_numerals.gd`: pure, tested.
- `scripts/systems/save_service.gd`: `user://profile.json` with `version`, gamertag and last IP;
  tolerant load, so a missing or corrupt file gives defaults.
- `data/graphics_presets.json` (`default` preset, 60 fps cap; OQ-40), applied at boot. boot.tscn routes
  to the main menu.

Acceptance: Definition of done passes. Named tests pass:
- `test_roman_numerals_1_to_100`: spot checks I, IV, IX, XL, XC, C, plus 0 → "N" or empty per the
  placeholder note.
- `test_save_roundtrip_user_dir`
- `test_save_missing_or_corrupt_gives_defaults`
- `test_hud_binds_and_updates_on_signals`
- `test_menus_instantiate`
- `test_touch_hud_hidden_when_not_touch`
- `test_graphics_preset_applied`

Grep finds no hard-coded absolute paths (`C:/`, `/sdcard`, `/storage`) in scripts/.

Placeholders: OQ-28, OQ-29, OQ-38, OQ-39, OQ-40, OQ-41.

Manual (Shibi, outside the gate): install the APK on two phones, start a hotspot on one, host there,
join from the other by IP, and play to 100 points.

## Out of milestone 1 (provisioned in ARCHITECTURE.md, not built)

- Moving hill
- Melee, grenades, crouch/prone, radar
- Scorestreaks, deployables, weapon pickups, power weapons
- Killcam, join in progress, host-drop reconnect
- Bot commands
- Gyro aim (OQ-34), aim assist strength (OQ-19)
- Economy/Denarii, progression, shop/cosmetics, factions beyond Romans
- Audio, settings screen, tutorial, campaign, vehicles
