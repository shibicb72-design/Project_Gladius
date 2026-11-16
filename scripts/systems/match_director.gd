class_name MatchDirector
extends Node
## Owns BrRules for one match. Builds the per-tick facts, acts on the rules' events (zone damage, life
## states, kills) and emits signals for the HUD. Authoritative side only: a client runs no rules.

signal zone_changed()
signal alive_changed(players_alive: int, squads_alive: int)
signal player_downed(player_id: int)
signal player_revived(player_id: int)
signal player_eliminated(player_id: int, killer_id: int, cause: String)
signal match_over(result: Dictionary)

const MODE_ID := "br"

## Loaded from data/*.json in load_config(); tests may override before start().
var mode_cfg: Dictionary = {}
var match_cfg: Dictionary = {}
## data/loot.json with the map's loot overrides (load_config); MatchRoot hands it to the LootField.
var loot_cfg: Dictionary = {}
const LOOT_PATH := "res://data/loot.json"
var rules: BrRules
var running: bool = false
## The seed start() was given; bots and pawns derive their own RNG seeds from it (G0).
var match_seed: int = 0
## False on a network client: no rules ticking or match_over of its own. The result arrives from the host
## through apply_remote_match_over. TODO(M3): zone and downed state are not replicated yet.
var authoritative: bool = true
## Rule ticks run so far (tests use it to see whether the simulation advances, e.g. under a pause menu).
var tick_count: int = 0

var _players: Dictionary = {}  # player id -> Pawn
var _spawn_xforms: Dictionary = {}  # spot id -> Transform3D
var _slot_in_squad: Dictionary = {}  # player id -> index within its squad
var _reviving: Dictionary = {}  # reviver player id -> target player id (revive input)


# --- M2 Z2 match length (OQ-BR-LENGTH) ---
## The last match length info (apply_match_length's return) from load_config; {} before the first load. The sim
## prints it.
var match_length_info: Dictionary = {}


## Loads mode_cfg (data/br.json through modes.json), match_cfg and loot_cfg (data/loot.json). M2L1 (binding fixes
## 3, 21): with a map json, its "overrides" {"br": {...}, "loot": {...}} are deep-merged over br and loot for this
## match only (merge_overrides). This is the one place the merge happens: MatchRoot.begin calls load_config(map)
## only while mode_cfg is empty, so a caller that loads the config and then edits it (the sim's faster phases)
## keeps its edits. Without a map (every existing caller) the configs are the plain files.
## M2 Z2 (OQ-BR-LENGTH): with a `length_id` (an id of br.json "match_length".options), the zone schedule of the
## merged config is then stretched to that length (apply_match_length), before any caller can edit the phases;
## the result is kept in match_length_info. With length_id "" the phases are not touched at all.
func load_config(map_json: String = "", length_id: String = "") -> void:
	var reg := DataRegistry.new()
	mode_cfg = ModeRegistry.merged_config(MODE_ID, reg.load_file("res://data/modes.json"))
	match_cfg = reg.load_file("res://data/match.json").duplicate(true)
	loot_cfg = reg.load_file(LOOT_PATH).duplicate(true)
	if map_json != "":
		var overrides := map_overrides(map_json)
		mode_cfg = merge_overrides(mode_cfg, overrides.get("br", {}))
		loot_cfg = merge_overrides(loot_cfg, overrides.get("loot", {}))
	match_length_info = apply_match_length(mode_cfg, length_id)


## The nominal zone schedule of `cfg`: the sum of every phase's wait_s + shrink_s (the time at which the last
## circle finishes closing); 0.0 when the phases are missing or malformed. Pure.
static func zone_nominal_s(cfg: Dictionary) -> float:
	var zone: Variant = cfg.get("zone", {})
	var phases: Variant = zone.get("phases", []) if typeof(zone) == TYPE_DICTIONARY else []
	if typeof(phases) != TYPE_ARRAY:
		return 0.0
	var total := 0.0
	for ph: Variant in phases:
		if typeof(ph) != TYPE_DICTIONARY or not _length_num(ph.get("wait_s")) or not _length_num(ph.get("shrink_s")):
			return 0.0
		total += float(ph["wait_s"]) + float(ph["shrink_s"])
	return total


