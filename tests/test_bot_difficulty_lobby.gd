extends "res://tests/test_case.gd"
## M2 B4 phase 2 (OQ-BOT-DIFFICULTY): the bot difficulty travels lobby -> LobbyState -> MatchRoot.begin -> the brains.
## LobbyState.bot_difficulty (default "normal", BOT_DIFFICULTIES mirrors data/bots.json difficulty.order), the
## SaveService "bot_difficulty" profile key (data default for anything unknown), the host-only Bots button in the lobby
## ActionBar (cycles the data levels, saves, broadcasts), the wire to a client, and a real begin() with a lobby.
## AppFlow.profile / AppFlow.lobby / AppFlow.session are globals: every test restores them. Profile writes go to
## TMP_PROFILE only (Lobby.save is pointed there before any change; _ready itself never saves).

const _MatchScene := preload("res://scenes/match/match.tscn")
const TMP_PROFILE := "user://test_bot_difficulty_lobby_profile.json"
const TIMEOUT_S := 5.0
const IDS: Array[String] = ["easy", "normal", "hard", "very_hard"]


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _root() -> Window:
	return _tree().root


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > int(timeout_s * 1000.0):
			return false
		await _tree().process_frame
	return true


func _remove_tmp() -> void:
	if FileAccess.file_exists(TMP_PROFILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PROFILE))


## Hosting lobby on an isolated loopback session (as tests/test_match_length_lobby.gd does), with `profile` as
## AppFlow.profile while _ready runs.
func _host_lobby(profile: Dictionary) -> Lobby:
	var s := NetSession.new()
	s.name = "BotDifficultyLobbySession"
	s.isolated = true
	_root().add_child(s)
	AppFlow.session = s
	s.host_game()
	AppFlow.profile = profile
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	_root().add_child(lobby)
	lobby.save = SaveService.new(TMP_PROFILE)
	return lobby


func _end_lobby(lobby: Lobby, old_profile: Dictionary) -> void:
	lobby.free()
	AppFlow.end_session()
	AppFlow.lobby = null
	AppFlow.profile = old_profile
	_remove_tmp()


## The four values a brain plays with now.
static func _effective(brain: BotBrain) -> Dictionary:
	return {"accuracy": float(brain.profile["accuracy"]), "reaction_time_s": float(brain.profile["reaction_time_s"]),
			"settle_s": float(brain.cfg["fight"]["settle_s"]), "settle_floor_frac": float(brain.cfg["fight"]["settle_floor_frac"])}


static func _level_values(id: String) -> Dictionary:
	var lv := MatchRoot.bot_difficulty_level(id)
	return {"accuracy": float(lv["accuracy"]), "reaction_time_s": float(lv["reaction_time_s"]),
			"settle_s": float(lv["settle_s"]), "settle_floor_frac": float(lv["settle_floor_frac"])}


func test_lobby_state_mirrors_the_data_table() -> void:
	assert_eq(LobbyState.BOT_DIFFICULTIES, MatchRoot.bot_difficulty_ids(), "LobbyState's ids = data/bots.json difficulty.order")
	assert_eq(LobbyState.new().bot_difficulty, MatchRoot.bot_difficulty_default(), "the default field = the data default")
	assert_eq(LobbyState.new().bot_difficulty, "normal", "normal by default")


func test_lobby_state_bot_difficulty_field() -> void:
	var l := LobbyState.new()
	l.setup(2, 3)
	l.add_human(1, "Host")
	for id in IDS:
		assert_true(l.set_bot_difficulty(id), "accepts " + id)
		assert_eq(l.bot_difficulty, id, "stored " + id)
		assert_eq(l.to_dict()["bot_difficulty"], id, "in the wire format: " + id)
		assert_eq(LobbyState.from_dict(l.to_dict()).bot_difficulty, id, "survives the round trip: " + id)
	assert_true(l.set_bot_difficulty("hard"), "set hard")
	for bad in ["nightmare", "", "Hard", "very hard"]:
		assert_true(not l.set_bot_difficulty(bad), "refuses unknown '%s'" % bad)
		assert_eq(l.bot_difficulty, "hard", "unchanged after refusing '%s'" % bad)
	assert_eq(LobbyState.from_dict({}).bot_difficulty, "normal", "missing key (older host): normal")
	assert_eq(LobbyState.from_dict({"bot_difficulty": "nightmare"}).bot_difficulty, "normal", "unknown string: normal")
	for bad: Variant in [2, null, true, ["hard"], {"hard": 1}, 0.5]:
		assert_eq(LobbyState.from_dict({"bot_difficulty": bad}).bot_difficulty, "normal", "non-string %s: normal" % str(bad))
	assert_true(l.start(), "start")
	assert_true(not l.set_bot_difficulty("easy"), "refused after start")
	assert_eq(l.bot_difficulty, "hard", "unchanged after a refused set")
	assert_eq(LobbyState.from_dict(l.to_dict()).bot_difficulty, "hard", "the started payload carries it")


