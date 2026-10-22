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

## Touch proof re-check 3

Scope: C6 `7943ce8` ("fix: cursor-independent capture taps, roster drag-scroll test"), checked against `fix3c/C6.txt`
items 1-4. The commit changes `tools/touch_capture.gd` (+18), `tests/test_ui.gd` (+56/−0) and one line of product code,
`scripts/ui/lobby.gd:148`.

### Verification (run during this re-check)

- `godot --headless --path . --import`: no errors. `--export-debug "Android" build/gladius-debug.apk`: no errors, and the
  APK exists.
- `godot --headless --path . --script res://tests/run_tests.gd`: **124 passed, 0 failed**, with no `SCRIPT ERROR`,
  `Parse Error` or `ERROR:` lines.
- `git diff 4b84062 HEAD -- tests/`: +56/−0, all in the new test. No assertion was removed or weakened.
- Capture, run 3 times per size, windowed, output in `build/shots_v4/`: `--resolution 2520x1080 --dpi=420` (tags
  `folded1-3`) and `--resolution 2176x1812 --dpi=373` (tags `unfolded1-3`). All six runs exited 0 with no
  `RESULT FAILED` line.

| RESULT line | folded / 420, runs 1-3 | unfolded / 373, runs 1-3 |
|---|---|---|
| `lobby_buttons_min_48dp` | true ×3 (48.3 dp) | true ×3 (70.5 dp) |
| `lobby_action_buttons_inside_viewport` | true ×3 | true ×3 |
| `player_class_toggled` | **true ×3** (`hastati -> sagittarii`) | **true ×3** |
| `bot_class_cycled` | true ×3 | true ×3 |
| `touch_on_by_default` | true ×3 (not forced) | true ×3 (not forced) |
| `walk_moved / look_changed / pitch_bounded` | true ×3 (4.64-4.71 m; pitch 70°, inside the ±70° clamp) | true ×3 |

### Checklist

| C6 item | Result | Evidence |
|---|---|---|
| 1. Probe that logs every event during the first tap, to confirm the cause | yes, built into the capture | `touch_capture.gd:72-77` swallows non-emulated mouse events and, while `_trace_events` is set (`:203-206`), logs every event the first Class tap delivers. On every run the trace shows exactly the expected four events (emulated mouse press, ScreenTouch press, emulated mouse release, ScreenTouch release), all at the button centre. It also logs 5-6 real desktop mouse events swallowed. That count is the stray OS input that re-check 2 inferred from the hover highlight. A separate `build/` probe was not kept, but the in-capture trace is the stronger evidence. |
| 2. Capture independent of the desktop cursor | yes | `touch_capture.gd:83` parks the OS cursor at the top-right (over the non-interactive overlay). `:72-75` drops real mouse events, so only emulated touch reaches the GUI. In the `*_lobby_before.png` shots, no row shows the hover style any more (re-check 2 saw one hovered row in each). This is capture-only code. No lobby or input code changed for it. |
| 3. Touch-drag scroll test from a slot row, with a product fix if the drag is swallowed | yes, with one limitation (Low 1) | `test_ui.gd:220-274`. The product fix is `scripts/ui/lobby.gd:148` (`row.mouse_filter = MOUSE_FILTER_PASS`). **Real cause, confirmed:** I temporarily removed that line and re-ran the suite. The new test failed with `roster saw { "touch": 0, "drag": 0 }`, meaning the default `MOUSE_FILTER_STOP` on the row `Button` stopped every touch and drag from reaching the `ScrollContainer`. With the line restored, the suite is back to 124/0 and `git diff` is clean. |
| 4. 3 runs per size, every RESULT true, all tests pass | yes | See the table above. |

### PNGs

I opened `folded1_lobby_before/after`, `unfolded2_lobby_before/after`, `folded3_hud_walk` and `unfolded3_hud_look`.
- Lobby: before, the Player row reads `hastati`. After the taps it reads `sagittarii`, with `Class: sagittarii` on the
  button and Bot 1 changed `hastati -> sagittarii`. No row is hover-highlighted. In the folded shots, Class / Start / Back
  are one full-width bar at the bottom, and the roster scrolls (scrollbar visible, Bot 5 partly below the fold). In the
  unfolded shots, the whole roster fits.
- HUD: both sticks are visible. The move knob is deflected in `hud_walk`, and the look knob is deflected in `hud_look`.
  The five labelled buttons are bottom-right. The stat bars, weapon and ammo text are uncovered, and the overlay sits
  top-right below the timer row.

### Findings

#### Low

1. **On desktop and headless hosts the test never checks that the roster scrolls.** `test_ui.gd:268-269` asserts
   `scroll_vertical > 0` only when `DisplayServer.is_touchscreen_available()`, which is false on desktop and headless. So
   on this machine, and in CI, it proves only that the events reach the `ScrollContainer` (`:267`). That still catches the
   bug C6 fixed (shown above), but not the scrolling itself. C6 asked for the scroll assertion. The comment states the
   limitation honestly, and nothing was weakened. Shibi's device check should include a drag on the folded roster.
2. **A drag that starts on a row could also count as a tap.** With `MOUSE_FILTER_PASS`, the row `Button` still receives
   the press. Nothing tests that a drag-then-release on a bot row does not also emit `pressed`, which would cycle that
   bot's class. Add this to the device check. If it happens on hardware, cancel the press once the drag passes a
   threshold.
3. The capture's `_input` filter (`touch_capture.gd:72-75`) drops all real mouse input for the whole run, including the
   match phase. This is acceptable for a capture tool, but it means the PNGs say nothing about mouse/keyboard play.
   (Unchanged carry-over: the overlay still overlaps the right end of the Player row in the lobby PNGs, debug shots only.)

C6 does what `fix3c/C6.txt` asked. The first-tap failure is now explained by a logged trace and removed by a capture-only
change. All RESULT lines are true on all six runs at both fold sizes and DPIs. The one product change has a demonstrated
cause at `scripts/ui/lobby.gd:148`. No assertion was weakened, and the suite is green.

VERDICT: APPROVE
- `player_class_toggled=true` and every other RESULT true on 3/3 folded (420 dpi) and 3/3 unfolded (373 dpi) runs, exit 0.
- The cause is confirmed by the per-event trace. The fix is in `tools/` only, and the PNGs show no hover artefact.
- Product change `lobby.gd:148` verified necessary: removing it makes the new test fail with 0 touch / 0 drag events.
- Left for the on-device check, not blocking: real scrolling on a touchscreen, and drag-on-row not triggering a class change (Low 1-2).

## D1 review

Scope: D1 `cd633af` ("feat: apply Shibi decisions OQ batch 1"), checked against `fix3c/D1.txt` (Shibi's 8 decisions of
2026-10-22). The commit changes `data/loadouts.json`, `data/stats.json`, `docs/OPEN_QUESTIONS.md`, `export_presets.cfg`,
`scripts/systems/match_root.gd`, `scripts/systems/save_service.gd` and `scripts/ui/main_menu.gd`, and adds
`tests/test_decisions_batch1.gd` (+ `.uid`).

### Verification (run during this review)

- `godot --headless --path . --import`: exit 0, no errors.
- `godot --headless --path . --export-debug "Android" build/gladius-debug.apk`: exit 0, no `ERROR:` lines, APK exists.
- `godot --headless --path . --script res://tests/run_tests.gd`: exit 0, **129 passed, 0 failed** (124 before + the 5 new
  D1 tests). No `SCRIPT ERROR`, `Parse Error`, `ERROR:` or `WARNING` lines.
- `git show cd633af --stat -- tests/`: only the new test file was added. No existing test was edited, so no assertion was
  removed or weakened. `docs/DESIGN.md` is not in the commit.
- Probe (`build/vd_probe.gd`, not committed): in Godot 4.7.2, `input_devices/sensors/enable_gyroscope` exists and
  defaults to `false`. `project.godot` does not set it.

### Checklist

| D1 item | Result | Evidence |
|---|---|---|
| 1. OQ-01/02: package id `com.shibibabu.gladius` (preset and CI), launcher name "Project Gladius" | yes | `export_presets.cfg:38` `package/unique_name="com.shibibabu.gladius"`, `:39` `package/name="Project Gladius"`. `project.godot` `config/name` is "Project Gladius". `.github/workflows/android.yml` has no package id (it only exports `build/gladius-debug.apk`), so CI needed no change. No `com.placeholder` is left outside the OQ history. |
| 2. OQ-04: sensor landscape, preset matches | yes | `project.godot:15` `window/handheld/orientation=4` (= `SCREEN_SENSOR_LANDSCAPE`, checked by the test). Godot 4.7's Android preset has no orientation key of its own. It exports the project setting, so the preset matches by construction. |
| 3. OQ-29: lobby class toggle per human, large touch button, host-authoritative, applies at match start and next spawn | yes (already built in S10/C6; D1 adds a test) | `scripts/ui/lobby.gd:59-62,101-107` Class button in the full-width action bar, sized by `UiScale` (48 dp floor, measured 48.3/70.5 dp in touch re-check 3). Clients send `_request_update` to the host (`net_lobby.gd:51,72-78`), and the host applies it and syncs. `match_roster.gd:41` spawns with the slot's `class_id`. `pawn.gd:72` rebuilds the loadout from `class_id` on respawn. |
| 4. OQ-08/10: Hastati Pilum BR + Gladius Lux; Sagittarii long-range single-shot rifle + Gladius Lux; rifle in stats.json, placeholder and `# TUNE` | yes | `data/loadouts.json` sagittarii primary is `sagittarii_rifle`. `data/stats.json` adds `sagittarii_rifle`: `kind` hitscan, `burst_count` 1, `range_m` 200, `"_placeholder": true`, `"# TUNE": "all numbers are placeholders"`, `_todo` naming OQ-06/07/08/10. The markers are entry-level, not per number. That is how every other weapon entry is marked, so I accept it. |
| 5. OQ-17: jump stays in, OQ marker removed, numbers still placeholder | yes | `stats.json` movement `_todo` now cites only OQ-18. `jump_enabled` is true and `_placeholder` is kept. |
| 6. OQ-30/31: fill to 2 squads of 3 at Tiro | yes (no code change needed) | `data/match.json` `squads: 2`, `squad_size: 3`. `data/bots.json` `match_fill.profile: "tiro"`, read by `bot_spawner.gd:26,38`. |
| 7. OQ-24/25: Alesia hilltop citadel section, greybox | yes (no code change needed) | OQ entries updated. Map data unchanged. |
| 8. OQ-34: gyro off by default, On/Off toggle in settings, saved to user:// | **partly** | Default off: `save_service.gd:18`. Toggle: `main_menu.gd:43-45,64-71` (the disabled "Settings (later)" entry was swapped for a real gyro button, so the button count is unchanged). Saved to `user://profile.json` (`save_service.gd:41,52`). The match reads it: `match_root.gd:45-48`. **But the On state can't work on a device**, see Important 1. |
| OPEN_QUESTIONS.md: the 12 OQs marked DECIDED, others untouched | yes | The diff touches exactly OQ-01, 02, 04, 08, 10, 17, 24, 25, 29, 30, 31 and 34. Each says "DECIDED (Shibi, 2026-10-22): ..." and keeps the old placeholder text as history. |
| Required tests | yes | `test_decisions_batch1.gd`: package id and name read from `export_presets.cfg` and ProjectSettings; orientation; the lobby toggle changes the class and the spawned `Pawn` loadout matches (both directions); the Sagittarii loadout contains the rifle; gyro is off by default, the menu toggle persists On and back Off through a fresh `SaveService`, and the temp file is cleaned up. |

