class_name PauseMenu
extends Control
## In-match menu: a small gear at the top-right opens a full-screen overlay (Resume, Settings, Quit to main
## menu with a confirm step). The gear is the ONLY way in: Android Back / ui_cancel are not handled here.
## Pausing and the zero InputFrame are decided by MatchRoot; this node only reports opened/closed/quit.

signal opened
signal closed
signal quit_confirmed

const _Theme := preload("res://scenes/ui/theme.tres")
const _SettingsScene := preload("res://scenes/ui/settings_panel.tscn")

var is_open: bool = false
var settings: SettingsPanel
var resume_button: Button
var settings_button: Button
var quit_button: Button
var confirm_button: Button
var cancel_button: Button
var back_button: Button

var _gear: Dictionary = {}
var _menu: Dictionary = {}
var _overlay: Control
var _main_box: VBoxContainer
var _confirm_box: VBoxContainer
var _settings_box: VBoxContainer


func _ready() -> void:
	theme = _Theme
	process_mode = Node.PROCESS_MODE_ALWAYS  # works while the tree is paused (offline)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ui := DataRegistry.new().load_file("res://data/ui.json")
	_gear = ui["pause_gear"]
	_menu = ui["pause_menu"]
	_build()
	resized.connect(queue_redraw)


func _build() -> void:
	_overlay = Control.new()
	_overlay.theme = _Theme
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP  # swallows every touch while open
	_overlay.visible = false
	add_child(_overlay)
	var dim := ColorRect.new()
	dim.color = _color(_menu["dim_color"])
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var holder := VBoxContainer.new()
	center.add_child(holder)
	_main_box = _box(holder)
	resume_button = _button(_main_box, _menu["resume_text"], close)
	settings_button = _button(_main_box, _menu["settings_text"], func() -> void: _show(_settings_box))
	quit_button = _button(_main_box, _menu["quit_text"], func() -> void: _show(_confirm_box))
	_confirm_box = _box(holder)
	var prompt := Label.new()
	prompt.text = _menu["confirm_prompt"]
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_box.add_child(prompt)
	confirm_button = _button(_confirm_box, _menu["confirm_text"], func() -> void: quit_confirmed.emit())
	cancel_button = _button(_confirm_box, _menu["cancel_text"], func() -> void: _show(_main_box))
	_settings_box = _box(holder)
	settings = _SettingsScene.instantiate()  # the same scene the main menu uses
	_settings_box.add_child(settings)
	back_button = _button(_settings_box, _menu["back_text"], func() -> void: _show(_main_box))
	UiScale.bind(_overlay)
	_show(_main_box)


func _box(parent: Node) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", int(float(_menu["gap_dp"]) * PlatformServices.new().get_dp_scale()))
	b.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(b)
	return b


func _button(parent: Node, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	var s := PlatformServices.new().get_dp_scale()
	b.custom_minimum_size = Vector2(float(_menu["button_dp"][0]), float(_menu["button_dp"][1])) * s
	parent.add_child(b)
	return b


func _show(which: Control) -> void:
	for b in [_main_box, _confirm_box, _settings_box]:
		b.visible = b == which


func open() -> void:
	if is_open:
		return
	is_open = true
	_show(_main_box)
	_overlay.visible = true
	queue_redraw()
	opened.emit()


func close() -> void:
	if not is_open:
		return
	is_open = false
	_overlay.visible = false
	queue_redraw()
	closed.emit()


## Touch rect of the gear in global coordinates: touch_dp square (>= 48 dp) in the corner given by data.
func get_gear_touch_rect() -> Rect2:
	var s := PlatformServices.new().get_dp_scale()
	var side := float(_gear["touch_dp"]) * s
	var corner := Vector2(float(_gear["anchor"][0]) * size.x, float(_gear["anchor"][1]) * size.y)
	var margin := Vector2(float(_gear["margin_dp"][0]), float(_gear["margin_dp"][1])) * s
	var pos := Vector2(corner.x - margin.x - side, corner.y + margin.y)
	return Rect2(global_position + pos, Vector2(side, side))


## The drawn gear: icon_dp square centred in the touch rect.
func get_gear_icon_rect() -> Rect2:
	var t := get_gear_touch_rect()
	var side := float(_gear["icon_dp"]) * PlatformServices.new().get_dp_scale()
	return Rect2(t.get_center() - Vector2.ONE * side * 0.5, Vector2.ONE * side)


func _draw() -> void:
	if is_open or _gear.is_empty():
		return
	var r := get_gear_icon_rect()
	var c := r.get_center() - global_position
	var outer := r.size.x * 0.5
	var teeth := int(_gear["teeth"])
	var col := _color(_gear["color"])
	draw_circle(c, outer, Color(0.0, 0.0, 0.0, 0.35))
	var pts := PackedVector2Array()
	for i in teeth * 4:
		var rad := outer * (0.9 if (i % 4) < 2 else 0.68)
		pts.append(c + Vector2.from_angle(TAU * (float(i) - 0.5) / float(teeth * 4)) * rad)
	draw_colored_polygon(pts, col)
	draw_circle(c, outer * 0.28, Color(0.0, 0.0, 0.0, 0.6))


## The gear is handled here, before the touch HUD's stick/button zones (this node sits after it in the tree),
## and the tap is consumed so it never becomes a look touch.
func _input(event: InputEvent) -> void:
	if is_open:
		return
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch and event.pressed:
		pos = event.position
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		pos = event.position
	else:
		return
	if get_gear_touch_rect().has_point(pos):
		open()
		get_viewport().set_input_as_handled()


static func _color(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
