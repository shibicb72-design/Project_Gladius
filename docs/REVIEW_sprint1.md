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

## G2b3 review

Opus check of 1abac99 "fix: G2b3 runner guard docs, FAIL reason" against cc_gladius/fixG/G2b3.txt, run on Oct 22 2026.

INPUTS: tests log/exit code = FOUND (VG2b3 says to run the tests myself: import exit 0, export exit 0, full suite exit 0,
"TESTS: 201 passed, 0 failed". cc_gladius/tests_G2b3.log exists. fix3c.log has no "GATE G2b3" line yet, which is the
orchestrator's own gate) ; apk = FOUND (build/gladius-debug.apk, exported in this review, "Signed", "[ DONE ] export") ;
shots = FOUND (n=75 in build/shots/*.png, at least 4 Fold-size landscape, e.g. folded*_hud_*, unfolded*_hud_*,
cover_landscape_*, inner_landscape_*) incl. vjoy_rest_cover_landscape.png and vjoy_rest_inner_landscape.png = FOUND
(portrait not required, OQ-PORTRAIT) ; step commit = FOUND (1abac99 on top of 07dc82d, 7 files, +51/-6)

Verification:
- `godot --headless --path . --import` exited 0, and `--export-debug "Android" build/gladius-debug.apk` exited 0. Neither
  printed a SCRIPT ERROR, Parse Error or ERROR: line. Glob finds build/gladius-debug.apk.
- The full suite exited 0 with no SCRIPT ERROR lines (the fixture's SCRIPT ERROR appears only inside the
  subprocess, which captures it).

1. Guard docs: OK.
   - tests/test_case.gd:5-8:
     "## SECONDARY guard only. Set true when run_test() resumes after the body. In Godot 4.7.2 a runtime script error
     ## aborts just the called test body and the awaiting caller resumes, so this is still set true after such an
     ## error and CANNOT detect it. The real guard is the script-error logger (tests/script_error_logger.gd, checked
     ## in run_tests.gd). This flag only catches a body that never returns control normally."
   - tests/test_case.gd:12: "## Runner entry point: runs the named test, then sets `completed` (see above; not proof the
     body ran to its end)." The :13-15 code is unchanged.
   - tests/run_tests.gd:31-32: "# The script-error logger is the real guard against runtime script errors (see the check
     below); # test_case.gd's `completed` flag is only a secondary check."
   - tests/run_tests.gd:59-60: "# A runtime script error aborts only the test body and the await above resumes, so
     `completed` is still # true; the script-error logger (err_logger) is the real guard. `completed` is a SECONDARY
     check."
   - tests/script_error_logger.gd:2-4 was updated to match ("this logger is the real guard").
   - The condition (now :61, was :58) still has all three checks:
     `if inst.completed and inst.failures.is_empty() and err_logger.errors.is_empty():`. The diff shows no other
     behaviour change.
2. FAIL reason: OK.
   - tests/run_tests.gd:69-74:
     `var reason := "did not complete (script error?)"` /
     `if not err_logger.errors.is_empty(): reason += "; script error logged: %s" % err_logger.errors[0]` /
     `if err_logger.errors.size() > 1: reason += " (+%d more)" % (err_logger.errors.size() - 1)` /
     `why.append(reason)`.
     When errors is empty and completed is false, the old text "did not complete (script error?)" stays.
   - `-- --only=test_runner_safety` exited 0:
     "PASS test_runner_safety.gd::test_runtime_script_error_is_reported_as_fail_with_nonzero_exit",
     "PASS test_runner_safety.gd::test_fixture_dir_is_not_in_the_default_scan", "TESTS: 2 passed, 0 failed".
   - The fixture subprocess (`-- --dir=res://tests/fixtures/runner_error`) exited 1, as intended:
     "FAIL test_runtime_error.gd::test_null_call_before_the_end: did not complete (script error?); script error logged:
     Cannot call method 'call' on a null value. (res://tests/fixtures/runner_error/test_runtime_error.gd:7 in
     test_null_call_before_the_end)"
   - That line contains both asserted substrings:
     - test_runner_safety.gd:16 `assert_true(text.contains("FAIL test_runtime_error.gd::test_null_call_before_the_end"), ...)`
     - test_runner_safety.gd:17 `assert_true(text.contains("did not complete"), ...)`
     It also contains the new "script error logged: <error>" text.
   - `git diff 07dc82d -- tests/test_runner_safety.gd` is empty.
   - Added test tests/test_runner_reason.gd:7-16 (test_fail_reason_names_the_logged_script_error, plus its .uid):
     - It runs `OS.execute(OS.get_executable_path(), args, output, true)` with args `--headless --path
       ProjectSettings.globalize_path("res://") --script res://tests/run_tests.gd -- --dir=res://tests/fixtures/runner_error`.
     - It asserts `text.contains("did not complete (script error?); script error logged:")` and
       `text.contains("script error logged: Cannot call method 'call' on a null value.")`.
     - It uses only OS.get_executable_path() and res:// paths.
3. Comment fix: OK. scripts/input/providers/touch_provider.gd:60: "## Fail loudly, once per provider: shaping is on but
   data/input.json has no top-level move_feel." data/input.json:35 `"move_feel": {` is a sibling of
   `"touch_layout"` at :41. The runtime message at :65 is unchanged and consistent.
4. docs/LESSONS.md: OK.
   - `git diff 07dc82d -- docs/LESSONS.md` only adds lines (hunk @@ -23,3 +23,19 @@, all "+").
   - The new "## G2b2 ITERATE, Oct 22 2026" entry has 5 numbered Whys. Why 5 says "BOTH the spec author (Android Lead)
     and the approver (Engineering Lead) assumed the semantics without a probe".
   - It ends with "### Prevention rule" and the verbatim rule "Verify an engine's error semantics with a probe before
     specifying a guard."
5. Stability: OK. Three full runs (one before and two after the mutations, all on the unmutated tree):
   "TESTS: 201 passed, 0 failed" / "TESTS: 201 passed, 0 failed" / "TESTS: 201 passed, 0 failed".
6. Mutations: OK.
   - `git clone` into build/ needed approval that a non-interactive session cannot give, so I applied the mutations
     in memory in the repo with Edit and reverted them.
   - `git status --porcelain` was EMPTY afterwards, before this review commit.
   - M2: removed `and err_logger.errors.is_empty()` from run_tests.gd:61, then ran `--only=test_runner_`:
     - "FAIL test_runner_safety.gd::test_runtime_script_error_is_reported_as_fail_with_nonzero_exit: fixture test
       reported as FAIL, ... PASS test_runtime_error.gd::test_null_call_before_the_end ... ; fixture test must not PASS;
       runner exit code is non-zero, got 0"
     - test_runner_reason.gd also FAILs ("reason names the logged error").
     - "TESTS: 1 passed, 2 failed". It FAILs as required.
   - M3: changed pawn.gd:216 rate to `get_move_speed() / ramp_s * delta`:
     - "FAIL test_move_feel.gd::test_shipped_ramp_per_axis_for_every_enabled_class_forward: sagittarii forward up tick 1
       z: -0.63333332538605 vs -0.66666668653488; ..."
     - The diagonal test also fails.
     - "TESTS: 1 passed, 2 failed". The Sagittarii forward ramp test fails as required.
   - M4: replaced pawn.gd:199-200 with the G2b `Vector2 cur.move_toward(target, get_move_speed() / ramp_s * delta)`
     block:
     - "FAIL test_move_feel.gd::test_shipped_ramp_per_axis_for_every_enabled_class_diagonal: hastati (0.707, 0.707) up
       tick 1 x: 0.47140455245972 vs 0.66666668653488; ..."
     - "TESTS: 1 passed, 2 failed". The diagonal ramp test fails as required.
   - I reverted every mutation, so no clone was left behind.
7. Integrity: OK.
   - `git diff 8ffb2da -- tests/test_touch_controls.gd` is exactly 7 added lines, each
     `load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"  # this test targets the custom stick`,
     with 0 removed.
   - `git diff 07dc82d -- tests/test_physics_baseline.gd data/physics_baseline.json` is empty, and both baseline tests
     PASS in all 3 runs (test_movement_within_tolerance_of_physics_baseline, test_physics_engine_is_jolt).
   - In the touched test files, no assertion was changed or removed: test_case.gd assert_* is untouched,
     run_tests.gd/script_error_logger.gd have no assertions, and test_runner_reason.gd is new.
8. Paths: OK. Grep with pattern `C:\\|cc_gladius|/Users/|/home/` (case-insensitive) over tests/ finds "No matches
   found".
9. Hygiene: OK.
   - `git diff 07dc82d -U0 -G "[Hh][Aa][Ll][Oo]"` is empty.
   - `git diff 07dc82d -- .claude/settings.json` is empty.
   - `git diff 07dc82d --diff-filter=D --name-only` is empty.
   - iOS: the only OS-name checks in *.gd are scripts/platform/platform_services.gd:37/53/68 (`"Android", "iOS"`). There
     are no JNISingleton, JavaClassWrapper or Android permission calls.
   - API cites: docs/engine-reference/godot has no entry for OS.execute, OS.get_executable_path,
     ProjectSettings.globalize_path or Logger/OS.add_logger. breaking-changes.md:92 covers only OS.execute_with_pipe,
     which is not used.

VERDICT: APPROVE
All 9 G2b3 items are met:
- the guard docs are correct and the condition is unchanged;
- the FAIL reason names the logged error and keeps the asserted substrings;
- the M2/M3/M4 mutations are each caught;
- 3/3 full runs are green;
- the locked files are untouched.

## GBTN review

Opus check of dd07615 "fix: GBTN aim, action feedback, button tests" against cc_gladius/fixG/GBTN.txt, run on Oct 22 2026.
Prev commit = 140ca8f (G2b3 review), the parent of dd07615.

INPUTS: tests log/exit code = FOUND (cc_gladius/tests_GBTN.log exists; the gate line is in cc_gladius/fixG.log:51, not
fix3c.log: "GATE GBTN apk=True tests=0 shots=78". I also ran the suite myself: exit 0, "TESTS: 209 passed, 0 failed") ;
apk = FOUND (build/gladius-debug.apk, re-exported in this review: exit 0, "Signed", "[ DONE ] export") ; shots = FOUND
(n=78 in build/shots/*.png, incl. buttons_fire_cover_landscape, buttons_reload_inner_landscape,
buttons_aim_cover_landscape, buttons_swap_inner_landscape) ; step commit = FOUND (dd07615, 20 files, +789/-17)

Verification (all run in this review from the repo root):
- `godot --headless --path . --import` exited 0. `--export-debug "Android" build/gladius-debug.apk` exited 0. Neither
  printed a SCRIPT ERROR, Parse Error or ERROR: line. Glob finds build/gladius-debug.apk.
- Full suite: exit 0, "TESTS: 209 passed, 0 failed". The output has no SCRIPT ERROR or ERROR: lines.
- `-- --only=action_buttons --move-stick=virtual`: "TESTS: 8 passed, 0 failed".
- `-- --only=action_buttons --move-stick=custom`: "TESTS: 8 passed, 0 failed".

1. Root causes: confirmed.
   - Aim is now consumed. scripts/classes/pawn.gd:234 `aiming = _frame.aim_pressed` (in `_apply_aim`, called from
     `_physics_process` at :218). The FOV goes through camera_rig.gd `set_aim_blend`, and the spread through
     pawn.gd `get_spread_mult` into hitscan.gd `cast(..., spread_mult)`.
   - Each button has a visible effect node or HUD element:
     - Fire: shot_fx.gd tracer and flash (:71-72) and hud.gd hit_marker. Empty mag shows hud.gd cue_label "Empty".
     - Reload: hud.gd reload_box/reload_bar, shown while `w.reloading` (`refresh_pawn`). A full mag shows cue_label "Full"
       via pawn.gd `reload_rejected`.
     - Swap: hud.gd toast_label via `weapon_switched`.
     - Aim: camera FOV.
   - Gameplay reads no HUD nodes. pawn.gd only emits signals; hud.gd connects to them in `bind`.
2. Tests: real, and delivered through the viewport.
   - tests/test_action_buttons.gd:27-28 `func _deliver(e: InputEvent) -> void: _root().push_input(e, true)`.
   - :31-36 builds the InputEventScreenTouch. :83-88 taps `get_button_rect(action).get_center()`.
   - Each button test loops 2 sizes x 2 modes x stick held/not held (:92-99). The two-finger case: move stick index 0
     is pressed and dragged (:66-70), then the button is pressed with index 1 (:11, :84).
   - Effects are asserted, not just input state:
     - ammo drop plus tracer/flash visible (:110-112);
     - reloading, reload_box visible, then refill and hidden (:128-134);
     - Full cue and ammo unchanged (:146-148);
     - Empty cue (:160);
     - slot change and toast text (:172-175);
     - `pawn.aiming`, FOV < base, spread < 1, then back to base (:187-193);
     - velocity.y > 0 (:202).
3. Mutations: each is caught. I could not make a scratch clone: the allowed shell commands are godot, mkdir, git
   add/commit/status/diff/log, so no clone or rm. Instead I applied each mutation in place with Edit, ran the test,
   reverted it, and confirmed `git status --porcelain` was empty afterwards.
   - (a) pawn.gd:234 changed to `aiming = false`: test_aim_button_zooms_and_releases FAILS in all 8 combos ("pawn
     aiming", "FOV zoomed (75.0 < 75.0)", "aim tightens spread").
   - (b) shot_fx.gd:71 changed to `tracer.visible = false`: test_fire_button_spends_ammo_and_shows_tracer FAILS in all 8
     combos ("tracer visible").
   - (c) touch_hud.gd:342 changed to return "" for fire: test_fire_button FAILS ("fire spent ammo (30 -> 30)", tracer,
     flash) and test_fire_on_empty_mag FAILS ("Empty cue shown, got ''").
   - Note on (c): test_reload_button still passed. The missed tap falls into the look zone, and the look-tap fire pulse
     (touch_hud.gd:429) spends ammo anyway, so its "mag not full after firing" precondition is not proof that the Fire
     button works. This is acceptable because the fire tests cover that.
4. Data: OK.
   - New values are in data/stats.json `aim` and data/ui.json `shot_fx`, `feedback` and `touch_debug_overlay`. Every
     block has `"_placeholder": true` and a `_todo` naming OQ-AIM, OQ-FEEDBACK or OQ-DEVICE-TOUCH, plus "Not design
     values" (stats.json also says "Not PUBG values").
   - No value is labelled as PUBG's. The new code reads them without numeric fallbacks (e.g. pawn.gd:235
     `_aim["aim_zoom_s"]`).
   - OPEN_QUESTIONS.md adds OQ-DEVICE-TOUCH and OQ-AIM / OQ-FEEDBACK.
5. Touch targets and HUD bars: OK.
   - `git diff 140ca8f dd07615 -- tests/test_touch_controls.gd` is empty, so :470-477 are unchanged.
   - test_hud_clear_of_sticks_and_buttons_folded and _unfolded PASS, and
     test_touch_virtual.gd::test_move_stick_touch_target_at_least_48dp_at_fold_sizes PASSES.
   - data/ui.json `min_touch_target_dp` is still 48.0.
6. Debug touch overlay: OK. data/ui.json `touch_debug_overlay.enabled: false`. touch_hud.gd creates `debug_label` only
   when it is true. `_debug_touch` returns early otherwise.
7. Hygiene: OK.
   - `git diff 140ca8f dd07615 -U0 -G "[Hh][Aa][Ll][Oo]" --stat` is empty.
   - `git diff 140ca8f dd07615 -- .claude/settings.json tests/test_physics_baseline.gd data/physics_baseline.json
     tests/run_tests.gd tests/test_case.gd` is empty.
   - No existing test file was touched; tests/test_action_buttons.gd is entirely new.
   - iOS: the only OS-name checks in scripts/ are scripts/platform/platform_services.gd:36/52/67. GBTN adds no
     platform code.
8. Shots (opened and viewed):
   - buttons_fire_cover_landscape (2520x1080): ammo reads 29 / 120. The Fire button is highlighted. A small dark
     weapon box and a small orange flash are left of the capsule's chest. **No tracer line is visible anywhere.**
   - buttons_reload_inner_landscape (2176x1812): ammo reads 27 / 120. The Reload button is highlighted. Yellow
     "Reloading" text and a thin progress bar (just started) sit at about 70% height, at the capsule's waist. The bar
     overlaps the top-left of the look-stick ring. It is display-only (mouse_filter ignore), but it is hard to read there.
   - buttons_aim_cover_landscape (2520x1080): the view is clearly zoomed compared with the fire shot (the capsule and
     the wall are larger). The Aim button is highlighted.
   - buttons_swap_inner_landscape (2176x1812): the weapon label reads "Gladius Lux" and the ammo reads "-". A white
     "Gladius Lux" toast is at about 55% height, on the capsule. The Swap button is highlighted.
9. Other (minor, not blocking on their own):
   - Bots' shots on the host are not announced to clients. match_root.gd wires only `local_player.shot_resolved` to
     `announce_pawn_shot`, so clients do not see bot tracers.
   - net_match_bridge.gd `request_fire(..., aimed)` trusts a client-sent flag for tighter spread. The host already gets
     `aim_pressed` in the replicated InputFrame (input_frame.gd:5, :10) and could use that instead.
   - test_hit_marker_shows_on_a_hit_only (:206-214) emits `shot_resolved` by hand rather than hitting a target.

VERDICT: ITERATE
1. build/shots/buttons_fire_cover_landscape.png, scripts/weapons/shot_fx.gd:55-74: no tracer is visible in the
   fire shot. GBTN item 5 requires "(tracer visible)", and Shibi's bug is that Fire shows nothing. The GBTN summary
   admits this: the tracer is seen end-on from the third-person camera. The test passes only because it checks the
   node's `visible` flag, not whether the tracer can be seen on screen. Fix: make the tracer readable from the shipped
   camera, e.g. start it at the weapon box and end it at the hit point, offset from the view axis, or capture the shot
   against a near target. Then re-shoot.
2. GBTN summary, first-person weapon mesh: no first-person weapon mesh was added. ShotFx adds a third-person box
   beside the pawn (shot_fx.gd:27-29, data/ui.json shot_fx.weapon_mesh_offset_m). The summary describes "a box placed
   left of the pawn" but never says explicitly that no first-person weapon mesh was added, which this check requires.
3. GODOT API RULE not met: the GBTN summary says it "did not check breaking-changes.md or deprecated-apis.md" and
   gives no file:line. I grepped both for push_input, ProgressBar, top_level, Basis.looking_at, move_toward and
   SubViewport and found no matches. None of them is listed as changed or deprecated, but the summary must say that
   with the cites.
4. Minor: scripts/ui/hud.gd `_build_feedback` with data/ui.json `feedback.reload_anchor_y_frac` 0.7 puts the
   "Reloading" bar over the look-stick ring on the inner screen (buttons_reload_inner_landscape.png). Move the anchor
   or extend tests/test_touch_controls.gd-style clearance checks to the new feedback widgets.

## GBTN2 review

Opus check of 4e33a18 against C:\Users\shibi\cc_gladius\fixG\GBTN2.txt (template fixG\VTEMPLATE.txt).

INPUTS: GBTN2 commit = FOUND (4e33a18 "fix: GBTN2 visible tracer, feedback clearance, host aim, bot tracers", parent
e454c66, 18 files, +390/-21) ; test run = FOUND (I ran it: import exit 0, Android export exit 0, full suite exit 0,
"TESTS: 214 passed, 0 failed", no SCRIPT ERROR / Parse Error / ERROR: lines) ; apk = FOUND (build/gladius-debug.apk,
re-exported by me) ; shots = FOUND (Fold-size landscape set build/shots/cover_landscape_*, inner_landscape_*, plus
buttons_*_landscape: well over 4) ; named shots = FOUND (buttons_fire_cover_landscape.png, buttons_fire_inner_landscape.png,
buttons_reload_inner_landscape.png). Portrait not required (OQ-PORTRAIT).

1. Tracer. The new code is in scripts/weapons/shot_fx.gd:24-29:
   `tmat.no_depth_test = bool(_cfg["tracer_draw_on_top"])`, `tmat.render_priority = int(_cfg["tracer_render_priority"])`,
   `(flash.mesh as SphereMesh).material.set("no_depth_test", bool(_cfg["tracer_draw_on_top"]))`. It also records the
   endpoints (:78-82) and adds `get_tracer_endpoints()` (:91-92). The origin is still the weapon-box tip (:68-69), as in
   GBTN. Root cause given in the summary: the segment was 116 px long on screen but sat behind the depth-tested capsule.
   The fix draws it on top; it does not offset the segment from the view axis (GBTN2.txt item 1 allowed "offset ...
   enough to be readable"; the result is readable, see the shots below, so I accept it).
   Gameplay: `git diff e454c66 -- scripts/weapons/hitscan.gd` is empty, and no file under scripts/classes/ changed
   (pawn.gd:165-169 fire path unchanged). The diff under scripts/ touches only net_match_bridge.gd, match_root.gd,
   hud.gd and shot_fx.gd.
   Test (I ran it): `PASS test_tracer_visibility.gd::test_tracer_projects_to_a_readable_segment_and_draws_on_top`. It
   fires through the Fire button (tests/button_rig.gd:62-63, Viewport.push_input) at 2520x1080 and 2176x1812, both modes,
   and asserts the projected endpoints differ and `a.distance_to(b) > min_px` (test_tracer_visibility.gd:29-33).
   data/ui.json:21 `"tracer_min_screen_px": 60.0` in shot_fx, which has `"_placeholder": true` (:13); read without a
   fallback (test_tracer_visibility.gd:9, :13).
   Shots (opened): buttons_fire_cover_landscape.png: a yellow trail starts at the orange flash on the weapon box, left of
   the capsule at about (1165, 615) px in the 2520x1080 image, and runs up and right to about (1260, 545), at the
   capsule's neck. buttons_fire_inner_landscape.png: the same trail from the flash at about (955, 1015) px to about
   (1090, 915) in the 2176x1812 image. It is drawn over the capsule and is clearly visible in both. PASS.
2. Reload bar. data/ui.json:47-50: `"row_x_frac": [0.35, 0.65]`, `"cue_anchor_y_frac": 0.26`,
   `"reload_anchor_y_frac": 0.32`, `"toast_anchor_y_frac": 0.2` (was 0.62 / 0.7 / 0.55); scripts/ui/hud.gd:96-98
   `c.anchor_left = float(_fb["row_x_frac"][0])`, `c.anchor_right = float(_fb["row_x_frac"][1])` (was 0.0 / 1.0).
   Test: `PASS test_feedback_clearance.gd::test_feedback_widgets_clear_of_sticks_and_buttons`. It covers 4 widgets x 4
   sizes x 2 modes, and each widget is checked against 7 rects (move, look, 5 buttons) plus shown, has size and inside
   viewport (test_feedback_clearance.gd:45-53). Shot (opened): buttons_reload_inner_landscape.png shows "Reloading" and
   its bar at about 32% height in the centre, far above the look-stick ring top (about 64%) and left of the Aim button.
   It is clear of both sticks and all buttons. PASS.
3. Summary (cc_gladius\out\GBTN2.json "result"): it contains the sentence verbatim: "No first-person weapon mesh was
   added; the only weapon mesh is the third-person placeholder box beside the pawn (shot_fx.gd, data/ui.json
   shot_fx.weapon_mesh_*)." API list: push_input, ProgressBar, top_level, Basis.looking_at, move_toward, SubViewport,
   Camera3D.unproject_position, rpc, no_depth_test, render_priority, is_position_behind: all "not listed", plus related
   cites breaking-changes.md:24, deprecated-apis.md:53, breaking-changes.md:55. Spot-checks (opened): breaking-changes.md:24
   is "Input | Mouse and keyboard device IDs ... DEVICE_ID_MOUSE"; deprecated-apis.md:53 is "`event.device == 0` to
   detect mouse or keyboard"; breaking-changes.md:55 is "UI | Dual-focus system". All match. My Grep of docs/engine-reference/godot
   for all 11 names finds only modules/networking.md (rpc examples), nothing in breaking-changes.md or deprecated-apis.md,
   so "not listed" is correct. PASS.
4. Host aim. net_match_bridge.gd:159 `host_note_input(peer_id, frame_array)` in submit_input; :164-167
   `_last_aim[pid] = InputFrame.from_array(frame_array).aim_pressed`; :238-240 `spread_mult = ... if _last_aim.get(pid,
   false) else 1.0`. The client flag is now `_aimed` (:205, :215), not passed on by request_fire and not read anywhere.
   Tests: `PASS ...::test_host_ignores_client_claimed_aim_when_frame_says_not_aiming` and
   `PASS ...::test_host_uses_frame_aim_even_when_client_claims_not_aimed`. PASS.
5. Bot tracers. match_root.gd:116 `wire_bot_shots(host_bridge, bots)` in the host branch of begin(); :188-192
   `static func wire_bot_shots` connects each bot's `shot_resolved` to `host_bridge.announce_pawn_shot(b, o, e)`.
   announce_shot now emits `shot_announced` (net_match_bridge.gd:253). Test: `PASS
   test_host_aim_and_bot_tracers.gd::test_bot_shot_is_announced_with_the_bot_player_id_and_client_draws_it`. It calls
   `MatchRoot.wire_bot_shots(host, [bot])` directly (:75), not begin(). See mutation iv-a: the begin() wiring is not
   tested. ISSUE 1.
6. Hit marker. Before (e454c66 test_action_buttons.gd:206-214): `pawn.shot_resolved.emit(Vector3.ZERO, Vector3.FORWARD,
   {})` / `assert_true(not hud.hit_marker.visible, "miss shows no hit marker")` / `pawn.shot_resolved.emit(...,
   {"target": pawn})` / `assert_true(hud.hit_marker.visible, "hit shows the hit marker")`. After (:207-225): an enemy pawn
   is placed 4 m ahead (hit) or 4 m behind (miss) via button_rig.gd:67-79, Fire is pressed through push_input, and the
   test asserts both original assertions with the same messages, plus "no marker before firing" and
   `resolved[0].get("target") == target` / `== null`. Equal or stronger, through a real hitscan (mutation v confirms).
   PASS.
7. LESSONS.md: `git diff e454c66 -- docs/LESSONS.md` has only "+" lines (18 added at the end). "## GBTN ITERATE, Oct 22
   2026" has Whys 1-5 and ends with "Visual feedback tests assert on-screen projection/size, not just visible." verbatim.
   PASS.
8. Stability (run by me): full suite 3 times: "TESTS: 214 passed, 0 failed" / "TESTS: 214 passed, 0 failed" /
   "TESTS: 214 passed, 0 failed" (build/v_run1-3.log:218), each exit 0. `-- --only=action_buttons --move-stick=virtual`:
   "TESTS: 8 passed, 0 failed"; `--move-stick=custom`: "TESTS: 8 passed, 0 failed". PASS.
9. Mutations (in-memory in the repo, each reverted with Edit):
   (i) shot_fx.gd show_shot: origin = camera position + 2 m along the camera forward ray, end = + 30 m on the same ray ->
       `FAIL test_tracer_visibility.gd::test_tracer_projects_to_a_readable_segment_and_draws_on_top: (2520, 1080)
       mode=virtual: projected endpoints differ ... tracer on-screen length 0.0 px > 60.0 px` (all 4 size/mode
       combinations), "TESTS: 0 passed, 1 failed". Caught.
   (ii) data/ui.json cue/reload/toast_anchor_y_frac back to 0.62 / 0.7 / 0.55 and hud.gd anchors back to 0.0 / 1.0 ->
       `FAIL test_feedback_clearance.gd::test_feedback_widgets_clear_of_sticks_and_buttons: reload_box (1512.0, 648.0)
       mode=virtual [P: (0.0, 430.1), S: (1512.0, 47.0)] overlaps move_stick [P: (149.04, 414.72), S: (155.52,
       155.52)]`, "TESTS: 0 passed, 1 failed". Caught.
   (iii) net_match_bridge.gd:239 `if _aimed else 1.0` -> `FAIL ...::test_host_ignores_client_claimed_aim_when_frame_says_not_aiming:
       ... (expected 1.0, got 0.5)` and `FAIL ...::test_host_uses_frame_aim_even_when_client_claims_not_aimed: ...
       (expected 0.5, got 1.0)`, "TESTS: 1 passed, 2 failed". Caught.
   (iv-a) match_root.gd:116 `wire_bot_shots(host_bridge, bots)` replaced by `pass` (bots in a real hosted match are no
       longer wired) -> full suite "TESTS: 214 passed, 0 failed" (build/v_mut4a.log:218). NOT CAUGHT.
   (iv-b) the `b.shot_resolved.connect(...)` inside wire_bot_shots (:191-192) replaced by `pass` -> `FAIL
       ...::test_bot_shot_is_announced_with_the_bot_player_id_and_client_draws_it: one bot shot -> one announce_shot
       (expected 1, got 0); announced with the bot's player id (expected 8, got -1)`, "TESTS: 2 passed, 1 failed". Caught.
   (v) scripts/classes/pawn.gd:169 `res = {}` before `shot_resolved.emit` (every shot misses) -> `FAIL
       test_action_buttons.gd::test_hit_marker_shows_on_a_hit_only: hit shows the hit marker; the real hitscan hit the
       target pawn`, "TESTS: 7 passed, 1 failed". Caught.
   After reverting all: `git status --porcelain` printed nothing (empty).
10. Integrity: `git diff 8ffb2da -- tests/test_touch_controls.gd` is exactly 7 added lines, each
    `load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"  # this test targets the custom stick` (in
    test_move_stick_forward_and_release, test_move_stick_in_match_moves_pawn, test_fire_button_works_with_move_finger_held,
    test_both_sticks_visible_at_rest_unfolded_2176x1812, test_hud_clear_of_sticks_and_buttons_folded / _unfolded,
    test_move_stick_recentres_on_touch_and_returns_to_rest), no removed lines. `git diff e454c66 -- tests/test_physics_baseline.gd
    data/physics_baseline.json tests/run_tests.gd tests/test_case.gd tests/test_runner_safety.gd .claude/settings.json`:
    empty. `PASS test_physics_baseline.gd::test_movement_within_tolerance_of_physics_baseline` and `PASS
    test_physics_baseline.gd::test_physics_engine_is_jolt` in all 3 runs. The only existing test changed is
    test_action_buttons.gd (item 6 replacement, judged equal or stronger). The rest are new files. PASS.
11. Data: new values tracer_draw_on_top, tracer_render_priority, tracer_min_screen_px (shot_fx, `_placeholder` :13) and
    row_x_frac plus the moved anchors (feedback, `_placeholder` :31) are all in placeholder blocks and listed in
    OPEN_QUESTIONS.md ("OQ-FEEDBACK (GBTN2)"). `git diff e454c66 -U0 -G "PUBG|Android|..."` is empty, so no new PUBG
    label. The new reads (shot_fx.gd:27-29, hud.gd:97-98, test_tracer_visibility.gd:13) have no numeric fallback
    (`_last_aim.get(pid, false)` is a bool state default, not a tunable). PASS.
12. Paths: Grep `C:\\|cc_gladius|/Users/|/home/` (case-insensitive) over tests/** and scripts/**: "No matches found".
    PASS.
13. Hygiene: `git diff e454c66 -U0 -G "[Hh][Aa][Ll][Oo]"`: empty. `git diff e454c66 --diff-filter=D --name-only`:
    empty. No Android-only API (JavaClass/JNI/get_singleton/OS.get_name/"Android") in the diff. touch_hud.gd,
    data/input.json and the button sizing were not touched, so the buttons are still >= 48 dp (data/ui.json:10
    min_touch_target_dp 48.0). PASS.

Minor (not blocking): docs/CONTROLS.md:17, Aim row, still says "clients send it with the shot so the host applies the
same spread". Since GBTN2 the host ignores that flag and uses the last InputFrame (net_match_bridge.gd:238-239).

VERDICT: ITERATE
1. scripts/systems/match_root.gd:116, tests/test_host_aim_and_bot_tracers.gd:64-96: the call that wires bots in a real
   hosted match is untested. Mutation iv-a (delete `wire_bot_shots(host_bridge, bots)` from begin()) leaves the full
   suite at 214 passed, 0 failed. The test calls `MatchRoot.wire_bot_shots(host, [bot])` itself (:75), so it proves the
   helper works but not that the match uses it. This is the exact bug of GBTN review item 9 (clients see no bot shots),
   and the same pattern as the GBTN lesson (the test checks a stand-in, not the outcome). Fix: add a test that
   starts a hosted match through begin() (session_override/lobby_override with a host session and at least one bot),
   fires one of `m.bots`, and asserts `roster.bridge.shot_announced` fires with that bot's player id. Mutation iv-a
   must then FAIL.
2. Minor: docs/CONTROLS.md:17: update the Aim row to say the host takes aim from the client's latest InputFrame and
   ignores the client-sent flag.

## GBTN3 review

Opus check of 73d196b ("fix: GBTN3 bot shot wiring test via begin, far tracer shots, aim doc") against
cc_gladius/fixG/GBTN3.txt, Oct 22 2026. Review only; no product code changed (mutations were in-repo and reverted).

INPUTS: step commit = FOUND (73d196b, parent db40f64; 7 files, +115/-2) ; test run = FOUND (run by this review:
`godot --headless --path . --import` exit 0, `--export-debug "Android" build/gladius-debug.apk` exit 0 ending
"[ DONE ] export", suite exit 0 "TESTS: 215 passed, 0 failed"; no SCRIPT ERROR / Parse Error / ERROR: lines from
project files; tests_GBTN3.log also says "TESTS: 215 passed, 0 failed") ; apk = FOUND (Glob build/gladius-debug.apk) ;
shots = FOUND (build/shots/*.png well over 4, incl. Fold landscape) ; named shots = FOUND
(buttons_fire_cover_landscape.png, buttons_fire_inner_landscape.png, buttons_fire_far_cover_landscape.png,
buttons_fire_far_inner_landscape.png). Note: fix3c.log has no "GATE GBTN3" line; the task said to run the gates
myself, which I did.

1. Wiring test, tests/test_bot_shot_wiring.gd (new file, all lines added). It builds a hosted session (:12-17
   `isolated = true`, :22 `host.host_game()`, :23 `host.lobby.host_open(2, 3, "Host")`), a SubViewport with its own
   world (:24-28), and the match with `fill_bots = true`, `session_override = host`, `lobby_override`, `seed_override`
   (:29-35). It starts the match through `m.begin()` (:40), asserts `m.bots.size() >= 1` (:42) and a valid
   `m.roster.bridge` (:43-44), looks the bot id up from `m.director.all_players()` (:48-51, not hardcoded), connects
   `shot_announced` (:54), calls `bot.fire_shot()` (:55), and asserts exactly one announce (:56) carrying that id (:57).
   It never calls `wire_bot_shots`. Cleanup (:58-65): queue_free on match, session and viewport, `host.leave()`,
   AppFlow reset, two frames. Run: "PASS test_bot_shot_wiring.gd::test_begin_wires_bot_shots_to_the_host_bridge".
   `git diff db40f64 -- tests/test_host_aim_and_bot_tracers.gd`: empty. PASS.
2. Docs: docs/CONTROLS.md:17 now ends "the host takes aim from the client's latest `InputFrame`
   (`net_match_bridge.gd` `host_note_input` stores it, the shot's spread reads it) and ignores the client-sent aim
   flag." This matches net_match_bridge.gd:167 (`_last_aim[pid] = ...aim_pressed`) and :238-239. The diff against
   db40f64 touches only line 17. PASS.
3. Tracer at distance. I opened all four PNGs from the GBTN3 run, then re-ran
   `godot --path . res://tools/button_capture.tscn -- --out=build/shots` (exit 0, all 7 shots "-> OK") and opened the
   fresh far cover shot too. The spawn spot changes per run, so world endpoints differ between runs.
   - buttons_fire_cover_landscape (2520x1080)
     MEASURED: GBTN3 summary: world_a=(-20.18,1.15,33.85) world_b=(10.41,1.57,-17.77) px_a=(1165.6,617.2)
     px_b=(1261.4,540.3) len_px=122.8. My run: world_a=(-19.22,1.15,-34.40) world_b=(-15.0,1.34,-25.97)
     px_a=(1165.6,617.2) px_b=(1260.1,553.5) len_px=114.0. Read off the image: the trail starts at the muzzle flash at
     about (1166,615) and ends at about (1260,542), on the shooter's neck/left shoulder.
     INFERRED: a short yellow stub that rises from the gun to the shooter's own neck. It does not read as a shot going
     out into the arena.
   - buttons_fire_inner_landscape (2176x1812)
     MEASURED: summary: world_b=(-10.58,1.32,-17.68) px_a=(955.4,1014.5) px_b=(1083.1,910.3) len_px=164.8. My run:
     px_b=(1092.7,926.1) len_px=163.3. Image: starts at about (956,1014), ends at about (1085,913), at the base of the
     shooter's head.
     INFERRED: same as cover. The trail stops at the shooter's own body.
   - buttons_fire_far_cover_landscape (2520x1080)
     MEASURED: summary: world_a=(19.40,1.15,-34.09) world_b=(-14.84,1.56,-34.68) (34.2 m, the target pawn)
     px_a=(1165.6,617.2) px_b=(1260.7,540.7) len_px=122.1. My run: world_b=(-31.08,1.02,-15.0), only ~22 m, so it hit
     level geometry, not the 35 m target; px_b=(1253.9,555.8) len_px=107.6. Image (both runs): starts at about
     (1166,617), ends at about (1256,546) / (1254,554), on the shooter's neck/shoulder. The 35 m target pawn is not
     visible (hidden behind the shooter's body).
     INFERRED: the far shot looks the same as the near one: a ~110-120 px stub ending at the shooter's own body. A
     player would not see a shot travelling into the distance. The extra world distance changes nothing on screen,
     because a far point on the aim ray projects to the screen centre, and the pawn body sits there.
   - buttons_fire_far_inner_landscape (2176x1812)
     MEASURED: summary: world_b=(-40.60,1.26,-34.51) (60 m, missed the target, max range) px_a=(955.4,1014.5)
     px_b=(1085.9,911.2) len_px=166.5. My run: world_b=(-14.83,1.87,-34.71) (34.2 m, target) px_b=(1089.7,898.9)
     len_px=177.2. Image: starts at about (956,1014), ends at about (1088,913), at the shooter's neck.
     INFERRED: same. The trail visibly stops at the shooter's own body; no distant target or impact is visible.
   The near buttons_fire_* shots are still produced (SHOTS :13-14 unchanged; both "-> OK"). The new value
   data/ui.json:30-34 `capture.far_target_distance_m` = 35.0 sits in a block with `"_placeholder": true`, is listed in
   OPEN_QUESTIONS.md, and is read without a fallback (tools/button_capture.gd:79). The aim chord uses a hard-coded
   `PI / 3.0` (button_capture.gd:87) that assumes the spawn layout. In my run it did not give a clear line (hit at
   ~22 m), so the far endpoint is not reliably far.
   Result: the far shots show the trail ending at the shooter's own body -> ITERATE (task rule).
4. LESSONS.md: `git diff db40f64 -- docs/LESSONS.md` is 18 added lines, 0 removed. The "## GBTN2 ITERATE, Oct 22 2026"
   entry has Whys 1-5 and ends with "Wiring tests go through the real entry point, not the helper." verbatim. PASS.
5. Stability: full suite 3 runs: "TESTS: 215 passed, 0 failed" / "TESTS: 215 passed, 0 failed" /
   "TESTS: 215 passed, 0 failed". `-- --only=action_buttons --move-stick=virtual`: "TESTS: 8 passed, 0 failed";
   `--move-stick=custom`: "TESTS: 8 passed, 0 failed". PASS.
6. Mutations (in repo, each reverted; `git status --porcelain` afterwards: empty):
   (iv-a) match_root.gd:116 `wire_bot_shots(host_bridge, bots)` -> `pass`: "FAIL test_bot_shot_wiring.gd::
   test_begin_wires_bot_shots_to_the_host_bridge: one bot shot -> exactly one announce through begin()'s wiring
   (expected 1, got 0); announced with the bot's player id (expected 1, got -1)". Caught.
   (i) shot_fx.gd:69 origin and end moved onto the camera forward ray: "FAIL test_tracer_visibility.gd::
   test_tracer_projects_to_a_readable_segment_and_draws_on_top: (2520, 1080) mode=virtual: projected endpoints differ;
   ... tracer on-screen length 0.0 px > 60.0 px".
   (ii) feedback anchors back to 0.62/0.7/0.55: "FAIL test_feedback_clearance.gd::
   test_feedback_widgets_clear_of_sticks_and_buttons: reload_box (1512.0, 648.0) mode=virtual ... overlaps look_stick".
   (iii) net_match_bridge.gd:239 uses `_aimed`: "FAIL ...test_host_ignores_client_claimed_aim_when_frame_says_not_aiming:
   ... (expected 1.0, got 0.5)" and "FAIL ...test_host_uses_frame_aim_even_when_client_claims_not_aimed: (expected
   0.5, got 1.0)".
   (iv-b) match_root.gd:191-192 connect -> `pass`: "FAIL test_host_aim_and_bot_tracers.gd::
   test_bot_shot_is_announced_with_the_bot_player_id_and_client_draws_it: one bot shot -> one announce_shot
   (expected 1, got 0)".
   (v) pawn.gd:166 `res = {}` (forced miss): "FAIL test_action_buttons.gd::test_hit_marker_shows_on_a_hit_only: hit
   shows the hit marker; the real hitscan hit the target pawn". All caught. PASS.
7. Integrity: `git diff 8ffb2da -- tests/test_touch_controls.gd` = exactly 7 added lines, each
   `load("res://scripts/ui/touch_hud.gd").move_stick_override = "custom"  # this test targets the custom stick`.
   `git diff db40f64 -- tests/test_physics_baseline.gd data/physics_baseline.json tests/run_tests.gd
   tests/test_case.gd tests/test_runner_safety.gd .claude/settings.json`: empty. Both baseline tests PASS.
   `git diff db40f64 --stat -- tests/`: only test_bot_shot_wiring.gd (+65) and its .uid (+1), new files; no changed
   or removed assertion. PASS.
8. Data: the only new data value is `capture.far_target_distance_m` (placeholder block). No new PUBG label
   (data/ grep "PUBG" hits only stats.json:46 "Not PUBG values", which is pre-existing). No numeric fallback in the new
   read. PASS.
9. Paths: Grep `C:\\|cc_gladius|/Users/|/home/` (-i) over tests/**, scripts/**, tools/**: "No matches found". PASS.
10. Hygiene: `git diff db40f64 -U0 -G "[Hh][Aa][Ll][Oo]"`: empty. `git diff db40f64 --diff-filter=D --name-only`:
    empty. OS.get_name only in scripts/platform/platform_services.gd. Button sizing untouched;
    test_move_stick_touch_target_at_least_48dp_at_fold_sizes and test_menu_buttons_meet_touch_target_height PASS.
    PASS.

VERDICT: ITERATE
1. tools/button_capture.gd:76-90, :115-125 (GBTN3 item 3): in all four fire shots, including both new far shots, the
   tracer ends on screen at the shooter's own neck/shoulder (px_b about (1254-1261, 540-556) at 2520x1080; about
   (1085-1093, 899-926) at 2176x1812). A player would not read it as a shot travelling into the distance, and the 35 m
   target is hidden behind the shooter's body. The root cause is the camera, not the distance: the crosshair (where any
   far point on the aim ray projects) sits on the pawn's own body in this third-person framing. More distance cannot
   fix that. Fix options (a camera-framing product call for Shibi; if undecided, add an OQ): offset the third-person camera so the crosshair clears
   the pawn (an over-the-shoulder offset in data/camera, `_placeholder`), or make the pawn body see-through/hidden
   along the aim line. Either way, add a capture/test check that the tracer's far pixel endpoint is not inside the
   local pawn's on-screen rect.
2. tools/button_capture.gd:87: the far-shot aim uses a hard-coded `PI / 3.0` spawn-layout assumption. With a
   different spawn (this review's run) the shot hit level geometry at ~22 m instead of the 35 m target. Derive the
   direction from the map data (e.g. aim at the actual target or a known open lane), so the far shot is reliably far.

## GBTN4 review

Opus check of 981928a ("fix: GBTN4 right-shoulder camera, host-validated aim", parent de7f74d) against
cc_gladius/fixG/GBTN4.txt and VGBTN4.txt, template fixG/VTEMPLATE.txt, Oct 22 2026. Review only; mutations were
in-repo and reverted (`git status --porcelain` afterwards: empty).

INPUTS: tests log/exit code = FOUND (cc_gladius/tests_GBTN4.log "TESTS: 219 passed, 0 failed"; gate line is in
cc_gladius/fixG.log:82 "GATE GBTN4 apk=True tests=0 shots=81", not fix3c.log) ; apk = FOUND (build/gladius-debug.apk,
re-exported in this review: "Signed", "[ DONE ] export") ; shots = FOUND (build/shots/*.png, 81 per gate, incl.
buttons_fire_{,far_}{cover,inner}_landscape.png) ; step commit = FOUND (981928a, 18 files, +329/-12).
Gates run here: `--import` exit 0; Android export "[ DONE ] export"; full suite exit 0 "TESTS: 219 passed, 0 failed",
no SCRIPT ERROR / Parse Error / ERROR: lines (the only warning is the expected "fire rejected for player 5:
aim_blocked" from the rejection test).

1. SpringArm3D question, measured. `godot --headless --path . --script res://tools/measure_shoulder.gd` at HEAD:
   "arm.position=(0.6, 0.0, 0.0) cam.position(local to arm)=(0.0, 0.0, 3.5) cam_in_rig=(0.6, 0.0, 3.5)". With the
   offset put back on the camera (camera_rig.gd:31 `_arm` -> `_camera`, reverted): "arm.position=(0.0, 0.0, 0.0)
   cam.position(local to arm)=(0.0, 0.0, 3.5) cam_in_rig=(0.0, 0.0, 3.5)". So SpringArm3D does reset the child camera's
   x; the offset on the arm (camera_rig.gd:31) is where it takes effect. PASS.
2. data/camera.json:5 `"shoulder_offset_m": {"_placeholder": true, "value": 0.6, "unit": "m", ...}`;
   camera_rig.gd:31 `_arm.position.x = float(_cfg["shoulder_offset_m"]["value"])`, no fallback. The two new keys
   (camera.json:6-7 aim_ray_length_m, aim_validate_epsilon_m) are placeholders too, read without fallback
   (camera_rig.gd:53, net_match_bridge.gd:242). PASS.
3. Aim path:
   - client: match_root.gd:166-169 `frame.aim_point = rig.get_aim_point(local_player.hitscan_exclude())`,
     `frame.has_aim_point = true` -> camera_rig.gd:52-53 -> aim_math.gd:8-17 (screen-centre ray, world/body/head,
     else far point at aim_ray_length_m).
   - local shot: pawn.gd:147-151 direction = muzzle -> frame.aim_point; pawn.gd:169-171 hitscan from
     get_muzzle_position().
   - input frame: input_frame.gd:48 `to_array` appends has_aim_point, aim.x/y/z; :59-61 `from_array` reads them;
     match_root.gd:175 `send_input(frame, ...)` -> net_match_bridge.gd:153-160 `submit_input` -> :165-173
     `host_note_input` stores `_last_aim_point[pid]` (erased when a frame has none).
   - host validation: net_match_bridge.gd:238-245 `AimMath.validate_aim(space, muzzle, _last_aim_point[pid], eps, exclude)`;
     aim_math.gd:22-31 casts muzzle -> point on MASK_WORLD and returns "aim_blocked" if the hit is nearer than the
     point minus epsilon; bridge returns before validate_fire, ammo and announce.
   - shot spawn: net_match_bridge.gd:249-251 `origin = muzzle`, `direction = (point - muzzle).normalized()`, then
     Hitscan.fire :261, show_shot_fx :266, announce_shot :267.
   Rejection verified by test_shoulder_aim.gd:74-90 (wall at z=-5, point at z=-12: not ok, reason aim_blocked, 0
   announces, ammo unchanged) and mutation (d) below. PASS.
4. `Grep PI tools/button_capture.gd`: no match. button_capture.gd:81 `SpawnLane.neighbour_lane(pawn, dist)`;
   spawn_lane.gd:10 reads `DataRegistry.MAP_PATH` (data_registry.gd:11 = res://data/maps/alesia_section.json, 6
   spot_ ids) "spawns", tries both ring neighbours, rejects too-close or world-blocked lanes; stop path
   button_capture.gd:82-84 `push_error("[button_capture] STOP, no usable lane: ...")`, `return false`, and :121-123
   frees the viewport and fails the shot. PASS (but see mutation (c)).
5. Tracer far end vs shooter rect (test_shoulder_aim.gd:125-145), values from a temporary print added to the
   passing test (removed afterwards):
   "VGBTN4PROBE (2520, 1080) vp=(1512.0, 648.0) ep=[(-39.22, 1.15, 0.24), (-9.74, 1.36, 52.50)] far_px=(752.38, 325.61)
   rect=[P: (619.79, 324.0), S: (114.55, 217.93)]" and
   "VGBTN4PROBE (2176, 1812) vp=(1152.0, 959.0) ep=[(-20.78, 1.15, 34.40), (-50.26, 1.36, -17.86)] far_px=(571.51, 481.50)
   rect=[P: (407.20, 479.5), S: (141.97, 270.08)]"; "PASS ...test_far_tracer_ends_outside_the_shooter_screen_rect_at_fold_sizes".
   The far end is right of the rect by 18.0 px (cover) and 22.3 px (inner) in viewport pixels (content scale; the
   window sizes are 2520x1080 / 2176x1812). With offset 0 the test fails: "far end (755.11, 325.61) outside shooter
   rect [P: (701.52, 324.0), S: (108.97, 217.93)]". PASS.
6. docs/CONTROLS.md:63 shoulder row (placeholder, camera.json, measured note, OQ-SHOULDER); CONTROLS.md:57
   "radial_deadzone 0.1 is new vs 8ffb2da, a placeholder, tunable in input.json move_feel." verbatim;
   OPEN_QUESTIONS.md:122 OQ-SHOULDER (offset value, left/right swap). PASS.
7. Mutations (each reverted):
   (a) camera.json shoulder_offset_m value 0.0: "FAIL ...test_shoulder_offset_is_on_the_arm_and_survives_physics_frames:
       right shoulder: positive x" and "FAIL ...test_far_tracer_ends_outside_the_shooter_screen_rect_at_fold_sizes:
       (2520, 1080): far end (755.1147, 325.6097) outside shooter rect ...". Also offset on the camera instead of the arm:
       "FAIL ...: camera x in the rig is the shoulder offset (0.0 vs 0.6)". Caught.
   (b) shot origin at the camera. Client pawn.gd:169 `origin := get_viewport().get_camera_3d().global_position`:
       "FAIL test_action_buttons.gd::test_hit_marker_shows_on_a_hit_only" and "FAIL test_weapons.gd::
       test_hitscan_damages_dummy" (217 passed, 2 failed; caught by older tests, not by test_shoulder_aim). Host
       net_match_bridge.gd:250 `origin = pawn.global_transform * Vector3(0.6, 1.6, 3.5)`: "FAIL ...
       test_host_accepts_clear_aim_point_and_fires_from_the_muzzle_toward_it: shot starts at the muzzle". Caught.
   (c) PI/3 chord restored in button_capture.gd `_place_far_target` (replacing `lane["dir"]`): full suite
       "TESTS: 219 passed, 0 failed". NOT caught: no test loads tools/button_capture.gd (`Grep button_capture tests/`:
       no matches); test_shoulder_aim.gd:130 calls SpawnLane directly.
   (d) aim_math.gd:30 returns ok for a blocked ray: "FAIL ...test_host_rejects_aim_point_behind_a_wall_and_spawns_no_shot:
       aim point behind the wall is rejected; reason names the blocked muzzle ray (expected aim_blocked, got );
       no shot spawned or announced (expected 0, got 1); no ammo spent (expected 30, got 29)". Caught.
8. Integrity: `git diff de7f74d --stat -- tests/` = test_net_match.gd +6, test_shoulder_aim.gd +145 (new), .uid;
   no assertion removed. test_net_match.gd:196-201 frees the client CameraRig so the e2e fire test keeps its staged
   claimed direction; documented in the test, but it means no e2e test sends an aim point over the real RPC.
9. Godot APIs: PhysicsRayQueryParameters3D.create / intersect_ray as in docs/engine-reference/godot/modules/physics.md:75-77;
   SpringArm3D, Camera3D.project_ray_origin/normal, unproject_position: no entry in breaking-changes.md or
   deprecated-apis.md (Grep: no matches).

Non-blocking notes:
- net_match_bridge.gd:239-251: the host fires at the last aim point from `submit_input`, which is unreliable and sent
  at input_interval_s (1/15 s, net_match_bridge.gd:22), while `request_fire` is reliable. A shot fired while turning
  can go to an aim point up to ~67 ms old (more on loss), so the host's shot can differ from the client's own tracer.
  Sending the aim point with `request_fire` would remove that. The task asked for it in the input frame, so this is a
  follow-up, not a defect.
- net_match_bridge.gd:239: a client that sends frames without an aim point skips validate_aim and uses its claimed
  direction (legacy path). Already listed in OQ-SHOULDER.
- The tracer clears the shooter rect by only 18-22 viewport px at offset 0.6; any smaller placeholder value would
  fail the test. Fine while 0.6 is the value; worth knowing when OQ-SHOULDER is decided.

VERDICT: ITERATE
1. tools/button_capture.gd:78-94 (VGBTN4 mutation (c)): restoring the `PI / 3.0` chord in `_place_far_target` leaves
   the suite green (219 passed, 0 failed), so the fixture's use of map-data spawns is untested. test_shoulder_aim.gd:130
   checks SpawnLane on its own, not the tool. Add a test that drives the far-target placement (e.g. move the
   placement into a function the test can call, or run `_place_far_target` on a button_rig match) and asserts the
   target lies on the line to the SpawnLane spot from data/maps/alesia_section.json, plus the STOP path returning
   false when no lane is usable.

---

## GBTN5 review

cc_gladius/fixG/GBTN5.txt and VGBTN5.txt, template fixG/VTEMPLATE.txt, Oct 22 2026. Review only. The mutations were
made in the repo and reverted (`git status --porcelain` afterwards: empty).

INPUTS: tests log/exit code = FOUND (cc_gladius/tests_GBTN5.log:249 "TESTS: 221 passed, 0 failed"; gate line
cc_gladius/fixG.log:92 "GATE GBTN5 apk=True tests=0 shots=81") ; apk = FOUND (build/gladius-debug.apk, re-exported in
this review: "Signed", "[ DONE ] export") ; shots = FOUND (81 per gate, incl. build/shots/buttons_fire_far_{cover,inner}_landscape.png)
; step commit = FOUND (dcc3a26, 2 files, +157/-0).
Gates run here, each as its own command: `mkdir -p build`; `--import` exit 0; `--export-debug "Android"` "[ DONE ] export";
full suite exit 0, "TESTS: 221 passed, 0 failed" (219 + the 2 new tests). The only ERROR: line is the expected
"[button_capture] STOP, no usable lane: lane to spot_1 blocked at (37.83487, 1.4, 3.75); lane to spot_5 blocked at ..."
from the new STOP test, which GBTN5.txt:9 allows. The only WARNING is the known "fire rejected for player 5:
aim_blocked". There are no SCRIPT ERROR or Parse Error lines.

1. Loads the real tool. test_button_capture_far_target.gd:6 `const _Capture := preload("res://tools/button_capture.gd")`.
   The tests instance it with `_Capture.new()` at :97 and :147 and call `cap._place_far_target(m, pawn)` at :98 and :148.
   The rig (:36-50) starts a real match.tscn MatchRoot and moves the local player onto a spawn spot from the map JSON. PASS.
2. Data-driven expectations. Spawns come from `DataRegistry.MAP_PATH` (:28; data_registry.gd:11 =
   "res://data/maps/alesia_section.json"). The distance comes from data/ui.json capture.far_target_distance_m (:62).
   :66-76 compute their own expected direction from the JSON spot positions (next ring neighbour, then the previous
   one, with a clear muzzle ray and length >= dist), the same rule as spawn_lane.gd:26-40.
   :110 asserts target - pawn == dir*dist, :112 asserts forward·dir > 0.9999 (rotation.y faces it), :113 asserts pitch 0.
   :116 asserts that at least one spot uses the *next* lane, so the old PI/3 chord, which always pointed at the
   previous spot, cannot pass. The only literals are the fence geometry in the STOP fixture (:132-137) and the facing
   tolerance; none is an expected target value. PASS.
3. STOP path. A ring of four world-layer StaticBody3D walls around the pawn (:129-143) blocks both lanes. :150 asserts
   a false return, :151 asserts the pawn count is unchanged, and :152 asserts `catcher.hits == 1`, so the error fires
   exactly once. :153 asserts that no other error of any type was logged while the call ran.
   The allowance is test-local (`_StopCatcher`, :11-20) and is added and removed around the single call (:146/:149).
   It matches only text that begins with the exact constant STOP_MSG = "[button_capture] STOP, no usable lane" (:7, :17).
   A prefix match is the narrowest form that works, because button_capture.gd:83 appends ": <reason>" with float hit
   positions. Everything else goes into `others` and fails :153.
   The logger is not weakened: run_tests.gd and script_error_logger.gd are unchanged (`git diff 8175210 --name-only`
   lists only the test and its .uid). push_error is ERROR_TYPE_ERROR, which script_error_logger.gd:10 never counted,
   so no global allowance was needed or added. PASS.
4. Scope. `git diff 8175210 HEAD --name-only` = tests/test_button_capture_far_target.gd and its .uid only. No seam in
   button_capture.gd and no production code. The three VGBTN4 non-blocking items (net_match_bridge.gd stale aim point,
   missing-aim-point legacy path, 18-22 px tracer margin) are untouched. PASS.
5. Suite. My run says "TESTS: 221 passed, 0 failed" with exit 0; cc_gladius/tests_GBTN5.log:249 says the same. PASS.

Mutations (each run with `--only=test_button_capture_far_target`, then reverted):
 (c) Restored `(from.rotated(Vector3.UP, PI / 3.0) - from).normalized()` in place of `lane["dir"]` at
     button_capture.gd:85. Result: "FAIL ...test_place_far_target_sits_toward_the_neighbour_spawn_spot: ... spot_1: target
     at pawn + dir * far_target_distance_m ((17.49961, 0.0, -30.31111) vs (-35.0, 0.0, 0.0)); spot_1: pawn faces the
     neighbour spot ...", 1 passed, 1 failed. Caught.
 (e) Removed button_capture.gd:82-84 (`if not lane["ok"]` ... `return false`). Result: "FAIL ...test_place_far_target_stops_when_no_lane_is_usable:
     the exact STOP push_error fired exactly once (expected 1, got 0); no other error logged: [Invalid access ... 'dir'
     ...]", 1 passed, 1 failed. Caught.
     I also ran a softer variant that does not crash (`lane.get("dir", Vector3.ZERO)`). It is also caught, by the
     no-target assertion: "no target pawn added on STOP (expected 1, got 2)".
 After reverting: `git status --porcelain` is empty and `--only=test_button_capture_far_target` gives "2 passed, 0 failed".

Godot APIs: PhysicsRayQueryParameters3D.create and intersect_ray as in docs/engine-reference/godot/modules/physics.md:75-77.
Logger._log_error and OS.add_logger/remove_logger have no entry in breaking-changes.md or deprecated-apis.md (Grep: no
matches); the same signature is already used at tests/script_error_logger.gd:9.

Non-blocking notes:
- test_button_capture_far_target.gd:113 `pitch == 0.0` would also hold if the tool never set it (the rig's pitch is
  already 0), so this assertion is weak. It is harmless.
- :110 uses `is_equal_approx` on vectors about 35 m long. That is a tight tolerance, and it passes because the test and
  SpawnLane compute the same float path.

VERDICT: APPROVE

## G2c review

cc_gladius/fixG/G2c.txt and VG2c.txt, template fixG/VTEMPLATE.txt, Oct 23 2026. Review only, no fixes. Step commit
6d3d05c; prev = f520001. The mutations were made in the repo and reverted with Edit, because `git clone` and `rm` are not
in this session's shell, so a scratch clone could not be made or deleted. `git status --porcelain` afterwards: empty.

INPUTS: tests log/exit code = FOUND (cc_gladius/tests_G2c.log:264 "TESTS: 236 passed, 0 failed"; gate line
cc_gladius/fixG.log:102 "GATE G2c apk=True tests=0 shots=85") ; apk = FOUND (build/gladius-debug.apk, re-exported in this
review) ; shots = FOUND (n=85, including all four named shots) ; step commit = FOUND (6d3d05c, 22 files, +894/-28).
Gates run here, each as its own command: `mkdir -p build`; `--import` exit 0, with no ERROR, SCRIPT ERROR or Parse Error lines;
`--export-debug "Android" build/gladius-debug.apk` exit 0, with no ERROR lines, and Glob finds the APK; full suite exit 0,
"TESTS: 236 passed, 0 failed". The only ERROR: line is the expected GBTN5 STOP message from
test_button_capture_far_target.gd:148, which is not caused by G2c.

1. Baseline. PASS. `git diff f520001 -- data/physics_baseline.json` changes exactly one line:
   `-    "walk_speed_mps": 5.000004529953,` / `+    "walk_speed_mps": 5.37500381469727,`.
   `git diff f520001 -- tests/test_physics_baseline.gd` is empty.
   `-- --only=physics_baseline` printed PHYSICS_METRICS {"jump_air_time_s":0.716666666666667,"jump_apex_m":1.28420352935791,
   "max_slope_deg":45.5,"max_step_up_m":0.12,"walk_speed_mps":5.37500381469727}, then "2 passed, 0 failed". The baseline values
   are 0.716666666666667 / 1.28415989875793 / 45.5 / 0.12. That is 0% / +0.003% / 0% / 0%, all within the 5% tolerance.
2. Walk and accel. PASS. stats.json:20 has `base_speed_mps` 5.375 under movement `_placeholder: true` (:19).
   stats.json:21 has the note "Shibi Oct 22 asked for +5-10%; +7.5% chosen (5.0 x 1.075)...".
   stats.json:23-24 set `ground_accel`/`ground_decel` time_s to 0.134375, `_placeholder: true`. 5.375 / 40 = 0.134375 s, so
   the rate is 5.375 / 0.134375 = 40 m/s^2.
   test_sprint.gd:222-225 measures a per-tick gain of 40/60 within 1% over 5 ticks, and :214 checks walk 5.375 within 1%.
   The commit message and docs/PHYSICS_JOLT.md:25 cite Shibi's Oct 22 request.
3. DESIGN.md / OQ. PASS. `git diff -U0 -- docs/DESIGN.md` is one hunk at line 15. Only "No sprint." became
   "Sprint added by Shibi's decision, Oct 22 2026."; the rest of the line is byte-identical (both full lines compared).
   OPEN_QUESTIONS.md:66 OQ-SPRINT reads "DECIDED Oct 22 2026 (Shibi): sprint is added with a speed boost; trigger = move stick
   held at the forward extreme for 0.5 s; see docs/CONTROLS.md Sprint. CLOSED."
   "Halo": `git diff f520001 6d3d05c -U0 -i -G halo --name-only` lists only docs/DESIGN.md, which is the pre-existing line-15
   wording. No new Halo text appears in code, data, docs or the commit message.
4. Sprint data. PASS.
   - stats.json:25 `sprint_hold_s` {"_source": "Shibi Oct 22", "value": 0.5}, with no _placeholder.
   - stats.json:26 `sprint_speed_multiplier` 1.3 `_placeholder` with the exact note and no source.
   - stats.json:27 `sprint_ramp_s` 1.0 `_placeholder`.
   - input.json:38-40 hold the threshold at 0/100 (0.98/0.7) and the cone of 25 deg, all `_placeholder`.
   - input.json:41-43 hold lock_target and lock_button, both `_placeholder`.
   - There is no `sprint_speed_mult` key; test_sprint.gd:193 asserts that.
   - No value is labelled as PUBG's. CONTROLS.md says "PUBG publishes no numbers, so none are taken from it".
5. Sprint behaviour and smoothness in code. PASS.
   - Before G2c the pawn had no sprint term (wish = basis*local*get_move_speed()).
   - After: pawn.gd:262 `sprint_factor = ... move_toward(sprint_factor, target, (mult - 1.0) / ramp_s * delta)`. This is a
     linear ease in both directions at a fixed rate, so there is no snap. It is applied at pawn.gd:268 inside
     _apply_movement and multiplies the wish speed.
   - The hold timer is in scripts/input/sprint_detector.gd:46-53, with reset to 0 when the condition breaks and the cone
     check at :43. It is fed via InputProvider.tick and is_sprinting (input_router.gd) into InputFrame.sprint.
   - Gameplay never reads HUD nodes. The host validator uses pawn.get_max_move_speed() (pawn.gd:252,
     net_match_bridge.gd:186).
   - Tests:
     - no sprint at 0.45 s, sprint at tick 30-31 (:102-113);
     - entry non-decreasing, step <= bound, reaches 1.3x within 1% (:116-130);
     - exit by release, below threshold and out of cone non-increasing with the same bound (:134-156);
     - 45 deg and below threshold never sprint over 3 s (:159-167);
     - break at 0.4 s restarts the timer (:170-181).
6. Sensitivity. PASS. input.json:35 is exactly {"min": 0, "max": 100, "default": 50, "step": 5, "_source": "HT Tech
   report of BGMI 1.6 notes, single unofficial source; Shibi chose it as the starting point Oct 22 2026"}, with no _placeholder.
   sprint_detector.gd:35-36 maps the slider linearly between the two placeholder thresholds. at_forward_extreme
   (:40-43) is used by both the hold trigger (:49) and the lock target (touch_provider.gd lock_target_visible), and
   CONTROLS.md Sprint says so.
   Tests:
   - 0/50/100 push lengths shrink while sprint speed and hold stay equal (:244-257);
   - default 50, 52->50, 53->55, clamp 0/100 (:260-266);
   - profile round trip with snap and clamp (:269-284);
   - the slider saves to the profile (:287-298).
   The slider is 48 dp tall (main_menu.gd `_build_sprint_slider`).
7. Lock. PASS.
   - Release on target locks (touch_hud.gd:512, :516). Release elsewhere stops.
   - A new move touch cancels (:463). The button toggles (:457 -> touch_provider.gd toggle_sprint_lock).
   - Look works while locked.
   - Tested in custom/floating, virtual/floating and virtual/fixed (:346-393, :396-423). Locked speed and ease-down are
     tested at :427-447.
   - The lock button and target are >= 48 dp, using dp from PlatformServices.
   - The lock button position comes from input.json:42, with the profile key `sprint_lock_pos` overriding it
     (save_service.gd).
   - Clear of shield/health bars, all HUD labels, both sticks and all buttons at 1512x648, 2520x1080, 1152x959 and
     2176x1812 (:452-493). These are the same 4 sizes as test_touch_controls.gd:476-483.
   - CONTROLS.md Sprint contains the 4 research quotes plus the GuruGamer 18712, Reddit 1rbgu31 and PuK quotes verbatim.
8. Existing test file touched: tests/test_move_feel.gd only. The changed assertion lines:
   - :185 `5.0` -> `5.375` ("forward walk speed 5.375 m/s (5.0 + 7.5%%, Shibi Oct 22)").
   - :200 and :203 `move_toward(old, 5.0, ...)` -> `5.375`, and "steady state unchanged" -> "steady state at the new 5.375
     walk speed". Same tolerances.
   - :284-288 the "x and z reach their targets at different ticks" assertion moved from (-0.707, -0.707) to (-0.6, -0.8).
     _check_ramp on (-0.707, -0.707) is kept.
   - :299-301 the literal `5.0 / 0.5` became `base / 0.5`, with base read from data.
   - :312-313 `5.0 / 40.0` -> `5.375 / 40.0`.
   All of these are forced by the mandated 5.0 -> 5.375 change: the old expected values cannot hold. None widens a
   tolerance or drops a property. I checked the diagonal by arithmetic. Per-axis gain is 0.6667 per tick. x = 0.707 *
   0.889 * 5.375 = 3.378, which needs 5.07 ticks and lands on tick 6. z = 0.707 * 5.375 = 3.800, which needs 5.70 ticks
   and also lands on tick 6. At 5.0 they were 4.71 (tick 5) and 5.30 (tick 6). The "different ticks" property is kept on
   (-0.6, -0.8). I do not count this as weakening.
9. iOS / platform. PASS. The diff adds no OS.get_name, JNI, Engine.get_singleton or Android API. dp comes from the
   platform layer. `.claude/settings.json` is unchanged (`git diff f520001 -- .claude/settings.json` is empty).
10. Godot APIs I relied on: move_toward, lerpf, atan2, HSlider, StyleBoxFlat, add_theme_stylebox_override and
   Input.action_press have no entry in docs/engine-reference/godot/breaking-changes.md or deprecated-apis.md (Grep: no
   matches). VirtualJoystick is new in 4.7 per docs/engine-reference/godot/modules/input.md:11.

Mutations (each batch run with `-- --only=sprint`, then reverted):
 A. pawn.gd:262 snap (`sprint_factor = target`) -> FAIL entry ("entry step 0.6667 <= bound 0.0271"), exit (all 3 cases) and
    locked ease-down. touch_hud.gd:516 lock_sprint removed -> FAIL release_on_target in all 3 modes. get_threshold returns
    threshold_at_0 -> FAIL sensitivity ("0.98 0.98 0.98"). 11 passed, 5 failed.
 B. Timer reset removed (sprint_detector.gd:52) -> FAIL restart ("expected 0.0, got 0.4"). Cone check removed (:43) -> FAIL
    45-deg case and the exit out-of-cone case. cancel on new move touch removed (touch_hud.gd:463) -> FAIL "new move touch
    cancels the lock" in all 3 modes. 12 passed, 4 failed.
 C. No hold (`sprinting = held_s >= 0.0 and ...`) -> FAIL no-sprint-before-0.5 s, walk speed, hold per sensitivity, GUI
    0.45 s. Lock-button cancel removed (touch_provider.gd toggle_sprint_lock) -> FAIL "tap while locked cancels" in all 3
    modes. 10 passed, 6 failed.
 After reverting: `git status --porcelain` is empty, so the tree equals 6d3d05c, which passed 236/236 above.

Shots (opened):
- sprint_lock_cover_landscape (2520x1080, tag s1): move ring bottom left, a light "Lock" target circle above it and slightly
  right, the "Sprint lock" button at about 56% x / 42% y above the look stick, and Aim, Reload, Fire, Swap and Jump at
  bottom right.
- sprint_lock_inner_landscape (2176x1812, s3): the same layout scaled, with the "Lock" target visible.
- sprint_locked_cover_landscape (s2) and sprint_locked_inner_landscape (s4): the target is gone, the button reads "Locked"
  with a brighter fill, and the move knob is centred (no finger down).
- No element overlaps another.

Non-blocking notes:
- The *_lock_* shots show the target but not a deflected knob. touch_capture.gd `_sprint_shot` presses the vjoy action,
  which does not move the VirtualJoystick's drawn tip, so "mid-push" is only implied.
- touch_hud.gd:127-150 builds new StyleBoxFlat objects and theme overrides every _process frame (:266). This is per-frame
  allocation on mobile, and it should only restyle when the lock state changes.
- The lock target is checked clear of the HUD bars only at rest (`lock_target_at_rest`). While pushing, it follows the
  finger origin and is clamped on screen, but it can cover HUD labels.
- On release the pawn stops (move = 0, decel 40 m/s^2), per item 4. The "release" exit test checks the eased sprint factor,
  not ground speed. That matches the spec's two statements together.
- Keyboard and gamepad have no sprint binding yet. This is recorded as a TODO in OQ-SPRINT, not invented.

VERDICT: APPROVE

## G2M review

Reviewer: Opus (VG2M). Step commit 1b2e4b1 ("feat: G2M in-match menu (gear), shared settings panel"). Prev commit: fc51581.
Checked against fixG/G2M.txt.

INPUTS: tests log/exit code = FOUND (cc_gladius\tests_G2M.log; gate line "GATE G2M apk=True tests=0 shots=89" in
cc_gladius\fixG.log:112, which is where this run's orchestrator writes; fix3c.log has no G2M line) ; reviewer re-run =
FOUND (import exit 0; Android export exit 0, "Signed", no ERROR lines; full suite exit 0, "TESTS: 246 passed, 0 failed") ;
apk = FOUND (build/gladius-debug.apk, re-exported by this review) ; shots = FOUND (n=89, all 4 named menu_* shots present) ;
step commit = FOUND (1b2e4b1, 16 files, +837/-81)

Run notes: the only "ERROR:" line in the suite is the pre-existing intentional button_capture STOP push_error from
test_button_capture_far_target.gd:148 (GBTN5). A new WARNING ("SubViewport is not a child of a SubViewportContainer",
ui_scale.gd:43 via settings_panel.gd:35) appears when test_bot_shot_wiring.gd builds the match in a SubViewport. It is a
warning, not an error.

### Item by item
1. Gear. data/ui.json `pause_gear` has `"_placeholder": true` with anchor [1,0], margin_dp [8,56], icon_dp 28, touch_dp 48.
   The touch rect is pause_menu.gd:122-128 (dp from PlatformServices.get_dp_scale), and the icon is centred inside it
   (:132-135). The gear is handled in `_input` (:157-170). PauseMenu is the last child of Hud (match.tscn), so it gets
   input before TouchHud, and the tap is consumed with set_input_as_handled. Emulated mouse events are skipped (:164), so
   one touch can't open it twice. The HUD text was not shrunk. The gear sits 56 dp below the top edge.
2. Menu. Full-screen overlay with MOUSE_FILTER_STOP (:47) and Resume, Settings, Quit buttons sized from
   `pause_menu.button_dp` (`_placeholder`). Quit opens a confirm box (Confirm / Cancel, :64-70). Confirm emits
   quit_confirmed, which goes to match_root.gd:188 quit_to_menu (unpauses, then main menu).
3. Settings reuse. There is one implementation, scripts/ui/settings_panel.gd (scene scenes/ui/settings_panel.tscn).
   main_menu.gd:67-70 and pause_menu.gd:72 both instance `_SettingsScene`. main_menu keeps its old public names as
   getters that delegate to the panel (main_menu.gd:22-39). The toggle, slider and refresh code was removed from
   main_menu (-109 lines) and lives only in settings_panel.gd. No toggle code is duplicated (grep: toggle_move_stick /
   toggle_stick_layout exist only in settings_panel.gd). Main-menu tests pass unchanged (test_ui, test_decisions_batch1
   gyro toggle/persist, test_sprint slider).
4. Online / offline. Offline: match_root.gd:174-178 sets get_tree().paused = true only when not networked_match.
   pause_menu.tscn and pause_menu.gd:33 set PROCESS_MODE_ALWAYS, and so do settings_panel.tscn and the boxes
   (pause_menu.gd:82). Online: no pause. match_root.gd:203 sends `InputFrame.new()` (zero) whenever menu_open.
   touch_hud.gd set_suspended releases held buttons and vjoy actions, clears look, move and sprint lock, and ignores
   touches. docs/CONTROLS.md "In-match menu (gear)" documents this, including "You can be shot while in the menu".
5. Back. A grep of scripts/ for NOTIFICATION_WM_GO_BACK_REQUEST / ui_cancel finds only the comment at pause_menu.gd:4.
   No handler opens the menu, and no Back handling was added.
6. Tests (tests/test_pause_menu.gd, all new; 10 tests pass): gear centre (:128), icon edge + touch-rect corner + just
   outside (:139), Resume (:156), Quit -> Confirm/Cancel (:167), offline pause + pawn frozen 30 frames + clock stopped
   (:187), online not paused + zero frame + tick advances with a closed-menu control run first (:204), go-back via
   root propagate_notification + direct notification + ui_cancel action + Escape key (:239), same scene_file_path and
   in-match change persisted (:258), touch rect >= 48 dp and all menu buttons >= 48 dp at dpi 0 and 420 (:280), and the gear
   icon AND touch rects vs scores/timer/hill labels, shield/health bars, weapon/ammo labels, both sticks, lock button
   and every action button at 1512x648, 2520x1080, 1152x959, 2176x1812 under custom and virtual modes (:298-344, new helper;
   _check_hud_clear untouched). The long-text fill in :310-314 is the same text as test_touch_controls.gd:448-452.
7. Shots: see below.

### Rule checks
- No existing assertion was changed: `git diff fc51581 1b2e4b1 --stat -- tests/` lists only tests/test_pause_menu.gd and
  its .uid (both added). No existing test line changed.
- Placeholders: both new ui.json blocks carry `"_placeholder": true` plus an OQ-PAUSE-MENU `_todo`, and OQ-PAUSE-MENU was
  added to docs/OPEN_QUESTIONS.md. `git diff fc51581 1b2e4b1 -U0 -i -G "pubg|_source"` finds nothing, so no value is
  labelled as PUBG's.
- `git diff fc51581 1b2e4b1 -U0 -i -G halo` finds nothing, and the commit message doesn't contain it either.
- .claude/settings.json, tests/test_physics_baseline.gd, data/physics_baseline.json, project.godot and
  export_presets.cfg are unchanged.
- iOS: no OS.get_name / Engine.get_singleton / Android API was added outside scripts/platform/. dp comes from
  PlatformServices.
- move_stick_override is set at test_pause_menu.gd:342 and not reset, but run_tests.gd:55 resets it before every test,
  so it doesn't leak.

### Mutations
A scratch clone was not possible because `git clone` is outside this session's allowed shell. The mutations were
applied in the working tree, run, and reverted by Edit. `git status --short` was empty afterwards.
- Back wired to open the menu (`_notification` GO_BACK -> open() and `ui_cancel` -> open() in pause_menu.gd):
  test_go_back_does_not_open_menu FAILED ("Back / ui_cancel never open the menu; tree not paused by Back"). Each half
  alone (notification only, ui_cancel only) also FAILED.
- Input zeroing removed (match_root.gd `if not menu_open:` -> `if true:`): test_online_overlay_keeps_sim_running_with_zero_input
  FAILED ("open: no motion, drift 2.687; open: ammo unchanged (expected 27, got 24)").

### Shots (opened)
- menu_closed_cover_landscape.png (2520x1080): match HUD. "Squad 1: 0  Squad 2: 0" is top-left and "10:00 Hill: empty"
  top-right. Below them are the capture tool's yellow/green debug captions. A yellow 8-tooth gear on a dark disc sits at
  the right edge, about a quarter of the way down, clearly below the time/Hill text and above Aim. The sticks, Sprint lock and the
  five buttons are visible.
- menu_open_cover_landscape.png: the scene is dimmed and three large red buttons with gold borders are centred: Resume,
  Settings, Quit to main menu. The gear is hidden while the menu is open.
- menu_closed_inner_landscape.png (2176x1812): same layout scaled. The gear is top-right below the time/Hill row and the
  debug captions, and well clear of the Aim button.
- menu_open_inner_landscape.png: dimmed scene with the same three large buttons centred.

### Non-blocking notes
- The staged engine reference has no entries for SceneTree.paused, Node.process_mode or NOTIFICATION_WM_GO_BACK_REQUEST
  (grep of docs/engine-reference/godot/ finds nothing). The step should say "not staged". Nothing in the repo
  (e.g. CONTROLS.md) says so, so this review can't confirm the step said it.
- pause_menu.gd:75 UiScale.bind(_overlay) overwrites each button's custom_minimum_size.y with UiScale's own min height
  (ui_scale.gd:55). So `pause_menu.button_dp[1]` (64 dp) is not what is shown. The 48 dp floor still holds
  (ui_scale.gd:35), so the touch target rule is met. The data knob is just partly ineffective.
- The online test holds move/fire with Input.action_press, not a touch on the move stick. While suspended the touch HUD
  ignores touches, so the zero frame is the real guard, and the mutation proves the test catches its removal.
- A move-stick mode changed in-match is saved to the profile but not applied to the live touch HUD until the next match.
  The prompt only asks for persistence.

VERDICT: APPROVE

## G2L review

Task prompt: fixG/G2L.txt. Verifier template: fixG/VTEMPLATE.txt. Step commit 0e610c1, compared with prev = 3a6c6d4 (G2M head).

INPUTS: tests log/exit code = FOUND (ran here: `--import` exit 0; `--export-debug "Android" build/gladius-debug.apk`
exit 0, "Signed", "[ DONE ] export"; full suite exit 0, "TESTS: 251 passed, 0 failed"; the step's log tests_G2L.log
also exists, but fix3c.log has no "GATE G2L" line, so this run is the evidence) ; apk = FOUND (Glob finds
build/gladius-debug.apk after the export) ; shots = FOUND (n=95 in build/shots/*.png, including the 4 named
layout_* shots) ; step commit = FOUND (0e610c1 "feat: G2L new default touch layout", 7 files, +204/-37)

Run notes: no SCRIPT ERROR or Parse Error lines. The only "ERROR:" line is the deliberate STOP push_error from
tools/button_capture.gd:83, which tests/test_button_capture_far_target.gd:148 triggers on purpose. Earlier reviews
accepted it.

### Item by item
1. DATA. data/input.json:51-89 touch_layout is `"_placeholder": true` (:52). It holds look_stick_rest [0.88, 0.78] (:60,
   was [0.58, 0.76]), stick size stick_radius_frac_of_height (:54, unchanged), button_size_frac_of_height 0.12 (:78, was
   0.16), button_min_dp 48 (:79), per-button offsets in button sizes from the look rest (:82-86, `_placeholder_buttons`
   :77) and sprint_lock_pos [0.30, 0.45] (:89). move_stick_rest stays [0.15, 0.76] (:59). OQ-LAYOUT
   (docs/OPEN_QUESTIONS.md:99-104) says these are "not a design value and not PUBG's". No value is labelled as PUBG's.
   The only `_source` in the file is the pre-existing sprint_sensitivity one (:35). The look_zone (:73) is unchanged
   (right half), and buttons and the lock button still take priority in _on_down (touch_hud.gd:476 onward).
   - Layout literals in touch_hud.gd: the diff removes every layout fallback it touched (`_rest_center`:306-309,
     `_button_size`:380-381, `_cell_rect`:385-389). The only new numbers are the 0.0 anchors (:57-60, with a comment that
     offsets are absolute) and the 0.5 half-size in `_cell_rect`:389. Neither is a layout value. One fallback from before
     G2L remains: `_layout.get("button_font_frac_of_size", 0.24)` (:299, :134).
   - Sprint lock default: `sprint.lock_button.pos` is gone (input.json:42). `git grep -n -e lock_button -e sprint_lock_pos`
     lists these readers: touch_hud.gd:101/106-115/128-135/476 (the only default reader is `_lock_button_center` :106-110,
     now `_layout["sprint_lock_pos"]`), save_service.gd:21/69/84, settings_panel.gd:19/33/102, main_menu.gd:38-39 (these
     carry only the profile value; [] = default), tools/touch_capture.gd:427, and tests test_sprint.gd:201/274/278/396/404/475/491,
     test_pause_menu.gd:326, test_touch_layout_g2l.gd. Docs: **docs/CONTROLS.md:88 still says the default is `input.json`
     `sprint.lock_button.pos`** (issue 2). The test test_touch_layout_g2l.gd:115-135 proves the key is gone, that the
     default comes from touch_layout, and that the profile value overrides it.
2. GEAR. pause_menu is not in the diff. The gear stays top-right. test_pause_menu.gd::test_gear_clear_of_hud_both_stick_modes
   passes, and the new pairwise test includes `pm.get_gear_touch_rect()` (test_touch_layout_g2l.gd:93). In all 4 shots the gear
   sits below the hud.gd:48-51 row (scores, timer, Hill) and is clear of Jump.
3. CLEARANCE. `git diff 3a6c6d4 -- tests/test_touch_controls.gd` is **empty**: `_check_hud_clear` (:439-471) and its
   callers (:474-483) are byte-identical. test_hud_clear_of_sticks_and_buttons_folded/unfolded PASS (log lines 240-241).
   The new pairwise test (test_touch_layout_g2l.gd:74-112) covers both sticks, the 5 buttons, the lock button, the lock
   target and the gear, plus viewport containment, at all 4 sizes in both modes, and it PASSes.
4. DEFAULT. The new values are the data defaults. G2e is not built yet.
5. TESTS. The look stick is bottom-right and the 5 buttons are NW, at 4 sizes x 2 modes (:33-44). Size is checked
   against the literal 0.16 from f793f1a (:11, :47-53). 48 dp is checked at dpi 0 and 420 for both sticks, the buttons and
   the lock button (:56-70). The GBTN tests (test_action_buttons.gd, 8 tests, set mode per test at :50) and
   test_touch_controls.gd's button tests pass unchanged.
   - Existing test files: `git diff 3a6c6d4 -- tests/test_touch_controls.gd tests/test_action_buttons.gd
     tests/test_sprint.gd tests/test_pause_menu.gd` is empty. No assertion was changed or removed. The only test files
     touched are the new tests/test_touch_layout_g2l.gd and its .uid.
6. SHOTS. All 4 exist. Details are in the shot descriptions below.

Other checks: `git diff 3a6c6d4 -U0` has no "halo" (case-insensitive grep: no output). .claude/settings.json,
tests/test_physics_baseline.gd, data/physics_baseline.json and docs/DESIGN.md are unchanged (diff --stat empty). iOS:
the diff adds no OS/Android/JNI/singleton calls. dp comes from `_Platform.new().get_dp_scale()` (touch_hud.gd:381), from
the platform layer. GODOT API: the staged docs/engine-reference/godot/breaking-changes.md and deprecated-apis.md have no
entries for Control anchors/offsets, Rect2 or maxf (grep finds nothing). Those APIs are "not staged", and nothing in
the repo records that.

### Mutation check: NOT DONE (scratch copy denied)
The brief asks me to break the feature only in a scratch copy under cc_gladius\scratch. Both `git worktree add --detach
.../cc_gladius/scratch/vg2l 0e610c1` and `git clone --no-hardlinks ... .../cc_gladius/scratch/vg2l` were denied
("requires approval"). Per the brief I stopped there and did not mutate the live tree. **I have not shown that the new
tests fail when the feature breaks.** Reading the code, the asserts look sound: they read live rects from the HUD, and
`not has("pos")` would catch a re-added key. Reading is not proof, so this step cannot be approved yet.

### Shots (opened and viewed)
- layout_cover_landscape.png (2520x1080): the scores are top-left and "10:00 Hill: empty" is top-right. Shield and health bars,
  "Pilum BR" and "30 / 120" are under the scores. The move stick ring is bottom-left. The look stick ring with its knob is in the
  bottom-right corner. Left of and above it sits a 2x2 grid: Swap, Aim on the upper row and Reload, Fire on the lower
  row. Jump is higher, above Aim and to the right. The gear is at the right edge level with Jump, below the time/Hill text. "Sprint
  lock" is a round button left of centre at about 30% x, 45% y. Nothing overlaps.
- layout_cover_small_landscape.png (1512x648): the same layout, scaled. Buttons are clearly smaller than the sticks. The gear is
  below the time/Hill row, right of Jump. Nothing overlaps.
- layout_inner_landscape.png (2176x1812): the same arrangement. The look stick is large in the bottom-right corner, with the
  2x2 cluster NW of it and Jump above at about 45% height. The gear is top-right, well below the label row. Sprint lock is left
  of centre. A lot of empty space remains in the upper half.
- layout_inner_small_landscape.png (1152x959): the same layout. The cluster is NW of the look stick, Jump is above, and the gear
  is top-right under the labels.
- Note: the HUD labels are filled, but with live match values ("Pilum BR", "30 / 120", "Hill: empty"), not the strings
  `_layout_shot` sets (tools/touch_capture.gd:276-280). The match HUD overwrites them before the shot. The labels are still
  filled, which is what the prompt asks for.

### Issues
1. Blocking for approval: the mutation proof for tests/test_touch_layout_g2l.gd is missing (see above). The next verify
   must run it in a scratch copy. Suggested mutations: (a) look_stick_rest back to [0.58, 0.76] fails :39;
   (b) `_button_size` without the maxf floor fails :68 at 1512x648 dpi 420; (c) re-adding `sprint.lock_button.pos` fails
   :117; (d) one button offset of [0, 0] fails :42/:101; (e) `_lock_button_center` ignoring the profile fails :133.
2. docs/CONTROLS.md:88 (Important): it still names `sprint.lock_button.pos` as the default. That key no longer exists
   (data/input.json:42). The prompt wants "exactly one default, not two", and the doc points readers to the removed key.
   Fix: point it to `touch_layout.sprint_lock_pos`, and also mention the G2L layout (look stick bottom-right, cluster NW,
   offsets in button sizes) in CONTROLS.md.
3. data/input.json:89 (Minor): the lock default moved from [0.56, 0.42] to [0.30, 0.45]. The prompt says "move that one
   default", and neither the commit message nor OQ-LAYOUT says why. By my arithmetic the old point was still clear of the
   new cluster at all 4 sizes. Either restore [0.56, 0.42] or say in OQ-LAYOUT why it moved. It now also sits inside the
   floating move_zone (:72). Button priority makes that work, but it is a layout choice for Shibi.
4. tests/test_touch_layout_g2l.gd:74-112 (Minor): the pairwise no-overlap test runs only at the default dpi. At dpi 420 on
   1512x648 the 48 dp floor makes buttons 126 px instead of 78 px (OQ-LAYOUT says so). That case is never checked for overlap,
   nor through `_check_hud_clear`. Add the dpi 0 and 420 loop to `_check_pairwise`.
5. tools/touch_capture.gd:265-266 (Minor): the "## G2M: the match with the gear closed..." doc comment now sits above
   `_layout_shot`, not `_menu_shots`. Also, `_layout_shot`'s label strings (:276-280) are overwritten by the live HUD, so
   the shots show "Hill: empty" rather than "Hill: contested".

VERDICT: ITERATE
1. tests/test_touch_layout_g2l.gd: the new tests have not been shown to fail on a broken feature. The scratch copy (git
   worktree / git clone) was denied, so the mutation check must run in the next verify.
2. docs/CONTROLS.md:88: it still names the removed `sprint.lock_button.pos` as the lock default. Point it to
   `touch_layout.sprint_lock_pos`.
3. data/input.json:89: the lock default value changed ([0.56, 0.42] to [0.30, 0.45]) without a stated reason. Restore it or
   justify it in OQ-LAYOUT.
4. tests/test_touch_layout_g2l.gd:74-112: the pairwise overlap test only runs at the default dpi. Also run it at dpi 420,
   where the 48 dp floor enlarges the buttons.
5. tools/touch_capture.gd:265-280: the misplaced G2M doc comment, and layout-shot label strings that never show.

## G2L review (VG2L2: G2L2 fix round)

Task prompts: fixG/G2L2.txt (fix round), with fixG/G2L.txt for everything G2L2 leaves in place. Verifier template:
fixG/VTEMPLATE.txt. Step commit 326a548, compared with prev = 9f7056f (G2L review).

INPUTS: tests log/exit code = FOUND (ran here: `--import` exit 0; `--export-debug "Android" build/gladius-debug.apk`
exit 0, "Signed", "[ DONE ] export"; full suite exit 0, "TESTS: 252 passed, 0 failed". fix3c.log has no "GATE G2L2" line,
so this run is the evidence) ; apk = FOUND (Glob finds build/gladius-debug.apk after the export) ; shots = FOUND (n=95 in
build/shots/*.png, including the 4 named layout_* shots) ; step commit = FOUND (326a548 "fix: G2L2 lock default, dpi-420
overlap, doc and tool fixes", 4 files, +15/-3)

Run notes: no SCRIPT ERROR or Parse Error lines. The only "ERROR:" line is the deliberate STOP push_error from
tools/button_capture.gd:83, which tests/test_button_capture_far_target.gd:148 triggers on purpose (accepted before).

### G2L2 items
1. CONTROLS.md: OK. docs/CONTROLS.md:88 now reads "Its default position is `input.json` `touch_layout.sprint_lock_pos`
   (`"_placeholder": true`); the profile key `sprint_lock_pos` ([x, y] fractions) overrides it". `sprint.lock_button.pos` is
   no longer named.
2. Lock default: OK. data/input.json:89 `"sprint_lock_pos": [0.56, 0.42]`, inside touch_layout (`"_placeholder": true`
   :52). `sprint.lock_button` (:42-43) has no `pos`. test_lock_default_only_in_touch_layout_and_profile_overrides
   (tests/test_touch_layout_g2l.gd:126-146) passes. Its :129 check (no "0.56" in the sprint block) still holds, because the
   value now lives only in touch_layout.
3. dpi 420 pairwise: OK. The new test test_pairwise_no_overlap_four_sizes_both_modes_dpi_420 (tests/test_touch_layout_g2l.gd:115-123)
   sets `PlatformServices.dpi_override = 420.0` (the same platform-layer hook the 48 dp test uses at :58), then runs
   the unchanged `_check_pairwise` (:74-104: both sticks, 5 buttons, lock button, lock target, gear, plus viewport
   containment) for both modes at all 4 sizes. It resets the dpi to 0 at :123. It passes, so no pair overlaps at dpi
   420 and no layout data change was needed (the commit changes no layout value besides the lock revert).
   `git diff 9f7056f -- tests/test_touch_controls.gd` and `git diff 3a6c6d4 -- tests/test_touch_controls.gd` are both
   **empty**: `_check_hud_clear` and its callers are byte-identical, and test_hud_clear_of_sticks_and_buttons_folded/unfolded pass.
4. Doc comment: OK. tools/touch_capture.gd:288 "## G2M: the match with the gear closed..." now sits directly above
   `_menu_shots` (:289). `_layout_shot` (:265) has no stray comment. The diff only moves the line.
5. Label text: OK. tools/touch_capture.gd:275 `hud.set_process(false)` stops GameHud._process (scripts/ui/hud.gd:218, which
   rewrites scores/timer/weapon/ammo/Hill at :230-262), so the tool's strings stick. hud.gd is not in the diff. The shots
   show "Hill: contested", "Gladius Rifle" and "120 / 360", where before they showed "Hill: empty".

### Existing tests and other checks
- Touched test files: only tests/test_touch_layout_g2l.gd (G2L's own file), with +11 lines and no changed or removed line. The
  diff is the whole new function at :115-123, with no `-` lines. `git diff 9f7056f -- tests/test_touch_controls.gd
  tests/test_action_buttons.gd tests/test_sprint.gd tests/test_pause_menu.gd tests/test_physics_baseline.gd
  data/physics_baseline.json .claude/settings.json docs/DESIGN.md scripts/` is empty. The GBTN tests (test_action_buttons.gd, 8)
  pass unchanged.
- G2L items left in place: the look stick is bottom-right, the 5 buttons are NW of it, button size 0.12 < 0.16 (literal
  from f793f1a, :11), and 48 dp at dpi 0 and 420 (:56-70) all pass in both modes. The gear stays top-right and clear
  (test_pause_menu.gd::test_gear_clear_of_hud_both_stick_modes passes, and the gear is in both pairwise tests).
- Data: the only value G2L2 changes is input.json:89, under touch_layout `"_placeholder": true`. No value is labelled as
  PUBG's, and the diff adds no `_source`.
- "halo": `git diff 9f7056f -U0 -i -G halo` prints nothing.
- Layout literals: G2L2 does not touch scripts/. The numeric `_layout.get(..., N)` fallbacks still in
  scripts/ui/touch_hud.gd (:134, :139, :157-158, :238, :299, :425, :540, :542, :560) date from c7f94fc and earlier, not from
  G2L or G2L2. They are outside this fix round's scope (see note 2).
- iOS: no OS/JNI/Android call added. The only new engine call is `Node.set_process` in a desktop shot tool. dp comes from
  PlatformServices (platform layer).
- GODOT API: `Node.set_process` has no entry in docs/engine-reference/godot/breaking-changes.md or deprecated-apis.md (grep
  for set_process finds only an unrelated `_process` row at deprecated-apis.md:48), so it is "not staged". `PlatformServices.dpi_override` is
  project code.

### Mutations (scratch copy cc_gladius/scratch/vG2L2 at 326a548, imported first; each mutation made with Edit, run, then undone)
The 5 suggested in the G2L review (above, Issues 1): "(a) look_stick_rest back to [0.58, 0.76] fails :39; (b) `_button_size`
without the maxf floor fails :68 at 1512x648 dpi 420; (c) re-adding `sprint.lock_button.pos` fails :117; (d) one button
offset of [0, 0] fails :42/:101; (e) `_lock_button_center` ignoring the profile fails :133." (After G2L2, :117 is now
:128 and :133 is now :144.)
- (a) input.json look_stick_rest = [0.58, 0.76]: CAUGHT, but not by :39. Full suite "TESTS: 243 passed, 9 failed".
  test_look_stick_bottom_right_and_buttons_north_west PASSES, because [0.58, 0.76] still satisfies x > 0.5w, y > 0.5h. FAIL
  test_pairwise_no_overlap_four_sizes_both_modes: "lock_button [P: (807.84, 233.28), S: (77.76, 77.76)] overlaps button_jump
  ... at (1512.0, 648.0)" (all 4 sizes), and the dpi-420 variant fails too ("move_stick ... overlaps button_swap_weapon ...
  at (1152.0, 959.0)"). test_action_buttons.gd::test_jump_button_lifts_pawn also fails.
- (b) touch_hud.gd:381 `_button_size` without `maxf`: CAUGHT. FAIL test_targets_at_least_48dp_at_dpi_0_and_420: "button_jump 29.6
  dp >= 48 at (1512.0, 648.0) dpi 420.0; ... button_aim 43.8 dp >= 48 at (1152.0, 959.0) dpi 420.0".
- (c) re-add `"pos": [0.56, 0.42]` to sprint.lock_button: CAUGHT. FAIL test_lock_default_only_in_touch_layout_and_profile_overrides:
  "no lock default in sprint.lock_button; old lock default value gone from the sprint block" (:128, :129).
- (d) fire offset [0, 0]: CAUGHT. FAIL test_look_stick_bottom_right_and_buttons_north_west: "custom (1512.0, 648.0): fire centre
  (1330.56, 505.44) north-west of look centre (1330.56, 505.44)" (:42). FAIL test_pairwise_no_overlap_four_sizes_both_modes:
  "look_stick ... overlaps button_fire ..." (:101), and the dpi-420 variant fails the same way.
- (e) touch_hud.gd:108-109 `_lock_button_center` always uses the data default: CAUGHT. FAIL
  test_lock_default_only_in_touch_layout_and_profile_overrides: "profile value overrides the default" (:144).
- (f) new: a button over the look stick at dpi 420 at 1512x648 only. A data offset cannot do this, because offsets are in
  button sizes and grow with the 48 dp floor. So the edit was in `_cell_rect` (touch_hud.gd:388): Fire's centre goes to
  the look rest only when the HUD is 1512x648 and the dp floor is active. CAUGHT, only by the new test: FAIL
  test_pairwise_no_overlap_four_sizes_both_modes_dpi_420: "look_stick [P: (1252.8, 427.68), S: (155.52, 155.52)] overlaps
  button_fire [P: (1267.56, 442.44), S: (126.0, 126.0)] at (1512.0, 648.0)". The dpi-0 pairwise test PASSES, which shows
  the new test covers a case the old one missed.
- After undoing all six: the edited regions read the same as the live repo (touch_hud.gd:106-110, :380-389; input.json:43,
  :60, :84), and `--only=test_touch` in the copy gives "TESTS: 48 passed, 0 failed". One undo first joined two lines
  (Parse Error at touch_hud.gd:388); I fixed that before this check. `git -C <copy> status` needed approval, so it was not run.
  The copy is left in place. The live repo was never mutated.

### Shots (retaken, opened and viewed)
- layout_cover_landscape.png (2520x1080): "Squad VIII: XXXVIII   Squad II: XXIX" top-left, "10:00 Hill: contested" top-right,
  shield/health bars, "Gladius Rifle" and "120 / 360" under the scores. Move stick ring bottom-left. Look stick ring with its knob
  in the bottom-right corner. Swap, Aim (upper row) and Reload, Fire (lower row) form a 2x2 grid to its left, and Jump is above
  Aim, to the right. "Sprint lock" is back at about 56% x, 42% y (right of the pawn). The gear is at the right edge below the
  time/Hill row. Nothing overlaps.
- layout_cover_small_landscape.png (1512x648): the same layout, scaled down. The buttons are smaller than the sticks, Sprint lock
  is just right of centre and above the horizon, and the gear is below the time/Hill row. Nothing overlaps.
- layout_inner_landscape.png (2176x1812): the same arrangement, larger. Big look stick bottom-right, the 2x2 cluster NW of it,
  Jump above at about 45% height, and Sprint lock at about 56% x, 42% y. The gear is top-right, well below the labels. Nothing overlaps.
- layout_inner_small_landscape.png (1152x959): the same layout. The cluster is NW of the look stick, Jump is above it, Sprint lock is right of
  the pawn, and the gear is top-right under the labels. Nothing overlaps.
- In all 4, the capture tool's own yellow "desktop render, not device - layout" caption is drawn behind the gear icon. That
  caption belongs to the tool and is not game HUD (see note 3).

### Notes (not blocking)
1. tests/test_touch_layout_g2l.gd:39: the quadrant assert cannot tell the old mid-screen rest [0.58, 0.76] from the new corner.
   It is exactly what fixG/G2L.txt item 5 asks for (x > 0.5w, y > 0.5h), and the pairwise tests catch that mutation (a), so
   this is not a defect. A tighter bound (e.g. x > 0.75w) would need Shibi's decision.
2. scripts/ui/touch_hud.gd: numeric `_layout.get` fallbacks from before G2L (list above) go against "read without numeric
   fallbacks". They are out of scope for this fix round. Worth a later cleanup step.
3. tools/touch_capture.gd: the tool's caption sits under the gear in the layout shots. This is cosmetic and affects only
   the shots.

VERDICT: APPROVE
All 5 G2L2 findings are fixed with file:line evidence. The import, the Android export and the full suite (252/252) pass. The
4 layout shots were retaken and look right. No existing assertion was changed. All 5 G2L mutations and the new dpi-420
mutation are caught, the last one only by the new test.

## G2d review

Task prompt: fixG/G2d.txt (checks from fixG/VG2d.txt). Verifier template: fixG/VTEMPLATE.txt. Step commit 95dba05
"feat: G2d sensitivity tables and gyro modes" (20 files, +873/-15), prev = 02d2432 (G2L2 review head).

INPUTS: tests log/exit code = FOUND (I ran them here: `--import` exit 0; `--export-debug "Android" build/gladius-debug.apk`
exit 0, "Signed", "[ DONE ] export"; full suite exit 0, "TESTS: 266 passed, 0 failed". cc_gladius/tests_G2d.log exists;
fix3c.log has no "GATE G2d" line, so this run is the evidence) ; apk = FOUND (Glob finds build/gladius-debug.apk after the
export) ; shots = FOUND (n=99 in build/shots/*.png, including the 4 named sensitivity_* shots) ; step commit = FOUND (95dba05)

Run notes: no SCRIPT ERROR or Parse Error lines. The only "ERROR:" line is the deliberate STOP push_error from
tools/button_capture.gd:83, which tests/test_button_capture_far_target.gd:148 triggers on purpose (accepted before).

### fixG/G2d.txt items
1. Tables: OK. data/input.json:20-45 `sensitivity_tables`. Camera, ADS, Gyro and ADS Gyro share `scope_rows`
   tpp_fpp_no_scope, red_dot, 2x, 4x, 8x, 16x, which match DESIGN.md:24 "Scopes red dot, 2x, 4x, 8x, 16x". A separate Free Look
   table has rows tpp_character and fpp_character. Parachuting is skipped because there is no parachute. The 3x/6x reason is
   in docs/CONTROLS.md:52 and the `_free_look_note` in input.json. The look-state API is `InputRouter.set_aim_state`
   (scripts/input/input_router.gd:21-22). Unknown states fall back to no_scope, and `set_ads(false)` resets to no_scope (:26-29).
   The data `states` map is at input.json:24-27. OQ-ADS-ZOOM is at docs/OPEN_QUESTIONS.md:63, and OQ-SENS is at :62.
   No ADS mechanics were invented. The only "zoom" text in scripts/input and data/input.json is in comments and notes; no FOV,
   scope or zoom code was added. The ADS tables follow the existing aim_blend (match_root.gd:204).
2. Gyro modes: OK. off/scope_on/always_on are at input.json `gyro_modes` and GyroProvider.MODES (gyro_provider.gd). The
   `allows_gyro()` gate is `always_on or (scope_on and ads)`. Inversion X/Y is applied in InputRouter._scaled_look, for gyro
   providers only. The default is "off" (input.json `default_gyro_mode` with note OQ-34; SaveService defaults keep
   `gyro_enabled: false`). The old `gyro_enabled` is migrated in SensitivitySettings.from_profile/from_dict
   (sensitivity_settings.gd:111-136, trueΓåÆalways_on, falseΓåÆoff) and through SaveService._set_sensitivity (save_service.gd:51-56).
   **The single toggle is not gone.** settings_panel.gd:34 still builds "Gyro aim" (OffΓåöAlways), and main_menu.gd:22-25
   and :89-90 still delegate to it. This is the conflict fixG/G2d.txt item 7 anticipates. tests/test_decisions_batch1.gd:108-114
   and tests/test_pause_menu.gd:267-272 click it and read "Gyro aim: On", so the step kept it and did not edit those tests. It
   is reported in test_sensitivity.gd:3-4 and CONTROLS.md:54, but not in OPEN_QUESTIONS.md (see issue 4).
3. Ranges and sources: OK, with one gap. Only gyro and ads_gyro `max` 400 carry the 1.1 `_source` (input.json:34-35).
   Every other min/max/default/step has `"_placeholder": true`, and the `presets` block is `"_placeholder": true` with a
   `_todo`. G2d adds no other `_source`. The `sprint_sensitivity` `_source` at input.json:62 predates G2d. No other value is
   labelled as PUBG's. Gap: `"default_preset": "medium"` (input.json:21) is a default with no placeholder marker (issue 3).
   Custom: `set_value` sets preset = custom (sensitivity_settings.gd:75-77). The Custom button only shows state.
4. Persistence: OK. The profile key `sensitivity` is in `user://profile.json` via SaveService (DEFAULT_PATH user://).
   Loading is tolerant: bad or missing keys keep the data defaults, and hand-edited values are clamped.
5. Apply: OK in the router; not proven in a match (issues 1, 2). InputRouter.update_frame multiplies every provider's look
   by `look_percent` (look_math.gd `apply_percent`). Camera/ADS/Free Look tables apply to camera providers and Gyro/ADS Gyro
   tables to the gyro provider. GyroProvider has no assist code, and none was added (DESIGN.md:18 "none on gyro").
6. UI: OK. scenes/ui/sensitivity_screen.tscn + scripts/ui/sensitivity_screen.gd: presets, gyro mode, Invert X/Y, and 26
   sliders (4├ù6 + 2) in a ScrollContainer. Buttons get the 48 dp floor from UiScale.bind (ui_scale.gd:31-36, dp from
   PlatformServices). Sliders use `48.0 * PlatformServices.get_dp_scale()` (sensitivity_screen.gd:41,123). The screen is
   reached from the shared SettingsPanel "Sensitivity" button (settings_panel.gd:33), which is where the toggle was.
7. Tests: present and mostly real (mutations below). No existing test file is touched: `git diff 02d2432 95dba05
   --name-only -- tests/test_decisions_batch1.gd tests/test_pause_menu.gd tests/test_physics_baseline.gd
   data/physics_baseline.json .claude` prints nothing, and the only test file in the stat is the new tests/test_sensitivity.gd.
   No assertion was changed or removed.
8. Docs: CONTROLS.md:47-57 has a Sensitivity section. The shots are below.

### Shots (opened and checked)
- sensitivity_cover_landscape.png (2520x1080): Back + "Sensitivity" title; Low / Medium (selected, black) / High / Custom
  (greyed); "Gyro:" Off (selected), ADS, Always, Invert X, Invert Y; the Camera table with all 6 rows at 100% and the start of
  ADS (to 8x), with a scrollbar on the right. Text is readable, and nothing is clipped except the list, which scrolls.
- sensitivity_inner_landscape.png (2176x1812): the same layout with larger text. Camera and the full ADS table (6 rows) are
  visible, and the list scrolls.
- sensitivity_cover_small_landscape.png (1512x648): the same controls, smaller but readable. Camera plus ADS up to 4x.
- sensitivity_inner_small_landscape.png (1152x959): the same controls. Camera plus ADS up to 8x. The five gyro buttons fit
  without truncation.
  In all four shots the slider track sits slightly above its row label's baseline. This is cosmetic.

### Other checks
- Banned-word check (word list kept off-repo) prints nothing, and the commit message has none.
- iOS: G2d adds no OS/JNI/Engine.get_singleton/Android call (grep over scripts/input, the new UI, save_service, the tool and
  the test). Gyro reads stay behind PlatformServices.has_gyro/get_gyro_rate, and dp comes from PlatformServices.
- .claude/settings.json, tests/test_physics_baseline.gd and data/physics_baseline.json are unchanged (diff empty).
- GODOT API: the new engine calls (`snappedf`, `clampf`, `Range.set_value_no_signal`, `BaseButton.set_pressed_no_signal`,
  `ScrollContainer.SCROLL_MODE_DISABLED`, `Label.clip_text`, `size_flags_stretch_ratio`, `CanvasLayer`) have no entry in
  docs/engine-reference/godot/breaking-changes.md or deprecated-apis.md (grep finds none), so they are "not staged".
  `FileAccess.store_string` returns bool (breaking-changes.md:91). The test ignores the return value, which is harmless.

### Mutations (scratch copy cc_gladius/scratch/vG2d, HEAD 95dba05 per its .git/refs; imported first; Edit, run, revert)
`git worktree add` and `git clone` both needed approval this session could not give. The pre-made scratch copy
cc_gladius/scratch/vG2d was used instead. The live tree was never edited. Runs used `-- --only=test_sensitivity` unless noted.
- M1 look_percent always uses row tpp_fpp_no_scope: CAUGHT (test_every_camera_and_ads_row_is_applied,
  test_every_gyro_row_is_applied: "camera row red_dot applied (got 0.019635)" ...).
- M2 ADS flag ignored (camera/gyro table always): CAUGHT (both row tests + test_look_state_api_picks_the_row "ADS table while
  aiming (expected 40.0, got 70.0)").
- M3 Free Look multiplier removed: CAUGHT (test_free_look_rows_applied).
- M4 Invert X removed: CAUGHT (test_gyro_inversion "invert X (expected (-0.25, 0.5), got (0.25, 0.5))").
- M5 `allows_gyro` = mode != off: CAUGHT (test_gyro_mode_gating "scope_on hip (expected false, got true)").
- M6 clamp_value without clampf: CAUGHT (test_gyro_max_400_clamps "gyro clamps to 400 (expected 400.0, got 1000.0)").
- M7 set_value no longer sets Custom: CAUGHT (presets test, round trip, screen test).
- M8 from_profile ignores legacy gyro_enabled: CAUGHT (test_old_gyro_enabled_migration "expected always_on, got off").
- P1 (full suite) match_root.gd:58 `router.sens = SensitivitySettings.from_profile(profile)` removed: NOT CAUGHT (266/266).
- P2 (same run) match_root.gd:204 `router.set_ads(local_player.aim_blend > 0.0)` removed: NOT CAUGHT.
- P3 (same run) `gyro_invert_x` dropped from to_dict (sensitivity_settings.gd:105): NOT CAUGHT. The round trip compares
  two to_dict outputs, and only invert_y persistence is asserted (test_sensitivity.gd:271).
All edits were reverted. `git diff --no-index --stat` of live scripts/ vs scratch scripts/ shows no file differences. This
shell has no rm, so the scratch copy could not be deleted. It is left clean at 95dba05.

VERDICT: ITERATE
1. scripts/systems/match_root.gd:58-59 with scripts/ui/settings_panel.gd:73-83 and :55-66: the Sensitivity screen and the
   gyro quick toggle can be opened from the in-match menu (CONTROLS.md:49), but the running match never re-reads the
   profile. router.sens and GyroProvider.mode are set once in _ready, so tables, presets, gyro mode and inversion changed
   mid-match do nothing until the next match. Fix: when SettingsPanel/SensitivityScreen saves (SettingsPanel.changed, or
   when the screen closes), have match_root reload `router.sens = SensitivitySettings.from_profile(AppFlow.profile)` and
   call `gyro.configure(...)` again. Add a test that edits a value through the in-match panel and measures the router look.
2. Missing tests for the match wiring (P1, P2 survive the full suite). fixG/G2d.txt item 1 says the ADS row applies while
   aim_blend > 0, but only the router is tested. Add a match-level test: set the profile's ads/tpp_fpp_no_scope to a
   non-default value, start a match, hold Aim (aim_blend > 0), and assert the look delta uses the ADS value, then the camera
   value after release.
3. data/input.json:21 `"default_preset": "medium"` is a default that the design does not give, with no `"_placeholder":
   true` or TODO. fixG/G2d.txt item 3 requires every other default to be a placeholder. Mark it and list it under OQ-SENS.
4. Small: round trip does not prove gyro_invert_x persists (P3). Assert `back.gyro_invert_x == true` in
   test_save_load_round_trip (test_sensitivity.gd:223-227). Also record the kept single toggle (settings_panel.gd:34, pinned
   by test_decisions_batch1.gd:108-114 and test_pause_menu.gd:267-272) in docs/OPEN_QUESTIONS.md so EL decides whether to
   retire those tests and the toggle.

## G2d2 review

Step: G2d2 fix round (task prompt fixG/G2d2.txt, on top of 15f148c), commit 6fdf804. Reviewer: Opus (VG2d2).

INPUTS: tests log/exit code = FOUND (cc_gladius/tests_G2d2.log; fixG.log:173 "GATE G2d2 apk=True tests=0 shots=97") ;
apk = FOUND (re-exported by this review, Glob finds build/gladius-debug.apk) ; shots = FOUND (n=97 in build/shots, including
the 4 named sensitivity_{cover,inner,cover_small,inner_small}_landscape.png) ; step commit = FOUND (6fdf804, 8 files,
+181/-6).

Gates run by this review (repo root, one command each): `mkdir -p build` exit 0; `godot.cmd --headless --path . --import`
exit 0; `godot.cmd --headless --path . --export-debug "Android" build/gladius-debug.apk` exit 0 ("Signed", APK verified);
`godot.cmd --headless --path . --script res://tests/run_tests.gd` exit 0, "TESTS: 270 passed, 0 failed" (266 before + 4 new
in tests/test_match_sensitivity.gd). No "SCRIPT ERROR" or "Parse Error". The only "ERROR:" line is the expected
`[button_capture] STOP, no usable lane` that test_button_capture_far_target.gd:148 provokes on purpose (PASS). GBTN tests
(test_action_buttons.gd, test_button_capture_far_target.gd), G2L tests (test_touch_layout_g2l.gd, 6) and G2d tests
(test_sensitivity.gd, 14) all PASS.

### Item by item (fixG/G2d2.txt)
1. In-match reapply: FIXED. scripts/systems/match_root.gd:74-76 adds `apply_sensitivity()`, which sets
   `router.sens = SensitivitySettings.from_profile(profile_cfg())` and re-configures the gyro provider with the new mode;
   it runs at start (:59) and on `pause_menu.settings.changed` (:61). The Sensitivity screen gains a `changed` signal emitted
   after every save (scripts/ui/sensitivity_screen.gd:9, :192) and the panel forwards it (scripts/ui/settings_panel.gd:84);
   the quick toggle and other panel edits already emit `changed` via persist() (settings_panel.gd:157). Inversion lives in
   router.sens (input_router.gd:52), so it is reapplied too. GyroProvider.configure keeps the data sensitivity because it only
   overwrites it when the key is present (gyro_provider.gd:28-29). Test: test_in_match_sensitivity_screen_applies_at_once
   moves the in-match slider to 40 and measures the router's look output (test_match_sensitivity.gd:111-112), then the
   gyro mode, invert X and a preset. PASS.
2. Match-level wiring test: FIXED. test_match_uses_ads_table_while_aiming_and_camera_table_otherwise
   (test_match_sensitivity.gd:73-96) sets ADS 37 and Camera 173 on tpp_fpp_no_scope, starts a match, holds Aim until
   aim_blend > 0, asserts the look is 37%, releases until aim_blend == 0 and asserts 173%. PASS.
3. default_preset: FIXED in substance. data/input.json:22-23 add `"_default_preset_placeholder": true` and a note naming
   OQ-SENS; docs/OPEN_QUESTIONS.md OQ-SENS now lists it. It is a sibling key, not a literal `"_placeholder": true` on the
   value. Wrapping the value as `{"value": ..., "_placeholder": true}` would change sensitivity_settings.gd:27 and the
   meaning of existing assertions test_sensitivity.gd:197 and :241 (both compare against `str(cfg["default_preset"])`), so
   the sibling key is the choice that leaves existing assertions alone. The file is also covered by the root
   `"_placeholder": true` (input.json:2) and the block note (input.json:19). Accepted (minor note 1).
4. Round trip: FIXED. test_sensitivity.gd:218 (pre-existing) sets `gyro_invert_x = true`; new lines :226
   `assert_eq(back.gyro_invert_x, true, "gyro_invert_x kept")` and :227 `assert_eq(back.gyro_invert_y, false, ...)`.
5. Old toggle: FIXED. `git diff 15f148c -- tests/test_decisions_batch1.gd tests/test_pause_menu.gd` is EMPTY. The toggle is
   unchanged (settings_panel.gd:34, :57-66). New test test_gyro_toggle_matches_sensitivity_gyro_mode
   (test_match_sensitivity.gd:137-157) checks off -> always_on -> off in the saved `sensitivity.gyro_mode`, the legacy
   `gyro_enabled` in step, and the panel state; test_quick_gyro_toggle_in_match_applies_at_once (:126-132) checks the running
   match follows. OQ-GYRO-TOGGLE exists in docs/OPEN_QUESTIONS.md (EL decides).

### Rule checks
- Data values: the only data change is the placeholder flag above. No value is newly labelled as PUBG's; the existing
  `_source` on the gyro and ADS-gyro max 400 (input.json:36-37) is the one the G2d prompt allows.
- Banned-word check (word list kept off-repo) prints nothing. docs/DESIGN.md unchanged.
- Existing tests: the only touched existing test file is tests/test_sensitivity.gd, and its diff is two added lines (:226,
  :227 above); no line changed or removed. tests/test_physics_baseline.gd, data/physics_baseline.json, .claude/settings.json
  and scripts/platform/ have an empty diff since 15f148c.
- iOS / cross-platform: no new platform API; changes are signals and data only. No new touch targets (the screen is the
  G2d one, already pinned at 48 dp by test_screen_buttons_sliders_and_persistence).
- Godot API: callable signal connections (`changed.connect(apply_sensitivity)`, `screen.changed.connect(changed.emit)`)
  follow docs/engine-reference/godot/deprecated-apis.md:28 and :47; tests use `await tree.physics_frame` per
  deprecated-apis.md:27. Nothing used appears in breaking-changes.md.

### Shots (opened)
- sensitivity_cover_landscape.png (2520x1080): Sensitivity screen with Back top-left and centred title; preset row Low /
  Medium (selected, black) / High / Custom (greyed); Gyro row Off (selected) / ADS / Always / Invert X / Invert Y; the Camera
  table (TPP/FPP no scope, Red dot, 2x, 4x, 8x, 16x) and the start of ADS, every slider at 100%, scrollbar on the right.
- sensitivity_inner_landscape.png (2176x1812): same layout, larger text; the full Camera and ADS tables are visible with
  sliders at 100%; buttons fill the width with no overlap.
- sensitivity_cover_small_landscape.png (small cover window): same screen scaled down; Camera table and ADS rows down to 4x
  visible, labels readable, nothing clipped.
- sensitivity_inner_small_landscape.png (small inner window): same screen; Camera table and ADS down to 8x; buttons and
  sliders inside the frame.
All four are consistent with the G2d shots: Medium preset, gyro off, 100% defaults. They are a retake; G2d2 did not change
the screen's layout.

### Mutations (scratch copy cc_gladius/scratch/vG2d2 at 6fdf804, imported first; one at a time, each undone)
- P1 match_root.gd:59 startup `apply_sensitivity()` removed (the only startup path that sets router.sens): CAUGHT, full suite
  "269 passed, 1 failed": test_match_uses_ads_table_while_aiming_and_camera_table_otherwise "two different values; not
  aiming: Camera value; aiming: ADS value, got 100.0; released: Camera value again".
- P2 match_root.gd:212 `router.set_ads(local_player.aim_blend > 0.0)` removed: CAUGHT, same test "aiming: ADS value, got
  173.000006830189".
- P3 `gyro_invert_x` dropped from SensitivitySettings.to_dict (sensitivity_settings.gd:105): CAUGHT, test_save_load_round_trip
  "gyro_invert_x kept (expected true, got false)" and test_in_match_sensitivity_screen_applies_at_once "inversion re-applied
  to the router".
- P4 match_root.gd:61 `pause_menu.settings.changed.connect(apply_sensitivity)` removed: CAUGHT,
  test_in_match_sensitivity_screen_applies_at_once "slider change measured in the router's look output; gyro mode
  re-applied to the provider (expected scope_on, got off) ..." and test_quick_gyro_toggle_in_match_applies_at_once "toggle
  applied to the running match (expected always_on, got off)".
- P5 settings_panel.gd:59 `s.set_gyro_mode(...)` removed (toggle stops updating the new mode): CAUGHT,
  test_gyro_toggle_matches_sensitivity_gyro_mode "off -> always_on in the sensitivity settings (expected always_on, got off)
  ...", test_quick_gyro_toggle_in_match_applies_at_once, and the pre-existing test_gyro_default_off_and_toggle_persists.
P2-P5 were run with `-- --only=<filter>` covering the G2d2 tests (P3 and P5 filters also covered test_sensitivity.gd and
test_decisions_batch1.gd). All five edits were reverted; the copy is left in place.

### Minor notes (no fix required for this step)
1. data/input.json:22 uses a sibling `_default_preset_placeholder` flag rather than the `{"value", "_placeholder"}` form
   used elsewhere in the same block (:34-38). A tool scanning for the literal `_placeholder` key on the value would miss it.
   Worth normalising if a placeholder scanner is added.
2. test_match_sensitivity.gd:108, :114, :129-130 read the private `MatchRoot._gyro`. Acceptable for a wiring test; a public
   getter would be cleaner.
3. apply_sensitivity also runs on unrelated panel saves (move stick, sprint slider). Harmless (it only re-reads the profile).

VERDICT: APPROVE
All 5 items of fixG/G2d2.txt are fixed and tested; gates green (270/270, APK exported); no existing assertion changed;
the 4 named shots are present and correct; mutations P1-P5 are each caught by a G2d2 test.

## G2e review

Reviewer: Opus (VG2e). Task prompt: fixG/G2e.txt. Step commit 4d204ba ("feat: G2e HUD layout editor"), prev = 28b123f.

INPUTS: tests log/exit code = FOUND (cc_gladius/tests_G2e.log; fixG.log:186 "GATE G2e apk=True tests=0 shots=101";
re-run by this review: exit 0, "TESTS: 283 passed, 0 failed") ; apk = FOUND (build/gladius-debug.apk, re-exported by this
review, exit 0, "Signed", "Verifying APK... DONE") ; shots = FOUND (n>100 in build/shots/*.png, including all 4 named
layout_editor_{cover,inner,cover_small,inner_small}_landscape.png) ; step commit = FOUND (4d204ba, 19 files, +1201/-30)

### Verification (run by this review, repo root, each command on its own)
- `godot --headless --path . --import`: exit 0, no errors.
- `godot --headless --path . --export-debug "Android" build/gladius-debug.apk`: exit 0, APK present (Glob).
- `godot --headless --path . --script res://tests/run_tests.gd`: exit 0, "TESTS: 283 passed, 0 failed" (13 new
  test_layout_editor.gd tests). The only "ERROR:" line is the existing negative test
  test_button_capture_far_target.gd::test_place_far_target_stops_when_no_lane_is_usable, which calls push_error on
  purpose and PASSes; it is not from G2e.

### Rules
- Banned-word check (word list kept off-repo) prints nothing.
- Existing tests: the commit touches no existing test file (stat: only tests/test_layout_editor.gd(.uid) under tests/). No
  assertion changed or removed. tests/test_physics_baseline.gd, data/physics_baseline.json and .claude/settings.json are
  not in the diff.
- Profile leak: AppFlow.profile is loaded only by scripts/ui/boot.gd:8, which the runner does not run. The new tests use
  `user://test_layout_editor_profile.json` (test_layout_editor.gd:15, :45) and restore AppFlow.profile, dpi_override
  and safe_insets_override in `_end()` (:31-35). Existing touch tests keep the data defaults.
- iOS / cross-platform: the safe area is read only in scripts/platform/platform_services.gd:31-44 behind an
  `OS.get_name()` match ("Android", "iOS"; other platforms -> Vector4.ZERO). No Android-only API elsewhere. Saves use user://.
- Godot API rule: APIs used are DisplayServer.get_display_safe_area / screen_get_size, Rect2.encloses / intersects /
  grow, snappedf, HSlider, CanvasLayer, CanvasItem.modulate. None of them appears in
  docs/engine-reference/godot/breaking-changes.md or deprecated-apis.md (searched). The only DisplayServer entries,
  breaking-changes.md:21 and deprecated-apis.md:39, are about AccessibilityLiveMode and do not apply.

### Task items (fixG/G2e.txt)
1. Editor screen: CHECKS OUT. Settings > "HUD layout" (settings_panel.gd:47, :105-117) opens scenes/ui/layout_editor.tscn
   on a CanvasLayer for both menus (shared SettingsPanel). The preview is the real touch HUD scene with both sticks,
   every button and Sprint lock (touch_hud.gd get_element_keys). Tap selects (layout_editor.gd:251-260), drag moves
   (:263-266), and there are per-element size and alpha sliders (:132-133, :212-223). Ranges: data/input.json
   `layout_editor`: size_pct 50/250/5 and alpha_pct 10/100/5, each `"_placeholder": true`, and the block is a
   placeholder too. Its `_todo` says "not a design value and not PUBG's"; CONTROLS.md and OQ-LAYOUT-EDITOR repeat that.
   Nothing labels 250 % as PUBG's. Positions are stored as fractions (hud_layout_model.gd:85-86).
2. 48 dp: CHECKS OUT. The slider's lower end is raised to ceil(min_px/base) (layout_editor.gd:177-181, :206, :215).
   The HUD clamps at render time too: buttons touch_hud.gd:472, sticks :519-521 (radius >= half of 48 dp), lock button
   :181-185. dp comes from the platform layer get_dp_scale(). Tested by test_size_never_below_48dp at dpi 0 and 420
   (slider end, slider clamp, drawn side, and a stored 50 % below the floor). Editor buttons and sliders are at least
   48 dp tall (layout_editor.gd:103, :119, :143, :155).
3. Off-screen warning: CHECKS OUT. Every edited slot plus the active one is checked at all four data sizes
   (layout_editor.gd:334-348, data check_sizes 2520x1080, 2176x1812, 1512x648, 1152x959; landscape only) against
   the platform safe area (:296-298), else the viewport. The warning names the element and size (:316). Save is
   disabled (:363) and save_layout refuses (:400-403). Tested at the four sizes, including x=0.96 fitting the cover
   screen but not the inner one (test :137-159). Safe area tested at :162-172; blocking and unblocking by fix or Reset
   tested at :175-190.
4. Slots, Reset, persistence: CHECKS OUT. 3 slots (data `slots`: 3, research "save three different layouts"), active
   select, Save, and per-slot Reset to an empty slot = the data touch_layout default (hud_layout_model.gd:99-100).
   Persisted under profile `hud_layouts` in user://profile.json (save_service.gd:23, :80, :96), sanitized on load
   (hud_layout_model.gd:50-68). touch_hud.gd:85-87 applies the active slot over the data defaults, and the in-match
   menu re-applies on Save (match_root.gd:64). The gear is not an editable element and stays top-right
   (pause_menu.gd gear_touch_rect from data). The lock position is mirrored to profile `sprint_lock_pos`, and the data
   default is never written (test :310-321). Reset test :221-263 compares every element with the data/input.json
   touch_layout default and with a fresh HUD. Round trip :266-307 covers a new editor and the game HUD from the file.
5. HUD clearance decision: DOCUMENTED, ONLY PARTLY TESTED. The choice is "warn only" (data `overlap_policy`,
   CONTROLS.md "Overlap policy", OQ-LAYOUT-EDITOR). check_slot warns on overlap with the HUD bars and labels
   (layout_editor.gd:308-321) and the gear. test_overlap_with_gear_warns_and_does_not_block (:326-341) covers only the
   gear. No test asserts a warning for overlap with a HUD bar, and mutation M5 below (bars list emptied) survives the
   whole layout-editor file. See ITERATE item 1.
6. Docs and shots: CHECKS OUT. CONTROLS.md "Layout editor (G2e)" section and OQ-LAYOUT-EDITOR are present. Shots below.

### Shots (opened)
- layout_editor_cover_landscape.png (2520x1080): editor panel top-centre (Slot 1 active, Save, Reset, Back, two
  sliders). Sprint lock is selected (gold outline, dimmed by reduced opacity). Jump has been moved up under the
  panel. Move stick bottom-left, look stick bottom-right, Swap/Aim/Reload/Fire west of it. No warning.
- layout_editor_inner_landscape.png (2176x1812): same panel with larger text. Look stick selected (gold box); default
  layout otherwise; no warning.
- layout_editor_cover_small_landscape.png (1512x648): THE OFF-SCREEN SHOT. Fire is dragged past the right edge
  (red/gold outline, half visible). Save is greyed out. The red warning reads "Fire is partly off-screen at 2520x1080 /
  2176x1812 / 1512x648 / (+1 more) / Fix it or press Reset to save." The expanded warning panel covers the top of
  the Sprint lock button (see minor note 1).
- layout_editor_inner_small_landscape.png (1152x959): Slot 2 active, move stick selected and made smaller with
  reduced opacity; the rest are defaults; no warning.

### Mutations (scratch copy cc_gladius/scratch/vG2e at 4d204ba, imported first; one at a time with Edit, each undone;
run with `-- --only=test_layout_editor`)
- M1 layout_editor.gd:181 slider floor removed (`return cfg min`): CAUGHT, test_size_never_below_48dp "slider lower
  end 50.0% is >= 48 dp at dpi 420.0" (all 8 elements).
- M2 touch_hud.gd:472 `_button_side` 48 dp maxf removed: CAUGHT, test_size_never_below_48dp "jump stored 50% still
  >= 48 dp at dpi 420.0, got 38.88".
- M3 layout_editor.gd:351 `is_blocked()` always false: CAUGHT, test_save_blocked_while_offscreen_until_fixed_or_reset
  "Save button disabled while off-screen; save_layout refuses; nothing was written" and
  test_offscreen_detected_at_the_four_sizes.
- M4 layout_editor.gd:334 check only the editor's own size: CAUGHT, test_offscreen_detected_at_the_four_sizes
  "fire at x=0.995 is off-screen at (2176, 1812) (editor at (2520, 1080)) ... x=0.96 falls off the inner screen".
- M5 layout_editor.gd:310 HUD-bar list emptied (gear check kept): NOT CAUGHT, "TESTS: 13 passed, 0 failed".
- M6 hud_layout_model.gd:100 Reset a no-op: CAUGHT, test_reset_restores_the_g2l_default_exactly (every element's
  centre, size, alpha, rect, and "profile sprint_lock_pos cleared") and the Save-after-Reset test.
- M7 hud_layout_model.gd:80-82 all edits go to slot 1: CAUGHT, test_three_slots_are_independent "slot 1 kept its
  move ... three slots persisted independently", test_real_hud_applies_the_active_slot_from_the_profile, and
  test_save_load_round_trip.
- M8 save_service.gd:96 save writes empty hud_layouts: CAUGHT, test_three_slots_are_independent "active slot
  persisted (expected 1, got 0)" and test_save_load_round_trip.
- M9 layout_editor.gd:353 overlap also blocks Save: CAUGHT, test_overlap_with_gear_warns_and_does_not_block "overlap
  alone does not block Save".
All 9 edits were reverted. A content diff of the copy's scripts/ against the repo's shows no differences. The copy is
left in place.

### Minor notes (no fix required for this step)
1. layout_editor.gd:102-137: the editor panel sits over the top of the HUD area and grows with the warning text. In
   the cover_small shot it hides part of the Sprint lock button, and taps there hit the panel, not the element.
   Worth a collapsible panel or keeping it clear of elements.
2. The two sliders have no "Size"/"Opacity" captions in the shots (only the element name), though CONTROLS.md calls
   them Size and Opacity sliders.
3. touch_hud.gd:139 (new) repeats the numeric fallback `get("stick_radius_frac_of_height", 0.12)` from the existing
   :520. The prompt asks for tunables without numeric fallbacks; the key exists in data, so it has no effect today.
   layout_editor.gd:130 `110.0 * _dp()` is a hard-coded label width.
4. Moving the look stick only moves its visual and its rect. Look input still starts anywhere in the data `look_zone`
   (touch_hud.gd:585), so a look stick dragged into the left half is decorative. Document this or move the zone with it.

VERDICT: ITERATE
1. tests/test_layout_editor.gd:326-341: the chosen clearance option (fixG/G2e.txt item 5, "the editor warns about
   overlap with the HUD bars") is not tested for the HUD bars. Only overlap with the gear is asserted, so removing every
   HUD bar from the check (layout_editor.gd:310, mutation M5) leaves all 13 tests green. Add a test that moves an
   element onto a HUD bar or label (e.g. the shield/health bar or the scores label) at a checked size and asserts an
   "overlap" issue naming that bar, a visible warning, and Save still enabled.

## G2e2 review

Opus check of 9810b7f ("fix: G2e2 HUD-bar overlap warning test") against fixG/G2e2.txt, prev = 5292ab5.

INPUTS: tests log/exit code = FOUND (cc_gladius tests_G2e2.log; fixG.log:199 "GATE G2e2 apk=True tests=0 shots=101";
re-run here: import exit 0, Android export exit 0, full suite exit 0 "TESTS: 284 passed, 0 failed") ; apk = FOUND
(build/gladius-debug.apk after this session's export) ; shots = FOUND (n>=100, including all 4 named
layout_editor_{cover,inner,cover_small,inner_small}_landscape.png) ; step commit = FOUND (9810b7f, 1 file, +19 lines)

Gate output: the only "ERROR:" line is the expected push_error from test_button_capture_far_target.gd:148
(tools/button_capture.gd:83), which that test asserts on and which predates this step; no SCRIPT ERROR or Parse Error.

### Diff
`git diff 5292ab5 --stat`: only tests/test_layout_editor.gd, 19 insertions, 0 deletions. The single hunk is
`@@ -343,0 +344,19 @@`, i.e. pure additions after the gear test; no existing line in the file is changed or removed.
No scripts/, data/*.json, docs, .claude/settings.json, tests/test_physics_baseline.gd or data/physics_baseline.json
change. No added line contains the banned word (checked the full `git diff 5292ab5 -U0`; commit message too). No new
data values, so no placeholder/_source question arises; no new Godot API (test uses existing helpers only); no
Android-only code, so the iOS rule is untouched.

### Item 1 (the one finding)
The new test is tests/test_layout_editor.gd:346-360 `test_overlap_with_hud_bar_warns_and_does_not_block`:
- :347/:349/:350/:351/:359/:360 use the same helpers as the gear test (_begin, _editor(COVER), select_element("jump"),
  move_selected_to(Vector2(0.06, 0.12)), free, _end). COVER is a checked size. OK.
- :348 re-asserts overlap_policy == "warn_only". OK.
- :352-356 looks for an issue with kind "overlap", element "jump", size COVER, text containing "the HUD (" and not
  "gear". OK for kind/element/size; see issue 1 for "names that bar".
- :357 `assert_true(ed.warn_label.visible, ...)`. OK.
- :358 `assert_true(not ed.is_blocked(), ...)` (Save still enabled). OK.
- No scripts/ change, so no root-cause write-up was needed.

### Existing tests
All of test_layout_editor.gd's 13 pre-existing tests (G2e), GBTN/G2L (test_touch_layout_g2l.gd, test_action_buttons.gd),
G2d/G2d2 (test_sensitivity.gd, test_match_sensitivity.gd) pass in the 284/284 run above.

### Mutations (scratch copy only; import run first; each undone before the next)
- P1 layout_editor.gd:310 `for n in [...7 bars...]` -> `for n in []` (gear only). Full suite: 283 passed, 1 failed;
  `--only=test_layout_editor.gd`: "FAIL test_layout_editor.gd::test_overlap_with_hud_bar_warns_and_does_not_block:
  overlap with a HUD bar is reported by name: []; warning shown". CAUGHT by the new test.
- P2 delete layout_editor.gd:312 `bars["gear"] = gear_rect(Vector2(sz))`. "FAIL
  test_layout_editor.gd::test_overlap_with_gear_warns_and_does_not_block: overlap with the gear is reported by name:
  [{ ... "text": "Jump overlaps the HUD (hill label) at 1512x648" }]". CAUGHT by the gear test.
- P3 (extra) layout_editor.gd:319 `"the HUD (%s)" % String(bname).replace("_", " ")` -> `"the HUD (something)"`.
  test_layout_editor.gd: 14 passed, 0 failed. SURVIVED: the new test does not check that the text names the bar.

### Shots (opened)
- layout_editor_cover_landscape.png (2520x1080): editor top panel (Slot 1 selected, Slot 2, Slot 3, Save, Reset,
  Back) with "Sprint lock" size/opacity sliders; Sprint lock button selected (gold box) mid-screen; Jump moved up near
  the panel; move stick bottom-left, Swap/Aim/Reload/Fire cluster and look stick bottom-right. No warning text.
- layout_editor_inner_landscape.png (2176x1812): same panel, "Look stick" selected (gold box, bottom-right); Sprint
  lock, Jump, the 2x2 button cluster and move stick in their G2L places. No warning.
- layout_editor_cover_small_landscape.png (1512x648): Fire dragged off the right edge (gold box clipped); red warning
  list "Fire is partly off-screen at 2520x1080 / 2176x1812 / 1512x648 / (+1 more) / Fix it or press Reset to save.";
  Save greyed out (blocked). The tall warning panel covers the top of the Sprint lock button in this editor view.
- layout_editor_inner_small_landscape.png (~1152x959): Slot 2 selected, "Move stick" selected (gold box, bottom-left);
  other controls in default places; Save enabled, no warning.
All four are landscape Fold sizes; buttons are visibly well above 48 dp (sizes are enforced by
test_size_never_below_48dp and test_targets_at_least_48dp_at_dpi_0_and_420, both passing).

VERDICT: ITERATE
1. tests/test_layout_editor.gd:354: fixG/G2e2.txt item 1 asks for an overlap issue "whose text names that bar". The
   test only checks the generic prefix "the HUD (" and the absence of "gear", so mutation P3 (layout_editor.gd:319
   replacing the bar name with a fixed word) leaves every test green. Fix: assert the text contains the specific bar
   the element is dropped on at Vector2(0.06, 0.12) on COVER (e.g. "shield bar" or "health bar", whichever the check
   reports first; layout_editor.gd:317-321 names only the first intersecting bar), so a wrong or missing bar name fails.

## G2e3 review

Opus check of 24a420c ("fix: G2e3 HUD-bar test asserts the bar name") against fixG/G2e3.txt (and fixG/G2e2.txt,
fixG/G2e.txt for what it leaves in place), prev = fb5b557.

INPUTS: tests log/exit code = FOUND (cc_gladius tests_G2e3.log; fixG.log:212 "GATE G2e3 apk=True tests=0 shots=101";
re-run here: import exit 0, Android export exit 0, full suite exit 0 "TESTS: 284 passed, 0 failed") ; apk = FOUND
(build/gladius-debug.apk after this session's export) ; shots = FOUND (n>=100, including all 4 named
layout_editor_{cover,inner,cover_small,inner_small}_landscape.png; not retaken this step, as the task allows) ;
step commit = FOUND (24a420c, 1 file, 1 insertion, 1 deletion)

Gate output: the only "ERROR:" line is the expected push_error from test_button_capture_far_target.gd:148
(tools/button_capture.gd:83), which that test asserts on and which predates this step; no SCRIPT ERROR or Parse Error.

### Diff
`git diff fb5b557 --stat`: `tests/test_layout_editor.gd | 2 +-`, nothing else (no scripts/, data/, docs, .claude/settings.json,
tests/test_physics_baseline.gd or data/physics_baseline.json). `git diff fb5b557 -- tests/test_layout_editor.gd` is a
single hunk `@@ -351,7 +351,7 @@ func test_overlap_with_hud_bar_warns_and_does_not_block()`; the one changed line:

    -		if it["kind"] == "overlap" and it["element"] == "jump" and it["size"] == COVER and it["text"].contains("the HUD (") and not it["text"].contains("gear"):
    +		if it["kind"] == "overlap" and it["element"] == "jump" and it["size"] == COVER and it["text"].contains("overlaps the HUD (shield bar) at") and not it["text"].contains("gear"):

It is :354, inside that test function (:346-360). The check is strictly stronger (the new substring contains the old
prefix "the HUD ("); kind/element/size/not-gear clauses and the assert messages at :356-358 are unchanged. No other
assertion in any test file is changed or removed. `git diff fb5b557 -U0` and the commit message contain no banned word.
No new data values (no placeholder/_source question), no new Godot API, no Android-only code (iOS rule untouched).

### Item 1 (the one finding)
scripts/ui/layout_editor.gd check_slot: :310 fills `bars` in the order shield_bar, health_bar, weapon_label, ammo_label,
scores_label, timer_label, hill_label, then :312 adds gear; :317-321 walks `bars` in that insertion order and `break`s on
the first intersection, and :319 builds "the HUD (%s)" from the key with "_" -> " ". Jump at (0.06, 0.12) on COVER sits
on the top-left stat block, so the first hit is shield_bar and the text is "Jump overlaps the HUD (shield bar) at
2520x1080" (confirmed: the test passes on the unmutated tree, and the P3 failure output below shows the same issue set at
all four sizes). The asserted "overlaps the HUD (shield bar) at" matches exactly. Fixed as written.

### Existing tests
All 284 pass, including test_layout_editor.gd (G2e/G2e2, 14 tests), test_touch_layout_g2l.gd and test_action_buttons.gd
(G2L/GBTN), test_sensitivity.gd and test_match_sensitivity.gd (G2d/G2d2). 48 dp floors still enforced by
test_size_never_below_48dp and test_targets_at_least_48dp_at_dpi_0_and_420 (both pass).

### Mutations (scratch copy only; import run first; each undone before the next; full suite then --only=test_layout_editor.gd)
- P1 layout_editor.gd:310 bar list -> `for n in []:` (gear only). Full suite "TESTS: 283 passed, 1 failed"; "FAIL
  test_layout_editor.gd::test_overlap_with_hud_bar_warns_and_does_not_block: overlap with a HUD bar is reported by
  name: []; warning shown". CAUGHT.
- P2 delete layout_editor.gd:312 `bars["gear"] = gear_rect(Vector2(sz))`. Full suite 283/1; "FAIL
  test_layout_editor.gd::test_overlap_with_gear_warns_and_does_not_block: overlap with the gear is reported by name:
  [{ ... "text": "Jump overlaps the HUD (hill label) at 1512x648" }]". CAUGHT.
- P3 layout_editor.gd:319 `"the HUD (%s)" % String(bname).replace("_", " ")` -> `"the HUD (bar)"`. Full suite 283/1;
  "FAIL test_layout_editor.gd::test_overlap_with_hud_bar_warns_and_does_not_block: overlap with a HUD bar is reported by
  name: [{ ... "text": "Jump overlaps the HUD (bar) at 2520x1080" }, ... 2176x1812, 1512x648, 1152x959]". CAUGHT
  (this survived in the G2e2 review; now killed).
Scratch copy restored (grep confirms :310, :312, :319 back to the original text) and left in place.

### Shots (opened; unchanged from G2e2)
- layout_editor_cover_landscape.png (2520x1080): top panel Slot 1 (active), Slot 2, Slot 3, Save, Reset, Back, with
  "Sprint lock" size/opacity sliders; Sprint lock selected (gold box) mid-screen; Jump moved up below the panel; move
  stick bottom-left; Swap/Aim/Reload/Fire 2x2 and look stick bottom-right. No warning.
- layout_editor_inner_landscape.png (2176x1812): same panel, "Look stick" selected (gold box bottom-right); Sprint lock,
  Jump, 2x2 cluster and move stick in their G2L places. No warning.
- layout_editor_cover_small_landscape.png (1512x648): Fire dragged off the right edge (gold box clipped); red list "Fire
  is partly off-screen at 2520x1080 / 2176x1812 / 1512x648 / (+1 more) / Fix it or press Reset to save."; Save greyed
  (blocked). The warning panel overlaps the top of the Sprint lock button in the editor view (cosmetic, pre-existing).
- layout_editor_inner_small_landscape.png (~1152x959): Slot 2 active, "Move stick" selected (gold box bottom-left);
  other controls in default places; Save enabled, no warning.
All four are landscape Fold sizes; every control is visibly well above 48 dp.

VERDICT: APPROVE
G2e3's single item is fixed exactly as asked (tests/test_layout_editor.gd:354 asserts "shield bar", which matches
check_slot's first-hit order at layout_editor.gd:310/317-321); only that line changed; no assertion weakened; suite
284/284; import and export clean; P1, P2 and P3 are all caught.

## G2f review

Opus check of 6c87f90 ("feat: G2f haptics settings and platform service") against fixG/G2f.txt, prev = 66f58c0.

INPUTS: tests log/exit code = FOUND (cc_gladius tests_G2f.log:337 "TESTS: 297 passed, 0 failed"; fixG.log:225 "GATE G2f
apk=True tests=0 shots=105") ; apk = FOUND (build/gladius-debug.apk, re-exported in this review) ; shots = FOUND (n>100;
all four named haptics_settings_{cover,inner,cover_small,inner_small}_landscape.png present) ; step commit = FOUND (6c87f90,
24 files, +710/-4).

### Run in this review (live repo, each command on its own)
- `godot.cmd --headless --path . --import`: exit 0, no project errors.
- `godot.cmd --headless --path . --export-debug "Android" build/gladius-debug.apk`: exit 0, "Signed", "Adding permission
  android.permission.VIBRATE", no ERROR lines. Glob finds build/gladius-debug.apk.
- `godot.cmd --headless --path . --script res://tests/run_tests.gd`: exit 0, "TESTS: 297 passed, 0 failed" (13 new in
  test_haptics.gd). The only "ERROR:" line is the pre-existing intentional push_error that
  test_button_capture_far_target.gd::test_place_far_target_stops_when_no_lane_is_usable expects (tools/button_capture.gd:83).
  G2f did not add it.

### Item 1: API check (G2f took the full path, not the STOP path)
- I searched it myself. `vibrate_handheld` IS staged: staging/godot-docs/class_input.md:1834 gives the signature
  `vibrate_handheld(duration_ms: int = 500, amplitude: float = -1.0)`, :1838 says amplitude is 0.0-1.0, :1840 says "implemented on
  Android, iOS, and Web. It has no effect on other platforms.", :1842 says Android needs VIBRATE in the export preset, and :1844
  says iOS honours duration only on 13+. docs/engine-reference/godot/ has no vibrate/haptic entry (grep: no match). So
  continuing past item 1 was correct.
- OQ-HAPTICS-API exists (docs/OPEN_QUESTIONS.md, added at :136) and is marked RESOLVED with those citations.

### Item 2: platform service
- scripts/platform/haptics_backend.gd:9-20: OS.get_name() switch. "Android", "iOS" call `Input.vibrate_handheld(duration_ms,
  amplitude)` (staged signature). Everything else, and headless, is a no-op. The iOS path follows the doc (:1840).
  Web is a documented no-op for now (OQ-HAPTICS-API). OK.
- Permission: export_presets.cfg:68 `permissions/vibrate=true`, per class_input.md:1842. The export log confirms it. OK.
- `Input.vibrate_handheld` is called only in scripts/platform/ (grep over *.gd: haptics_backend.gd:20, plus the
  pre-existing platform_services.gd:94). OK. Gameplay goes through `Haptics.play(...)` (scripts/platform/haptics.gd:16)
  from scripts/systems/haptics_events.gd:9-12. No gameplay file touches Input for vibration.
- Unsupported devices: haptics_service.gd:66-67 `is_enabled()` is `enabled and is_supported()`, and play() returns early
  (:91). The screen shows "Not available on this device" and disables the controls (haptics_screen.gd:62-63, :110-123). OK.

### Item 3: categories, quality, data
- data/haptics.json:11 categories = weapons, status, sound_cues. There is **no vehicle category**. Events: weapon_fire,
  weapon_reload, melee_hit (weapons), damage_taken, shield_break, death (status), sound_cue (sound_cues). Each category has
  a toggle (haptics_screen.gd:65-66). Sound cues are wired to nothing, with OQ-HAPTICS-SOUND-CUES, as the prompt allows.
- High/Low: every event has `high` and `low` {duration_ms, amplitude} blocks and `"_placeholder": true` (haptics.json:13-26).
  The root (:2) and defaults (:5) are `_placeholder` too, and OQ-HAPTICS-VALUES lists them. play() picks `ev[quality]`
  (haptics_service.gd:99). The service reads them with no numeric fallback.
- Defaults: on, every category on, High (haptics.json:4-9), placeholders. No value is labelled as PUBG's: CONTROLS.md says
  "not PUBG's", and the diff adds no `_source`.

### Item 4: settings UI and persistence
- Settings > "Haptics" (settings_panel.gd:51, :136-155). It is reachable from the main menu and the pause menu through the
  shared SettingsPanel.
- Persistence: profile key `haptics` in SaveService (save_service.gd:24, :82, :99), which is the user:// profile.
  sanitize() falls back to data defaults (haptics_service.gd:31-46). OK.
- 48 dp: UiScale.bind (haptics_screen.gd:33), and test_haptics.gd:169-171 checks master_button against
  48 * PlatformServices.get_dp_scale(). In the shots, every button is well above 48 dp.

### Item 5: tests (tests/test_haptics.gd, new file)
- The category gating (:43-59), master off (:62), quality High vs Low values from data (:75-90), unsupported = off and no
  calls (:99-106), round trip through a user:// file (:117-132), corrupt profile (:135), screen persistence and the
  unsupported text (:141-173), and a real offline match where `fire_shot()` reaches the fake through Haptics.play with the data
  values (:185-221) are all present. The fake backend is injected via `HapticsService.new({}, fake)`.
- Weak spot (note 2): the match test emits `reload_started`, `melee_landed` and `damaged` directly (:210-217). Only fire
  goes through real gameplay code.

### Item 6 and other checks
- docs/CONTROLS.md:132-146 Haptics section with the class_input.md file:line citations.
- Existing tests: the commit touches no existing test file (`--stat` lists only the new tests/test_haptics.gd). No assertion
  changed or removed.
- `git diff 66f58c0 6c87f90 --stat -- .claude/settings.json tests/test_physics_baseline.gd data/physics_baseline.json` is
  empty.
- Banned-word check (word list kept off-repo): a case-insensitive grep of the repo finds hits only in pre-existing files
  (DESIGN.md, ARCHITECTURE.md, OPEN_QUESTIONS.md:29, plans/sprint1.md, damage_rules.gd:3, earlier review text). None of the
  24 G2f files contains it, and the commit message doesn't either.
- iOS: no Android-only API outside scripts/platform/. The backend's iOS branch uses the same documented cross-platform call.
- GODOT API: Input.vibrate_handheld (class_input.md:1834-1850). Button.toggle_mode, set_pressed_no_signal, CanvasLayer,
  OS.get_name and DisplayServer.get_name have no entry in breaking-changes.md or deprecated-apis.md.

### Shots (opened and viewed)
- haptics_settings_cover_landscape.png (2520x1080): Back (red) top-left, "Haptics" title centred. Then full-width rows:
  "Haptics: On", "Weapons (fire, reload, melee hit): On", "Status (damage, shield break, death): On", "Sound cues: On".
  Then "Quality:" with a dark "High" button and a red/gold-bordered "Low" button. The lower ~40% is empty. No
  "Not available" text (the fake backend reports supported).
- haptics_settings_inner_landscape.png (2176x1812): the same layout, larger text. The rows fill the top ~55%.
- haptics_settings_cover_small_landscape.png (1512x648): the same, scaled down. Rows about 58 px tall.
- haptics_settings_inner_small_landscape.png (1152x959): the same. The rows and quality buttons are clearly above 48 dp.
- In all four, the **selected** quality (High, the default) is drawn dark and the unselected **Low** is drawn red with a
  gold border, so the screen reads as "Low selected" (Issue 1).

### Notes (not blocking)
1. scripts/platform/platform_services.gd:90-96 (pre-existing) still has `vibrate(ms)`, which calls Input.vibrate_handheld
   without the haptics settings. Nothing calls it today. Delegate it to Haptics or remove it so the toggles cannot be
   bypassed later.
2. tests/test_haptics.gd:210-217 emit the reload, melee and damage signals by hand, so they only prove the binding in
   haptics_events.gd, not that Pawn emits `melee_landed`/`damaged` (pawn.gd:125-128, :181-183).
3. docs/CONTROLS.md:136 cites the staged doc with an absolute user path. A repo-relative "staging/godot-docs/..." (as
   in OPEN_QUESTIONS.md) would be cleaner.

### Mutations (scratch copy cc_gladius/scratch/vG2f at 6c87f90, imported first; each made with Edit, run, then undone)
- M1 haptics_service.gd:97 category gate disabled (`if false and ...`): CAUGHT. The full suite gives "295 passed, 2 failed":
  FAIL test_each_category_toggle_gates_its_events ("weapon_fire blocked when weapons is off; ... expected 4, got 7") and
  FAIL test_match_gameplay_events_reach_the_service ("weapons off -> the next shot makes no call (expected 4, got 5)").
- M2 haptics_service.gd:99 `ev["high"]` regardless of quality: CAUGHT. FAIL test_quality_selects_high_or_low_values_from_data
  ("weapon_fire low values (expected [12, 0.3], got [25, 0.6]) ...").
- M3 haptics_service.gd:67 `is_enabled()` ignores is_supported(): CAUGHT. FAIL test_unsupported_device_is_off_and_never_calls
  ("no backend calls (expected 0, got 2)") and FAIL test_screen_toggles_persist_and_unsupported_shows_text ("reads Off").
- M4 haptics_events.gd:9 shot_resolved no longer plays weapon_fire: CAUGHT. FAIL test_match_gameplay_events_reach_the_service
  ("a fired shot -> one weapon_fire haptic call (expected 1, got 0)").
- M5 pawn.gd:126 `damaged` never emitted: SURVIVES. The full suite gives "297 passed, 0 failed". This confirms note 2: the
  status-event path from real damage is untested. The prompt's item 5 only requires the weapon-fire path, so this is not
  blocking.
- M6 save_service.gd:99 save drops the haptics settings (`sanitize(null)`): CAUGHT. FAIL test_profile_round_trip ("quality
  round-trips (expected low, got high)") and FAIL test_screen_toggles_persist_and_unsupported_shows_text ("quality saved").
- After undoing all six, `--only=test_haptics` in the copy gives "TESTS: 13 passed, 0 failed". The copy is left in place.
  The live repo was never mutated.

VERDICT: ITERATE
1. scenes/ui/theme.tres:23 styles only `Button/styles/normal` (red, gold border), and scripts/ui/haptics_screen.gd:72-73,
   :120-123 rely on the toggle-button pressed state to show the chosen quality. The pressed state falls back to the default
   dark style, so the active quality (High) looks dark and the inactive Low looks highlighted, which is inverted in all four
   shots. The category rows survive only because their text says On/Off. Fix: give the selected quality a clear marker,
   either a `pressed` style in the theme or a text cue ("High (selected)" / a check mark) as the category rows do. Retake the
   four shots, and add a test asserting the active quality button is visually distinguished (e.g. its text or style
   override) after choosing Low.

## G2f2 review

Opus check of 76572d4 ("fix: G2f2 selected haptics quality is visibly marked", parent b219360) against fixG/G2f2.txt,
prev = b219360.

INPUTS: tests log/exit code = FOUND (cc_gladius tests_G2f2.log:339 "TESTS: 299 passed, 0 failed"; fixG.log:238 "GATE G2f2
apk=True tests=0 shots=105"; also re-run here, see below) ; apk = FOUND (build/gladius-debug.apk, re-exported in this review,
Glob finds it) ; shots = FOUND (n>100; all four named haptics_settings_{cover,inner,cover_small,inner_small}_landscape.png
present) ; step commit = FOUND (76572d4, 5 files, +66/-2).

### Run in this review (live repo, each command on its own)
- `godot.cmd --headless --path . --import`: exit 0, no project errors.
- `godot.cmd --headless --path . --export-debug "Android" build/gladius-debug.apk`: exit 0, "Signed", no ERROR lines.
- `godot.cmd --headless --path . --script res://tests/run_tests.gd`: exit 0, "TESTS: 299 passed, 0 failed" (2 new in
  tests/test_haptics_marker.gd). The only "ERROR:" line is the pre-existing intentional push_error expected by
  test_button_capture_far_target.gd::test_place_far_target_stops_when_no_lane_is_usable (tools/button_capture.gd:83).

### Item 1: pressed style, marker, test, shots
- scenes/ui/theme.tres:19-25 adds StyleBoxFlat `button_pressed` (gold bg Color(0.85, 0.68, 0.2), light-gold border), and
  :33 `Button/styles/hover_pressed`, :35 `Button/styles/pressed` use it; :31-32 set a dark-red font for pressed and
  hover-pressed so text stays readable. Normal (:11-17, :34) stays red with a gold border, so pressed is clearly distinct.
  Red/gold follows docs/DESIGN.md:31 (HUD colours). The theme is not a tunable number store, so no data/*.json entry is
  needed; no new numeric tunable was added in code.
- scripts/ui/haptics_screen.gd:16-17 `SELECTED_MARKER := "[x] "`, :125 the quality text is the marker plus the title only
  when `q == service.quality`; it runs in `_refresh()`, so it follows every change of selection.
- New test tests/test_haptics_marker.gd:20-38 instantiates the real haptics_screen.tscn with a fake supported backend,
  asserts the selected quality begins with the marker and the other has none (:30-32), presses the other button through
  its real `pressed` signal (:33), then asserts the marker moved and left the old one (:34-36). :41-48 assert the theme has
  `pressed` and `hover_pressed` Button styles and that their bg colours differ from `normal`. This covers all three things
  the prompt asks for.
- Shots (opened and viewed):
  - haptics_settings_cover_landscape.png (2520x1080): red Back top-left, "Haptics" title, four full-width gold rows with dark
    text ("Haptics: On", "Weapons (fire, reload, melee hit): On", "Status (damage, shield break, death): On", "Sound cues:
    On"), then "Quality:" with a gold "[x] High" button and a red "Low" button with gold text. Lower ~40% empty.
  - haptics_settings_inner_landscape.png (2176x1812): same layout, larger text; "[x] High" gold, "Low" red.
  - haptics_settings_cover_small_landscape.png (1512x648): same, scaled down; "[x] High" gold, "Low" red.
  - haptics_settings_inner_small_landscape.png (1152x959): same; "[x] High" gold, "Low" red.
  - In all four the selected quality (High, the default) is the distinct one: gold fill plus the "[x]" marker, while Low
    uses the plain red normal style. The G2f inversion is fixed. The On toggles now also draw gold (pressed), which matches
    their "On" text. All buttons are well above 48 dp in every shot.

### Item 2: CONTROLS.md citation
- docs/CONTROLS.md:136 now cites `staging/godot-docs/class_input.md:1834` (relative). P-check: the added lines of
  `git diff b219360 -U0` contain no absolute user path (none of the 5 files' + lines has it). OK.

### Nothing else changed
- `git diff b219360 --stat` lists only docs/CONTROLS.md, scenes/ui/theme.tres, scripts/ui/haptics_screen.gd,
  tests/test_haptics_marker.gd and its .uid. scripts/platform/platform_services.gd (vibrate()) is untouched. No
  damaged-signal test was added (the new file has only the two tests above).
- No existing test file is touched, so no assertion was changed or removed.
- .claude/settings.json, tests/test_physics_baseline.gd and data/physics_baseline.json are not in the diff.
- Data: the step adds no data value; nothing is labelled as PUBG's and no `_source` was added.
- Banned-word check (word list kept off-repo): no added line in `git diff b219360 -U0` contains it, nor does the commit
  message. The only occurrences are pre-existing (e.g. the DESIGN.md wording), not new.
- iOS: no platform code changed; no Android-only API outside scripts/platform/.
- GODOT API: Theme.has_stylebox/get_stylebox, StyleBoxFlat.bg_color and Button `pressed`/`hover_pressed` theme items have no
  entry in docs/engine-reference/godot/breaking-changes.md or deprecated-apis.md (grep for "stylebox": no match; the only
  theme item, breaking-changes.md:57, is the editor theme and does not apply). modules/ui.md:38-44 confirms custom game
  themes work as before in 4.6+.

### Mutations (scratch copy cc_gladius/scratch/vG2f2 at 76572d4, imported first; each made with Edit, run, then undone)
- M1 theme.tres:35 `Button/styles/pressed` line removed: CAUGHT. Full suite "298 passed, 1 failed"; `--only=test_haptics_marker`
  gives FAIL test_theme_has_distinct_pressed_button_style: "theme has Button pressed style".
- M2 haptics_screen.gd:125 marker line removed: CAUGHT. FAIL test_selected_quality_has_marker_and_follows_selection:
  "selected shows marker; marker moved to new choice".
- M3 (extra) marker put on both quality buttons: CAUGHT. FAIL test_selected_quality_has_marker_and_follows_selection:
  "unselected has no marker; marker removed from old choice".
- After undoing all three, `--only=test_haptics` in the copy gives "TESTS: 15 passed, 0 failed". The copy is left in place.
  The live repo was never mutated.

### Notes (not blocking)
1. The new pressed style is theme-wide, so the toggle buttons in scripts/ui/sensitivity_screen.gd and
   scripts/ui/layout_editor.gd (toggle_mode = true) now also draw gold when pressed. This is consistent with the fix and
   likely an improvement, but those screens' shots were not retaken in this step.
2. Carried over from the G2f review: the `damaged` path from real damage (pawn.gd) is still untested, and
   platform_services.gd vibrate() still bypasses the haptics settings. Both were out of scope here by the prompt.

VERDICT: APPROVE

Note: G2f/G2f2 commits were rebuilt before push to remove an absolute user path; old->new SHAs: 6c87f90->129d0e5, 12a73ad->d0f9a35, b219360->a9f36a2, 76572d4->a39ddf3, 243e7c6->cc94fb6.

## G3a review

Task: fixG/G3a.txt. Step commit 91e3700, prev d3af596.

INPUTS: step commit = FOUND (91e3700, `git diff d3af596 --stat`: 3 files, 36 insertions) ; test run = FOUND (run in this
review: import exit 0, Android export exit 0, full suite exit 0 "TESTS: 300 passed, 0 failed"; the step log
cc_gladius/tests_G3a.log also shows 300/0) ; apk = FOUND (build/gladius-debug.apk, re-exported in this review) ;
Fold-size shots including the named ones = ABSENT (the count of build/shots/*.png is well over 4, and all four named files
exist, but only the two cover shots are Fold size. sprint_lock_inner_landscape.png and sprint_locked_inner_landscape.png
are 2176x1421, not the 2176x1812 Fold inner size the prompt asks for (fixG/G3a.txt:1, :12). The step's own report
(cc_gladius/out/G3a.json) says the OS window was clamped to this desktop's screen height. The G2c inner shot of the same
screen was 2176x1812 (see the G2c review above).)

What the two inner files show (described anyway, for the retake): sprint_lock_inner_landscape shows the move stick at rest
bottom-left, the light "Lock" target above it, "Sprint lock" in the button cluster, and Swap/Aim/Reload/Fire/Jump with the
look stick bottom-right. sprint_locked_inner_landscape shows the same layout with the target gone and the button reading
"Locked" (highlighted). At this shorter 1421 px height, the Sprint lock / Locked circle touches the top of Swap.
test_lock_button_clear_of_hud_at_four_sizes passes at the real 2176x1812, so this is a side effect of the clamped window,
not a G3a finding. The cover shots (2520x1080) show the same two states with clear gaps: "Lock" above the stick and
"Sprint lock" in the first shot, "Locked" with no target in the second. Both carry the "desktop render, not device" label.

Checks completed before the verdict, for the re-run (they do not replace it):
- Scope: `git diff d3af596 --stat` lists only docs/CONTROLS.md, docs/OPEN_QUESTIONS.md and tests/test_sprint.gd.
  Nothing changed under scripts/, data/, scenes/ or tools/. .claude/settings.json, tests/test_physics_baseline.gd and
  data/physics_baseline.json are unchanged.
- tests/test_sprint.gd: the diff is one added hunk at :494-522 (`@@ -493,0 +494,29 @@`) with no changed or removed line.
  The new test_tap_on_stick_cancels_lock_and_stops loops `_modes()` (:498). It locks by release on the target (:507-511,
  same calls as :374-378) and asserts the lock (:512). It then taps with `_touch(hud, 1, start, true)` and
  `_touch(hud, 1, start, false)` (:514-515, no drag), asserts `not sprint_locked` (:516), and after one `update_frame(DT)`
  asserts `fr.move == Vector2.ZERO and not fr.sprint` (:517-518). It frees the router and HUD and resets
  move_stick_override (:519-522).
- data/stats.json:25 `sprint_hold_s` is still `{"_source": "Shibi Oct 22", "value": 0.5}`. The trigger
  (scripts/input/sprint_detector.gd:35-43) is unchanged.
- docs/OPEN_QUESTIONS.md:70 adds OQ-SPRINT-HOLD (Shibi decides: keep the hold or start on the threshold).
  docs/CONTROLS.md:99-103 adds "Compared with PUBG Mobile (G3a)" at the end of the Sprint section. The three findings are
  labelled OFFICIAL plus COMMUNITY-REPORTED, OFFICIAL plus COMMUNITY-REPORTED, and COMMUNITY-REPORTED, as quoted in the
  prompt. The only number, 0.5 s, is attributed to Gladius, not to PUBG. No value is labelled as PUBG's.
- P-check: no added line of `git diff d3af596 -U0` contains an absolute user-home path (the P-check search string). Banned-word check (word list kept off-repo):
  no added line contains a listed word.
- iOS / cross-platform: no code change, so no new platform API. GODOT API: no new engine API was used.
- Mutations, in the orchestrator's scratch copy (cc_gladius/scratch/vG3a) only, each undone before the next. The live
  repo was never mutated.
  - M1, delete `provider.cancel_sprint_lock()` at scripts/ui/touch_hud.gd:580: CAUGHT. 298/2. The new test fails in all 3
    modes ("tap cancels the lock", "stopped after the tap, move (0.0, -1.0)"), and so does
    test_release_on_target_locks_release_elsewhere_stops ("new move touch cancels the lock").
  - M2, `var on_target := true` at scripts/ui/touch_hud.gd:629: CAUGHT. 293/7. The new test fails on sprint_locked and
    fr.move in all 3 modes, and tests/test_sprint.gd:371 fails ("release elsewhere stops", all 3 modes). Also failing:
    test_touch_controls_custom, plus test_touch_virtual's gui_routed, multitouch and floating_spawn tests.
  - M3, get_threshold returns `threshold_at_0` at scripts/input/sprint_detector.gd:36: CAUGHT. 299/1.
    tests/test_sprint.gd:244 fails: "push length shrinks with sensitivity: 0.98 0.98 0.98".
  - Afterwards the copy is restored to the G3a code and left in place.

VERDICT: NOT ASSESSED
MISSING: Fold-size inner shots. build/shots/sprint_lock_inner_landscape.png and
build/shots/sprint_locked_inner_landscape.png are 2176x1421 instead of 2176x1812, because the capture window was clamped to
the desktop screen height. To fix, retake both with the existing tool (`res://tools/touch_capture.tscn`,
`--resolution 2176x1812`) on a setup that does not clamp the window, so the PNGs really are 2176x1812, and confirm
RESULT sprint_state_ok=true. Every other check above passed, including all three mandatory mutations.