### CROSS-PLATFORM and iOS rules

- Gyro reads go through `scripts/platform/platform_services.gd:51-63` (`OS.get_name()` switch, Android/iOS only, no-op
  elsewhere and on headless). `GyroProvider` is a swappable provider in `scripts/input/providers/`. No gameplay code reads
  raw touch or sensors.
- The save goes to `user://` through `SaveService`. There are no hard-coded paths.
- No plugin, GDExtension or Android-only API was added. Both the gyro path and the new menu button have an iOS/desktop
  path. `export_presets.cfg` still has only the Android preset. The renderer is unchanged (Mobile).
- The new menu button uses the existing `_button()`/`UiScale` path (containers, touch-target floor).

### Findings

#### Important

1. **Gyro "On" gives no input on Android (or iOS), because the engine never turns the sensor on.** In Godot 4.7.2,
   `input_devices/sensors/enable_gyroscope` defaults to `false` (confirmed by the probe), and `project.godot` doesn't set
   it. With it off, the engine never registers the gyroscope listener, so `Input.get_gyroscope()` stays at zero and
   `GyroProvider.get_look()` (`gyro_provider.gd:16-20`) returns `Vector2.ZERO` even when the player picks On. Decision 8
   asks for a working On/Off toggle. As shipped, On saves and shows "On" but does nothing, and the headless tests can't
   catch it. **Fix:** set `input_devices/sensors/enable_gyroscope=true` in `project.godot`. The profile toggle still
   gates gyro use in `GyroProvider`, so default-off behaviour is unchanged. The setting is cross-platform, and it is
   ignored where there is no gyro. Add a test that asserts the setting is true. Include a gyro On check on the Fold7 in
   Shibi's device pass.

#### Low

1. `GyroProvider.sensitivity` is hard-coded `1.0` (`gyro_provider.gd:8`). Now that gyro can be switched on, this is a
   tunable number outside `data/`. Move it to `data/input.json` as a placeholder (OQ-34/OQ-36) when fixing Important 1.
   This is a carry-over, not introduced by D1.
2. `data/input.json:5` `"gyro_mode": "off"` is now dead. `match_root.gd:47` builds the gyro config only from the profile,
   so the file value is never read. Remove it, or note that the profile owns the setting.
3. Stale labels left over after decision 6: `data/match.json:10` `_note` still calls `squads` "a placeholder matching
   OQ-30, not a design value", and `data/bots.json` `match_fill` (squad_size 3, profile tiro) still has
   `"_placeholder": true`. The values are right and now decided. Only the labels are out of date. They err on the safe
   side, so this is not blocking.
4. The offline/standalone branch hard-codes `local_player.class_id = "hastati"` (`match_root.gd:108`). That branch runs
   only without a lobby (tests, standalone scene). Every real match goes through the lobby, so the toggle applies there.
   This is a carry-over.

D1 applies decisions 1-7 as stated and the OQ log exactly as asked. Nothing outside the brief was invented, the
placeholders are clearly marked, no test was weakened, and the suite is green at 129/0. Decision 8 is wired end to end
in data and UI, but the engine sensor switch is missing, so the On setting does nothing on the target devices.

VERDICT: ITERATE
- Important 1: set `input_devices/sensors/enable_gyroscope=true` in `project.godot` (with a test). Otherwise gyro "On"
  (decision 8, OQ-34) never produces input on Android/iOS.
- Everything else passes: decisions 1-7, the OPEN_QUESTIONS.md update, the required tests, import/export/tests exit 0
  with 129 passed / 0 failed, no weakened assertions, and the CROSS-PLATFORM and iOS rules hold. The Low items can go in
  the same small fix.

## D2 review

Scope: D2 `beddc7c` ("fix: enable gyro sensor, D1 review lows"), checked against `fix3c/D2.txt` items 1-6 and the
"## D1 review" findings above. The commit changes `data/bots.json`, `data/input.json`, `data/match.json`, `project.godot`,
`scripts/input/providers/gyro_provider.gd`, `scripts/systems/match_root.gd` and `tests/test_decisions_batch1.gd`.

### Verification (run during this review)

- `godot --headless --path . --import`: exit 0, no errors.
- `godot --headless --path . --export-debug "Android" build/gladius-debug.apk`: exit 0, no `ERROR:` lines, APK exists.
- `godot --headless --path . --script res://tests/run_tests.gd`: exit 0, **132 passed, 0 failed** (129 before + 3 new).
  No `SCRIPT ERROR`, `Parse Error`, `ERROR:` or `WARNING` lines.
- `git show beddc7c --stat`: the 5 deleted lines are all in `data/` and `scripts/`. `tests/test_decisions_batch1.gd` has
  insertions only (+37) and no other test file is touched, so no assertion was removed or weakened. `docs/DESIGN.md` is
  not in the commit.

### Checklist

| D2 item | Result | Evidence |
|---|---|---|
| 1. `enable_gyroscope=true` + test (D1 Important 1) | yes | `project.godot:104-106` `[input_devices] sensors/enable_gyroscope=true`. `test_gyro_sensor_enabled_in_project` asserts the ProjectSettings value is `true`. |
| 2. Gyro sensitivity to `data/input.json` as placeholder (D1 Low 1) | yes | `input.json` `gyro: {"_placeholder": true, "_todo": "OQ-34, OQ-36 ...", "sensitivity": 1.0}`. `match_root.gd:47-48` reads it and passes it to `GyroProvider.configure()`, which applies it (`gyro_provider.gd:17-18`). The field default `1.0` stays only as a fallback, and the comment points to the data file. `test_gyro_sensitivity_from_data` checks the key exists and that configure applies it. |
| 3. Dead `gyro_mode` (D1 Low 2) | yes | Removed from `input.json` and replaced by `_gyro_note` saying the profile (`gyro_enabled`, default off) owns it. The test asserts the key is gone. No code reads it from data (grep). |
| 4. Stale labels (D1 Low 3) | yes | `match.json` `_note` now says squads = 2 is DECIDED (OQ-30), while `squad_spacing_m` keeps its TODO (OQ-52). `bots.json` `match_fill` loses `_placeholder` and cites the decision (OQ-30/31). Values unchanged. The `profiles` and `brain` placeholders are untouched, which is correct. |
| 5. Gyro off by default, with sensor on and fake reading injected | yes | `test_gyro_off_by_default_ignores_injected_reading`: default profile -> `gyro_mode` "off"; a `FakeGyroPlatform` (has_gyro true, rate (0.5, 0.25, 0)) is injected; `get_look()` == ZERO and `InputRouter.update_frame().look` == ZERO. A sanity step then toggles On and gets `(0.25, 0.5)`, which proves the fake really flows and the off result is not vacuous. Runs with the project setting true (item 1 test, same suite). |
| 6. iOS NSMotionUsageDescription comment | yes | `gyro_provider.gd:4-6`. |

### CROSS-PLATFORM and iOS rules

- `enable_gyroscope` is an engine-wide setting with no platform tie and is ignored on devices without a gyro. Gyro reads
  still go only through `PlatformServices` (`OS.get_name()` switch, no-op on desktop/headless). No plugin, GDExtension
  or Android-only API was added. The iOS permission string is noted for the port. Renderer (Mobile) and
  `export_presets.cfg` (Android only) are unchanged.
- Gyro stays off by default: the gate is `GyroProvider.enabled`, fed only from the profile (`save_service.gd:22`,
  default `gyro_enabled` false).

### Findings

No Critical or Important findings.

#### Low

1. `docs/OPEN_QUESTIONS.md` OQ-36 still reads "Default look sensitivity (stick, touch)". The new `gyro.sensitivity`
   placeholder cites OQ-34/OQ-36 in the data file, but OQ-36 doesn't mention gyro. Add "gyro" to OQ-36 in the next docs
   pass so the open question covers the new placeholder. Not blocking: the value is clearly marked `_placeholder`.
2. D1 Low 4 (offline branch hard-codes `class_id = "hastati"`, `match_root.gd`) is still open. It wasn't in the D2 brief
   and only affects the no-lobby path. Carry-over.
3. On-device check is still needed: gyro On on the Fold7 in Shibi's device pass (headless tests can't read a real
   sensor).

D2 does all 6 brief items and closes D1 Important 1 and Lows 1-3. The suite is green at 132/0, gyro stays off by default
with the sensor enabled (now tested with an injected reading), and no assertion was weakened.

VERDICT: APPROVE
- D1 Important 1 is fixed and tested (`enable_gyroscope=true`). Gyro stays off by default through the profile gate,
  proven by a test with a fake gyro reading at both provider and router level.
- Items 2-6 are done, import/export/tests exit 0 (132 passed / 0 failed), and no test was weakened. The remaining Lows
  (OQ-36 wording, the offline class carry-over, the device gyro check) are not blocking.

