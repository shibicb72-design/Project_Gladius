extends "res://tests/test_case.gd"
## M2 Z2 part 2 (OQ-BR-LENGTH): the match length travels lobby -> LobbyState -> MatchRoot.begin -> load_config.
## LobbyState.match_length ("" = no preset), the SaveService "match_length" profile key (data default for anything
## unknown), the host-only Length button in the lobby ActionBar (cycles the data options, saves, broadcasts), and
## a real begin(): offline with a lobby, and host + client on loopback ending with the same stretched phases.
## AppFlow.profile / AppFlow.lobby / AppFlow.session are globals: every test restores them. Profile writes go to
## TMP_PROFILE only (Lobby.save is pointed there before any change; _ready itself never saves).

const _MatchScene := preload("res://scenes/match/match.tscn")
const _Sizes := preload("res://tests/test_front_end_sizes.gd")
const TMP_PROFILE := "user://test_match_length_lobby_profile.json"
const TIMEOUT_S := 5.0


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


func _br_cfg() -> Dictionary:
	return ModeRegistry.merged_config(MatchDirector.MODE_ID, DataRegistry.new().load_file("res://data/modes.json"))


func _data_ids() -> Array:
	var ids: Array = []
	for opt: Dictionary in MatchDirector.match_length_options(_br_cfg()):
		ids.append(str(opt["id"]))
	return ids


## Hosting lobby on an isolated loopback session (as tests/test_br_presentation.gd does), with `profile` as
## AppFlow.profile while _ready runs.
func _host_lobby(profile: Dictionary) -> Lobby:
	var s := NetSession.new()
	s.name = "MatchLengthLobbySession"
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


func _phases_text(m: MatchRoot) -> String:
	return var_to_str(m.director.mode_cfg["zone"]["phases"])


func test_lobby_state_match_length_field() -> void:
	var l := LobbyState.new()
	assert_eq(l.match_length, "", "default: no preset")
	l.setup(2, 3)
	l.add_human(1, "Host")
	assert_true(l.set_match_length("12"), "set before start")
	assert_eq(l.match_length, "12", "stored")
	assert_eq(l.to_dict()["match_length"], "12", "in the wire format")
	assert_eq(LobbyState.from_dict(l.to_dict()).match_length, "12", "survives the round trip")
	assert_eq(LobbyState.from_dict({}).match_length, "", "missing on the wire: no preset")
	assert_true(l.set_match_length("whatever"), "pure: not validated against data here")
	assert_true(l.set_match_length("20"), "set again")
	assert_true(l.start(), "start")
	assert_true(not l.set_match_length("15"), "refused after start")
	assert_eq(l.match_length, "20", "unchanged after a refused set")
	assert_eq(LobbyState.from_dict(l.to_dict()).match_length, "20", "the started payload carries it")


func test_save_service_match_length_key() -> void:
	_remove_tmp()
	assert_eq(SaveService.defaults()["match_length"], "15", "default from data/br.json match_length.default")
	assert_eq(SaveService.match_length_default(), "15", "the default helper")
	assert_eq(SaveService.match_length("20"), "20", "a data id stays")
	assert_eq(SaveService.match_length("99"), "15", "unknown -> data default")
	assert_eq(SaveService.match_length(12), "15", "not a string -> data default")
	assert_eq(SaveService.match_length(null), "15", "missing -> data default")
	var save := SaveService.new(TMP_PROFILE)
	assert_eq(save.load_profile()["match_length"], "15", "no file: default")
	var p := SaveService.defaults()
	p["match_length"] = "12"
	assert_true(save.save_profile(p), "saved")
	assert_eq(save.load_profile()["match_length"], "12", "reloads the saved choice")
	p["match_length"] = "99"
	save.save_profile(p)
	assert_eq(save.load_profile()["match_length"], "15", "an unknown id is saved as the default")
	var f := FileAccess.open(TMP_PROFILE, FileAccess.WRITE)
	f.store_string(JSON.stringify({"gamertag": "T", "match_length": "7"}))
	f.close()
	assert_eq(save.load_profile()["match_length"], "15", "an unknown id in the file loads as the default")
	_remove_tmp()


