class_name Lobby
extends Control
## Pre-match lobby: players by squad, Hastati/Sagittarii toggle (OQ-29), host Start, host IPs.
## H1 is wired: Start goes through NetLobby on every peer, MatchRoot then sends client input and fire
## to the host and applies its snapshots (see MatchRoot, NetMatchBridge, tests/test_net_match.gd).
## All networking goes through NetLobby (session.lobby); this UI only calls it and listens to its signals.
## Layout (docs/UI_STYLE.md): page backdrop; header (title, IPs or status); the roster as a grid of squad cards in a
## vertical scroll; the always-visible ActionBar (Back, Class, Mode, Length, Bots, Start) at the bottom.

const _Theme := preload("res://scenes/ui/menu_theme.tres")
const CLASSES: Array[String] = ["hastati", "sagittarii"]

var net_lobby: NetLobby
var state := LobbyState.new()
var rows_box: VBoxContainer
## The squad cards (one VBoxContainer per squad: caption, then its rows), inside rows_box.
var squad_grid: GridContainer
## One row button per slot, indexed by player_id (rebuilt in refresh()).
var slot_buttons: Array[Button] = []
var ips_label: Label
var status_label: Label
var start_button: Button
var class_button: Button
## Host only: Solo / Squads (battle royale team mode). Clients see the mode in the status line.
var mode_button: Button
## Host only (M2 Z2, OQ-BR-LENGTH): cycles the data/br.json match_length options. Clients see it in the status line.
var length_button: Button
## Host only (M2 B4, OQ-BOT-DIFFICULTY): cycles the data/bots.json difficulty levels. Clients see it in the status line.
var bot_button: Button
## Where a length or bot difficulty change is saved (tests point it at a temp user:// file).
var save := SaveService.new()
var is_host: bool = true
var _br_cfg: Dictionary = {}
var _match_cfg: Dictionary = {}
## HudNumbers.roman_enabled() read once in _ready, not on every refresh.
var roman_numerals: bool = false
## The roster scroll (rows_box's parent).
var _scroll: ScrollContainer
## data/ui.json, read once.
var _ui: Dictionary = {}


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

	add_child(MenuBackdrop.make("page"))
	var margin := MenuStyle.safe_margin()
	add_child(margin)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(box, 1.5)
	margin.add_child(box)
	# Header: the title, then the host's IPs or the client's status line at the right.
	var header := HBoxContainer.new()
	header.name = "Header"
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(header, 2.0)
	box.add_child(header)
	header.add_child(MenuStyle.headline("Lobby"))
	ips_label = Label.new()
	ips_label.theme_type_variation = &"CaptionLabel"
	ips_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ips_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ips_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ips_label.clip_text = true
	ips_label.visible = is_host
	header.add_child(ips_label)
	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.clip_text = true
	status_label.visible = not is_host
	header.add_child(status_label)
	box.add_child(HSeparator.new())
	# The roster (squad cards in a grid) takes the rest; the action bar below it is always visible.
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	rows_box = VBoxContainer.new()
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(rows_box)
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	rows_box.mouse_filter = Control.MOUSE_FILTER_PASS
	squad_grid = GridContainer.new()
	squad_grid.name = "SquadGrid"
	squad_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	squad_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	MenuStyle.gap(squad_grid, 1.5)
	rows_box.add_child(squad_grid)
	# M2 Z2: a flow container, one row when the five buttons fit, else it wraps to a second row (the Fold's inner
	# screen: its 1152 x 959 canvas has taller buttons whose labels do not fit in one row). Each row's buttons
	# still share the row width by their stretch ratios.
	var actions := HFlowContainer.new()
	actions.name = "ActionBar"
	actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(actions, 1.5)
	box.add_child(actions)
	var back := Button.new()
	back.text = "Back"
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back.size_flags_stretch_ratio = 0.8
	MenuStyle.add_icon(back, "chevron_left")
	back.pressed.connect(_on_back)
	actions.add_child(back)
	class_button = Button.new()
	class_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	class_button.pressed.connect(toggle_class)
	actions.add_child(class_button)
	mode_button = Button.new()
	mode_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_button.visible = is_host
	mode_button.pressed.connect(toggle_team_mode)
	actions.add_child(mode_button)
	length_button = Button.new()
	length_button.name = "LengthButton"
	length_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	length_button.visible = is_host
	length_button.pressed.connect(cycle_match_length)
	actions.add_child(length_button)
	bot_button = Button.new()
	bot_button.name = "BotDifficultyButton"
	bot_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot_button.visible = is_host
	bot_button.pressed.connect(cycle_bot_difficulty)
	actions.add_child(bot_button)
	start_button = Button.new()
	start_button.text = "Start"
	start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_button.size_flags_stretch_ratio = 1.4
	MenuStyle.primary(start_button)  # the screen's one crimson control; before add_icon (picks the Icon twin)
	MenuStyle.add_icon(start_button, "play")
	start_button.visible = is_host
	start_button.pressed.connect(_on_start)
	actions.add_child(start_button)
	resized.connect(_update_columns)
	_scroll.resized.connect(_update_columns)  # its first real width arrives after the first layout pass

	session.host_lost.connect(_on_back)
	net_lobby.state_changed.connect(_on_state_changed)
	net_lobby.match_starting.connect(_on_match_starting)
	var reg := DataRegistry.new()
	# The br config: team layouts (host) and the match length options and labels (host and clients, M2 Z2).
	_br_cfg = ModeRegistry.merged_config(MatchDirector.MODE_ID, reg.load_file("res://data/modes.json"))
	if is_host:
		ips_label.text = "Your IP: " + ", ".join(local_ipv4())
		_match_cfg = cfg
		var layout := MatchDirector.team_layout(_br_cfg, cfg)
		net_lobby.host_open(int(layout["squad_count"]), int(layout["squad_size"]), my_name, [], int(cfg.get("max_humans", 8)))
		set_team_mode(MatchDirector.team_mode_of(_br_cfg))
		# M2 Z2: the profile's last length (validated, else the data default). Not saved here: only a change saves.
		_apply_match_length(SaveService.match_length(_profile().get("match_length", null)), false)
		# M2 B4: the profile's last bot difficulty (validated, else the data default). Not saved here either.
		_apply_bot_difficulty(SaveService.bot_difficulty(_profile().get("bot_difficulty", null)), false)
	else:
		status_label.text = "Connected. Waiting for the host to start."
		net_lobby.submit_local(my_name, "hastati")
	refresh()
	UiScale.bind(self)
	MenuStyle.fade_in(box)


