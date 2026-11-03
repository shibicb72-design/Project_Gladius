class_name InputProvider
extends RefCounted
## Base class for swappable input sources. The router sums move/look and ORs buttons.

## A one-shot action press (D1: cover Crouch). The router re-emits it at once and latches the edge into its
## next frame, so a tap that starts and ends between two ticks is still seen exactly once.
signal action_triggered(action: String)
## The end of a held press-time action (D2: cover FIRE). cancel is true when the hold was interrupted (hide,
## menu, suspend, death, exit) rather than let go; the action's owner decides what that drops.
signal action_released(action: String, cancel: bool)
## Per-refresh look state of a press-time action (D2: cover FIRE leans out while the HUD look drag is active).
signal action_look_changed(action: String, active: bool)


## Press entry point for controls that act at press time. The default does nothing; TouchProvider emits.
func trigger_action(_action: String) -> void:
	pass


## Release entry point for held press-time controls. The default does nothing; TouchProvider emits.
func release_action(_action: String, _cancel: bool = false) -> void:
	pass


## Look-state entry point for press-time controls. The default does nothing; TouchProvider emits.
func set_action_look(_action: String, _active: bool) -> void:
	pass


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


## Called by the router once per physics tick before it reads the provider (sprint threshold and lock state).
func tick(_delta: float) -> void:
	pass


## Sprint requested by this provider (only the touch move stick has the sprint gesture today).
func is_sprinting() -> bool:
	return false


## Router forwards unhandled events here (e.g. mouse motion). Called from the router only.
func handle_event(_event: InputEvent) -> void:
	pass
