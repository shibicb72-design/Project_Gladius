extends RefCounted
## M2B1: metrics shared by the on-demand sims (tests/sim/test_sim_alesia_1km.gd, tests/sim/test_sim_bot_match.gd).
## Not a test file (the runner loads only test_*.gd). Read-only: it connects to signals and reads state, it
## never changes a decision, except the optional --sim-profile / --sim-difficulty / --sim-brain overrides of the
## bots' profile and brain numbers (see bind).
##   Shots: one Pawn.fired is one round (a burst fires one per round); a swing is a fired whose active weapon is
##     melee (Pawn.shot follows fired with the same weapon, pawn.gd fire_shot); hits are hitscan rays that hit a
##     pawn (shot_resolved is hitscan only). gun_hit_rate = hits / (shots - swings).
##   Loot: placed ids are the LootField items on the first frame it reports `placed`; any later id is a dropped
##     id (LootField.drop gives every drop a new id). An id that vanishes was taken (LootField.take is the only
##     removal, MatchDirector.try_pickup its only caller); it is credited to the nearest not-DEAD pawn within the
##     director's pickup range of the item's position. The sim reads at physics_frame, before this tick's
##     nodes run, so the picker may have moved one tick since its pickup: CREDIT_SLACK_M covers that.
##     An id that appeared and vanished between two reads (a gun dropped and taken in the same tick) has no
##     known position: it counts in `flash`.
##   CPU proxy: BotBrain.brain_usec / think_ticks summed over the bots (wall clock, report only).

const BOTS_PATH := "res://data/bots.json"
const CREDIT_SLACK_M := 0.5
## LootField.nearest's height window (2 m), plus the slack.
const CREDIT_DY_M := 2.0

var m: MatchRoot
var profile_name := ""
var shots := {}  # player id -> rounds fired (guns and swings)
var swings := {}  # player id -> blade swings
var hits := {}  # player id -> hitscan rays that hit a pawn
var last_melee := {}  # player id -> whether its last fire was the blade
var pickup_range_m := 0.0
var loot_placed := -1
var taken_placed := 0
var taken_dropped := 0
var uncredited := 0
var flash := 0
var pickups := {}  # player id -> items credited
var _placed_ids := {}
var _known := {}  # id -> pos, for every item on the ground at the last read
var _size := -1
var _next := -1
## M2B2 distance bands: band -> gun rounds / hits. A gun round's band is the shooter's flat (x,z) distance to its
## Brain's target_id pawn at the `fired` signal; "none" without a Brain, without a target or with the target pawn
## missing. A hit (shot_resolved, emitted later in the same Pawn.fire_shot call) counts in the band of that
## shooter's latest gun round.
const BANDS: Array[String] = ["0-15", "15-40", "40-80", "80+", "none"]
var band_shots := {}  # band -> gun rounds
var band_hits := {}  # band -> hitscan rays that hit a pawn
var _last_band := {}  # player id -> band of its latest gun round


## The --sim-profile=<name> user argument (after `--`), "" when absent.
static func cli_profile() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sim-profile="):
			return a.substr(14)
	return ""


## M2 B4: the --sim-difficulty=<level> user argument (after `--`), a data/bots.json "difficulty" level id; "" when
## absent. The level is applied after --sim-profile and before --sim-brain (see bind).
static func cli_difficulty() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sim-difficulty="):
			return a.substr(17)
	return ""


## --sim-brain=<path>=<number>[,<path>=<number>...] (after `--`): SIM-LOCAL overrides of data/bots.json "brain"
## numbers for this run's bots, for tuning runs, e.g. --sim-brain=fight.band_far_frac=0.25,fight.sight_by_weapon.pilum_br=60.
## {} when absent. The SIM line shows them after the profile name (profile=tiro+fight.band_far_frac=0.25).
static func cli_brain_overrides() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sim-brain="):
			for part in a.substr(12).split(",", false):
				var eq := part.rfind("=")
				if eq > 0:
					out[part.substr(0, eq)] = float(part.substr(eq + 1))
	return out


## --sim-scale=<number> (after `--`): the zone and carrier time scale of the 1 km sim; `fallback` when absent.
static func cli_scale(fallback: float) -> float:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sim-scale="):
			return float(a.substr(12))
	return fallback


## --sim-seed=<n> (after `--`): the match seed of the 1 km sim; `fallback` when absent.
static func cli_seed(fallback: int) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sim-seed="):
			return int(a.substr(11))
	return fallback


## M2 Z2: --sim-length=<id> (after `--`): a data/br.json "match_length" option id for the 1 km sim; "" when absent.
static func cli_length() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sim-length="):
			return a.substr(13)
	return ""


## The distance band of a flat distance in metres.
static func band_of(dist_m: float) -> String:
	if dist_m < 15.0:
		return "0-15"
	if dist_m < 40.0:
		return "15-40"
	if dist_m < 80.0:
		return "40-80"
	return "80+"


