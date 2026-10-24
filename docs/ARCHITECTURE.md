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
- Data: `modes.json`. Each mode has `rules` (behavior id) + params. `koth` has points_per_second 1,
  score_to_win 100, time_limit_s 600, hill_modes fixed/moving, moving_warn_s 5. Later entries:
  `slayer`, `capture_the_eagle`, `oddball`.
- Code: `GameModeRules` base (`setup`, `tick(delta, world_facts) -> events`, `on_event`, `is_over`,
  `result`). `KothRules` comes first. `ModeRegistry` maps `rules` id → script. Moving hill is a param
  of KotH plus a hill-position provider, not a new mode.
- Add a mode variant: data entry with existing `rules`. Add a new mode: one rules script + registry
  line + optional objective scene (eagle, oddball).

### 4.10 Match flow
- `MatchDirector` (Node, authority only) owns the active GameModeRules, SpawnRules, StreakRules and
  the match event log. Its states: `lobby → warmup (30 s max load, 30 s countdown, early start) →
  playing → post_match`.
- It feeds rules with world facts collected by presentation nodes. `HillZone` (Area3D) reports which
  squads are inside; it decides nothing.
- Spawns: `SpawnRules` gives each squad a random fixed spot for the whole match (seeded), a 5 s
  respawn and 5 s spawn protection that ends on firing, not on pickup.
- Killcam (later): after death the client shows 5 s on the killer, optionally up to 30 s; exit →
  squad spot; timeout → random spot, still protected. Only the camera is client-side; respawn timing
  stays with the authority.
- Bots use exactly the same spawn/respawn path.
- Join in progress, quitter→bot replacement and the host-drop 60 s pause (resettable up to 10×) are
  MatchDirector/NetSession states, added later without changing the rules scripts.

### 4.11 Bots and commands
- Data: `bots.json`. Profiles `tiro`, `miles`, `centurion`, `legatus` + custom slider fields
  (accuracy, health, spawns, AI smartness, damage, grenade frequency, reaction time); `match_fill`.
  The rule "bots can't use tiers above their player" is a lookup when building bot loadouts.
- Code: `BotBrain` turns perception into an `InputFrame` and drives the same `Pawn` as a human. So
  bots get movement, weapons and rules for free, and work identically on host and dedicated server.
  Target selection and aim error are pure helpers (`bot_targeting.gd`).
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
- InputMap actions are the vocabulary: move, look, fire, aim, reload, swap_weapon, jump, pause; later
  crouch, prone, melee, grenade, deployable, streak and command pages.
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
  `roman_numerals.gd`. Later: radar (25 m, crouch/prone hide, jammer blanking, smoke animation),
  streak/deployable slots, killfeed, Latin medal popups, bad-trait banner.
- `touch_hud.tscn`: a separate CanvasLayer above the HUD. Left stick; right side backup aim stick
  where a tap fires; quick-tap command buttons above fire (later, pages 1/2). Hidden when
  `PlatformServices.is_touch_device()` is false, unless forced on by a setting.
- Layouts use anchors and containers only, and scale with DPI/aspect (S24/S25 Ultra, Fold7
  outer/inner).

### 4.16 Camera and FOV per aspect ratio
- `CameraRig` (SpringArm3D + Camera3D, third person). FOV and offset come from `camera.json`: a table
  of aspect-ratio breakpoints. Tall phones use the base FOV; near-square screens (Z Fold7 inner) use a
  wider entry, as DESIGN.md requires. The rig re-applies on viewport `size_changed`, so folding or
  unfolding mid-match works. Scope zoom multiplies on top.

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
- Lobby: `LobbyState` (pure, serializable) holds players, squads, classes and settings. The host owns
  it and broadcasts changes.
- Discovery: manual IP in milestone 1 (OQ-41). A later UDP-broadcast discoverer plugs into
  NetSession, and needs a platform hook for an Android multicast lock if multicast is used.
- Dedicated server later: the same project runs `--headless` with a server boot scene. Its
  MatchDirector is authority with zero local players. Because rules are pure and presentation only
  listens, no rules code changes.

### 4.18 Graphics quality
- Renderer: Mobile (Vulkan) project-wide. Compatibility only as a per-platform override (e.g. web).
- `graphics_presets.json`: named presets (render scale, shadows, MSAA, fps cap 60/120, LOD). Applied
  at boot by a small `GraphicsSettings` helper; the profile stores the chosen preset.

### 4.19 Audio (later)
- `audio.json` maps event ids (announcer lines, music states) to streams. Shibi's Latin announcer
  lines fill placeholder slots by id.

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
| Map | `maps/<id>.json` + scene with matching markers | No |
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
