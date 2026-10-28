# Starter weapon stats (OQ-06)

All numbers live in `data/stats.json` under `weapons` and are loaded at runtime by `DataRegistry`
(`WeaponDef`). Nothing here is hard-coded in scripts. Every entry carries `"_placeholder": true`:
Shibi tunes them on the phone.

<!--
Reasoning for the starter numbers (short):
- Shield + health is 200 for Hastati (100/100), so Pilum BR does 20 per bullet, 3-round bursts: 10 body hits
  to empty a Hastati, about 7 with headshots (x1.5 = 30, 200/30 = 6.7). Fire interval 0.5 s per burst:
  4 bursts = about 1.5 s on body hits (the 4th burst starts 3 x 0.5 s after the first). Derived from
  data/stats.json by tests/test_stats_doc.gd, which also checks this text.
- Pilum BR is the all-rounder: mid range 80 m, 1 degree spread, 30 round magazine, 1 s reload
  (was 2 s; Shibi Fold eye-test 2026-10-28: reload times halved).
- Gladius Lux is an ENERGY BLADE (OQ-07): melee swing, 0.6 s between swings, 2.2 m reach, 100 degree
  arc. Damage follows the DESIGN.md:15 melee rule (OQ-56, see below), not a flat number. No ammo, so
  magazine, reload and spread are zero/unused. It does not test the head, so its headshot_multiplier is 1.0.
- Sagittarii rifle: PLACEHOLDER "long-range single-shot" design, NOT a Shibi decision (working name,
  OQ-08/OQ-10). 90 damage, 1.2 s between shots, 200 m, near-zero spread, 5 round magazine, headshot
  x2.0 so a headshot (180) breaks a Sagittarii/Hastati shield and most of the health. Slow fire and a
  small magazine are the price for range. Class counters from DESIGN.md (one-shot Gladiators) are not
  yet tuned: Gladiator is 60/120 = 180 total, a headshot is 180.
- headshot_multiplier is per weapon (OQ-13) and applied the same to shield and health.
-->

| Field | Pilum BR | Gladius Lux (melee) | Sagittarii Rifle (PLACEHOLDER) |
|---|---|---|---|
| kind | hitscan burst | melee | hitscan single shot |
| damage | 20 per bullet | front 70 (Hastati), front 56 (Sagittarii); Gladiator attacker front 100 (Hastati), Gladiator attacker front 80 (Sagittarii); back instant kill | 90 |
| headshot_multiplier | 1.5 | 1.0 (no head test) | 2.0 |
| fire_interval_s | 0.5 | 0.6 (swing) | 1.2 |
| burst_count / burst_interval_s | 3 / 0.07 | 1 / 0.05 | 1 / 0.05 |
| range_m | 80 | 2.2 (= melee_range_m) | 200 |
| spread_deg | 1.0 | unused | 0.1 |
| magazine / reserve_ammo / reload_s | 30 / 120 / 1.0 | none | 5 / 25 / 1.25 |
| melee_range_m / melee_arc_deg / swing_duration_s | - | 2.2 / 100 / 0.2 | - |

Status:
- **Reload times: Shibi Fold eye-test 2026-10-28: reload times halved.** Pilum BR `reload_s` 2.0 -> 1.0 s,
  Sagittarii rifle 2.5 -> 1.25 s; Gladius Lux has no reload (0). Still placeholders (`"_placeholder": true`):
  Shibi keeps tuning them on the phone (OQ-06). Moving while reloading: OQ-RELOAD-MOVE.
- **Sagittarii rifle: PLACEHOLDER design.** "Long-range single-shot" comes from the Oct 22 decision
  OQ-08/OQ-10 but its numbers, and the weapon's real name, are not a Shibi decision.
- Not yet statted (no design numbers, outside milestone 1, OQ-16): Scorpio Rail, Onager Launcher,
  Ignis sticky, Scutum field, grenades. Add them to `data/stats.json` when they are built.
- **Melee rule (DECIDED, OQ-56, DESIGN.md:15), implemented for the Gladius Lux swing** with the numbers in
  `data/stats.json` `melee`: a front hit removes 70% of the target's FULL (max) shield
  (`melee_front_shield_fraction`); a Gladiator attacker's front hit breaks a full shield in one hit; a hit
  from behind is an instant kill. Front/back is the angle between the target's facing and the direction
  target -> attacker; `melee_back_angle_deg` (90) is a PLACEHOLDER. A front hit on a target with no shield
  left applies the same 70%-of-full-shield amount to health through the normal shield-then-health path:
  also a PLACEHOLDER, not a Shibi decision. The `damage` key (60) is kept in data but no longer used
  by this rule.
