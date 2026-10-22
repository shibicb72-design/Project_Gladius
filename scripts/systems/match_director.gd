class_name MatchDirector
extends Node
## Owns KothRules + SpawnRules for one offline match. Feeds them occupancy and time,
## spawns/respawns pawns, applies spawn protection and emits signals for the HUD.

signal score_changed(scores: Dictionary)
signal time_changed(remaining_s: float)
signal match_over(result: Dictionary)

const MODE_ID := "koth"

## Loaded from data/*.json in load_config(); tests may override before start().
var mode_cfg: Dictionary = {}
var match_cfg: Dictionary = {}
var rules: KothRules
var spawn_rules: SpawnRules = SpawnRules.new()
var hill_zone: HillZone
var running: bool = false

var _players: Dictionary = {}  # player id -> Pawn
var _spawn_xforms: Dictionary = {}  # spot id -> Transform3D
var _slot_in_squad: Dictionary = {}  # player id -> index within its squad


func load_config() -> void:
	var reg := DataRegistry.new()
	mode_cfg = reg.load_file("res://data/modes.json").get(MODE_ID, {}).duplicate(true)
	match_cfg = reg.load_file("res://data/match.json").duplicate(true)


func add_player(player_id: int, pawn: Pawn) -> void:
	_players[player_id] = pawn
	var slot := 0
	for other in _players:
		if other != player_id and _players[other].squad_id == pawn.squad_id:
			slot += 1
	_slot_in_squad[player_id] = slot
	pawn.fired.connect(_on_pawn_fired.bind(player_id))


## Returns false if the map has fewer spots than squads.
func start(squad_ids: Array, spawn_xforms: Dictionary, zone: HillZone, seed_value: int = 1) -> bool:
	hill_zone = zone
	_spawn_xforms = spawn_xforms
	rules = ModeRegistry.create(MODE_ID, {MODE_ID: mode_cfg}) as KothRules
	if rules == null:
		return false
	rules.register_squads(squad_ids)
	spawn_rules.setup(match_cfg)
	if not spawn_rules.assign_squad_spots(squad_ids, spawn_xforms.keys(), seed_value):
		return false
	for id in _players:
		_place(id)
	running = true
	score_changed.emit(rules.scores)
	time_changed.emit(float(mode_cfg.get("time_limit_s", 600)))
	return true


func player(player_id: int) -> Pawn:
	return _players.get(player_id)


func _physics_process(delta: float) -> void:
	if not running:
		return
	for id in spawn_rules.tick(delta):
		_place(id)
	for id in _players:
		var pawn: Pawn = _players[id]
		if not pawn.is_alive() and not spawn_rules.is_waiting_respawn(id):
			pawn.set_active(false)
			spawn_rules.start_respawn(id)
		pawn.bridge.spawn_protected = spawn_rules.is_protected(id)
	var occupancy: Dictionary = hill_zone.occupancy() if hill_zone != null else {}
	for ev in rules.tick(delta, occupancy):
		match ev["type"]:
			"score":
				score_changed.emit(rules.scores)
			"match_over":
				running = false
				match_over.emit(rules.result())
	var remaining := maxf(float(mode_cfg.get("time_limit_s", 600)) - rules.elapsed_s, 0.0)
	time_changed.emit(remaining)


func _place(player_id: int) -> void:
	var pawn: Pawn = _players[player_id]
	var spot: Variant = spawn_rules.squad_spot(pawn.squad_id)
	var xform: Transform3D = _spawn_xforms[spot]
	# Squad mates stand side by side, 1.5 m apart.
	xform.origin += xform.basis.x * 1.5 * float(_slot_in_squad.get(player_id, 0))
	pawn.respawn_at(xform)
	spawn_rules.spawn_now(player_id)
	pawn.bridge.spawn_protected = true


func _on_pawn_fired(player_id: int) -> void:
	spawn_rules.notify_event(player_id, "fire")
