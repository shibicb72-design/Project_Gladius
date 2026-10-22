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

## Re-review

Scope: `git log --oneline 8ee5273..HEAD` (6 commits): F1 `80a22bd` (CI), F2 `1c63451` (lobby, H2),
F2b `7ef6744` (networked match setup), F2c `8a98f55` (end-to-end client input/fire/replica),
F3 `e01eed0` (M1-M3), F4 `db3a6f4` (L1, L2, L4). No fix step is missing. Checked against
docs/REVIEW_sprint1.md (above), docs/plans/sprint1.md and docs/DESIGN.md. This review changed no code, data or tests.

### Verification (run during this re-review)

| Step | Result |
|---|---|
| `mkdir -p build` | exit 0 |
| `godot --headless --path . --import` | exit 0, no ERROR / SCRIPT ERROR / Parse Error lines |
| `godot --headless --path . --export-debug "Android" build/gladius-debug.apk` | exit 0, signed with the shared debug key ("Signed", APK verified), `build/gladius-debug.apk` found by Glob, no ERROR lines |
| `godot --headless --path . --script res://tests/run_tests.gd` | exit 0, `TESTS: 86 passed, 0 failed` (was 62) |

### Per-finding status

- **H1 (hotspot multiplayer end to end): fixed (code and loopback tests). Two-phone run still pending.**
  - Start RPC: `scripts/net/net_lobby.gd:54-58,79-86`. The host sends the lobby state and seed to all
    peers (`call_local`), and `scripts/ui/lobby.gd:114` plus `_on_match_starting` load the match on every peer.
  - One pawn per lobby slot, with the lobby's player ids and squads: `scripts/systems/match_roster.gd:31-58`,
    used by `scripts/systems/match_root.gd:86-98`.
  - Bridge: created under the NetSession on every peer (`scripts/net/net_session.gd` `_enter_tree`).
    The host registers peer → player ids (`match_roster.gd:63-77`).
  - Client input and fire go through the bridge: `match_root.gd:133,137-145`, using `Pawn.shot`,
    `reload_started` and `weapon_switched`. The replica is applied in `match_root.gd` `_on_snapshot` and
    `net_match_bridge.gd:270-306`.
  - Lobby name/class sync: `net_lobby.gd:46-51,62-76,90-100`. The host edits only the sender's entry
    and truncates names to `max_name_length`.
  - Tests exist and pass:
    - F2: `test_net_lobby.gd` (4/4)
    - F2b: `test_match_roster.gd` (4/4)
    - F2c: `test_net_match.gd` (`test_e2e_client_join_start_same_pawn_set`, `test_e2e_client_input_moves_pawn_on_host`, `test_e2e_client_fire_damages_on_host_only`, 3/3)
    - F3 follow-up: `test_net_authority.gd` (8/8)
  - **Client never applies damage or score locally: confirmed.**
    - The client's local pawn has `hit_authority = Callable()` (`match_roster.gd:50-53`), and
      `scripts/weapons/hitscan.gd:44` applies nothing when the authority is invalid.
    - Every other pawn on a client is `REPLICA` (`match_roster.gd:56-58`): `pawn.gd:123` returns before
      any tick, so it has no brain, no weapon and no regen.
    - The client director is passive (`match_director.gd:73`, `authoritative = false` from `match_root.gd:86`).
      Score, respawns and match over arrive only through `apply_remote_*`. The client's own shield, health
      and alive values come from the host snapshot (`net_match_bridge.gd:286-296`).
  - **Remote pawns on the host are not fired or moved twice: confirmed.**
    - A remote human is `HOST_REMOTE` (`match_roster.gd:58`). `pawn.gd:127` returns after `bridge.tick`,
      so no look, movement or weapon runs from an InputFrame.
    - Position changes only in `host_handle_move` (`net_match_bridge.gd:159-175`). Shots happen only in
      `host_handle_fire` (`:195-217`), one host raycast per accepted request.
    - `last_frames` (`:153`) is stored but never read (see N4).
- **H2 (client registers with host peer id): fixed.**
  - `lobby.gd:81,99` use `net_lobby.local_id()` (`net_lobby.gd:26`).
  - Clients add themselves through `_request_update`, keyed on `multiplayer.get_remote_sender_id()` (`net_lobby.gd:62-69`).
  - Test: `test_net_lobby.gd::test_lobby_client_registers_with_own_peer_id`, plus `test_lobby_rejects_edit_of_other_player`.
