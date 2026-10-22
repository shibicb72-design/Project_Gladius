class_name SpawnRules
extends RefCounted
## Squad spots, respawn timers and spawn protection. Pure, seeded.
## Protection ends on firing or after spawn_protection_s, never on pickup.
## What protection blocks is a placeholder (OQ-15).

var respawn_s: float = 5.0
var protection_s: float = 5.0
var _spots: Dictionary = {}
var _respawn_left: Dictionary = {}
var _protection_left: Dictionary = {}


func setup(match_cfg: Dictionary) -> void:
	respawn_s = float(match_cfg.get("respawn_s", 5))
	protection_s = float(match_cfg.get("spawn_protection_s", 5))
	_spots = {}
	_respawn_left = {}
	_protection_left = {}


## Gives each squad a distinct random spot from spot_ids for the whole match.
func assign_squad_spots(squad_ids: Array, spot_ids: Array, seed_value: int) -> bool:
	if spot_ids.size() < squad_ids.size():
		return false
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var pool: Array = spot_ids.duplicate()
	for i in range(pool.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	_spots = {}
	for i in squad_ids.size():
		_spots[squad_ids[i]] = pool[i]
	return true


func squad_spot(squad_id: Variant) -> Variant:
	return _spots.get(squad_id)


func start_respawn(player_id: Variant) -> void:
	_respawn_left[player_id] = respawn_s
	_protection_left.erase(player_id)


func is_waiting_respawn(player_id: Variant) -> bool:
	return _respawn_left.has(player_id)


## Immediate (re)spawn, e.g. at match start or killcam timeout; grants protection.
func spawn_now(player_id: Variant) -> void:
	_respawn_left.erase(player_id)
	_protection_left[player_id] = protection_s


## Advances timers; returns ids of players whose respawn timer finished.
func tick(delta: float) -> Array:
	var respawned: Array = []
	for id in _respawn_left.keys():
		_respawn_left[id] -= delta
		if _respawn_left[id] <= 0.0:
			respawned.append(id)
	for id in respawned:
		spawn_now(id)
	for id in _protection_left.keys():
		if id in respawned:
			continue
		_protection_left[id] -= delta
		if _protection_left[id] <= 0.0:
			_protection_left.erase(id)
	return respawned


func is_protected(player_id: Variant) -> bool:
	return _protection_left.has(player_id)


## Game events other than firing (pickups etc.) never end protection.
func notify_event(player_id: Variant, event_type: String) -> void:
	if event_type == "fire":
		_protection_left.erase(player_id)
