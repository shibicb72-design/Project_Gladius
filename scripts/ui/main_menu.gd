class_name MainMenu
extends Control
## Main menu: Host, Join (manual IP, OQ-41), gamertag (OQ-39). Later-milestone entries are shown disabled.

const _Theme := preload("res://scenes/ui/theme.tres")
const LATER_ENTRIES: Array[String] = ["Loadout", "Profile", "Shop", "Tutorials", "Settings"]

var save := SaveService.new()
var name_edit: LineEdit
var ip_edit: LineEdit
var status_label: Label
var host_button: Button
var join_button: Button
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


func _save_profile() -> void:
	AppFlow.profile = {"gamertag": name_edit.text.strip_edges(), "last_ip": ip_edit.text.strip_edges()}
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
