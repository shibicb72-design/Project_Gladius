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
  `roman_numerals.gd`. Later: radar (25 m, crouch/prone hide, jammer blanking, smoke animation),
  streak/deployable slots, killfeed, Latin medal popups, bad-trait banner.
- `touch_hud.tscn`: a separate CanvasLayer above the HUD. Left stick; right side backup aim stick
  where a tap fires; quick-tap command buttons above fire (later, pages 1/2). Hidden when
  `PlatformServices.is_touch_device()` is false, unless forced on by a setting.
- Layouts use anchors and containers only, and scale with DPI/aspect (S24/S25 Ultra, Fold7
  outer/inner).
- The front-end (boot, main menu, lobby, settings pages, pause overlay, end screen) has its own look
  (M2 U1): theme `menu_theme.tres`, the kit in `scripts/ui/menu/` (`MenuStyle`, `MenuIcon`,
  `MenuBackdrop`, `MenuLogo`), numbers in `data/ui.json` `menu_style` / `menu_type_scale`. `UiScale`
  sizes touch targets and applies the kit's sizes on every resize. Rules: `docs/UI_STYLE.md`. Proof
  shots: `tools/menu_shots.tscn` (every screen at six phone sizes).

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
- Status (M2 P1b, Nov 14 2026): two of three pipeline slices towards the 1 km map. Built in P1a: map
  selection, per-map piece files, looks batched per chunk, a 300 m test map, tree-count proxies.
  Built in P1b: ground size and paint resolution from data, height-field terrain (data, chunked look,
  one height-map collider), pieces standing on the terrain, saved navigation with stale detection.
  Not built: visibility ranges, culling, near and far meshes, fog and far plane, loot grid, bot think
  rate (P1c).
- **Which map a match loads.** `data/map_select.json` `"map"` names a map json.
  `MatchRoot.select_map()` returns `{path, error}`; a missing or invalid map gives
  `alesia_section` and a non-empty error, and only `MatchRoot.begin()` reports it. The file
  `user://map_select_override` (one `res://data/maps/<file>.json` path on its first line) wins when
  it exists: a measurement tool for a debug build on the phone, like the perf logger's flag file.
  `MatchRoot.map_path` holds the loaded map; tests set `map_path_override`.
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
  source (`cover`, `ring`, `structure`, `decor`) and type, with that type's material and its source's
  shadow setting (decor casts none). A decor type is `<kind>_<n>`, one per kind and size
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
  None of these is a frame time: the Fold measurement decides.
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
- **Saved navigation (P1b).** `tools/bake_nav.gd -- --map=<json>` (no argument: both maps) bakes a
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