func _profile() -> Dictionary:
	return AppFlow.profile if not AppFlow.profile.is_empty() else SaveService.new().load_profile()


## Non-loopback IPv4 addresses of this device (shown on the host so others can join).
static func local_ipv4() -> Array[String]:
	var out: Array[String] = []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out


## Host only: Solo <-> Squads.
func toggle_team_mode() -> void:
	set_team_mode("squads" if state.team_mode == "solo" else "solo")


## Host only: applies a team mode and its layout (solo = 18 x 1, squads = 6 x 3). False if refused.
func set_team_mode(mode: String) -> bool:
	if not is_host:
		return false
	var cfg := _br_cfg.duplicate(true)
	cfg["teams"] = (cfg.get("teams", {}) as Dictionary).duplicate(true)
	cfg["teams"]["mode"] = {"value": mode}
	var layout := MatchDirector.team_layout(cfg, _match_cfg)
	var ok := net_lobby.host_set_team_mode(mode, int(layout["squad_count"]), int(layout["squad_size"]))
	refresh()
	return ok


## M2 Z2, host only: the next data/br.json match_length option, in data order (wraps).
func cycle_match_length() -> void:
	var ids: Array[String] = []
	for opt: Dictionary in MatchDirector.match_length_options(_br_cfg):
		ids.append(str(opt.get("id", "")))
	if ids.is_empty():
		return
	set_match_length(ids[(ids.find(state.match_length) + 1) % ids.size()])


## M2 Z2, host only: sets a data match length id, saves it in the profile and sends it to the clients. False for a
## client, an id not in data, or after the start.
func set_match_length(id: String) -> bool:
	if not is_host or MatchDirector.match_length_option(_br_cfg, id).is_empty():
		return false
	return _apply_match_length(id, true)


func _apply_match_length(id: String, persist: bool) -> bool:
	if not net_lobby.state.set_match_length(id):
		return false
	state = net_lobby.state
	if persist:  # the settings screens' pattern (haptics_screen.gd _persist)
		var profile := save.load_profile()
		profile["match_length"] = id
		save.save_profile(profile)
		AppFlow.profile = save.load_profile()
	_resend_lobby()
	refresh()
	return true


## M2 B4, host only: the next data/bots.json difficulty level, in data order (wraps).
func cycle_bot_difficulty() -> void:
	var ids := MatchRoot.bot_difficulty_ids()
	if ids.is_empty():
		return
	set_bot_difficulty(ids[(ids.find(state.bot_difficulty) + 1) % ids.size()])


## M2 B4, host only: sets a data bot difficulty id, saves it in the profile and sends it to the clients. False for a
## client, an id not in data, or after the start.
func set_bot_difficulty(id: String) -> bool:
	if not is_host or MatchRoot.bot_difficulty_level(id).is_empty():
		return false
	return _apply_bot_difficulty(id, true)


func _apply_bot_difficulty(id: String, persist: bool) -> bool:
	if not net_lobby.state.set_bot_difficulty(id):
		return false
	state = net_lobby.state
	if persist:
		var profile := save.load_profile()
		profile["bot_difficulty"] = id
		save.save_profile(profile)
		AppFlow.profile = save.load_profile()
	_resend_lobby()
	refresh()
	return true