## The band of pawn `p`'s current shot: its flat distance to the pawn its Brain targets, "none" without one.
func _shot_band(p: Pawn) -> String:
	var brain := p.get_node_or_null("Brain") as BotBrain
	if brain == null or brain.target_id < 0:
		return "none"
	var t = m.director.all_players().get(brain.target_id)
	if t == null or not is_instance_valid(t) or not t is Pawn:
		return "none"
	var a: Vector3 = p.global_position
	var b: Vector3 = (t as Pawn).global_position
	return band_of(Vector2(a.x - b.x, a.z - b.z).length())


## Call right after m.begin() (before the first physics tick). Applies --sim-profile to every bot Brain (the
## bots.json profile dictionary, as BotSpawner.attach_brain would hand it; the brain reads `profile` only while
## it thinks) and connects the shot counters. Returns the profile name in use, "" for an unknown --sim-profile.
## M2 B4: --sim-difficulty=<level> then applies that bots.json difficulty level (MatchRoot.apply_bot_difficulty: the
## level's accuracy, reaction_time_s and fight.settle_*) on top of the profile and names the run after the level
## (profile=<level>); --sim-brain overrides still come last and win. "" for an unknown level. Without the argument
## nothing changes.
func bind(match_root: MatchRoot) -> String:
	m = match_root
	var cfg := DataRegistry.new().load_file(BOTS_PATH)
	var profiles: Dictionary = cfg.get("profiles", {})
	var want := cli_profile()
	var level := cli_difficulty()
	if level != "" and MatchRoot.bot_difficulty_level(level).is_empty():
		return ""
	if want == "":
		profile_name = String(cfg.get("match_fill", {}).get("profile", "tiro"))
	elif not profiles.has(want):
		return ""
	else:
		profile_name = want
		for b in m.bots:
			var brain := b.get_node_or_null("Brain") as BotBrain
			if brain != null:
				brain.profile = (profiles[want] as Dictionary).duplicate(true)
	if level != "":
		MatchRoot.apply_bot_difficulty(m.bots, level)
		profile_name = level
	var overrides := cli_brain_overrides()
	if not overrides.is_empty():
		var shown: Array[String] = []
		for path in overrides:
			shown.append("%s=%s" % [path, overrides[path]])
		profile_name += "+" + ",".join(shown)
		for b in m.bots:
			var brain := b.get_node_or_null("Brain") as BotBrain
			if brain == null:
				continue
			brain.cfg = brain.cfg.duplicate(true)  # this sim's bots only; bots.json stays as it is
			for path in overrides:
				var keys: PackedStringArray = String(path).split(".")
				var d: Dictionary = brain.cfg
				for i in keys.size() - 1:
					if not d.has(keys[i]) or not d[keys[i]] is Dictionary:
						d[keys[i]] = {}
					d = d[keys[i]]
				d[keys[keys.size() - 1]] = overrides[path]
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		p.fired.connect(func() -> void: shots[id] = int(shots.get(id, 0)) + 1)
		p.shot.connect(func(_o: Vector3, _d: Vector3, _w: String) -> void:
			var w := p.loadout.get_active() if p.loadout != null else null
			var melee := w != null and w.def.is_melee()
			last_melee[id] = melee
			if melee:
				swings[id] = int(swings.get(id, 0)) + 1)
		p.shot_resolved.connect(func(_o: Vector3, _e: Vector3, hit: Dictionary) -> void:
			if not hit.is_empty() and hit.get("target") is Pawn:
				hits[id] = int(hits.get(id, 0)) + 1)
		p.fired.connect(func() -> void:
			var w := p.loadout.get_active() if p.loadout != null else null
			if w == null or w.def.is_melee():
				return
			var band := _shot_band(p)
			_last_band[id] = band
			band_shots[band] = int(band_shots.get(band, 0)) + 1)
		p.shot_resolved.connect(func(_o: Vector3, _e: Vector3, hit: Dictionary) -> void:
			if not hit.is_empty() and hit.get("target") is Pawn:
				var band: String = _last_band.get(id, "none")
				band_hits[band] = int(band_hits.get(band, 0)) + 1)
	return profile_name


## Once per sim frame.
func loot_step() -> void:
	var loot := m.loot
	if loot == null or not loot.placed:
		return
	var nxt: int = loot._next_id
	if loot_placed < 0:
		loot_placed = loot.items.size()
		pickup_range_m = m.director._pickup_range()
		for id in loot.items:
			_placed_ids[id] = true
			_known[id] = loot.items[id]["pos"]
		_size = loot.items.size()
		_next = nxt
		return
	# A take shrinks `items`, a drop raises _next_id: nothing changed when neither moved.
	if loot.items.size() == _size and nxt == _next:
		return
	var gone: Array = []
	for id in _known:
		if not loot.items.has(id):
			gone.append(id)
	for id in gone:
		_credit(id, _known[id])
		_known.erase(id)
	for id in range(_next, nxt):
		if loot.items.has(id):
			_known[id] = loot.items[id]["pos"]
		else:
			flash += 1
	_size = loot.items.size()
	_next = nxt


