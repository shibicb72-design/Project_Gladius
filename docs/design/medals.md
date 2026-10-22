# Latin medals: DRAFT for Shibi's approval

> **DRAFT (task T1).** Shibi asked for proposals to approve, so everything here is a proposal and
> not a design decision. Names, triggers and numbers can all change.
> **Build steps must not wire medals into gameplay, UI or the economy until Shibi approves**
> (docs/OPEN_QUESTIONS.md OQ-42). The data lives in `data/medals.json` (`"status": "DRAFT - awaiting
> Shibi approval"`). This doc mirrors that file. Code reads every number from the JSON; none are in code.

## What DESIGN.md fixes

- Latin medals exist and each pays **10 Denarii** (`denarii_per_medal: 10`). Medals give no other
  reward. Whether this number lives in medals.json or economy.json is OQ-49.
- The post-match screen shows medals. ARCHITECTURE.md plans Latin medal popups in the HUD.

## Global rules (proposal)

- **Kill** means an enemy, human or bot, killed by you personally (`count_bot_victims: true`; OQ-46).
  Squad-bot kills count only for Dux.
- Tiered medals also award the lower tiers (`award_lower_tiers: true`; OQ-47). A Triplex therefore
  also gives Duplex (2 medals, 20 Denarii), and a 10-kill spree gives Impetus and Furor.
  Each medal can be earned again in the same match unless its trigger says "once per match".
- Squad bots are squad members for squad medals (`squad_bots_are_squad_members: true`).

## Medals (27)

| id | Latin name | English meaning | Exact trigger |
|---|---|---|---|
| **Multi-kills** | | | |
| `duplex` | Duplex | Double | 2 kills in one life, each within 4.0 s of the previous one. |
| `triplex` | Triplex | Triple | 3 kills in one life, each within 4.0 s of the previous one. |
| `quadriga` | Quadriga | Four-horse chariot | 4 kills in one life, each within 4.0 s of the previous one. |
| `quinqueremis` | Quinqueremis | Quinquereme (five-banked warship) | 5 kills in one life, each within 4.0 s of the previous one. |
| **Sprees** | | | |
| `impetus` | Impetus | Onslaught | 5 kills in one life without dying. |
| `furor` | Furor | Battle rage | 10 kills in one life without dying. |
| `ira_martis` | Ira Martis | Wrath of Mars | 15 kills in one life without dying. |
| `invictus` | Invictus | Unconquered | 20 kills in one life without dying. |
| **Streak medals** | | | |
| `commeatus` | Commeatus | Supplies | You earn the ammo drop scorestreak (`ammo_drop`). |
| `currus_auxilii` | Currus Auxilii | Chariot of aid | You earn the support chariot scorestreak (`support_chariot`). |
| `fulmen_iovis` | Fulmen Iovis | Thunderbolt of Jupiter | You earn the orbital bombardment scorestreak (`orbital_bombardment`). |
| **Hill** | | | |
| `custos_collis` | Custos Collis | Guardian of the hill | Kill an enemy while you and the enemy are both inside the hill. |
| `propugnator` | Propugnator | Defender, champion | 5 Custos Collis-type kills in one match (you and the enemy both inside the hill). Once per match. |
| `expugnator` | Expugnator | Stormer of strongholds | A kill while more than one squad is inside the hill, after which only your squad is inside. |
| `rex_collis` | Rex Collis | King of the hill | Stay inside the hill for 30 s in a row while your squad scores (uncontested). Once per continuous hold. |
| **Assassinations and melee** | | | |
| `sicarius` | Sicarius | Dagger-man, assassin | An assassination (melee kill from behind). |
| `idus_martiae` | Idus Martiae | Ides of March | Assassinate the enemy with the most personal kills in the match (ties count; the victim has at least 1 kill). |
| `comminus` | Comminus | Hand to hand | A melee kill from the front. |
| **Headshots** | | | |
| `caput` | Caput | Head | A headshot kill. |
| `oculus_aquilae` | Oculus Aquilae | Eye of the eagle | Your last 5 kills in one life were all headshots. |
| `longinquus` | Longinquus | From afar | A headshot kill from at least 60 m away. |
| **Saves and squad play** | | | |
| `corona_civica` | Corona Civica | Civic crown (for saving a citizen) | Kill an enemy who damaged a living squadmate of yours within the last 3.0 s. |
| `ultor` | Ultor | Avenger | Kill the enemy who killed a squadmate of yours within the last 10.0 s. |
| `concordia` | Concordia | Harmony | At least 3 living members of your squad (you included) are inside the hill together for 10 s in a row while your squad scores. Once per continuous hold. |
| `dux` | Dux | Leader | Your squad bots make 5 kills in one Denarii chain (the chain resets on bot death, as in the economy rules). |
| **Special** | | | |
| `prima_caedes` | Prima Caedes | First blood | The first kill of the match by anyone. |
| `finis` | Finis | The end (spree breaker) | Kill an enemy who has at least 5 kills in their current life. |

Notes:
- Streak medal triggers name a scorestreak id and hold no threshold. The thresholds (3, 5, 10 in
  DESIGN.md) belong to scorestreaks.json. Sagittarii extra support streaks get no medal in this draft.
- Many medals need features outside milestone 1 (melee, scorestreaks, squad-bot chain). They are
  data only until those features exist.
- The Longinquus distance (60 m) depends on weapon ranges, which are still open (OQ-06).
