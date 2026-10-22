# Open questions

Gaps in docs/DESIGN.md that block or shape milestone 1 (FIRST PLAYABLE). Shibi decides each one.
Until then the build uses the placeholder shown. In data files a placeholder is marked
`"_placeholder": true` and/or `"_todo": "OQ-xx"`, so `grep -r OQ- data/` finds every use.
A placeholder is never a design value.

Format: **OQ-xx: question.** Placeholder now: ... (story that introduces it)

## Identity and packaging

- **OQ-01: Final Android application id.** DECIDED (Shibi, 2026-10-22): `com.shibibabu.gladius` (export_presets.cfg `package/unique_name`). Superseded placeholder: `com.placeholder.gladius` (S1, export_presets.cfg `package/unique_name`).
- **OQ-02: App display name on the launcher.** DECIDED (Shibi, 2026-10-22): launcher name `Project Gladius` (project.godot `application/config/name`, export preset `package/name`). Previous placeholder: `Project Gladius` (S1, project.godot `application/config/name`).
- **OQ-03: App icon.** Placeholder: plain generated `res://icon.svg` (S1).
- **OQ-04: Screen orientation.** DECIDED (Shibi, 2026-10-22): landscape only, sensor landscape (rotates between both landscape sides): `display/window/handheld/orientation=sensor_landscape` (value 4). Previous placeholder: sensor landscape (`display/window/handheld/orientation=4`) (S1).
- **OQ-05: Minimum Android version / supported devices beyond S24 Ultra, S25 Ultra and Z Fold7.** Placeholder: Godot 4.7.2 default min SDK, arm64-v8a only (S1).

## Weapons and loadouts

- **OQ-06: Pilum BR and Gladius Lux numbers**: damage, headshot multiplier, fire interval, burst size, magazine, reserve ammo, reload time, range, spread. DECIDED (Shibi, Oct 22 2026): a full starter set of stats for every milestone-1 weapon (incl. the Sagittarii long-range single-shot rifle, a PLACEHOLDER design) in `data/stats.json`, reasoning in `docs/STATS.md`; Shibi tunes on the phone, so entries stay `"_placeholder": true`.
- **OQ-07: What kind of weapon Gladius Lux is** (ranged gun, or an energy blade / melee weapon?). DECIDED (Shibi, Oct 22 2026): Gladius Lux is an energy blade (melee swing, arc and range from `stats.json`); Pilum BR stays a hitscan burst weapon.
- **OQ-08: Spawn loadout per class in milestone 1.** DECIDED (Shibi, 2026-10-22): Hastati spawn with Pilum BR + Gladius Lux; Sagittarii spawn with a long-range single-shot rifle (`sagittarii_rifle`, working name, hitscan, all numbers placeholder `# TUNE`) + Gladius Lux (`data/loadouts.json`, `data/stats.json`). Previous placeholder: both spawn with Pilum BR (primary) + Gladius Lux (secondary) (S6, `data/loadouts.json`).
- **OQ-09: Class sidearm.** DESIGN.md says "class sidearm" but names none. Placeholder: no sidearm in milestone 1 (S6).
- **OQ-10: Sagittarii loadout and identity in milestone 1.** DECIDED (Shibi, 2026-10-22): long-range single-shot rifle (`sagittarii_rifle`, working name; numbers are placeholders) + Gladius Lux; see OQ-08. Earlier note: it is the counter-sniper class ("one-shot Gladiators"), but no sniper weapon is in milestone 1 (Scorpio Rail is not listed). Placeholder: same loadout as Hastati; only the class table stats differ (S6).
- **OQ-11: Weapon tier for milestone 1.** Placeholder: `standard` only (S1).

## Combat rules