func test_lobby_length_button_cycles_saves_and_updates_the_profile() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	var lobby := _host_lobby({"gamertag": "Host", "match_length": "20"})
	assert_true(lobby.length_button.visible, "the host sees the Length button")
	assert_eq(lobby.state.match_length, "20", "the profile's length at _ready")
	assert_eq(lobby.length_button.text, "Length: 20 min", "label from data")
	assert_true(not FileAccess.file_exists(TMP_PROFILE), "_ready does not save")
	var bar: Control = lobby.find_child("ActionBar", true, false)
	var order: Array = []
	for c in bar.get_children():
		if c is Button:
			order.append(c)
	assert_eq(order.find(lobby.length_button), order.find(lobby.mode_button) + 1, "Length sits right after Mode")
	# Cycling visits every data option in data order and wraps (20 -> 12 -> 15 -> 20).
	var ids := _data_ids()
	assert_eq(ids, ["12", "15", "20"], "the data options")
	var start := ids.find("20")
	for k in ids.size():
		lobby.length_button.pressed.emit()
		var want: String = ids[(start + 1 + k) % ids.size()]
		assert_eq(lobby.state.match_length, want, "cycle step %d" % k)
		assert_eq(lobby.length_button.text, "Length: %s" % MatchDirector.match_length_label(_br_cfg(), want), "label step %d" % k)
		assert_eq(str(AppFlow.profile.get("match_length", "")), want, "AppFlow.profile step %d" % k)
		assert_eq(SaveService.new(TMP_PROFILE).load_profile()["match_length"], want, "saved step %d" % k)
		assert_eq(lobby.net_lobby.state.match_length, want, "NetLobby's state step %d" % k)
	assert_true(not lobby.set_match_length("99"), "an id not in data is refused")
	assert_eq(lobby.state.match_length, "20", "unchanged after a refused id")
	assert_true(lobby.set_match_length("12"), "set directly")
	assert_eq(lobby.length_button.text, "Length: 12 min", "label 12")
	assert_eq(lobby.state.humans.size(), 1, "re-submitting the host entry adds nobody")
	assert_eq(str(lobby.state.humans[0]["name"]), "Host", "the host's name is unchanged")
	_end_lobby(lobby, old_profile)
	# An unknown saved id gives the data default at _ready.
	lobby = _host_lobby({"gamertag": "Host", "match_length": "99"})
	assert_eq(lobby.state.match_length, "15", "unknown saved id -> data default")
	assert_eq(lobby.length_button.text, "Length: 15 min", "label 15")
	_end_lobby(lobby, old_profile)
	assert_eq(AppFlow.profile, old_profile, "AppFlow.profile restored")


## The six ActionBar buttons (Back, Class, Mode, Length, Bots, Start; Bots since M2 B4) at every phone size and the smallest desktop
## size the UI tests use (tests/test_front_end_sizes.gd): inside the viewport, not narrower than their minimum
## (text not clipped), no overlap, >= 48 dp tall.
func test_action_bar_fits_with_the_length_button() -> void:
	var old_profile: Dictionary = AppFlow.profile
	var prev := _root().size
	var cases: Array = _Sizes.SIZES.duplicate()
	cases.append([Vector2i(1152, 648), 0.0])
	for case: Array in cases:
		var px: Vector2i = case[0]
		var dpi: float = case[1]
		var tag := "%s/%d dpi" % [px, int(dpi)]
		PlatformServices.dpi_override = dpi
		_root().size = px
		var lobby := _host_lobby({"gamertag": "Host"})
		await _frames(4)
		var vp := _root().get_visible_rect()
		var bar: Control = lobby.find_child("ActionBar", true, false)
		var buttons: Array[Button] = []
		for c in bar.get_children():
			if c is Button and (c as Button).is_visible_in_tree():
				buttons.append(c)
		assert_eq(buttons.size(), 6, "Back, Class, Mode, Length, Bots, Start at %s" % tag)  # M2 B4: + Bots
		var min_sum := 0.0
		for b in buttons:
			min_sum += b.get_combined_minimum_size().x
		var mins: Array = []
		for b in buttons:
			mins.append("%s=%.0f/%.0f" % [b.text, b.get_combined_minimum_size().x, b.size.x])
		print("LENGTH_BAR %s vp=%s bar_w=%.1f bar_min_w=%.1f button_min_sum=%.1f rows=%s %s" % [tag, vp.size, bar.size.x,
				bar.get_combined_minimum_size().x, min_sum, _rows(buttons), " ".join(mins)])
		var px_scale := _root().get_screen_transform().get_scale().y
		var dp_scale := PlatformServices.new().get_dp_scale()
		for i in buttons.size():
			var b := buttons[i]
			var r := b.get_global_rect()
			assert_true(vp.grow(0.5).encloses(r), "%s inside the viewport at %s: %s" % [b.text, tag, r])
			assert_true(bar.get_global_rect().grow(0.5).encloses(r), "%s inside the action bar at %s" % [b.text, tag])
			assert_true(b.size.x >= b.get_combined_minimum_size().x - 0.5, "%s not narrower than its text at %s (%.1f < %.1f)" % [b.text, tag, b.size.x, b.get_combined_minimum_size().x])
			assert_true(r.size.y * px_scale / dp_scale >= 48.0 - 0.5, "%s >= 48 dp at %s" % [b.text, tag])
			for j in range(i + 1, buttons.size()):
				assert_true(not r.grow(-0.5).intersects(buttons[j].get_global_rect().grow(-0.5)), "%s and %s do not overlap at %s" % [b.text, buttons[j].text, tag])
		var scroll := lobby.rows_box.get_parent() as ScrollContainer
		assert_true(scroll.get_global_rect().end.y <= bar.get_global_rect().position.y + 0.5, "roster ends above the action bar at %s" % tag)
		assert_true(scroll.size.y > lobby.slot_buttons[0].size.y * 2.0, "roster taller than two rows at %s" % tag)
		_end_lobby(lobby, old_profile)
	PlatformServices.dpi_override = 0.0
	_root().size = prev
	await _frames(1)


