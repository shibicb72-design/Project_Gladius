class_name SettingsPanel
extends VBoxContainer
## Shared settings UI (gyro, move stick, stick layout, sprint sensitivity), used by the main menu and the
## in-match menu. Every change is written to the profile at once (persist()).

signal changed

var save := SaveService.new()
## Optional: extra profile keys owned by the host screen (main menu: gamertag, last_ip), merged on save.
var extra_fields: Callable = Callable()
var gyro_button: Button
var gyro_enabled: bool = false
var move_stick_button: Button
var stick_layout_button: Button
var move_stick_mode: String = "virtual"
var vjoy_layout: String = "floating"
var sprint_label: Label
var sprint_slider: HSlider
var sprint_lock_pos: Array = []  # kept so saving does not drop the layout editor's value


func _ready() -> void:
	var profile := save.load_profile()
	gyro_enabled = bool(profile["gyro_enabled"])
	gyro_button = _button("", toggle_gyro)  # Settings: gyro On/Off (OQ-34)
	_refresh_gyro_text()
	var input_cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]
	move_stick_mode = str(profile["move_stick"]) if str(profile["move_stick"]) != "" else str(input_cfg["move_stick"])
	vjoy_layout = str(profile["vjoy_layout"]) if str(profile["vjoy_layout"]) != "" else str(input_cfg["vjoy_layout"])
	move_stick_button = _button("", toggle_move_stick)  # Settings: Virtual / Custom move stick
	stick_layout_button = _button("", toggle_stick_layout)  # Settings: Floating / Fixed (virtual stick)
	_refresh_stick_text()
	sprint_lock_pos = profile["sprint_lock_pos"]
	_build_sprint_slider(float(profile["sprint_sensitivity"]))
	UiScale.apply_to(self)


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	add_child(b)
	return b


func toggle_gyro() -> void:
	gyro_enabled = not gyro_enabled
	_refresh_gyro_text()
	persist()


func _refresh_gyro_text() -> void:
	gyro_button.text = "Gyro aim: %s" % ("On" if gyro_enabled else "Off")


func toggle_move_stick() -> void:
	move_stick_mode = "custom" if move_stick_mode == "virtual" else "virtual"
	_refresh_stick_text()
	persist()


func toggle_stick_layout() -> void:
	vjoy_layout = "fixed" if vjoy_layout == "floating" else "floating"
	_refresh_stick_text()
	persist()


func _refresh_stick_text() -> void:
	move_stick_button.text = "Move stick: %s" % move_stick_mode.capitalize()
	stick_layout_button.text = "Stick: %s" % vjoy_layout.capitalize()
	stick_layout_button.disabled = move_stick_mode != "virtual"


## Settings: sprint sensitivity slider (range/step from data/input.json sprint_sensitivity). Higher = shorter push to sprint.
func _build_sprint_slider(value: float) -> void:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")["sprint_sensitivity"]
	sprint_label = Label.new()
	add_child(sprint_label)
	sprint_slider = HSlider.new()
	sprint_slider.min_value = float(cfg["min"])
	sprint_slider.max_value = float(cfg["max"])
	sprint_slider.step = float(cfg["step"])
	sprint_slider.custom_minimum_size = Vector2(0, 48.0 * PlatformServices.new().get_dp_scale())
	sprint_slider.value = value
	sprint_slider.value_changed.connect(_on_sprint_sensitivity_changed)
	add_child(sprint_slider)
	_refresh_sprint_text()


func _on_sprint_sensitivity_changed(_v: float) -> void:
	_refresh_sprint_text()
	persist()


func _refresh_sprint_text() -> void:
	sprint_label.text = "Sprint sensitivity: %d" % int(sprint_slider.value)


## The profile keys this panel owns.
func fields() -> Dictionary:
	return {"gyro_enabled": gyro_enabled, "move_stick": move_stick_mode, "vjoy_layout": vjoy_layout,
			"sprint_sensitivity": sprint_slider.value, "sprint_lock_pos": sprint_lock_pos}


## Writes the stored profile + the host screen's extra keys + this panel's keys, then reloads AppFlow.profile.
func persist() -> void:
	var profile := save.load_profile()
	if extra_fields.is_valid():
		profile.merge(extra_fields.call(), true)
	profile.merge(fields(), true)
	save.save_profile(profile)
	AppFlow.profile = save.load_profile()
	changed.emit()
