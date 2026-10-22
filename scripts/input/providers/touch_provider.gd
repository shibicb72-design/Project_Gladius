class_name TouchProvider
extends InputProvider
## Values are pushed in by the touch HUD. Buttons reach the game via Input.action_press
## (picked up by KeyboardMouseProvider), so only the sticks live here.

var move_value: Vector2 = Vector2.ZERO
var look_value: Vector2 = Vector2.ZERO
var sensitivity: float = 1.0
var invert_y: bool = false


func configure(cfg: Dictionary) -> void:
	sensitivity = float(cfg.get("sensitivity", {}).get("touch_look", sensitivity))
	invert_y = bool(cfg.get("invert_y", false))


func get_move() -> Vector2:
	return move_value


func get_look() -> Vector2:
	var v := look_value * sensitivity
	if invert_y:
		v.y = -v.y
	return v
