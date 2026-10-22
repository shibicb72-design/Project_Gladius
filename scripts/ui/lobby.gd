class_name Lobby
extends Control
## Pre-match lobby: players by squad, Hastati/Sagittarii toggle (OQ-29), host Start, host IPs.
## TODO: peer name/class sync and match start for remote peers are not wired yet (see OPEN_QUESTIONS).

const _Theme := preload("res://scenes/ui/theme.tres")
const CLASSES: Array[String] = ["hastati", "sagittarii"]

var state := LobbyState.new()
var list_label: Label
var ips_label: Label
var status_label: Label
var start_button: Button
var class_button: Button
var is_host: bool = true


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var cfg := DataRegistry.new().load_file("res://data/match.json")
	state.setup(2, int(cfg.get("squad_size", 3)))
	var session := AppFlow.session
	is_host = session == null or session.is_host
	AppFlow.lobby = state
	state.add_human(1, str(_profile().get("gamertag", SaveService.DEFAULT_GAMERTAG)))

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(box)
	list_label = Label.new()
	list_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(list_label)
	ips_label = Label.new()
	box.add_child(ips_label)
	status_label = Label.new()
	box.add_child(status_label)
	class_button = Button.new()
	class_button.pressed.connect(toggle_class)
	box.add_child(class_button)
	start_button = Button.new()
	start_button.text = "Start"
	start_button.visible = is_host
	start_button.pressed.connect(_on_start)
	box.add_child(start_button)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_on_back)
	box.add_child(back)

	if session != null:
		session.peer_joined.connect(_on_peer_joined)
		session.peer_left.connect(_on_peer_left)
		session.host_lost.connect(_on_back)
	if is_host:
		ips_label.text = "Your IP: " + ", ".join(local_ipv4())
	else:
		status_label.text = "Connected. Waiting for the host to start."
	refresh()


func _profile() -> Dictionary:
	return AppFlow.profile if not AppFlow.profile.is_empty() else SaveService.new().load_profile()


## Non-loopback IPv4 addresses of this device (shown on the host so others can join).
static func local_ipv4() -> Array[String]:
	var out: Array[String] = []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out


func toggle_class() -> void:
	var i := state.find_human(1)
	if i < 0:
		return
	var cur := str(state.humans[i]["class_id"])
	state.set_class(1, CLASSES[(CLASSES.find(cur) + 1) % CLASSES.size()])
	refresh()


func refresh() -> void:
	var slots := state.assign()
	var lines: Array[String] = []
	var last_squad := -1
	for s in slots:
		if int(s["squad_id"]) != last_squad:
			last_squad = int(s["squad_id"])
			lines.append("Squad %s" % RomanNumerals.to_roman(last_squad + 1))
		lines.append("  %s (%s)%s" % [s["name"], s["class_id"], "" if not s["is_bot"] else " [bot]"])
	list_label.text = "\n".join(lines)
	var i := state.find_human(1)
	class_button.text = "Class: %s" % (str(state.humans[i]["class_id"]) if i >= 0 else "-")


func _on_peer_joined(peer_id: int) -> void:
	if is_host and state.add_human(peer_id, "Player %d" % peer_id):
		refresh()


func _on_peer_left(peer_id: int) -> void:
	state.remove_human(peer_id)
	refresh()


func _on_start() -> void:
	if state.start():
		AppFlow.go(get_tree(), AppFlow.MATCH_SCENE)


func _on_back() -> void:
	AppFlow.end_session()
	AppFlow.go(get_tree(), AppFlow.MENU_SCENE)