## E1 review

Scope: E1 `e336bd3` ("feat: Oct 22 decisions (stats, energy blade, scoring, digits)"), checked against
`fix3c/E1.txt` items 1-10 and ALSO a/b. 28 files, +576/-53. `docs/DESIGN.md`, `project.godot`,
`export_presets.cfg` and `android/` are not in the commit.

### Verification (run during this review)

- `godot --headless --path . --import`: exit 0, no errors.
- `godot --headless --path . --export-debug "Android" build/gladius-debug.apk`: exit 0, no `ERROR:` lines, APK signed
  with the shared debug key and verified.
- `godot --headless --path . --script res://tests/run_tests.gd`: exit 0, **148 passed, 0 failed** (132 before + 16 new
  in `tests/test_decisions_oct22.gd`). No `SCRIPT ERROR`, `Parse Error` or `ERROR:` lines.

### Checklist

| E1 item | Result | Evidence |
|---|---|---|
| 1. OQ-06 starter stats, all weapons, data-driven | yes | `data/stats.json` covers `pilum_br`, `gladius_lux` and `sagittarii_rifle` (damage, fire interval, burst, range, spread, magazine, reserve, reload, headshot_multiplier, plus melee fields for the blade), all `_placeholder: true`. `WeaponDef.from_dict` reads the new melee keys, and no script hard-codes a weapon number. `docs/STATS.md` has the reasoning comment block and marks the Sagittarii design as PLACEHOLDER, NOT a Shibi decision (also in the rifle's `_todo`, which a test asserts). |
| 2. OQ-07 Gladius Lux energy blade | yes | `kind: "melee"`, `scripts/weapons/melee.gd` (range + arc hit test, world-occlusion ray, same authority Callable as Hitscan), `swing_visual.gd` placeholder sweep. `pawn.fire_shot()` and the host path `net_match_bridge.gd:213-217` both branch to `melee_swing`. `Weapon.has_ammo()` and `start_reload()` mean the blade never consumes ammo or reloads. Pilum BR stays hitscan, burst 3. |
| 3. OQ-13 per-weapon headshot multiplier, shield = health | yes | Tested for Pilum and rifle on shield-only and health-only states. The weapons carry different multipliers. |
| 4. OQ-20 independent squads, up to 6 | yes | `test_six_squads_score_independently`. |
| 5. OQ-21/22 contested = no score, top tie = draw | yes | Contested test with 3 of 6 squads inside, 6-squad tie-at-top test, plus a clear-leader control. |
| 6. OQ-38 plain digits behind `hud.roman_numerals:false` | yes | `HudNumbers` is the single formatter. HUD, end screen and lobby headers use it. `RomanNumerals` and `test_roman_numerals_1_to_100` are kept. Score 0 renders "0", squads read "Squad 1..6". |
| 7. OQ-41/27 behaviour | yes | IP field pre-filled from `last_ip` (tested). Host IPs listed via `IP.get_local_addresses()` (`lobby.gd:95`, already there). Late join after `start()` is rejected (tested). A host drop sends a lobby client back (`lobby.gd:75`). New: an in-match client drop goes to the menu (`match_root.gd:108,196-201`). |
| 8. OQ-42/43/46/47 starting set, OQ-48 open | yes | `traits.json` and `medals.json` status says STARTING SET, still data-driven. OQ-48 stays OPEN in both the data and the docs. |
| 9. OPEN_QUESTIONS marked DECIDED | yes | OQ-06, 07, 13, 20, 21, 22, 27, 38, 41, 42, 43, 46 and 47 each have a one-line "DECIDED (Shibi, Oct 22 2026)" entry. |
| 10. Tests | yes | All six requested areas are covered in `tests/test_decisions_oct22.gd`. |
| ALSO a. OQ-36 covers gyro | yes | `OPEN_QUESTIONS.md:62` now names the `data/input.json` `gyro.sensitivity` placeholder. Closes D2 Low 1. |
| ALSO b. No hard-coded `hastati` offline | yes | `match.json` `default_class`, then the profile's `last_class`, then the first enabled class (`MatchRoot.offline_class_id`). Disabled or unknown classes are skipped. Tested, including the fallbacks. Closes D1 Low 4 / D2 Low 2. |

### Assertion audit (were any tests weakened?)

Three existing test files changed. None of the changes weakens a check:
- `test_stats_data.gd::test_weapons`: `gladius_lux` left the gun-key loop (magazine/reload/spread > 0 can't hold for a
  blade by decision OQ-07), and `sagittarii_rifle` joined it. The blade's keys are now asserted > 0 against
  `MELEE_KEYS`, with `_placeholder`, in `test_stats_json_loads_every_weapon`. That is net stronger, because every
  weapon in the file is now checked.
- `test_weapons.gd`: the fire-interval and reload tests switched their subject from `gladius_lux` to
  `sagittarii_rifle`, with the same assertions. This is needed because the blade has no magazine.
- `test_ui.gd`: the expected strings changed from Roman to digits, as OQ-38 directs. The Roman expectations are kept
  as assertions with `roman_numerals = true`, and zero-score assertions were added.

### CROSS-PLATFORM and iOS rules

No plugin, GDExtension, Android-only API or `OS.get_name()` branch was added. Melee uses core physics queries, and
the swing visual uses only `MeshInstance3D`/`StandardMaterial3D`/Tween, so it is renderer-agnostic. The host-drop
path uses the ENet `server_disconnected` signal through `NetSession`. Settings stay in `res://data`, with no file
paths. Input is still read only through the input layer (`_frame.fire` -> `fire_shot`). The renderer and the
Android-only `export_presets.cfg` are unchanged.

### Findings

No Critical or Important findings.

#### Medium (non-blocking, docs)

1. **Blade vs the DESIGN.md melee rule is not logged as an open question.** DESIGN.md says "Melee every class: front =
   70% of full shield; Gladiator front breaks full shield in one hit; from behind = instant kill". The Gladius Lux
   swing deals flat `damage` (60) from any angle and never tests the head (`headshot_multiplier` 1.0). `docs/STATS.md:41-43`
   and the `gladius_lux._note` in `stats.json` explain this choice, but `docs/OPEN_QUESTIONS.md` has no entry for
   it, and the house rule requires undecided points to go there. OQ-16 also still says melee is OUT of milestone 1,
   which is now stale against OQ-07. Fix: add an OQ ("Does a Gladius Lux swing follow the DESIGN melee rule (70%
   front / back = instant kill / head)?"), and add a pointer from OQ-16 to OQ-07.

#### Low

1. `docs/STATS.md:9-10` arithmetic: with a 200 total for Hastati and 20 per bullet, a body-hit kill takes **10** bullets
   (about 7 with headshots), not "about 30" (about 20). The 120 dmg/s and ~1.7 s TTK figures are right. Shibi tunes
   from this file, so correct it.
2. `test_lobby_start_blocks_late_joins_and_host_drop_goes_to_menu_handler` calls `_on_host_lost()` directly and only
   checks the flag. It doesn't prove that `session.host_lost` is connected for clients (`match_root.gd:108`) or that the
   menu change happens (that branch is skipped under `lobby_override`). Consider a loopback test that closes the host
   and asserts the handler ran.
3. `lobby.gd:144` calls `HudNumbers.roman_enabled()` for every squad header on every `refresh()`. It is cached by
   `DataRegistry`, but it builds a new registry each time. Read it once into a member as `hud.gd` does.
4. On-device check: the blade's swing feel and the visual on the Fold7 (headless tests can't judge feel or
   readability).

VERDICT: APPROVE
- All 10 E1 items and both ALSO items are implemented and tested. Import, export and tests all exit 0 (148 passed / 0
  failed), and no project errors were printed.
- No existing assertion was weakened. The three edited test files keep or strengthen their checks, and every change
  follows a Shibi decision (OQ-07, OQ-38).
- The iOS and cross-platform rules hold. The Medium item (log the blade-vs-DESIGN melee question, refresh OQ-16) and
  the Lows are docs/test polish for the next pass, not blockers.

## G0 review

Reviewer: Opus (VG0), Oct 22 2026. Target: commit a1e3182 against `cc_gladius/fixG/G0.txt` items 1-5 and a-d,
using `fixG/VTEMPLATE.txt`.

INPUTS: tests log/exit code = FOUND (`cc_gladius/tests_G0.log`; `fix3c.log:84` "GATE G0 apk=True tests=0 shots=60";
re-run here: 159 passed / 0 failed, exit 0) ; apk = FOUND (`build/gladius-debug.apk`, re-exported here, exit 0) ;
shots = FOUND (n=60 in `build/shots/*.png`, including cover/inner portrait and landscape Fold sizes) ; step commit =
FOUND (a1e3182, 31 files, +1467/-17)

Gates run in this review, each as its own command: `--import` exit 0, `--export-debug "Android"` exit 0 (signed with
the shared debug key), `run_tests.gd` exit 0 (159 passed, 0 failed). No "SCRIPT ERROR", "Parse Error" or "ERROR:"
lines in any of the three outputs.

### What checks out
- **1. Engine reference:** `git diff --no-index` of the staged
  `Claude-Code-Game-Studios-1.2.0/docs/engine-reference/godot/` against `docs/engine-reference/godot/` shows no
  differences except the added `LICENSE`, and that `LICENSE` is identical to the staged source `LICENSE`.
  `THIRD_PARTY.md` records the repo, tag v1.2.0, commit 05ad7c8a..., zip SHA-256 031BE54B..., the vendored path and MIT.
- **2.** `cc_gladius/common.txt:13` has the GODOT API RULE word for word.
- **3.** `fixG/VTEMPLATE.txt` has the FOUND/ABSENT input table (tests log/exit code, APK, shots >= 4, step commit),
  NOT ASSESSED when any input is ABSENT ("FAILS the step... never treated as approve"), and APPROVE/ITERATE otherwise.
  `fixG/orch_notassessed.diff` is a valid unified diff of `fix3corch.ps1`: the hunk `@@ -5,6 +5,9 @@` context and `-`
  lines match `fix3corch.ps1:5-10` exactly, and the line counts add up. It changes the regex to
  `VERDICT: (APPROVE|ITERATE|NOT ASSESSED)`, logs it, and pings "blocked" then exits on NOT ASSESSED, ITERATE or a
  missing verdict. `fix3corch.ps1` still has the old `(\w+)` regex (not applied), and `run_step.ps1:14` still has no
  `--settings` (not edited).