func test_save_service_bot_difficulty_key() -> void:
	_remove_tmp()
	assert_eq(SaveService.defaults()["bot_difficulty"], "normal", "default from data/bots.json difficulty.default")
	assert_eq(SaveService.bot_difficulty_default(), "normal", "the default helper")
	for id in IDS:
		assert_eq(SaveService.bot_difficulty(id), id, "a data id stays: " + id)
	for bad: Variant in ["nightmare", "", "Hard", null, 2, true, ["hard"]]:
		assert_eq(SaveService.bot_difficulty(bad), "normal", "falls back to normal: %s" % str(bad))
	var save := SaveService.new(TMP_PROFILE)
	assert_eq(save.load_profile()["bot_difficulty"], "normal", "no file: default")
	var p := SaveService.defaults()
	p["bot_difficulty"] = "hard"
	assert_true(save.save_profile(p), "saved")
	assert_eq(save.load_profile()["bot_difficulty"], "hard", "reloads the saved choice")
	assert_eq(JSON.parse_string(FileAccess.get_file_as_string(TMP_PROFILE))["bot_difficulty"], "hard", "written to the file")
	p["bot_difficulty"] = "nightmare"
	save.save_profile(p)
	assert_eq(save.load_profile()["bot_difficulty"], "normal", "an unknown id is saved as the default")
	var f := FileAccess.open(TMP_PROFILE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"gamertag": "T", "bot_difficulty": 3}))
	f.close()
	assert_eq(save.load_profile()["bot_difficulty"], "normal", "a bad value in the file loads as the default")
	f = FileAccess.open(TMP_PROFILE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "gamertag": "T", "match_length": "20"}))
	f.close()
	var old := save.load_profile()
	assert_eq(old["bot_difficulty"], "normal", "an old profile without the key loads as normal")
	assert_eq(old["match_length"], "20", "and keeps its other keys")
	_remove_tmp()


func test_lobby_bots_button_cycles_saves_and_updates_the_profile() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	var lobby := _host_lobby({"gamertag": "Host"})
	assert_true(lobby.bot_button.visible, "the host sees the Bots button")
	assert_eq(lobby.state.bot_difficulty, "normal", "normal at _ready without a saved choice")
	assert_eq(lobby.bot_button.text, "Bots: Normal", "label from data")
	assert_true(not FileAccess.file_exists(TMP_PROFILE), "_ready does not save")
	var bar: Control = lobby.find_child("ActionBar", true, false)
	var order: Array = []
	for c in bar.get_children():
		if c is Button:
			order.append(c)
	assert_eq(order.find(lobby.bot_button), order.find(lobby.length_button) + 1, "Bots sits right after Length")
	assert_eq(order.find(lobby.start_button), order.find(lobby.bot_button) + 1, "Start stays last")
	# Cycling visits every level in data order and wraps (normal -> hard -> very_hard -> easy -> normal).
	var start := IDS.find("normal")
	for k in IDS.size():
		lobby.bot_button.pressed.emit()
		var want: String = IDS[(start + 1 + k) % IDS.size()]
		assert_eq(lobby.state.bot_difficulty, want, "cycle step %d" % k)
		assert_eq(lobby.bot_button.text, "Bots: %s" % MatchRoot.bot_difficulty_label(want), "label step %d" % k)
		assert_eq(str(AppFlow.profile.get("bot_difficulty", "")), want, "AppFlow.profile step %d" % k)
		assert_eq(SaveService.new(TMP_PROFILE).load_profile()["bot_difficulty"], want, "saved step %d" % k)
		assert_eq(lobby.net_lobby.state.bot_difficulty, want, "NetLobby's state step %d" % k)
	assert_true(not lobby.set_bot_difficulty("nightmare"), "an id not in data is refused")
	assert_eq(lobby.state.bot_difficulty, "normal", "unchanged after a refused id")
	assert_true(lobby.set_bot_difficulty("very_hard"), "set directly")
	assert_eq(lobby.bot_button.text, "Bots: Very hard", "label Very hard")
	assert_eq(lobby.state.humans.size(), 1, "re-submitting the host entry adds nobody")
	assert_eq(str(lobby.state.humans[0]["name"]), "Host", "the host's name is unchanged")
	# The length still works beside it (the shared resend helper).
	assert_true(lobby.set_match_length("12"), "length still settable")
	assert_eq(lobby.state.bot_difficulty, "very_hard", "a length change keeps the bot difficulty")
	assert_eq(SaveService.new(TMP_PROFILE).load_profile()["bot_difficulty"], "very_hard", "and its saved value")
	# A client cannot set it (the button is host only); the status line shows the host's choice.
	lobby.is_host = false
	assert_true(not lobby.set_bot_difficulty("easy"), "a client cannot set it")
	lobby.cycle_bot_difficulty()
	assert_eq(lobby.state.bot_difficulty, "very_hard", "a client's cycle changes nothing")
	lobby.refresh()
	assert_true(lobby.status_label.text.contains("Bots: Very hard."), "the client status line shows the level: '%s'" % lobby.status_label.text)
	lobby.is_host = true
	# Refused after the start.
	assert_true(lobby.net_lobby.state.start(), "start")
	assert_true(not lobby.set_bot_difficulty("easy"), "refused after the start")
	lobby.cycle_bot_difficulty()
	assert_eq(lobby.state.bot_difficulty, "very_hard", "cycling after the start changes nothing")
	_end_lobby(lobby, old_profile)
	# A host whose profile says hard opens the lobby at Hard; an unknown saved id gives normal.
	lobby = _host_lobby({"gamertag": "Host", "bot_difficulty": "hard"})
	assert_eq(lobby.state.bot_difficulty, "hard", "the profile's hard at _ready")
	assert_eq(lobby.bot_button.text, "Bots: Hard", "label Hard")
	assert_true(not FileAccess.file_exists(TMP_PROFILE), "the initial apply does not save")
	_end_lobby(lobby, old_profile)
	lobby = _host_lobby({"gamertag": "Host", "bot_difficulty": "nightmare"})
	assert_eq(lobby.state.bot_difficulty, "normal", "unknown saved id -> normal")
	assert_eq(lobby.bot_button.text, "Bots: Normal", "label Normal")
	_end_lobby(lobby, old_profile)
	assert_eq(AppFlow.profile, old_profile, "AppFlow.profile restored")


