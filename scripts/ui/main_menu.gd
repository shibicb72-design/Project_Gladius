class_name MainMenu
extends Control
## Main menu: Host, Join (manual IP, OQ-41), gamertag (OQ-39). Later-milestone entries are shown disabled.

const _Theme := preload("res://scenes/ui/theme.tres")
const LATER_ENTRIES: Array[String] = ["Loadout", "Profile", "Shop", "Tutorials"]

var save := SaveService.new()
var name_edit: LineEdit
var ip_edit: LineEdit
var status_label: Label
var host_button: Button
var join_button: Button
var gyro_button: Button
var gyro_enabled: bool = false
var move_stick_button: Button
var stick_layout_button: Button
var move_stick_mode: String = "virtual"
var vjoy_layout: String = "floating"
var sprint_label: Label
var sprint_slider: HSlider
var sprint_lock_pos: Array = []  # kept so saving the menu does not drop the layout editor's value
var later_buttons: Array[Button] = []


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var profile := save.load_profile()
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(360, 0)
	center.add_child(box)
	var title := Label.new()
	title.text = "PROJECT GLADIUS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Gamertag"
	name_edit.text = str(profile["gamertag"])
	box.add_child(name_edit)
	host_button = _button(box, "Host", _on_host)
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "Host IP"
	ip_edit.text = str(profile["last_ip"])
	box.add_child(ip_edit)
	join_button = _button(box, "Join", _on_join)
	gyro_enabled = bool(profile["gyro_enabled"])
	gyro_button = _button(box, "", toggle_gyro)  # Settings: gyro On/Off (OQ-34)
	_refresh_gyro_text()
	var input_cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")["touch_layout"]
	move_stick_mode = str(profile["move_stick"]) if str(profile["move_stick"]) != "" else str(input_cfg["move_stick"])
	vjoy_layout = str(profile["vjoy_layout"]) if str(profile["vjoy_layout"]) != "" else str(input_cfg["vjoy_layout"])
	move_stick_button = _button(box, "", toggle_move_stick)  # Settings: Virtual / Custom move stick
	stick_layout_button = _button(box, "", toggle_stick_layout)  # Settings: Floating / Fixed (virtual stick)
	_refresh_stick_text()
	sprint_lock_pos = profile["sprint_lock_pos"]
	_build_sprint_slider(box, float(profile["sprint_sensitivity"]))
	for entry in LATER_ENTRIES:
		var b := _button(box, "%s (later)" % entry, Callable())
		b.disabled = true
		later_buttons.append(b)
	status_label = Label.new()
	box.add_child(status_label)
	UiScale.bind(self)


func _button(parent: Node, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	if handler.is_valid():
		b.pressed.connect(handler)
	parent.add_child(b)
	return b


func toggle_gyro() -> void:
	gyro_enabled = not gyro_enabled
	_refresh_gyro_text()
	_save_profile()


func _refresh_gyro_text() -> void:
	gyro_button.text = "Gyro aim: %s" % ("On" if gyro_enabled else "Off")


func toggle_move_stick() -> void:
	move_stick_mode = "custom" if move_stick_mode == "virtual" else "virtual"
	_refresh_stick_text()
	_save_profile()


func toggle_stick_layout() -> void:
	vjoy_layout = "fixed" if vjoy_layout == "floating" else "floating"
	_refresh_stick_text()
	_save_profile()


func _refresh_stick_text() -> void:
	move_stick_button.text = "Move stick: %s" % move_stick_mode.capitalize()
	stick_layout_button.text = "Stick: %s" % vjoy_layout.capitalize()
	stick_layout_button.disabled = move_stick_mode != "virtual"


## Settings: sprint sensitivity slider (range/step from data/input.json sprint_sensitivity). Higher = shorter push to sprint.
func _build_sprint_slider(parent: Node, value: float) -> void:
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json")["sprint_sensitivity"]
	sprint_label = Label.new()
	parent.add_child(sprint_label)
	sprint_slider = HSlider.new()
	sprint_slider.min_value = float(cfg["min"])
	sprint_slider.max_value = float(cfg["max"])
	sprint_slider.step = float(cfg["step"])
	sprint_slider.custom_minimum_size = Vector2(0, 48.0 * PlatformServices.new().get_dp_scale())
	sprint_slider.value = value
	sprint_slider.value_changed.connect(_on_sprint_sensitivity_changed)
	parent.add_child(sprint_slider)
	_refresh_sprint_text()


func _on_sprint_sensitivity_changed(_v: float) -> void:
	_refresh_sprint_text()
	_save_profile()


func _refresh_sprint_text() -> void:
	sprint_label.text = "Sprint sensitivity: %d" % int(sprint_slider.value)


func _save_profile() -> void:
	AppFlow.profile = {"gamertag": name_edit.text.strip_edges(), "last_ip": ip_edit.text.strip_edges(),
			"gyro_enabled": gyro_enabled, "move_stick": move_stick_mode, "vjoy_layout": vjoy_layout,
			"sprint_sensitivity": sprint_slider.value, "sprint_lock_pos": sprint_lock_pos}
	save.save_profile(AppFlow.profile)
	AppFlow.profile = save.load_profile()


func _on_host() -> void:
	_save_profile()
	var session := AppFlow.ensure_session(get_tree())
	var err := session.host_game()
	if err != OK:
		status_label.text = "Could not host (error %d)" % err
		AppFlow.end_session()
		return
	AppFlow.go(get_tree(), AppFlow.LOBBY_SCENE)


func _on_join() -> void:
	_save_profile()
	var address := str(AppFlow.profile["last_ip"])
	if address.is_empty():
		status_label.text = "Enter the host IP"
		return
	var session := AppFlow.ensure_session(get_tree())
	session.connected.connect(_on_joined, CONNECT_ONE_SHOT)
	session.failed.connect(_on_join_failed, CONNECT_ONE_SHOT)
	var err := session.join_game(address)
	if err != OK:
		status_label.text = "Could not connect (error %d)" % err
		AppFlow.end_session()
		return
	status_label.text = "Connecting..."


func _on_joined() -> void:
	AppFlow.go(get_tree(), AppFlow.LOBBY_SCENE)


func _on_join_failed() -> void:
	status_label.text = "Connection failed"
	AppFlow.end_session()