static func _length_num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## Stretches the zone schedule of `cfg` IN PLACE to the "match_length" option `length_id`: minutes = the nominal
## time at which the last circle finishes closing (Lanista's reading, OQ-BR-LENGTH). factor = minutes x 60 / the
## sum of every phase's wait_s + shrink_s; every wait_s and shrink_s is multiplied by it (floats, never rounded).
## radius_m, damage_per_s, the phase order, the start circle, the drop (carrier_s ...) and loot are not touched.
## Returns {id, minutes, factor, last_close_s, nominal_s, applied}. length_id "" changes nothing (applied false,
## no warning). An unknown id, a malformed option or schedule, or a factor below 1.0 is rejected with one
## push_warning and changes nothing (applied false). Why factor < 1.0 is rejected: a shorter schedule than the
## map's own would move the zone edge faster than the generator's edge-speed cap (alesia_1km.json
## zone_gen.edge_speed_cap_mps, 4 m/s, tools/gen_zone.gd) and could break the drop rule (the last forced drop
## must land before the first wait ends).
static func apply_match_length(cfg: Dictionary, length_id: String) -> Dictionary:
	var nominal := zone_nominal_s(cfg)
	var info := {"id": length_id, "minutes": 0.0, "factor": 1.0, "last_close_s": nominal, "nominal_s": nominal,
			"applied": false}
	if length_id == "":
		return info
	var opt := match_length_option(cfg, length_id)
	var why := ""
	if opt.is_empty():
		why = "unknown id"
	elif not _length_num(opt.get("minutes")) or float(opt["minutes"]) <= 0.0:
		why = "malformed option (minutes must be a number > 0)"
	elif nominal <= 0.0:
		why = "malformed zone phases"
	else:
		info["minutes"] = float(opt["minutes"])
		var factor := float(opt["minutes"]) * 60.0 / nominal
		if factor < 1.0:
			why = "factor %.3f < 1.0 (shorter than the map's own %.0f s schedule)" % [factor, nominal]
		else:
			for ph: Dictionary in cfg["zone"]["phases"]:
				ph["wait_s"] = float(ph["wait_s"]) * factor
				ph["shrink_s"] = float(ph["shrink_s"]) * factor
			info["factor"] = factor
			info["last_close_s"] = zone_nominal_s(cfg)
			info["applied"] = true
			return info
	push_warning("match_length '%s' rejected: %s; the map's own zone schedule is used (OQ-BR-LENGTH)" % [length_id, why])
	return info


## The "match_length" option dictionary with this id in `cfg`, or {} (unknown id, missing or malformed block).
static func match_length_option(cfg: Dictionary, length_id: String) -> Dictionary:
	for opt: Dictionary in match_length_options(cfg):
		if str(opt.get("id", "")) == length_id:
			return opt
	return {}


