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
var rules: BrRules
var running: bool = false
## False on a network client: no rules ticking or match_over of its own. The result arrives from the host
## through apply_remote_match_over. TODO(M3): zone and downed state are not replicated yet.
var authoritative: bool = true
## Rule ticks run so far (tests use it to see whether the simulation advances, e.g. under a pause menu).
var tick_count: int = 0

var _players: Dictionary = {}  # player id -> Pawn
var _spawn_xforms: Dictionary = {}  # spot id -> Transform3D
var _slot_in_squad: Dictionary = {}  # player id -> index within its squad
var _reviving: Dictionary = {}  # reviver player id -> target player id (revive input)


func load_config() -> void:
	var reg := DataRegistry.new()
	mode_cfg = ModeRegistry.merged_config(MODE_ID, reg.load_file("res://data/modes.json"))
	match_cfg = reg.load_file("res://data/match.json").duplicate(true)


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
	var downed_pct := float(_downed_cfg().get("downed_move_speed_pct", 100.0))
	var ids: Array = _players.keys()
	ids.sort()
	for id in ids:
		var pawn: Pawn = _players[id]
		if not rules.register_player(id, pawn.squad_id):
			return false
		pawn.set_squad(rules.squad_of(id))  # solo: every player is its own squad (friendly fire, bot targets)
		pawn.downed_move_speed_pct = downed_pct
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


## data/bots.json brain.ammo_low_magazines (placeholder, OQ-31): bots take ammo below this many magazines.
func bot_ammo_low_magazines() -> float:
	if _bot_ammo_low < 0.0:
		_bot_ammo_low = float(DataRegistry.new().load_file("res://data/bots.json").get("brain", {}).get("ammo_low_magazines", 2.0))
	return _bot_ammo_low


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


func _bot_pickups() -> void:
	if loot == null:
		return
	for id in _players:
		var pawn: Pawn = _players[id]
		if pawn.has_node("Brain") and pawn.is_alive() and not pawn.is_dropping():
			try_pickup(id, true)


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
