class_name InteractButton
extends Control
## S1b: the contextual Interact touch button. Labelled "Revive" and visible only while the local pawn is ALIVE
## and a DOWNED squad mate is within revive range (S4 reuses it for pickups). A held press goes through the
## input layer like the D2 cover FIRE control: TouchProvider trigger_action / release_action "interact" ->
## InputRouter -> MatchRoot -> MatchDirector, which owns the revive pairs. This script never mutates pawn,
## cover or director state; it only reads them to decide visibility.
## Placement (data/ui.json interact_button, placeholder OQ-BR-DOWNED): centre at the touch HUD's data look-stick
## rest plus offset_buttons default button sides, side = size_buttons default button sides (the same units
## as the touch_layout buttons), lower right, clear of the other buttons.

const ACTION := "interact"

var pawn: Pawn
var director: MatchDirector
var touch_hud: Control
var pause_menu: PauseMenu
var label: Label
var cfg: Dictionary = {}
var _press_index := -1
var _mouse_held := false


func _ready() -> void:
	name = "InteractButton"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = preload("res://scenes/ui/theme.tres")
	cfg = DataRegistry.new().load_file("res://data/ui.json")["interact_button"]
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = str(cfg["label"])  # placeholder text, S6 does the look
	add_child(label)
	refresh()


func bind(local_pawn: Pawn, match_director: MatchDirector, touch: Control, menu: PauseMenu) -> void:
	pawn = local_pawn
	director = match_director
	touch_hud = touch
	pause_menu = menu
	if is_node_ready():
		refresh()


## Screen rect of the button (viewport space). Without a TouchHud there is no route, so no rect.
func get_touch_rect() -> Rect2:
	if not is_instance_valid(touch_hud):
		return Rect2()
	var side: float = touch_hud._button_size()
	var off: Array = cfg["offset_buttons"]
	var center: Vector2 = touch_hud._rest_center(str(cfg["anchor"])) + Vector2(float(off[0]), float(off[1])) * side
	var s := side * float(cfg["size_buttons"])
	return Rect2(touch_hud.global_position + center - Vector2.ONE * s * 0.5, Vector2.ONE * s)


func _available() -> bool:
	if not is_instance_valid(pawn) or not is_instance_valid(director) or not is_instance_valid(touch_hud):
		return false
	if is_instance_valid(pause_menu) and pause_menu.is_open:
		return false
	if touch_hud.suspended or not touch_hud.is_visible_in_tree():
		return false
	if not director.authoritative:
		return false
	return director.revive_target_for(pawn.player_id) >= 0 or director.pickup_target_for(pawn.player_id) >= 0


## "Revive" (cfg label) when a DOWNED squad mate is in range, else "Pick up <item>". Placeholder text (S6).
func _label_text() -> String:
	if not is_instance_valid(director) or not is_instance_valid(pawn):
		return str(cfg["label"])
	if director.revive_target_for(pawn.player_id) >= 0:
		return str(cfg["label"])
	var item := director.pickup_target_for(pawn.player_id)
	if item >= 0 and director.loot != null:
		return "Pick up\n%s" % director.loot.display_name(item)
	return str(cfg["label"])


func _input_provider() -> InputProvider:
	if is_instance_valid(touch_hud) and touch_hud.provider != null:
		return touch_hud.provider
	return null


func refresh() -> void:
	var was_visible := visible
	visible = _available()
	if visible and label != null:
		label.text = _label_text()
	if not visible and (was_visible or _is_pressed()):
		_release(true)
	_place()


func _place() -> void:
	if label == null:
		return
	var rect := get_touch_rect()
	global_position = rect.position
	size = rect.size
	label.position = Vector2.ZERO
	label.size = rect.size
	label.add_theme_font_size_override("font_size", int(float(cfg["font_dp"]) * PlatformServices.new().get_dp_scale()))
	queue_redraw()


func _is_pressed() -> bool:
	return _press_index != -1 or _mouse_held


func _draw() -> void:
	if cfg.is_empty() or size.x <= 0.0:
		return
	var alpha := float(cfg["pressed_fill_alpha"] if _is_pressed() else cfg["fill_alpha"])
	draw_circle(size * 0.5, size.x * 0.5, Color(1, 1, 1, alpha))
	draw_arc(size * 0.5, size.x * 0.5 - 1.0, 0.0, TAU, 48, Color(1, 1, 1, 0.6), 2.0, true)


func _process(_delta: float) -> void:
	refresh()


func _physics_process(_delta: float) -> void:
	refresh()


func _press() -> void:
	var input := _input_provider()
	if input != null:
		input.trigger_action(ACTION)


## Always sends the release, held or not (ungated in MatchRoot), so a hide or an open menu ends the revive.
func _release(cancel: bool = false) -> void:
	var input := _input_provider()
	if input != null:
		input.release_action(ACTION, cancel)
	_press_index = -1
	_mouse_held = false
	queue_redraw()


func _exit_tree() -> void:
	if _is_pressed():
		_release(true)


func _accept_point(point: Vector2) -> bool:
	var rect := get_touch_rect()
	return is_visible_in_tree() and _available() and point.distance_squared_to(rect.get_center()) <= pow(rect.size.x * 0.5, 2)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenDrag and event.index == _press_index:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if not event.pressed and event.index == _press_index:
			_release()
			get_viewport().set_input_as_handled()
		elif event.pressed and not _is_pressed() and _accept_point(event.position):
			_press_index = event.index
			_press()
			queue_redraw()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION:
		if not event.pressed and _mouse_held:
			_release()
			get_viewport().set_input_as_handled()
		elif event.pressed and not _is_pressed() and _accept_point(event.position):
			_mouse_held = true
			_press()
			queue_redraw()
			get_viewport().set_input_as_handled()