## The option dictionaries of cfg["match_length"]["options"] (non-dictionary entries skipped), in data order.
static func match_length_options(cfg: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var block: Variant = cfg.get("match_length", {})
	var opts: Variant = block.get("options", []) if typeof(block) == TYPE_DICTIONARY else []
	if typeof(opts) == TYPE_ARRAY:
		for opt: Variant in opts:
			if typeof(opt) == TYPE_DICTIONARY:
				out.append(opt)
	return out


## The data default id (cfg["match_length"]["default"]); "" when the block has none.
static func match_length_default_id(cfg: Dictionary) -> String:
	var block: Variant = cfg.get("match_length", {})
	return str(block.get("default", "")) if typeof(block) == TYPE_DICTIONARY else ""


## A short label for an option from its data, e.g. "15 min"; "" for an unknown id.
static func match_length_label(cfg: Dictionary, length_id: String) -> String:
	var opt := match_length_option(cfg, length_id)
	if opt.is_empty() or not _length_num(opt.get("minutes")):
		return ""
	var minutes := float(opt["minutes"])
	return "%s min" % (str(int(minutes)) if is_equal_approx(minutes, roundf(minutes)) else "%.1f" % minutes)


## `length_id` when it names an option, else the data default (quiet: for saved profiles and lobby values).
static func validated_match_length_id(cfg: Dictionary, length_id: String) -> String:
	return length_id if not match_length_option(cfg, length_id).is_empty() else match_length_default_id(cfg)
# --- end M2 Z2 match length ---


## M2L1: the "overrides" block of a map json ({} when it has none or the file is unreadable). Quiet.
static func map_overrides(map_json: String) -> Dictionary:
	var block: Variant = DataRegistry.parse_quiet(map_json).get("overrides", {})
	return block if typeof(block) == TYPE_DICTIONARY else {}


## M2L1: `over` deep-merged into a copy of `base`: dictionaries merge by key recursively, arrays and scalars
## replace, keys starting with "_" (notes) are not merged. Neither argument changes.
static func merge_overrides(base: Dictionary, over: Variant) -> Dictionary:
	var out: Dictionary = base.duplicate(true)
	if typeof(over) != TYPE_DICTIONARY:
		return out
	for key: Variant in over:
		if str(key).begins_with("_"):
			continue
		var value: Variant = over[key]
		if typeof(value) == TYPE_DICTIONARY:
			out[key] = merge_overrides(out[key] if typeof(out.get(key)) == TYPE_DICTIONARY else {}, value)
		else:
			out[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	return out


## "solo" or "squads", from the merged br config (data default: solo).
static func team_mode_of(cfg: Dictionary) -> String:
	return str(cfg.get("teams", {}).get("mode", {}).get("value", "solo"))


## {squad_count, squad_size} for a roster of match_cfg.max_players: solo = N squads of 1,
## squads = squads of teams.squad_size_max.
static func team_layout(cfg: Dictionary, match_cfg_in: Dictionary) -> Dictionary:
	var total := int(match_cfg_in.get("max_players", 18))
	if team_mode_of(cfg) == "solo":
		return {"squad_count": total, "squad_size": 1}
	var size := maxi(int(cfg.get("teams", {}).get("squad_size_max", 3)), 1)
	return {"squad_count": int(ceil(float(total) / float(size))), "squad_size": size}


func team_mode() -> String:
	return team_mode_of(mode_cfg)


## Zone target circle for bots and later HUD/visuals; start circle before the rules exist.
func zone_target_center() -> Vector3:
	var c := rules.zone_target_center() if rules != null else Vector2.ZERO
	return Vector3(c.x, 0.0, c.y)


func zone_target_radius() -> float:
	return rules.zone_target_radius() if rules != null else 0.0


func add_player(player_id: int, pawn: Pawn) -> void:
	_players[player_id] = pawn
	pawn.player_id = player_id
	pawn.health_zeroed.connect(_on_pawn_health_zeroed.bind(player_id))


## Builds BrRules from mode_cfg as it is now, registers every pawn and places the squads.
## Returns false if the rules config is unusable or there are no spawn spots.
func start(spawn_xforms: Dictionary, seed_value: int = 1, use_drop: bool = false) -> bool:
	_spawn_xforms = spawn_xforms
	if spawn_xforms.is_empty():
		return false
	rules = ModeRegistry.create(MODE_ID, {MODE_ID: mode_cfg}) as BrRules
	if rules == null or not rules.config_problems().is_empty():
		return false
	rules.set_seed(seed_value)
	rules.set_team_mode(team_mode())
	match_seed = seed_value
	var downed_pct := float(_downed_cfg().get("downed_move_speed_pct", 100.0))
	var ids: Array = _players.keys()
	ids.sort()
	for id in ids:
		var pawn: Pawn = _players[id]
		if not rules.register_player(id, pawn.squad_id):
			return false
		pawn.set_squad(rules.squad_of(id))  # solo: every player is its own squad (friendly fire, bot targets)
		pawn.seed_rng(hash([seed_value, id]))
		pawn.downed_move_speed_pct = downed_pct
		pawn.downed_body_height_m = float(_downed_cfg().get("downed_body_height_m", -1.0))
		pawn.downed_head_y_m = float(_downed_cfg().get("downed_head_y_m", -1.0))
	_slot_in_squad.clear()
	var members: Dictionary = {}  # squad id -> count so far
	for id in ids:
		var sq: int = _players[id].squad_id
		_slot_in_squad[id] = int(members.get(sq, 0))
		members[sq] = _slot_in_squad[id] + 1
	var squad_ids: Array = members.keys()
	squad_ids.sort()
	var spots: Array = spawn_xforms.keys()
	spots.sort()
	for id in ids:
		_place(id, squad_ids, spots)
	if use_drop:
		_begin_drop(seed_value, ids)
	if loot != null:
		var kit: Dictionary = loot.cfg.get("start_kit", {})
		for id in ids:
			(_players[id] as Pawn).apply_start_kit(kit)
	running = true
	zone_changed.emit()
	alive_changed.emit(players_alive(), squads_alive())
	return true


## ---- Ground loot (S4; LootField + data/loot.json). Set by MatchRoot before start(); null = no loot,
## and pawns keep their class loadouts (tests that do not opt in). ----
var loot: LootField
## M2 L1b: the match's breakables and loot chests: state and seeded loot (WorldProps, set by MatchRoot.begin
## before start(); null in tests that build no match root).
var props: WorldProps


func _pickup_range() -> float:
	return float(loot.cfg.get("pickup_range_m", 2.0)) if loot != null else 0.0


## The loot item `player_id` could pick up now (nearest in range that it can use); -1 if none.
func pickup_target_for(player_id: int, bot_rules: bool = false) -> int:
	var pawn: Pawn = _players.get(player_id)
	if loot == null or not running or pawn == null:
		return -1
	var low := bot_ammo_low_magazines()
	# Nearest item in range that this pawn can use (bots: that it wants), so an unwanted item lying on
	# top of a wanted one never blocks it.
	var usable := func(item_id: String) -> bool:
		var d := loot.def(item_id)
		return pawn.wants_item(d, low) if bot_rules else pawn.can_take(d)
	return loot.nearest(pawn.global_position, _pickup_range(), usable)


var _bot_ammo_low := -1.0
var _bot_heal_below := -1.0


## data/bots.json brain.ammo_low_magazines (placeholder, OQ-31): bots take ammo below this many magazines.
func bot_ammo_low_magazines() -> float:
	if _bot_ammo_low < 0.0:
		_bot_ammo_low = float(DataRegistry.new().load_file("res://data/bots.json").get("brain", {}).get("ammo_low_magazines", 2.0))
	return _bot_ammo_low


## data/bots.json brain.heal_below_health_pct (placeholder, OQ-HEAL-ITEM): bots want a Bandage only below it.
func bot_heal_below_pct() -> float:
	if _bot_heal_below < 0.0:
		_bot_heal_below = float(DataRegistry.new().load_file("res://data/bots.json").get("brain", {}).get("heal_below_health_pct", 70.0))
	return _bot_heal_below


## Picks up the current pickup target; a replaced gun goes on the ground. False if nothing to take.
func try_pickup(player_id: int, bot_rules: bool = false) -> bool:
	var id := pickup_target_for(player_id, bot_rules)
	if id < 0:
		return false
	var pawn: Pawn = _players[player_id]
	var item := loot.take(id)
	var dropped := pawn.take_item(item, loot.def(str(item["item_id"])))
	if not dropped.is_empty():
		loot.drop(dropped, pawn.global_position)
	return true


## M2 L1b: the closed chest `player_id` could open now (WorldProps.chest_near from its feet), with pickup's
## conditions (a running match, an alive pawn that is not dropping; a DOWNED or dead pawn is not alive); "" if none.
func chest_target_for(player_id: int) -> String:
	var pawn: Pawn = _players.get(player_id)
	if props == null or not running or pawn == null or not pawn.is_alive() or pawn.is_dropping():
		return ""
	return props.chest_near(pawn.global_position)


## M2 L1b: opens the current chest target on the authority (WorldProps.open_chest spills its seeded roll). False
## on a client or when no chest is in range.
func try_open_chest(player_id: int) -> bool:
	if not authoritative:
		return false
	var id := chest_target_for(player_id)
	return id != "" and props.open_chest(id)


## M2 L1c: the door or gate `player_id` would toggle now (WorldProps.door_near from its feet: the nearest one in its
## kind's range, open or closed), with pickup's conditions (a running match, an alive pawn that is not dropping);
## "" if none.
func door_target_for(player_id: int) -> String:
	var pawn: Pawn = _players.get(player_id)
	if props == null or not running or pawn == null or not pawn.is_alive() or pawn.is_dropping():
		return ""
	return props.door_near(pawn.global_position)


## M2 L1c: toggles the current door target on the authority (WorldProps.toggle_door: the other ABSOLUTE state, sent
## by the bridge as that value). False on a client or when no door is in range. Nothing else is touched.
func try_toggle_door(player_id: int) -> bool:
	if not authoritative:
		return false
	var id := door_target_for(player_id)
	return id != "" and props.toggle_door(id)


func _bot_pickups() -> void:
	if loot == null:
		return
	for id in _players:
		var pawn: Pawn = _players[id]
		if pawn.has_node("Brain") and pawn.is_alive() and not pawn.is_dropping():
			try_pickup(id, true)
	_bot_chests()


## M2 L1b: after every bot's pickup, a bot opens any closed chest in range (no chest goal in the brain,
## OQ-PROPS-CHEST). A separate pass, so this tick's pickups are exactly what they were before chests.
func _bot_chests() -> void:
	if props == null or props.chests.is_empty():
		return
	for id in _players:
		if (_players[id] as Pawn).has_node("Brain"):
			try_open_chest(id)


## ---- Bots and doors (M2 L1c commit 4; data/props.json door bot_open_delay_s, OQ-PROPS-DOOR) ----
## Paths are planned as if every door were open (doors are outside the Nav bake), so a bot whose way forward runs
## through a CLOSED door opens it: this director pass, not the brain's goal logic (bot_brain.gd is untouched).
## Condition, per bot and closed door, every tick: the bot (a pawn with a Brain) is alive and not dropping; it is in
## the door's kind range (WorldProps.door_near's test: flat distance to the closed footprint <= interact_range_m,
## threshold within height_limit_m); its last move input is not zero (it is walking); and its way forward crosses
## the doorway (path_crosses_door: the brain's NavigationAgent3D path read with plain getters, never
## get_next_path_position). A bot walking past along the wall never crosses the door's plane inside the opening.
## Held for bot_open_delay_s (whole director ticks at the physics rate, counted per bot and door; no wall clock, no
## random draw) the door opens through props.set_door(id, OPEN) (authority only, the existing prop_changed event).
## The count resets as soon as the condition fails. Bots never close a door. A client does nothing.
## Timing: bot_open_delay_s + move_time_s stays under data/bots.json stuck_window_s for both kinds (a test checks
## it from the data), so a door never trips the brain's stuck check.
var _bot_door_ticks: Dictionary = {}  # bot player id -> {door id: consecutive ticks the condition held}
var _door_delay_ticks: Dictionary = {}  # door kind -> bot_open_delay_s in ticks (read once)
## Report only (the sims print it on SIM_DOORS): doors and gates opened by this pass.
var bot_doors_opened: int = 0
## How far ahead along the path the crossing is looked for: path points within this many metres of the bot.
## The value in use is data/props.json door bot_path_lookahead_m (OQ-PROPS-DOOR); this is the fallback.
const BOT_DOOR_LOOKAHEAD_M := 6.0
## The crossing point may lie this far outside the opening's edge (the path's corner rounding). The value in use is
## data/props.json door bot_path_edge_m (OQ-PROPS-DOOR); this is the fallback.
const BOT_DOOR_EDGE_M := 0.25


func _bot_door_delay_ticks(kind: String) -> int:
	if not _door_delay_ticks.has(kind):
		var delay_s := float(WorldProps.door_cfg(props.cfg, kind).get("bot_open_delay_s", 0.4))
		_door_delay_ticks[kind] = maxi(ceili(delay_s * float(Engine.physics_ticks_per_second) - 0.001), 1)
	return int(_door_delay_ticks[kind])


func _bot_doors() -> void:
	if props == null or props.doors.is_empty() or not authoritative:
		return
	var closed: Array[Door] = []
	for door_id: String in props.doors:
		var d: Door = props.doors[door_id]
		if is_instance_valid(d) and props.state_of(door_id) == WorldProps.CLOSED:
			closed.append(d)
	if closed.is_empty():
		_bot_door_ticks.clear()
		return
	for id in _players:
		var pawn: Pawn = _players[id]
		var brain := pawn.get_node_or_null("Brain")
		if brain == null or not pawn.is_alive() or pawn.is_dropping() or pawn._frame.move == Vector2.ZERO:
			_bot_door_ticks.erase(id)
			continue
		var agent: NavigationAgent3D = brain.get("_agent")
		var held: Dictionary = _bot_door_ticks.get(id, {})
		var still: Dictionary = {}
		var pos := pawn.global_position
		for d: Door in closed:
			var reach := d.interact_range_m + d.size.x * 0.5 + 0.5
			var flat := Vector2(d.global_position.x - pos.x, d.global_position.z - pos.z)
			if flat.length_squared() > reach * reach:  # cheap first: most doors are far
				continue
			if absf(d.bottom_y() - pos.y) > d.height_limit_m or d.distance_to(pos) > d.interact_range_m:
				continue
			var door_cfg := WorldProps.door_cfg(props.cfg, d.kind)
			if agent == null or not path_crosses_door(d, pos, agent.get_current_navigation_path(),
					agent.get_current_navigation_path_index(),
					float(door_cfg.get("bot_path_lookahead_m", BOT_DOOR_LOOKAHEAD_M)),
					float(door_cfg.get("bot_path_edge_m", BOT_DOOR_EDGE_M))):
				continue
			var ticks := int(held.get(d.prop_id, 0)) + 1
			if ticks >= _bot_door_delay_ticks(d.kind):
				if props.set_door(d.prop_id, WorldProps.OPEN):
					bot_doors_opened += 1
			else:
				still[d.prop_id] = ticks
		if still.is_empty():
			_bot_door_ticks.erase(id)
		else:
			_bot_door_ticks[id] = still


## True when the way forward from `from` (the bot's feet) along `path` from `index` (the next point) crosses `door`'s
## plane (its local z = 0) inside the opening (|local x| <= half the width + BOT_DOOR_EDGE_M) at its floor (within
## height_limit_m of the threshold). Segments are checked until a point lies BOT_DOOR_LOOKAHEAD_M from `from`.
static func path_crosses_door(door: Door, from: Vector3, path: PackedVector3Array, index: int,
		lookahead_m := BOT_DOOR_LOOKAHEAD_M, edge_m := BOT_DOOR_EDGE_M) -> bool:
	if index < 0 or index >= path.size():
		return false
	var inv := door.global_transform.affine_inverse()
	var half_w := door.size.x * 0.5 + edge_m
	var floor_y := door.size.y * -0.5  # the threshold in the door's frame
	var a := inv * from
	for i in range(index, path.size()):
		var b := inv * path[i]
		if (a.z > 0.0) != (b.z > 0.0) and absf(a.z - b.z) > 0.0001:
			var t := a.z / (a.z - b.z)
			var at := a.lerp(b, t)
			if absf(at.x) <= half_w and absf(at.y - floor_y) <= door.height_limit_m:
				return true
		if Vector2(path[i].x - from.x, path[i].z - from.z).length() > lookahead_m:
			break
		a = b
	return false


## ---- Drop from the sky (br.json "drop", placeholders, OQ-BR-DROP) ----
## The carrier flies a seeded straight line through the zone start center at altitude_m for carrier_s.
## Every pawn rides it (Pawn.board_carrier). Humans drop with Jump; bots drop at a seeded moment inside
## bot_jump_window (squad mates together); anyone still aboard at the end of the path drops then.
var drop_active: bool = false
var carrier_from := Vector3.ZERO
var carrier_to := Vector3.ZERO
var carrier_t: float = 0.0
var _carrier_s: float = 20.0
var _bot_jump_t: Dictionary = {}  # squad id -> path fraction


func _drop_cfg() -> Dictionary:
	return mode_cfg.get("drop", {})


func _begin_drop(seed_value: int, ids: Array) -> void:
	var cfg := _drop_cfg()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 7919  # separate stream from the zone's
	var path := carrier_path(mode_cfg, rng)
	carrier_from = path[0]
	carrier_to = path[1]
	_carrier_s = maxf(float(cfg.get("carrier_s", 20.0)), 0.1)
	carrier_t = 0.0
	var window: Array = cfg.get("bot_jump_window", [0.15, 0.85])
	_bot_jump_t.clear()
	for id in ids:
		var pawn: Pawn = _players[id]
		if not _bot_jump_t.has(pawn.squad_id):
			_bot_jump_t[pawn.squad_id] = rng.randf_range(float(window[0]), float(window[1]))
		pawn.drop_glide_mps = float(cfg.get("glide_speed_mps", 8.0))
		pawn.drop_max_fall_mps = float(cfg.get("max_fall_mps", 15.0))
		pawn.board_carrier()
	drop_active = true
	_place_aboard()


## [from, to] of the carrier line: through the zone start center at drop.altitude_m, seeded direction,
## drop.path_length_m long. One rng draw (the direction).
static func carrier_path(cfg: Dictionary, rng: RandomNumberGenerator) -> Array[Vector3]:
	var drop: Dictionary = cfg.get("drop", {})
	var c: Array = cfg.get("zone", {}).get("start_center", [0, 0])
	var center := Vector3(float(c[0]), float(drop.get("altitude_m", 120.0)), float(c[1]))
	var angle := rng.randf() * TAU
	var half := float(drop.get("path_length_m", 200.0)) * 0.5
	var dir := Vector3(cos(angle), 0.0, sin(angle))
	return [center - dir * half, center + dir * half]


## Keeps x/z inside the playable square (br.json drop.map_half_m, placeholder; the M1 map is 160 m).
func _clamp_to_map(p: Vector3) -> Vector3:
	var half := float(_drop_cfg().get("map_half_m", 78.0))
	return Vector3(clampf(p.x, -half, half), p.y, clampf(p.z, -half, half))


## Safety net: a pawn that ends up below the map (fell past an edge) is put back on the map edge.
func _catch_fallen() -> void:
	for id in _players:
		var pawn: Pawn = _players[id]
		if pawn.life != Pawn.Life.DEAD and pawn.global_position.y < -5.0:
			var p := _clamp_to_map(pawn.global_position)
			pawn.global_position = Vector3(p.x * 0.97, 3.0, p.z * 0.97)
			pawn.velocity = Vector3.ZERO


func carrier_position() -> Vector3:
	return carrier_from.lerp(carrier_to, clampf(carrier_t, 0.0, 1.0))


func _place_aboard() -> void:
	var pos := carrier_position()
	for id in _players:
		var pawn: Pawn = _players[id]
		if pawn.drop_state == Pawn.Drop.ABOARD:
			pawn.global_position = pos


func _tick_drop(delta: float) -> void:
	carrier_t += delta / _carrier_s
	_place_aboard()
	var still_aboard := false
	var ids: Array = _players.keys()
	ids.sort()
	for id in ids:
		var pawn: Pawn = _players[id]
		if pawn.drop_state != Pawn.Drop.ABOARD:
			continue
		var is_bot := pawn.has_node("Brain")
		var go := carrier_t >= 1.0 or pawn.take_drop_request() \
				or (is_bot and carrier_t >= float(_bot_jump_t.get(pawn.squad_id, 0.5)))
		if go:
			# Squad mates and neighbours leave side by side, not inside each other.
			var side := Vector3(-(carrier_to - carrier_from).z, 0.0, (carrier_to - carrier_from).x).normalized()
			pawn.start_fall(_clamp_to_map(carrier_position() + side * float(_slot_in_squad.get(id, 0)) * 2.0))
		else:
			still_aboard = true
	if not still_aboard:
		drop_active = false


func all_players() -> Dictionary:
	return _players


func player(player_id: int) -> Pawn:
	return _players.get(player_id)


func players_alive() -> int:
	var n := 0
	for id in _players:
		if _players[id].life != Pawn.Life.DEAD:
			n += 1
	return n


func squads_alive() -> int:
	var seen: Dictionary = {}
	for id in _players:
		if _players[id].life != Pawn.Life.DEAD:
			seen[_players[id].squad_id] = true
	return seen.size()


## Ground-plane position, the same Vector2(x, z) the rules get in facts["positions"].
static func _flat(p: Pawn) -> Vector2:
	return Vector2(p.global_position.x, p.global_position.z)


func _downed_cfg() -> Dictionary:
	return mode_cfg.get("downed", {})


## The DOWNED squad mate `player_id` could revive now: nearest within br.json downed.revive_range_m while
## `player_id` is ALIVE; -1 if none. The touch HUD shows Interact ("Revive") only when this is >= 0.
func revive_target_for(player_id: int) -> int:
	var me: Pawn = _players.get(player_id)
	if not running or me == null or not me.is_alive() or me.is_dropping():
		return -1
	var range_m := float(_downed_cfg().get("revive_range_m", 0.0))
	var best := -1
	var best_d := INF
	var ids: Array = _players.keys()
	ids.sort()
	for id in ids:
		var other: Pawn = _players[id]
		if id == player_id or not other.is_downed() or other.squad_id != me.squad_id:
			continue
		var d := _flat(me).distance_to(_flat(other))
		if d <= range_m and d < best_d:
			best = id
			best_d = d
	return best


## Interact pressed: starts holding a revive on the current revive target. False if there is none.
func begin_revive(player_id: int) -> bool:
	var target := revive_target_for(player_id)
	if target < 0:
		return false
	_reviving[player_id] = target
	return true


## Interact released (or the HUD hid / the menu opened): the revive pair ends. Safe when none is held.
func end_revive(player_id: int) -> void:
	_reviving.erase(player_id)


func is_reviving(player_id: int) -> bool:
	return _reviving.has(player_id)


## Drops pairs whose reviver is no longer ALIVE, whose target is no longer DOWNED, or that left range.
func _prune_revives() -> void:
	for r in _reviving.keys():
		var me: Pawn = _players.get(r)
		var target: Pawn = _players.get(_reviving[r])
		if me == null or target == null or not me.is_alive() or not target.is_downed() \
				or _flat(me).distance_to(_flat(target)) > float(_downed_cfg().get("revive_range_m", 0.0)):
			_reviving.erase(r)


func _physics_process(delta: float) -> void:
	if not running or not authoritative:
		return
	_prune_revives()
	if drop_active:
		_tick_drop(delta)
	_catch_fallen()
	_bot_pickups()
	_bot_doors()  # M2 L1c: after pickups and chests (loot or not), before the rule tick
	var positions: Dictionary = {}
	for id in _players:
		var pawn: Pawn = _players[id]
		pawn.bridge.spawn_protected = false  # field kept for the network path; no protection in battle royale
		# Pawns still aboard the carrier are left out: BrRules treats them as inside the zone.
		if pawn.life != Pawn.Life.DEAD and pawn.drop_state != Pawn.Drop.ABOARD:
			positions[id] = _flat(pawn)
	tick_count += 1
	var facts := {"positions": positions, "reviving": _reviving.duplicate()}
	for ev in rules.tick(delta, facts):
		_handle_event(ev)
	_prune_revives()  # a revived or dead target ends its pair


func _handle_event(ev: Dictionary) -> void:
	match ev["type"]:
		"zone_phase":
			zone_changed.emit()
		"zone_damage":
			var pawn: Pawn = _players.get(int(ev["player_id"]))
			if pawn != null and pawn.life == Pawn.Life.ALIVE:
				pawn.bridge.take_direct_damage(float(ev["amount"]), bool(ev["skips_shield"]))
				if pawn.bridge.state.is_dead():
					rules.report_zero_health(int(ev["player_id"]), -1, "zone")
		"downed":
			var pawn: Pawn = _players.get(int(ev["player_id"]))
			if pawn != null:
				pawn.life = Pawn.Life.DOWNED
			player_downed.emit(int(ev["player_id"]))
			alive_changed.emit(players_alive(), squads_alive())
		"revived":
			var pawn: Pawn = _players.get(int(ev["player_id"]))
			if pawn != null:
				pawn.life = Pawn.Life.ALIVE
				pawn.bridge.state.health = pawn.bridge.state.max_health * float(ev["health_pct"]) / 100.0
				pawn.bridge.state.shield = 0.0
			player_revived.emit(int(ev["player_id"]))
			alive_changed.emit(players_alive(), squads_alive())
		"dead":
			var pawn: Pawn = _players.get(int(ev["player_id"]))
			if pawn != null:
				pawn.life = Pawn.Life.DEAD
				if loot != null:
					for gun in pawn.surrender_guns():
						loot.drop(gun, pawn.global_position)
				pawn.set_active(false)
			player_eliminated.emit(int(ev["player_id"]), int(ev["killer_id"]), str(ev["cause"]))
			alive_changed.emit(players_alive(), squads_alive())
		"match_over":
			running = false
			match_over.emit(rules.result())


## Client side: the host's result replayed here so the end screen listens to one set of signals.
func apply_remote_match_over(result: Dictionary) -> void:
	running = false
	match_over.emit(result)


func _on_pawn_health_zeroed(attacker_id: int, victim_id: int) -> void:
	if running and authoritative and rules != null:
		rules.report_zero_health(victim_id, attacker_id, "hit")


## Squad k stands at spot k mod spot count; squads sharing a spot are spread on a ring of radius
## match.json spawn_share_offset_m (placeholder, OQ-BR-DROP) until S3 adds the drop.
func _place(player_id: int, squad_ids: Array, spots: Array) -> void:
	var pawn: Pawn = _players[player_id]
	var k := squad_ids.find(pawn.squad_id)
	var spot_i := k % spots.size()
	var xform: Transform3D = _spawn_xforms[spots[spot_i]]
	var sharers := 0
	var rank := 0
	for j in squad_ids.size():
		if j % spots.size() == spot_i:
			if j < k:
				rank += 1
			sharers += 1
	if sharers > 1:
		var ang := TAU * float(rank) / float(sharers)
		xform.origin += Vector3(cos(ang), 0.0, sin(ang)) * float(match_cfg.get("spawn_share_offset_m", 4.0))
	# Squad mates stand side by side (match.json squad_spacing_m, placeholder).
	var spacing := float(match_cfg.get("squad_spacing_m", 1.5))
	xform.origin += xform.basis.x * spacing * float(_slot_in_squad.get(player_id, 0))
	pawn.respawn_at(xform)


## M2B1, read only: a copy of the map's landmark list the loot field was set up with ([{id, at [x, z],
## radius_m, ...}], data/maps/<map>_landmarks.json); [] when there is no loot field. The bot brain picks its
## gear-up landmark from it. No state changes.
func loot_landmarks() -> Array:
	return loot._landmarks.duplicate(true) if loot != null else []