- **OQ-12: Shield regeneration delay and rate** ("Halo damage rules"). Placeholder: values in `data/stats.json` `combat`, marked placeholder (S3).
- **OQ-13: Headshot bonus.** DECIDED (Shibi, Oct 22 2026): each weapon has its own `headshot_multiplier`, applied the same way to shield and health.
- **OQ-14: Shield-break overflow.** Does damage that breaks the shield carry over into health in the same hit? Placeholder: yes, overflow carries over (S3).
- **OQ-15: What spawn protection blocks.** Placeholder: all damage is blocked for 5 s; protection ends on firing (both from DESIGN.md) (S4).
- **OQ-16: Which combat features are in milestone 1.** Milestone 1 lists only map, hill, two weapons, two classes, bots, input and hotspot. Melee is IN milestone 1 (the Gladius Lux energy blade, OQ-07, follows the DESIGN.md:15 melee rule, OQ-56). Placeholder: these are OUT of milestone 1: grenades, crouch/prone, radar, scorestreaks, deployables, weapon pickups from the fallen, power weapons, killcam and vehicles. All are provisioned in ARCHITECTURE.md (S-none).
- **OQ-17: Jump.** DECIDED (Shibi, 2026-10-22): jump stays in (`jump_enabled` true); jump numbers remain placeholders (see OQ-18). Previous note: DESIGN.md never mentions a jump button (the map has jump pads). Earlier placeholder: jump is enabled with a placeholder jump velocity, behind `"jump_enabled"` in `data/stats.json` `movement` (S6).
- **OQ-18: Base movement speed in m/s** (class speed is a % of it), gravity and acceleration. Placeholder: values in `data/stats.json` `movement` (S6).
- **OQ-19: Aim assist numbers** (friction, follow, magnetism, angle zones, falloff). DESIGN.md only says "all values low". Placeholder: `aim_assist` section in `data/stats.json` with every strength at 0, so aim assist is effectively off in milestone 1 (S6).

## Match / King of the Hill

- **OQ-20: Teams in KotH.** DECIDED (Shibi, Oct 22 2026): each 3-player squad scores independently, up to 6 squads.
- **OQ-21: When is the hill contested?** DECIDED (Shibi, Oct 22 2026): a contested zone (players from more than one squad inside) means no squad scores.
- **OQ-22: Result when the 10-minute timer ends.** DECIDED (Shibi, Oct 22 2026): highest score wins; a tie at the top is a draw.
- **OQ-23: Hill size and shape.** Placeholder: cylinder, radius and height in `data/maps/alesia_section.json` (S7).
- **OQ-24: Which part of Alesia is the "rough section".** DECIDED (Shibi, 2026-10-22): the Alesia hilltop citadel section, in greybox. Earlier placeholder: the hilltop citadel (fixed hill) plus a slice of the inner wall and legion-camp ring, as greybox geometry (S7).
- **OQ-25: Art assets for milestone 1.** DESIGN.md names CC0 packs (Kenney, Quaternius, Mixamo), but the build sessions cannot download them. DECIDED (Shibi, 2026-10-22): the map stays the Alesia hilltop citadel section in greybox. Earlier placeholder: greybox primitives (CSG/MeshInstance3D) and capsule characters until Shibi adds asset packs to the repo (S6/S7).
- **OQ-26: Number and placement of squad spawn spots on the section.** Placeholder: 6 spots in `data/maps/alesia_section.json`, arranged evenly around the hill (S7).
- **OQ-27: Join in progress and host-drop handling (60 s reconnect pause) in milestone 1?** DECIDED (Shibi, Oct 22 2026): keep the placeholder: joining works only from the lobby and a host drop returns everyone to the menu (lobby and in-match, `MatchRoot._on_host_lost`). Detail: out of milestone 1. Players join only in the pre-match lobby. If the host drops, clients return to the main menu (S9). Quitter handling mid-match: DESIGN.md says "Quitter replaced by bot", but that is not built. Placeholder (F2): the quitter's pawn is only marked inactive (MatchRoster._on_peer_left, TODO).
- **OQ-28: Pre-match lobby in milestone 1.** Placeholder: minimal. The host sees connected players, squads are auto-assigned (humans first, then bots fill), the host taps Start. Slot tapping, move/kick/lock, Advanced options and series are out (S9/S10). Undecided detail: `LobbyState.assign()` puts humans in the first slots, so they share squad 0 (co-op against bots) until the design says whether humans are split across squads. Net tolerances in `data/net.json` `validation` are placeholders (see T-03).
- **OQ-29: Class selection in milestone 1.** Where and when does a player pick Hastati or Sagittarii? DECIDED (Shibi, 2026-10-22): a class toggle Hastati/Sagittarii in the lobby for each human player (large touch button, synced host-authoritative); applies at match start and next spawn. Earlier placeholder: a two-button toggle in the lobby; applies on the next spawn (S10).

