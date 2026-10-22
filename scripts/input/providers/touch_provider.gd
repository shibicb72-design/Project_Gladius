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
var shape_move: bool = true  # off for the custom stick, which has its own dead zone
var move_feel_errors: int = 0  # times the missing-move_feel error was reported (0 or 1)
var error_sink: Callable = Callable()  # tests capture the error here instead of push_error
var _feel: Dictionary = {}
var _cfg: Dictionary = {}
var _drag_accum: Vector2 = Vector2.ZERO  # pixels since the last tick (drag mode)
var _viewport_h: float = 1.0


func configure(cfg: Dictionary) -> void:
	_cfg = cfg
	_feel = cfg["move_feel"] if cfg.has("move_feel") else {}
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


## Radial dead zone on the vector's length (no diagonal snapping), then the response curve:
## out = dir * pow(remapped_len, exponent). An unconfigured provider passes the raw value through.
func get_move() -> Vector2:
	if not shape_move:
		return move_value
	if _feel.is_empty():
		# A provider that was never configured has nothing to shape with; a configured one is missing data.
		if not _cfg.is_empty():
			_report_missing_feel()
		return move_value
	var length := move_value.length()
	var dead: float = _feel["radial_deadzone"]["value"]
	if length <= dead or length <= 0.0:
		return Vector2.ZERO
	var remapped := minf(1.0, (length - dead) / (1.0 - dead))
	return move_value / length * pow(remapped, float(_feel["response_exponent"]["value"]))


## Fail loudly, once per provider: shaping is on but data/input.json has no touch_layout.move_feel.
func _report_missing_feel() -> void:
	if move_feel_errors > 0:
		return
	move_feel_errors += 1
	var msg := "TouchProvider: shape_move is true but data/input.json move_feel (the touch move-feel block, next to touch_layout) is missing; move stick shaping is off"
	if error_sink.is_valid():
		error_sink.call(msg)
	else:
		push_error(msg)


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
