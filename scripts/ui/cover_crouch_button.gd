class_name CoverCrouchButton
extends Control
## Contextual controls share the fire-mode button's sibling input routing and dp/theme rules.
var pawn: Pawn
var touch_hud: Control
var pause_menu: PauseMenu
var label: Label
var cfg: Dictionary = {}
var config_key := "cover_crouch"

func _ready() -> void:
	name = "CoverCrouchButton" if config_key == "cover_crouch" else "CoverFireButton"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = preload("res://scenes/ui/theme.tres")
	cfg = DataRegistry.new().load_file("res://data/ui.json")[config_key]
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = cfg["label"]
	add_child(label)
	resized.connect(_place)
	_place()
	refresh()

func bind(local_pawn: Pawn, touch: Control, menu: PauseMenu) -> void:
	pawn = local_pawn
	touch_hud = touch
	pause_menu = menu
	process_physics_priority = pawn.process_physics_priority - 1
	if is_node_ready():
		refresh()

func get_touch_rect() -> Rect2:
	var rect := FireModeButton.touch_rect(cfg, size)
	rect.position += global_position
	return rect

func _place() -> void:
	if label == null:
		return
	var rect := FireModeButton.touch_rect(cfg, size)
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_size_override("font_size", int(float(cfg["font_dp"]) * PlatformServices.new().get_dp_scale()))

func _available() -> bool:
	if not is_instance_valid(pawn) or not pawn.is_alive() or pawn.cover == null:
		return false
	if is_instance_valid(pause_menu) and pause_menu.is_open:
		return false
	if is_instance_valid(touch_hud) and touch_hud.suspended:
		return false
	return pawn.cover.state == CoverController.State.IN_COVER or pawn.cover.state == CoverController.State.PEEK_LEFT or pawn.cover.state == CoverController.State.PEEK_RIGHT

func refresh() -> void:
	visible = _available()

func _process(_delta: float) -> void:
	refresh()

func _physics_process(_delta: float) -> void:
	refresh()

func _accept_point(point: Vector2) -> bool:
	if not is_visible_in_tree() or not _available() or not get_touch_rect().has_point(point):
		return false
	if is_instance_valid(touch_hud):
		for key in touch_hud.get_button_actions():
			if touch_hud.get_element_rect(key).has_point(point):
				return false
		if touch_hud.get_lock_button_rect().has_point(point):
			return false
	return true

func _input(event: InputEvent) -> void:
	var point: Vector2
	if event is InputEventScreenTouch and event.pressed:
		point = event.position
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION:
		point = event.position
	else:
		return
	if _accept_point(point):
		pawn.cover.toggle_crouch()
		get_viewport().set_input_as_handled()