## Bots

- **OQ-30: How many bots in milestone 1 ("a few bots").** DECIDED (Shibi, 2026-10-22): bots fill to 2 squads of 3 (`data/match.json` squads = 2). Implementation notes: fill to 2 squads of 3 (6 total). The number of squads is the single key `data/match.json` `squads` (read by the lobby, MatchRoot, NetLobby and bot fill; replaces `offline_squads` and `match_fill.squads`); `DataRegistry.validate()` checks squads * squad_size <= max_players and enough map spawn spots. Bot profile and squad size are in `data/bots.json` `match_fill` (S8).
- **OQ-31: Bot difficulty in milestone 1, and numbers for Tiro/Miles/Centurion/Legatus** (accuracy, reaction time, damage, health...). DECIDED (Shibi, 2026-10-22): bots use the Tiro profile; the Tiro numbers themselves stay placeholders. Notes: one profile `tiro` with placeholder numbers; the other three listed with placeholder numbers, unused (S8). damage_mult, health_mult, aim_smartness and grenade_freq are stored in data/bots.json but not yet applied by the bot brain.
- **OQ-32: Bot classes.** Placeholder: bots alternate Hastati / Sagittarii (S8).
- **OQ-33: Bot squad commands in milestone 1?** (follow/attack/hold/rush hill). Not listed for milestone 1. Placeholder: out of milestone 1. Bots always play the hill. Command system provisioned in ARCHITECTURE.md (S8).

## Input and controls