- **5.** Nothing else from CCGS was imported: the commit has no hooks, statusLine, agents, skills or CLAUDE.md
  protocol (`git show --stat a1e3182`).
- **a. STATS.md:9-12** now says 10 body hits, about 7 with headshots (200/30 = 6.7), 4 bursts = about 1.5 s.
  `tests/test_stats_doc.gd` derives those numbers from `data/stats.json` through `DataRegistry` and checks that the doc
  text contains them.
- **b. Host drop:** `test_net_match.gd:118-129` builds a real loopback ENet pair (`_start_pair`, which appends a
  failure rather than skipping if the pair does not come up). It closes the host with `host.leave()`
  (`net_session.gd:87-92`, `_peer.close()`), waits for `cm.host_lost_handled` (set only by
  `match_root.gd:198 _on_host_lost`, connected at `match_root.gd:110` from `net_session.gd:41`
  `server_disconnected`), and asserts the menu path `AppFlow.MENU_SCENE`. It passed in this run.
- **c.** `lobby.gd:27` caches `HudNumbers.roman_enabled()` in `roman_numerals` in `_ready`. `lobby.gd:147` uses the
  member, and there is no per-refresh call.
- **d. Melee vs DESIGN.md:15** ("front = 70% of full shield; Gladiator front breaks full shield in one hit; from
  behind = instant kill"):
  - `damage_rules.gd apply_melee`: the front hit is `max_shield * melee_front_shield_fraction`, so it uses the FULL
    shield, not the current one. For classes in `front_breaks_full_shield_classes` (["gladiator"]) it is at least
    `max_shield`. A hit from behind zeroes shield and health and sets `killed`. The friendly, protected and dead guards
    are the same as in `apply_hit`. Both cases go through the shared shield-then-health `_deal`, and no further rule
    was invented.
  - Front/back: `melee.gd is_from_behind` takes the flat angle between the TARGET's facing and target -> attacker.
    `pawn.gd receive_melee` reads `melee_back_angle_deg` from `registry.get_melee_cfg()` on every hit, so it is read at
    runtime. `data_registry.gd:94-100` validates both new keys next to the weapon checks.
  - Both hit authorities route melee there: local `pawn.gd:142` and host `net_match_bridge.gd:227-231`. No other
    `receive_hit` caller exists in `scripts/`.
  - `stats.json` `melee` lists `melee_back_angle_deg` and `front_hit_no_shield_rule` in `_placeholders`, with
    PLACEHOLDER/OQ-56 notes. The gladius_lux `damage` key is kept and only its `_note` changed, so `MELEE_KEYS` at
    `test_decisions_oct22.gd:7` still holds.
  - Tests (`tests/test_melee_rule.gd`, all PASS): front 70% of full (including a damaged shield), Gladiator front
    breaks a full Triarii shield, back hit is an instant kill, the no-shield front hit takes 70 off health
    (PLACEHOLDER), angle just inside and just outside the threshold on both sides, plus a Pawn-level test using real
    facing.
  - Changed assertions: only `test_decisions_oct22.gd:111` (was `:109`), whose expected value changes from
    `shield_before - def.damage` (the old flat-60 blade) to `shield_before - max_shield * melee_front_shield_fraction`.
    In the `:88` and `:117` tests only setup lines were added (`front.rotation.y = PI`, `victim.rotation.y = PI`).
    Their assertions and the outside-arc, friendly-fire and `:131` checks are unchanged, and nothing was removed.
  - `OPEN_QUESTIONS.md`: OQ-56 is DECIDED (Shibi, Oct 22 2026) with the wording from G0 plus a clearly marked
    no-shield PLACEHOLDER. OQ-16 now puts melee IN milestone 1 and points to OQ-07 and OQ-56.
- **iOS/Android:** the only "Android" strings in `scripts/` are in `scripts/platform/platform_services.gd`
  (`"Android", "iOS"` switch arms). The commit adds no plugin, GDExtension, JavaClassWrapper or singleton.
- **GODOT API RULE (APIs this commit relies on):** `docs/engine-reference/godot/breaking-changes.md:91` covers only
  `FileAccess.store_*` return types. `test_stats_doc.gd` uses `FileAccess.open`/`get_as_text`, which are not affected.
  `Vector3.angle_to`, `ENetMultiplayerPeer.close` and `server_disconnected` do not appear in `breaking-changes.md` or
  `deprecated-apis.md`.

### Open findings
1. **Critical (item 4 not delivered): `.claude/settings.json` does not exist in the repo.** It is not on disk (Read:
   file does not exist) and not in a1e3182. `fixG/settings_proposal.md:8-11` says the Write tool refused because the
   harness protects `.claude/`. The proposed content in `settings_proposal.md:24-71` is correct: it has only
   `permissions.deny`, covering rm -rf variants, force-push, reset --hard, clean -f, sudo, chmod 777, Read/Edit `.env`
   and PowerShell `Remove-Item -Recurse`/`-r`, with no hooks, agents or statusLine. The deny rules are not active,
   though, so the item is not done. Fix: Shibi creates the file from `settings_proposal.md` (or grants the write and
   re-runs that sub-step), or chooses the `--settings` alternative in `run_step.ps1`. This needs a human decision or
   permission, so a code iteration alone cannot close it.
2. Minor: `docs/STATS.md:28` table still shows Gladius Lux damage "60 per swing", which contradicts `STATS.md:14-15`
   and `:42-49`. G0 named only lines 13-14 and 41-43, but the table now misleads anyone tuning from it. Suggest
   "DESIGN.md:15 rule (60 unused)".
3. Minor: with a Gladiator attacker, a front hit on a target with no shield left takes the full `max_shield` off
   health (`apply_melee` `maxf(dmg, max_shield)` then `_deal`; tested at `test_melee_rule.gd:59-62`), not 70%. This
   follows the same placeholder path, but the OQ-56 PLACEHOLDER text only mentions "the 70%-of-full-shield amount".
   Add one line to OQ-56 so Shibi sees this consequence. No code change is needed.
4. Minor: `pawn.gd receive_melee` falls back to hard-coded `90.0` if the key is missing. `validate()` catches a missing
   key, so this is only belt-and-braces, but the data file should stay the single source.
5. Minor: the host-drop test asserts the menu change through the `go_scene` test hook (`match_root.gd:200-202`), not
   the real `AppFlow.go`. This is acceptable for headless tests, but the real scene change remains an on-device check.

VERDICT: ITERATE
- Gates and every code item (1-3, 5, a-d) pass, and no assertion was weakened beyond the allowed flat-60 change.
- G0 item 4 is missing: the repo `.claude/settings.json` deny block was never created (finding 1). It needs Shibi to
  create the file or grant the write. Findings 2-5 are minor and can ride along.

## G0b review

Reviewer: Opus (VG0b), Oct 22 2026. Target: commit f0d6725 ("fix: G0b review lows") against
`cc_gladius/fixG/G0b.txt` a-d, using `fixG/VTEMPLATE.txt`.

INPUTS: tests log/exit code = FOUND (full suite re-run in this review: `run_tests.gd` exit 0, "TESTS: 164 passed,
0 failed"; `cc_gladius/tests_G0b.log` and `gate_G0b.log` also exist) ; apk = FOUND (`build/gladius-debug.apk`,
re-exported in this review, exit 0, "Signed", "Verifying APK... DONE") ; shots = FOUND (n=60 in `build/shots/*.png`,
including folded/unfolded and cover/inner portrait and landscape Fold sizes) ; step commit = FOUND (f0d6725, 8 files,
+127/-14)

Gates run in this review, each as its own command from the repo root: `mkdir -p build`, `--import` exit 0,
`--export-debug "Android" build/gladius-debug.apk` exit 0, `run_tests.gd` exit 0. No "SCRIPT ERROR", "Parse Error" or
"ERROR:" lines in any of the three outputs.

### What checks out
- **a. STATS.md:28** no longer says "60 per swing". The cell now reads "front 70 (Hastati), front 56 (Sagittarii);
  Gladiator attacker front 100 (Hastati), Gladiator attacker front 80 (Sagittarii); back instant kill". These are
  0.7 x max shield and the full max shield for the enabled classes in `data/stats.json`.
  `tests/test_stats_doc.gd:29 _derive_melee` derives them from `DataRegistry` (fraction from `get_melee_cfg()`,
  classes filtered by `enabled`). `:43` pins the derived values, `:49-62` checks every figure in the doc text with
  `text.contains`, and `:62` asserts "60 per swing" is gone. The gladius_lux `"damage": 60` key is still in
  `stats.json:56`, so `MELEE_KEYS` (`test_decisions_oct22.gd:7`) still holds.
- **b. OQ-56** (`OPEN_QUESTIONS.md:115`) has "(3) PLACEHOLDER: with a Gladiator attacker, a front hit on a target with
  no shield left takes the full max_shield amount off health. DESIGN.md and STATS.md don't say this and it is not a
  Shibi decision". The code already did this before G0b (`damage_rules.gd:69-71`, `maxf(dmg, max_shield)` then `_deal`;
  existing assertion `test_melee_rule.gd:62`), so no code change was needed and none was made.
  `gladiator_front_hit_no_shield_rule` is added to `stats.json` melee `_placeholders` with a PLACEHOLDER note.
  `test_melee_rule.gd:65` checks the placeholder marker, the full 80 off health for a Gladiator attacker, and 56 for a
  non-Gladiator attacker. No other rule was invented.