## How many distinct rows (global y positions) the buttons occupy.
func _rows(buttons: Array[Button]) -> int:
	var ys := {}
	for b in buttons:
		ys[roundi(b.get_global_rect().position.y)] = true
	return ys.size()


func _offline_match(lobby: LobbyState) -> MatchRoot:
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.lobby_override = lobby
	_root().add_child(m)
	await _tree().physics_frame
	return m


func test_begin_applies_the_lobby_length() -> void:
	var old_session = AppFlow.session
	AppFlow.session = null
	# Today's phases: begin() with no lobby on the fixture map.
	var plain := await _offline_match(null)
	assert_true(plain.begin(), "begin without a lobby")
	var today := _phases_text(plain)
	assert_true(not bool(plain.director.match_length_info["applied"]), "no lobby: no preset")
	var fixture := MatchDirector.new()
	fixture.load_config(plain.map_path)
	assert_eq(today, var_to_str(fixture.mode_cfg["zone"]["phases"]), "no lobby: the map's own phases")
	var nominal := MatchDirector.zone_nominal_s(fixture.mode_cfg)
	plain.queue_free()
	await _frames(1)
	for id: String in ["", "12"]:
		var l := LobbyState.new()
		l.setup(2, 3)
		l.add_human(0, "Host")
		l.set_match_length(id)
		var m := await _offline_match(l)
		assert_true(m.begin(), "begin with lobby length '%s'" % id)
		var info: Dictionary = m.director.match_length_info
		if id == "":
			assert_true(not bool(info["applied"]), "'': not applied")
			assert_eq(_phases_text(m), today, "'': today's phases")
		else:
			var factor := 720.0 / nominal
			assert_true(bool(info["applied"]), "12: applied")
			assert_true(absf(float(info["factor"]) - factor) < 1e-9, "12: factor 720 / %.0f" % nominal)
			var phases: Array = m.director.mode_cfg["zone"]["phases"]
			var base: Array = fixture.mode_cfg["zone"]["phases"]
			assert_eq(phases.size(), base.size(), "12: phase count")
			for i in phases.size():
				assert_true(absf(float(phases[i]["wait_s"]) - float(base[i]["wait_s"]) * factor) < 1e-9, "12: phase %d wait" % i)
				assert_true(absf(float(phases[i]["shrink_s"]) - float(base[i]["shrink_s"]) * factor) < 1e-9, "12: phase %d shrink" % i)
				assert_eq(phases[i]["radius_m"], base[i]["radius_m"], "12: phase %d radius" % i)
			assert_true(absf(m.director.rules.zone_seconds_left() - float(base[0]["wait_s"]) * factor) < 1e-6, "12: the rules start on the stretched first wait")
		m.queue_free()
		await _frames(1)
	fixture.free()
	AppFlow.session = old_session
	AppFlow.lobby = null


func _make_session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_root().add_child(s)
	return s


## As tests/test_net_match.gd _build_match, but the config is NOT preloaded: begin() loads it with the lobby length.
func _build_match(session: NetSession, viewports: Array) -> MatchRoot:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_root().add_child(vp)
	viewports.append(vp)
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.session_override = session
	m.lobby_override = session.lobby.state
	m.seed_override = session.lobby.match_seed
	vp.add_child(m)
	await _tree().physics_frame
	if not m.begin():
		failures.append("match did not begin")
	return m


func test_net_host_length_reaches_the_client_and_both_matches() -> void:
	var host := _make_session("ZLenHost")
	var client := _make_session("ZLenClient")
	var viewports: Array = []
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
		# The lobby UI's path: set the field, then re-submit the host's own entry, which broadcasts the state.
		assert_true(host.lobby.state.set_match_length("12"), "host sets 12")
		host.lobby.submit_local("Host", "hastati")
		ok = await _wait_until(func() -> bool: return client.lobby.state.match_length == "12", TIMEOUT_S)
		assert_true(ok, "the client's LobbyState gets 12 by sync")
	if ok:
		var started := {"host": false, "client": false}
		host.lobby.match_starting.connect(func() -> void: started["host"] = true)
		client.lobby.match_starting.connect(func() -> void: started["client"] = true)
		host.lobby.start_match()
		ok = await _wait_until(func() -> bool: return started["host"] and started["client"], TIMEOUT_S)
		assert_true(ok, "match_starting on both peers")
	if ok:
		assert_eq(client.lobby.state.match_length, "12", "the start payload carries 12")
		var hm := await _build_match(host, viewports)
		var cm := await _build_match(client, viewports)
		assert_true(bool(hm.director.match_length_info["applied"]), "host applied 12")
		assert_true(bool(cm.director.match_length_info["applied"]), "client applied 12")
		assert_eq(_phases_text(cm), _phases_text(hm), "host and client have the same stretched phases")
		assert_true(absf(MatchDirector.zone_nominal_s(hm.director.mode_cfg) - 720.0) <= 1.0 / 60.0, "they close at 720 s")
	for s in [client, host]:
		s.leave()
		s.queue_free()
	for vp in viewports:
		vp.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _frames(2)
