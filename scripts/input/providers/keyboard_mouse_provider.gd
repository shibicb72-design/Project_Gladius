class_name KeyboardMouseProvider
extends InputProvider
## Reads InputMap actions (keyboard, mouse buttons, and the gamepad bindings that share them)
## for move and buttons, plus accumulated mouse motion for look.

const INPUT_PATH := "res://data/input.json"

## Look radians per pixel of mouse motion, before the Camera / ADS percent tables (InputRouter.look_percent).
## W0 (binding fix 14): data/input.json sensitivity.mouse_look (placeholder, OQ-36); was a hard-coded 0.002.
var mouse_sensitivity: float = 0.0
var _mouse_accum: Vector2 = Vector2.ZERO
## W0 mouse mode seam (binding fix 13): () -> int, an Input.MouseMode. MatchRoot points it at the PauseMenu's
## MouseCapture, so tests fake one mode for the capture state machine and this provider.
var get_mouse_mode: Callable = func() -> int: return Input.mouse_mode


func _init() -> void:
	configure(DataRegistry.new().load_file(INPUT_PATH))


## Reads sensitivity.mouse_look from an input.json dictionary (missing key: look stays as it is).
func configure(cfg: Dictionary) -> void:
	var sens: Variant = cfg.get("sensitivity", {})
	if sens is Dictionary and (sens as Dictionary).has("mouse_look"):
		mouse_sensitivity = float(sens["mouse_look"])


func get_move() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")


func get_look() -> Vector2:
	var l := _mouse_accum * mouse_sensitivity
	_mouse_accum = Vector2.ZERO
	return l


func is_pressed(action: String) -> bool:
	return Input.is_action_pressed(action)


## W0 (binding fix 6): sprint is the held "sprint" action (Left Shift). The pawn exits cover on its rising edge, as
## it does for the touch Sprint lock (pawn.gd sprint_pressed -> cover.request_exit).
func is_sprinting() -> bool:
	return InputMap.has_action("sprint") and Input.is_action_pressed("sprint")


## M2 H1c item 4 (OQ-CROUCH): InputMap actions that act at press time, like the touch buttons that call
## TouchProvider.trigger_action. A keyboard key or gamepad button bound to one is re-emitted once per press (no echo),
## so the router reaches Pawn.handle_action_press the same way the touch Crouch button does. Only this provider emits
## (the gamepad provider reads look only), so one press is one toggle.
## W0 (binding fix 5): interact (E) and cover (F) too; they act only through action_triggered (InputRouter
## NON_FRAME_ACTIONS), as the touch Interact and Cover buttons do.
const PRESS_ACTIONS: Array[String] = ["crouch", "interact", "cover"]
## W0: held press-time actions whose release is re-emitted (interact: the revive hold ends on the E release).
const RELEASE_ACTIONS: Array[String] = ["interact"]
## W0: actions whose MOUSE bindings (the wheel) are latched through action_triggered: a wheel notch is a press and
## release in one go with no held state, so the router's is_pressed polling would miss it. Keys stay polled.
const MOUSE_LATCH_ACTIONS: Array[String] = ["swap_weapon"]


func handle_event(event: InputEvent) -> void:
	if event is InputEventMouseMotion and int(get_mouse_mode.call()) == Input.MOUSE_MODE_CAPTURED:
		_mouse_accum += event.relative
	for action in PRESS_ACTIONS:
		if InputMap.has_action(action) and event.is_action_pressed(action, false):
			action_triggered.emit(action)
	for action in RELEASE_ACTIONS:
		if InputMap.has_action(action) and event.is_action_released(action):
			action_released.emit(action, false)
	if event is InputEventMouseButton:
		for action in MOUSE_LATCH_ACTIONS:
			if InputMap.has_action(action) and event.is_action_pressed(action, false):
				action_triggered.emit(action)