- **c. pawn.gd receive_melee** (`:98-112`) has no back-angle fallback. `:100` checks `cfg.has("melee_back_angle_deg")`.
  If the key is missing it returns a `HitResult` with `blocked_reason = "invalid_melee_cfg"` and no damage, and calls
  `push_error` (`:107`). `:110` reads `cfg["melee_back_angle_deg"]` directly. The cfg comes from
  `registry.get_melee_cfg()` (`:99`). The seam (`:22-25`, `melee_cfg_override` = {} and `melee_error_sink` = an
  invalid Callable by default) is set nowhere in `scripts/`, so runtime behaviour is unchanged.
  `DataRegistry.validate()` now calls the new static `validate_melee` (`data_registry.gd:94`, `:104-118`), which
  reports a missing key instead of defaulting it to 0.0. Tests: `test_melee_rule.gd:79` (override without the key:
  "invalid_melee_cfg", damage 0, shield and health stay 100, one error naming the key) and `:103` (real cfg is clean;
  in-memory dicts missing the angle or the fraction each report exactly that key; out-of-range angle still reported).
  `data/stats.json` was not edited for the tests.
- **d. Assertions:** in `git show f0d6725 -- tests` both test hunks contain only added lines, so no existing assertion
  was changed, weakened or removed. Added: `test_stats_doc.gd:28-64` (`_derive_melee`, two tests) and
  `test_melee_rule.gd:65-112` (three tests). The unrelated 90.0 hits (`test_damage_rules.gd:84`,
  `test_touch_controls.gd:294-295`) and `stats.json` melee `"melee_back_angle_deg": 90` are untouched. The G0b summary
  (`cc_gladius/out/G0b.json`) correctly says every touched test is "added" and none are changed, and it names each
  one. See minor finding 1 for the missing line numbers.
- **.claude/settings.json** is present. Its only key is `permissions.deny`, with 128 entries (counted per line,
  4-44). `git diff HEAD~1 -- .claude/settings.json` is empty, and the file is not in `git show --stat f0d6725`.
- **iOS/Android:** the only "Android" strings in `scripts/` are the `"Android", "iOS"` switch arms in
  `scripts/platform/platform_services.gd:37,53,68` (plus a comment at `:23`). The commit adds no plugin, GDExtension,
  JavaClassWrapper or singleton.
- **GODOT API RULE:** the commit relies on `push_error`, `Callable.is_valid`/`call`, `Dictionary.has`/`is_empty`,
  `PackedStringArray.append_array` and `FileAccess.open`/`get_as_text`. None of them is listed in
  `docs/engine-reference/godot/deprecated-apis.md`. `breaking-changes.md:91` covers only `FileAccess.store_*` return
  types, which the commit doesn't use. `deprecated-apis.md:28` (Callable-based connections) is consistent with the
  Callable sink.

### Minor findings (non-blocking)
1. The G0b summary lists the touched tests by function name, not by `file:line` as G0b d) asked. The content is
   accurate (verified above against the diff). Next time, give line numbers.
2. `damage_rules.gd:68` still has a hard-coded `0.7` fallback for `melee_front_shield_fraction`, and `pawn.gd:111`
   defaults `front_breaks_full_shield_classes` to `[]`. Both predate G0b and are outside G0 finding 4, which was about
   the 90.0 back angle. `validate_melee` now reports a missing fraction, but the hit path would still silently use
   0.7. Suggest the same treatment as the back angle in a later step.
3. The error-path test goes through `melee_error_sink`, so the `push_error` branch (`pawn.gd:107`) itself is never
   executed by a test. This was deliberate, to keep the gate free of "ERROR:" lines, and the branch is trivial.
4. OQ-56 (2) still ends "no special Gladiator case for health", right before (3) describes the Gladiator outcome. They
   don't contradict each other (the same max-shield amount goes down the same path), but rewording (2) would read
   more clearly.

VERDICT: APPROVE
- All gates pass in this review (import, Android export and 164/164 tests, all exit 0, with no error lines), and all
  inputs are FOUND.
- G0b a-d are delivered. No assertion was weakened or removed, settings.json is unchanged with 128 deny entries, and
  no Android-only API is used outside the platform layer. Findings 1-4 are minor.

## G1 review

Reviewer: Opus (VG1), Oct 22 2026. Target: commit 982448a ("feat: switch to Jolt physics", 12 files, +451/-17)
against `cc_gladius/fixG/G1.txt`, using `fixG/VTEMPLATE.txt`.

INPUTS: G1 commit = FOUND (982448a, non-empty diff) ; tests log/exit code = FOUND (`cc_gladius/tests_G1.log`;
`cc_gladius/fixG.log:4` "GATE G1 apk=True tests=0 shots=70"; full suite also re-run in this review, exit 0,
"TESTS: 173 passed, 0 failed") ; apk = FOUND (`build/gladius-debug.apk`, re-exported in this review, exit 0, "Signed",
"Verifying APK... DONE") ; shots = FOUND (Fold-size `build/shots/{cover,inner}_*.png` n=30: cover 2520x1080 and inner
2184x1968, landscape and portrait sets; 70 PNGs in `build/shots/` in total) ; docs/PHYSICS_JOLT.md = FOUND (55 lines)

Gates run in this review, each as its own command from the repo root: `mkdir -p build`, `--import` exit 0,
`--export-debug "Android" build/gladius-debug.apk` exit 0, `run_tests.gd` exit 0. No "SCRIPT ERROR", "Parse Error" or
"ERROR:" lines in any of the three outputs.

### What checks out
- **Engine setting.** `project.godot:108-110` `[physics] 3d/physics_engine="Jolt Physics"`. Before G1 the key was
  absent (`git grep physics b02e610 -- project.godot`: no match), as PHYSICS_JOLT.md:6 says.
  `tests/test_physics_baseline.gd:50-51` asserts the value is exactly "Jolt Physics".
- **Baseline is measured, not typed in.** `data/physics_baseline.json` holds full-precision values ("engine":
  "GodotPhysics3D", tolerance_pct 5.0). `test_physics_baseline.gd:32-47` reads it, asserts 0 < tolerance <= 5
  (`MAX_TOLERANCE_PCT` :10, so the 5% cannot be widened in data), measures every metric and asserts each is within
  tolerance. I re-ran it both ways in this review:
  - Jolt (committed setting): `PHYSICS_METRICS {"jump_air_time_s":0.716666666666667,"jump_apex_m":1.28420352935791,
    "max_slope_deg":45.5,"max_step_up_m":0.12,"walk_speed_mps":5.000004529953}`, matching the Jolt column of
    PHYSICS_JOLT.md:17-23.
  - GodotPhysics3D (project.godot temporarily edited to `"GodotPhysics3D"`, `--only=test_physics_baseline`, then
    restored; `git status` clean afterwards): `"jump_apex_m":1.28415989875793`, all other metrics as above. This is
    byte-identical to `physics_baseline.json:6-10`. In that run `test_physics_engine_is_jolt` FAILED as it should.
  So the GodotPhysics column comes from a real GodotPhysics3D run of this test. Largest difference: jump apex
  0.003%. No metric is over 5%, so no root cause or fix was required, and none of `floor_snap_length`, `safe_margin`,
  the collision shape or step logic was changed. No tolerance was loosened.
- **Before/after table** (metric, GodotPhysics, Jolt, % diff) for walk speed, jump apex, jump-to-land time, step-up
  and slope limit is in PHYSICS_JOLT.md:17-23 and in the G1 summary (`cc_gladius/out/G1.json`). The pawn is driven
  through `InputFrame` / `Pawn.set_frame` at the fixed physics tick (`test_physics_baseline.gd:102,124,189`
  `await physics_frame`).
- **Breaking changes (my own grep of `scenes/` and `scripts/`).** `WorldBoundaryShape3D` (:25), `SoftBody3D` (:26)
  and `HingeJoint3D` (:50): no matches. `Area3D` (:27): `scenes/player/pawn.tscn:33` (Head), `scripts/classes/pawn.gd:159`,
  `scripts/weapons/hitscan.gd:3,30`, `scripts/systems/hill_zone.gd:2`. Head is layer 4, mask 0 (`pawn.tscn:35-36`);
  hill is layer 0, mask 2 (`hill_zone.gd:9-10`). With no SoftBody3D in the project, :27 has no effect. Both are
  pinned by `tests/test_physics_collisions.gd:79-90`. Walls, pawn-pawn, hitscan body/head/world/miss/self-exclusion
  and hill occupancy are retested in `test_physics_collisions.gd` and pass on Jolt.
- **Carry-over (melee defaults).** No silent default is left: `grep` of `scripts/` finds only direct reads
  (`pawn.gd:108-109`, `damage_rules.gd:73`). `pawn.gd:18-19` `MELEE_REQUIRED_KEYS` is in the required order (back
  angle, fraction, classes); `receive_melee` stops at the first missing key and `_invalid_melee` returns
  `invalid_melee_cfg` with no damage, reporting through `melee_error_sink` else `push_error`. `damage_rules.gd:68-71`
  returns `invalid_melee_cfg` with `push_error` if apply_melee is reached without the fraction.
  `data_registry.gd:118-119` reports a missing `front_breaks_full_shield_classes`. New tests use in-memory dicts
  only (`test_melee_rule.gd:117-150`, `_check_missing_melee_key` for each key: invalid, 0 damage, shield/health
  100, exactly one error naming the key) and `:109-110` (validate_melee reports the missing classes key).
  `test_melee_rule.gd:91` is unchanged and passes (one error naming `melee_back_angle_deg`, thanks to the key
  order). `data/stats.json` was not edited. The unrelated `0.7` and `get(..., [])` hits outside `test_melee_rule.gd`
  are not in the diff.
- **OQ-56** (`OPEN_QUESTIONS.md:115`): (2) now says "for a non-Gladiator attacker ... the Gladiator case is (3).
  There is still no overflow multiplier and no headshot rule for the blade." Same meaning; both PLACEHOLDER markers
  for (2) and (3) are kept. The G1 summary says no test pins the old wording; the suite passes.
- **Assertions.** `git show 982448a -- tests` touches existing lines only in `test_validate_melee_reports_missing_keys`
  (old `test_melee_rule.gd:105,107,109`, now `:105,107,111-112`): `"front_breaks_full_shield_classes": []` was
  added to the input dicts. The expected values (exact `PackedStringArray` for :106/:108, `size() == 1` for
  :111-113) and the `0.7` literals are unchanged. Without the added key each case would now report two problems, so
  this keeps every case isolating one key; nothing is weakened. The G1 summary lists these lines old -> new plus the
  added tests, and flags the conflict (see minor 4 on its numbering). Everything else in the test diff is added.
