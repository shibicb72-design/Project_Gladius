class_name GameModeRules
extends RefCounted
## Base class for pure match-mode rules. No scene access; runs headless.

var cfg: Dictionary = {}


func setup(p_cfg: Dictionary) -> void:
	cfg = p_cfg


## occupancy: {squad_id: players_on_hill}. Returns a list of event dictionaries.
func tick(_delta: float, _occupancy: Dictionary) -> Array[Dictionary]:
	return []


func is_over() -> bool:
	return false


## {"winner": squad_id or -1, "draw": bool, "scores": {squad_id: score}}
func result() -> Dictionary:
	return {"winner": -1, "draw": false, "scores": {}}
