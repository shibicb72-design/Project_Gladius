class_name FireModeButton
extends Control
## Match-local mode choice. Handles input before TouchHud, like PauseMenu's gear.

var pawn: Pawn
var touch_hud: Control
var pause_menu: PauseMenu
var label: Label
var cfg: Dictionary = {}
var choices: Dictionary = {}
var _weapons: Dictionary = {}
var _loadout: Loadout
var _slot: int = -1


func _ready() -> void:
	name = "FireModeButton"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = preload("res://scenes/ui/theme.tres")
	cfg = DataRegistry.new().load_file("res://data/ui.json")["fire_mode_button"]
	_weapons = DataRegistry.new().load_file("res://data/fire_modes.json")["weapons"]
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
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


static func touch_rect(settings: Dictionary, view_size: Vector2) -> Rect2:
	var scale_dp := PlatformServices.new().get_dp_scale()
	var side := float(settings["touch_dp"]) * scale_dp
	var corner := Vector2(float(settings["anchor"][0]) * view_size.x, float(settings["anchor"][1]) * view_size.y)
	var margin := Vector2(float(settings["margin_dp"][0]), float(settings["margin_dp"][1])) * scale_dp
	return Rect2(Vector2(corner.x - margin.x - side, corner.y + margin.y), Vector2.ONE * side)


func get_touch_rect() -> Rect2:
	var rect := touch_rect(cfg, size)
	rect.position += global_position
	return rect


func _place() -> void:
	if label == null:
		return
	var rect := touch_rect(cfg, size)
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_size_override("font_size", int(float(cfg["font_dp"]) * PlatformServices.new().get_dp_scale()))


func _physics_process(_delta: float) -> void:
	refresh()


func _active_weapon() -> Weapon:
	if not is_instance_valid(pawn) or pawn.loadout == null:
		return null
	return pawn.loadout.get_active()


func refresh() -> void:
	var weapon := _active_weapon()
	if is_instance_valid(pawn) and pawn.loadout != null and (pawn.loadout != _loadout or pawn.loadout.active != _slot):
		_loadout = pawn.loadout
		_slot = _loadout.active
		# Apply on loadout replacement and slot changes, before the pawn's weapon tick.
		for candidate in _loadout.slots:
			if candidate != null and _weapons.has(candidate.def.id):
				var id := candidate.def.id
				if not choices.has(id):
					choices[id] = _weapons[id]["default"]
				candidate.fire_mode = choices[id]
	visible = weapon != null and _weapons.has(weapon.def.id) and pawn.is_alive()
	if visible and label != null:
		label.text = weapon.fire_mode.to_upper()


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not is_instance_valid(pawn) or not pawn.is_alive():
		return
	if is_instance_valid(pause_menu) and pause_menu.is_open:
		return
	if is_instance_valid(touch_hud) and touch_hud.suspended:
		return
	var weapon := _active_weapon()
	if weapon == null or not _weapons.has(weapon.def.id):
		return
	var point: Vector2
	if event is InputEventScreenTouch and event.pressed:
		point = event.position
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		point = event.position
	else:
		return
	if not get_touch_rect().has_point(point):
		return
	if is_instance_valid(touch_hud):
		for key in touch_hud.get_button_actions():
			if touch_hud.get_element_rect(key).has_point(point):
				return
		if touch_hud.get_lock_button_rect().has_point(point):
			return
	var modes: Array = _weapons[weapon.def.id]["modes"]
	var current := modes.find(weapon.fire_mode)
	weapon.fire_mode = modes[(current + 1) % modes.size()]
	choices[weapon.def.id] = weapon.fire_mode
	label.text = weapon.fire_mode.to_upper()
	get_viewport().set_input_as_handled()