- **.claude/settings.json** is not in `git show --stat 982448a`.
- **iOS/Android:** Jolt is core Godot (no plugin, GDExtension or Android-only API). The commit adds no platform
  code.
- **GODOT API RULE:** the commit relies on `ProjectSettings.get_setting`, `CharacterBody3D`/`move_and_slide`
  (`modules/physics.md:51-69`, "API unchanged across engines"), `StaticBody3D`, `BoxShape3D`, `SceneTree.physics_frame`,
  `Engine.physics_ticks_per_second`, `JSON.parse_string`/`stringify`, `FileAccess.get_file_as_string`, `Area3D`
  (`breaking-changes.md:27`). None is listed in `deprecated-apis.md`; `breaking-changes.md:25-27,50` are the only
  physics entries and are covered above.

### Minor findings (non-blocking)
1. `test_melee_rule.gd:105,109` were listed in G1.txt as "unrelated 0.7 hits stay unchanged", but G1.txt also asked
   validate_melee to report the classes key, which forces those inputs to change. The 0.7 stays and the expected
   values are unchanged, and the summary disclosed it, so this is accepted. The summary's "I did not touch any
   assertion" is slightly loose: `:109` is an `assert_true` line whose input dict changed.
2. PHYSICS_JOLT.md:27 says step heights are swept "at 0.005 m up to 0.20 m", but `STEP_HEIGHTS_M`
   (`test_physics_baseline.gd:23-26`) is 0.005 m only up to 0.15, then 0.01 to 0.20 and coarser to 0.50. The
   0.12 m result is in the 0.005 m band, so the figure stands.
3. The `push_error` fallback in `damage_rules.gd:68-71` is not reached by any test (pawn validation stops first).
   As in G0b minor 3 this keeps the gate free of "ERROR:" lines; the branch is trivial.
4. The G1 summary's touched-line list gives the out-of-range case as ":109-110"; that is the old line 109, which is
   now `:111-112` (new `:109-110` are the added `no_classes` check). The content of the list is correct.

VERDICT: APPROVE
- All inputs are FOUND and all gates pass in this review (import, Android export, 173/173 tests, exit 0, no error lines).
- Jolt is set and asserted. The baseline was re-measured here under both engines and matches the recorded numbers
  exactly (max difference 0.003%), the 5% cap is enforced in code, the breaking-change audit holds, the melee
  carry-over and OQ-56 rewording are done as specified, no assertion was weakened, and settings.json is untouched.
  Findings 1-4 are minor.

## G2b review

Reviewer: Opus (VG2b), 2026-10-22. Target: commit 4a63495 "fix: G2b virtual stick tests and fixes" against
`cc_gladius/fixG/G2b.txt`, using `fixG/VTEMPLATE.txt`.

INPUTS: G2b commit = FOUND (4a63495, 16 files, +768/-163) ; test run = FOUND (run here: import exit 0, Android export
exit 0, full suite 3 runs, each "TESTS: 194 passed, 0 failed", exit 0; orchestrator `fixG.log:21` "GATE G2b apk=True
tests=0 shots=74") ; apk = FOUND (build/gladius-debug.apk, re-exported in this review) ; shots = FOUND (build/shots/*.png
well over 4) ; vjoy_rest shots = FOUND (vjoy_rest_cover_landscape/portrait, vjoy_rest_inner_landscape/portrait).
Import, export and test output had no "SCRIPT ERROR", "Parse Error" or "ERROR:" lines.

### Checklist
- **Item 0 (root cause).** `tests/run_tests.gd:44` has `await process_frame` right before `var inst = script.new()`
  (:47), and `:46` resets `move_stick_override` to the `--move-stick` value (`move_stick_arg`, :17/:24, "" when not
  given) before each test. `git diff f793f1a -- tests/test_tunables_and_bridge.gd` is empty. `test_bridge_snapshot_applies_replica`
  passed in all 3 full-suite runs here (3/3). The G2b summary (`cc_gladius/out/G2b.json`) gives the root cause: G2
  tests ended on physics_frame (`test_touch_controls.gd:54-56`), so the bridge test started inside the physics step, and
  gravity at `pawn.gd:202` moved the local pawn before the await at `test_tunables_and_bridge.gd:27`. No retries:
  `git diff f793f1a -G "[Rr]etr"` is empty. `--repeat` existed before G2b.
- **test_touch_controls.gd rule.** `git diff 8ffb2da -- tests/test_touch_controls.gd` is exactly 7 added lines, each
  `load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"` as the first body line of the tests at new
  t:66, :82, :358, :434, :475, :481, :487 (old t:65, 80, 355, 430, 470, 475, 480). No line is changed or removed, so
  :361/:364/:485 and `_check_hud_clear` t:439-471 (old 435-467) are intact. G2's tests now live in `tests/test_touch_virtual.gd`.
- **Default.** `data/input.json` has `"move_stick": "virtual"` and `"vjoy_layout": "floating"`. The custom code is kept
  (`touch_hud.gd:95`, `:405-411`), and `test_touch_controls_custom.gd` is unchanged and passes.
