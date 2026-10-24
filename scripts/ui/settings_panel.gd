class_name SettingsPanel
extends VBoxContainer
## Shared settings UI (gyro, move stick, stick layout, sprint sensitivity), used by the main menu and the
## in-match menu. Every change is written to the profile at once (persist()).

signal changed

var save := SaveService.new()
## Optional: extra profile keys owned by the host screen (main menu: gamertag, last_ip), merged on save.
var extra_fields: Callable = Callable()
const _SensitivityScene := preload("res://scenes/ui/sensitivity_screen.tscn")

var gyro_button: Button
var sensitivity_button: Button
var sensitivity_layer: CanvasLayer
var gyro_mode: String = "off"
var gyro_enabled: bool = false
var move_stick_button: Button
var stick_layout_button: Button
var move_stick_mode: String = "virtual"
var vjoy_layout: String = "floating"
var sprint_label: Label
var sprint_slider: HSlider
const _LayoutScene := preload("res://scenes/ui/layout_editor.tscn")
var layout_button: Button
var layout_layer: CanvasLayer
const _HapticsScene := preload("res://scenes/ui/haptics_screen.tscn")
var haptics_button: Button
var haptics_layer: CanvasLayer
var left_fire_button: Button
var left_fire_enabled: bool = false
var sprint_lock_pos: Array = []  # kept so saving does not drop the layout editor's value


func _ready() -> void:
	var profile := save.load_profile()
	gyro_mode = SensitivitySettings.from_profile(profile).gyro_mode
	gyro_enabled = gyro_mode != "off"
	# G2d: the Sensitivity screen owns the gyro mode, tables and inversion; this quick toggle (Off <-> Always)
	# is kept because tests/test_decisions_batch1.gd and tests/test_pause_menu.gd still pin it.
	sensitivity_button = _button("Sensitivity", open_sensitivity)
	gyro_button = _button("", toggle_gyro)
	_refresh_gyro_text()
	var input_cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]
	move_stick_mode = str(profile["move_stick"]) if str(profile["move_stick"]) != "" else str(input_cfg["move_stick"])
	vjoy_layout = str(profile["vjoy_layout"]) if str(profile["vjoy_layout"]) != "" else str(input_cfg["vjoy_layout"])
	move_stick_button = _button("", toggle_move_stick)  # Settings: Virtual / Custom move stick
	stick_layout_button = _button("", toggle_stick_layout)  # Settings: Floating / Fixed (virtual stick)
	_refresh_stick_text()
	sprint_lock_pos = profile["sprint_lock_pos"]
	_build_sprint_slider(float(profile["sprint_sensitivity"]))
	left_fire_enabled = bool(profile["left_fire_enabled"])
	left_fire_button = _button("", toggle_left_fire)  # G3e
	_refresh_left_fire_text()
	layout_button = _button("HUD layout", open_layout_editor)  # G2e
	haptics_button = _button("Haptics", open_haptics)  # G2f
	UiScale.apply_to(self)


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	add_child(b)
	return b


## Quick toggle: any gyro mode goes to off, off goes to always_on. Reads the stored sensitivity first so a
## change made on the Sensitivity screen is not overwritten.
func toggle_gyro() -> void:
	var s := SensitivitySettings.from_profile(save.load_profile())
	s.set_gyro_mode("off" if s.gyro_mode != "off" else "always_on")
	gyro_mode = s.gyro_mode
	gyro_enabled = gyro_mode != "off"
	_refresh_gyro_text()
	var profile := save.load_profile()
	profile["sensitivity"] = s.to_dict()
	save.save_profile(profile)
	persist()


func _refresh_gyro_text() -> void:
	var names := {"off": "Off", "scope_on": "ADS", "always_on": "On"}
	gyro_button.text = "Gyro aim: %s" % names[gyro_mode]


## Opens the Sensitivity screen on top of everything (own CanvasLayer, so it works in the menu and in a match).
func open_sensitivity() -> void:
	if sensitivity_layer != null:
		return
	sensitivity_layer = CanvasLayer.new()
	sensitivity_layer.layer = 100
	sensitivity_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var screen: SensitivityScreen = _SensitivityScene.instantiate()
	screen.save = save
	screen.closed.connect(_close_sensitivity)
	screen.changed.connect(changed.emit)  # the host (in-match: MatchRoot) re-reads the profile
	sensitivity_layer.add_child(screen)
	add_child(sensitivity_layer)


func _close_sensitivity() -> void:
	if sensitivity_layer == null:
		return
	sensitivity_layer.queue_free()
	sensitivity_layer = null
	var profile := save.load_profile()
	gyro_mode = SensitivitySettings.from_profile(profile).gyro_mode
	gyro_enabled = gyro_mode != "off"
	_refresh_gyro_text()


## Opens the HUD layout editor (G2e) on top of everything, like the Sensitivity screen.
func open_layout_editor() -> void:
	if layout_layer != null:
		return
	layout_layer = CanvasLayer.new()
	layout_layer.layer = 100
	layout_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var editor: LayoutEditor = _LayoutScene.instantiate()
	editor.save = save
	editor.closed.connect(_close_layout_editor)
	editor.changed.connect(_on_layout_saved)
	layout_layer.add_child(editor)
	add_child(layout_layer)


func _on_layout_saved() -> void:
	sprint_lock_pos = save.load_profile()["sprint_lock_pos"]  # the editor mirrors the active slot's lock position
	changed.emit()  # the host (in-match: MatchRoot) re-applies the layout to the live HUD


func _close_layout_editor() -> void:
	if layout_layer == null:
		return
	layout_layer.queue_free()
	layout_layer = null
	sprint_lock_pos = save.load_profile()["sprint_lock_pos"]


## Opens the Haptics screen (G2f) on top of everything, like the Sensitivity screen.
func open_haptics() -> void:
	if haptics_layer != null:
		return
	haptics_layer = CanvasLayer.new()
	haptics_layer.layer = 100
	haptics_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var screen: HapticsScreen = _HapticsScene.instantiate()
	screen.save = save
	screen.closed.connect(_close_haptics)
	screen.changed.connect(changed.emit)
	haptics_layer.add_child(screen)
	add_child(haptics_layer)


func _close_haptics() -> void:
	if haptics_layer == null:
		return
	haptics_layer.queue_free()
	haptics_layer = null


func toggle_move_stick() -> void:
	move_stick_mode = "custom" if move_stick_mode == "virtual" else "virtual"
	_refresh_stick_text()
	persist()


func toggle_stick_layout() -> void:
	vjoy_layout = "fixed" if vjoy_layout == "floating" else "floating"
	_refresh_stick_text()
	persist()


## G3e: the optional second Fire button for the left thumb (touch HUD).
func toggle_left_fire() -> void:
	left_fire_enabled = not left_fire_enabled
	_refresh_left_fire_text()
	persist()


func _refresh_left_fire_text() -> void:
	left_fire_button.text = "Left Fire button: %s" % ("On" if left_fire_enabled else "Off")


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
	return {"move_stick": move_stick_mode, "vjoy_layout": vjoy_layout,
			"sprint_sensitivity": sprint_slider.value, "sprint_lock_pos": sprint_lock_pos,
			"left_fire_enabled": left_fire_enabled}


## Writes the stored profile + the host screen's extra keys + this panel's keys, then reloads AppFlow.profile.
func persist() -> void:
	var profile := save.load_profile()
	if extra_fields.is_valid():
		profile.merge(extra_fields.call(), true)
	profile.merge(fields(), true)
	save.save_profile(profile)
	AppFlow.profile = save.load_profile()
	changed.emit()
