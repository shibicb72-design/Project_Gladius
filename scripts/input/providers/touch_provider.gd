class_name TouchProvider
extends InputProvider
## Values are pushed in by the touch HUD. Buttons reach the game via Input.action_press
## (picked up by KeyboardMouseProvider), so only the sticks live here.
## Look is radians per physics tick (see look_math.gd), in "stick" or "drag" mode.

const _LookMath := preload("res://scripts/input/look_math.gd")

var move_value: Vector2 = Vector2.ZERO
var look_value: Vector2 = Vector2.ZERO  # stick mode: deflection in [-1, 1]
var sensitivity: float = 1.0
var invert_y: bool = false
var look_mode: String = "stick"
var _cfg: Dictionary = {}
var _drag_accum: Vector2 = Vector2.ZERO  # pixels since the last tick (drag mode)
var _viewport_h: float = 1.0


func configure(cfg: Dictionary) -> void:
	_cfg = cfg
	sensitivity = float(cfg.get("sensitivity", {}).get("touch_look", sensitivity))
	invert_y = bool(cfg.get("invert_y", false))
	look_mode = String(cfg.get("look", {}).get("mode", "stick"))


## Drag mode: accumulate every drag event; consumed by the next get_look().
func add_drag(relative: Vector2, viewport_h: float) -> void:
	_drag_accum += relative
	_viewport_h = viewport_h


func clear_look() -> void:
	look_value = Vector2.ZERO
	_drag_accum = Vector2.ZERO


func get_move() -> Vector2:
	return move_value


func get_look() -> Vector2:
	var v := Vector2.ZERO
	if look_mode == "drag":
		v = _LookMath.look_from_drag(_drag_accum, _viewport_h, _cfg)
		_drag_accum = Vector2.ZERO
	else:
		v = _LookMath.look_from_stick(look_value, _cfg, _LookMath.tick_hz())
	v *= sensitivity
	if invert_y:
		v.y = -v.y
	return _LookMath.clamp_turn(v, _cfg, _LookMath.tick_hz())
