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
func start(spawn_xforms: Dictionary, seed_value: int = 1) -> bool:
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
	running = true
	zone_changed.emit()
	alive_changed.emit(players_alive(), squads_alive())
	return true


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
	if not running or me == null or not me.is_alive():
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
	var positions: Dictionary = {}
	for id in _players:
		var pawn: Pawn = _players[id]
		pawn.bridge.spawn_protected = false  # field kept for the network path; no protection in battle royale
		if pawn.life != Pawn.Life.DEAD:
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
