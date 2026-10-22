class_name InputProvider
extends RefCounted
## Base class for swappable input sources. The router sums move/look and ORs buttons.


## Movement contribution, each axis in -1..1.
func get_move() -> Vector2:
	return Vector2.ZERO


## Look contribution in radians-per-tick-ish units, already scaled by sensitivity.
func get_look() -> Vector2:
	return Vector2.ZERO


func is_pressed(_action: String) -> bool:
	return false


## Router forwards unhandled events here (e.g. mouse motion). Called from the router only.
func handle_event(_event: InputEvent) -> void:
	pass
