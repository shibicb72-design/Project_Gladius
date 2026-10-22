# Open questions

Gaps in docs/DESIGN.md that block or shape milestone 1 (FIRST PLAYABLE). Shibi decides each one.
Until then the build uses the placeholder shown. In data files a placeholder is marked
`"_placeholder": true` and/or `"_todo": "OQ-xx"`, so `grep -r OQ- data/` finds every use.
A placeholder is never a design value.

Format: **OQ-xx: question.** Placeholder now: ... (story that introduces it)

## Identity and packaging

- **OQ-01: Final Android application id.** Placeholder: `com.placeholder.gladius` (S1, export_presets.cfg `package/unique_name`).
- **OQ-02: App display name on the launcher.** Placeholder: `Project Gladius` (S1, project.godot `application/config/name`).
- **OQ-03: App icon.** Placeholder: plain generated `res://icon.svg` (S1).
- **OQ-04: Screen orientation.** DESIGN.md does not state it. Placeholder: sensor landscape (`display/window/handheld/orientation=4`) (S1).
- **OQ-05: Minimum Android version / supported devices beyond S24 Ultra, S25 Ultra and Z Fold7.** Placeholder: Godot 4.7.2 default min SDK, arm64-v8a only (S1).

## Weapons and loadouts

- **OQ-06: Pilum BR and Gladius Lux numbers**: damage, headshot multiplier, fire interval, burst size, magazine, reserve ammo, reload time, range, spread. DESIGN.md gives none. Placeholder: values in `data/stats.json` under `weapons`, each entry `"_placeholder": true` (S1).
- **OQ-07: What kind of weapon Gladius Lux is** (ranged gun, or an energy blade / melee weapon?). Pilum BR's "BR" suggests a battle rifle, but that isn't stated either. Placeholder: both are hitscan guns (`"kind": "hitscan"`). Pilum BR fires a burst; Gladius Lux fires single shots (S1/S6).
- **OQ-08: Spawn loadout per class in milestone 1.** Which two weapons Hastati and Sagittarii spawn with. Placeholder: both spawn with Pilum BR (primary) + Gladius Lux (secondary) (S6, `data/loadouts.json`).
- **OQ-09: Class sidearm.** DESIGN.md says "class sidearm" but names none. Placeholder: no sidearm in milestone 1 (S6).
- **OQ-10: Sagittarii loadout and identity in milestone 1.** It is the counter-sniper class ("one-shot Gladiators"), but no sniper weapon is in milestone 1 (Scorpio Rail is not listed). Placeholder: same loadout as Hastati; only the class table stats differ (S6).
- **OQ-11: Weapon tier for milestone 1.** Placeholder: `standard` only (S1).

## Combat rules

- **OQ-12: Shield regeneration delay and rate** ("Halo damage rules"). Placeholder: values in `data/stats.json` `combat`, marked placeholder (S3).
- **OQ-13: Headshot bonus.** Does "headshots extra on all weapons" mean a multiplier, and how large is it? Does it bypass shields? Placeholder: per-weapon `headshot_multiplier`, applied the same way to shield and health (S3).
- **OQ-14: Shield-break overflow.** Does damage that breaks the shield carry over into health in the same hit? Placeholder: yes, overflow carries over (S3).
- **OQ-15: What spawn protection blocks.** Placeholder: all damage is blocked for 5 s; protection ends on firing (both from DESIGN.md) (S4).
- **OQ-16: Which combat features are in milestone 1.** Milestone 1 lists only map, hill, two weapons, two classes, bots, input and hotspot. Placeholder: these are OUT of milestone 1: melee, grenades, crouch/prone, radar, scorestreaks, deployables, weapon pickups from the fallen, power weapons, killcam and vehicles. All are provisioned in ARCHITECTURE.md (S-none).
- **OQ-17: Jump.** DESIGN.md never mentions a jump button (the map has jump pads). Placeholder: jump is enabled with a placeholder jump velocity, behind `"jump_enabled"` in `data/stats.json` `movement` (S6).
- **OQ-18: Base movement speed in m/s** (class speed is a % of it), gravity and acceleration. Placeholder: values in `data/stats.json` `movement` (S6).
- **OQ-19: Aim assist numbers** (friction, follow, magnetism, angle zones, falloff). DESIGN.md only says "all values low". Placeholder: `aim_assist` section in `data/stats.json` with every strength at 0, so aim assist is effectively off in milestone 1 (S6).

## Match / King of the Hill

