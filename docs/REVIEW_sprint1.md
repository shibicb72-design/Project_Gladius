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

## Re-review 2

Scope: `git log --oneline a3ea02d..HEAD` (2 commits): G1 `d0e19d2` (N1, N4, N5) and G1b `99cc07f`
(N2, N3, N6). Neither commit is missing. Checked against "## Re-review" above, docs/plans/sprint1.md and
docs/DESIGN.md. This review changed no code, data or tests.

### Verification (run during this re-review)

| Step | Result |
|---|---|
| `mkdir -p build` | exit 0 |
| `godot --headless --path . --import` | exit 0, no ERROR / SCRIPT ERROR / Parse Error lines |
| `godot --headless --path . --export-debug "Android" build/gladius-debug.apk` | exit 0, "Signed" with the shared debug key, APK verified, `build/gladius-debug.apk` found by Glob, no ERROR lines |
| `godot --headless --path . --script res://tests/run_tests.gd` | exit 0, `TESTS: 89 passed, 0 failed` (was 86; +3 new tests) |

`godot` was not on the Bash PATH in this session, so each command ran as `godot.cmd` with the same arguments.

### Per-finding status

- **N1 (Medium, spawn protection on client fire): fixed.**
  - `scripts/net/net_match_bridge.gd:214`: after an accepted request (ammo used, validator passed), the
    host emits `pawn.fired`. That reaches `MatchDirector._on_pawn_fired` → `spawn_rules.notify_event(pid, "fire")`
    (`match_director.gd:42,123-124`), the same path a local shot takes (`pawn.gd:102`). It also matches
    the local order: protection ends before the raycast.
  - Rejected requests (`no_pawn`, `reloading`, `empty`, validator failures) return before line 214, so
    they keep protection. Nothing else connects to `fired` (scripts or .tscn), so the host copy gets no
    side effects.
  - Tests:
    - `tests/test_net_authority.gd:128` `test_remote_fire_ends_spawn_protection_only_when_accepted`
      (an empty shot keeps protection; an accepted shot ends it)
    - `tests/test_net_match.gd:194` `test_e2e_client_fire_ends_spawn_protection_on_host`
      (real loopback RPC; an enemy hit is blocked before the shot and does damage after it)
- **N2 (Low, OQ-50 reused): fixed.** OQ-50 now means only max name length (`docs/OPEN_QUESTIONS.md:76`,
  `data/net.json:8`). OQ-51 follows it (`:77`). The tunables entry is now OQ-52 under its own heading
  (`:110`). `data/match.json:10` and `data/ui.json:3` cite OQ-52. No other OQ-50 reference is left.
  This is a docs change, so it has no test.
- **N3 (Low, stale "M1/M2" note): fixed.** `docs/OPEN_QUESTIONS.md:69` now lists only the missing host
  `ev_kill` and quitter handling (OQ-27). Docs only, no test.
- **N4 (Low, dead `last_frames`): fixed.** The field, its write in `submit_input` (`net_match_bridge.gd:145-152`)
  and its erase in `unregister_peer` are gone. Nothing referenced it. The full suite still passes; no test
  is needed for removed code.
- **N5 (Low, repeated corrections): fixed.** `net_match_bridge.gd:170-174` sends `correct_position` at most once
  per `snapshot_interval_s` per player. `_last_correction_s` is cleared in `unregister_peer` (`:76`). The
  move is still rejected on every packet, and `_last_move_s` is still reset on each attempt (`:164`).
  Test: `tests/test_net_authority.gd:111` `test_rejected_move_corrections_are_rate_limited`.
- **N6 (Low, hidden file read): fixed.** `BotSpawner.plan_fill` takes `squad_count`
  (`scripts/systems/bot_spawner.gd:12`) and reads no file. `spawn_bots` passes it through (`:35-40`). The
  only caller, `match_root.gd:107`, passes `squads.size()`, which comes from `director.match_cfg["squads"]`
  (`:79`), so `data/match.json` stays the single source. Tests: `tests/test_bots.gd:11`
  `test_fill_counts_from_data` and `tests/test_net_authority.gd:145` `test_squad_count_single_source`.
- **N7 (Low, no host `ev_kill`): still open, still noted** at `docs/OPEN_QUESTIONS.md:69`. It affects only
  the kill feed.

### Data numbers and design values

- The only data changes are two reference strings: `data/match.json:10` (OQ-50 → OQ-52) and `data/ui.json:3`
  (OQ-50 → OQ-52).
