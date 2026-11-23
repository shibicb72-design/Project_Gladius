# Project Gladius architecture

Companion to docs/DESIGN.md (the approved design, which wins on any conflict). This file describes how
the code is organized so that later features plug in without rewrites. Placeholders and undecided
items are tracked in docs/OPEN_QUESTIONS.md; the milestone-1 build order is in docs/plans/sprint1.md.

## 1. Principles

1. **Data first.** Every tunable number lives in `res://data/*.json`. Code holds behavior, data holds
   values. Adding a class, weapon, deployable, faction, mode variant, bot profile or cosmetic that
   reuses an existing behavior is a data-only change.
2. **Rules separate from presentation.** Anything that decides an outcome (hits, damage, scoring,
   spawns, payouts, unlocks) is a pure `RefCounted` script in `scripts/systems/`. It has no Node, scene,
   rendering or input dependency, takes time as an explicit `delta`, and gets randomness from an
   injected seeded `RandomNumberGenerator`. These scripts run headless in tests, on the host phone, and
   later on the dedicated server on the Alienware PC, unchanged.
3. **One authority.** The host phone (later the dedicated server) is the only place rules run for a
   networked match. Clients send intent and render state.
4. **Platform-neutral.** Input goes through `scripts/input/`. OS-specific code goes through
   `scripts/platform/`. Saves use `user://`. UI is anchors/containers. Networking is ENet via the
   high-level multiplayer API. Nothing outside `scripts/platform/` checks `OS.get_name()`.
5. **Small scenes.** One responsibility per scene; compose by instancing.

## 2. Folder layout

```
data/                 JSON data (stats.json, modes.json, match.json, bots.json, input.json, camera.json,
                      net.json, loadouts.json, graphics_presets.json, maps/*.json; later economy.json,
                      progression.json, deployables.json, scorestreaks.json, grenades.json, scopes.json,
                      attachments.json, tiers.json, factions.json, cosmetics.json, medals.json, traits.json)
scenes/               boot/, ui/, player/, maps/, match/, test/ (later: deployables/, vehicles/, fx/)
scripts/systems/      pure rules + registries + match orchestration nodes (match_director, hill_zone)
scripts/classes/      class definitions, pawn
scripts/weapons/      weapon defs, weapon runtime, hitscan, loadout, (later) stat resolver
scripts/net/          session, lobby state, match bridge (replication/RPC)
scripts/ui/           menus, HUD, touch HUD, formatters (roman numerals)
scripts/input/        InputFrame, InputRouter, providers/
scripts/platform/     PlatformServices + per-OS implementations
tests/                run_tests.gd, test_case.gd, test_*.gd
android/              debug.keystore (shared debug key only)
```

## 3. Data loading

- `DataRegistry` (`scripts/systems/data_registry.gd`) is the only code that reads `res://data/*.json`.
  It caches each file. It exposes typed accessors (`get_class_def(id)`, `get_weapon_def(id)`,
  `get_mode(id)`, ...) and a `validate()` that returns a list of problems instead of printing errors.
- Every file has `"version": <int>` at the top level and entries keyed by a stable lowercase `id`.
  Display text is a field (`display_name`), never the key.
- Typed wrappers (`ClassDef`, `WeaponDef`, `ModeDef`, ...) are built from dictionaries in one place,
  so a renamed key is fixed in one file.
- Placeholders: `"_placeholder": true` and `"_todo": "OQ-xx"` on the entry or section. Keys starting
  with `_` are metadata and ignored by loaders.
- Behavior is selected by id, not by code edits. A data entry names a behavior (`"kind": "hitscan"`,
  `"rules": "koth"`, `"behavior": "bubble_shield"`). A small registry maps that id to a script/scene.
  New *values* need data only; a new *behavior* needs one script plus one registry line, and nothing
  else changes.
- Export: `include_filter="data/*.json"` in the Android preset, because plain JSON is not a Godot
  resource and would otherwise be left out of the APK.
- Tests load data through the same registry, so a malformed data edit fails the test gate.

## 4. Systems

### 4.1 Classes
- Data: `stats.json` `classes` holds the core table (shield, health, speed_pct) plus traits
  (`skill`, `role`, `vehicle_speed_pct`). Later fields: `prone_radar_hide` (Velites best, Triarii
  worst), `off_class_penalty` (aim/recoil; Hastati/Principes none), `unlock` (`start` or
  `rank_or_denarii` with `after` and price from `economy.json`), `streaks_extra` (Sagittarii support
  streaks), `faction_skins`. `enabled` scopes a build.
- Code: `ClassDef` (typed), `Pawn` reads it at spawn. Class skills are behaviors keyed by `skill` id
  (e.g. `mark` → `scripts/classes/skills/mark.gd`).
- Add a class: new entry in `classes`. Write a skill script only if it uses a new skill id.
- Counters (Gladiators beat line infantry, Sagittarii one-shot Gladiators...) come from numbers in
  data (class shield/health vs weapon damage, melee multipliers), not from special-case code.

### 4.2 Weapons (tiers, scopes, attachments)
- Data:
  - `stats.json` `weapons`: base stats per weapon id, `kind` (hitscan, projectile, beam, melee,
    thrown...), `scope_slots`, `attachment_slots`, `power_weapon` flag, `class_affinity`.
  - Later, separate files:
    - `tiers.json`: standard/upgraded/legendary multipliers or overrides
    - `scopes.json`: red dot, 2x, 4x, 8x, 16x; zoom, FOV and aim-assist zone scale
    - `attachments.json`: stat modifiers, add or multiply
- Code: `WeaponStatsResolver` (pure) computes the final stats from
  base + tier + scope + attachments + class off-class penalty. Gameplay and the shop's stat chart both
  use it, so the chart can never disagree with the game.
- `Weapon` (runtime: timing, burst, magazine, reload) consumes the resolved stats. Fire behavior is
  chosen by `kind` (`hitscan.gd`, later `projectile.gd`).
- Hits are reported to an injected authority callable. Offline it calls DamageRules directly; online it
  sends a fire request to the host.
- Pickups (later): a dropped weapon carries its resolved stats + ammo; crates refill; lost on death.
- Add a weapon: data entry + optional model scene path. Add a scope/attachment/tier: data entry.

### 4.3 Grenades
- Data (later): `grenades.json` with `ignis_sticky`, `frag`, `smoke`, each with `behavior`
  (`sticky_explode`, `explode`, `smoke_cloud`), damage/radius/fuse; spawn counts
  `{ignis_sticky:1, frag:2, smoke:1}` and `carry_max: 7` (design values).
- Code: a thrown-projectile scene + behavior scripts. Explosion damage goes through DamageRules with
  an `aoe` flag (the economy pays the AoE kill bonus). Smoke registers a sight-blocker volume used by
  bot perception and radar.

### 4.4 Deployables
- Data (later): `deployables.json`. Each entry has `behavior` id, `scene`, `duration_s`, params and
  `carry_max` (5, design). A map-level spawner has `spawn_interval_s` and spawn points.
  Testudo bubble: 30 s, rallies squad bots, can be fired out of. Also radar jammer, turret, healing
  station, grav lift, decoy, mine field, regen field.
- Code: `Deployable` base node + behavior scripts. Effects that change outcomes (heal amounts, jammer
  radius) are computed by rules helpers.
- Add a deployable: data entry; a behavior script only for a new behavior.

### 4.5 Scorestreaks
- Data (later): `scorestreaks.json`. Thresholds: ammo drop 3, support chariot 5, orbital
  bombardment 10 (design). Each streak has a `behavior` id, and class extras (Sagittarii) are listed
  per class.
- Code: `StreakRules` (pure) counts player kills only, resets on death, and emits `streak_earned`.
  Activation scenes are keyed by behavior.

### 4.6 Economy / Denarii
- Data (later): `economy.json`.
  - Kill payouts: start 500; player kill 20, headshot +10, assassination +25, class bonus +15,
    deployable/AoE +5 (bonuses stack).
  - Squad-bot chain: 10, ×1.5 per kill, cap 100, resets on bot death.
  - Match payouts: win 100, 1 per second on the hill, 10 per medal; quitters lose match Denarii.
  - Prices and the class unlock cost of 1500.
- Code: `EconomyRules` (pure) takes the match event log (kills with flags, hill seconds, medals,
  result, quit) and returns a payout per player. It runs only on the authority. Clients receive their
  payout and save it. Tests cover each bonus and the chain cap.

### 4.7 Progression and saves
- Data (later): `progression.json` (12 ranks Tiro..Consul with XP thresholds), `medals.json`,
  `traits.json` (virtues and bad traits with decay rules), `cosmetics.json` (slot, rarity, price),
  loot tables by rarity.
- Code: `ProgressionRules` (pure: XP → rank, trait updates, loot rolls with seeded RNG).
  `SaveService` (`scripts/systems/save_service.gd`):
  - `user://profile.json` with a `version` field and migration functions per version
  - tolerant load: a missing or corrupt file gives defaults and keeps a `.bak`
  - writes to a temp file, then renames
  - later sync to the Alienware PC keeps `user://profile.last_synced.json` as the last good sync and
    resolves conflicts against it
- Never use absolute paths. Paths come from PlatformServices when the OS requires it (e.g. the log
  file for "Send logs").

### 4.8 Factions
- Data (later): `factions.json`. Romans now; Spartans etc. later. Each has `display_name`, class
  roster (ids into `classes`), skin set, announcer set and colors.
- Code: the lobby and spawn code look up the faction for a squad; presentation picks skins/announcer
  by faction id.
- Add a faction: data entry + art; no code.

### 4.9 Game modes
- Battle royale is the only mode (DESIGN.md, Nov 9 2026; King of the Hill was removed in M1 step S1b).
- Data: `modes.json` maps a mode id to `rules` (behavior id) and an optional `data` path. `br` points at
  `data/br.json` (zone phases, downed/revive, tie rule, teams, default seed; placeholders, OQ-BR-*).
- Code: `GameModeRules` base (`setup`, `tick(delta, facts) -> events`, `is_over`, `result`). `ModeRegistry`
  maps `rules` id → script. `ModeRegistry.create` loads a `data` file through `DataRegistry` (null if the file
  is missing or not an object) and passes `setup` a deep copy of the entry with the file's keys merged in (the
  file wins; the registry cache is never mutated).
- `BrRules` (`scripts/systems/br_rules.gd`, pure RefCounted): `tick(delta, facts)` takes
  `facts.positions {player_id: Vector2(x, z)}` and `facts.reviving {reviver_id: target_id}` and returns events
  (`zone_phase`, `zone_damage`, `downed`, `revive_progress`, `revived`, `bled_out`, `dead`, `squad_eliminated`,
  `match_over`); their keys and order are documented at the top of the file. Health comes in through
  `report_zero_health(player_id, killer_id, cause)`.
- Add a new mode: one rules script + registry line + data entry.

### 4.10 Match flow
- `MatchDirector` (Node, authority only) owns `BrRules`. `load_config` keeps the merged `br` config in
  `mode_cfg` (tests may edit it before `start`); `start` seeds the rules, sets the team mode and registers every
  pawn. The roster fills to `match.json` `max_players` (18) on both the lobby and the standalone path: solo
  = 18 squads of 1, squads = 6 squads of 3. In solo each pawn's squad id is its player id.
- Match length (M2 Z2, OQ-BR-LENGTH): `data/br.json` `match_length` lists the options (`id`, `minutes`) and
  the default; adding an option is a data change only. `MatchDirector.load_config(map_json, length_id)`
  applies one after the map's overrides are merged (`apply_match_length`, one marked block): every zone
  phase's `wait_s` and `shrink_s` is multiplied by `minutes x 60 / the sum of all waits and shrinks`, so the
  last circle finishes closing at `minutes`. Radii, damage, the phase order, the drop and loot are not
  scaled; the scaled times stay floats. An empty id changes nothing (tests and sims that pass nothing keep the
  file's phases untouched). An unknown id, or a factor below 1.0 (shorter than the map's own schedule, which
  would break the zone generator's edge-speed cap and the drop rule), is rejected with one warning and the
  map's own schedule is used. The host picks the length in the lobby ("Length: 15 min", saved in the profile
  key `match_length`); it travels in `LobbyState.match_length`, and `MatchRoot.begin` passes the lobby's
  value to `load_config` on every peer. A `begin()` without a lobby passes "". Map files are not edited and
  nothing is re-baked. Nothing else needed a change: the HUD timer, the zone sounds, the zone wall and the
  bots' rotation rule read the rules' state and seconds left.
- Each physics tick it sends positions and revive pairs to `BrRules` and acts on the events: zone damage
  through `PawnRulesBridge.take_direct_damage`, pawn life state ALIVE / DOWNED / DEAD, deactivation on
  `dead`, and the signals `zone_changed`, `alive_changed`, `player_downed`, `player_revived`,
  `player_eliminated`, `match_over`. A hit that takes a pawn to zero health, or lands on a DOWNED pawn, is
  reported once from `Pawn._notify_damage` as cause `hit` with the attacker's player id.
- No respawn and no spawn protection. Until the drop from the sky (S3), squads start at the map's spawn
  spots round-robin, offset on a ring when several squads share a spot.
- Revive: the touch Interact button (a non-frame action through the input layer) asks the director to hold a
  revive pair on the nearest DOWNED squad mate in range; release, menu, hidden HUD or leaving range ends it.
- `MatchRoot` adds `local_player_id`, `local_squad_id` and `squad_count` to the result before the end screen.
- Spectate and killcam (later, S2 / M4) are client-side cameras only.
- Join in progress (OQ-BR-JOIN), quitter→bot replacement and the host-drop 60 s pause are
  MatchDirector/NetSession states, added later without changing the rules scripts. LAN battle royale is M3.

### 4.11 Bots and commands
- Data: `bots.json`. Profiles `tiro`, `miles`, `centurion`, `legatus` + custom slider fields
  (accuracy, health, spawns, AI smartness, damage, grenade frequency, reaction time); `match_fill`.
  The rule "bots can't use tiers above their player" is a lookup when building bot loadouts.
- Code: `BotBrain` turns perception into an `InputFrame` and drives the same `Pawn` as a human. So
  bots get movement, weapons and rules for free, and work identically on host and dedicated server.
  Target selection and aim error are pure helpers (`bot_targeting.gd`).