func _offline_match(lobby: LobbyState) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.lobby_override = lobby
	_root().add_child(m)
	await _tree().physics_frame
	return m


func test_begin_applies_the_lobby_bot_difficulty() -> void:
	var old_session = AppFlow.session
	AppFlow.session = null
	var tiro := {"accuracy": 0.35, "reaction_time_s": 0.8, "settle_s": 1.5, "settle_floor_frac": 0.15}
	assert_eq(_level_values("normal"), tiro, "normal = tiro 0.35 / 0.8, settle 1.5 / 0.15")
	for id: String in ["hard", "normal", "bogus"]:
		var l := LobbyState.new()
		l.setup(2, 3)
		l.add_human(0, "Host")
		if id != "bogus":
			assert_true(l.set_bot_difficulty(id), "set " + id)
		else:
			l.bot_difficulty = "bogus"  # cannot be set through the setter; plays as normal
		var m := await _offline_match(l)
		assert_true(m.begin(), "begin with lobby difficulty '%s'" % id)
		assert_true(m.roster != null, "%s: the lobby branch (a roster)" % id)
		assert_true(m.bots.size() > 0, "%s: the match filled bots" % id)
		for b in m.bots:
			b.get_node("Brain").set_physics_process(false)
		var want: Dictionary = _level_values("hard") if id == "hard" else tiro
		var ok := true
		var bad := ""
		for b in m.bots:
			var got := _effective(b.get_node("Brain"))
			if got != want:
				ok = false
				bad = str(got)
		assert_true(ok, "%s: every bot brain plays %s (%s)" % [id, want, bad])
		m.queue_free()
		await _frames(1)
	AppFlow.session = old_session
	AppFlow.lobby = null


func _make_session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_root().add_child(s)
	return s


## The wire: the host's choice reaches a client's LobbyState through the lobby UI's resend path (no new RPC).
func test_net_host_bot_difficulty_reaches_the_client() -> void:
	var host := _make_session("BDiffHost")
	var client := _make_session("BDiffClient")
	host.host_game()
	host.lobby.host_open(2, 3, "Host")
	client.join_game("127.0.0.1")
	var ok := await _wait_until(func() -> bool: return client.is_connected_to_host(), TIMEOUT_S)
	assert_true(ok, "client connected")
	if ok:
		client.lobby.submit_local("Cli", "hastati")
		ok = await _wait_until(func() -> bool: return host.lobby.state.humans.size() == 2, TIMEOUT_S)
		assert_true(ok, "client in the lobby")
	if ok:
		assert_eq(client.lobby.state.bot_difficulty, "normal", "the client starts at normal")
		assert_true(host.lobby.state.set_bot_difficulty("hard"), "host sets hard")
		host.lobby.submit_local("Host", "hastati")
		ok = await _wait_until(func() -> bool: return client.lobby.state.bot_difficulty == "hard", TIMEOUT_S)
		assert_true(ok, "the client's LobbyState gets hard by sync")
	for s in [client, host]:
		s.leave()
		s.queue_free()
	AppFlow.lobby = null
	await _frames(2)