- No value changed, no key was added, and no number was added to data/*.json.
- No DESIGN.md value was changed and no product decision was added. Protection ending on fire follows
  DESIGN.md.
- No cross-platform rule is affected: no OS, touch or renderer code changed, and `export_presets.cfg` is untouched.

### Remaining concerns

- **Low: N7, no host kill events** (`docs/OPEN_QUESTIONS.md:69`). Already noted; it affects only the kill feed.
- **Low: formatting nit** at `scripts/net/net_match_bridge.gd:33`: `var _rng :=RandomNumberGenerator.new()`
  is missing a space after `:=`. G1 introduced it; it has no functional effect.

### Pending outside this session (not blockers)

- Two-phone manual acceptance (docs/plans/sprint1.md:497-502): install the APK on two phones, host on the
  hotspot, join by IP and play to 100 points.
- First real GitHub Actions run (T-02), checked by the orchestrator after the push.

Every concern still open is Low, so this re-review approves.

VERDICT: APPROVE

## Touch review

Scope: `git log --oneline aaded41..HEAD` (3 commits). Part 1 (T1) is `c7f94fc` "feat: touch move/look sticks, look rate cap,
no stray touch fire". Part 2 (T1b) is `91a974c` "feat: touch buttons, canvas scaling, foldable relayout". Part 3 (T1c) is `b4ef0b2`
"feat: touch-sized menus, lobby bot class choice". No part is missing. Checked against the task files
C:\Users\shibi\cc_gladius\fix3\T1.txt, T1b.txt and T1c.txt, and against docs/DESIGN.md. This review changed no code, data or tests.

### Verification (run during this review)

| Step | Result |
|---|---|
| `mkdir -p build` | exit 0 |
| `godot --headless --path . --import` | exit 0, no ERROR / SCRIPT ERROR / Parse Error lines |
| `godot --headless --path . --export-debug "Android" build/gladius-debug.apk` | exit 0, "Signed" with the shared debug key, APK verified, `build/gladius-debug.apk` found by Glob, no ERROR lines |
| `godot --headless --path . --script res://tests/run_tests.gd` | exit 0, `TESTS: 106 passed, 0 failed` (was 89; 17 new tests) |

`godot` was not on the Bash PATH, so each command ran as `godot.cmd` with the same arguments. This session cannot delete
files, so an older APK was already in build/. The export log shows a fresh sign and verify, and the orchestrator's own
gate deletes the APK first. Headless tests cannot prove feel or on-device behaviour (see the Fold 7 checklist below).

### T1 (part 1): move stick, look, stray fire

| Item | Status | Where | Covering test |
|---|---|---|---|
| 1 Look units, rate cap | done | `scripts/input/look_math.gd:16-37`. `gamepad_provider.gd:22-28` and `touch_provider.gd:41-51` both use it. Placeholders are in `data/input.json:21-28` with `_placeholder`. Sensitivity, dead zone and invert_y still apply. `match_root.gd:42-44` now configures the gamepad. The pitch clamp stays only in pawn.gd. | `test_touch_controls.gd:106` `test_look_is_capped_in_both_modes`, `:137` `test_gamepad_obeys_cap` |
| 2 Right-side look, stick (default) or drag | done | `data/input.json:24` sets `"mode": "stick"`. Drag accumulates in `touch_provider.gd:27-35` and is consumed in `get_look`. Viewport-height scaling is in `look_math.gd:34-38`. Tap-to-fire works in both modes (`touch_hud.gd:229-232`). Each finger is tracked by index, and a touch that starts on a button never starts move or look (`touch_hud.gd:196-216`). | `:119` `test_small_drag_is_small_and_directional`, `:152` `test_tap_in_look_zone_pulses_fire`, `:163` `test_look_drag_is_not_a_tap` |
| 3 Floating move stick, drawn | done | Origin is where the finger lands (`touch_hud.gd:202-206`). Radius is a fraction of height (`:172-182`). `_draw` is at `:259-275`. The move zone is now the full-height left half (`data/input.json` `move_zone` top 0.0, was 0.4; placeholder OQ-35). | `:65` `test_move_stick_forward_and_release` |
| 4 No stray fire | done | Emulation goes off when the HUD shows and is restored in `_exit_tree` (`touch_hud.gd:54-83`). The switch lives in `scripts/platform/platform_services.gd:16-19`. The project setting is unchanged. | `:248` `test_mouse_emulation_off_while_hud_active_and_restored`, `:172` `test_move_touch_never_fires_or_aims` |
| 5 Behind InputProvider/Router | done | Only `touch_hud.gd:187,192` read ScreenTouch/ScreenDrag. `keyboard_mouse_provider.gd` is untouched. | the existing `test_input.gd` tests pass |
| 6 OQ-53, numbers in data | done | `docs/OPEN_QUESTIONS.md:63`. There are no `# TUNE` comments. | docs, no test |
| (a) Move forward/release + match e2e | done as T1 wrote it | `test_touch_controls.gd:65` covers the unit case. `:80` `test_move_stick_in_match_moves_pawn` covers the match, but offline only: it calls `_input` directly and gives the HUD a fixed size. | see T-MOVE below |
| (b) Cap in both modes + gamepad | done | | `:106`, `:119`, `:137` |
| (c) Tap fires/releases; move never fires/aims; emulation restored | done | | `:152`, `:172`, `:248` |

**Root cause of "could not walk": partly given.** The commit message has no cause. The part-1 session summary
(cc_gladius\out\T1.json) says the failure "couldn't be reproduced headless" and lists likely contributors: the stick was
invisible, the old move zone ignored the top 40% of the screen, and the emulated left click held "fire". It suggests the
touch coordinate space on the device as the next thing to check. That is allowed by T1:7, but no cause is confirmed.

### T1b (part 2): buttons, scaling, foldable

| Item | Status | Where | Covering test |
|---|---|---|---|
| 1 canvas_items / expand | done | `project.godot:13-14`. The renderer is unchanged. | the full suite passes |
| 2 Five round, labelled buttons | done | `data/input.json:40-52` (`_placeholder_buttons`, OQ-35). Buttons are anchored right with grid cells (`touch_hud.gd:109-163`). They are round (corner radius = size/2), use mouse_filter IGNORE and focus NONE, and each touch index is tracked in `_button_touch`. There is no sprint or pause button. | `:186`, `:199`, `:213` |
| 3 Detection in platform layer | done | `touch_hud.gd:63-65` → `platform_services.gd:6-12` | `test_ui.gd` `test_touch_hud_hidden_when_not_touch` |
| 4 Foldable relayout | done | `touch_hud.gd:48-49` connects `resized` and `size_changed` to `relayout()` (`:109-121`). Zones and stick radius are worked out from `_area()` each time. No device sizes are in scripts. | `:228` `test_relayout_folded_and_unfolded` (calls `relayout()` directly; the signal wiring is not tested) |
| 5 Gyro unchanged, no Settings | done | The diff does not touch the gyro provider, `main_menu.gd` Settings entries or DESIGN.md. | none |
| 6 Numbers in data | done | `data/input.json:30-45` | none |
| (c) Each button + multitouch | done | | `:186` `test_each_button_presses_and_releases_its_action`, `:199` `test_fire_button_works_with_move_finger_held` |
| (d) Visible, five labels, no sprint | done | | `:213` |
| (f) 2316x1000 and 2184x1968 | done | | `:228` |

### T1c (part 3): lobby and menus

| Item | Status | Where | Covering test |
|---|---|---|---|
| 1 Touch-sized menus | done | `scripts/ui/ui_scale.gd:8-40` sets the minimum Button height and theme font size from `data/ui.json` (placeholders, OQ-54). It is bound in `main_menu.gd:47`, `end_screen.gd:30` and `lobby.gd:71`, and re-applied in `refresh()`. Containers only. | `test_ui.gd` `test_menu_buttons_meet_touch_target_height` |
| 2 Bot class choice | done | Overrides are in `lobby_state.gd:15-18,51-55`. They apply only to bot slots (`:81`) and are serialized (`:99,109-112`). Unknown classes, human slots and started matches are refused. The host-only path is `net_lobby.gd:55-60` (it uses `_broadcast`). Lobby rows are in `lobby.gd:97-141`. The match reads `class_id` from `assign()` (`match_roster.gd:41`). | `test_net_lobby.gd` `test_bot_class_override_state`, `test_bot_override_reaches_client`; `test_ui.gd` `test_lobby_bot_row_cycles_class` |
| 3 OQ-54, OQ-55 | done | `docs/OPEN_QUESTIONS.md:115-116` | docs |
| (e) LobbyState + UI row + client sync | done | The client-sync check was also done over loopback. | as above |
| (g) Heights at 1000 and 1968 | done | The test passes the height to `apply_to` directly. The resize-signal path and font size are not tested. | `test_menu_buttons_meet_touch_target_height` |

### DESIGN.md and rules

- **No sprint (DESIGN.md:15): OK.** There is no sprint action in project.godot, data, scenes or scripts, and the test asserts it.
- **Right-side aim stick, tap-to-fire, default (DESIGN.md:31): OK.** `look.mode` is `"stick"`, and tap-to-fire works in both modes.
  Drag is an opt-in placeholder (OQ-53).
- **No Settings screen or gyro behaviour (OQ-34): OK.** Neither changed.
- **Numbers marked as placeholders: OK.** The `look` block has `"_placeholder": true`. `touch_layout` has `"_placeholder": true` and `"_placeholder_buttons": true`.
  `data/ui.json` has `"_placeholder": true` and cites OQ-54. OQ-53 (`:63`), OQ-54 (`:115`) and OQ-55 (`:116`) exist.
- **Screen events only in the HUD, platform checks in scripts/platform/: OK.** `OS.get_name`, `is_touchscreen_available`
  and `emulate_mouse_from_touch` appear only in `platform_services.gd`. Keyboard/mouse is unchanged. The gamepad now goes
  through the same rate cap. All input, router and match tests pass.
- **emulate_mouse_from_touch restored when the match ends: OK.** When the match scene is freed (`AppFlow.go` to the end
  screen, `match_root.gd:174`), `TouchHud._exit_tree` runs and restores the previous value (`touch_hud.gd:54-55,79-82`).
  Tested at `test_touch_controls.gd:248`.
- DESIGN.md is unchanged in this range.

### Findings

#### High

- **T-MOVE: the required device-path walking test is missing.** No test sends touch events through
  `Input.parse_input_event` (a grep for `parse_input_event` finds nothing in the repo).
  `test_move_stick_in_match_moves_pawn` (`tests/test_touch_controls.gd:80-103`) has three gaps:
  - it runs offline only;
  - it calls `hud._input()` directly;
  - it forces `hud.size = 1152x648` with a top-left preset, so it bypasses viewport event dispatch, the canvas_items
    stretch transform and the HUD's real full-rect sizing.

  Those are exactly the paths that could explain the unconfirmed "could not walk". On the Fold, a match is started from
  the lobby as host (networked `match_root.gd:89-100`), and that path has no touch-move test at all.

  Fix: add two integration tests, one offline and one as host with a lobby (an isolated `NetSession.host_game()` plus
  `AppFlow.lobby`/`lobby_override`, as `test_match_roster.gd` does). Each test instantiates `scenes/match/match.tscn` and
  forces the touch HUD on. Set the root window size instead of the HUD size: the headless root is 64x64, so use
  `get_tree().root.size = Vector2i(1152, 648)` or a content-scale size. Then send `InputEventScreenTouch` and
  `InputEventScreenDrag` with `Input.parse_input_event` in the left move zone, call `Input.flush_buffered_events()` and
  await process and physics frames. Finally, assert that `local_player.global_position` changed horizontally.
  (T1 told the engineer not to use `parse_input_event`, so this gap comes from the brief, not from the implementation.)

#### Medium

- **Tap-to-fire and the Fire button share one action** (`touch_hud.gd:88-91`, `:219-224` and `:229-232`). Say one finger holds
  Fire and another taps the look zone: 0.08 s later the pulse calls `Input.action_release("fire")` while the Fire button
  is still held, and firing stops. The reverse also happens: releasing the Fire finger during a pulse cuts the pulse
  short. Fix: release "fire" only when neither the pulse nor any button finger holds it. Add a multitouch test for this.
- **Root cause for walking not confirmed** (see T1 above). Close it with T-MOVE and the Fold 7 check below.

#### Low

- `ui_scale.gd:25-27` duplicates the theme on every call, and `lobby.gd` `refresh()` calls `apply_to` on every lobby
  state change. Each call also reloads `data/ui.json` from disk. This is harmless at current sizes, but the theme copies pile up.
- `look_math.gd:7-9` and the `get(..., default)` fallbacks in `touch_hud.gd` repeat the placeholder numbers in scripts.
  data/input.json is still the source; the fallbacks only apply if a key is missing.
- `UiScale.bind` and `TouchHud` resize wiring are untested. The tests call `apply_to(h)` and `relayout()` directly.

### Shibi to check on the Galaxy Z Fold 7 (folded cover screen and unfolded inner screen)

1. **Sticks visible:** a ring and knob appear under the left thumb wherever it lands on the left half, and under the
   right thumb in stick mode. They disappear on release.
2. **Walking:** drag the left thumb up, down, left and right. The gladiator walks forward, back and strafes, both offline
   (if reachable) and in a hosted lobby match. Repeat after folding or unfolding mid-match.
3. **Look speed:** a full right-stick push turns smoothly, with no spinning: about 180°/s, capped at 360°/s (placeholders).
   Small pushes give fine aim. Report whether it is too slow or too fast (OQ-36, OQ-53).
4. **Button sizes:** Fire, Aim, Reload, Swap and Jump are round, read as full words, sit bottom-right, do not overlap, and
   are easy to hit on both screens. Menu and lobby buttons are thumb-sized and their text is readable.
5. **Tap-to-fire:** a quick tap on the right half fires one shot. Holding the left stick never fires or aims. Holding
   Fire while tapping the look area currently stops firing (the Medium finding above).
6. **Lobby bot classes:** as host, tap a bot row to cycle Hastati ⇄ Sagittarii. The row updates, a joined phone sees the
   change, and the bots spawn with those classes. Tapping your own row changes your class.
7. Back in the menus after a match, taps still work (touch-to-mouse emulation restored).

The acceptance test T-MOVE is missing, so this review iterates. Everything else in T1, T1b and T1c is done, the suite
passes 106/0, and DESIGN.md is not contradicted.

VERDICT: ITERATE

## Touch proof review

Scope: C1 `1040044` (T-MOVE and touch capture tool), C2 `bd5f304` (T-MOVE at Fold resolutions, touch default), and C3
`d7f54a4` (always-visible touch sticks). I read `build/shots/{folded,unfolded}_report.txt` and looked at all ten PNGs.

### Verification (run during this review)

- `godot --headless --path . --import`: no errors.
- `godot --headless --path . --script res://tests/run_tests.gd`: **115 passed, 0 failed**. All six T-MOVE tests pass
  (offline and host, each at the default size, 2520x1080 and 2176x1812). So do both rest-stick tests, the recentre test and
  `test_ui.gd::test_lobby_bot_row_cycles_class`.
- I did not re-run the APK export; this review changes only this document.

### Checklist

| Check | Result | Evidence |
|---|---|---|
| T-MOVE uses real `InputEventScreenTouch`/`InputEventScreenDrag` | yes | `test_touch_controls.gd:117-153` builds the events, delivers them, and the HUD's `_input` turns them into stick state |
| at 2520x1080 and 2176x1812 | yes | It resizes the real root window, then asserts the viewport aspect and that the HUD fills the viewport (`:124-129`) |
| offline and as host | yes | `_move_offline` and `_move_host` (`:200`), with the host on an isolated ENet session through `NetSession.host_game()` |
| asserts a real position change | yes | It measures the XZ delta of `m.local_player.global_position` and asserts it is above 0.05 m |
| no assertion weakened or deleted | yes | `git diff 9bf9671 d7f54a4 -- tests/` only adds tests. `run_tests.gd` gains `--only`/`--repeat` (filtering only). `test_net_match.gd` parks non-bot pawns out of the line of fire and adds a diagnostic suffix. The shield assertion is unchanged. |
| touch HUD not forced in capture | yes | `touch_capture.gd:56` sets `PlatformServices.simulate_touchscreen`, which `is_touch_device()` reads (`platform_services.gd:16`, desktop branch only). Report: `force_touch_hud=false ... HUD visible=true`. |
| lobby buttons >= 48 dp | **not proven** | See finding 1 |
| camera clamp holds | yes | Both reports show pitch 0 → 70.0 against the data clamp [-70, 70], `within clamp: true`. `folded_hud_look.png` shows the camera stopped at the limit. |
| every PNG labelled "desktop render, not device" | yes | All 10 PNGs carry the yellow label with the tag (`touch_capture.gd:38`) |
| C3: both sticks visible at rest, both sizes | yes | `folded_hud_rest.png` and `unfolded_hud_rest.png` show the left and right rings with centred knobs and no buttons overlapping. The walk shot shows the move stick recentred under the thumb, and the look shot shows the look knob deflected. Tests at `:375-417`. |
| C3: debug label at bottom-centre | yes | `PRESET_CENTER_BOTTOM` with grow-both (`touch_capture.gd:39-41`). It is bottom-centre in every PNG. |
| C3: bot class change from the host lobby (OQ-55) | **code and unit test yes; touch proof no** | See finding 2 |
| C3: T-MOVE's `push_input` counts as real touch input | **partly** | See finding 3 |

### Findings

#### High

1. **The 48 dp lobby result uses the desktop's DPI, not the device's.** Both reports say `dpi=168 (desktop-reported; pass
   --dpi=N for the device)`, and the capture was not re-run with a device DPI. Folded, a lobby button is 98 window px
   tall: 0.09 of 1080, from the OQ-54 placeholder. A 2520x1080 cover screen of about 6.5" is about 420 ppi, and Android
   density is typically 2.625 (420 dpi) at that ppi. That gives about **37 dp**. The button reaches 48 dp only if the
   density is at or below about 2.0 (≤ 323 dpi), which is unlikely for this panel. Unfolded, 163 px at that density is
   about 62 dp, which matches the "about 64 dp" note in OQ-54. OQ-54's figure only holds unfolded. The HUD buttons pass
   either way: 173 px folded is about 66 dp.
   Fix: re-run `tools/touch_capture` with `--dpi=<value from the Fold 7>` (or log `DisplayServer.screen_get_dpi()` on the
   device). If folded is under 48 dp, make `UiScale` enforce a dp floor (48 dp × `screen_get_scale`/DPI via the platform
   layer) on top of the height fraction, and update OQ-54. Shibi's device check 4 covers this by eye. The report should
   not claim `lobby_buttons_min_48dp=true` until the number is real.

#### Medium

2. **The capture never shows a host lobby, so bot class cycling (OQ-55) has no touch proof.** `touch_capture.gd:149-151`
   instantiates the lobby without hosting. `AppFlow.ensure_session` creates a bare `NetSession`, so `is_host=false`. The
   lobby PNGs show "Connected. Waiting for the host to start.", a state a player never sees, with no Start button. Both
   taps are no-ops in both reports: `'Class: hastati' -> 'Class: hastati'` and `'Bot 1 (hastati) [bot]' -> 'Bot 1
   (hastati) [bot]'`. The feature itself works. `lobby.gd:97-105` is host-gated, and `test_ui.gd:125-140` passes on a
   hosted lobby, but only through `pressed.emit()`, not a tap.
   Fix: in the capture, host first, as `test_ui.gd:_host_lobby` does (`AppFlow.session = s; s.host_game()`). Then tap the
   bot row and the class button through `Input.parse_input_event`, and log a `RESULT bot_class_cycled=` line that must
   read true.

3. **T-MOVE's `push_input(e, true)` is the real dispatch, but not the full Android path.** On Android, the OS event goes
   through `Input.parse_input_event` (input state, touch-to-mouse emulation, drag accumulation), then
   `Window._window_input`, then `Viewport.push_input(e, false)`. The last step maps window pixels into canvas space
   through the stretch transform (×1/1.667 folded, ×1/1.889 unfolded), then dispatches to every node's `_input`.
   T-MOVE (`test_touch_controls.gd:110-111`) enters at that last step with `in_local_coords=true`. It hands canvas
   coordinates straight in, so it skips the Input singleton and the window-to-canvas transform. Everything after that is
   real: real event classes, the real viewport dispatch, and the HUD → provider → router → pawn chain. A bug in the
   coordinate space, which is exactly what differs between the folded and unfolded screens, would not fail T-MOVE.
   The capture tool covers that gap. It sends window-pixel events through `Input.parse_input_event`
   (`touch_capture.gd:246-272`) and walked 4.64 m folded and 4.71 m unfolded. That is a report, not an assertion,
   though. The message at `:141` ("reached the HUD via Input") is also inaccurate.
   Fix: add a T-MOVE variant that converts the zone centre with `get_screen_transform()` and delivers it with
   `push_input(e, false)`, so an asserting test covers the stretch transform. Reword the message at `:141`.

#### Low

- Capture overlays sit on top of lobby content. The green "touch auto-detected" note covers the "Player (hastati)" row,
  and the bottom label covers the "Back" text (both lobby PNGs). Fine for debug shots, but keep this in mind before
  judging layout from them.
- Folded, the shield and health bars draw across the bottom of the move-stick ring (`folded_hud_rest.png`). Unfolded,
  the look ring overlaps the third-person pawn. Both are cosmetic. The stick-to-button overlap test does not cover the
  stat bars.
- Godot imports the PNGs (`build/shots/*.png.import`) because `build/` has no `.gdignore`. Git ignores them, but a
  `build/.gdignore` would keep the import step quiet.
- The Medium finding on tap-to-fire and the Fire button sharing one action, from the touch review above, was outside
  C1-C3 and is not re-checked here.

C1 and C2 are honest work. No assertion was weakened, T-MOVE drives real touch event objects into the full gameplay
chain at both Fold sizes, offline and hosted, and C3's sticks and label are right. Three required checks do not hold:
48 dp on the folded screen is unproven and arithmetically likely to fail, the host-lobby bot change has no touch proof,
and T-MOVE skips the window-to-canvas step of the Android input path.

VERDICT: ITERATE
- Re-run the capture with the device DPI, and add a dp floor if folded lobby buttons are under 48 dp (finding 1, OQ-54).
- Host the lobby in the capture and prove that tapping a bot row cycles its class (finding 2, OQ-55).
- Add a T-MOVE variant that enters through `push_input(e, false)` with window coordinates (finding 3).

## Touch proof re-check

Scope: C4 `48fc25e` ("fix: dp floor, host-lobby capture, window-coord T-MOVE"), checked against the three ITERATE items above.

### Verification (run during this re-check)

- `godot --headless --path . --import`: no errors. `--export-debug "Android" build/gladius-debug.apk`: no errors, and the
  APK exists.
- `godot --headless --path . --script res://tests/run_tests.gd`: **122 passed, 0 failed**, with no `SCRIPT ERROR`,
  `Parse Error` or `ERROR:` lines. The seven new tests pass: four window-coordinate T-MOVE tests, two HUD-clearance tests
  and `test_dp_floor_holds_at_420_and_373_dpi`.
- I re-ran the capture myself: `tools/touch_capture.tscn` at `--resolution 2520x1080 --dpi=420` (twice) and at
  `2176x1812 --dpi=373` (once). Then I looked at all ten regenerated PNGs.
- I ran two throwaway probes, kept in the gitignored `build/` and not committed. `probe_xf.gd` prints the headless root
  screen transform. `probe_tap.gd` taps a freshly hosted lobby's class button three ways.

### Checklist

| Check | Result | Evidence |
|---|---|---|
| Lobby/menu buttons >= 48 dp, folded at 420 dpi | yes | `UiScale.min_button_height` = max(height fraction, `min_touch_target_dp` × dp_scale / px_scale). Report: 76.0 canvas = 126.7 window px = **48.3 dp**, all 9 lobby buttons pass. The floor drives the height (fraction alone = 58.3 canvas ≈ 37 dp). |
| Lobby/menu buttons >= 48 dp, unfolded at 373 dpi | yes | 87.0 canvas = 164.4 px = **70.5 dp**. The fraction drives the height here. |
| dp floor is data-driven and honest | yes | `min_touch_target_dp: 48.0` in `data/ui.json`, labelled as the Android guideline, not a design value. OQ-54 says 420/373 dpi are assumptions until the device run. `boot.gd` logs `[display] ... screen_get_dpi=` for that run. DPI comes from `PlatformServices` (no Android assumption, 160 fallback). |
| Hosted-lobby capture: `bot_class_cycled=true` by tap | yes | `lobby hosted: is_host=true`. The bot row goes `hastati -> sagittarii` in all three of my runs, and `*_lobby_after.png` shows "Bot 1 (sagittarii)". |
| Hosted-lobby capture: `player_class_toggled=true` by tap | **no, not reproducible** | See finding 1. In all 3 of my runs: `'Class: hastati' -> 'Class: hastati'`, `RESULT player_class_toggled=false`. Both `*_lobby_after.png` still read "Class: hastati". |
| Window-coord `push_input(e, false)` T-MOVE, offline + host, both sizes | yes | Four tests pass. `_deliver(e, true)` maps canvas to window with `get_screen_transform()` and delivers with `push_input(e, false)`, so the viewport's own inverse brings it back to canvas space. The probe shows the transform is not identity in headless: ×1.667 at 2520x1080 (visible 1512x648) and ×1.889 at 2176x1812 (1152x959). The test therefore exercises the stretch step. |
| Nothing overlaps sticks or buttons | yes | Stat bars, weapon and ammo moved top-left (`hud_layout.stat_block_pos`, placeholder, OQ-35/OQ-54). `_check_hud_clear` asserts no HUD rect intersects either stick or any button, all inside the viewport, at both canvas and window sizes. In all six HUD PNGs nothing overlaps the stick rings or buttons. The deflected look knob in `unfolded_hud_look.png` comes close to Reload but does not touch it. |
| No assertion weakened (`git diff 1db000f HEAD -- tests/`) | yes | +103/−13 lines. The 13 removed lines are signature changes (`window_coords` parameter added) and one message re-worded ("via Input" → "via Viewport.push_input (… coordinates)", fixing the earlier finding 3 wording). All thresholds (`> 0.05`, aspect `< 0.01`, size match) are unchanged. Only tests were added. |

### Findings

#### Medium

1. **The capture's "tap" is a synthetic mouse click, and the first one after the lobby opens is dropped, so
   `player_class_toggled` depends on where the desktop cursor happens to be.** `touch_capture.gd:132-147` (`_mouse`/`_tap`)
   sends `InputEventMouseButton` press/release through `Input.parse_input_event` with no preceding motion. The committed C4
   reports said `true`, but every one of my three re-runs (folded twice, unfolded once) logged
   `player_class_toggled=false`. The bot-row tap, which comes second, worked every time. `build/probe_tap.gd` isolates the
   cause on a freshly hosted lobby:
   - mouse button only: tap 1 and tap 2 both no-op;
   - mouse motion to the point, then button: tap 1 `hastati -> sagittarii`, tap 2 back;
   - `InputEventScreenTouch` press/release (what Android delivers, mouse emulated by Godot): tap 1 `hastati -> sagittarii`,
     tap 2 back.
   So **the product works on a real tap**. The defect is in the proof tool. It is not a real touch, and it is not
   reproducible, so the required "player_class_toggled=true by tap" result is not proven.
   Fix: make `_tap` send `InputEventScreenTouch` (index 0, window coordinates, press, 2 frames, release) instead of mouse
   buttons, as the HUD drags already do. Make the capture exit non-zero, or print `RESULT ... FAILED`, when any RESULT line
   is false. Re-run both sizes and commit nothing from `build/`.

#### Low

- `test_dp_floor_holds_at_420_and_373_dpi` checks the formula with hard-coded px_scale values. It does not lay out a lobby
  at those sizes. The capture covers that end to end, so this is acceptable.
- `test_move_window_coords_*` does not assert that `get_screen_transform()` is non-identity. The probe shows it is today
  (×1.667 / ×1.889). An `assert_true(absf(xf.get_scale().y - 1.0) > 0.1)` would stop a future headless or stretch change
  from silently turning the variant back into the canvas-coordinate test.
- Capture overlays still cover content. Folded, the green note sits on the shield and health bars (they are at 0.08 ×
  648 ≈ 52 canvas px). In the lobby PNGs the bottom label covers "Back". This affects debug shots only.
- Folded, the lobby slot list shows about 3.5 rows before scrolling (Squad II is below the fold). This is expected with
  48 dp rows on a 648-unit-tall canvas. Shibi's device check should confirm the list scrolls by drag.
- `hud.gd:_place_stats` reloads `data/ui.json` on every `resized`. This is cheap but could use the cached config.

C4 fixes all three ITERATE items in code. The dp floor is real, data-driven and correctly flagged as an assumption until
the device reports its DPI. The window-coordinate T-MOVE runs through a non-identity stretch transform offline and as
host at both Fold sizes. The HUD is now clear of the sticks and buttons, and an assertion guards that. No assertion was
weakened. The remaining gap is in the evidence, not the game: the capture's tap is a cursor-dependent mouse click, so one
of the two required lobby RESULT lines fails on re-run.

VERDICT: ITERATE
- `tools/touch_capture.gd`: tap with `InputEventScreenTouch` instead of motionless mouse clicks, so
  `player_class_toggled=true` and `bot_class_cycled=true` are reproducible by touch on every run (finding 1).
- Make the capture fail loudly on any false RESULT, then re-run folded (`--dpi=420`) and unfolded (`--dpi=373`).
- Optional: assert the window-coords T-MOVE transform is non-identity.

## Touch proof re-check 2

Scope: C5 `6e24522` ("fix: touch taps in capture, fail on false RESULT"), checked against `fix3c/C5.txt` items 1-5.

### Verification (run during this re-check)

- `godot --headless --path . --import`: no errors. `--export-debug "Android" build/gladius-debug.apk`: no errors, and the
  APK exists.
- `godot --headless --path . --script res://tests/run_tests.gd`: **123 passed, 0 failed**, with no `SCRIPT ERROR`,
  `Parse Error` or `ERROR:` lines.
- `git diff c29a2b3 HEAD -- tests/`: +40/−0 lines. No assertion was removed or weakened.
- Capture, run once per size, windowed: `tools/touch_capture.tscn` at `--resolution 2520x1080 --dpi=420` (folded) and
  `--resolution 2176x1812 --dpi=373` (unfolded). I looked at all ten PNGs.

| RESULT line | folded / 420 | unfolded / 373 |
|---|---|---|
| `lobby_buttons_min_48dp` | true (48.3 dp) | true (70.5 dp) |
| `lobby_action_buttons_inside_viewport` | true | true |
| `player_class_toggled` | **false** | **false** |
| `bot_class_cycled` | true | true |
| `touch_on_by_default` | true (not forced) | true (not forced) |
| `walk_moved / look_changed / pitch_bounded` | true | true |
| final line | `RESULT FAILED: 1 false RESULT line(s)` | `RESULT FAILED: 1 false RESULT line(s)` |

### Checklist

| C5 item | Result | Evidence |
|---|---|---|
| 1. `_tap` sends `InputEventScreenTouch` (index 0, window coords, press, 2 frames, release) | yes in code | `touch_capture.gd:145-149` calls `_touch_event`, which maps canvas to window with `get_screen_transform()` (`:271-276`). The mouse helper is gone. |
| 2. Fail loudly on any false RESULT | yes | `touch_capture.gd:74-86` logs `RESULT FAILED: ...` and calls `quit(1)`. It fired on both of my runs. |
| 3. Window-coords T-MOVE asserts a non-identity transform | yes | `test_touch_controls.gd:140-142`: `absf(scale.y - 1.0) > 0.1`, only in the window-coords variant. |
| 4. Overlays clear of stat bars and Back | yes | Notes are top-right, below the timer row. In all six HUD PNGs the stat bars, weapon and ammo text are uncovered. In the lobby PNGs Back is uncovered. |
| 5. Folded lobby: action bar always on screen, >= 48 dp, roster scrolls in the rest | yes for layout; drag-scroll not proven | `folded_lobby_before.png`: Class / Start / Back are one full-width row at the bottom, fully visible. The roster shows Squad I, Squad II and Bots 1-5 with a scrollbar on the right, with Bot 5 partly below the fold. Unfolded shows the whole roster with no scrolling. `test_lobby_buttons_inside_viewport_at_both_fold_sizes` asserts every non-row button is inside the viewport and >= 48 dp, the bar is inside, the roster ends above the bar and is taller than two rows, at both sizes and DPIs. |
| `player_class_toggled=true` and `bot_class_cycled=true` on every run | **no** | `player_class_toggled=false` on both runs, folded and unfolded (`'Class: hastati' -> 'Class: hastati'`). The bot-row tap, the second tap, worked both times. |

### Findings

#### High

1. **The first tap after the lobby opens is still dropped, so `player_class_toggled` fails at both sizes.** Item 1 was
   implemented as specified, but the symptom from re-check 1 is unchanged: the first tap (Class) is a no-op and the second
   (bot row) works. The PNGs point at the cause. In each `*_lobby_before.png` exactly one row shows the hover style,
   wherever the real desktop cursor sits over the window: the Player row folded, the Bot 2 row unfolded. So the windowed
   capture still receives real OS mouse motion. That motion most likely moves Godot's mouse/hover state between the
   emulated press and release. `BaseButton` then sees the release as outside the button and does not emit `pressed`.
   Once the first emulated touch has moved Godot's mouse position, the next tap works. This is an inference from the PNGs
   and the log, not a confirmed trace. C5 asked for this RESULT to be true on every run, and it is false on every run I made.
   Fix: first confirm with a throwaway probe in `build/` that logs every `InputEvent` the class button gets between press
   and release. Then make the capture independent of the cursor, for example by parking the OS cursor outside the lobby
   (`Input.warp_mouse` to a corner) before the first tap. Any such change belongs in `tools/` only, not in the lobby or
   input code, and must not weaken the RESULT check. Re-run each size 3 times.

#### Low

- Drag-to-scroll on the roster (item 5, "scrolls by touch drag") has no assertion. The roster is a `ScrollContainer`
  with `rows_box` set to `MOUSE_FILTER_PASS`, but the slot `Button`s keep the default filter. Nothing shows that a drag
  starting on a row scrolls instead of being swallowed by the button. Add a test, or a capture step, that drags from
  a row in the folded lobby and asserts `scroll_vertical` increased. Shibi's device check should also cover this.
- Item 5 says "every lobby button" inside the viewport. The test and the capture exempt slot rows. That is reasonable,
  because rows are scroll content, but nothing asserts that rows are clipped to the scroll rect.
- The capture overlay still sits over the right end of the Player row in both lobby PNGs. The row text is left-aligned
  and stays readable. This affects debug shots only.

C5 does items 1-4 as specified. The folded lobby rework (item 5) fixes the clipped Back button and the squeezed list.
The action bar is fully on screen and >= 48 dp at both sizes, and a test guards that. No assertion was weakened, and
the suite is green. But the acceptance condition was "every RESULT line true on every run", and the capture itself now
exits non-zero with `RESULT FAILED` at both sizes. The player-class tap is still not proven by touch.

VERDICT: ITERATE
- `player_class_toggled=false` on both runs (folded 420 dpi, unfolded 373 dpi). The capture reports `RESULT FAILED` and
  exits 1. Make the first capture tap independent of the desktop cursor (finding 1), then re-run each size 3 times.
- Add a touch-drag scroll assertion for the folded roster (Low, but item 5 asks for it).