- **OQ-20: Teams in KotH.** Is each squad of 3 its own team (up to 6 squads scoring independently), or are squads grouped into two sides? Placeholder: each squad scores independently (S4).
- **OQ-21: When is the hill contested?** Placeholder: if players from more than one squad are inside, nobody scores (S4).
- **OQ-22: Result when the 10-minute timer ends.** Highest score wins; what about a tie? Placeholder: a tie at the top is a draw (S4).
- **OQ-23: Hill size and shape.** Placeholder: cylinder, radius and height in `data/maps/alesia_section.json` (S7).
- **OQ-24: Which part of Alesia is the "rough section".** Placeholder: the hilltop citadel (fixed hill) plus a slice of the inner wall and legion-camp ring, as greybox geometry (S7).
- **OQ-25: Art assets for milestone 1.** DESIGN.md names CC0 packs (Kenney, Quaternius, Mixamo), but the build sessions cannot download them. Placeholder: greybox primitives (CSG/MeshInstance3D) and capsule characters until Shibi adds asset packs to the repo (S6/S7).
- **OQ-26: Number and placement of squad spawn spots on the section.** Placeholder: 6 spots in `data/maps/alesia_section.json`, arranged evenly around the hill (S7).
- **OQ-27: Join in progress and host-drop handling (60 s reconnect pause) in milestone 1?** Placeholder: out of milestone 1. Players join only in the pre-match lobby. If the host drops, clients return to the main menu (S9).
- **OQ-28: Pre-match lobby in milestone 1.** Placeholder: minimal. The host sees connected players, squads are auto-assigned (humans first, then bots fill), the host taps Start. Slot tapping, move/kick/lock, Advanced options and series are out (S9/S10).
- **OQ-29: Class selection in milestone 1.** Where and when does a player pick Hastati or Sagittarii? Placeholder: a two-button toggle in the lobby; applies on the next spawn (S10).

## Bots

- **OQ-30: How many bots in milestone 1 ("a few bots").** Placeholder: fill to 2 squads of 3 (6 total). Configured in `data/bots.json` `match_fill` (S8).
- **OQ-31: Bot difficulty in milestone 1, and numbers for Tiro/Miles/Centurion/Legatus** (accuracy, reaction time, damage, health...). Placeholder: one profile `tiro` with placeholder numbers; the other three listed with placeholder numbers, unused (S8).
- **OQ-32: Bot classes.** Placeholder: bots alternate Hastati / Sagittarii (S8).
- **OQ-33: Bot squad commands in milestone 1?** (follow/attack/hold/rush hill). Not listed for milestone 1. Placeholder: out of milestone 1. Bots always play the hill. Command system provisioned in ARCHITECTURE.md (S8).

## Input and controls

- **OQ-34: Gyro aim in milestone 1?** Milestone 1 says "touch + controller". Placeholder: a gyro provider exists but is a no-op and the default mode is `Off` (S5).
- **OQ-35: Default touch layout** (button positions and sizes, stick dead zones) and **default controller mapping**. Placeholder: values in `data/input.json`, marked placeholder (S5).
- **OQ-36: Default look sensitivity (stick, touch) and invert Y default.** Placeholder: values in `data/input.json`, invert off (S5).

## Camera, HUD, presentation

- **OQ-37: Third-person camera offset/distance and FOV per aspect ratio** (including the wider Fold7 inner screen FOV). Placeholder: table in `data/camera.json` (S6).
- **OQ-38: Which HUD numbers use Roman numerals** (score? timer? ammo?). Placeholder: hill scores in Roman numerals; timer as mm:ss; ammo as Arabic numerals (S10).
- **OQ-39: Gamertag entry in milestone 1.** Placeholder: an editable name field on the main menu, saved to `user://profile.json`, default `Player` (S10).
- **OQ-40: Graphics quality presets and fps for milestone 1.** Placeholder: one preset `default` in `data/graphics_presets.json`, 60 fps cap; the 120 fps option is not exposed (S10).

## Networking

- **OQ-41: LAN autodiscovery in milestone 1?** The UI flow says "Join (autodiscovery)"; milestone 1 says "hotspot". Placeholder: manual IP entry, pre-filled with the last-used address. The host screen shows its local IPs. No multicast, so `CHANGE_WIFI_MULTICAST_STATE` is not requested (S9).

## Technical defaults (not product decisions; listed for visibility)

- **T-01: Network port and tick/sync rates.** Default: port 7777, values in `data/net.json` (S9).
- **T-02: Android SDK platform / build-tools version installed in CI.** Must match what Godot 4.7.2 targets. Verify on the first real CI run (S2).
- **T-03: Movement authority.** Milestone 1: clients own their own movement (the host sanity-checks speed); the host decides hits, damage, score and respawns. See ARCHITECTURE.md "Networking" (S9).