- Think rate (M2 P1c): a bot far from every alive human decides only every 4th tick; see 4.20.
- Difficulty (M2 B4, OQ-BOT-DIFFICULTY; numbers in `bots.json` `difficulty`, placeholders):
  - Data: levels `easy`, `normal`, `hard`, `very_hard` (cycle `order`, `default` normal), each
    with an English `label`, the DESIGN Roman name as a `note` only, and four values: `accuracy`,
    `reaction_time_s`, `settle_s`, `settle_floor_frac`. Normal equals profile `tiro` plus
    `brain.fight`'s settle values exactly (a test asserts it). `profiles`, `match_fill` and
    `brain` are unchanged; `damage_mult`, `health_mult`, `aim_smartness` and `grenade_freq` are
    still not applied.
  - Code: the table helpers and `apply_bot_difficulty(bots, id)` are statics on `MatchRoot`. Apply
    gives each bot brain a deep copy of its `profile` with the level's accuracy and reaction time
    and a deep copy of its `cfg` with the level's `fight.settle_s` / `settle_floor_frac`; shared
    data is never written. `BotBrain` and `BotSpawner` are unchanged.
  - Flow: the host cycles the lobby button "Bots: Normal" (`lobby.gd`, next to Length; interim
    until the host's Advanced options panel exists) -> saved in the profile as `bot_difficulty`
    (`SaveService`, validated: anything unknown is normal) -> `LobbyState.bot_difficulty`, one
    more key of the lobby dictionary (no new RPC; a missing or bad value reads as normal; refused
    after start) -> `MatchRoot.begin` applies it in the lobby branch right after the roster is
    built. Only the host runs brains; clients just show the level in the status line.
  - Without a lobby (tests, sims, the offline branch) nothing is applied and bots play
    `match_fill.profile` (tiro) as before. Sims opt in with `--sim-difficulty=<level>`
    (`sim_metrics.gd` bind, same apply function; the SIM line then prints `profile=<level>`).
  - The settle values only act on big maps (4.11 big maps, `route.big_map_radius_m`): on
    alesia_section a level changes accuracy and reaction time only.
- Big maps (M2 B1; numbers in `bots.json` `brain.route` and `brain.fight`, OQ-BOT-ROUTE / -FIGHT):
  - Switch: at seeding the zone's start radius is above `route.big_map_radius_m` (250). Only then
    do the rules below run; on a small map every goal and result is the pre-B1 one apart from the
    stuck-window fix below (the small-map sim's deterministic lines match the post-fix reference).
  - Goal order (first that applies): chase (blade only) > revive > gun_first (unarmed) > zone
    pressure > fight > loot > gear > hunt > spot / hold. Small maps: chase > revive > gun_first >
    zone > loot > spot / hold, as before.
  - Landmark and glide: at the jump a bot picks, seeded, one of the `landmark_pick_k` nearest
    landmarks holding loot (`MatchDirector.loot_landmarks()`, a read-only deep copy taken once)
    and glides toward its anchor. The gear goal walks there until geared (armour tier >=
    `geared_armor_tier_min` and gun reserve >= magazine x ammo_low_magazines); every
    `gear_recheck_ticks` it re-checks for wanted loot inside the circle, else re-picks.
  - Rotation: while the zone waits a bot leaves for its zone spot when
    distance / class move speed x `rotate_detour` + `rotate_margin_s` > seconds left.
  - Hearing and hunt: each brain connects to the other pawns' `shot` signals; an enemy gun shot
    within `hearing_radius_m` (or an enemy in sight) sets a memory point. With nothing in sight a
    geared bot walks to a memory younger than `hunt_memory_s`, else toward the next circle's
    centre, until within `hunt_arrive_m`.
  - Hunt pace (M2 B2; each key's off value gives the B1 hunt exactly; no random draws):
    `hunt_edge_frac` > 0 replaces the centre by a rim patrol (centre + unit(angle) x next radius
    x frac; the angle starts at the bot's `_spot_dir` and steps `hunt_patrol_step_deg` on each
    arrival, + for even player ids, - for odd), which never falls through to hold.
    `hunt_delay_s`: for that long after the first grounded think and after the last think with
    an enemy in sight the memory is not used and the goal kind is "regroup" (same rim point).
    `hunt_speed_scale` (clamped 0.3-1): `frame.move` is scaled while the goal is hunt or regroup,
    in `build_frame` and on coast ticks; the unstick sidestep keeps full speed.
  - Sight and band: sight is `fight.sight_by_weapon[gun]` clamped to the gun's `range_m`
    (otherwise `sight_range_m`). A gun bot with a standing enemy in sight closes in while farther
    than `band_far_frac` x sight (the goal moves only when the enemy is `repath_m` from it). At
    or inside `band_near_frac` x sight it strafes in place: a point `strafe_step_m` to the side,
    fixed for a seeded period, then flips. Between the two edges (M2 B2) the strafe point also
    carries `strafe_step_m` x `band_push_frac` toward the enemy. In both strafe zones the stuck
    window is off (as in hold). Downed targets keep today's goals.
  - Aim settle (M2 B2): `_settle_s` counts the time on the same `target_id` (reset on any change
    or loss; advanced identically on coast ticks). At each aim-error draw the limit is multiplied
    by `BotTargeting.settle_scale`: lerp(1, floor_eff, t x reach), t = settle time / `settle_s`,
    floor_eff = lerp(`settle_floor_frac`, 1, target flat speed / `settle_speed_ref_mps`), reach =
    distance / `settle_range_ref_m` (all clamped to 0-1; speed and distance sampled at the last
    think). Exactly 1.0 on a small map. Same two draws per refresh, so the aim stream's order
    is unchanged.
  - Route RNG: every new seeded draw uses `_route_rng` (hash of match seed, player id, "route"),
    never the aim stream `_rng`, so aim is unchanged by route decisions.
  - Path queries: on a big map a goal that did not change is not handed to the NavigationAgent3D
    again (setting `target_position` re-queries the path); the agent still re-paths by itself when
    the pawn strays. This halved the CPU proxy on the 1 km map. Small maps set it every think.
  - Stuck window fix (all maps): a window measures from where it started (`_stuck_from` is set
    when `_stuck_t` starts), not from the world origin; hold and arrival open a fresh window.
  - Zone edge (M2 B3, big maps only, placeholders OQ-BOT-FLIP): `_zone_calls()` holds the zone's
    terms without the inside test (shrinking or final, late, or outside the current circle);
    `_zone_pressure()` = not `_inside_target()` and `_zone_calls()`. `_inside_target()` has
    hysteresis: inside once within `route.inside_enter_frac` (0.80) x the next circle's radius,
    outside again only beyond `route.inside_leave_frac` (0.85). The state resets when the next
    circle changes and on every think skipped for a dead, falling or dropping pawn; after a reset
    it is judged at the enter edge. While `_zone_calls()` is true, a bot inside takes a loot, gear
    or hunt goal only when its target lies inside the leave edge (`_inside_leave`); otherwise the
    next goal in the order is tried. Exempt: the unarmed bot's gun_first loot and the jump
    landmark pick. Small maps and missing keys keep the single 0.85 edge and no filter. No draws.
    On demand: `tests/sim/test_zz_goal_off_nav.gd -- --offnav-from=<dir>` lists `SIM_UNSTICK_AT`
    goals farther than 2 m (flat) from the saved 1 km navmesh.
- Sims (`tests/sim/`, metrics shared in `sim_metrics.gd`): kills and downs by gun / blade with
  distances, gun hit rate, zone deaths, loot taken (placed / dropped), goal shares, unstick
  events, landmark landings. Args after `--`: `--sim-profile=<name>` (every bot's profile),
  `--sim-brain=<path>=<n>,...` (sim-local `brain` overrides, shown in `profile=`), and
  `--sim-scale=<n>` (the 1 km sim's zone and carrier time scale, default 0.4), `--sim-seed=<n>`
  (the 1 km match seed, default 99 solo / 199 squads), `--sim-length=<id>` (M2 Z2: a `br.json`
  `match_length` option, applied before `--sim-scale`; prints one `SIM_LENGTH id= minutes= factor=
  last_close_s=` line and stretches the wall cap by the factor; absent = nothing changes). M2 B2 lines, separate from the `SIM` line:
  `SIM_BANDS` (gun rounds / hits / hit rate by the shooter's flat distance to its target at
  `fired`: 0-15, 15-40, 40-80, 80+ m, none) in both sims; `SIM_UNSTICK_GOALS` (unstick events by
  goal kind and whether the nav target was reachable) in the 1 km sim. On demand:
  `test_sim_bot_ttd.gd` (`SIM_TTD`: seconds for one bot to down a standing target at set
  distances, per gun and profile, 10 seeded trials). CPU proxy, printed
  after " | " and never compared: "us per think tick (incl. coast)" = sum of `BotBrain.brain_usec`
  over bots / sum of `think_ticks`.
- Commands (later): a `BotCommand` id (follow, attack, hold, rush_hill; page 2: guard, rush,
  attack_marked) switches the brain's goal state. Command pages/buttons are data in `input.json`.
  Prone and seeking good spots are brain behaviors.

### 4.12 Aim assist
- Data: `stats.json` `aim_assist`. Per input profile (controller strongest, touch lighter, gyro none):
  friction, follow, magnetism (per weapon override), angle zones that shrink with zoom, and distance
  falloff. ADS snap is off. All values low; milestone 1 ships them at 0 (OQ-19).
- Code: `AimAssist` (pure) takes the look input, active provider type, targets in view and weapon
  zoom, and returns the adjusted look delta. The pawn applies it; providers report their type, so
  "none on gyro" is a data lookup.

### 4.13 Input abstraction and providers
- InputMap actions are the vocabulary: move, look, fire, aim, reload, swap_weapon, jump, pause, crouch
  (M2 H1c: the free crouch toggle, keyboard C / gamepad B, and the touch Crouch button); prone and interact are
  reserved (action plus InputFrame bit, no behaviour or bindings yet); later melee, grenade, deployable, streak and
  command pages.
- One-shot presses (D1): a provider's `trigger_action(action)` emits `action_triggered`; the router
  re-emits it at once and latches one pressed+just_pressed frame edge (even for a sub-tick tap).
  MatchRoot forwards it to the local pawn (`handle_action_press`). M2 H1c: "crouch" toggles the free crouch
  (`Pawn.press_free_crouch`); keyboard / gamepad reach the same signal through `KeyboardMouseProvider.PRESS_ACTIONS`
  (one emit per InputMap press, no echo). The frame bit is transport only until the host-side cover slice, so the
  pawn never toggles from it.
- Held press-time actions (D2): the in-cover FIRE control uses the action `cover_fire`, listed in
  `InputRouter.NON_FRAME_ACTIONS` and not in `InputFrame.BUTTONS`/`LOCAL_BUTTONS` (no bit, no latch,
  never sent). The provider's `trigger_action` / `release_action(action, cancel)` /
  `set_action_look(action, active)` emit `action_triggered` / `action_released` / `action_look_changed`;
  the router re-emits each at once, unfiltered, and MatchRoot forwards them to the local pawn
  (`handle_action_press` / `handle_action_release` / `handle_action_look`), which calls
  `cover.quick_draw(true)`, `cover.quick_draw(false, cancel)` and `cover.set_look_active(active)`. Only
  the press is gated (menu in MatchRoot, death in Pawn, suspend in the UI); release and look go
  through ungated so an interruption always lands. No file in scripts/ui calls a CoverController
  mutator (tests/test_crouch_guard_d1.gd, no exceptions).
- `InputRouter` merges the active providers into one `InputFrame` per physics tick. Providers:
  `KeyboardMouseProvider`, `GamepadProvider`, `TouchProvider`, `GyroProvider`. Each is swappable and
  can be enabled or disabled from settings.
- Gameplay reads only `InputFrame`/actions; it never reads raw touch events. The touch HUD is the only
  consumer of screen-touch events, and it turns them into TouchProvider values and action presses.
- `InputFrame` is serializable. The network sends it to the host, and bots produce it, so one pawn
  script serves all three.
- Remapping (later) edits InputMap events and saves them to the profile. Gyro settings (toggle,
  sensitivity, ADS-only, recenter, Off/ADS/Always) live in `input.json` defaults + the profile.

#### W0: PC keyboard and mouse (web milestone, Nov 22 2026)
Key map (project.godot [input]; every key is a physical keycode, so it sits in the same place on any layout; the
key map itself is a guess for Shibi, OQ-WEB-KEYS):

| Action | Keys / buttons | Path |
|---|---|---|
| move_forward / move_left / move_back / move_right | W / A / S / D | polled (`Input.get_vector`) |
| look | mouse motion while captured (arrows still bound to look_*) | `KeyboardMouseProvider.get_look`, Camera / ADS tables |
| fire | left mouse button | polled bit |
| aim | right mouse button | polled bit (Aim tap toggle as before) |
| sprint (new action) | Shift (hold) | `KeyboardMouseProvider.is_sprinting()` -> `InputFrame.sprint`; no new BUTTONS bit |
| jump | Space | polled bit |
| crouch | C, Ctrl | press path (`PRESS_ACTIONS`, router latch) |
| prone | Z | polled bit only: bound, no behaviour (pawn.gd is read-only in W0) |
| interact | E (press and release) | press path + `action_released` (revive hold ends on release) |
| cover | F | press path (`NON_FRAME_ACTIONS`) |
| swap_shoulder | V | polled LOCAL_BUTTONS bit (view only) |
| reload | R | polled bit |
| swap_weapon | Q, 1, 2, mouse wheel up / down | keys polled; the wheel through the router latch (`MOUSE_LATCH_ACTIONS`); each is a toggle, no slot select |
| pause | Esc | MouseCapture / PauseMenu (below) |

- Shift and Ctrl bindings leave the key location unspecified (Left Shift / Left Ctrl are the intended keys; the right
  ones also match), so a browser that reports no key location never loses sprint or crouch.
- Sprint in cover: the pawn exits cover on the rising edge of `InputFrame.sprint` (pawn.gd, the touch Sprint lock's
  path), so a Shift press in cover leaves cover and sprints, exactly as the lock does. A Shift already held when cover
  starts has no edge and does not exit (as a lock already on at entry). No tunable (OQ-WEB-SPRINT-COVER).
- Mouse look: `KeyboardMouseProvider.mouse_sensitivity` comes from data/input.json `sensitivity.mouse_look`
  (placeholder, OQ-36; replaced the hard-coded 0.002 rad per pixel), then the router's Camera / ADS percent tables
  scale it like every "camera" provider. The in-match Settings -> Sensitivity screen's Camera and ADS tables are
  therefore the mouse sensitivity setting; there is no separate mouse row.
- Conflicts: no physical key, mouse button, pad button or pad axis direction is in two gameplay actions
  (tests/test_w0_input.gd); the engine's ui_* actions are excluded (ui_cancel = Esc, ui_accept = Space, ui_ arrows).
- Browser hazard (not fixable in the page): Ctrl is also the browser's shortcut key; Ctrl+W / Ctrl+T / Ctrl+N
  cannot be blocked by a page, so crouching on Ctrl while pressing W can close the tab. C is the safe crouch key.

Mouse capture state machine (`MouseCapture`, scripts/input/mouse_capture.gd; owned and driven by `PauseMenu`, which
runs with PROCESS_MODE_ALWAYS; active only while `PlatformServices.is_touch_device()` is false):

| State | Event | Next | Effect |
|---|---|---|---|
| FREE | left click in the match (not the gear) | CAPTURED once the mode reads captured | `set_mode(CAPTURED)`; a refused request stays FREE and the next click asks again |
| CAPTURED | Esc (desktop: the key arrives) | MENU | release, open the menu |
| CAPTURED | capture lost (mode no longer captured, no key event: the browser ate Esc, or the tab lost focus) | MENU | open the menu (polled once per frame) |
| any | menu opened (gear included) | MENU | release |
| MENU | Esc (no Sensitivity / Layout / Haptics screen open) or Resume | FREE | close; never recaptures by itself |
| FREE | the next click | CAPTURED | recapture (Chrome refuses an immediate re-lock after Esc) |
| any | PauseMenu leaves the tree (quit, end screen) | FREE | release |

- Seam (binding fix 13): every mouse mode read and write goes through `MouseCapture.get_mode` / `set_mode`
  (defaults: `Input.mouse_mode`), and MatchRoot points `KeyboardMouseProvider.get_mouse_mode` at it, so the captured
  check for mouse look and the state machine read one mode. Headless ignores mouse mode changes; tests fake the seam.
- Pausing stays MatchRoot's: offline and solo the open menu pauses the tree, online it only zeroes the frame.
- Touch devices: unchanged. Android Back, ui_cancel and Esc never open the menu; the gear is the only way in.
- The first click that captures also fires (the fire action is polled from Input), a known W0 behaviour.

### 4.14 Platform layer
- `PlatformServices` (`scripts/platform/platform_services.gd`) picks an implementation with an
  `OS.get_name()` switch: Android, desktop (Windows/Linux/macOS), iOS, Web, and a null fallback.
  API:
  - `is_touch_device()`
  - `has_gyro()` / `get_gyro_rate()`
  - `vibrate(ms)`
  - `request_permissions()`
  - `get_log_path()`
  - `share_file(path)` (later "Send logs")
  - `get_local_addresses()`
  Every method has a safe no-op default.

#### W0: Web build (web milestone, Nov 22 2026)
- `export_presets.cfg` gains a "Web" preset (appended; Android and iOS byte-identical): single-threaded
  (`variant/thread_support=false`, so no COOP/COEP headers), desktop texture compression, `tests/*, tools/*`
  excluded (`build/` is never packed: it has a `.gdignore`), adaptive canvas resize, export path
  `build/web/index.html`. `project.godot` sets `rendering_method.web="gl_compatibility"` explicitly (WebGL2); desktop
  and Android keep `mobile`. Desktop and web share one code path; the only web branches are `PlatformServices.is_web()`
  (Host / Join off) and `WebArgs` below.
- `WebArgs` (scripts/platform/web_args.gd): debug-only URL arguments for automation, read through `JavaScriptBridge`
  only when `OS.is_debug_build()` and the `web` feature tag hold. `?autosolo=1&length=<id>&wait=<s>`: the main menu
  presses Play solo (`apply_autosolo`, request in `WebArgs.pending`), the solo lobby applies the length (not saved)
  and presses Start after `wait` seconds via a child Timer (Back cancels it). Parsing is the pure
  `WebArgs.parse(query, debug, web)`; tests/test_w0_web.gd covers it. `WebArgs.debug_marker` prints the debug web
  markers `GLADIUS_MENU_READY` / `GLADIUS_LOBBY_READY` / `GLADIUS_PAUSE_OPENED` / `GLADIUS_PAUSE_CLOSED`;
  `GLADIUS_MATCH_STARTED` is a plain print in `MatchRoot.begin` once the local player exists.
- `tools/web/serve.mjs` (static server, Node built-ins) and `tools/web/smoke.mjs` (headed Chrome through
  puppeteer-core from outside the repo) are the browser smoke test; docs/WEB.md has the commands and caveats.

### 4.15 HUD and touch HUD
- `hud.tscn`: presentation only. Binds to signals from MatchDirector (or its replicated mirror on
  clients) and the local pawn. Classic Halo layout, red/gold theme (`theme.tres`), Roman numerals via
  `roman_numerals.gd` (off by default, OQ-38). The radar (25 m, crouch hide: `Pawn.crouch_amount()`, the cover or the free crouch, M2 H1c) is built (M2 H1b, below). Later: prone hide, jammer blanking, smoke animation,
  streak/deployable slots, killfeed, Latin medal popups, bad-trait banner.
- `touch_hud.tscn`: a separate CanvasLayer above the HUD. Floating move stick bottom left; a look
  area (right half, no control in it by default) where a touch only turns the view; action buttons hung off
  data-defined anchors at the bottom right and bottom centre (M2 H1a, below). Hidden when
  `PlatformServices.is_touch_device()` is false, unless forced on by a setting.
- Layouts use anchors and containers only, and scale with DPI/aspect (S24/S25 Ultra, Fold7
  outer/inner).
- The front-end (boot, main menu, lobby, settings pages, pause overlay, end screen) has its own look
  (M2 U1): theme `menu_theme.tres`, the kit in `scripts/ui/menu/` (`MenuStyle`, `MenuIcon`,
  `MenuBackdrop`, `MenuLogo`), numbers in `data/ui.json` `menu_style` / `menu_type_scale`. `UiScale`
  sizes touch targets and applies the kit's sizes on every resize. Rules: `docs/UI_STYLE.md`. Proof
  shots: `tools/menu_shots.tscn` (every screen at six phone sizes).

#### M2 H1a: shooting modes and touch layout
- Fire sources: the right Fire button, the optional Left Fire button, keys and gamepad (their providers), and in Simple
  mode the HUD auto-fire. A look-area touch never fires. Touch sources all go through the one "fire" action in
  `TouchHud._sync_fire_action`, so the shot takes the normal InputFrame / host path.
- Mode: profile key `shooting_mode` ("advanced" | "simple"; unknown or missing = `data/input.json` `shooting.default_mode`),
  Settings row "Shooting mode", applied live by `TouchHud.refresh_shooting_mode()`. Simple removes the right Fire button
  (not drawn, not hit-tested); Left Fire and the Aim button stay.
- Simple auto-fire is decided in `TouchHud._update_simple_fire`: `simple_fire_block_reason()` must be "" (mode, hidden,
  suspended, no pawn, spectating, drop, downed, LAN session, sight down) and the read-only `Pawn.simple_fire_target()`
  must name the same enemy for `shooting.simple.first_shot_delay_s`. It only decides when to press "fire"; it never
  changes the aim direction. Semi weapons get one press per round.
- Hold-to-ADS (`shooting.hold_to_ads`, off by default, Advanced only): a Fire button held for `hold_s` sets
  `TouchProvider.hold_ads`; `InputRouter` ORs it into `aim_pressed` after the Aim toggle resolve, so a release never
  lowers a toggled sight.
- Look area and anchors are data (`input.json` `touch_layout.look_area`, `button_anchor`, `bottom_centre_anchor`, per-button
  `offset` / `anchor` / `ring`); read the rects with `TouchHud.get_look_area_rect()` and `get_button_rect(key)`. The drawn
  look stick exists only in look mode "stick" (`look_stick_rest` is used only there).
- Layout version: `layout_editor.layout_version` (3; M2 H1c item 4 raised it from 2 when the Crouch button moved the
  Cover / Shoulder, Swap and fire-mode defaults) is stored as `hud_layouts.version`. On load `SaveService` resets an
  older or unversioned layout and the legacy `sprint_lock_pos` once, writes the profile back, and sets
  `layout_notice_pending` when something edited was discarded; the touch HUD shows a one-time notice and clears it.
  The layout editor only warns when a control sits in the look area.
- Tools: `tools/layout_probe.gd` (headless; prints every control rect per size and dpi and any overlap, off-screen or
  under-48-dp problem) and `tools/h1a_capture.tscn` (windowed; advanced, simple, cover, editor and look-area shots plus a
  contact sheet per size: 2176x1812, 2520x1080, 3120x1440).

#### M2 H1b: in-match HUD, prompts, minimap, radar, coach
New scripts (all in `scripts/ui/`, each with a `.uid`), numbers in `data/ui.json` (`hud_arrangement`, `interact_prompt`,
`minimap`, `radar`, `pause_gear`) and `data/coach.json`, every one a placeholder (OQ-HUD, OQ-MINIMAP, OQ-RADAR, OQ-COACH):
- `hud_arrangement.gd` (`HudArrangement`): the single source of rects. Static getters for the weapon block, chip,
  objective strip, kill banner, radar disc, minimap square, panel, minimap tap target and gear top, from the view size,
  one HUD unit (`unit_frac_of_height` of the height, floor `unit_min_dp`) and the touch layout's button side. Placement is
  `above_row` (data default; no button moves, `layout_version` stays 2) or `split_row` (only at aspect 2.0 or wider, else
  above_row; M2 H1c: Swap and Cover / Shoulder both left of the block, the fire-mode button left of Swap; it hooks
  Swap, Cover / Shoulder and Interact in `touch_hud.gd`, `fire_mode_button.gd`, `interact_button.gd`
  `get_touch_rect`; a saved slot position still wins). `placement_override` is a seam for tests and tools. Match, tests,
  layout editor and tools all read the same getters.
- `hud_style.gd` (`HudStyle`): menu-style plates (surface fill, gold hairline, cut corners) and HUD labels that ignore
  touches and keep a fixed rect. `hud_weapon_block.gd` (`HudWeaponBlock`) and `hud_chip.gd` (`HudChip`): the passive
  weapon block (slots, ammo, name, shield and health bars, own drawn icons) and the top-left alive / zone chip. `hud.gd`
  (`GameHud`) owns them, keeps the old public vars (`shield_bar`, `health_bar`, `ammo_label`, `weapon_label`,
  `alive_label`, `zone_label`, `downed_label`), places them in `_arrange()` on every resize, and picks the objective key in
  the static `objective_key_for()` (read-only from the pawn and `rules`; wording from data).
- Touch target vs passive display. Only touch targets obey the look-area and 48 dp rules: `tests/test_h1a_layout.gd`
  `_controls()` lists them (`minimap_tap`, `minimap_close` while expanded, `coach_skip`, the gear) and runs both placements.
  Passive displays are `mouse_filter` IGNORE, may overlay either half, and are checked by `tests/test_h1b_hud.gd`: on
  screen, apart, clear of every `_controls()` rect and the stick's rest visual, every node IGNORE, and a look drag and a
  stick start both work through each. The prompt is the named exception: it may sit in the look area.
- `interact_prompt.gd` (`InteractPrompt`): one prompt at the Interact button's target. It reads the target the same way
  (`revive_target_for`, `pickup_target_for`, `chest_target_for`, `door_target_for`, in that order) and shows only while the
  button is visible, so a LAN client has none. It never consumes a touch (its `_input` only watches the finger); a tap or
  the revive hold calls `touch_hud.provider.trigger_action("interact")` / `release_action`, the button's own calls, and it
  releases on hide. Its one `set_input_as_handled` swallows a press on the Interact button while the prompt holds interact.
  Screen point: `Camera3D.unproject_position`, converted from viewport pixels to canvas units with the viewport's final
  transform (`to_canvas`; the two differ under `canvas_items` stretch). `MatchDirector.player(id)` already gave the revive
  position, so no getter was added to the director.
- `minimap_math.gd` (`MinimapMath`): the one world-to-minimap mapping (`frame_for`, `to_px`, `to_world`, `world_to_px`).
  `hud_minimap.gd` (`HudMinimap`): the display and its input; every drawing and every test goes through `MinimapMath`.
  `HudRadar.to_px(offset_m, yaw, range, radius_px, centre)` in `hud_radar.gd` (`HudRadar`) is the radar's one mapping (the
  same rotation as the minimap's rotating frame) and `HudRadar.classify_with` is its one show / hide rule (see CONTROLS.md).
- Overlays run at a data rate with per-frame transforms: marks lists, circles, mates, landmark names and radar blips are
  rebuilt `update_hz` (10) times a second; the view (the map's pan and turn, the arrow, the radar's blip layer turning
  with the heading) follows every frame as node transforms, with no redraw. The minimap and radar sit after the touch HUD
  at `z_index` -1, so buttons and displays draw above them. Only the minimap's `_input` consumes a press, and only inside
  its tap rect (`set_input_as_handled`, like the gear); the radar has no `_input`.
- Baked minimap textures: `tools/render_layout.gd --minimap[=ids] [--minimap_dir=...]` bakes a top-down picture per map from
  the map data (ground paint, hill shading, 5 m contours, collider footprints by class, the map scene's box colliders), no
  text. Output is `assets/generated/ui/minimap_<map>.png` (1024 px for alesia_1km, 512 px for test_300 and alesia_section),
  hashed through `tools/asset_hashes.gd` (its `TOOLS` has a `ui` entry). The texture and the world extent
  `[x, z, width, depth]` per map are data: `ui.json` `minimap.maps`. `tests/test_h1b_minimap.gd` checks each extent and
  size against the tool's `minimap_extent` / `minimap_px`, so they cannot drift. A map with no entry or texture shows a
  plain panel with the circles and arrows. Landmark names are drawn at runtime from the map's landmarks json.
- Profile keys (`SaveService`, in `defaults()`, `load_profile()` and `save_profile()`): `minimap_rotate` (default true;
  Settings row "Minimap") and `coach_done` (default false; only a bool `true` counts; Settings row "Replay the coach").
- Coach: `hud_coach.gd` (`HudCoach`, steps and text in `data/coach.json`). Gate: `HudCoach.wanted(route_flag, profile)` is
  `coach.enabled` and `AppFlow.coach_route` and not `coach_done`. `AppFlow.coach_route` is a static bool set only by
  `lobby.gd _on_match_starting` (a test scans `scripts/` and `tools/` for any other writer), taken and cleared once per
  match by `GameHud.bind` (`take_coach_route()`), and cleared by `end_session()`. So `auto_start`, `use_map_select`, tests,
  sims and capture tools never show it. It reads state and signals only, never consumes input, never touches the tree's
  pause or `Engine.time_scale`; its `_input` takes only a press on Skip. It needs the touch HUD shown (`require_touch_hud`).
  The layout editor draws the fixed pieces with `LayoutEditor.fixed_elements(view)` (same rects as the match).
- Order in `GameHud.bind`: the prompt after the Interact button, then the minimap after the touch HUD, the radar after the
  minimap, the coach after the radar (all by deferred `add_sibling`, so the tree order is fixed and the coach's `_input`
  runs before the touch HUD's).
- Tools: `tools/h1b_capture.tscn` (`h1b_capture.gd`; windowed; `--out=<dir> [--kinds=a,b] [--sizes=WxH,...]`; every piece,
  both placements, each prompt kind, the minimap small and expanded, the radar with blips, the coach steps and the editor,
  at 2176x1812, 2520x1080 and 3120x1440 with contact sheets); `tools/minimap_cost.gd` (`--frames=N --rounds=N [--radar]`;
  render CPU and GPU, draw calls and the overlay's script time, states alternating in blocks, on the desktop proxy);
  `tools/layout_probe.gd` now loops over both placements and prints the passive rects, with the passive-display and
  `minimap_tap` / `coach_skip` checks.
- New files (each with its `.uid`): `scripts/ui/hud_arrangement.gd`, `hud_style.gd`, `hud_weapon_block.gd`, `hud_chip.gd`,
  `interact_prompt.gd`, `minimap_math.gd`, `hud_minimap.gd`, `hud_radar.gd`, `hud_coach.gd`; `data/coach.json`;
  `tests/test_h1b_hud.gd`, `test_h1b_prompt.gd`, `test_h1b_minimap.gd`, `test_h1b_radar.gd`, `test_h1b_coach.gd`;
  `tools/h1b_capture.gd` (+ `.tscn`), `tools/minimap_cost.gd`; `assets/generated/ui/minimap_alesia_1km.png`,
  `minimap_test_300.png`, `minimap_alesia_section.png`.
- LAN: no protocol change. What a client lacks for the minimap and radar (zone progress, match seed, cover state, downed,
  drop state) is listed under OQ-MINIMAP and OQ-RADAR for M3.

#### M2 H1c: the free crouch (item 4, OQ-CROUCH)
- State on `Pawn` (plain, for M3 to replicate; no protocol change): `free_crouch` (the toggle) and
  `free_crouch_amount` (0..1, eased over `stats.json movement.crouch.blend_s`). Read-only: `crouch_amount()` (the
  larger of `cover.crouch_amount` and `free_crouch_amount`; the radar, CameraRig and presentation read it),
  `crouch_button_available()` (switch on, LOCAL, no Brain, not `in_lan_session()`), `free_crouch_possible()` (also
  ALIVE, drop NONE, not climbing, not in cover), `crouch_height_scale()`, `free_crouch_height_scale()`.
- The only toggle is `press_free_crouch()` from `handle_action_press("crouch")`; `_tick_free_crouch` (every LOCAL
  physics tick, before the carrier return) clears it wherever a press would not act (carrier, falling, ladder; in
  cover it eases out under the cover crouch) and eases the amount; downed / dead (the life setter) and `respawn_at`
  clear it at once. Standing up (a press, a sprint, a jump) needs `CoverProbe.standing_clear`; a jump press while
  crouched only stands; no sprint while crouched; a crouch press while sprinting is ignored.
- Shapes: `_apply_body_shapes` is the one writer (downed, then `crouch_amount()` with `cover.json crouch_height_m` /
  `crouch_head_y_m`, else standing). The first-person eye (`CameraRig._crouch_eye_scale`, a marked block) and the
  muzzle (`get_muzzle_position`, the free crouch only, never in cover) scale by the head's ratio, so eye, head and
  muzzle move together. Speed: `movement.crouch.speed_multiplier`; spread: `get_spread_mult` times
  `movement.crouch.spread_multiplier` (1.0, no effect).
- HUD: `input.json touch_layout.buttons.crouch` (a ring button on the bottom edge directly left of Jump, `button_anchor`
  [-3.9, -0.6]); to make room the Cover / Shoulder slot moved [0.65, -0.6] -> [-0.45, -0.6], Swap [-0.65, -0.6] ->
  [-1.7, -0.6] (`bottom_centre_anchor`), `ui.json fire_mode_button` [-1.75, -0.6] -> [-2.8, -0.6] (left of Swap; `FireModeButton.touch_rect`
  moves it left of the move stick's default rect, or to `crowded_offset_buttons` [-1.7, -1.8] above Swap, where the
  row slot meets the stick), `HudArrangement.split_center` in the same order, and `layout_version` 2 -> 3 (saved layouts reset once);
  `TouchHud.crouch_button_shown` (the one rule; hidden buttons catch nothing), looks normal / held / dimmed
  (`ui.json cover_fire_dim`); the layout editor shows it (`show_crouch_for_editing`). Radar: `HudRadar.classify_with`
  hides an enemy whose `crouch_amount()` >= `radar.cover_crouch_min`. Tests: `tests/test_h1c_crouch.gd`.

### 4.16 Camera and FOV per aspect ratio
- `CameraRig` (SpringArm3D + Camera3D, third person). FOV and offset come from `camera.json`: a table
  of aspect-ratio breakpoints. Tall phones use the base FOV; near-square screens (Z Fold7 inner) use a
  wider entry, as DESIGN.md requires. The rig re-applies on viewport `size_changed`, so folding or
  unfolding mid-match works. Scope zoom multiplies on top.
- Two modes (M2 C1a, OQ-FIRST-PERSON; `camera.json` `first_person`). The rig decides every physics frame
  (`is_first_person`): first person when its parent is the local player's pawn (a Pawn with no `Brain`
  child), ALIVE, on the ground and with cover FREE or absent; today's third person everywhere else (cover,
  including ENTERING and EXITING, the carrier, falling, downed, a rig without a pawn). A smoothstep weight
  (`get_first_person_weight`, 0 third to 1 first, over `blend_s`) blends the spring length to 0, the side
  offset to 0, the rig height to `eye_height_m` and the FOV; the first evaluation snaps. Same rig, same
  contracts: `AimRayCast`, `get_aim_point`, `set_pitch`, `set_aim_blend`, the view-only knockback. The shoulder
  swap is ignored in first person.
- View model (`scripts/visual/view_model.gd` and the `view_*.gd` files, section 4.22): two skinned arms with
  fingers and the held weapon on the rig's Camera3D, attached lazily by the rig for the local pawn only, shown
  from `view_model.show_weight` and already risen by `raise_start`, so leaving cover never shows a frame with
  neither body nor gun. It plays breathing, the walk bob, the sprint pose, switch, pickup, staged reloads, kick,
  the landing dip and the blade swing from the pawn's state and signals (M2 AN1; shapes in `data/anim.json`
  `first_person`, durations `swap_s`, `swing_s`, `recoil_s` here). Since M2 AN2 a clip layer sits under the
  procedural one: where `first_person.clips.enabled` is on (reload, switch, pickup, blade swing, the ADS
  path), `ViewMotion` samples the Blender-keyed clip of `view_clips_<weapon>.glb`, time-scaled to the same
  durations, and that motion's procedural curve steps aside (fade `clips.fade_s`); idle, walk, sprint and fire
  stay procedural, and the other procedural terms (look sway, kick, landing dip) stay on top. A missing or
  disabled clip falls back to the curve; aim, recoil numbers, muzzle and fire timing never read either layer.
  The view model draws its own tracer and flash from `ShotFx.shot_shown`, and raises the gun to a red dot on the centre ray in ADS; the long rifle's ADS looks
  through a modelled scope tube with a reticle (no overlay, no FOV change: OQ-ADS-ZOOM). Presentation only:
  no colliders, the shot never reads it.
- Body layer (`scripts/visual/local_body_layer.gd`): the rig calls `Pawn.ensure_local_body_layer` every physics
  frame; for the local pawn it moves Body, HeadMesh, every SoldierModel mesh (also ones added later, followed
  by `child_entered_tree`), the ShotFx tracer and flash and the SwingVisual bar from render layer 1 to
  `body_layer`. The rig camera leaves that layer out of its cull mask while the view model shows
  (`is_body_hidden`), so body and arms swap on one frame; every other camera (SpectatorCamera, other players)
  keeps the default mask. ShotFx impact, sparks and dust stay on layer 1. Render layers only: collision,
  hitboxes, the muzzle and the host aim check are unchanged. The body's shadow goes with it (measured).
- HUD rules: `hud.gd` hides the crosshair at `crosshair_hide_aim_blend` in first person with a gun; the touch
  HUD reads the mode from the sibling GameHud's pawn and its CameraRig and hides the Shoulder button in first
  person (`ui.json` `first_person_touch.shoulder_visible`), its slot reserved and swallowing taps
  (the slot still hit-tests and presses `swap_shoulder`, which the rig ignores in first person, so a tap there
  never reaches the look area or fires).
- Tests: `tests/test_first_person_camera.gd`; captures: `tools/fp_capture.gd`.
- Third-person soldier under the camera (M2 AN3, section 4.22): the camera code is unchanged; the soldier's helmet
  now stays on the pawn's head hitbox in every upright state and the body is brought under it (`SoldierNeck`,
  `SoldierGait`, data `anim_third_person.json` `head`), so the head the camera frames no longer bobbles against the
  torso. `--legacy-head` on `soldier_capture.gd`, `cover_capture.gd` and `drop_capture.gd` records the old look.

### 4.17 Networking (host authority)
- Transport: `ENetMultiplayerPeer` + Godot high-level multiplayer (RPCs, MultiplayerSpawner/
  Synchronizer). No Android-only APIs, so PC/iOS clients can join later. Config in `net.json`.
- Roles: the host is server + a local player (peer 1). Clients:
  - send `InputFrame`s (unreliable_ordered)
  - send fire requests with origin, direction, weapon id and client tick (reliable)
  - in milestone 1 they own their own movement; the host clamps implausible speed (T-03)
- The host runs all rules: validates fire rate/ammo/weapon, raycasts on its own world, applies
  DamageRules, scores, spawns, runs bots and computes payouts.
- Replication: transforms + health/shield per pawn, score/timer and match state. Discrete events
  (kill, respawn, streak, match over, payout) go as reliable RPCs. Clients never write rules state.
- World props (M2 L1b): one reliable event `NetMatchBridge.ev_world_prop(prop_id, state)` for breakables,
  chests and (M2 L1c) doors and gates: a door's state is the absolute OPEN or CLOSED, never a toggle; every door is
  stored from the start, so the wiring resend carries all of them (see 4.20, Props: doors and ladders). The bridge wires `director.props` (WorldProps) once it exists (MatchRoot.begin makes it after the
  bridge's setup: setup, the next physics tick or an incoming event); the host forwards every `prop_changed`, a
  client calls `apply_state` (look and collider; no loot roll: the spill reaches it as ground loot). Events that
  arrive before a client's WorldProps exist are kept and applied when it is wired; detach unwires.
- Lobby: `LobbyState` (pure, serializable) holds players, squads, classes and settings. The host owns
  it and broadcasts changes. `match_length` (M2 Z2) is one field of that payload: the host's match length
  id, sent with every sync and with the start, so every peer stretches its own zone clock alike. The zone
  state itself is still not replicated (M3).
- Discovery: manual IP in milestone 1 (OQ-41). A later UDP-broadcast discoverer plugs into
  NetSession, and needs a platform hook for an Android multicast lock if multicast is used.
- Dedicated server later: the same project runs `--headless` with a server boot scene. Its
  MatchDirector is authority with zero local players. Because rules are pure and presentation only
  listens, no rules code changes.

#### W0: Play solo without a network (web milestone, Nov 22 2026)
- The main menu's first button, **Play solo** (`MainMenu._on_solo`), sets the explicit flag `AppFlow.solo` and opens
  the same lobby screen. The flag is cleared by `AppFlow.end_session()` (every Back, quit, result-screen Menu and lost
  host goes through it) and by Host and Join.
- `Lobby._ready` sees the flag and calls `NetSession.start_offline()`: any network peer is dropped and the session's
  multiplayer gets an `OfflineMultiplayerPeer` (unique id 1, so the host entry is id 1 as on a real host). No
  `ENetMultiplayerPeer` is ever created (`host_game` / `join_game` are never called). `NetSession.solo` and
  `NetLobby.solo` are set with it.
- The lobby acts as host locally (`Lobby.is_host = session.is_host or solo`): team mode, match length, bot difficulty
  and Start all show and work, the header says "Solo, offline" instead of IPs, and the client branch (`submit_local`
  to the host) never runs. `NetLobby` with `solo` is host (`is_host()`), skips every broadcast RPC, and `start_match()`
  calls the shared `_enter_match` directly instead of `_start_match.rpc` (no protocol change: the RPC still calls the
  same body on LAN peers).
- `MatchRoot.begin`: `networked = local_peer != 0 and not solo_match`, where `solo_match` is `AppFlow.solo` or the
  session's `solo`. Solo therefore takes the lobby branch (roster, the lobby's team mode, length and bot difficulty)
  with `networked_match == false`, no `NetMatchBridge` wired and the director authoritative; the pause menu pauses the
  tree as offline always did. Only the flag changes the rule: a Host with no client is still a networked match
  (tests/test_h1c_cover_button.gd).
- **Why an explicit flag, not a peer trick:** the lobby always creates a session (`AppFlow.ensure_session`) and the
  tree's default `OfflineMultiplayerPeer` reports unique id 1, which is exactly what a real host reports. Sniffing the
  peer would therefore call solo networked (bridge wired, no tree pause), and a "no session" lobby would need a second
  lobby code path. One flag, set in one place and cleared in the two places that end it, keeps the LAN path unchanged.
- **Web:** `PlatformServices.is_web()` (`OS.has_feature("web")`, test hook `simulate_web`) and `can_lan()` decide
  whether Host and Join are enabled. In a browser (no ENet) they are disabled with the note "LAN in the browser comes
  later" instead of failing; the LAN relay is slice W2. Tests: tests/test_w0_solo.gd.

### 4.18 Graphics quality
- Renderer: Mobile (Vulkan) project-wide. Compatibility only as a per-platform override (e.g. web).
- `graphics_presets.json`: named presets (render scale, shadows, MSAA, fps cap 60/120, LOD). Applied
  at boot by a small `GraphicsSettings` helper; the profile stores the chosen preset.

### 4.19 Audio
- Status (M2A1, Nov 10 2026): sound effects and ambience play; music and the announcer are empty slots.
  `audio.json` maps event ids (announcer lines, music states) to streams. Shibi's Latin announcer
  lines fill placeholder slots by id.
- `scripts/audio/sfx.gd` (autoload `Sfx`) owns the buses, a fixed pool of positional voices, the UI
  voices and the loop count. `pawn_audio.gd` (a child of each pawn) and `match_audio.gd` (beside the
  match look) only listen to signals and read public state; gameplay never calls the audio layer.
- `data/audio.json` "sounds": an id either lists `"files"` (full `res://` paths of recorded takes,
  any AudioStream type; one take is picked per play, streams are cached per path) or plays its
  generated WAV from `dir`. Loops are a duplicate of the loaded stream with looping switched on;
  `.import` loop flags are never used.
- Real recordings are CC0 only and never enter the repo raw: `tools/import_audio.gd` (headless,
  calls an ffmpeg binary given on the command line) cuts, fades, levels and encodes each take named in
  `tools/audio_import.json` to OGG Vorbis under `assets/third_party/audio/<pack>/` and writes its row
  in `data/asset_catalog.json`; `--check` re-encodes and compares hashes. The recipe lives under
  `tools/` so it is not exported. `tools/gen_audio.gd` writes only ids without `"files"`.
- Positional sounds (anything played at a world position, brazier fire included) are mono files; the
  non-positional beds and thunder are stereo. Ambience is a list of loop layers per look:
  `base_loop` + `by_weather[weather]` + `by_variant[look id]`. A far shot swaps to the weapon's own
  far report (`hooks.shot_far_by_weapon`, fallback `shot_far`). The local player's sprint adds one
  foley sound per step; other pawns stay one voice per step.
- Part b (M2A1b, Nov 10 2026), all values placeholders (OQ-AUDIO-SPACE):
  - Distance filters: every positional player takes `attenuation_filter_cutoff_hz` and
    `attenuation_filter_db` from the sound's settings (`defaults` plus per sound). `play_at` sets them on
    every play because pool voices are reused; `make_loop` sets them on its 3D player.
  - Impacts by material: Hitscan reports no collider and `scripts/weapons/` is not changed, so
    `pawn_audio.gd` casts its own short ray (mask 1, bodies only) through a world hit's end point on
    `shot_resolved` and reads the body's meta: `structure_type`, else `cover_palette`, else `decor_id`,
    else the body named Ground. Data `impacts` (top level, not under `hooks`) maps that to a material
    and the material to a sound id; `hooks.impact_world` stays the fallback.
  - Reverb zones: `Sfx` creates a `Reverb` bus with an AudioEffectReverb from data `buses` (a bus may
    name its `send` and a `reverb` block; dry is 0 because the zones send an extra copy). Once the map
    exists, `match_audio.gd` builds one Area3D per structure body whose type is listed in data
    `reverb_zones.types`, under its own child `ReverbZones` (never under the bodies or Nav). The box is
    the union of the type's `open` volumes from `WorldKit.config()`, padded sideways only, at the
    body's global transform. Zones sit on physics layer 10 (bit 512, named only in `audio.json`), with
    `collision_mask` 0, `monitoring` false and `monitorable` false; every gameplay query uses mask 7 or
    less, so rays pass through them. Every positional player has `area_mask` 512, so the engine finds
    the zone at the player's own position: reverb depends on where the sound is, not the listener.
    Under Jolt that point query finds a zone from the physics frame after it is built
    (`tests/test_audio_space.gd`). Zones are not loops and use no voice budget.

### 4.20 Maps and the chunked map builder
- Status (M2 P1c, Nov 14 2026): the three pipeline slices towards the 1 km map are built. P1a: map
  selection, per-map piece files, looks batched per chunk, a 300 m test map, tree-count proxies.
  P1b: ground size and paint resolution from data, height-field terrain (data, chunked look, one
  height-map collider), pieces standing on the terrain, saved navigation with stale detection. P1c:
  visibility ranges per piece class, shadows per class, chunk size 100 m, near and far terrain, a
  cover index, a loot grid, a bot think rate, visible-at-a-point proxies. Not built: fog and far
  plane matching (a product call for P2, OQ-MAP-CULL). M2 L1 (Nov 14 2026): the real M2 map,
  `alesia_1km`, as a generated grey-box (below); real matches play it, the M1 map stays a fixture.
- **Which map a match loads.** `MatchRoot.chosen_map()`: `map_path_override` when set (tests and
  the on-demand sim only); else, when `use_map_select` is on, `select_map()`; else `MatchRoot.MAP_PATH`
  (`alesia_section`, the test fixture). `_ready` sets `use_map_select` on the `auto_start` path, which
  is how the menu and the lobby start every real match; a `begin()` without the flag (every match
  test) keeps the fixture. `data/map_select.json` `"map"` names `alesia_1km`. `select_map()` returns
  `{path, error}`; a missing or invalid map gives `alesia_section` and a non-empty error, and only
  `MatchRoot.begin()` reports it. The file `user://map_select_override` (one
  `res://data/maps/<file>.json` path on its first line) wins for real matches when it exists: a
  measurement tool for a debug build on the phone. `MatchRoot.map_path` holds the loaded map.
  `DataRegistry.MAP_PATH` stays `alesia_section`.
- **A map** is `data/maps/<id>.json` (scene, spawns, landmarks) plus a scene with `Nav/Ground`,
  `ArtBuilder`, `Decor` and `SquadSpawns` markers named like the json spawns. Two optional keys name
  the map's own piece files: `"cover_data"` (`pieces`, `ring_pieces`, `decor`) and
  `"structure_data"` (`pieces`). Without them the alesia files are used. Piece types and decor
  colliders always come from `data/maps/alesia_cover.json`, structure types from
  `data/maps/alesia_structures.json`. `DataRegistry.validate_map()` checks all of this.
- **The builder** (`scripts/visual/astra_map.gd`, node `ArtBuilder`) builds the map named by its
  exported `map_json` (default `alesia_section`; `MatchRoot` sets it before the scene enters the
  tree). Physics and cover stay per piece: every piece is its own `StaticBody3D` under `Nav`, and a
  coverable piece keeps the cover contract of `scripts/systems/cover_probe.gd` (group `cover_wall`,
  a `Shape` child holding a box, collision layer 1).
- **Looks are batched per chunk** (`scripts/visual/map_chunks.gd`, `MapChunks`):
  `ArtBuilder/Chunks/Chunk_<ix>_<iz>/Batch_<source>_<type>`, one `MultiMeshInstance3D` per chunk,
  source (`cover`, `ring`, `structure`, `decor`) and type, with that type's material; its shadow
  setting comes from its class (P1c, below). A decor type is `<kind>_<n>`, one per kind and size
  (`ArtBuilder.decor_types` maps a decor id to it), because Godot strips "." from node names. The grid starts at the map centre: index = floor((x + half) / size) on each axis, clamped
  to the grid; the piece's body origin decides. Chunk nodes stay at the origin, so an instance
  transform equals its body's transform; each batch keeps it in the `transforms` meta.
  `data/map_build.json` `chunk_size_m` is a placeholder (OQ-MAP-CHUNK).
- **Not batched:** alesia's eight scene-authored walls, which retire with the M1 map. The scene's
  `Decor` node stays in the layout but holds nothing since the decor looks moved into the chunks.
- **The test map** `data/maps/test_300.json` is test-only, for performance measurement: a 300 m
  ground with alesia's types at alesia's density. `tools/gen_test_map.gd` writes its two piece files
  from the `"generator"` block with a fixed seed; a test checks that the committed files equal the
  generator's output. Zone, loot and drop data are unchanged, so a match plays only its centre.
- **Proxies.** A headless run has no draw counts, so `MapChunks.proxies()` counts nodes per map and
  per chunk (`MultiMeshInstance3D`, `MeshInstance3D`, unique materials, bodies);
  `tests/test_map_proxy.gd` checks them against `data/map_build.json` `proxy_limits` (placeholders,
  OQ-MAP-PROXY) and prints one `MAP_PROXY` line per map. `tests/test_astra_perf.gd` reports its
  draw proxy on the test map too. `tools/nav_bake_time.gd -- --map=<json>` times the bake of a map.
  None of these is a frame time: the Fold measurement decides. P1c adds the visible-at-a-point
  counts (below).
- **Ground size and paint (P1b).** `ArtBuilder.ground_size_of()` resolves the square ground's width
  once: `terrain.size_m`, then the map json's `ground_size_m`, then the AABB of `Nav/Ground/Mesh`
  (alesia's fallback: its json is read-only). The chunk grid, the paint and the footsteps read
  `ArtBuilder.ground_size_m`; `ArtBuilder.ground_material` is the one ground material (flat ground
  mesh, terrain chunks, backdrop skirt). `GroundPaint.px_for(size)` =
  min(round(size x `paint_px_per_m`), `paint_px_cap`) from `data/art_materials.json` `ground`
  (1.6 and 2048, placeholders): alesia stays 256 px and byte-identical, test_300 is 480 px.
- **Terrain (P1b).** A map json may carry `"terrain"`: `size_m`, `resolution_m`,
  `max_piece_slope_deg`, `max_piece_float_m` and a `height_source`, either `"generated"` (seed, value
  noise, a flat centre, an edge blend to 0, named hills with centre, height, radius, outer radius and
  falloff) or `"file"` (a saved heights file, JSON or a binary `.res`, never an imported image). No
  block means the flat box ground. `scripts/visual/map_terrain.gd` (`MapTerrain`) holds the grid:
  `height_at`, `normal_at` and `slope_deg_at` follow the triangulated surface (each quad split along
  (ix+1, iz)-(ix, iz+1), the split Jolt uses), and generation uses only +, *, floor, sqrt and integer
  hashing so every platform gets the same heights. `DataRegistry.validate_terrain()` checks the block.
  - Look: `ArtBuilder/Terrain/Chunk_<ix>_<iz>/Mesh`, one `ArrayMesh` per cell of the chunk grid (every
    cell), with the ground material; normals come from the whole grid, so chunks share edge normals.
    `data/map_build.json` `terrain.cast_shadows` is off (placeholder).
  - Collider: exactly one `StaticBody3D` named `Ground` under `Nav` with one `Shape` holding one
    `HeightMapShape3D` (no seams between chunk colliders). The name matters: the audio code, the
    builder's wall loop and `greybox_art.gd` tell the ground apart by it. A terrain map's scene keeps
    an empty `Nav/Ground`; the builder fills it.
  - Pieces: the builder adds the terrain height at a piece's origin to its y at build time
    (`ArtBuilder.lifted()`, `WorldKit.populate`, `WorldKit.decor_body` with a lift so arch piers end at
    the ground). Piece files keep their flat-ground y. `tools/gen_test_map.gd` rejects spots that are
    too steep or too uneven (`ground_fits`).
  - test_300: flat (exactly 0) within 80 m of the origin, where spawns, zone start and drop lie; one
    12.3 m hill at (90, 90), gentle towards the centre. All numbers are placeholders (OQ-MAP-TERRAIN).
- **Saved navigation (P1b).** `tools/bake_nav.gd -- --map=<json>` (no argument: the three maps) bakes a
  duplicate of the scene's inline `NavigationMesh` and saves it as `data/maps/nav/<map>.res` with a
  manifest `data/maps/nav/<map>.json`: the sha256 of every input. Runtime inputs are JSON (map json,
  piece files, `alesia_cover.json`, `alesia_structures.json`, `art_astra.json`, a JSON heights file),
  hashed with "\r" removed; tool inputs (the scene, a binary heights file) are compared only by the
  tool and the tests. `MatchRoot.begin()` calls `MapNav.load_fresh()` (`scripts/visual/map_nav.gd`):
  a fresh mesh is loaded past the resource cache and assigned to `Nav`; otherwise it bakes as before,
  prints one line and counts it in `nav_bakes`. `bake_navmesh = false` skips both.
  `tests/test_saved_nav.gd` fails when a committed mesh is stale and re-bakes both maps to compare
  polygon and vertex counts (a same-machine check). After changing any input, re-run the tool and
  commit the four files. `tools/nav_bake_time.gd -- --load` reports load against bake (OQ-MAP-NAV).
  `DataRegistry.validate_terrain()` reads a heights file and reports a grid that does not fit the
  block (P1c); `MapTerrain.for_map()` logs one error when a map's terrain block gives no terrain, and
  its cache holds one map's terrain, dropped when `ArtBuilder` leaves the tree.
- **Visibility ranges (P1c).** Godot 4.7.2 measures `visibility_range_begin`/`_end` from the camera
  to the centre of the node's world AABB (for a batch: the box around all its instances), not from
  the node origin (`tools/vis_range_probe.gd`, windowed). So the P1a placement stays: batches and
  terrain chunks at the origin with world-space content. Fade is disabled everywhere, so the margin is
  hysteresis: a drawn node hides beyond end + margin, a hidden one shows again within end - margin.
  - Classes: `data/map_build.json` `classes` puts each batch in a class (by type, then by kind, then
    by source) with a `range_m` and `cast_shadows`. `range_m` means "every piece is drawn at least
    out to this distance", so end = range_m + the batch radius (half its AABB diagonal) + `margin_m`
    (5); 0 = never culled. A batch with colliders never ends below `sight_floor_m` (250); the code
    raises it (`MapChunks.effective_range`). Only paving (120 m) ends earlier.
  - Shadows per class: structures and cover or ring pieces of 1.8 m and taller cast; small cover,
    small ring and decor do not. The class wins over the builders' old settings.
  - Chunk size 100 m (was 50): measured at 50, 75 and 100 m (`test_chunk_size_report_only`, through
    `MapChunks.size_override_m`), 100 m gave the fewest batches, the lowest draw proxy and the fewest
    batches in range from the centre and a corner on both maps, and tiles 300 m and 1 km. Costs: about
    71 m of batch radius in every range end and 20,000-triangle terrain chunks.
  - Near and far terrain: each chunk has `Mesh` (full resolution) and `Far`
    (`MapTerrain.far_chunk_mesh`, every `far_step_m` 5 m inside, every full-resolution sample on the
    border, so neighbours meet without cracks). `Mesh` ends and `Far` begins at the same E =
    `far_swap_m` (150) + chunk radius + margin, measured from the same centre (`Far` takes `Mesh`'s
    AABB as its custom AABB): never neither drawn. `Far` has no end, so terrain is never culled. The
    collider is unchanged (the full height map).
- **Cover index and loot grid (P1c).** `CoverIndex` (`scripts/systems/cover_index.gd`) is a grid over
  the group `cover_wall`, one per SceneTree (a meta on its root); `CoverProbe` joins only walls near
  the current ends and still runs every old per-wall check live. Staleness: every sample an O(1)
  check (a dirty flag from tree signals and the group's node count); at most once per frame a full
  O(walls) validation (group array, shape positions, box resources). So a wall moved silently is seen
  from the next frame, not within the frame. `LootField` keeps a grid of its items; `nearest()` and
  the bot loot goal ask `items_near()`, which returns ids in insertion (rank) order, so ties keep the
  first-inserted winner. Both give the old results (proven by tests); cell sizes
  `spatial_index.cover_cell_m` 16 and `loot_cell_m` 20 change only speed (OQ-MAP-INDEX).
- **Bot think rate (P1c).** A bot farther than `bots.json` `brain.think_rate.far_distance_m` (60) from
  every alive human runs a full think only when (`MatchDirector.tick_count` + player id) %
  `far_interval_ticks` (4) == 0; downed, dead and spectating humans do not count. On the other ticks
  it coasts: movement, look, timers and path following run on the last decision. The near check runs
  on cadence ticks, so an approached bot is at most 3 ticks late. While the match is not running
  every tick thinks. OQ-BOT-THINK.
- **Visible-at-a-point proxies (P1c).** `MapChunks.visible_at(map, point)` counts what the renderer's
  rule draws from a point (batches, colliding or not, shadow casters, terrain near and far and their
  triangles). `MapChunks.standard_points()` defines the two points once (the play centre and the
  ground corner, at eye height 1.7 m); `visible_proxies()` and `visible_problems()` check them
  against `proxy_limits.visible` (placeholders, OQ-MAP-PROXY).
- **P1c tests.** `tests/test_map_cull.gd` (placement, classes, floor, shadows, chunk sizes, far
  terrain, the `P1C_PROXY` report), `tests/test_map_proxy.gd` (limits), `tests/test_cover_index.gd`,
  `tests/test_loot_grid.gd`, `tests/test_bot_think_rate.gd`, `tests/test_terrain_heights_and_cache.gd`.
- **alesia_1km (M2 L1).** The concentric Alesia at 1 km, a grey-box from data; every size, count,
  place and name is a proposal (OQ-ALESIA-LAYOUT). `tools/gen_alesia.gd` (seeded) reads the map
  json's `"generator"` block and writes `alesia_1km_cover.json`, `_structures.json`,
  `_landmarks.json`, `_heights.res`, `_paint.res` and the generated keys of `alesia_1km.json`
  (`spawns`, `reserved_spots`, the two sha256 keys; other keys are kept, sorted). Same block, same
  bytes; `tests/test_alesia_1km_data.gd` pins it. To change the layout: edit `"generator"`, run
  `tools/gen_alesia.gd`, then `tools/bake_nav.gd -- --map=res://data/maps/alesia_1km.json`, commit
  all of it. Only existing piece types; rings are polygons (inner 24, outer 32 sides).
  - `"free_yaw_types"`: the wall types (wall_walk, wall_stair, gate, watchtower) that may take any
    yaw on the ring tangent; every other piece keeps the 90 degree step
    (`DataRegistry.yaw_problems`). Consecutive wall pieces overlap; joint gaps stay <= 0.3 m.
  - `"reserved_spots"`: `[{id, kind, at: [x, z]}]`, kind `jump_pad`, `man_cannon` or `lily_trap`,
    places for J1 only, no nodes. Validated: known kind, inside `play_radius_m`, outside every
    collider footprint (`DataRegistry.collider_footprints` / `footprint_at`, from the data).
  - `"backdrop": true` since M2W1 (honoured by `ArtBuilder`, `backdrop_wanted`): the outer wall and the
    fields are still the play edge; beyond them the far backdrop of `data/art_backdrop.json` `maps.alesia_1km`
    is drawn (see "World art (M2W1)" below). It was `false` until then.
  - `"ground_paint"`: the art_materials `ground` keys for this map, plus `roads` (false: no spokes)
    and `baked`: the paint is painted offline into an Image `.res` (1024 px; footsteps read its
    pixels) and loaded at runtime with an inputs-hash stale check; a stale or missing bake paints at
    load and prints one line. Flat maps are unchanged (alesia 256 px byte-identical).
  - Terrain: flat except the citadel hill (r 90 m, 25 m, steepest 29 degrees), saved as a binary
    HeightMapShape3D `.res` at 2 m (501 x 501). `validate_terrain` reads only its header
    (`MapTerrain.heights_header_problem`), so the samples are read once, by the builder.
    `terrain.far_step_m` (10) overrides map_build.json's 5 m, which is no multiple of 2 m.
  - `"overrides": {"br": {..}, "loot": {..}}`: deep-merged over `br.json` / `loot.json` for this
    map only, by `MatchDirector.load_config(map_json)` (dictionaries by key, arrays and scalars
    replace, `_` keys are notes). `begin()` calls it once, after the map choice, only while
    `mode_cfg` is empty, so a caller's later changes (the sim's scaling) survive. `overrides.br` may
    not set `teams` (the lobby reads it first; `DataRegistry.overrides_problems`). alesia_1km: zone
    start 480 m and phases, drop path 960 m and carrier 40 s, altitude 150 m, fall 12 m/s, glide
    10 m/s, loot over 480 m, 540 items, 12 at each landmark (OQ-BR-ZONE, -DROP, -LOOT guesses).
  - The zone generator (M2 Z1): the phases in `overrides.br.zone` are written by `tools/gen_zone.gd`
    from the map's top-level `"zone_gen"` block (run speed, edge speed cap, shortest shrink, and per
    phase a radius fraction, a wait and a damage), never by hand. Rules: each radius is smaller than
    the one before and the last is 0; shrink = the shortest whole second with the edge speed
    2 (r_prev - r) / shrink at or under the cap; damage rises; the first wait is lengthened until the
    last forced drop (carrier_s + altitude / max fall, read from the merged drop) can land and run
    2 (R0 - r1) to the first circle before it closes. Same inputs, same file (gen_alesia's writer).
    After any change to the map json: run `gen_zone.gd` (if zone_gen or the drop changed), then
    `bake_nav.gd` (the saved-nav manifest hashes the map json). `tests/test_zone_gen.gd` is the
    drift test; `tests/test_map_overrides.gd` holds the zone, drop and loot rules.
  - `tests/sim/test_sim_match_length.gd` (on demand): one real-timing match per process on
    alesia_1km (`--ml-mode=solo|squads --ml-seed=N`, run with `--fixed-fps 60`: same result as real
    time, about 2.5 times faster); prints `ML` lines: length, kills and alive per phase, bots
    outside the zone at each shrink, and per pawn the landing and the seconds to its first armour,
    ammo, heal and second gun (found by polling; gameplay code has no pickup signal).
  - Loot height: `LootField.setup` takes an optional terrain height callable (passed by `MatchRoot`);
    `max_ground_y_m` is measured above the terrain at the item, so loot lands on the hill. On flat
    maps identical.
  - Saved nav for three maps: `tools/bake_nav.gd`'s default list names alesia_section, test_300
    and alesia_1km (about 6 s; 10,901 polygons since M2 L1c commit 2, 10,352 and 329 kB when first measured; doors and ladders
    do not change it, they stand outside Nav). The manifest's tool inputs hold the heights
    `.res`, the paint `.res` and the scene sha256; `tests/test_saved_nav.gd` re-hashes them and
    re-bakes only the two small maps.
  - Tests: `tests/test_alesia_1km.gd` is the ONE suite file that builds the 1 km scene (a static
    built by `_map()`, freed by its last method `test_zz_free_the_map`; add scene checks above it;
    run it whole with `--only=test_alesia_1km`). It also holds the one real-match entry on this map
    and the report lines (`ALESIA_1KM_*`). Data checks live in `tests/test_alesia_1km_data.gd`.
  - The sim, on demand: `tests/sim/test_sim_alesia_1km.gd` (never in the normal suite) plays seeded
    18-player matches with `map_path_override` (its one allowed use), `director.load_config(map)`,
    then the existing sim's x0.4 phases and carrier time; a 10-minute wall cap per match, an
    unfinished match fails and says how far it got. It counts kills by gun and blade, zone deaths,
    loot taken, unstick events (each 0 -> >0 of a brain's `_unstick_left`, read with `get()`) by
    area, and reports the draw proxy, the cover-index time and load times (`ALESIA_1KM_LOAD`). One
    match per method: `-- --dir=res://tests/sim --only=test_sim_alesia_1km.gd::<method>`.
  - The layout picture: `tools/render_layout.gd -- --out=<png>` draws the map from its data into an
    Image, headless (ground bands, hill contours, every collider footprint by class, rings, gates,
    towers, aqueducts, camps, spawns, reserved spots, play circle and zone start, legend, north
    arrow, 100 m scale; text in a built-in 5x7 bitmap font). `-- --shots=<dir>` (windowed) builds
    the map scene with the match's Light and WorldEnvironment (GreyboxArt) and saves six ground
    shots at 2520 x 1080 (`shot_points`). Its data pass is tested in test_alesia_1km_data.gd.
- **M2 L2a: `alesia_500`, the 500 m map real matches use** (`data/map_select.json`; Shibi, Nov 17 2026:
  half the size, more world building; every number a placeholder, OQ-ALESIA-500). The 1 km map stays
  in the repo, untouched, with its tests and saved nav.
  - Generated by the same tool: `tools/gen_alesia.gd -- --map=<id>` (default alesia_1km). The 500 m
    layout passes are separate functions that run only when the map's generator block has their keys
    (`arx_wall`, `town`, `farmsteads`, `field_walls`, `vineae`, `stationes`, `ground_contact`,
    `doors.*.id_patterns`, `ladders.id_patterns`), so the 1 km stream of random draws is unchanged
    (`tests/test_alesia_1km_data.gd` compares the generator's output with the committed files).
  - Layout (centre outwards): the Arx on a 16 m hill with a fortress ring (8 sides, apothem 26 m, two
    gates, four towers); ring road; inner wall (apothem 84 m, 16 sides, four gates); the town, a
    street grid of 28 m cells with templates (insula, forum, templum, thermae, fabrica, horreum) and
    half blocks; six camps at 164 m; fields with twelve farmsteads, vineyard plots of stake rows,
    picket posts and field wall runs; outer wall (apothem 222 m, 32 sides, four gates, eight towers);
    three aqueducts ending in the fields. Play radius 240 m. No new kit types.
  - Ground contact: `tests/test_ground_contact.gd` measures, per visual, the gap between its lowest
    point and the terrain under its footprint; asserted on alesia_500 (`terrain.max_visual_float_m`),
    printed for alesia_1km (`GROUND_CONTACT` lines). The generator's `ground_contact` rule sinks or
    re-draws a piece that would float. `terrain.far_step_m` is 4 on this map (the far terrain mesh
    cut under the Arx ring at 10).
  - Sight lines: `tools/sight_lines.gd -- --map=<id>` (also called by `tests/test_alesia_500.gd`):
    eye-height points every 10 m on walkable ground, 16 rays each, the share travelling past 80 m,
    per district (`SIGHT_LINES` lines); the target in the map json is report-only.
  - Sized to the map: `zone_gen` (nominal last close 570 s, as the 1 km map), the drop (side reach
    252 m covers the 240 m play radius), loot (count = max(540 x walkable-area ratio, 25 per player)),
    `data/bots.json` `brain.route.big_map_radius_m` 200 (the 240 m start radius counts as a big map;
    the 75 m maps stay small), the minimap texture and `data/ui.json` extent.
  - Looks: `alesia_500` blocks in `art_world_maps.json`, `art_clutter.json`, `art_backdrop.json`, and
    an optional per-map roads override `place_map.maps.<id>` in `data/art_ground_detail.json`
    (`scripts/visual/place_map.gd`; absent = the global block).
  - Saved nav: `tools/bake_nav.gd` bakes four maps by default. Tests: `tests/test_alesia_500.gd`
    builds the scene once (validation, landmarks, gates and every barracks doorway on the saved
    navmesh, spawns to the Arx, proxies and sight lines report-only, the real-match entry),
    `tests/test_alesia_500_data.gd` the data and the generator.
  - **M2 CX2 world pass.** Alesia 500's generator selects civic building types before testing block
    footprints and doorway aprons. Insula upper storeys are solid. The tower beacons mount on
    existing corner aerials, and the aqueduct variant reuses the span's collision geometry. The
    final placement pass fits compound cypress stands, farm walls, carts and well stations around
    the existing layout. These pieces and the Forum stalls are structures under Nav with one
    body per placed piece. The 844 cover walls still fit the cap of 850.
  - Three original Blender families (`tools/blender/m2cx2_town.py`, `m2cx2_landmarks.py`,
    `m2cx2_dressing.py`) share the W1 vertex exporter. Each type points to its own family's GLB
    in `art_world_kit.json`. MapChunks swaps the larger looks to hand-built far meshes. Small
    dressing and cypress batches retain the 250 m collider sight floor. The new beacons, carts,
    wells, stalls and short farm walls skip real-time shadow casting.
  - The 500 m backdrop uses closer ridges and a painted-edge blend into the terrain skirt.
    The central terrain cell uses its full-resolution surface at all distances to keep the
    Arx ring in contact. The other terrain cells retain their 4 m far meshes. The contact
    test samples the render step at each point of a piece's footprint.
  - Each of the ten gates has a local approach profile in Alesia 500's place-map settings.
    The masks are stamped before clutter: trodden strips keep ground patches out, and
    shelter strips draw them in (world_clutter.gd shelter chance). Alesia 500's compacted
    earth uses the ochre soil colour set alongside the profiles (trial value).
  - Saved-nav doorway coverage includes the new housing and civic rooms. Re-baked meshes for
    `alesia_1km`, `alesia_section` and `test_300` retain their pinned hashes in
    `tests/test_m2w1_backdrop.gd`. Their manifests carry the updated shared input hash.
  - Sims take the map: `--sim-map=<id>` (default alesia_1km) in `tests/sim/test_sim_alesia_1km.gd`
    and `test_sim_match_length.gd`; every `map=` field prints that id.
- **Props: breakables and loot chests (M2 L1b).** All numbers are placeholders (OQ-PROPS-BREAK, OQ-PROPS-CHEST).
  - Data split: WHERE lives in the map's cover file (`alesia_1km_cover.json` `"breakables"` {id, type, at, size}
    and `"chests"` {id, at, size, yaw}), because the saved nav hashes that file; WHAT lives in `data/props.json`
    (breakable types: health, melee damage, palette, look, loot roll; `chest`: range, height limit, palette, the
    closed and open looks for `look_size`, the spill, the roll; `break_fx`). props.json is never a nav input.
  - Generator passes, in this order (each appended after the earlier ones, so earlier output stays
    byte-identical): original pieces, `_extra_cover` ("extra_cover"), `_breakables` ("props.breakables"),
    `_chests` ("props.chests"; a chest's footprint is its box plus `front_clear_m` in front, `chest_rect`).
    Re-generate: `godot --headless --path . --script res://tools/gen_alesia.gd`, then
    `tools/bake_nav.gd -- --map=res://data/maps/alesia_1km.json`; commit the map json, the cover file, the paint
    `.res` if it changed and the two nav files.
  - Building (`astra_map.gd`): breakables are `Breakable` bodies under `ArtBuilder/Props`, OUTSIDE Nav (never
    baked; bots path through them), groups `cover_wall` and `breakable`, appended to `cover_bodies` right after the
    pieces (the paint's trodden order, `gen_alesia.trodden_of`). Chests are permanent `LootChest` bodies UNDER Nav
    (baked), group `loot_chest` only (never cover_wall, never in cover_bodies, so the paint and the cover index are
    unchanged), built after the wall loop, in `chest_bodies`. alesia_section and test_300 have neither.
  - Looks are named chunk pieces (`MapChunks.add(..., piece_id)`, source "cover"): a breakable's id; a chest's
    closed look (type `loot_chest`, its id) and open look (`loot_chest_open`, `LootChest.open_id(id)` =
    "<id>/open", hidden right after `build()`). `hide_piece` / `show_piece` set a zero-scale instance (and the
    batch's "transforms" meta); breaking hides, opening swaps. `tools/props_shots.gd -- --out=<dir>` (windowed)
    shows the result on screen.
  - `WorldProps` (`scripts/props/world_props.gd`, one per match, `MatchRoot.world_props` = `director.props`):
    collects the map's breakables and chests, holds the states (INTACT, BROKEN, OPEN), and on the authority rolls
    the loot from the match seed and the prop id (`loot_roll`, salt "break" / "chest") and spills it through
    `LootField.drop` (`spilled` keeps the ids); `prop_changed` feeds the net event (4.17); `apply_state` is the
    client side. `chest_near(pos)` is the nearest closed chest within range and height.
  - Hooks: `Hitscan.fire` and `Melee.swing` damage group `breakable` on the authority only. Interact
    (`MatchRoot._on_action_triggered`): revive, else pickup, else `MatchDirector.try_open_chest`;
    `chest_target_for` has pickup's conditions (alive, not dropping). `InteractButton` shows "Open chest". Bots:
    `_bot_pickups` then `_bot_chests` (any closed chest in range; no brain change).
  - Tests: `test_props_world.gd`, `test_props_breakable.gd`, `test_props_hooks.gd`, `test_props_nav.gd`,
    `test_props_chest.gd`, the 1 km checks in `test_alesia_1km.gd`, the host/client agreement in
    `test_net_match.gd`. The sims print `props_broken chests_opened prop_loot prop_loot_taken` at the end of the
    SIM line's deterministic part.
- **Props: doors, gates and ladders (M2 L1c).** All numbers are placeholders (OQ-PROPS-DOOR, OQ-PROPS-LADDER).
  - Data split as for chests: WHERE lives in the cover file (`alesia_1km_cover.json` `"doors"` {id, kind door|gate, at,
    yaw, size, slide left|right|apart, start open|closed} and `"ladders"` {id, piece, at, yaw, height, width, top}),
    WHAT in `data/props.json` `door` (with a `gate` block merged over it by `WorldProps.door_cfg`) and `ladder`. Neither
    is a nav input. Generator blocks `doors` and `ladders` in `alesia_1km.json`; passes `_doors` and `_ladders` in
    `tools/gen_alesia.gd` run after every other pass (and after `_ramp_guards`), so earlier output stays byte-identical.
    `doors` uses the doorways the kit already has: 24 barracks doors (openings 0 and 1 of 12 barracks, one leaf) and 8
    gates (two half leaves, `apart`); the start state comes from one seeded draw per door against `start_open_share`
    (door 0.5, gate 0.75): 17 open, 15 closed. `ladders`: one per barracks block on an end wall (12), no random draw.
  - Door (`scripts/props/door.gd`, a `StaticBody3D` under `ArtBuilder/Props`, outside Nav, on the world layer, never a
    cover wall, not in `max_cover_walls`). Doors SLIDE into the wall (pocket doors), they do not swing: only a pawn in
    the doorway is ever in the way, where a swing would be blocked by the opener standing in front of it. The collider
    is on only while the door stands closed, so a door never pushes or traps a pawn. A close waits `blocked_retry_s` while
    a pawn stands in the doorway; an open starts at once. Sound: palette `door`, so the existing wood impact.
  - `WorldProps`: `doors`, new state `CLOSED` (3) beside `OPEN` (2), every door stored from registration;
    `set_door(id, state)` (authority, absolute), `toggle_door`, `door_near(pos)`, `apply_state` for doors (a client takes
    every changed value), and the data checks in `problems`. Net: see 4.17. LAN clients cannot toggle until M3.
  - Interact priority: revive, pickup, chest, door (`MatchRoot._on_action_triggered`; `MatchDirector.door_target_for`
    and `try_toggle_door`; `InteractButton` reads "Open/Close door" or "Open/Close gate").
  - Bots: `MatchDirector._bot_doors` (after the pickup and chest passes; `bot_brain.gd` is untouched). A walking bot in
    range of a closed door whose NavigationAgent3D path crosses the doorway (`path_crosses_door`, plain getters,
    `bot_path_lookahead_m`, `bot_path_edge_m`) opens it after `bot_open_delay_s`, counted in director ticks. Bots never
    close doors. Delay plus move time must stay under `stuck_window_s` 2.0.
  - Ladder (`scripts/props/ladder.gd`): an `Area3D` trigger on layer 0 (mask 2), under `ArtBuilder/Props`, outside Nav,
    not on the world mask: it blocks no shot, sight or movement. Pawn (`scripts/classes/pawn.gd`, the "M2 L1c ladder"
    block): plain state `climbing`, `ladder_id`, `can_climb`. Walking into a ladder from below, or out over the edge
    from the roof, grabs it; the stick's share into the ladder climbs at `climb_speed_mps` (no input holds); past the top
    the pawn is stepped onto the roof (`top_rise_m`); Jump lets go with a small push; reaching the ground, downed, dead
    or the drop state also let go. While climbing: no gravity, no jump, no cover probe, no fire, no melee; reload and
    swap work. Bots never grab and no nav link is built. Offline only until M3 (`in_lan_session`, as cover): the host's
    move validation would refuse the top step.
  - Ladders only on barracks roofs (the only tops no ramp or stair reaches). Not added: colonnade and pediment tops,
    gate arch tops, mid-run aqueduct deck access, long wall-walk stretches between stairs.
  - Tests: `test_props_doors.gd`, `test_props_doors_interact.gd`, `test_props_doors_net.gd`, `test_props_doors_bots.gd`,
    `test_props_ladders.gd`, `test_pawn_ladder.gd`, and the 1 km checks in `test_alesia_1km.gd`.
- **Map fix and stuck-spot tools (M2 L1c).** Generator block `ramp_guard` (OQ-MAP-CLEAR; `_ramp_guards` in
  `tools/gen_alesia.gd`): a `stake_row` flush along both sides of each aqueduct ramp for `along_m` 4.0 from the foot,
  `overlap_m` 0.05 into it, 12 pieces appended after every other pass. Why: the saved nav joined the ground to a ramp's
  side near the foot over a 0.37 m step (`agent_max_climb` 0.25), and a pawn steps 0.12 m. Nav re-baked: 10,831 to
  10,901 polygons. Test: `tests/test_stuck_spots.gd`.
  - Measurement: `tests/sim/test_sim_alesia_1km.gd` prints one `SIM_UNSTICK_AT` line per unstick start (bot, game time,
    position, area, goal, goal position, nav reachable, next path point; plain getters, no draw), and a `SIM_DOORS`
    line (doors, closed at start, opened by bots, closed at end); the `SIM` line is unchanged, and `chests_opened`
    counts chest ids only. `tools/unstick_probe.gd` (`-- --from=<log> | --at="x,z;..."`) clusters the lines at 8 m and
    prints a PROBE block per cluster (colliders in range, groups, Nav or not, nav polygons under each, gaps, steps).
    `tests/sim/test_zz_stuck_trace.gd` (on demand) prints what happened in the 121 frames before each unstick.
  - Finding: the big clusters (camp ring S and N, Castra Sexta, inner_band SE and NW) are not map faults. The bot walks
    at full speed with no wall frames and flips between a loot or hunt goal outside 0.85 x the next circle's radius and
    the zone goal (`bot_brain.gd` `_inside_target` / `_zone_pressure`, no deadband). Left open: OQ-BOT-FLIP.
- **World art (M2W1, Nov 16 2026).** Looks only; every look and number is a trial (OQ-ART-WORLD). The play space is
  pinned: `tests/test_m2w1_colliders.gd` compares every collision shape under `Nav` and `ArtBuilder/Props`, the
  `cover_wall` order, the builder lists and the ground paint inputs hash with
  `data/maps/snapshots/alesia_1km_colliders.json` (`tools/m2w1_collider_snapshot.gd` rewrites it after an INTENDED
  collider change), and `tests/test_m2w1_backdrop.gd` pins the three saved navs' `mesh_sha256`.
  - **Structure looks from Blender.** `tools/blender/m2w1_world_kit.py` (`blender.cmd -b --python ...`, then import,
    then `tools/asset_hashes.gd -- --write`) writes `assets/generated/world/m2w1_world_kit.glb`: one node per type
    (`<type>`) and far level (`<type>_lod1`), carrying the kit's vertex data (paint as sRGB vertex colour, UV in
    metres, UV2 = surface id and shade), so `WorldKitMeshes` (`scripts/visual/world_kit_meshes.gd`) turns each into
    ONE surface with the one shared `WorldSurface` material and builds the tangents. `data/art_world_kit.json` names
    the nodes, `lod_swap_m`, `fit_tolerance_m` (0.15: every vertex lies within it of the type's colliders; open
    volumes stay open; nothing rises over a walk surface), the triangle caps and `joint_skew` (overlapping wall
    pieces are skewed 1.5 cm so shared faces do not z-fight). `WorldKit.mesh_for(type)` answers the glb mesh when
    the preset's `art_world_kit_enabled` is on, the kit mesh otherwise or when an entry, file or node is missing
    (one error line). The "parts" in `alesia_structures.json` stay (a nav input) and are the fallback look.
  - **LOD pairs.** `MapChunks.pair_lod`: per chunk one MultiMesh per type and level; the near batch ends at
    `lod_swap_m` + radius + margin, the far batch begins there and ends at the class range; both measure from the
    near batch's AABB centre (the far one takes it as `custom_aabb`), so exactly one draws. A far batch has meta
    `lod_level` 1 and is not counted as instances of its own. A type under `lod_required_over_tris` may have none.
  - **Door, gate and ladder looks** are the `look` parts in `data/props.json` (behaviour untouched).
  - **Light.** Every look change lives in `data/art_look.json` `variants` (`light`, `fog`, `sky`, `post`);
    `art_greybox.json` and `art_astra.json` keep the old base numbers, which the variant `dusk_deep` (not in the
    rotation) still shows. `dusk` is now a clear late-day look. Optional variant keys (absent = engine default):
    `ambient_source`, `ambient_sky_contribution`, `reflected_light_source`, `tonemap_white`, `fog_height`,
    `fog_height_density`, `shadow_blur`, `shadow_bias`, `shadow_normal_bias`, `shadow_opacity`,
    `shadow_fade_start`, `shadow_blend_splits`, `glow_hdr_scale`, `glow_levels`, and the sky's `cloud_light_*`,
    `cloud_base*`, `cloud2_*`, `horizon_haze*`. No Light3D was added.
  - **WorldAmbient per map.** On a terrain map `WorldAmbient` reads `data/art_world_maps.json` (the map's block,
    else `terrain_default`, empty) and lifts each point onto the terrain; flat maps keep `art_world.json`.
  - **Ground.** `data/art_ground_detail.json` (never hashed; `art_materials.json` `ground` is, by
    `GroundPaint.inputs_hash`) feeds `ground.gdshader` when `art_ground_detail_enabled` is on: macro patches, rock
    by slope, paving edges, near grain, tiling faded with distance; 8 texture fetches per pixel (was 6).
  - **Clutter.** `scripts/visual/world_clutter.gd` (`WorldClutter`), `data/art_clutter.json`,
    `tools/blender/m2w1_clutter.py` -> `m2w1_clutter.glb`: draw-only MultiMesh instances (source `clutter`, classes
    `clutter_prop` and `clutter_scatter`, no shadows), only on maps with a block in `maps` and with
    `art_clutter_enabled`. Dressing sets sit in a piece type's local space; scatter follows the ground paint and
    noise; the placement is a hash of the position (no gameplay RNG). The builder drops an instance that breaks a
    rule (0.6 m height, lanes through doorways and gates, door pockets, ladders, chests, landmark loot centres,
    cover edges, collider footprints, walk and open volumes, reserved spots, slope); the test checks the built
    result against the real saved-nav paths. Ground loot is rolled per match, so only landmark centres are kept
    clear.
  - **Far backdrop.** `Backdrop.build(material, map_json, terrain)`: a map named in `art_backdrop.json` `maps`
    gets its own set (alesia_1km: ground skirt to 3 km, three hill rings, a far aqueduct, beacons, cypresses beyond
    the wall; 5 draws, about 10,000 triangles, inside the default 4 km far plane); other maps build the old ring.
  - **Capture.** `tools/m2w1_capture.gd` with `data/m2w1_capture.json` (named shots per look and size);
    `tools/m2w1_pixel_probe.gd` samples screen values from a capture.
  - **After the Astra review (Nov 16 2026).** Built without Blender (it was refused in that session; the two glb
    files are unchanged, and `tools/blender/m2w1_world_kit.py` was last RUN at commit 1046309):
    - Cover looks: `data/art_world_kit.json` `cover` holds kit parts per cover type (`same_as`, `swap_xz` share
      one); `WorldKitMeshes.cover_mesh` builds them with `LowpolyKit.merge` when the kit switch is on, else
      `LowpolyKit.build_cover` on the hashed file's parts. Breakable and chest looks are the `look` keys in
      `data/props.json`, built through `WorldKit.prop_look`. One box collider each, unchanged; no far levels.
    - Shade bake: `WorldKitMeshes.bake_shade` (`shade_bake` keys) multiplies each glb vertex's shade by a value
      per paint, a ground-contact term, an up/down facing term and a per-type gain, at load. The loader writes
      CUSTOM0 (x = variation weight, y = shade range, z = grime share); `world_surface.gdshader` takes its new
      path only for meshes that carry CUSTOM0, so kit meshes, doors and ladders render as before.
    - Variation: value and warm/cool shift per piece from a hash of its instance origin (`variation` keys), the
      same for a piece's near and far level.
    - Place map: `scripts/visual/place_map.gd` paints a 512 px RGBA image at map build from the placed bodies
      and the clutter (R trodden aprons and tracks, G shelter, B contact shadow, A the old 360 m noise); never
      saved, no hashed input. The ground shader reads it in place of that noise fetch (still 8 fetches) and
      adds height bands on the hill (`data/art_ground_detail.json`).
    - Clutter: composed groups merged at load (supply_row, fire_ring, arms_trough, veg_patch, stone_patch),
      placed against walls and in sheltered pockets; 246 batches (was 503), `budgets.batches` 250.
    - Astra round 2 (with Blender again; `tools/blender/m2w1_world_kit.py` and its glb match from commit
      4f173fb on): the script bakes part shade, tread and sill wear, a foundation band and ray occlusion into
      the glb's shade; `WorldKitMeshes.bake_shade` keeps paint value, facing and per-type gains (one place per
      term). A `cover` entry names kit `parts` OR a glb `node` (sandbags, the nests, wreck_cart). The summit
      types swap to their far level only at 420 m. `place_map.gd` also paints broad roads (gate to camp to
      citadel foot, two ring tracks, field tracks); `art_look.json` variants may carry a `ground` block that
      overrides ground-look keys for that variant; `WorldClutter` places edge runs along walls, outposts round
      cover and pockets along roads, with a `join` rule that adds no batch.
    - Looks: dusk is a low golden hour (sun 13.5 degrees, AgX tonemapper in dusk, night and storm; `dusk_deep`
      keeps ACES); optional keys `glow_gain` (scales surface glow per variant), `cloud_sun_3d`,
      `sun_halo_wide`, `wet_far_m`. The backdrop's hill rings take a compass profile (massif north, table
      east, opening south, wooded hills west).

### 4.21 Cover

Owner-only contextual cover: `CoverController` (`scripts/systems/cover_controller.gd`, a pure state machine
FREE, ENTERING, IN_COVER, PEEK_LEFT, PEEK_RIGHT, EXITING) fed by `CoverProbe` (`cover_probe.gd`, the
`cover_wall` contract: a StaticBody3D in group `cover_wall` with a "Shape" BoxShape3D on layer 1) and
`CoverIndex`. `Pawn._ensure_cover` builds it only for the local player (CameraRig child, no Brain,
`net_mode` LOCAL, offline). All numbers are placeholders in `data/cover.json` (OQ-COVER).

#### C1b cover as built (kept current per stage; stage 1 = the Cover button and auto-snap; stage 2 = the cover camera, pose and auto crouch; stage 3 = moving and exiting; stage 4 = Fire in cover, Aim hold and removal of the old path; a final description closes the section)
- **Entry by button.** Touch only in C1b. The touch HUD's Shoulder slot (`swap_shoulder` element) is the
  Cover button while `Pawn.cover_button_available()` (controller present, ALIVE, `drop_state` NONE, not
  LAN): on the ground, FREE or in cover. Carrier, falling and downed show Shoulder swap as C1a left it.
  A press calls `Input.action_press("cover")` (project.godot action `cover`, no key or pad events) and
  `TouchProvider.trigger_action("cover")`; `"cover"` is in `InputRouter.NON_FRAME_ACTIONS` (no InputFrame
  bit), MatchRoot forwards it to `Pawn.handle_action_press("cover")`, which samples the main probe at
  `cover_button_range_m` and calls `CoverController.request_cover(probe)`. UI never calls the controller.
- **Controller API (stage 1).** `request_cover(probe) -> bool`: FREE enters when
  `can_enter_by_button(probe)` (hit, `distance_m` <= `cover_button_range_m`, `height_m` >=
  `min_cover_height_m`; no stick, angle, sprint, Fire or cooldown rule); IN_COVER / PEEK_* begin the exit;
  ENTERING / EXITING ignore it. `enter_duration()` = min(`enter_s`, `input_lock_max_s`). `tick(delta, move,
  fire_pressed, probe, aiming, sprinting)`; the last two inputs only gate auto-snap. Both entries go
  through `_enter()`, which emits `entered`.
- **Probe distance.** `CoverProbe.sample(pawn, cfg, locked, distance_m = -1)`: the unlocked ray reaches
  `distance_m`, else `probe_m`. The button press samples the pawn's main probe (so it holds the wall for
  the locked samples that follow); the HUD highlight uses `Pawn.cover_button_valid()`, a second lazily
  built probe sampled at most once per physics frame. `Pawn.in_cover()` drives the active look.
- **Auto-snap anti-sticky rules** (`_try_snap`): stick length >= `enter_stick_min` and its direction within
  `max_wall_angle_deg` of the wall normal, facing within the same angle, wall within `probe_m`, at least
  `min_cover_height_m`, held `snap_hold_s` on the same wall, not while `InputFrame.sprint` (a full forward
  touch push is the sprint gesture, so it does not snap), not while Fire is held, not within
  `reentry_cooldown_s` after an exit (the cooldown starts when an exit reaches FREE via `reset()`).
- **Input lock and snap lerp.** ENTERING (the stick-ignoring state) lasts `enter_duration()`; the move onto
  the wall plane keeps easing (smoothstep on the wall-normal part, speed bounded) over `snap_lerp_s` from
  entry, also after the state has settled to IN_COVER (`movement_velocity`).
- **Data keys (stage 1):** `snap_hold_s` 0.25, `max_wall_angle_deg` 45, `probe_m` 0.7, `enter_s` 0.15,
  `input_lock_max_s` 0.15, `snap_lerp_s` 0.25, `reentry_cooldown_s` 0.4, `cover_button_range_m` 1.5
  (cover.json); `ui.json cover_button` (label and idle / valid / active alphas and border colours);
  `ui.json cover_buttons.hidden_slots` is now jump and sprint_lock (swap_shoulder removed so the Cover
  button can exit cover; stage 3 empties it); `haptics.json events.cover_snap` (category status).
- **LAN signal.** A LAN host's and a LAN client's own pawn both stay `NetMode.LOCAL`, so the gate is
  `MatchRoot.networked_match` (read-only, set in `begin` before the rig is attached), read by
  `Pawn.in_lan_session()` from the pawn's MatchRoot ancestor. On LAN `_ensure_cover` and `enable_cover`
  refuse, so there is no auto-snap and no Cover button (the slot keeps C1a's hidden Shoulder behaviour).
- **Haptic.** `Pawn._on_cover_entered` (connected to `entered` in `enable_cover`) plays
  `Haptics.play("cover_snap")` for both entries.
- **HUD mode source.** The touch HUD finds the pawn through the sibling `../GameHud` node's `pawn`
  (`_hud_pawn`); no GameHud or pawn = no Cover button (the slot stays Shoulder).
- Tests: `tests/test_cover_entry_c1b.gd`.

**Stage 2: the cover camera, the wall-hug pose and the automatic crouch.**
- **Camera modes.** `CameraRig.is_first_person()` is false only while the local pawn HOLDS cover: ENTERING,
  IN_COVER, PEEK_LEFT, PEEK_RIGHT (`_holds_cover`, also `in_cover_view()`). EXITING already wants first person
  (fix 32), so the exit blend starts with the exit, not 0.3 s later at FREE; the body / view-model swap stays at
  `first_person.view_model.show_weight` 0.6 (one physics frame, both ways) and the touch HUD's mode follows
  `is_first_person()`. Blend time: `camera.json cover_blend_s` (0.6) when the blend goes into cover or comes back
  from the cover pose (`_cover_w > 0`); `first_person.blend_s` (0.35) for carrier, falling and downed.
- **Cover pose.** The third-person end of the first-person blend is `lerp(today's pose, cover pose, _cover_w)`:
  spring length `cover.distance_m` (leaned out `out_distance_m`), side offset `cover.side_offset_m` (leaned out
  `out_side_offset_m`) times the eased cover side, pivot height `lerp(cover.height_m, cover.crouch_height_m,
  crouch_amount)`. `_cover_w` jumps to 1 / 0 only while the first-person weight is 1 (invisible), is HELD while
  an exit blends back to first person (so only the first-person weight moves: one move), and eases over
  `cover_blend_s` for cover -> another third-person mode (downed). Leaned out = PEEK_* or `aim_out_amount > 0`,
  eased over `cover.out_ease_s`. The side is `CoverController.side`, smoothstep over `cover.side_ease_s`; looking
  along the wall toward side s, the view's right is the wall normal times s, so `+offset * s` is always the open
  side. `swap_shoulder` / `set_shoulder_side` are ignored in cover (and in first person). FOV is unchanged.
- **No snap on exit.** The cover follow (`camera_follow_damping_s`) runs only while holding cover. When it stops
  (EXITING, or FREE directly: a lost wall, `reset()`, death) its lag (world metres) eases out over
  `cover_blend_s` (smoothstep) to the parent-exact pivot. The old snap of `position.x/z = 0` at FREE is gone.
- **The automatic look turn** lives in `pawn.gd` (the pawn's yaw IS the look yaw): `_on_cover_entered` ->
  `_begin_cover_turn` aims at `cover.tangent * cover.side` (along the wall toward the nearer open edge, picked in
  `CoverController._enter`), shortest way; `_tick_cover_turn(delta)` runs right after `_apply_look` and applies the
  smoothstep increments over `cover_blend_s`, in step with the rig's blend (one frame later; the turn starts on the
  tick after `entered`). Look input is never locked (0 s, inside `input_lock_max_s`): any look delta above
  `cover.turn_cancel_look_deg` per physics frame calls `cancel_cover_turn()`, as do EXITING, FREE and death. Pitch
  is the player's; no turn on exit. API: `is_cover_turning()`, `cancel_cover_turn()`, `cover_blend_s()`.
  NOTE for stage 3: the stick is mapped through the pawn yaw, so after the turn a forward stick points ALONG the
  wall (today's controller then slides, peeks at the edge and exits on a held push); the fix 11 split owns this.
  Old-path tests that use view-relative stick inputs call `cancel_cover_turn()` at entry (the view stays on the
  wall) so they keep their meaning until stages 3 and 4 rewrite them.
- **Pose.** `CoverAnim` (only the visual model turns): in ENTERING / IN_COVER with `aim_out_amount == 0` the model
  faces `tangent * side * cos(a) + normal * sin(a)`, `a = cover.json animation.hug_out_deg` (30): along the wall
  toward the side, back and shoulder to the wall (90 = the old back-flat rule). Leaned out it returns to the pawn's
  facing as before. The view model stays hidden in cover by weight (below `show_weight`).
- **Automatic crouch** (`CoverController._update_crouch`): in ENTERING / IN_COVER / PEEK_*, `crouched =
  height_m < muzzle_height_m` from the probe facts every tick (`CoverProbe.sample`: the locked wall's top minus the
  pawn's feet; `stats.json movement.muzzle_height_m` 1.3), the rule `can_quick_draw` / `_tick_draw` already use. A
  tick without `height_m` keeps the stance; standing still waits for `stand_clear`; rising while drawn out is
  unchanged (crouch_amount 0 while out, back after). The probe locks one wall box, and the slide is clamped to
  that box's own ends, so today a slide cannot reach a section of another height; the rule follows any height
  change the probe reports (tested by resizing the wall). `toggle_crouch()` is a no-op (stage 4 removes it);
  in cover `Pawn.handle_action_press("crouch")` does nothing (cover owns the crouch); M2 H1c item 4 made the press
  toggle the free crouch outside cover (see "M2 H1c: the free crouch" under 4.15; it said a press outside cover does
  nothing). The InputFrame bits and router entries stay. The old cover Crouch button still draws and consumes its
  touch; its routed press reaches the pawn and does nothing.
- **Data keys (stage 2):** `camera.json cover_blend_s` 0.6 [Shibi default]; `camera.json cover`: `distance_m` 1.6,
  `side_offset_m` 0.55, `height_m` 1.45, `crouch_height_m` 1.05, `out_distance_m` 1.1, `out_side_offset_m` 0.4,
  `out_ease_s` 0.15, `side_ease_s` 0.3, `turn_cancel_look_deg` 0.05; `cover.json animation.hug_out_deg` 30. All
  OQ-COVER placeholders.
- Tests: `tests/test_cover_camera_c1b.gd` (prints `C1B CAMERA` lines with the per-frame camera maxima).

**Stage 3: moving and exiting.**
- **The stick split** (`CoverController.tick`, IN_COVER; decision 8, fix 11). The stick is mapped to world space
  through the pawn's yaw (the probe's `basis`, the look yaw), as normal movement is; after stage 2's entry turn the
  view looks ALONG the wall, so forward / back slide. Its along-wall (tangent) part slides at the probe's
  `slide_speed_mps`, clamped `edge_margin_m` short of the locked box's ends (`left_m` / `right_m`); its outward
  wall-normal part at or above `back_exit_min`, held `exit_away_hold_s`, exits (`_tick_away_exit`; a shorter push or a
  release restarts the hold); the into-wall part does nothing. The stick peek is gone: nothing enters PEEK_LEFT /
  PEEK_RIGHT from the stick, and the peek's continued-push exit is gone. The State enum keeps PEEK_*; a PEEK_* state
  (only tests set it now) returns to IN_COVER once no round is held and honours the away push. The quick draw still
  leans by itself at an edge (`_tick_draw`); while it is out or returning the stick is ignored, as before.
- **Exits, all through EXITING** (so every exit blends: the rig wants first person from EXITING, stage 2):
  1. the away push (above), in the controller;
  2. the Cover button (stage 1, `request_cover` in IN_COVER / PEEK_*);
  3. the Sprint lock: `Pawn._apply_movement` calls `CoverController.request_exit()` on the `InputFrame.sprint` rising
     edge. A lock already on at entry has no edge and does not exit. A hard stick push never exits (below);
  4. Jump (fix 14) [Shibi default]: the same call on `InputFrame.jump_just_pressed` (with `stats.json
     jump_enabled`); the jump velocity is applied above it, so the pawn exits and jumps;
  5. a vanished wall (item 5, fix 19): `CoverProbe` keeps the locked wall's instance id; a locked sample whose id is
     no longer valid (`is_instance_id_valid`, the freed body is never dereferenced) or whose body has left the tree
     returns `wall_gone: true`, and the controller calls `_begin_exit()` instead of counting a lost tick. Every other
     lost sample (pushed off the wall, the face ray missing, an untagged body) keeps the two-tick `reset()`.
  `request_exit()` accepts ENTERING, IN_COVER and PEEK_*. The re-entry cooldown (`reentry_cooldown_s`, auto-snap only)
  still starts in `reset()`, i.e. when FREE is reached, after every exit.
- **Sprint suppression in cover** (fixes 3, 24). `TouchProvider.cover_suppress_sprint`, set every `_process` (and on
  every touch-down) by `TouchHud._refresh_cover_slot` from the bound GameHud pawn's `in_cover()` (any non-FREE state,
  read-only). While true, `is_sprinting()` ignores the stick's forward-extreme detector, so a hard push slides and
  `InputFrame.sprint` stays false; `sprint_locked` and `lock_target_visible()` are untouched, so the Sprint lock button
  and the release-on-target lock stay reachable and are the sprint exit. One frame of lag at entry is harmless (no
  rising edge reaches IN_COVER). InputFrame.sprint stays one bool; there is no desktop sprint action.
- **Lock durations** against `input_lock_max_s` 0.15 (`CoverController.lock_durations()`, asserted in the tests):
  ENTERING ignores the stick for `enter_duration()` = min(`enter_s`, cap) = 0.15; EXITING lasts `exit_duration()` =
  min(`exit_s`, cap) = 0.15 (`exit_s` was 0.3) and ignores the Cover button and auto-snap and blocks Fire; it never locks
  the stick, the look, Jump or the Sprint lock (`movement_velocity` is the free wish); the draw out / back
  (`aim_out_s` 0.15 / `aim_return_s` 0.15) and the peek settle (`peek_s` 0.15) ignore the stick. `cover_anim.gd`'s exit
  pose reads `exit_s` too (now 0.15). The camera's exit blend is `cover_blend_s` 0.6, independent of EXITING.
- **Auto-snap and sprint switch**: `cover.json auto_snap_blocked_by_sprint` (true = the spec: a full forward touch
  push is the sprint gesture, so it never auto-snaps, only a partial push does; false lets a sprinting push snap).
- **No buttons change under the thumbs** (decision 3, fixes 26, 28): `ui.json cover_buttons.hidden_slots` is `[]`, so
  Jump, the Sprint lock and the Cover button stay visible and usable in cover. `GameHud.bind` no longer creates or binds
  `CoverCrouchButton` / `CoverFireButton` (their fields are gone from hud.gd). `TouchHud.set_cover_controls_active` /
  `is_cover_slot_hidden` are inert (nothing calls the setter; the list is empty). Until stage 4 there is no way to fire
  in cover from the touch HUD (accepted); the HUD's general "fire" press now reaches the pawn in cover too, where
  `Pawn._apply_weapon` still ignores it (only `quick_draw_trigger` fires in cover).
- **Data keys (stage 3, cover.json, OQ-COVER):** `exit_away_hold_s` 0.15 (new), `back_exit_min` 0.6 (now the away
  threshold), `exit_s` 0.15 (was 0.3), `auto_snap_blocked_by_sprint` true (new), `_c1b_stage3_todo`. Removed (only the
  stick peek read them): `peek_stick_min`, `exit_stick_min`, `exit_hold_s`. `ui.json cover_buttons.hidden_slots` [].
- **Left for stage 4** (the old path): `scripts/ui/cover_fire_button.gd`, `scripts/ui/cover_crouch_button.gd` (class
  files, unreferenced by the game); `ui.json cover_fire`, `cover_crouch` and the rest of `cover_buttons`; touch_hud's
  `cover_controls_active`, `_cover_hidden_slots`, `set_cover_controls_active`, `is_cover_slot_hidden` and their uses
  (`_refresh_button_visibility`, `get_element_keys`, `_on_down`, `_button_at`, `_sync_fire_action`);
  `CoverController.quick_draw`, `quick_draw_trigger`, `round_fired`, `set_look_active`, `_quick_held`,
  `_buffered_round`, `_look_active`, `toggle_crouch`, the `peeked` signal and `_anchor` / `_peek_target`; `Pawn
  handle_action_press / release / look("cover_fire")` (stage 4 makes it a no-op); `InputRouter.NON_FRAME_ACTIONS`
  "cover_fire" and `TouchProvider.release_action` / `set_action_look` (keep the plumbing, fix 4); docs/CONTROLS.md
  "In-cover controls". Tests that still drive the routed "cover_fire" press: `test_cover_fire_fix.gd`,
  `test_cover_fire_path_a2.gd`, `test_cover_fire_input_d2.gd`, `test_cover_crouch.gd`, `test_cover_pawn.gd`.
- Tests: `tests/test_cover_move_exit_c1b.gd` (prints `C1B MOVE_EXIT` lines with the per-frame camera maxima).

**Stage 4: Fire in cover, Aim hold and removal of the old path** (decisions 3-6, 9; fixes 4, 7, 9, 15, 16, 21). The
"Left for stage 4" list above is done: everything on it is removed or made a no-op as listed below.
- **Fire is the frame's fire bit.** `Pawn._apply_weapon` no longer ignores `InputFrame.fire_pressed` in cover: the
  trigger is `CoverController.fire_trigger(fire_pressed)` whenever the controller exists (FREE: the held Fire or a
  press buffered through EXITING; in cover: the held Fire or a buffered press, only while `blocks_fire()` is false).
  So the right Fire button, Left Fire, mouse, keyboard and gamepad fire all work in cover. `round_fired()` (any state)
  answers the buffered press. The muzzle / pose guard that restores a blocked semi or burst round is unchanged.
- **Out: the lean and the rise** (`CoverController._tick_out`, from IN_COVER only). Wanted (`_wants_out`) while the Aim
  toggle is on, Fire is held, a press is buffered, `_stay_out_left` > 0 or the weapon still owes a round (`weapon_pending`:
  a burst or an armed semi), and never while `weapon_ready` is false (empty magazine or reloading). Possible
  (`can_go_out`) behind LOW cover (`height_m` < `muzzle_height_m`) anywhere, or behind HIGH cover with an open edge
  (`usable_left_m` / `usable_right_m`) within `lean_reach_m`. HIGH: `side = lean_side(wish)` (the open edge; with both
  in reach the stick's along-wall direction, else the nearer one), the state becomes PEEK_LEFT / PEEK_RIGHT and the
  target is the anchor plus `tangent * side * (usable + peek_offset_m)`; CoverAnim's peek poses, the camera's "out"
  pose and the camera side (it follows `side`) apply. LOW: the state stays IN_COVER and the soldier rises in place
  (`crouch_amount` to 0 over `aim_out_s`, back over `aim_return_s`, then `crouch_blend_s` again). `aim_out_amount`
  eases out over `aim_out_s` and back over `aim_return_s`; `aimed_out` (refreshed after the move,
  `refresh_completed_pose`) needs the amount at 1, standing and the pawn at the target. When the return reaches the
  anchor the state goes back to IN_COVER. While out the slide is ignored; the away push, Cover, Jump and the Sprint lock
  exit as in stage 3 (`_begin_exit` ends the draw).
- **Fire gating.** `blocks_fire()`: in any cover state a round leaves only when `aimed_out` and the probe's
  `shot_clear` (the full-range wall ray, refreshed after the move) are both true; no blind fire. `fire_available()`
  (read-only, through `Pawn.cover_fire_available()`) is false only in ENTERING / IN_COVER when no lean or rise is
  possible (fix 7, [Shibi default]): there Fire does nothing and no ammo is spent.
- **The press buffer** (`_buffer_fire`, `_fire_buffered`). The rising edge of `fire_pressed` (the controller keeps
  `_fire_was`) is buffered in ENTERING and EXITING, and in IN_COVER / PEEK_* when out or able to go out; it is dropped
  when ENTERING settles where no lean or rise is possible, when the weapon is not ready, and when the completed pose's
  wall ray is blocked (so a press never holds the soldier out by itself). EXITING hands it to FREE (kept through the
  `reset()` at the end of EXITING; cleared on the next FREE tick). ENTERING and EXITING each last at most
  `input_lock_max_s`.
- **Release and the stay-out delay.** While Fire is held or a press is buffered, `_stay_out_left` =
  `fire_return_delay_s`; after the release it counts down and then the soldier returns, so quick taps do not bob. Aim
  on, or any along-wall stick push, sets it to 0 (Aim holds out by itself; the stick is never locked by the delay).
- **Empty magazine** (decision 9): the round that empties the magazine fires; the existing `combat.auto_reload_on_empty`
  in `_apply_weapon` starts the reload (reused); `weapon_ready` (new probe fact: `has_ammo()` and not `reloading`) is
  then false, so the soldier returns even with Fire or Aim held, and goes out again when the reload ends and Fire or
  Aim is still held. With no reserve it just returns.
- **No recoil, no camera knockback in cover** (decision 6, fix 15): the recoil skip in `_apply_weapon` stays;
  `Pawn._kick_camera` returns while `in_cover()`. The `fired` / `shot` signals (view model and soldier visual kick)
  are unchanged. Outside cover the knockback is unchanged (`tests/test_camera_knockback.gd`).
- **HUD** (decision 5, fixes 7, 9). `TouchHud._sync_fire_action` presses "fire" for the right Fire and Left Fire
  buttons (and, in Simple mode, the HUD auto-fire), in and out of cover alike; since M2 H1a a look-area touch never
  fires, so there is no cover special case in it (see "M2 H1a: shooting modes and touch layout" in 4.15).
  `TouchHud.set_fire_dimmed` (from `_refresh_cover_slot`: in cover and not
  `Pawn.cover_fire_available()`) restyles both Fire buttons with `ui.json cover_fire_dim`; they stay pressable.
- **Removed:** `CoverController.quick_draw`, `quick_draw_trigger`, `can_quick_draw`, `set_look_active`,
  `toggle_crouch`, `_tick_draw`, `_quick_held`, `_buffered_round`, `_look_active`, `_round_hold`, `_trigger_held`,
  `_anchor`, `_peek_target`, `_peek_complete`, `_returning` and the unused `peeked` signal; the probe facts
  `weapon_hold_s` / `weapon_repeats`; `TouchHud.cover_controls_active`, `_cover_hidden_slots`,
  `set_cover_controls_active`, `is_cover_slot_hidden` and their uses; `ui.json cover_fire`, `cover_crouch`,
  `cover_buttons`; `cover.json fire_requires_peek`, `quick_draw_stay_out`, `cover_edge_quickdraw_m` (renamed
  `lean_reach_m`). `peek_s` is no longer an input lock (only CoverAnim's peek clip length). Kept as no-op plumbing
  (fix 4): `Pawn.handle_action_press("cover_fire")` (and "crouch" in cover; M2 H1c: outside cover it toggles the
  free crouch) return at once, `handle_action_release` /
  `handle_action_look` do nothing; `InputRouter.NON_FRAME_ACTIONS` "cover_fire", the InputFrame bits,
  `TouchProvider.release_action` / `set_action_look` and match_root.gd are unchanged. Files to delete (unreferenced):
  `scripts/ui/cover_fire_button.gd`, `scripts/ui/cover_crouch_button.gd` (+ .uid), `tests/test_cover_fire_input_d2.gd`
  (+ .uid).
- **Data keys (stage 4, cover.json, OQ-COVER):** `aim_out_s` 0.12 (was 0.15), `aim_return_s` 0.15,
  `fire_return_delay_s` 0.2 (new), `lean_reach_m` 0.5 (renamed), `_c1b_stage4_todo`; `ui.json cover_fire_dim`
  (`bg_alpha` 0.08, `border_color`, `font_alpha` 0.3). `lock_durations()` lists `enter_s`, `exit_s`, `aim_out_s`,
  `aim_return_s`, all <= `input_lock_max_s`.
- Tests: `tests/test_cover_fire_c1b.gd` (prints `C1B FIRE` and `C1B FIX21` lines).

**C1b cover, final description.**
- **States:** FREE; ENTERING (the snap, at most `input_lock_max_s`, the stick ignored, Fire buffered); IN_COVER (slide,
  automatic crouch, the rise over LOW cover); PEEK_LEFT / PEEK_RIGHT (the lean past an edge of HIGH cover, Fire or
  Aim only); EXITING (at most `input_lock_max_s`, the free wish moves the pawn, Fire buffered to FREE). Every exit goes
  through EXITING; the camera blends both ways over `camera.json cover_blend_s`.
- **Controller API.** Mutators, called only by `Pawn` (`tests/test_crouch_guard_d1.gd`): `tick(delta, move,
  fire_pressed, probe, aiming, sprinting)`, `request_cover(probe)`, `request_exit()`, `round_fired()`,
  `refresh_shot_clear(clear)`, `refresh_completed_pose(position)`, `movement_velocity(...)`, `reset()`. Read-only
  (UI may read them): `state_name`, `blocks_fire`, `fire_trigger`, `fire_available`, `can_go_out`, `lean_side`,
  `enter_duration`, `exit_duration`, `lock_durations`, `can_enter_by_button`, and the fields `state`, `side`,
  `crouched`, `crouch_amount`, `aim_out_amount`, `aimed_out`, `normal`, `tangent`. Signals `entered`, `exited`.
- **Pawn hooks:** `_ensure_cover` (local, offline, no Brain), `handle_action_press("cover")`, `cover_button_available`,
  `cover_button_valid`, `in_cover`, `cover_fire_available`, the entry turn (`_begin_cover_turn`), `_apply_body_shapes`
  (capsule and Head follow the crouch; M2 H1c: the one shape writer, was `_apply_cover_shapes` + `_apply_life_shapes`), `_apply_movement` (Sprint-lock and Jump exits, the tick), `_apply_weapon`
  (the trigger, no recoil), `_kick_camera` (no knockback in cover).
- **HUD wiring:** the Shoulder slot is the Cover button on the ground (`ui.json cover_button`); in cover the stick's
  forward extreme does not sprint (`TouchProvider.cover_suppress_sprint`); only the Fire buttons fire; the Fire buttons
  dim where Fire is unavailable. No other button changes in cover.
- **Data:** `data/cover.json` (every C1b key, OQ-COVER), `data/camera.json` (`cover_blend_s`, `cover`),
  `data/ui.json` (`cover_button`, `cover_fire_dim`), `data/haptics.json` (`cover_snap`); read-only
  `stats.json movement.muzzle_height_m` and `combat.auto_reload_on_empty`. See docs/OPEN_QUESTIONS.md OQ-COVER (M2 C1b).

### 4.22 Soldier and view-model art and animation (M2 AN1, M2 AN2, M2 AN3)
Everything here is presentation: no collider, hitbox, muzzle, speed, ray, timing or net message reads it. Every
look is a trial for Shibi (OQ-ART-SOLDIER), not a design decision. Since M2 AN2 the soldier, the first-person
arms, the three weapons and most clips are built in Blender by scripts; the code-built paths below stay as the
fallback when a `mesh_source` is empty or a clip is missing.
- **Blender pipeline** (`tools/blender/`, Blender 5.3, bundled glTF exporter). Every file is written by a script
  from numbers; there is no .blend file and no hand edit. `gladius_bl.py`: the shared glue (`EXPORT_SETTINGS`,
  every exporter option named; `reset_scene`; `soldier_armature`, the 22-bone rig from the data rests;
  `godot_to_blender` axes; `update_manifest`). Builds are byte-identical over runs and output paths. Scripts and
  outputs: `build_pipeline_proof.py` -> `characters/pipeline_proof.glb` (the pipeline test asset);
  `build_soldier.py` (+ `soldier_geom.py`, `soldier_data.py`, `soldier_design.json`) -> `characters/soldier.glb`;
  `build_soldier_clips.py` (+ `soldier_clips_design.json`) -> `characters/soldier_clips.glb`;
  `build_soldier_directional.py` -> `characters/soldier_directional.glb`;
  `build_soldier_keyed.py` -> `characters/soldier_keyed.glb`; `build_soldier_rifle.py` (M2 AN3) ->
  `characters/soldier_rifle.glb`; `build_view_arms.py` (+ `view_geom.py`,
  `view_bl.py`) -> `characters/view_arms.glb`; `build_weapons.py` (+ `weapon_geom.py`) ->
  `weapons/pilum_br.glb`, `sagittarii_rifle.glb`, `gladius_lux.glb`; `build_view_clips.py` ->
  `characters/view_clips_<weapon>.glb` (all under `assets/generated/`, each with its own `.glb.import`). Each
  script records its output in `tools/blender/manifest.json` (`made_by`, `derived_from`: the UAL id for
  `soldier_clips.glb`, empty otherwise); `tools/asset_hashes.gd` copies that ledger into `data/asset_catalog.json`
  `generated`, and `tests/test_generated_assets.gd` pins that every generated .glb has its script. Rebuild one
  file: `blender.cmd -b --factory-startup --python tools/blender/<script>.py -- [--out=<repo path>]`
  (`build_weapons.py` takes `--only=<id> --out-dir=<dir>`, `build_view_clips.py` `--only=<ids>`), then
  `godot --headless --path . --script res://tools/asset_hashes.gd -- --write` and an import pass
  (`godot --headless --path . --import`). Scripts read the game data (rests, parts, anchors, anim.json stages) so
  the data stays the source of truth.
- **Data.** `data/art_soldier.json` (new) owns the hand, weapon and effect art, the soldier override layer and
  the budgets. `data/art_astra.json` is NOT edited by character work: it is hashed into every map's saved
  navigation (`map_nav.gd`). Animation numbers: `data/anim.json` `first_person` (view-model motion) and
  `data/anim_third_person.json` (gait, strafe, crawl, hit, cover arm pose, the foot-slide limit), which
  `SoldierRig.config()` merges over `data/anim.json`.
- **View model** (`scripts/visual/view_*.gd`). Meshes: each weapon's `mesh_source` (`art_soldier.json`
  `weapons.<id>.mesh_source`) names its Blender .glb, whose nodes are `Mesh` (first person, one primitive per
  shading pass), `Cell` and `Charge` (the energy cell and charging handle, own nodes), `ThirdNear` / `ThirdFar`
  (the third-person gun) and the empties `Muzzle`, `SightAnchor`, `Dot` (copies of the data anchors, which stay
  the source of truth; `test_view_glb.gd` compares them). `view_mesh.gd` (`glb_nodes`, `from_glb`) puts the
  game's shader on each pass; `view_weapons.gd` takes `Mesh` / `Cell` / `Charge` from the .glb. The arms:
  `hands.mesh_source` -> `view_arms.glb` (an armoured gauntlet over a glove, 18 bones, up to four weights),
  remapped by bone name onto the arm skeleton `view_rig.gd` still builds from data; the left arm is the right
  one mirrored; finger poses stay data (grip, trigger, foregrip, open, reach, blade). An empty `mesh_source`
  builds the old part lists (chamfered boxes, lathes, faceted fingers). Motion: `view_motion.gd` (4.16) plays
  the keyed clips of `view_clips_<weapon>.glb` (an action-only "ViewRig": Weapon, Cell, Charge, both hands, 15
  finger bones per side and two elbow targets; reload keyed on `anim.json` `reload.stages`, pickup on
  `pickup.swap_at`) where `data/anim.json` `first_person.clips.enabled` says so: reload, switch, pickup, blade
  swing and the ADS path now; idle, walk, sprint and fire stay procedural (their clips ship and are tested).
  `ViewRig.apply_clip` drives the parts and arms from the clip; `ViewHands.aim_forearm` still aims each forearm
  at the clip's elbow. `view_fx.gd` holds the flash, which is parented
  to the muzzle and follows the gun, a shadowless OmniLight3D lit for the flash time on the local view model
  only, the world-fixed tracer that starts at the muzzle, and the spent cell; `view_probe.gd` measures posed
  vertices for the tests. Pickup is told apart from switch inside the view code by comparing the loadout's slot
  objects on `weapon_switched`; `pawn.gd` has no hook for it.
  CX1 keys a lower support elbow and keeps the rifle canted during the charging stage. Sprint settles back
  to ready over 0.28 s, and the landing dip carries a small counter-pitch on recovery. The interior wrist cuff
  rings follow a bone that takes half the forearm bend. The hand and forearm retain their original aim transforms.
- **Soldier mesh.** `art_soldier.json` `soldier.mesh_source` -> `soldier.glb`: one armature of 22 bones (the 17
  of `anim.json` plus LeftToes, RightToes, LeftFingers, RightFingers and Prop from
  `anim_third_person.json` `bones_add`; identity rest bases) and two skinned LODs, `SoldierNear` (2,536
  triangles) and `SoldierFar` (1,152), with blended weights at the joints and rigid armour plates; vertex colour
  and UV2 surface ids, no texture. `SoldierRig.build` keeps the skeleton built from data, remaps the .glb joints
  by bone name and caches the meshes per rest signature; `SoldierModel.armor` (near, ends at `gun.far_m`, 30 m)
  and `armor_far` ("ArmorFar", begins there) share one skin and one custom AABB. The part boxes (`part_bones`,
  meta "parts") stay computed from the part data and are the tested proxy: `test_soldier_glb.gd` ties the mesh to
  them (helmet round the head sphere, rests and bind poses within 1 mm). An empty `mesh_source` builds the old
  merged-parts mesh (one LOD). The corpse keeps the near mesh. CX1 opens the lower spaulder lames and weights
  them nearer the cuirass. The cape's hem sits higher and farther behind the hips, with less inward sway while downed.
  The glove-side cuff ring follows the hand and the sleeve-side ring follows the forearm, preserving their cross-sections.
- **Soldier animation.** `clip_library.gd` resolves each logical clip from `data/anim_sources.json` in the
  order `blender`, `actionforge`, `ual`, `mixamo_local`. `blender` = `soldier_clips.glb` (the CC0 Quaternius
  UAL clips retargeted in Blender onto the soldier rig, feet and loops cleaned, shipped baked: idle, walk, jog,
  sprint, jump, crouch idle and move, hit chest and head, death, revive kneel, blade swing) and
  `soldier_keyed.glb` (hand-keyed: cover hug high and low, lean left and right, rise, enter and exit with left
  copies, ladder up, down and top, door open, chest open, ground pickup). A clip on the soldier's own rig is
  copied as authored (`AnimRetarget.same_rig_clip`); the UAL source (`assets/third_party/quaternius_ual/`,
  imported without the mannequin) is only the fallback, retargeted at runtime by `anim_retarget.gd` when no
  `blender` clip resolves. `soldier_clips.gd` measures each gait's stride on the soldier's legs, so the graph
  plays ground speed / stride and the feet stay planted; every soldier shares the clips. Still code-built:
  third-person aim and fire (hands on the gun through the upper layer and the left-hand IK; the code-built
  reload is now the fallback behind the keyed one, below), the downed
  knee-crawl (`soldier_crawl.gd`) and landing. CX1 adds hand-authored sidesteps and back-pedal on the same rig.
  The clips start at the same foot contact and use the authored cycle distance in `anim_sources.json`.
  The lateral and backward blend points use the existing movement ratio, so full-speed cardinal motion shows
  the complete cycle. The turned and reversed jog serve as fallbacks. `test_soldier_directional.gd` checks the
  resolved clips, live stance drift and head motion in all three directions.
  Cover: `cover_anim.gd` asks for the keyed clip per state and falls back to the old procedural pose.
  Actions: `SoldierPose` has an action layer; `SoldierModel.drive_actions` plays the ladder clips from
  `pawn.climbing` (clip time from the feet's height on the ladder, the gun slung) and `ladder_top` after the
  top step. The Blender opening key matches the nominal ladder's exit phase. The top step starts from the last
  drawn climb pose in world space and blends into the keyed motion over `keyed.ladder.top_handoff_s`.
  `SoldierModel.play_action(&"door_open" | &"chest_open" | &"pickup_ground")` is the entry point for
  the rest, but no gameplay signal calls it yet (OQ-ANIM-ACTIONS). `soldier_gait.gd` limits the pelvis bob and
  re-solves the legs around the same foot targets, with hip steering for the fallback jog variants.
- **Head and body (M2 AN3, the bobblehead fix; OQ-ANIM-HEAD).** Cause [measured, `tools/head_motion_measure.gd`]:
  the gait clips pitch the pelvis forward (jog 22, sprint 41 degrees) under a helmet pinned to the head hitbox, so
  the chest top swung ahead of the neck; in the drop the run cycle started under the fall pose in one frame. Fix,
  the body follows the head: `soldier_gait.gd` keeps `hips_keep` of the clip's pelvis pitch and roll, turns the
  Spine by at most `torso_reach_max_deg` so the chest top sits under the neck (stretch up to
  `torso_stretch_max_m`; `neck_drop_max_m` 0, `leg_reach`, feet goals unchanged); `soldier_neck.gd` (new
  `SoldierNeck`, the last body modifier, before the hand sync) turns the Neck about the head hitbox centre toward
  the chest top, clamped per axis (`neck_max_deg`, `head_max_deg`, `neck_tilt_max_deg`, `exceptions.cover_crouch`),
  first-order low-pass (`neck_smooth_s`, at most `neck_max_rate_dps`), no spring; `SoldierModel` rate-limits the
  locomotion blend (`blend_max_rate`) and holds it at 0 while falling; `SoldierPose` turns fall, land and lean about
  the head hitbox centre (`fall_pivot_head`, `offset_moves_head`); `CoverAnim` fades its mixes
  (`cover_mix_fade_s`, `cover_rest_fade_s`); the corpse returns the chest to its rest offset. All numbers:
  `data/anim_third_person.json` `head` (placeholders; `limits` is what the test asserts). `SoldierRig.head_legacy`
  (tools: `--legacy-head`) restores the old behaviour. Gap max before -> after [measured]: idle 0.035 -> 0.010,
  jog 0.191 -> 0.060, sprint 0.340 -> 0.047, fall and land 0.286 -> 0.084 m; helmet off the hitbox 0.06-0.135 ->
  0.000 m upright. Test: `tests/test_soldier_head_motion.gd`. The fall's limits were fitted to the measured result
  (`head._limits_note`: 30.99 deg vs 32, 0.0843 m vs 0.09).
- **Crouched low-cover hug (M2 AN3 review fix).** `test_crouched_cover_hug_ramped` ticks the real `CoverController`
  with a low-wall probe, so `crouch_amount` ramps over `cover.json` `crouch_blend_s` and the head hitbox lowers with
  it, then rises over the wall (Aim, `aim_out_s`) and back. Cause found: CoverAnim showed the cover crouch at its
  layer's fade times `crouch_amount`, so entering low cover the helmet lagged the lowering hitbox (0.088 m) and the
  hunch turned at up to 841 deg/s; `CoverAnim._show_crouch` now divides the crouch blend by the layer's weight while
  it fades in (settled poses unchanged). Ramped rise [measured; legacy and after by `cover_rise_ramped`, before this
  fix by the test at fc6a118], legacy -> before this fix -> after: gap max 0.133 ->
  0.068 -> 0.069 m, helmet off the hitbox 0.000 -> 0.088 -> 0.000 m, neck-chest rate 726 -> 936 -> 709 deg/s,
  neck-chest 75.6 -> 88.3 -> 88.6 deg (within `exceptions.cover_crouch`). The rate cannot stay under 650: the rise
  sweeps about 82 deg of hunch in `aim_out_s` (0.12 s, gameplay), 681 deg/s on average, the legacy path too (726), so
  `exceptions.cover_crouch.neck_chest_rate_max_dps` is 750 (`head._exceptions_note`). The tool's old `cover_crouch` /
  `cover_rise` states snap the crouch (0.136 m, 1357 deg/s); `cover_crouch_ramped` / `cover_rise_ramped` do not.
- **Low-cover squat (M2 CX1).** `build_soldier_keyed.py` bakes a staggered, wall-side squat and its mirror
  into `soldier_keyed.glb`. The hip moves into the wall and the torso stays over the boots. The rifle sits
  diagonally across the front with clearance from the chest and wall. During the free-crouch handoff, SoldierGait
  pins the neck to the live Head height and keeps the shoulders under it while preserving the solved foot goals.
  The cover layer, controller timings and head limits keep their existing values.
- **Tool and debug switches, default off, not gameplay** (static vars; nothing in the game sets them):
  `SoldierRig.head_legacy` (the pre-AN3 head and body; `--legacy-head` in `head_motion_measure.gd`,
  `soldier_capture.gd`, `cover_capture.gd`, `drop_capture.gd`, `anim_cost.gd`), `SoldierPose.measure_off` and `CoverAnim.measure_clip_neck` (per-source attribution in
  `tools/head_motion_measure.gd` only), `SoldierModel.code_built_reload` (the code-built reload; capture
  `--code-reload`).
- **Free crouch (M2 AN3, M2 FIX1, M2 CX1).** `SoldierModel._drive_crouch` shows the free crouch beyond the cover
  crouch amount, capped by the remaining weight outside the cover layer. `CoverAnim._show_crouch` shows the cover crouch, divided by
  the layer's weight while it fades in (`head.cover_mix_fade_s`), so the helmet is lowered once. (The AN3
  `has_method(&"crouch_amount")` fallback is gone: every Pawn has it since H1c.) `SoldierModel.crouch_amount()` is
  `pawn.crouch_amount()`, read-only. Out of cover the lower body blends to the existing `cover_crouch_idle` /
  `cover_crouch_move` clips (idle to moving by ground speed, cycle matched to speed; nothing new keyed).
  `head.free_crouch` keys: `nominal_head_drop_m` 0.9 (measured: standing Head rest 1.75 - cover.json
  `crouch_head_y_m` 0.85), `hips_drop_per_head`, `move_full_mps`, `reach_max_deg`. Tests (real pawn):
  `tests/test_soldier_crouch.gd`, and in `tests/test_soldier_head_motion.gd` the free crouch down / up and the
  free-crouch-to-low-cover hand-off (printed, not asserted: open finding, OQ-ANIM-HEAD). `tools/head_motion_measure.gd` and
  `tools/soldier_capture.gd` drive the real pawn's free crouch amount and update its body shapes.
- **Downed crawl and revive (M2 CX1).** The existing SoldierCrawl modifier offsets the shoulders and elbows
  in opposition to the knee cycle. The arm motion eases out when the pawn stops. During revive, SoldierModel
  hides the held weapon mesh at half pose weight so both hands can work clear of the weapon. Visibility
  returns as the revive pose blends out. The active loadout stays available throughout.
- **Stationary pivot (M2 CX1).** SoldierGait keeps the support boot in world space while the pawn turns. The
  other boot lifts, moves toward the new heading after clearing the ground, and settles before taking load.
  The existing leg solve reaches both targets. The contact and upright head limits are checked on steady turns
  and fast reversals in `test_soldier_turn_in_place.gd`. Moving off fades the held feet and the hip clamp back
  to the clip over `gait.pivot.release_s`; the same file checks that walking off a turn moves the feet no more
  per frame than a still start.
- **Keyed rifle reload (M2 AN3; OQ-ANIM-RELOAD).** `build_soldier_rifle.py` writes `soldier_rifle.glb`: one staged
  reload per gun (`reload_pilum_br`, `reload_sagittarii_rifle`), 50 frames at 30 fps, starting and ending on the
  aimed pose (a port of `SoldierRig.arm_rotations`) with the left hand on that gun's foregrip; stage times, cant
  and chest lean are the code-built `upper_body.reload_*` numbers, the left-hand points (foregrip, magazine =
  `weapons.<gun>.cell.at`, charging handle = `charge.at`, belt pouch) are `upper_body.reload_keyed`; UpperArm
  position keys carry the shoulder offset (slot `"positions"` in `anim_sources.json`, kept by
  `AnimRetarget.same_rig_clip`). `SoldierModel.play_reload` plays `reload_<shown gun>` first, via
  `SoldierAnimation.resolve_reload`: scaled to `WeaponDef.reload_s` and cut to the code-built reload's tracks (no
  new bones move); the code-built reload is the fallback (`SoldierModel.code_built_reload`, capture
  `--code-reload`). Its `.glb.import` turns the animation optimizer off (`_subresources` nodes
  `PATH:AnimationPlayer` `optimizer/enabled` false): the default optimizer dropped keys. Measured
  (`tools/rifle_hands_measure.gd`), code-built -> keyed: Pilum start error 0.134 -> 0.000 m, snap when the hand IK
  resumes 0.136 -> 0.0096 m; Sagittarii 0.171 -> 0.020 m and 0.156 -> 0.0048 m. The Sagittarii's foregrip is 2 cm
  out of the left arm's reach in the aimed pose too (the IK leaves the same gap). Aim and fire stay code-built.
  Test: `tests/test_soldier_rifle_glb.gd`.
- **Soldier look.** `soldier_look.gd` lays `art_soldier.json` `soldier.part_overrides` and `parts_add` over the
  art_astra soldier parts (these feed the part boxes and the code-built fallback), writes per-class metallic and
  roughness into the soldier material's own copy of the surface data (one surface), and gives the hands the
  active weapon's third-person gun: `ThirdNear` from its .glb (`_glb_gun`), swapped to `ThirdFar` beyond
  `gun.far_m` by visibility range (the part lists only when the weapon has no `mesh_source`). The third-person
  flash and tracer keep their older origin, which `tests/test_soldier_hands.gd` locks.
- **Impacts.** `scripts/visual/shot_impacts.gd`: one pool per world, capped (`fx.impact_cap`), a burst per shot
  by surface (sparks, dust, energy on a soldier), classified like the impact sounds from a short visual probe.
- **Budgets** (`art_soldier.json`, unchanged by AN2): view model 4,000 triangles and 12 draw calls; soldier
  near 3,100 / 2, far 2,420 / 2; rig cap 40 bones (soldier 22), arm rig 50 (view rig 37). Measured at the AN2
  commits [measured]: view model Pilum 3,846 with the flash, Sagittarii 3,964, blade 2,818; soldier body 2,536
  near / 1,152 far plus the gun's `ThirdNear` (about 470-490) or `ThirdFar` (about 250-260). Desktop proxy, Nov
  16 2026 (RTX 3080, not a phone): `tools/anim_cost.gd`, 18 soldiers in mixed states, about 2.3-3.0 ms of
  main-thread animation per frame (about 130-165 us per soldier: model script 0.8-1.0 ms, AnimationTree
  0.4-0.6 ms, skeleton modifiers and IK 1.1-1.4 ms); `tools/frame_time.gd` on alesia_1km, 1509x648: 303 draw
  calls, render CPU 0.69-0.71 ms, GPU 0.87-0.89 ms. Frame time on the Fold is not measured. M2 AN3 (same desktop
  proxy, 18 soldiers, legacy head vs after): 2.58 vs 3.17 ms in one pair, 2.82 vs 3.11 ms in another, noisy on the
  shared machine; the phone cost is unknown. Both "after" figures are above the 2.3-3.0 ms band measured at AN2
  (the soldier gained a modifier, SoldierNeck): check the animation cost on the phone before more is added.
- **Tests** (AN1): `test_view_model_art.gd`, `test_view_motion.gd`, `test_view_combat_fx.gd`,
  `test_soldier_clips.gd`, `test_soldier_footslide.gd`, `test_soldier_budget.gd`. (AN2):
  `test_blender_pipeline.gd` (bone axes, weights, colour and UV2 through the importer), `test_soldier_glb.gd`
  (rig, rests, LODs, the part-box proxy), `test_soldier_clips_glb.gd` (played equals authored),
  `test_soldier_keyed_glb.gd` (cover, ladder and action clips, contacts), `test_view_glb.gd` (arms, weapons,
  anchors), `test_view_clips.gd` (rig and clips per weapon, reload length and stages, the cell in the hand, ADS end
  pose, the procedural fallback), and the made_by pairing in
  `test_generated_assets.gd`. (AN3): `test_soldier_head_motion.gd`, `test_soldier_crouch.gd`,
  `test_soldier_rifle_glb.gd`.
- **Tools:** `tools/fp_capture.gd` (AN2: `dense_*` states for clip sequences, `--every=N`, `--no-clips`),
  `tools/soldier_capture.gd` (AN2: `ladder_up`, `ladder_down`, `ladder_top`, `door_open`, `chest_open`,
  `pickup_ground`; `--procedural` for code-built before-captures), `tools/l1c_capture.gd` (`--ladder-seq`),
  `tools/cover_capture.gd`, `tools/contact_sheet.gd`, `tools/sheet_from_list.gd`, `tools/fp_light_cost.gd`,
  `tools/glb_inspect.gd`, `tools/anim_cost.gd` (AN2: animation CPU time for 18 soldiers; run `--headless`).
  AN3: `tools/head_motion_measure.gd` (head-to-body gap and neck angles per state, with per-source attribution),
  `tools/rifle_hands_measure.gd` (left hand to foregrip in aim and reload, keyed vs code-built);
  `soldier_capture.gd` gains `fall`, `fall_side`, `turn`, `crouch`, `crouch_walk`, `aim_sweep`,
  `reload_sagittarii`, `--legacy-head` and `--code-reload`.

## 5. Testing

- `tests/run_tests.gd` (`extends SceneTree`) finds `tests/test_*.gd` and runs every `test_*` method
  (may `await` frames). It prints PASS/FAIL lines and a summary, and exits non-zero on failure or if it
  finds no tests. It uses no addons.
- Rules tests construct rules objects directly with data dicts, with time and RNG injected.
- Scene tests instantiate scenes under the runner's root, step physics frames, and free them.
- Every rules system gets tests in the story that introduces it: damage, KotH scoring, spawns, then
  later economy, streaks and progression.
- CI (`.github/workflows/android.yml`) runs import → tests → debug export → artifact upload.

## 6. How to add things (data only)

| Add | Where | Code needed? |
|---|---|---|
| Class | `stats.json` `classes` | Only for a new `skill` id |
| Weapon | `stats.json` `weapons` (+ model path) | Only for a new `kind` |
| Tier / scope / attachment | `tiers.json` / `scopes.json` / `attachments.json` | No |
| Grenade | `grenades.json` | Only for a new `behavior` |
| Deployable | `deployables.json` | Only for a new `behavior` |
| Scorestreak | `scorestreaks.json` | Only for a new `behavior` |
| Faction | `factions.json` | No (art only) |
| Mode variant | `modes.json` with existing `rules` | No |
| New mode | `modes.json` + rules script + registry line | Yes, isolated |
| Bot profile | `bots.json` `profiles` | No |
| Map | `maps/<id>.json` + scene with matching markers (+ its own piece files); pick it in `map_select.json` | No |
| Cosmetic / medal / rank | `cosmetics.json` / `medals.json` / `progression.json` | No |
| Graphics preset | `graphics_presets.json` | No |

## 7. Build note: tying a debug APK to a commit

The Android preset in `export_presets.cfg` carries `version/code` and `version/name` (currently `0.1.0`). Those
do not change per commit, so the APK itself does not record its commit. When you keep a debug APK
(`build/gladius-debug.apk`, not committed), record next to it:

```
git rev-parse HEAD        # full commit SHA the APK was exported from
```

and note it together with `version/name` (for example in `build/status.txt` or your test log):
`gladius-debug.apk  version/name=0.1.0  commit=<sha>`. Export from a clean tree (`git status`) so the SHA is exact.
