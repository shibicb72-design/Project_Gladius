# Project Gladius - approved design (Shibi, Oct 21 2026)
Rules: everything modular, data-driven, future-proof (additions must not mean rewrites). All numbers live in editable data files (res://data/*.json). Do NOT invent product decisions; where something is undecided, leave a clearly-marked TODO/placeholder.

## Platform/tech
Godot 4.7.2, GDScript, Android (Vulkan Mobile renderer). Phones: S24 Ultra, S25 Ultra, Z Fold7 (wider FOV on inner screen). 60 fps target, optional 120 fps setting. Low-poly 3D third-person. Free CC0 art (Kenney, Quaternius); Mixamo (Adobe terms, local builds only, never committed). Networking: local hotspot multiplayer, host phone is authoritative (decides hits/payouts). Later: dedicated server on Alienware is authoritative online (same rules code). Progress stored on phone; later sync to Alienware keeping last good sync.

## Setting
Futuristic Roman Republic (Rome never fell), Halo 2/3 feel. Map: futuristic Alesia (hilltop citadel = hill, inner wall, legion camp ring, outer wall with sniper towers, energy lily traps, stakes, jump pads, man cannons, aqueduct high routes, arches/eagles/columns/marble). Dusk/night/storm variants.

## Match
King of the Hill, fixed or moving (host picks); moving hill goes to random spots, flashes 5 s before moving. 1 pt/s uncontested, 100 to win or 10 min timer. 2-6 humans, squads of 3, up to 18 total; bot squads fill. Bots: Tiro, Miles, Centurion, Legatus + custom sliders (accuracy, health, spawns, AI smartness, damage, grenade frequency, reaction time). Join in progress. Host drop: 60 s reconnect pause, resettable up to 10x, else closes. Quitter replaced by bot, loses match Denarii. Host options simple + Advanced (score, time, difficulty, hill mode, series 3/5/7, power weapons, streaks...). Friends tap a lobby slot to join a squad; host can move/kick/lock. Scaffold modes later: Slayer, Capture the Eagle, Oddball. Factions provisioned (Romans now; Spartans etc later).
Spawns: each squad gets a random fixed spot for the whole match, no advantage. Respawn 5 s, 5 s spawn protection (ends on firing, not on pickup). Killcam: 5 s on killer, optionally keep watching up to 30 s; exit -> squad spot; timeout -> random spot (anti-AFK), still protected. Bots respawn same rules.

## Combat
Halo damage rules (shield then health), headshots extra on all weapons. Two weapons + swap + class sidearm. Crouch and prone (prone tightens spread, can shoot, hides on radar by class: lighter hides better, Velites best, Triarii worst). Sprint added by Shibi's decision, Oct 22 2026. No friendly fire. Melee every class: front = 70% of full shield; Gladiator front breaks full shield in one hit; from behind = instant kill (no animation). Grenades: spawn with 4 (1 Ignis sticky, 2 frag, 1 smoke), carry max 7, types data-driven. Smoke blocks bot sight and hides on radar (radar animation). Radar like Halo: 25 m, crouch/prone off radar, jammer blanks nearby enemies. Power weapons respawn every 2 min. Pick up weapons from fallen (keeps their ammo, crate refill, lost on death); off-class penalty (aim/recoil) by class; Hastati/Principes no penalty no bonus.
Scorestreaks (player kills only, reset on death, any class): ammo drop 3, support chariot 5, orbital bombardment 10; Sagittarii extra support streaks.
Deployables (carry 5, spawn randomly on map over time): Testudo bubble (30 s, rallies squad bots, open to fire out), radar jammer, turret, healing station, grav lift, decoy, mine field, regen field (first to cut).
Aim assist: Halo friction + light follow when aiming + small per-weapon magnetism, ADS snap off; controller strongest, touch lighter, none on gyro; angle zones shrink with zoom, distance falloff; all values low and in stats file.

## Cover crouch (decided by Shibi, Oct 29 2026)

While in cover, a Crouch toggle switches standing and crouched stances with a smooth pose and lowered body/head hitboxes. Crouch here applies only in cover; free crouch, prone and radar behavior are separate work. The contextual cover FIRE button draws out and fires only from a completed clear pose, then returns automatically; Aim or a look drag can hold the pawn out without firing. Low cover uses a standing rise; high cover requires a nearby usable edge. The cover FIRE button is the only firing control in cover, including peeks. Dimensions, timings and control placement remain placeholders in data pending review.

## Classes (shield/health/speed, editable core table)
Hastati 100/100/100%, Principes 110/110/100%, Triarii 140/130/85%, Velites 70/80/115% (Mark skill), Sagittarii 80/90/95%, Equites 90/100/100% (200% in chariot; mobile support: vehicle, heal, ammo, cover), Gladiator 60/120/110% (melee). Hastati->Principes->Triarii unlock by rank or Denarii; specialists open from start. Counters: Gladiators beat line infantry, Sagittarii one-shot Gladiators, Velites hunt Sagittarii. Bots can't use tiers above their player.

## Weapons
Pilum BR, Gladius Lux, Scorpio Rail, Onager Launcher, Ignis sticky, Scutum field. Tiers standard/upgraded/legendary. Scopes red dot, 2x, 4x, 8x, 16x. Attachments change stats; stat chart per weapon.
Vehicle: ground hover-chariot 2x run speed, driver + shooting passenger. Flying chariots later.

## Bots/commands
Page 1 quick-tap buttons above fire (right side): follow, attack, hold, rush hill. Page 2 (flip): guard, rush, attack marked target. Bots go prone and seek good spots.

## Controls/HUD
Left stick move; gyro aim (toggle, sensitivity, ADS-only, recenter, modes Off/ADS/Always); right-side backup aim stick where tap fires. Full Bluetooth controller. Full button remapping (only accessibility item at launch). Classic Halo HUD, red/gold, Roman numerals. No subtitles; no voice chat.

## Progression/economy
12 post-Marian ranks Tiro..Consul (~50 matches). Currency Denarii (all-purpose). Start 500. Player kill 20, +10 headshot, +25 assassination, +15 class bonus, +5 deployable/AoE kill; bonuses stack. Squad-bot kills pay the human: 10, then x1.5 each kill, cap 100, reset on bot death. Win 100, 1/s on hill, 10/medal. Prices: common 100, rare 300, epic 700, super rare 1200, legendary 2000, class unlock 1500, series advantage 200-500. Shop shows full catalog (rotation provisioned later). 50 cosmetics (helmet, chest, gloves, legs, boots, shields, skins). Post-match loot by rarity. Latin medals. Series advantages bought in lobby: better starting weapons, extra deployables; currency carries over. Gamertag on phone. Player traits/banners (Roman virtues; bad ones like Deserter/Carthaginian fade with opposite behavior; show in lobby; only bad ones show in-game as small banner; cosmetic now, effects provisioned).

## Audio
Latin announcer recorded by Shibi later (placeholder slots). Orchestral + synth music.

## UI flow
Main menu: Host, Join (autodiscovery), Loadout, Profile, Shop, Tutorials, Settings. Pre-match lobby (squad slots, bot customization). Warm-up lobby during load (30 s max load, 30 s countdown, can start early). Post-match credits-style stats screen with XP, medals, loot. Settings: stick/gyro sensitivity, remapping, volumes, 60/120 fps, quality, invert Y, Send logs (share log file via email/Drive). Tutorial: skippable training match (basics, classes/skills, deployables, advanced economy/streaks), also from main menu.

## Campaign (alpha+)
5 missions on Alesia, 15 min each, historical order (build walls, hold inner line, beat relief army, take citadel, boss). Enemies: Spartans of a Hellenic League (original armor, not Halo's): phalanx (3 form it; flank; flickers at 1 down from side/rear, collapses at 2), hoplite spear-gunner, buffing officer, Toxotes marksman, Hypaspist medic. Gauls (ragtag): berserker mob rusher, slinger-raider, war-cry chieftain, naked swordsman (bare chest, war paint, glass cannon), Gallic hover-chariot (driver+gunner, rams, hijackable). Boss Vercingetorix: screech 25 m every 30 s (shake, blur, radar scramble, slow aim 3 s), blocked by Testudo, distance, or 5 ft wall; ~5 min fight, scales 1-3 players. Co-op one squad (bots or solo). 2 checkpoints/mission; fallen co-op player respawns at nearest. 4 difficulties + sliders. 500 Denarii per phase first clear only (reward type data-driven). Cutscenes in-engine, no voice, detailed on-screen narration text.

## Milestones
1. FIRST PLAYABLE (approved, current target): rough Alesia section, fixed hill, Pilum BR + Gladius Lux, Hastati + Sagittarii, a few bots, touch + controller, hotspot. 2. Vertical slice. 3. Alpha. 4. Beta. 5. 1.0.
