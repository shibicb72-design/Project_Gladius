class_name Lobby
extends Control
## Pre-match lobby: players by squad, Hastati/Sagittarii toggle (OQ-29), host Start, host IPs.
## H1 is wired: Start goes through NetLobby on every peer, MatchRoot then sends client input and fire
## to the host and applies its snapshots (see MatchRoot, NetMatchBridge, tests/test_net_match.gd).
## All networking goes through NetLobby (session.lobby); this UI only calls it and listens to its signals.

const _Theme := preload("res://scenes/ui/theme.tres")
const CLASSES: Array[String] = ["hastati", "sagittarii"]

var net_lobby: NetLobby
var state := LobbyState.new()
var rows_box: VBoxContainer
## One row button per slot, indexed by player_id (rebuilt in refresh()).
var slot_buttons: Array[Button] = []
var ips_label: Label
var status_label: Label
var start_button: Button
var class_button: Button
var is_host: bool = true
## HudNumbers.roman_enabled() read once in _ready, not on every refresh.
var roman_numerals: bool = false


func _ready() -> void:
	theme = _Theme
	roman_numerals = HudNumbers.roman_enabled()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var cfg := DataRegistry.new().load_file("res://data/match.json")
	var session := AppFlow.ensure_session(get_tree())
	net_lobby = session.lobby
	is_host = session.is_host
	state = net_lobby.state
	AppFlow.lobby = state
	var my_name := str(_profile().get("gamertag", SaveService.DEFAULT_GAMERTAG))

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(box)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	rows_box = VBoxContainer.new()
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows_box)
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	rows_box.mouse_filter = Control.MOUSE_FILTER_PASS
	# One info line, then one always-visible action row (Class, Start, Back): the roster takes the rest.
	var info := HBoxContainer.new()
	box.add_child(info)
	ips_label = Label.new()
	ips_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ips_label.clip_text = true
	info.add_child(ips_label)
	status_label = Label.new()
	status_label.clip_text = true
	info.add_child(status_label)
	var actions := HBoxContainer.new()
	actions.name = "ActionBar"
	box.add_child(actions)
	class_button = Button.new()
	class_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	class_button.pressed.connect(toggle_class)
	actions.add_child(class_button)
	start_button = Button.new()
	start_button.text = "Start"
	start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_button.visible = is_host
	start_button.pressed.connect(_on_start)
	actions.add_child(start_button)
	var back := Button.new()
	back.text = "Back"
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back.pressed.connect(_on_back)
	actions.add_child(back)

	session.host_lost.connect(_on_back)
	net_lobby.state_changed.connect(_on_state_changed)
	net_lobby.match_starting.connect(_on_match_starting)
	if is_host:
		ips_label.text = "Your IP: " + ", ".join(local_ipv4())
		net_lobby.host_open(int(cfg.get("squads", 2)),int(cfg.get("squad_size", 3)), my_name)
	else:
		status_label.text = "Connected. Waiting for the host to start."
		net_lobby.submit_local(my_name, "hastati")
	refresh()
	UiScale.bind(self)


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
	var me := net_lobby.local_id()
	var i := state.find_human(me)
	if i < 0:
		return
	var cur := str(state.humans[i]["class_id"])
	net_lobby.submit_local(str(state.humans[i]["name"]), _next_class(cur))


## Tapping a row: the host cycles a bot's class (OQ-55), anyone cycles their own; other rows do nothing.
func on_slot_pressed(player_id: int) -> void:
	var s := _slot(player_id)
	if s.is_empty():
		return
	if bool(s["is_bot"]):
		if is_host:
			net_lobby.set_bot_class(player_id, _next_class(str(s["class_id"])))
	elif int(s["peer_id"]) == net_lobby.local_id():
		toggle_class()


func _slot(player_id: int) -> Dictionary:
	for s in state.slots:
		if int(s["player_id"]) == player_id:
			return s
	return {}


static func _next_class(cur: String) -> String:
	return CLASSES[(CLASSES.find(cur) + 1) % CLASSES.size()]


func refresh() -> void:
	var slots := state.assign()
	for c in rows_box.get_children():
		rows_box.remove_child(c)
		c.queue_free()
	slot_buttons.clear()
	var last_squad := -1
	for s in slots:
		if int(s["squad_id"]) != last_squad:
			last_squad = int(s["squad_id"])
			var header := Label.new()
			header.text = HudNumbers.squad_name(last_squad, roman_numerals)
			rows_box.add_child(header)
		var row := Button.new()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.mouse_filter = Control.MOUSE_FILTER_PASS  # STOP would swallow touch drags before the ScrollContainer
		row.text = "%s (%s)%s" % [s["name"], s["class_id"], "" if not s["is_bot"] else " [bot]"]
		row.pressed.connect(on_slot_pressed.bind(int(s["player_id"])))
		rows_box.add_child(row)
		slot_buttons.append(row)
	UiScale.apply_to(self)
	var i := state.find_human(net_lobby.local_id())
	class_button.text = "Class: %s" % (str(state.humans[i]["class_id"]) if i >= 0 else "-")


func _on_state_changed() -> void:
	state = net_lobby.state
	AppFlow.lobby = state
	refresh()


func _on_match_starting() -> void:
	AppFlow.go(get_tree(), AppFlow.MATCH_SCENE)


func _on_start() -> void:
	net_lobby.start_match()


func _on_back() -> void:
	AppFlow.end_session()
	AppFlow.go(get_tree(), AppFlow.MENU_SCENE)
