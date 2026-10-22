class_name GamepadProvider
extends InputProvider
## Right-stick look from the look_* actions with a data-driven dead zone.
## Left stick and buttons arrive through KeyboardMouseProvider (shared InputMap actions).
## Look is a rate source: radians per physics tick, capped by look.max_turn_rate_deg_s.

const _LookMath := preload("res://scripts/input/look_math.gd")

var dead_zone: float = 0.15
var sensitivity: float = 1.0
var invert_y: bool = false
var _cfg: Dictionary = {}


func configure(cfg: Dictionary) -> void:
	_cfg = cfg
	dead_zone = float(cfg.get("dead_zones", {}).get("gamepad_look", dead_zone))
	sensitivity = float(cfg.get("sensitivity", {}).get("stick_look", sensitivity))
	invert_y = bool(cfg.get("invert_y", false))


func get_look() -> Vector2:
	var v := Input.get_vector("look_left", "look_right", "look_up", "look_down")
	if v.length() < dead_zone:
		return Vector2.ZERO
	if invert_y:
		v.y = -v.y
	return _LookMath.look_from_stick(v * sensitivity, _cfg, _LookMath.tick_hz())