## Host: sends the lobby state (match length, bot difficulty) to the clients. NetLobby (read-only in this slice) has
## no host_set_match_length / host_set_bot_difficulty. Its public submit_local on the host applies the host's own
## unchanged name and class and then broadcasts state.to_dict() to every client, so re-submitting them sends the new
## value. A dedicated NetLobby setter would be cleaner (outside this slice).
func _resend_lobby() -> void:
	var i := state.find_human(net_lobby.local_id())
	if i >= 0:
		net_lobby.submit_local(str(state.humans[i]["name"]), str(state.humans[i]["class_id"]))


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
	for c in squad_grid.get_children():
		squad_grid.remove_child(c)
		c.queue_free()
	slot_buttons.clear()
	var me := net_lobby.local_id()
	var last_squad := -1
	var card: VBoxContainer = null
	for s in slots:
		if int(s["squad_id"]) != last_squad or card == null:
			last_squad = int(s["squad_id"])
			card = VBoxContainer.new()
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			card.mouse_filter = Control.MOUSE_FILTER_PASS
			MenuStyle.gap(card, 0.75)
			squad_grid.add_child(card)
			var header := Label.new()
			header.theme_type_variation = &"CaptionLabel"
			header.text = HudNumbers.squad_name(last_squad, roman_numerals)
			card.add_child(header)
		var is_bot := bool(s["is_bot"])
		var row := Button.new()
		MenuStyle.row(row)
		row.mouse_filter = Control.MOUSE_FILTER_PASS  # STOP would swallow touch drags before the ScrollContainer
		row.text = "%s (%s)%s" % [s["name"], s["class_id"], "" if not s["is_bot"] else " [bot]"]
		row.clip_text = true
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		MenuStyle.add_icon(row, "gear" if is_bot else "standard")
		if not is_bot and int(s["peer_id"]) == me:
			row.add_theme_color_override("font_color", MenuStyle.color("gold_hi"))  # find yourself at a glance
		row.pressed.connect(on_slot_pressed.bind(int(s["player_id"])))
		card.add_child(row)
		slot_buttons.append(row)
	_update_columns()
	UiScale.apply_to(self)
	var i := state.find_human(net_lobby.local_id())
	class_button.text = "Class: %s" % (str(state.humans[i]["class_id"]) if i >= 0 else "-")
	var mode_name := "Squads" if state.team_mode == "squads" else "Solo"
	mode_button.text = "Mode: %s" % mode_name
	var length_label := MatchDirector.match_length_label(_br_cfg, state.match_length)  # "" for "" or an unknown id
	length_button.text = "Length: %s" % (length_label if length_label != "" else "-")
	var bots_label := MatchRoot.bot_difficulty_label(state.bot_difficulty)  # "" for an unknown id
	bot_button.text = "Bots: %s" % (bots_label if bots_label != "" else "-")
	if not is_host:
		var length_part := " Length: %s." % length_label if length_label != "" else ""
		var bots_part := " Bots: %s." % bots_label if bots_label != "" else ""
		status_label.text = "Mode: %s.%s%s Waiting for the host to start." % [mode_name, length_part, bots_part]


## Squad card columns: one per ~15 body-font widths of roster width, 1 to 3.
func _update_columns() -> void:
	if squad_grid == null:
		return
	var vp := get_viewport()
	var vis := vp.get_visible_rect().size if vp != null else size
	var font_px := maxi(roundi(vis.y * float(_ui_cfg().get("font_size_frac_of_height", 0.0))), 1)
	var w := _scroll.size.x if _scroll != null and _scroll.size.x > 0.0 else _content_width(vis)
	squad_grid.columns = clampi(floori(w / (float(font_px) * 15.0)), 1, 3)


## Root width minus the safe margin's left and right (before the first layout pass).
func _content_width(vis: Vector2) -> float:
	var w := size.x if size.x > 0.0 else vis.x
	var base := MenuStyle.unit(vis.y) * float(MenuStyle.cfg().get("screen_margin_units", 0.0))
	var insets := PlatformServices.new().get_safe_insets()
	return w - 2.0 * base - (insets.x + insets.z) * vis.x


func _ui_cfg() -> Dictionary:
	if _ui.is_empty():
		_ui = DataRegistry.new().load_file("res://data/ui.json")
	return _ui


func _on_state_changed() -> void:
	state = net_lobby.state
	AppFlow.lobby = state
	refresh()


func _on_match_starting() -> void:
	AppFlow.coach_route = true  # M2 H1b commit 5 (OQ-COACH): a real match from the menu / lobby route
	AppFlow.go(get_tree(), AppFlow.MATCH_SCENE)


func _on_start() -> void:
	net_lobby.start_match()


func _on_back() -> void:
	AppFlow.end_session()
	AppFlow.go(get_tree(), AppFlow.MENU_SCENE)