- **M1 (host ammo/reload): fixed.**
  - `net_match_bridge.gd:195-212`: the host Weapon copy is advanced, and requests are rejected while
    reloading or when the magazine is empty (`reloading` / `empty`). Each accepted shot uses one round.
  - Reload and slot changes are synced reliably (`:98-142`). Weapon has no auto-reload
    (`scripts/weapons/weapon.gd:24-64`), so client and host magazines stay in step.
  - Tests: `test_net_authority.gd` (empty, reloading, reload refill).
- **M2 (horizontal-only move check): fixed.**
  - `net_validator.gd` `validate_move` bounds the vertical change: up by jump velocity plus slope climb,
    down by `max_fall_speed_mps`.
  - `_last_move_s` is reset on every attempt (`net_match_bridge.gd:166`), so a rejected position cannot
    age into acceptance. The host keeps its position and sends `correct_position` (`:173`).
  - Tests: `test_validate_move_rejects_vertical_teleport`, `test_validate_move_allows_jump_and_fall`,
    `test_rejected_move_keeps_host_position_and_does_not_age_in`.
- **M3 (three squad-count sources): fixed.**
  - `data/match.json` `squads` is the single key. It is read by `lobby.gd:60`, `match_root.gd:79` (via
    `lobby.squad_count` when networked) and `bot_spawner.gd:16`.
  - `match_fill.squads` and `offline_squads` are removed. `DataRegistry.validate_squads`
    (`data_registry.gd:92-103`) checks the count against max_players and map spawn spots.
  - Tests: `test_squad_count_single_source`, `test_validate_rejects_more_squads_than_spawns`.
- **L1 (tunables in scripts): fixed.**
  - Pitch clamp: from `camera.json` (`pawn.gd:136-137`, no more ±80 / ±70 conflict).
  - Muzzle height: `stats.json` movement `muzzle_height_m` (`pawn.gd:94`).
  - Bot eye/target heights and nav distances: `bots.json` brain.
  - Squad spacing: `match.json` `squad_spacing_m` (`match_director.gd` `_place`).
  - Fire pulse: `input.json` `fire_pulse_s`.
  - End-screen delay: `data/ui.json`.
  - Test: `test_pitch_clamp_uses_camera_data`.
- **L2 (float score): fixed.** `koth_rules.gd` uses an integer score plus a float carry, and the win check
  is an integer comparison. Tests: `test_koth_integer_score_exact_at_100`, `test_koth_win_on_same_tick_as_timer_expiry`.
- **L3 (CI unproven): fixed statically; real run pending (orchestrator).** See CI below.
- **L4 (missing tests): fixed.** Each test listed in L4 now exists and passes:
  - snapshot → replica: `test_bridge_snapshot_applies_replica`
  - implausible move rejection: `test_net_authority.gd` (move tests), via `host_handle_move`
  - KotH reaching 100 on the timer-expiry tick
  - `MatchDirector.start` false path: `test_match_director_start_fails_with_more_squads_than_spots`
  - squad count consistency: `test_squad_count_single_source`

### CI (static; GitHub Actions cannot run here)

`.github/workflows/android.yml`:
- `on: push: branches [main]`, `pull_request`, `workflow_dispatch`, so a PR from the same repo builds once.
- `android-actions/setup-android@v3` with `packages: "platform-tools build-tools;36.0.0 platforms;android-36"`.
  It has no `tools` entry, and a check step greps `sdkmanager --list_installed` for both pinned packages.
- No `secrets.` references, and `permissions: contents: read` is unchanged.

The first real run (T-02) is checked by the orchestrator after the push.

### Data numbers and product decisions

