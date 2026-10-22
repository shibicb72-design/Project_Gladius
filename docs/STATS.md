# Starter weapon stats (OQ-06)

All numbers live in `data/stats.json` under `weapons` and are loaded at runtime by `DataRegistry`
(`WeaponDef`). Nothing here is hard-coded in scripts. Every entry carries `"_placeholder": true`:
Shibi tunes them on the phone.

<!--
Reasoning for the starter numbers (short):
- Shield + health is 200 for Hastati (100/100), so Pilum BR does 20 per bullet, 3-round bursts, about
  30 bullets to empty a Hastati from body hits; headshot x1.5 trims that to about 20. Fire interval
  0.5 s per burst gives about 120 damage/s at best, roughly a 2 s time-to-kill on body hits.
- Pilum BR is the all-rounder: mid range 80 m, 1 degree spread, 30 round magazine, 2 s reload.
- Gladius Lux is an ENERGY BLADE (OQ-07): melee swing, 60 damage per hit, 0.6 s between swings,
  2.2 m reach, 100 degree arc. Four hits finish a Hastati. No ammo, so magazine, reload and spread
  are zero/unused. It does not test the head, so its headshot_multiplier is 1.0.
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
| damage | 20 per bullet | 60 per swing | 90 |
| headshot_multiplier | 1.5 | 1.0 (no head test) | 2.0 |
| fire_interval_s | 0.5 | 0.6 (swing) | 1.2 |
| burst_count / burst_interval_s | 3 / 0.07 | 1 / 0.05 | 1 / 0.05 |
| range_m | 80 | 2.2 (= melee_range_m) | 200 |
| spread_deg | 1.0 | unused | 0.1 |
| magazine / reserve_ammo / reload_s | 30 / 120 / 2.0 | none | 5 / 25 / 2.5 |
| melee_range_m / melee_arc_deg / swing_duration_s | - | 2.2 / 100 / 0.2 | - |

Status:
- **Sagittarii rifle: PLACEHOLDER design.** "Long-range single-shot" comes from the Oct 22 decision
  OQ-08/OQ-10 but its numbers, and the weapon's real name, are not a Shibi decision.
- Not yet statted (no design numbers, outside milestone 1, OQ-16): Scorpio Rail, Onager Launcher,
  Ignis sticky, Scutum field, grenades. Add them to `data/stats.json` when they are built.
- The generic melee rules from DESIGN.md (front hit = 70% of full shield, Gladiator breaks a full
  shield, back hit = instant kill) are a separate class-level melee and are not implemented; the
  Gladius Lux swing uses plain `damage` through the normal shield-then-health rules.
