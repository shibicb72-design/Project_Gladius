class_name SensitivityScreen
extends Control
## Sensitivity screen (G2d): preset buttons, the Camera / ADS / Gyro / ADS Gyro tables, Free Look, gyro mode
## and gyro inversion. Every change is saved to the profile at once. Opened from the shared SettingsPanel
## (main menu and in-match menu). Layout uses containers and anchors; all targets are at least 48 dp.

signal closed

const _Theme := preload("res://scenes/ui/theme.tres")
const TITLES := {"camera": "Camera", "ads": "ADS", "gyro": "Gyro", "ads_gyro": "ADS Gyro", "free_look": "Free Look"}
const ROW_TITLES := {"tpp_fpp_no_scope": "TPP / FPP, no scope", "red_dot": "Red dot", "2x": "2x", "4x": "4x", "8x": "8x",
		"16x": "16x", "tpp_character": "TPP character", "fpp_character": "FPP character"}
const MODE_TITLES := {"off": "Off", "scope_on": "ADS", "always_on": "Always"}

var save := SaveService.new()
var settings: SensitivitySettings
var back_button: Button
var preset_buttons: Dictionary = {}  # preset name (and "custom") -> Button
var mode_buttons: Dictionary = {}  # gyro mode -> Button
var invert_x_button: Button
var invert_y_button: Button
var sliders: Dictionary = {}  # "table/row" -> HSlider
var value_labels: Dictionary = {}  # "table/row" -> Label
var _built: bool = false


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	build()
	UiScale.bind(self)


## Builds the screen from the profile (callable from tests after `save` is set).
func build() -> void:
	if _built:
		return
	_built = true
	settings = SensitivitySettings.from_profile(save.load_profile())
	var dp_h := 48.0 * PlatformServices.new().get_dp_scale()
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.07, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var root := VBoxContainer.new()
	margin.add_child(root)
	var head := HBoxContainer.new()
	root.add_child(head)
	back_button = _button(head, "Back", _on_back)
	var title := Label.new()
	title.text = "Sensitivity"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_child(title)
	var presets := HBoxContainer.new()
	root.add_child(presets)
	for p in settings.preset_names():
		preset_buttons[p] = _toggle(presets, str(p).capitalize(), _on_preset.bind(p))
	preset_buttons[SensitivitySettings.CUSTOM] = _toggle(presets, "Custom", Callable())
	preset_buttons[SensitivitySettings.CUSTOM].disabled = true  # shows state only: any slider edit makes it Custom
	var gyro_row := HBoxContainer.new()
	root.add_child(gyro_row)
	var gl := Label.new()
	gl.text = "Gyro:"
	gyro_row.add_child(gl)
	for m in settings.cfg["gyro_modes"]:
		mode_buttons[m] = _toggle(gyro_row, MODE_TITLES[m], _on_mode.bind(m))
	invert_x_button = _toggle(gyro_row, "Invert X", _on_invert_x)
	invert_y_button = _toggle(gyro_row, "Invert Y", _on_invert_y)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for t in settings.all_tables():
		var h := Label.new()
		h.text = TITLES[t]
		list.add_child(h)
		for row in settings.rows_of(t):
			_add_row(list, t, row, dp_h)
	_refresh()


func _button(parent: Node, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	if handler.is_valid():
		b.pressed.connect(handler)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL if parent is HBoxContainer and text != "Back" else Control.SIZE_FILL
	parent.add_child(b)
	return b


func _toggle(parent: Node, text: String, handler: Callable) -> Button:
	var b := _button(parent, text, handler)
	b.toggle_mode = true
	return b


func _add_row(list: VBoxContainer, table: String, row: String, dp_h: float) -> void:
	var key := "%s/%s" % [table, row]
	var box := HBoxContainer.new()
	list.add_child(box)
	var name_label := Label.new()
	name_label.text = ROW_TITLES[row]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL  # same ratio on every row: sliders line up
	name_label.size_flags_stretch_ratio = 1.0
	name_label.clip_text = true
	box.add_child(name_label)
	var r := settings.range_of(table)
	var s := HSlider.new()
	s.min_value = r["min"]
	s.max_value = r["max"]
	s.step = r["step"]
	s.custom_minimum_size = Vector2(0, dp_h)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_stretch_ratio = 2.0
	s.value = settings.percent(table, row)
	s.value_changed.connect(_on_slider.bind(table, row))
	box.add_child(s)
	var v := Label.new()
	v.custom_minimum_size.x = 60.0
	box.add_child(v)
	sliders[key] = s
	value_labels[key] = v


func _on_slider(value: float, table: String, row: String) -> void:
	settings.set_value(table, row, value)
	_refresh()
	_persist()


func _on_preset(name: String) -> void:
	settings.apply_preset(name)
	_refresh()
	_persist()


func _on_mode(mode: String) -> void:
	settings.set_gyro_mode(mode)
	_refresh()
	_persist()


func _on_invert_x() -> void:
	settings.gyro_invert_x = not settings.gyro_invert_x
	_refresh()
	_persist()


func _on_invert_y() -> void:
	settings.gyro_invert_y = not settings.gyro_invert_y
	_refresh()
	_persist()


func _on_back() -> void:
	closed.emit()


## Syncs buttons, sliders and value labels to `settings` without re-emitting their signals.
func _refresh() -> void:
	for p in preset_buttons:
		preset_buttons[p].set_pressed_no_signal(p == settings.preset)
	for m in mode_buttons:
		mode_buttons[m].set_pressed_no_signal(m == settings.gyro_mode)
	invert_x_button.set_pressed_no_signal(settings.gyro_invert_x)
	invert_y_button.set_pressed_no_signal(settings.gyro_invert_y)
	for t in settings.all_tables():
		for row in settings.rows_of(t):
			var key := "%s/%s" % [t, row]
			sliders[key].set_value_no_signal(settings.percent(t, row))
			value_labels[key].text = "%d%%" % int(settings.percent(t, row))


func _persist() -> void:
	var profile := save.load_profile()
	profile["sensitivity"] = settings.to_dict()
	save.save_profile(profile)
	AppFlow.profile = save.load_profile()