func _credit(id: int, pos: Vector3) -> void:
	var best := -1
	var best_d := INF
	for pid in m.director.all_players():
		var p: Pawn = m.director.player(pid)
		if p == null or p.life == Pawn.Life.DEAD:
			continue
		var gp := p.global_position
		if absf(gp.y - pos.y) > CREDIT_DY_M + CREDIT_SLACK_M:
			continue
		var d := Vector2(gp.x - pos.x, gp.z - pos.z).length()
		if d <= pickup_range_m + CREDIT_SLACK_M and d < best_d:
			best = pid
			best_d = d
	if best < 0:
		uncredited += 1
		return
	pickups[best] = int(pickups.get(best, 0)) + 1
	if _placed_ids.has(id):
		taken_placed += 1
	else:
		taken_dropped += 1


static func total(counts: Dictionary) -> int:
	var t := 0
	for k in counts:
		t += int(counts[k])
	return t


func total_shots() -> int:
	return total(shots)


func total_swings() -> int:
	return total(swings)


func total_hits() -> int:
	return total(hits)


func gun_hit_rate() -> float:
	var gun := total_shots() - total_swings()
	return float(total_hits()) / float(gun) if gun > 0 else 0.0


## Pickups over every bot of the match (pawns with a Brain child; zeros included): {mean, min, max}.
func bot_pickups() -> Dictionary:
	var n := 0
	var sum := 0
	var lo := -1
	var hi := 0
	for b in m.bots:
		if not b.has_node("Brain"):
			continue
		var c := int(pickups.get(b.player_id, 0))
		n += 1
		sum += c
		lo = c if lo < 0 else mini(lo, c)
		hi = maxi(hi, c)
	return {"mean": float(sum) / float(n) if n > 0 else 0.0, "min": maxi(lo, 0), "max": hi}


## The deterministic loot fields of the SIM line.
func loot_fields() -> String:
	var bp := bot_pickups()
	var left: int = m.loot.items.size() if m.loot != null else -1
	return "loot_placed=%d loot_left=%d loot_taken_placed=%d loot_taken_dropped=%d loot_uncredited=%d loot_flash=%d pickups_per_bot=%.2f pickups_min=%d pickups_max=%d" % [
			loot_placed, left, taken_placed, taken_dropped, uncredited, flash, bp["mean"], bp["min"], bp["max"]]


## M2 L1b: the deterministic prop fields of the SIM line, read at the end of the match from MatchRoot.world_props:
## breakables broken, chests opened, items the props spilled (WorldProps.spilled) and how many of those are gone
## from the ground (LootField.take is the only removal, so gone = taken). All 0 on a map without props.
## M2 L1c commit 4: doors are stored as OPEN / CLOSED in the same states, so chests_opened counts only chest ids.
func prop_fields() -> String:
	var props: WorldProps = m.world_props if m != null else null
	var broken := 0
	var opened := 0
	var spilled := 0
	var taken := 0
	if props != null and is_instance_valid(props):
		for id: String in props.states:
			match int(props.states[id]):
				WorldProps.BROKEN:
					broken += 1
				WorldProps.OPEN:
					if props.chests.has(id):
						opened += 1
		spilled = props.spilled.size()
		for item_id: int in props.spilled:
			if m.loot != null and not m.loot.items.has(item_id):
				taken += 1
	return "props_broken=%d chests_opened=%d prop_loot=%d prop_loot_taken=%d" % [broken, opened, spilled, taken]


## The deterministic shot fields of the SIM line.
func shot_fields() -> String:
	return "shots=%d swings=%d gun_shots=%d hits=%d gun_hit_rate=%.3f" % [
			total_shots(), total_swings(), total_shots() - total_swings(), total_hits(), gun_hit_rate()]


## The deterministic distance-band fields of the SIM_BANDS line: band:gun_rounds/hits/hit_rate for each band.
func bands_fields() -> String:
	var parts: Array[String] = []
	for band in BANDS:
		var s := int(band_shots.get(band, 0))
		var h := int(band_hits.get(band, 0))
		parts.append("%s:%d/%d/%.3f" % [band, s, h, float(h) / float(s) if s > 0 else 0.0])
	return "bands=" + " ".join(parts)


## The wall-clock CPU proxy (after " | " only): microseconds per think tick, coasts included, over the bots.
## Dead bots keep their pawn and Brain (MatchDirector only deactivates a DEAD pawn), so the end-of-match read
## sees every bot; brains_missing reports any that were not readable.
func cpu_fields() -> String:
	var usec := 0
	var think := 0
	var ticks := 0
	var missing := 0
	for b in m.bots:
		var brain: BotBrain = b.get_node_or_null("Brain") as BotBrain if is_instance_valid(b) else null
		if brain == null:
			missing += 1
			continue
		usec += brain.brain_usec
		think += brain.think_ticks
		ticks += brain.brain_ticks
	return "brain_us_per_think=%.1f think_ticks=%d brain_ticks=%d brains_missing=%d" % [
			float(usec) / float(think) if think > 0 else 0.0, think, ticks, missing]
