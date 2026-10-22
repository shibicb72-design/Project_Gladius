# Player traits: DRAFT for Shibi's approval

> **DRAFT (task T1).** Shibi asked for proposals to approve, so everything here is a proposal and
> not a design decision. Names, rules and numbers can all change.
> **Build steps must not wire traits into gameplay, UI or the economy until Shibi approves**
> (docs/OPEN_QUESTIONS.md OQ-42). The data lives in `data/traits.json` (`"status": "DRAFT - awaiting
> Shibi approval"`). This doc mirrors that file. Code reads every number from the JSON; none are in code.

## What DESIGN.md fixes

- Player traits/banners are Roman virtues. Bad ones such as **Deserter** and **Carthaginian** fade
  with the opposite behavior.
- Traits show in the lobby. Only bad ones show in-game, as a small banner.
- Traits are cosmetic for now. Effects are provisioned only: every trait has an empty `"effects": []`
  list, and nothing reads it yet.

## How rules work (proposal)

Rules are evaluated after each counted match, from per-match stats. Only multiplayer matches count:
modes listed in `counted_matches.modes` (now `koth`), never tutorial or campaign (OQ-44).

| Rule type | Meaning |
|---|---|
| `lifetime_sum` | Sum of `stat` over all counted matches >= `min`. |
| `lifetime_count` | Number of counted matches where every `where` condition holds >= `count`. |
| `consecutive` | The last `count` counted matches all meet every `where` condition. |
| `window_count` | Among the last `window` counted matches, at least `count` meet every `where` condition. |

An optional `scope` list narrows which matches are looked at at all (for example only matches you
hosted, or only King of the Hill matches).

- Good traits stay once earned (`good_traits_permanent: true`; OQ-43).
- A bad trait is earned by its `earn` rule and removed by its `fade` rule. Fading needs a
  `consecutive` run, so one relapse restarts the run.
- A player can hold a good trait and a bad trait at the same time (for example Fides and Deserter).

### Per-match stats the rules use

| Stat | Meaning |
|---|---|
| `mode` | Mode id of the match. |
| `finished` | 1 if you were still in the match when it ended. |
| `quit` | 1 if you chose to leave before the end (whether a lost connection counts: OQ-44). |
| `won` | 1 if your squad won; a draw is 0. |
| `was_host` | 1 if your phone hosted the match. |
| `host_abandoned` | 1 if you hosted and the match closed because you left or did not return within the host-drop reconnect pause. |
| `kills` | Enemies (human or bot) you killed yourself; squad-bot kills not included (OQ-46). |
| `deaths` | Times you died, suicides included. |
| `suicides` | Deaths with no enemy credited (own grenade, fall, own mine...). |
| `headshot_kills` | Kills where the killing hit was a headshot. |
| `assassinations` | Melee kills from behind. |
| `hill_seconds` | Seconds you spent inside the hill. |
| `hill_defense_kills` | Kills that met the Custos Collis medal trigger (medals.md). |
| `saves` | Kills that met the Corona Civica medal trigger (medals.md). |
| `squad_bot_kills` | Kills made by your squad bots. |
| `medals` | Medals you earned in the match. |
| `afk_timeouts` | Times the killcam timed out and you were respawned at a random spot (anti-AFK). |
| `spawn_kills` | Kills on enemies whose spawn protection ended less than 3 s earlier (`window_after_protection_s`). |
| `kill_death_ratio` | Derived: kills / max(deaths, 1). |
| `headshot_ratio` | Derived: headshot_kills / max(kills, 1). |

## Good traits (15)

| id | Latin name | English meaning | Earned when |
|---|---|---|---|
| `virtus` | Virtus | Valor | 250 kills in total (`lifetime_sum` kills >= 250). |
| `pietas` | Pietas | Dutiful devotion | 50 matches finished in total. |
| `fides` | Fides | Good faith, loyalty | 10 matches in a row finished without quitting. |
| `disciplina` | Disciplina | Military discipline | 10 matches in a row finished with 0 suicides and 0 AFK timeouts. |
| `gravitas` | Gravitas | Composure, seriousness | 10 finished matches with at least 5 kills and at most 5 deaths. |
| `constantia` | Constantia | Steadfastness | 10 lost matches (won = 0) played to the end. |
| `dignitas` | Dignitas | Prestige, standing | 100 medals in total. |
| `auctoritas` | Auctoritas | Authority of command | 100 squad-bot kills in total. |
| `clementia` | Clementia | Mercy | 10 matches won with 0 spawn kills. |
| `prudentia` | Prudentia | Prudence | 10 matches with at least 5 kills and a kill/death ratio of at least 2.0. |
| `industria` | Industria | Diligence, hard work | 3600 seconds (1 hour) on the hill in total. |
| `firmitas` | Firmitas | Firmness, tenacity | 100 hill-defense kills in total. |
| `diligentia` | Diligentia | Precision, care | 10 matches with at least 5 kills and a headshot ratio of at least 0.5. |
| `comitas` | Comitas | Comradeship | 50 saves in total. |
| `felicitas` | Felicitas | Good fortune, success | 25 wins in total. |

## Bad traits (6)

All bad traits show in the lobby and as a small in-game banner (`show_in_game_banner: true`).

| id | Display name | Latin name | English meaning | Earned when | Fades when (opposite behavior) |
|---|---|---|---|---|---|
| `deserter` | Deserter | Desertor | Deserter | Quit at least 2 of your last 10 matches. | 5 matches in a row finished. |
| `carthaginian` | Carthaginian | Poenus | Carthaginian: one who breaks faith ("Punic faith") | In your last 10 hosted matches, at least 2 closed because you abandoned them as host. | 5 hosted matches in a row played to the end, none abandoned. |
| `ignavus` | Ignavus | Ignavus | Shirker, coward | In your last 10 King of the Hill matches, at least 3 finished with 0 seconds on the hill. | 3 King of the Hill matches in a row finished with at least 30 s on the hill. |
| `iners` | Iners | Iners | Idle, inactive | In your last 10 matches, at least 2 with 2 or more AFK timeouts. | 5 matches in a row finished with 0 AFK timeouts. |
| `temerarius` | Temerarius | Temerarius | Reckless | In your last 10 matches, at least 3 with 3 or more suicides. | 5 matches in a row finished with 0 suicides. |
| `latro` | Latro | Latro | Brigand (spawn camper) | In your last 10 matches, at least 2 with 5 or more spawn kills. | 5 matches in a row finished with 0 spawn kills. |

Notes:
- **Carthaginian** is DESIGN.md's name, but DESIGN.md does not say what behavior earns it. Since
  there is no friendly fire, this draft reads "Punic faith" as a host who walks out on everyone in
  the match. Deserter covers players who quit. OQ-45 asks Shibi to confirm or pick another meaning.
- **Latro** matters because each squad keeps one fixed spawn spot for the whole match, so camping a
  spawn spot is a real abuse.

## Not decided (left as TODO)

- How many traits the lobby shows per player, and whether a player with several bad traits shows one
  banner or several (OQ-48).
- What the provisioned `effects` would ever do. They stay empty.