Every new number in data/*.json is a placeholder with an OPEN_QUESTIONS entry:
- `net.json`:
  - `input_rate_hz` 30 (OQ-51)
  - `max_name_length` 24 (OQ-50)
  - `validation.move_vertical_tolerance` 1.5 and `max_fall_speed_mps` 60 (T-03, block `_placeholder`)
- `stats.json` `muzzle_height_m` 1.3: movement block `_placeholder`, OQ-50 tunables entry
- `bots.json` brain `eye_height_m`, `target_height_m`, `path_desired_distance_m` and
  `target_desired_distance_m`: block `_placeholder`
- `match.json`:
  - `squads` 2: TODO note, OQ-30
  - `squad_spacing_m` 1.5: TODO note
- `input.json` `fire_pulse_s` 0.08: touch_layout `_placeholder`
- `ui.json` `end_screen_delay_s` 3.0: file `_placeholder`

No design value was changed, and no product decision was invented:
- Squad assignment is unchanged (`LobbyState.assign` not touched; OQ-28 still notes that humans share squad 0).
- The quitter's pawn is only made inactive, with a TODO pointing at DESIGN.md's "replaced by bot"
  (`match_roster.gd:93-100`, OQ-27).
- Squad count stays the OQ-30 placeholder.

### Cross-platform

- `OS.get_name()` appears only in `scripts/platform/platform_services.gd`.
- `InputEventScreenTouch` / `InputEventScreenDrag` appear only in `scripts/ui/touch_hud.gd:89,94`.
- Networking is ENet over high-level multiplayer RPCs only.
- The renderer is still `mobile` (`project.godot:104`), and `export_presets.cfg` is unchanged.
- No hard-coded absolute paths.

### New concerns

- **N1 (Medium): spawn protection never ends when a client fires on the host.**
  - DESIGN.md: protection ends on firing.
  - Protection ends only through `Pawn.fired` → `MatchDirector._on_pawn_fired` → `spawn_rules.notify_event`
    (`match_director.gd:42,123-124`). `fired` is emitted only in `Pawn.fire_shot` (`pawn.gd:102`).
  - The host's copy of a remote human never calls `fire_shot`: `host_handle_fire`
    (`scripts/net/net_match_bridge.gd:195-217`) raycasts directly.
  - So for the full `spawn_protection_s` after every spawn, a client can shoot while taking no damage.
    The host and bots lose protection as soon as they fire. Any unmodified client gets this, and it breaks
    a design rule in the milestone-1 multiplayer path.
  - Fix: after an accepted request in `host_handle_fire`, emit `pawn.fired` (or call
    `director.spawn_rules.notify_event(pid, "fire")`). Add a test next to
    `test_e2e_client_fire_damages_on_host_only` with protection left on.
- **N2 (Low): OQ-50 is used for three different things.**
  - It is the max name length (`docs/OPEN_QUESTIONS.md:100`, `data/net.json:8`).
  - It is also the "placeholder tunables moved out of scripts" entry (`docs/OPEN_QUESTIONS.md:107`),
    which is filed under Technical defaults.
  - `data/match.json:10` (squad_spacing_m) and `data/ui.json:3` cite it as well.
  - OQ-51 is listed before OQ-50.
  - Fix: give the tunables entry its own id and fix the references.
- **N3 (Low): stale note.** `docs/OPEN_QUESTIONS.md:69` still says "Still open: M1/M2". Both were fixed in F3.
- **N4 (Low): dead state.** The host stores `last_frames[pid]` (`net_match_bridge.gd:153`) and nothing reads it.
  Remove it, or use it once HOST_REMOTE pawns need input-driven state such as a crouch or animation.
- **N5 (Low): repeated corrections.** A rejected move sends a reliable `correct_position` for every packet
  (`net_match_bridge.gd:173`). That is up to `input_rate_hz` (30) per second until the snap arrives, for
  example after a respawn before `ev_respawn`. Rate-limit it to once per snapshot interval.
- **N6 (Low): hidden file read.** `BotSpawner.plan_fill` now loads `res://data/match.json` itself
  (`scripts/systems/bot_spawner.gd:16`) instead of taking the squad count as a parameter. That hides a file
  read inside a helper that was pure. Pass `squads` in from the caller.
- **N7 (Low, already noted in OPEN_QUESTIONS.md:69): no host kill events.** Kills by the host's own pawn
  (local authority) do not send `ev_kill`, so clients get no kill event for them. This affects only the
  kill feed; score and respawn are unaffected.

### Pending (not a blocker)

The two-phone manual acceptance (docs/plans/sprint1.md:497-502) is Shibi's: install the APK on two phones,
host on the hotspot, join by IP and play to 100 points.

Medium N1 is open, so this re-review iterates.

VERDICT: ITERATE
