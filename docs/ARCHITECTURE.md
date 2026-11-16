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
  (D1: the in-cover Crouch control); prone and interact are reserved (action plus InputFrame bit, no
  behaviour or bindings yet); later melee, grenade, deployable, streak and command pages.
- One-shot presses (D1): a provider's `trigger_action(action)` emits `action_triggered`; the router
  re-emits it at once and latches one pressed+just_pressed frame edge (even for a sub-tick tap).
  MatchRoot forwards it to the local pawn (`handle_action_press`), which toggles cover crouch. The
  frame bit is transport only until the host-side cover slice, so the pawn never toggles from it.
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

### 4.15 HUD and touch HUD
- `hud.tscn`: presentation only. Binds to signals from MatchDirector (or its replicated mirror on
  clients) and the local pawn. Classic Halo layout, red/gold theme (`theme.tres`), Roman numerals via
  `roman_numerals.gd` (off by default, OQ-38). The radar (25 m, cover-crouch hide) is built (M2 H1b, below). Later: prone hide, jammer blanking, smoke animation,
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
- Layout version: `layout_editor.layout_version` (2) is stored as `hud_layouts.version`. On load `SaveService` resets an
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
  above_row; it hooks Swap, Cover / Shoulder and Interact in `touch_hud.gd`, `fire_mode_button.gd`, `interact_button.gd`
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
  `first_person`, durations `swap_s`, `swing_s`, `recoil_s` here), draws its own tracer and flash from
  `ShotFx.shot_shown`, and raises the gun to a red dot on the centre ray in ADS; the long rifle's ADS looks
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
  - `"backdrop": false` (honoured by `ArtBuilder`, `backdrop_wanted`): the outer wall and the
    fields are the edge; a backdrop for 1 km is W1's job.
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
  `Pawn.handle_action_press("crouch")` returns at once (outside cover the old toggle never acted either). The
  InputFrame bits and router entries stay. The old cover Crouch button still draws and consumes its touch; its
  routed press reaches the pawn and does nothing.
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
  (fix 4): `Pawn.handle_action_press("cover_fire")` (and "crouch") return at once, `handle_action_release` /
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
  `cover_button_valid`, `in_cover`, `cover_fire_available`, the entry turn (`_begin_cover_turn`), `_apply_cover_shapes`
  (capsule and Head follow the crouch), `_apply_movement` (Sprint-lock and Jump exits, the tick), `_apply_weapon`
  (the trigger, no recoil), `_kick_camera` (no knockback in cover).
- **HUD wiring:** the Shoulder slot is the Cover button on the ground (`ui.json cover_button`); in cover the stick's
  forward extreme does not sprint (`TouchProvider.cover_suppress_sprint`); only the Fire buttons fire; the Fire buttons
  dim where Fire is unavailable. No other button changes in cover.
- **Data:** `data/cover.json` (every C1b key, OQ-COVER), `data/camera.json` (`cover_blend_s`, `cover`),
  `data/ui.json` (`cover_button`, `cover_fire_dim`), `data/haptics.json` (`cover_snap`); read-only
  `stats.json movement.muzzle_height_m` and `combat.auto_reload_on_empty`. See docs/OPEN_QUESTIONS.md OQ-COVER (M2 C1b).

### 4.22 Soldier and view-model art (M2 AN1)
Everything here is presentation: no collider, hitbox, muzzle, speed, ray, timing or net message reads it. Every
look is a trial for Shibi (OQ-ART-SOLDIER), not a design decision.
- **Data.** `data/art_soldier.json` (new) owns the hand, weapon and effect art, the soldier override layer and
  the budgets. `data/art_astra.json` is NOT edited by character work: it is hashed into every map's saved
  navigation (`map_nav.gd`). Animation numbers: `data/anim.json` `first_person` (view-model motion) and
  `data/anim_third_person.json` (gait, strafe, crawl, hit, cover arm pose, the foot-slide limit), which
  `SoldierRig.config()` merges over `data/anim.json`.
- **View model** (`scripts/visual/view_*.gd`): `view_mesh.gd` and `view_weapons.gd` build the Pilum BR, the
  Sagittarii rifle (with a modelled scope) and the Gladius Lux from part lists (chamfered boxes, lathes), with
  the energy cell and the charging handle as their own nodes; `view_hands.gd` and `view_rig.gd` build each arm
  as one skinned mesh on a small code-built skeleton with finger poses as data (grip, trigger, foregrip, open,
  reach, blade); `view_motion.gd` layers the motions (4.16); `view_fx.gd` holds the flash, which is parented
  to the muzzle and follows the gun, a shadowless OmniLight3D lit for the flash time on the local view model
  only, the world-fixed tracer that starts at the muzzle, and the spent cell; `view_probe.gd` measures posed
  vertices for the tests. Pickup is told apart from switch inside the view code by comparing the loadout's slot
  objects on `weapon_switched`; `pawn.gd` has no hook for it.
- **Soldier animation.** `clip_library.gd` resolves each logical clip from `data/anim_sources.json`; the `ual`
  source is the CC0 Quaternius Universal Animation Library (`assets/third_party/quaternius_ual/`, imported
  without the mannequin mesh). `anim_retarget.gd` bakes a clip onto the 17-bone soldier once; `soldier_clips.gd`
  measures each gait's stride on the soldier's own legs and normalizes the cycles, so the graph plays
  cycles per second = ground speed / stride and the feet stay planted. Every soldier shares the baked clips.
  Library clips: idle, walk, jog, sprint, reversed jog (back-pedal), airborne loop, hit (added on top), death
  (the corpse), revive kneel, blade swing, cover crouch legs. Code-built: aim, fire and reload (the library has
  no rifle clips; hands stay on the gun through the upper layer and the left-hand IK), the downed knee-crawl
  (`soldier_crawl.gd`), cover hug and rise, landing. `soldier_gait.gd` turns the hips toward a strafe while the
  chest and rifle keep the aim, and limits the pelvis bob because the helmet stays on the head hitbox.
- **Soldier look.** `soldier_look.gd` lays `art_soldier.json` `soldier.part_overrides` and `parts_add` over the
  art_astra soldier parts (longer legs, flatter banded shoulders, a neck guard), writes per-class metallic and
  roughness into the soldier material's own copy of the surface data (steel, dark steel, squad plate, bronze,
  leather, cloth, gun steel; one surface), and builds the third-person gun from the first-person part lists at
  reduced detail: the active weapon's own model, with a silhouette copy beyond `gun.far_m` by visibility range.
  The third-person flash and tracer keep their older origin, which `tests/test_soldier_hands.gd` locks.
- **Impacts.** `scripts/visual/shot_impacts.gd`: one pool per world, capped (`fx.impact_cap`), a burst per shot
  by surface (sparks, dust, energy on a soldier), classified like the impact sounds from a short visual probe.
- **Budgets** (`art_soldier.json`): view model 4,000 triangles and 12 draw calls; soldier near 3,100 / 2, far
  2,420 / 2. Tests: `test_view_model_art.gd`, `test_view_motion.gd`, `test_view_combat_fx.gd`,
  `test_soldier_clips.gd`, `test_soldier_footslide.gd`, `test_soldier_budget.gd`.
- **Tools:** `tools/fp_capture.gd`, `tools/soldier_capture.gd`, `tools/contact_sheet.gd`,
  `tools/fp_light_cost.gd`, `tools/glb_inspect.gd`.

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
