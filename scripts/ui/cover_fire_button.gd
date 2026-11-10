class_name CoverFireButton
extends CoverCrouchButton
## One captured touch (or real left mouse). Red presses are consumed and never promoted.
var _press_index := -1
var _mouse_held := false
var enabled := false

func enabled_for_drawing() -> bool:
	return enabled

func _is_pressed() -> bool:
	return _press_index != -1 or _mouse_held

func _init() -> void:
	config_key = "cover_fire"

func refresh() -> void:
	super.refresh()
	if not visible:
		_release(true)
	# Sent every refresh, changed or not (the cover's look-hold follows the HUD look drag while available).
	var input := _input_provider()
	if input != null:
		input.set_action_look("cover_fire", _available() and touch_hud.is_look_active())
	enabled = visible and pawn.cover.can_quick_draw()
	if label != null:
		var color: Array = cfg["enabled_color" if enabled else "disabled_color"]
		label.self_modulate = Color(color[0], color[1], color[2], color[3])
	queue_redraw()

## D2: cover FIRE goes through the input layer (provider -> router -> MatchRoot -> pawn -> cover).
## No TouchHud means no route (the UI never drives the CoverController itself).
func _input_provider() -> InputProvider:
	if is_instance_valid(touch_hud) and touch_hud.provider != null:
		return touch_hud.provider
	return null

func _press() -> void:
	var input := _input_provider()
	if input != null:
		input.trigger_action("cover_fire")

## Always sends the release (with cancel_buffer), held or not: a press made elsewhere is cleared too.
func _release(cancel_buffer: bool = false) -> void:
	var input := _input_provider()
	if input != null:
		input.release_action("cover_fire", cancel_buffer)
	_press_index = -1
	_mouse_held = false

func _exit_tree() -> void:
	_release(true)
	var input := _input_provider()
	if input != null:
		input.set_action_look("cover_fire", false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_release(true)

func _input(event: InputEvent) -> void:
	if not _available():
		_release(true)
		return
	if event is InputEventScreenDrag and event.index == _press_index:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if not event.pressed and event.index == _press_index:
			_release()
			get_viewport().set_input_as_handled()
		elif event.pressed and _press_index == -1 and not _mouse_held and _accept_point(event.position):
			_press_index = event.index
			_press()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION:
		if not event.pressed and _mouse_held:
			_release()
			get_viewport().set_input_as_handled()
		elif event.pressed and not _mouse_held and _press_index == -1 and _accept_point(event.position):
			_mouse_held = true
			_press()
			get_viewport().set_input_as_handled()
