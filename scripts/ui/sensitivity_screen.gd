class_name SensitivityScreen
extends Control
## Sensitivity screen (G2d): preset buttons, the Camera / ADS / Gyro / ADS Gyro tables, Free Look, gyro mode
## and gyro inversion. Every change is saved to the profile at once. Opened from the shared SettingsPanel
## (main menu and in-match menu). Layout uses containers and anchors; all targets are at least 48 dp.

signal closed
## Emitted after every change was saved to the profile (the host panel forwards it).
signal changed

const _Theme := preload("res://scenes/ui/menu_theme.tres")
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
## The safe-margin content (faded in on enter).
var _content: Control


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	build()
	UiScale.bind(self)
	MenuStyle.fade_in(_content)


## Builds the screen from the profile (callable from tests after `save` is set).
func build() -> void:
	if _built:
		return
	_built = true
	settings = SensitivitySettings.from_profile(save.load_profile())
	var dp_h := 48.0 * PlatformServices.new().get_dp_scale()
	add_child(MenuBackdrop.make("page"))
	var margin := MenuStyle.safe_margin()
	add_child(margin)
	_content = margin
	var root := VBoxContainer.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(root, 1.5)
	margin.add_child(root)
	var header := MenuStyle.page_header("Sensitivity", _on_back)
	back_button = header["back"]
	root.add_child(header["row"])
	root.add_child(HSeparator.new())
	var presets := HBoxContainer.new()
	MenuStyle.gap(presets, 1.0)
	root.add_child(presets)
	presets.add_child(_row_caption("PRESET"))
	for p in settings.preset_names():
		preset_buttons[p] = _toggle(presets, str(p).capitalize(), _on_preset.bind(p))
	preset_buttons[SensitivitySettings.CUSTOM] = _toggle(presets, "Custom", Callable())
	preset_buttons[SensitivitySettings.CUSTOM].disabled = true  # shows state only: any slider edit makes it Custom
	var gyro_row := HBoxContainer.new()
	MenuStyle.gap(gyro_row, 1.0)
	root.add_child(gyro_row)
	gyro_row.add_child(_row_caption("GYRO"))
	for m in settings.cfg["gyro_modes"]:
		mode_buttons[m] = _toggle(gyro_row, MODE_TITLES[m], _on_mode.bind(m))
	invert_x_button = _toggle(gyro_row, "Invert X", _on_invert_x)
	invert_y_button = _toggle(gyro_row, "Invert Y", _on_invert_y)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	# A right gutter keeps the scrollbar off the value labels.
	var gutter := MarginContainer.new()
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	MenuStyle.pad(gutter, 0.0, 0.0, 1.75, 0.0)
	scroll.add_child(gutter)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	MenuStyle.gap(list, 1.0)
	gutter.add_child(list)
	var first := true
	for t in settings.all_tables():
		if not first:
			list.add_child(HSeparator.new())
		first = false
		var h := Label.new()
		h.text = TITLES[t]
		h.theme_type_variation = &"HeadlineLabel"
		list.add_child(h)
		for row in settings.rows_of(t):
			_add_row(list, t, row, dp_h)
	_refresh()


## The inline caption that starts the preset and gyro rows; same width on both so the rows line up.
func _row_caption(text: String) -> Label:
	var c := MenuStyle.caption(text)
	MenuStyle.min_width(c, 10.0)
	c.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return c


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
	MenuStyle.gap(box, 1.0)  # keeps a long row name off the slider
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
	MenuStyle.min_width(v, 8.0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
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
	changed.emit()