- **OQ-34: Gyro aim in milestone 1?** DECIDED (Shibi, 2026-10-22): gyro off by default, with an On/Off toggle in settings (main menu), saved to `user://profile.json` (`gyro_enabled`). Earlier note: milestone 1 says "touch + controller". Earlier placeholder: a gyro provider exists but is a no-op and the default mode is `Off` (S5).
- **OQ-35: Default touch layout** (button positions and sizes, stick dead zones) and **default controller mapping**. Placeholder: values in `data/input.json`, marked placeholder (S5). Touch buttons (Fire, Aim, Reload, Swap, Jump): size, gap, font, anchor and grid cells are placeholders (`button_*` keys); layout is recomputed from the viewport size for foldables (T1b). Always-visible sticks: rest centres (`move_stick_rest`, `look_stick_rest`), radius and ring alpha are placeholders in `data/input.json`.
- **OQ-36: Default look sensitivity (stick, touch), gyro sensitivity and invert Y default.** Placeholder: values in `data/input.json`, invert off (S5); this also covers the `data/input.json` `gyro.sensitivity` placeholder.
- **OQ-53: Right-side touch look.** DESIGN.md says an aim stick (default `"stick"`); a drag-to-look option (`"drag"`) exists for Shibi to try after the Fold 7 test. Which should be the default, and what turn-rate cap and sensitivity? Placeholders in `data/input.json` `look`: `mode`, `max_turn_rate_deg_s`, `stick_rate_deg_s`, `drag_rad_per_screen_height` (also `touch_layout.stick_radius_frac_of_height`, OQ-35). T1 also asked for a "pilum" button, but there is no such action (Pilum BR is the rifle, fired with `fire`). If a thrown pilum or grenade was meant, that is later than milestone 1.
- **OQ-VJOY: Godot 4.7 VirtualJoystick vs the custom move stick (G2/G2b).** CURRENT (G2b): `"virtual"` is now the default move stick and `"custom"` stays as a working fallback; `touch_layout.vjoy_layout` is `"floating"` (default, JOYSTICK_DYNAMIC, whole left half grabs) or `"fixed"` (JOYSTICK_FIXED at `move_stick_rest`). Player profile (main menu Settings) overrides input.json. Open: Shibi judges feel on the Fold and picks the final default/layout. All `move_feel` values (`data/input.json`: vjoy deadzone/clamp, radial dead zone, response exponent) and `stats.json` `movement.ground_accel`/`ground_decel` times are neutral placeholders (today's behaviour), not design values; the strafe/backpedal ratio 0.889 is sourced (community data, see `_source`), not tuned. See docs/CONTROLS.md. Older G2 text follows and is superseded where it disagrees. Shibi judges on the Fold. `data/input.json` `touch_layout.move_stick` is `"virtual"` or `"custom"`; default is `"custom"` because `"virtual"` cannot pass the existing tests in `tests/test_touch_controls.gd` unchanged (they call `hud._input()` with synthetic events and read the stick Control re-centring under the thumb; a real VirtualJoystick only reacts to GUI-routed touches). EL decides: rewrite those tests to deliver through the viewport, or keep `custom`. All `touch_layout.vjoy` values (mode `dynamic`, deadzone 0.1, clamp 1.0, sizes) are placeholders; the VirtualJoystick touch area is the ring at `move_stick_rest`, not the whole move zone.
- **OQ-DEVICE-TOUCH: device-only touch differences (GBTN).** On Shibi's Fold (build 7943ce8) Reload/Swap/Aim/Fire "did nothing"; on desktop, with touches delivered through `Viewport.push_input` at 2520x1080 and 2176x1812, every button is hit and acts (see `tests/test_action_buttons.gd`). The causes found were missing aim (now implemented) and missing visual feedback. Any difference that exists only on the real device (touch indices, palm rejection, system gesture zones, emulated mouse) was **not reproduced on desktop**. Suggestion: use the touch debug overlay (`data/ui.json` `touch_debug_overlay.enabled`, default `false`; one line per held touch with index, position and the button/stick it hit) on the phone to see what the device really delivers. Placeholder flag, not a design value.
- **OQ-AIM / OQ-FEEDBACK (GBTN): aim and action-feedback numbers.** `stats.json` `aim` (`aim_fov_mult` 0.6, `aim_zoom_s` 0.15, `aim_spread_mult` 0.5; no weapon has its own aim spread yet, so one global multiplier) and `data/ui.json` `shot_fx` / `feedback` (tracer, muzzle flash, weapon mesh, hit marker, reload bar, Full/Empty cues, swap toast) are all placeholders, not design values and not PUBG values. DESIGN.md gives no aim-down-sights, first-person weapon view or hit-feedback spec; the camera is third-person (OQ-37), so the tracer is seen nearly end-on from behind the shoulder, and the weapon mesh is a box placed left of the pawn so it is not hidden inside the body.

## Camera, HUD, presentation

- **OQ-37: Third-person camera offset/distance and FOV per aspect ratio** (including the wider Fold7 inner screen FOV). Placeholder: table in `data/camera.json` (S6).
- **OQ-38: Which HUD numbers use Roman numerals** (score? timer? ammo?). DECIDED (Shibi, Oct 22 2026): no Roman numerals for now. All HUD numbers and scores are plain digits (0 shows "0"), squads are "Squad 1", "Squad 2"... The `RomanNumerals` code and tests are kept behind `data/ui.json` `hud.roman_numerals` (false) so they can come back.
- **OQ-38 (addendum, S10):** the end-screen delay (3 s) is a presentation constant and stays undecided (OQ-52).
- **Wired (F2, review H1; was a TODO, not a design question):** lobby name/class sync, the start RPC, one pawn per lobby slot, the bridge under the NetSession, client input and fire to the host, and the replica on clients are all in. Clients send input at `input_rate_hz`, fire through `send_fire` (local hitscan is presentation only) and apply the host snapshot to every other pawn; their own pawn takes only shield, health and alive from it, and is snapped to the host position on spawn and respawn. Covered by `tests/test_net_match.gd`. Still open: the host's own kills do not send `ev_kill`, and quitter handling (OQ-27).
- **OQ-39: Gamertag entry in milestone 1.** Placeholder: an editable name field on the main menu, saved to `user://profile.json`, default `Player` (S10).
- **OQ-40: Graphics quality presets and fps for milestone 1.** Placeholder: one preset `default` in `data/graphics_presets.json`, 60 fps cap; the 120 fps option is not exposed (S10).

## Networking

- **OQ-41: LAN autodiscovery in milestone 1?** DECIDED (Shibi, Oct 22 2026): keep the placeholder (manual IP field pre-filled with the last address, host shows its IPs). The UI flow says "Join (autodiscovery)"; milestone 1 says "hotspot". Placeholder: manual IP entry, pre-filled with the last-used address. The host screen shows its local IPs. No multicast, so `CHANGE_WIFI_MULTICAST_STATE` is not requested (S9).
- **OQ-50: Maximum lobby display-name length.** Placeholder: 24 characters, `data/net.json` `max_name_length`; the host truncates longer names (F2). Not a design value.
- **OQ-51: Client input send rate.** Placeholder: 30 Hz, `data/net.json` `input_rate_hz` (the snapshot rate is 15 Hz). Not a design value (F2).

## Traits and medals (DRAFT proposals from task T1)

- **OQ-42: draft traits and medals.** DECIDED (Shibi, Oct 22 2026): the draft traits and medals are the starting set and stay data-driven.
  docs/design/traits.md + `data/traits.json` (15 good, 6 bad traits) and docs/design/medals.md +
  `data/medals.json` (27 medals). Names and numbers can still be tuned in the data files; no build step
  wires them into gameplay, UI or the economy yet.
- **OQ-43: Do good traits stay forever once earned, or can they lapse?** DECIDED (Shibi, Oct 22 2026): the draft stands: permanent
  (`good_traits_permanent: true`).
- **OQ-44: Which matches count toward traits, and what counts as quitting?** Draft: multiplayer
  matches only (`koth` now; never tutorial or campaign). Only a deliberate leave counts as quitting;
  whether a lost connection that never reconnects counts is undecided.
- **OQ-45: What behavior earns "Carthaginian"?** DESIGN.md names it but gives no rule, and there is no
  friendly fire. Draft: a host who abandons matches (the match closes because the host left), read
  as "Punic faith". Deserter covers players who quit.
- **OQ-46: Do bot victims count as kills for medals and traits?** DECIDED (Shibi, Oct 22 2026): the draft stands: yes (`count_bot_victims: true`).
- **OQ-47: Medal stacking.** DECIDED (Shibi, Oct 22 2026): the draft stands: lower tiers are also awarded (each pays 10 Denarii); no cap.
- **OQ-48: Trait display.** How many traits show per player in the lobby, and is there one in-game
  banner per bad trait or one banner in total? Draft: TODO, not decided.
- **OQ-49: Where the 10 Denarii per medal lives.** `medals.json` `denarii_per_medal` or
  `economy.json`. Keep one source of truth. Draft: medals.json, until economy.json exists.

## Technical defaults (not product decisions; listed for visibility)

- **T-01: Network port and tick/sync rates.** Default: port 7777, values in `data/net.json` (S9).
- **T-02: Android SDK platform / build-tools version installed in CI.** Packages pinned via setup-android input; confirm on the first green run.
- **T-03: Movement authority.** Milestone 1: clients own their own movement (the host sanity-checks speed and vertical change); the host decides hits, damage, score, respawns and ammo/reload. Placeholders in `data/net.json` `validation`: `move_vertical_tolerance` (1.5) and `max_fall_speed_mps` (60, generous because the pawn has no terminal velocity); upward allowance = (jump_velocity + max_speed * tan(floor_max_angle)) per second. A rejected move keeps the host position and the client is snapped back via a reliable `correct_position` RPC. See ARCHITECTURE.md "Networking" (S9).

## Placeholder tunables (review L1)

- **OQ-52: Placeholder tunables moved out of scripts (review L1).** Values unchanged, none are design values: `data/stats.json` movement `muzzle_height_m` (1.3); `data/bots.json` brain `eye_height_m` (1.3), `target_height_m` (1.0), `path_desired_distance_m` (1.0), `target_desired_distance_m` (1.0); `data/match.json` `squad_spacing_m` (1.5); `data/input.json` touch_layout `fire_pulse_s` (0.08); `data/ui.json` `end_screen_delay_s` (3.0, presentation timing). The pawn pitch clamp now uses `data/camera.json` `pitch_min_deg`/`pitch_max_deg` (OQ-37) as the single source.

## Menus and lobby (T1c)

- **OQ-54: Menu touch-target height and font size.** Placeholders in `data/ui.json`: `min_touch_target_frac_of_height` (0.09 of viewport height, about 64 dp on the Z Fold 7 per T1) and `font_size_frac_of_height` (0.035). Android guidance is at least 48 dp, T1 asked for about 64 dp. Not design values. **Update (C4):** the 0.09 fraction alone is only about 37 dp on the folded cover screen at its likely real density (420 dpi, 2.625), and about 62 dp unfolded. `UiScale` now also enforces a dp floor, `min_touch_target_dp` = 48 in `data/ui.json` (Android guideline, not a design value), using `PlatformServices.get_dp_scale()` (`DisplayServer.screen_get_dpi()/160`), so every menu button is at least 48 dp. Capture with `--dpi=420` (folded) and `--dpi=373` (unfolded) measured 48.3 dp and 70.5 dp lobby buttons. The 420 and 373 dpi figures are assumptions for the Fold 7 until Shibi's device run confirms them: startup logs `[display] ... screen_get_dpi=...` for that. Also placeholder: `hud_layout.stat_block_pos` in `data/ui.json` (stat bars, weapon and ammo moved to top-left, clear of the sticks; OQ-35).
- **OQ-55: Who may customize bots in the pre-match lobby?** Host only (placeholder), each human for their own squad's bots, or anyone? Current behaviour: only the host, before the match starts, host-authoritative (clients never send bot changes); bot class overrides live in `LobbyState.bot_classes` keyed by slot index. DESIGN.md only says "bot customization".
- **OQ-56: Does the Gladius Lux swing follow the DESIGN melee rule?** DECIDED (Shibi, Oct 22 2026): yes, front = 70% of full shield, Gladiator front breaks a full shield, behind = instant kill; angle threshold placeholder in stats.json (DESIGN.md:15; see OQ-07, OQ-16). Implemented in `DamageRules.apply_melee`, `Melee.is_from_behind`, `Pawn.receive_melee`; numbers in `data/stats.json` `melee`. **PLACEHOLDERS (not Shibi decisions):** (1) `melee_back_angle_deg` = 90: a hit is from behind when the angle between the target's facing and the direction target -> attacker exceeds it. (2) PLACEHOLDER: for a non-Gladiator attacker, a front hit on a target with NO shield left applies the 70%-of-full-shield amount to health through the normal shield-then-health path (DESIGN.md and STATS.md say nothing about this case; the Gladiator case is (3)). There is still no overflow multiplier and no headshot rule for the blade. (3) PLACEHOLDER: with a Gladiator attacker, a front hit on a target with no shield left takes the full max_shield amount off health. DESIGN.md and STATS.md don't say this and it is not a Shibi decision (listed as `gladiator_front_hit_no_shield_rule` in stats.json melee `_placeholders`).

- **OQ-PORTRAIT: Portrait layout?** DECIDED: Landscape only (project is sensor_landscape); Fold inner landscape 2176x1812 covered; portrait would be a new run if Shibi wants it (EL decision Oct 22 2026).
