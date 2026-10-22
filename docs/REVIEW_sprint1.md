# Sprint 1 review (opus/sprint1-first-playable vs main)

Scope: all commits `main..HEAD` (P1, T1, S1-S10), checked against docs/DESIGN.md, docs/ARCHITECTURE.md
and docs/plans/sprint1.md.

## Verification (run during this review, after the fixes below)

| Step | Result |
|---|---|
| `mkdir -p build` | ok |
| `godot --headless --path . --import` | exit 0, no ERROR / SCRIPT ERROR / Parse Error lines |
| `godot --headless --path . --export-debug "Android" build/gladius-debug.apk` | exit 0, signed with the shared debug key, `build/gladius-debug.apk` present, no ERROR lines |
| `godot --headless --path . --script res://tests/run_tests.gd` | `TESTS: 62 passed, 0 failed` |

## What checks out

- **Design fidelity:** class table, KotH (1 pt/s, 100 to win, 600 s), respawn 5 s, protection 5 s
  (ends on fire, not on pickup), squads of 3, 2-6 humans / 18 max and no friendly fire all match
  DESIGN.md. Every number DESIGN.md does not give is marked `_placeholder` / `_todo` in data/*.json
  and listed in docs/OPEN_QUESTIONS.md (OQ-01..OQ-49, T-01..T-03).
- **DRAFT traits/medals:** `data/traits.json` and `data/medals.json` are marked `"status": "DRAFT - awaiting
  Shibi approval"`. Nothing in scripts/ or scenes/ references them.
- **Rules vs presentation:** DamageRules, KothRules, SpawnRules, LobbyState, NetValidator, Weapon,
  BotTargeting are pure RefCounted classes with tests. HillZone only reports occupancy. The HUD only
  binds to signals. Modes resolve through ModeRegistry from data/modes.json. Classes and weapons come
  from data/stats.json, loadouts from data/loadouts.json.
- **Cross-platform:** input goes through InputMap and InputRouter providers. Raw touch events are read
  only in the touch HUD (`scripts/ui/touch_hud.gd`), which feeds TouchProvider. `OS.get_name()` is
  used only in `scripts/platform/`. Saves go to `user://`. Networking is ENet over high-level multiplayer.
  No hard-coded absolute paths.
- **Android export:** Mobile renderer, `import_etc2_astc=true`, `config/icon` set, a single "Android"
  preset (arm64-v8a only, debug key only, INTERNET / ACCESS_NETWORK_STATE / ACCESS_WIFI_STATE).
  The placeholder app id (OQ-01) and orientation (OQ-04) are in OPEN_QUESTIONS.
- **Repo hygiene:** `git diff main...HEAD --stat` has no APK, no build/ or .godot/ files, and no keystore
  except `android/debug.keystore`. .gitignore covers build/, .godot/, *.apk, *.aab, *.jks, *.keystore
  (with the debug key whitelisted).
- **CI (`.github/workflows/android.yml`):** pinned 4.7.2-stable editor and templates, SHA512 check
  (also on cache hit), templates installed to `~/.local/share/godot/export_templates/4.7.2.stable`,
  SDK/JDK paths in `editor_settings-4.7.tres`, Temurin JDK 17, build-tools 36.0.0 (apksigner),
  debug keystore env vars, then import, tests, export, a missing-APK check and the artifact upload.
  `permissions: contents: read`, no secrets.

## Fixed in this review

1. **Host fire-rate check let burst weapons fire at full burst speed.** `scripts/net/net_validator.gd`
   (validate_fire) used only `burst_interval_s` (0.07 s) as the minimum gap for burst weapons. A
   modified client could fire Pilum BR at about 14 shots/s instead of 3 shots per 0.5 s. It now allows
   at most `burst_count` shots per `fire_interval_s` window, each at least one burst gap apart, both
   scaled by the data tolerance. New test: `test_net.gd::test_fire_validation_caps_burst_per_interval`.
2. **Steep upward shots hit the shooter's own head.** The ray excluded only the body, not the Head Area3D
   (head spans y 1.53-1.97, muzzle at 1.3), so any shot aimed above about 64° was swallowed by the
   shooter's own head. Added `Pawn.hitscan_exclude()` (`scripts/classes/pawn.gd`). It is now used by
   both the local fire path and the host fire path (`scripts/net/net_match_bridge.gd` host_handle_fire).
3. **Test runner could hang CI.** If a test file failed to parse, `tests/run_tests.gd` crashed on a null
   script before `quit()`, and the headless job ran until the 45-minute timeout. It now counts the file
   as a FAIL and exits 1.
4. **Export preset exclude filter.** `export_presets.cfg` now sets `exclude_filter="tests/*"`, so test
   scripts are not packed into the APK. Nothing in scenes/ or scripts/ references res://tests.

## Open findings

### High

- **H1. Hotspot multiplayer is not playable end to end; it is a milestone-1 requirement.**
  `scripts/ui/lobby.gd:108-110`: host Start loads the match scene locally.
  `scripts/systems/match_root.gd:69-83`: only the local pawn plus bots are created.
  `NetMatchBridge` (`scripts/net/net_match_bridge.gd:5`) is never instantiated outside tests, and a
  joined client stays on "Waiting for the host to start" (`scripts/ui/lobby.gd:58`) forever. Remote
  humans in the lobby are dropped (`match_root.gd:97-98` reads only `humans[0]`). As a result the
  manual acceptance in docs/plans/sprint1.md:497-498 (two phones play to 100 points) cannot pass.
  Needed:
  - an RPC to start the match on clients
  - spawning one pawn per lobby slot with the lobby's player ids and squads
  - attaching NetMatchBridge under the NetSession on every peer and registering peer → player ids
  - clients sending input and fire through the bridge and applying the replica
  - lobby name/class sync

  The gap is already noted as a TODO in OPEN_QUESTIONS.md, but it blocks the milestone.
- **H2. Client registers itself with the host's peer id.** `scripts/ui/lobby.gd:26,76,94`: every peer adds
  its local human as peer id 1 and toggles class for peer 1. On a client the local id is
  `session.get_unique_id()`. This must be fixed as part of H1.

### Medium

- **M1. Host does not track ammo or reload for remote players.** `scripts/net/net_match_bridge.gd:94-108`
  checks the weapon id, rate and origin, but never consumes the host-side magazine or blocks fire
  while reloading. A modified client has unlimited ammo. Drive the host copy of `Weapon` from the
  accepted requests and reject shots when the magazine is empty or the weapon is reloading.
- **M2. Movement validation is horizontal only.** `scripts/net/net_validator.gd` validate_move ignores y,
  so a client can teleport or fly vertically. Rejected moves also leave `_last_move_s` unchanged
  (`net_match_bridge.gd:79-83`), so a repeated far position is eventually accepted. Add a vertical
  bound (jump velocity/gravity from data) and keep the host position authoritative after a rejection.
- **M3. Three sources for the number of squads.** `scripts/ui/lobby.gd:22` hard-codes `2`.
  `data/match.json` has `offline_squads` and `data/bots.json` has `match_fill.squads`. If bots.json fills
  more squads than match.json registers, `MatchDirector._place` (`scripts/systems/match_director.gd:94-95`)
  indexes `_spawn_xforms[null]` and errors. Use one data key, or validate them against each other
  in DataRegistry.validate().

### Low

- **L1. Tunable numbers still in scripts:**
  - `scripts/classes/pawn.gd:112`: pitch clamp ±80°. This duplicates and contradicts `camera.json`
    pitch_min/max ±70.
  - `scripts/classes/pawn.gd:7`: `MUZZLE_HEIGHT_M`.
  - `scripts/systems/bot_brain.gd:6-7,37-38`: eye/target heights and nav distances.
  - `scripts/systems/match_director.gd:96-97`: 1.5 m squad-mate spacing.
  - `scripts/ui/touch_hud.gd:8`: `FIRE_PULSE_S`.
  - `scripts/systems/match_root.gd:6`: `END_SCREEN_DELAY_S` (documented as presentation).

  Move them to data/*.json as placeholders.
- **L2. Float score accumulation.** `scripts/systems/koth_rules.gd:37-40` sums `points_per_second * delta`.
  The win check `>= score_to_win` can land a tick late (99.9999...). The impact is negligible, but an
  integer point counter with a fractional carry would be exact.
- **L3. CI not yet proven on a runner.** The SDK packages (`build-tools;36.0.0`, `platforms;android-36`)
  are unverified until the first GitHub run (T-02). `on: [push, pull_request]` builds twice for PRs
  from the same repo.
- **L4. Missing tests:**
  - NetMatchBridge snapshot → `apply_replica`
  - host rejection of an implausible `submit_input`
  - KotH reaching 100 on the same tick the timer expires
  - `MatchDirector.start` with more squads than spawn spots (false return path)
  - lobby squad count vs bot fill consistency (M3)

VERDICT: ITERATE