- **Virtual tests are real (mutation check).** `git clone` is not allowed in this session's shell, so I did not make a
  scratch clone. Instead, the probe `build/vg2b_mut.gd` (gitignored, outside res:// import) replaces `touch_hud.gd`'s
  `source_code` in memory and calls `reload()`, so the working tree is never edited. Control (no mutation): 11/11 pass.
  - M1, VirtualJoystick never created (`touch_hud.gd:95` -> always `_make_stick_visual`): 6 fail:
    test_gui_routed_move_and_release, test_virtual_stick_in_match_moves_pawn, test_fire_button_works_with_virtual_move_finger_held,
    test_virtual_stick_visible_with_no_touch_at_4_sizes, test_move_stick_touch_target_at_least_48dp_at_fold_sizes,
    test_multitouch_move_and_look_reach_one_input_frame.
  - M2, `_VJOY_ACTIONS` -> `provider.move_value` cut (`touch_hud.gd:178` -> `pass`): 6 fail:
    test_gui_routed_move_and_release, test_virtual_stick_in_match_moves_pawn, test_fire_button_works_with_virtual_move_finger_held,
    test_multitouch_move_and_look_reach_one_input_frame, test_floating_spawn_in_left_half_only,
    test_fixed_layout_stick_moves_pawn_base_stays_and_elsewhere_goes_to_look.
  Input goes through `Window.push_input` (`test_touch_virtual.gd:55-68`), never by setting `move_value` (`:137/:141/:210`
  only read it). Coverage is present: move/release :75, pawn in match :113, fire with move held :129, visible at rest
  at 4 sizes :146, multitouch in one InputFrame :176, look side never grabs :198, 48 dp at both Fold sizes with platform
  dpi :163, floating spawn at 0.02w / 0.25w / 0.5w-6 and never at 0.5w or 0.75w, back at rest :216, fixed mode
  :247, clearance :282-330. See minor 3 for the M1 tests that "pass" only because a script error aborts them.
- **Clearance.** `_check_hud_clear` (`test_touch_virtual.gd:282-318`) uses the same 4 sizes (:15) and the same
  size/encloses/intersects asserts as t:466-469, with no loosening. It adds move-vs-look `not intersects` (:307) and,
  for fixed, Control == drawn stick (:309). `get_move_visual_rect()` (`touch_hud.gd:276-281`) is built from the same
  `get_move_rest()` and `_vjoy_side()` that place the joystick (`:254-255`, base centre = `initial_offset_ratio`), so it
  matches the drawn base by construction. The landscape shots agree. See minor 4.
- **API.** Every VirtualJoystick name used is in `class_virtualjoystick.md`: class / `new()` touch_hud.gd:140 -> doc:2;
  `action_left/right/up/down` :143-146 -> doc:3; `joystick_mode` / `JOYSTICK_FIXED` / `JOYSTICK_DYNAMIC` :147 -> doc:3,6;
  `visibility_mode` / `VISIBILITY_*` :148 -> doc:3,7; `deadzone_ratio` :149 and `clampzone_ratio` :150 -> doc:3,8;
  theme `normal_joystick` / `pressed_joystick` / `normal_tip` / `pressed_tip` :153-156 -> doc:4; signal `released` :157
  -> doc:5; `initial_offset_ratio` :247/:254, `joystick_size` :255, `tip_size` :256 -> doc:3. Not in docs/engine-reference
  (flagged): `Viewport.push_input` (test_touch_virtual.gd:60,68), `InputMap.has_action` / `add_action` (touch_hud.gd:138-139).
  `Input.get_vector` (touch_hud.gd:178) is at `modules/input.md:33`, but not its 5th `deadzone` argument. None of
  these is in `breaking-changes.md` or `deprecated-apis.md`.
- **Tunables.** All are read from data with `[]` and no numeric `.get` fallback: vjoy deadzone/clamp touch_hud.gd:149-150;
  radial deadzone (length-based) touch_provider.gd:45-50; exponent touch_provider.gd:50 (before the InputFrame);
  accel/decel times pawn.gd:202; full analog pawn.gd:198; ratio pawn.gd:196-197. Each has an injecting test:
  test_move_feel.gd:30 (exp 2.0, 0.5 -> 0.25), :38 (radial), :56 (vjoy 0.3/0.7), :94 (accel 0.5 s = 30 ticks), :110
  (decel), :129 (half stick, ratio 0.5). Shipped data: neutral and `_placeholder: true` (input.json `move_feel`
  0.0 / 1.0 / 0.1 / 1.0; stats.json `ground_accel` / `ground_decel` 0.125). `strafe_back_ratio` 0.889 has no
  `_placeholder` and has the exact `_source` string; :148 asserts strafe and backpedal are 0.889 x forward within 1%,
  :185 checks the markers. `base_speed_mps` is unchanged at 5.0. See issue 1 and minors 2 and 5.
- **No labels.** `git grep -n -i halo` at 4a63495 gives the same 10 hits as at f793f1a (DESIGN.md, ARCHITECTURE.md,
  OPEN_QUESTIONS.md:29, plans/sprint1.md, damage_rules.gd). G2b adds none. In the G2b diff, PUBG appears only in
  `docs/CONTROLS.md:3-5`, as the layout reference, with an explicit "no value below is labelled as PUBG's".
- **Baseline untouched.** `git diff f793f1a -- tests/test_physics_baseline.gd data/physics_baseline.json` is empty.
  The baseline test passes (walk_speed_mps 5.000004, max_step_up_m 0.12, max_slope_deg 45.5).
- **Ramp.** For a speed_pct 100 class the forward ramp matches 8ffb2da: rate = 5.0/0.125 = 40 m/s^2, the same as old
  `accel 40` (test_move_feel.gd:164-182 passes). The value is shown as 5.0 / 40.0 = 0.125 s with `_placeholder: true`
  (stats.json movement). For other classes it does not match; see issue 1.
- **Mode switch.** `main_menu.gd:50-55` adds "Move stick: Virtual/Custom" and "Stick: Floating/Fixed" right after the
  gyro toggle. They are saved via `_save_profile` (:102-106) and `save_service.gd:49-50,62-63`, which accepts only valid
  values. `touch_hud.gd:76-81` resolves override > profile > input.json, which is the order the brief asks for (override
  wins for tests).
- **Docs.** `docs/CONTROLS.md` covers both modes, both layouts with the two quotes, how to switch, recentring (:26,
  DYNAMIC base inside a fixed Control) and every tunable with its unit and value, plus the 0.889 `_source`. OQ-VJOY is
  updated.
- **Shots.** All 4 were made with no override (`tools/touch_capture.gd:298`, which asserts virtual + floating). The
  stick is visible at rest in all 4. Landscape cover (2520x1080) and inner (2176x1812): the move base and look stick are
  clear of each other and of the buttons. Portrait: see issue 2. The shots are drawn over a flat backdrop without the
  game HUD (`touch_capture.gd:296`), so clearance from the HUD bars can't be seen in them. It is covered only by the
  clearance tests at the 4 landscape sizes.
- **settings.json / platform.** `git diff f793f1a -- .claude/settings.json` is empty. No Android-only API was added.
  `OS.get_name()` appears only in `scripts/platform/platform_services.gd`.

### Issues to fix
1. `scripts/classes/pawn.gd:206`: the ramp rate is `get_move_speed() / ramp_s`, and `get_move_speed()` is class-scaled
   (`pawn.gd:89-91`). At 8ffb2da the rate was a flat 40 m/s^2 for every class. Sagittarii is an enabled class with
   `speed_pct` 95 (`stats.json:8`). Its rate is now 4.75/0.125 = 38 m/s^2, 5% lower on every ramp tick (tick 1: 0.633
   vs 0.667 m/s). That fails "ramp and steady-state match 8ffb2da within 1%". Velites (115) and Triarii (85) would
   differ by 15%. The ramp test (`test_move_feel.gd:164-182`) only covers a speed_pct 100 pawn, so it does not catch
   this. Fix: derive the rate from the data base speed (`_movement["base_speed_mps"] / ramp_s`), which reproduces 40 for
   every class while keeping `time_s` as the tunable. Add a ramp test for a non-100 class (e.g. Sagittarii). If
   class-relative time is wanted instead, that is a design decision: record it in OPEN_QUESTIONS rather than choosing it.
2. Portrait shots: in `build/shots/vjoy_rest_cover_portrait.png` (1080x2124), the move base at `move_stick_rest`
   [0.15, 0.76] runs past the left screen edge, and its right side overlaps the look stick base. The look stick overlaps
   the Reload, Swap and Fire buttons. In `vjoy_rest_inner_portrait.png` (1812x2124), the look stick overlaps Reload and
   Swap. VG2b asks for the stick to be visible and clear at each size and orientation, so the shot check fails here.
   The clearance tests only cover the 4 landscape sizes (`test_touch_virtual.gd:15`). The project is
   `sensor_landscape` (test_decisions_batch1 `test_orientation_is_sensor_landscape`), so portrait may be unreachable
   on device. Whether portrait must be supported is not decided in the step brief. Either make the layout (move rest,
   radius and look rest relative to the short side) clear in portrait and add a portrait size to the clearance test,
   or have EL drop portrait from the shot requirement and record that in docs/OPEN_QUESTIONS.md. Don't decide it in
   code.

### Minor findings (non-blocking)
1. `touch_provider.gd:23`: `cfg["move_feel"] if cfg.has("move_feel") else {}` turns off shaping without any error when
   the block is missing, but G2b.txt item 5 asks to "fail loudly". This is not a numeric fallback. Prefer `push_error`
   when `shape_move` is on and `move_feel` is absent.
2. `clampzone_ratio` only acts in JOYSTICK_FOLLOWING (`class_virtualjoystick.md:8`), and the shipped layouts use FIXED
   or DYNAMIC (`touch_hud.gd:147`), so it does nothing today. `test_move_feel.gd:56-66` checks only that the property is
   assigned, not that it changes anything. Note this in CONTROLS.md:35.
3. `tests/run_tests.gd:48-49` (from before G2b): a test aborted by a SCRIPT ERROR returns with empty `failures` and is
   counted as PASS. Under M1, `test_floating_spawn_in_left_half_only` (null `joystick_size`, :220) and the fixed-layout
   test "passed" this way, and the run printed SCRIPT ERRORs. The gate's "SCRIPT ERROR" grep is the only safety net.
   Consider a completion flag per test in the runner.
4. `get_move_visual_rect()` is computed from layout data, not read back from the joystick. Because of that,
   `test_touch_virtual.gd:236` ("base back at rest") always holds, and the clearance tests pass under M1. The geometry
   matches the joystick by construction (`touch_hud.gd:254-255`), so this is acceptable.
5. pawn.gd:199-206 changed per-axis `move_toward` to a vector `move_toward`. Diagonal moves now ramp more slowly than at
   8ffb2da (before, each axis got 40 m/s^2). This is outside the forward-only ramp criterion. Disclosing it would help.
6. The strafe and ramp tests call `_apply_movement` directly (`test_move_feel.gd:88-91`) through an InputFrame, rather
   than stepping physics like test_physics_baseline.gd. This is acceptable because the tick count is exact.
7. The mutation probe is in `build/vg2b_mut.gd` (gitignored). This session's shell has no `rm`, so I could not delete
   it.

VERDICT: ITERATE
1. scripts/classes/pawn.gd:206: the accel/decel rate scales with class speed, so Sagittarii (speed_pct 95, enabled)
   ramps 5% slower than 8ffb2da's flat 40 m/s^2. This breaks the "ramp matches 8ffb2da within 1%" requirement, and the
   ramp test covers only a 100% class. Use base_speed_mps / time_s and add a non-100 class ramp test.
2. build/shots/vjoy_rest_cover_portrait.png and vjoy_rest_inner_portrait.png: in portrait the move base is clipped at
   the left edge and overlaps the look stick (cover), and the look stick overlaps Reload/Swap/Fire. That fails "clear at
   each size and orientation". Fix the portrait layout and add a portrait clearance size, or get an EL decision that
   portrait is out of scope (OPEN_QUESTIONS).

## G2b2 review

Reviewer: Opus (VG2b2), Oct 22 2026. Target: 2d309c2 "fix: G2b2 ramp rate, diagonal ramp, runner safety" (parent
f942a69). Checked against cc_gladius\fixG\G2b2.txt.

INPUTS: G2b2 commit = FOUND (2d309c2, parent f942a69, 15 files, +265/-25) ; tests = FOUND (I ran them myself:
`--import` exit 0, `--export-debug "Android" build/gladius-debug.apk` exit 0, "Signed", no SCRIPT ERROR/Parse Error/ERROR:
lines; full suite `TESTS: 200 passed, 0 failed`, exit 0) ; apk = FOUND (build/gladius-debug.apk, Glob after my export) ;
landscape shots = FOUND (build/shots/cover_landscape_*.png x5 and inner_landscape_*.png x5, plus folded*/unfolded*) ;
vjoy_rest_cover_landscape.png = FOUND ; vjoy_rest_inner_landscape.png = FOUND. Portrait shots are not required (OQ-PORTRAIT).

1. Ramp rate: OK. `scripts/classes/pawn.gd:216`:
   `return move_toward(cur, target, float(_movement["base_speed_mps"]) / ramp_s * delta)`. The rate does not call
   get_move_speed() and has no numeric fallback (`_movement[...]` indexes the key directly). get_move_speed() at
   pawn.gd:198 only scales the wish vector, as at 8ffb2da.
2. Per-axis: OK.
   - Before, at 8ffb2da pawn.gd:195-197: `var accel: float = float(_movement.get("accel", 40.0))`,
     `velocity.x = move_toward(velocity.x, wish.x, accel * delta)`, `velocity.z = move_toward(velocity.z, wish.z, accel * delta)`.
   - After, at pawn.gd:199-200: `velocity.x = _ramp_axis(velocity.x, wish.x, delta)` and the same for z.
   - `_ramp_axis` (pawn.gd:211-216) picks decel per axis when `absf(target) < absf(cur) or cur * target < 0.0`. It keeps
     "0 = instant" per axis at :214-215.
   - `--only=test_shipped_ramp_per_axis_for_every_enabled_class` gave
     `PASS test_move_feel.gd::test_shipped_ramp_per_axis_for_every_enabled_class_forward`,
     `PASS test_move_feel.gd::test_shipped_ramp_per_axis_for_every_enabled_class_diagonal` and `TESTS: 2 passed, 0 failed`.
   - `--only=0_889` gave `PASS test_move_feel.gd::test_shipped_strafe_and_backpedal_are_0_889_of_forward`. That test
     (test_move_feel.gd:176) is unchanged in the diff.

   My curves use the 8ffb2da formula v[n] = move_toward(v[n-1], wish, 40/60 = 0.6667) per axis:
   - Sagittarii (stats.json:8, 95%, 0.95 x 5.0 = 4.75 m/s). Up: 0.667, 1.333, 2.0, 2.667, 3.333, 4.0, 4.667, then 4.75
     at tick 8. Down: 4.083, 3.417, 2.75, 2.083, 1.417, 0.75, 0.083, then 0 at tick 8.
   - Hastati (stats.json:4, 100%, 5.0 m/s). Up: 0.667 ... 4.667, then 5.0 at tick 8. Down: 4.333, 3.667, 3.0, 2.333,
     1.667, 1.0, 0.333, then 0 at tick 8.
   - Diagonal (0.707, 0.707): both axes use the ratio (x strafe, +z back). The target is 0.707 x 0.889 x 5 = 3.1426,
     reached at tick 5 (Sagittarii: 2.9855, tick 5).
   - Diagonal (-0.707, -0.707): x uses the strafe ratio, -3.1426 at tick 5. z is forward with no ratio, -3.535 at tick 6
     (Sagittarii: -2.9855 at tick 5 and -3.3583 at tick 6), so the axes finish on different ticks.

   How the tests match:
   - The tests build the same per-tick expectation (test_move_feel.gd:225-252, `rate := 40.0 * DT`, 1% or 0.001 m/s
     tolerance). The forward test asserts `reached.y == ceil(speed / 0.6667)`, which is 8 for both classes.
   - The mutation runs below printed the tests' expected values: Sagittarii up -0.6667, -1.3333, -2.0 ... -4.6667 and
     down -3.4167, -2.75, -2.0833, -1.4167, -0.75, -0.0833; diagonal targets 3.1426, -3.535, 2.9855, -3.3583. They are
     identical to mine.
   - Both tests loop over `_enabled_class_ids()` (test_move_feel.gd:213-219, read from stats.json "enabled"), not a
     hard-coded list. :266 only asserts that hastati and sagittarii are in the set.
3. Test integrity: OK.
   - `git diff 8ffb2da -- tests/test_touch_controls.gd` is still exactly 7 added lines, each
     `load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"  # this test targets the custom stick`, at
     the starts of test_move_stick_forward_and_release, test_move_stick_in_match_moves_pawn,
     test_fire_button_works_with_move_finger_held, test_both_sticks_visible_at_rest_unfolded_2176x1812,
     test_hud_clear_of_sticks_and_buttons_folded, test_hud_clear_of_sticks_and_buttons_unfolded and
     test_move_stick_recentres_on_touch_and_returns_to_rest. There are no removed lines.
   - `git diff f942a69 -- tests/test_physics_baseline.gd data/physics_baseline.json` is empty, and both baseline tests
     PASS in the full run.
   - No assertion was changed or removed: the test_move_feel.gd diff has no `-` lines. The only edits to an existing
     test are 3 added setup lines, `p.velocity = Vector3.ZERO` at test_move_feel.gd:163, :166 and :169 in
     test_full_analog_speed_and_strafe_ratio_injected. They are justified: accel is forced to 0 there, but with per-axis
     choice an axis left over from the previous case (z -2.5 -> 0) now counts as a decel and would use the 0.125 s
     decel time. The asserted values are unchanged.
4. Portrait: OK.
   - docs/OPEN_QUESTIONS.md:118 has the OQ-PORTRAIT text verbatim.
   - tools/touch_capture.gd:91-94 skips any `--vjoy-shot` name containing "portrait" and logs the skip. Only
     `_vjoy_rest_shot` writes vjoy shots, so no portrait vjoy file is produced.
   - docs/CONTROLS.md "Rest-state screenshots (landscape only)" lists only the two landscape shots and cites OQ-PORTRAIT.
     The old portrait PNGs remain in build/ (allowed).
   - vjoy_rest_cover_landscape.png (2520x1080): both stick bases are fully on screen at rest, with nothing touching them.
     The move base is lower-left and the look base is near mid-bottom. Aim, Reload, Fire, Swap and Jump are stacked
     bottom-right, clear of the look stick. The banner reads "desktop render, not device - folded" and "touch
     auto-detected ... not forced".
   - vjoy_rest_inner_landscape.png (2176x1812): same layout scaled up. The look base sits about 40 px left of Reload
     with no overlap, and nothing is clipped at any edge.
5. Minors: OK.
   - touch_provider.gd:47-50 calls `_report_missing_feel()` when shape_move is on, the provider is configured and
     move_feel is missing. :61-70 push_errors once, or uses `error_sink` in tests.
   - The test is test_move_feel.gd:56-76: it checks that the shipped input.json has move_feel, that the error is
     reported exactly once with a message naming move_feel, and that there is no error with shaping off.
   - CONTROLS.md:35 cites `class_virtualjoystick.md:8` (confirmed: "clampzone_ratio in FOLLOWING sets how far the
     finger moves before the base follows").
   - Wording nit: move_feel is top-level in data/input.json:35, a sibling of touch_layout (:41). The runtime message
     says so correctly, but the doc comment at touch_provider.gd:60 says "touch_layout.move_feel".
6. Runner and mutations: PARTLY FAILS. I used the in-place fallback because `git clone` is not in this session's
   shell set and there is no `rm` to delete a clone.
   - Code: run_tests.gd:58 is
     `if inst.completed and inst.failures.is_empty() and err_logger.errors.is_empty():`. `completed` is set by
     test_case.gd:10-12 (`await call(method)`, `completed = true`). tests/script_error_logger.gd is an
     `OS.add_logger` Logger that records ERROR_TYPE_SCRIPT errors.
   - The subprocess test PASSes in the full suite.
   - The normal scan does not run the fixture: run_tests.gd:25-29 lists only the files directly in res://tests, the
     fixture is under tests/fixtures/runner_error/, and test_runner_safety.gd:22 checks this. The full-run output has
     no test_runtime_error line.
   - M1, the required mutation: removing `inst.completed and ` gave `PASS
     test_runner_safety.gd::test_runtime_script_error_is_reported_as_fail_with_nonzero_exit` and `TESTS: 2 passed, 0
     failed`. The required result ("fixture counts as PASS, so the safety test FAILs") did NOT occur.
   - M2, extra probe: keeping `inst.completed and inst.failures.is_empty()` but dropping the logger check gave, inside
     the subprocess, `SCRIPT ERROR: Cannot call method 'call' on a null value. ... [1] run_test
     (res://tests/test_case.gd:11)`, then `PASS test_runtime_error.gd::test_null_call_before_the_end`, `TESTS: 1
     passed, 0 failed` and exit 0. Outer: `FAIL test_runner_safety.gd::test_runtime_script_error_is_reported_as_fail_with_nonzero_exit:
     ... fixture test must not PASS; runner exit code is non-zero, got 0`.
   - So in Godot 4.7.2 a runtime script error aborts only the called test body; `run_test` resumes and sets
     `completed = true`. The completion flag can never catch this case. The real guard is the logger, and the safety
     test does protect it (M2 fails). The runner is therefore safe, but the flag and the "did not complete" reason text
     (run_tests.gd:65-66) are misleading, and the requested mutation check cannot pass as specified.
   - M3: reverting the rate to `get_move_speed() / ramp_s` gave `FAIL ...for_every_enabled_class_forward: sagittarii
     forward up tick 1 z: -0.6333 vs -0.6667; ... down tick 7 z: -0.3167 vs -0.0833`. Required result met.
   - M4: reverting to the G2b `Vector2.move_toward` block gave `FAIL ...for_every_enabled_class_diagonal: hastati
     (0.707, 0.707) up tick 1 x: 0.4714 vs 0.6667; ...` for every class and both diagonals. Required result met.
   - All mutations were reverted with Edit. `git status --porcelain` afterwards printed nothing (empty).
6b. Paths: OK. The Grep tool with the same pattern, case-insensitive (`C:\\|cc_gladius|/Users/|/home/`, over tests/),
   found no matches; `git grep` is not in this session's allowed shell set.
   - test_runner_safety.gd:11 passes `"--path", ProjectSettings.globalize_path("res://")`. :14 is
     `var code := OS.execute(OS.get_executable_path(), args, output, true)`. The script and fixture are res:// paths
     (:5, :12).
   - Both the binary and the project root are resolved at runtime from the running engine. On CI, or with a different
     Godot install or checkout path, the subprocess uses whichever Godot binary and checkout launched the suite, so no
     machine path is baked in.
   - CI green is checked by EL after the push; not pushed here.
7. docs/LESSONS.md: OK. It has the "G2b ITERATE, Oct 22 2026" entry with 5 Whys for both causes, and the prevention
   rule verbatim: "Ramp/feel equivalence tests must cover every enabled class and a diagonal input."
8. Hygiene: OK.
   - `git diff f942a69 -U0 -G "[Hh][Aa][Ll][Oo]"` finds nothing.
   - `git diff f942a69 -- .claude/settings.json` is empty.
   - `git diff f942a69 --diff-filter=D --name-only` is empty.
   - The only OS-name checks in *.gd are in scripts/platform/platform_services.gd:37/53/68 (`"Android", "iOS"`). No
     JNISingleton or Android permission calls.
   - API cites: docs/engine-reference/godot has no entry for move_toward, Logger/OS.add_logger, OS.execute,
     OS.get_executable_path or ProjectSettings.globalize_path. breaking-changes.md:92 covers only
     OS.execute_with_pipe, which is not used. VirtualJoystick clampzone: class_virtualjoystick.md:8.

VERDICT: ITERATE
1. tests/run_tests.gd:58 and :65-66, tests/test_case.gd:5-12: the per-test completion flag cannot detect a runtime
   script error in Godot 4.7.2, because the caller resumes after the aborted call (mutation M2 above). Removing the flag
   check therefore changes nothing (M1), and the required mutation result was not met. The script-error logger
   (tests/script_error_logger.gd) is the real guard. Fix:
   - Say this in the runner and test_case comments, and keep `completed` only as a secondary check, documented as such.
   - Change the FAIL reason to name the logged script error rather than claim the test "did not complete". Add the new
     wording alongside the existing text, without removing the asserted substring at test_runner_safety.gd:16.
   - EL should change the mutation check to "remove `err_logger.errors.is_empty()` from run_tests.gd:58, so
     test_runner_safety FAILs". That mutation already fails today (M2).
2. Minor: scripts/input/providers/touch_provider.gd:60: the doc comment says "touch_layout.move_feel", but move_feel is
   top-level in data/input.json:35. Correct the comment.
