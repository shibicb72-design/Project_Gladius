class_name KeyboardMouseProvider
extends InputProvider
## Reads InputMap actions (keyboard, mouse buttons, and the gamepad bindings that share them)
## for move and buttons, plus accumulated mouse motion for look.

var mouse_sensitivity: float = 0.002
var _mouse_accum: Vector2 = Vector2.ZERO


func get_move() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")


func get_look() -> Vector2:
	var l := _mouse_accum * mouse_sensitivity
	_mouse_accum = Vector2.ZERO
	return l


func is_pressed(action: String) -> bool:
	return Input.is_action_pressed(action)


func handle_event(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_accum += event.relative
