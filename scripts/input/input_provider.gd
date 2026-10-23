class_name InputProvider
extends RefCounted
## Base class for swappable input sources. The router sums move/look and ORs buttons.


## Movement contribution, each axis in -1..1.
func get_move() -> Vector2:
	return Vector2.ZERO


## Look contribution in radians-per-tick-ish units, already scaled by sensitivity.
## "camera" providers are scaled by the Camera / ADS / Free Look tables, "gyro" by the Gyro tables (G2d).
var look_source: String = "camera"


## Called by InputRouter every tick before get_look(): whether the player is aiming (aim_blend > 0) and the row.
func set_look_context(_ads: bool, _row: String) -> void:
	pass


func get_look() -> Vector2:
	return Vector2.ZERO


func is_pressed(_action: String) -> bool:
	return false


## Called by the router once per physics tick before it reads the provider (sprint hold timers).
func tick(_delta: float) -> void:
	pass


## Sprint requested by this provider (only the touch move stick has the sprint gesture today).
func is_sprinting() -> bool:
	return false


## Router forwards unhandled events here (e.g. mouse motion). Called from the router only.
func handle_event(_event: InputEvent) -> void:
	pass
