extends "res://tests/test_case.gd"
## W0 commit 1: Play solo without a network (brief item 1, binding fixes 1, 2, 9, 10). The main menu's Play solo sets
## AppFlow.solo and opens the lobby; the lobby goes offline (NetSession.start_offline: an OfflineMultiplayerPeer, never
## an ENet peer) and acts as host locally; Start begins the match without an RPC; MatchRoot plays it offline
## (networked_match false, no bridge, the director authoritative, the pause menu pauses the tree). In a web build Host
## and Join are disabled with a note (PlatformServices.simulate_web fakes the feature tag). AppFlow.session / lobby /
## profile / solo and PlatformServices.simulate_web are globals: every test restores them. Profile writes go to TMP only.

const _MatchScene := preload("res://scenes/match/match.tscn")
const TMP := "user://test_w0_solo_profile.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _root() -> Window:
	return _tree().root


func _frames(n: int) -> void:
	for i in n:
		await _tree().process_frame


func _remove_tmp() -> void:
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


## A session whose host and join fail at once and whose leave leaves the shared multiplayer alone (as test_ui.gd).
class _FailSession extends NetSession:
	func host_game(_port: int = -1) -> int:
		return FAILED

	func join_game(_address: String, _port: int = -1) -> int:
		return FAILED

	func leave() -> void:
		pass


## Records every engine and script error while installed (the RPC guard below).
class _ErrorSpy extends Logger:
	var errors: Array[String] = []

	func _log_error(function: String, _file: String, _line: int, code: String, rationale: String, _editor_notify: bool,
			_error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		errors.append("%s (%s)" % [rationale if rationale != "" else code, function])


func _menu() -> MainMenu:
	var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	menu.save = SaveService.new(TMP)
	_root().add_child(menu)
	return menu


## An isolated session (its own SceneMultiplayer, so the shared one is never touched) that AppFlow.ensure_session returns.
func _isolated_session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_root().add_child(s)
	AppFlow.session = s
	return s


func _restore(old_profile: Dictionary) -> void:
	AppFlow.end_session()
	AppFlow.session = null
	AppFlow.lobby = null
	AppFlow.solo = false
	AppFlow.profile = old_profile
	PlatformServices.simulate_web = false
	_remove_tmp()


func test_play_solo_is_the_first_primary_button_and_host_is_normal() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	var menu := _menu()
	await _frames(3)
	assert_true(menu.solo_button != null, "the menu has a Play solo button")
	assert_eq(menu.solo_button.text, "Play solo", "its label")
	assert_true(String(menu.solo_button.theme_type_variation).begins_with("Primary"),
			"Play solo is the crimson primary: %s" % menu.solo_button.theme_type_variation)
	assert_true(not String(menu.host_button.theme_type_variation).begins_with("Primary"),
			"Host is a normal button now: %s" % menu.host_button.theme_type_variation)
	var buttons: Array = []
	for c in menu.solo_button.get_parent().get_children():
		if c is Button:
			buttons.append(c)
	assert_eq(buttons.find(menu.solo_button), 0, "Play solo is the card's first button")
	assert_eq(buttons.find(menu.host_button), 1, "Host follows it")
	var solo_h := menu.solo_button.get_combined_minimum_size().y
	var host_h := menu.host_button.get_combined_minimum_size().y
	assert_true(solo_h > host_h, "Play solo is taller than Host (%.1f > %.1f)" % [solo_h, host_h])
	assert_true(not menu.lan_note.visible, "off the web: no LAN note")
	assert_true(not menu.host_button.disabled and not menu.join_button.disabled, "off the web: Host and Join enabled")
	menu.free()
	_restore(old_profile)


func test_play_solo_sets_the_flag_and_opens_the_lobby() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	var menu := _menu()
	var went: Array = []
	menu.go_scene = func(p: String) -> void: went.append(p)
	await _frames(1)
	var stale := _FailSession.new()  # a leftover LAN session must not carry into solo
	stale.name = "W0StaleSession"
	_root().add_child(stale)
	AppFlow.session = stale
	AppFlow.solo = false
	menu.solo_button.pressed.emit()
	assert_true(AppFlow.solo, "Play solo sets AppFlow.solo")
	assert_eq(went, [AppFlow.LOBBY_SCENE], "Play solo opens the lobby screen")
	assert_true(AppFlow.session == null, "the stale session was ended")
	menu.free()
	await _frames(1)
	_restore(old_profile)


func test_solo_flag_cleared_by_end_session_host_and_join() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.solo = true
	AppFlow.end_session()
	assert_true(not AppFlow.solo, "end_session clears the flag")
	var menu := _menu()
	await _frames(1)
	AppFlow.solo = true
	AppFlow.session = null
	var fs := _FailSession.new()
	fs.name = "W0FailHost"
	_root().add_child(fs)
	AppFlow.session = fs
	menu.host_button.pressed.emit()
	assert_true(not AppFlow.solo, "Host clears the flag")
	AppFlow.solo = true
	menu.ip_edit.text = ""  # returns early ("Enter the host IP"): the flag is cleared before any session work
	menu.join_button.pressed.emit()
	assert_true(not AppFlow.solo, "Join clears the flag")
	assert_eq(menu.status_label.text, "Enter the host IP", "Join's own early return")
	# On the web Host / Join return at once; they still clear the flag.
	PlatformServices.simulate_web = true
	AppFlow.solo = true
	menu.host_button.pressed.emit()
	assert_true(not AppFlow.solo, "Host on the web clears the flag")
	AppFlow.solo = true
	menu.join_button.pressed.emit()
	assert_true(not AppFlow.solo, "Join on the web clears the flag")
	menu.free()
	await _frames(1)
	for c in _root().get_children():
		if c is _FailSession:
			c.queue_free()
	_restore(old_profile)


func test_web_disables_host_and_join_with_a_note() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	PlatformServices.simulate_web = true
	assert_true(PlatformServices.new().is_web(), "the simulated web flag reads as web")
	assert_true(not PlatformServices.new().can_lan(), "no LAN on the web")
	var menu := _menu()
	await _frames(1)
	assert_true(menu.host_button.disabled, "Host disabled on the web")
	assert_true(menu.join_button.disabled, "Join disabled on the web")
	assert_true(not menu.ip_edit.editable, "the host IP field is read-only on the web")
	assert_true(menu.lan_note.visible, "the note shows")
	assert_eq(menu.lan_note.text, "LAN in the browser comes later", "the note's text")
	assert_true(not menu.solo_button.disabled, "Play solo stays enabled")
	# A press that reaches the handler anyway (disabled buttons can still be emitted) does not fail or open a session.
	menu.host_button.pressed.emit()
	assert_true(AppFlow.session == null, "Host made no session on the web")
	assert_eq(menu.status_label.text, "LAN in the browser comes later", "Host shows the note, not an error")
	menu.ip_edit.text = "192.168.1.9"
	menu.join_button.pressed.emit()
	assert_true(AppFlow.session == null, "Join made no session on the web")
	assert_true(not menu.status_label.text.begins_with("Could not"), "no failure text: '%s'" % menu.status_label.text)
	PlatformServices.simulate_web = false
	menu.apply_lan_availability()
	assert_true(not menu.host_button.disabled and not menu.join_button.disabled, "off the web again: enabled")
	assert_true(not menu.lan_note.visible, "and the note hides")
	menu.free()
	_restore(old_profile)


## The solo lobby on an isolated session: local host, every host control, no ENet peer, Start without an RPC, then a
## real begin() from the started lobby: offline, no bridge, bots, the lobby's options, the pause menu pauses the tree.
func test_solo_lobby_hosts_locally_and_starts_an_offline_match() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	var s := _isolated_session("W0SoloSession")
	AppFlow.solo = true
	AppFlow.profile = {"gamertag": "Solus"}
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	var went: Array = []
	lobby.go_scene = func(p: String) -> void: went.append(p)
	_root().add_child(lobby)
	lobby.save = SaveService.new(TMP)
	assert_true(s.solo and s.lobby.solo, "the session and its NetLobby are solo")
	assert_true(not s.has_enet_peer(), "no ENet peer after the lobby opened")
	assert_true(s.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "an OfflineMultiplayerPeer: %s" % s.multiplayer.multiplayer_peer)
	assert_true(not s.is_host, "is_host still means an ENet server")
	assert_true(lobby.solo and lobby.is_host, "the lobby acts as host locally")
	assert_true(s.lobby.is_host(), "NetLobby is host in solo")
	for b: Button in [lobby.mode_button, lobby.length_button, lobby.bot_button, lobby.start_button]:
		assert_true(b.visible, "host control shown in solo: %s" % b.text)
	assert_true(not lobby.status_label.visible, "no client status line")
	assert_eq(lobby.ips_label.text, "Solo, offline", "no IPs in solo")
	assert_eq(lobby.state.humans.size(), 1, "one human: the player")
	assert_eq(int(lobby.state.humans[0]["peer_id"]), 1, "the player's entry is id 1 (as a host)")
	assert_eq(str(lobby.state.humans[0]["name"]), "Solus", "the gamertag")
	assert_true(lobby.set_team_mode("squads"), "team mode settable in solo")
	assert_true(lobby.set_match_length("12"), "match length settable in solo")
	assert_true(lobby.set_bot_difficulty("hard"), "bot difficulty settable in solo")
	assert_eq(lobby.state.humans.size(), 1, "the resends added nobody")
	var starting := [0]
	s.lobby.match_starting.connect(func() -> void: starting[0] += 1)
	lobby.start_button.pressed.emit()
	assert_eq(starting[0], 1, "Start fired match_starting locally")
	assert_eq(went, [AppFlow.MATCH_SCENE], "the lobby goes to the match scene")
	assert_true(AppFlow.lobby != null and AppFlow.lobby.started, "AppFlow.lobby is the started state")
	assert_eq(AppFlow.lobby.team_mode, "squads", "started with the chosen team mode")
	assert_eq(AppFlow.lobby.match_length, "12", "started with the chosen length")
	assert_eq(AppFlow.lobby.bot_difficulty, "hard", "started with the chosen bot difficulty")
	assert_true(AppFlow.match_seed == s.lobby.match_seed, "the seed reached AppFlow")
	assert_true(not s.has_enet_peer(), "still no ENet peer after Start")
	lobby.free()
	# The match, as the match scene would build it from AppFlow (session and lobby injected the same way).
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	m.session_override = s
	m.lobby_override = AppFlow.lobby
	var back: Array = []
	m.go_scene = func(p: String) -> void: back.append(p)
	_root().add_child(m)
	await _tree().physics_frame
	assert_true(m.begin(), "begin")
	assert_true(not m.networked_match, "solo: networked_match is false")
	assert_true(m.director.authoritative, "solo: the director is authoritative")
	assert_true(m.roster != null, "the lobby branch (a roster)")
	assert_true(m.roster.bridge == null, "solo: no NetMatchBridge wired")
	assert_true(m.local_player != null and is_instance_valid(m.local_player), "the local player spawned")
	assert_true(m.bots.size() > 0, "bots spawned (%d)" % m.bots.size())
	assert_eq(str(m.director.mode_cfg["teams"]["mode"]["value"]), "squads", "the lobby's team mode applied")
	assert_true(bool(m.director.match_length_info["applied"]), "the lobby's match length applied")
	var hard := MatchRoot.bot_difficulty_level("hard")
	var all_hard := true
	for b in m.bots:
		var brain: BotBrain = b.get_node_or_null("Brain")
		if brain == null or not is_equal_approx(float(brain.profile["accuracy"]), float(hard["accuracy"])):
			all_hard = false
	assert_true(all_hard, "every bot brain plays the lobby's hard difficulty")
	assert_true(not s.has_enet_peer(), "no ENet peer during the match")
	assert_true(not m.local_player.in_lan_session(), "the pawn is not in a LAN session")
	# Pause in solo pauses the tree, and resume unpauses it.
	m.pause_menu.open()
	assert_true(m.menu_open, "the menu is open")
	assert_true(_tree().paused, "solo: the pause menu pauses the tree")
	m.pause_menu.close()
	assert_true(not _tree().paused, "closing the menu unpauses")
	# Quit to the menu: no peer to touch; ending the session clears the flag.
	m.quit_to_menu()
	assert_eq(back, [AppFlow.MENU_SCENE], "quit goes to the menu")
	assert_true(not _tree().paused, "not paused after quit")
	m.queue_free()
	await _frames(2)
	_restore(old_profile)
	assert_true(not AppFlow.solo, "the flag is cleared after the session ends")


## Either solo marker alone makes MatchRoot offline although the session's OfflineMultiplayerPeer reports id 1 (which
## a peer test would call networked): AppFlow.solo (what the match scene reads), or the session's own solo flag.
## Without either, the rule is unchanged: tests/test_h1c_cover_button.gd keeps the Host-with-no-client case networked.
func test_match_root_is_offline_for_either_solo_marker() -> void:
	var s := _isolated_session("W0RuleSession")
	s.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	assert_eq(s.get_unique_id(), 1, "the offline peer reports id 1")
	s.lobby.host_open(2, 3, "Host")
	assert_true(s.lobby.state.start(), "lobby started")
	for marker: String in ["AppFlow.solo", "session.solo"]:
		AppFlow.solo = marker == "AppFlow.solo"
		s.solo = marker == "session.solo"
		var m: MatchRoot = _MatchScene.instantiate()
		m.auto_start = false
		m.bake_navmesh = false
		m.fill_bots = false
		m.seed_override = 4242
		m.session_override = s
		m.lobby_override = s.lobby.state
		_root().add_child(m)
		await _tree().physics_frame
		assert_true(m.begin(), "begin (%s)" % marker)
		assert_true(not m.networked_match, "%s: networked_match false" % marker)
		assert_true(m.roster != null and m.roster.bridge == null, "%s: the lobby branch with no bridge" % marker)
		assert_true(m.director.authoritative, "%s: authoritative" % marker)
		m.queue_free()
		await _frames(2)
	AppFlow.solo = false
	s.solo = false
	s.leave()
	s.queue_free()
	AppFlow.session = null
	AppFlow.lobby = null
	await _frames(1)


## NetLobby in solo starts without the _start_match RPC: with no multiplayer peer at all an RPC would log an engine
## error ("no multiplayer peer is active"); the solo start logs none and still emits match_starting.
func test_solo_net_lobby_start_sends_no_rpc() -> void:
	var s := _isolated_session("W0RpcSession")
	s.start_offline()
	s.lobby.host_open(2, 3, "Host")
	s.multiplayer.multiplayer_peer = null  # any RPC from here on fails loudly
	var starting := [0]
	s.lobby.match_starting.connect(func() -> void: starting[0] += 1)
	var spy := _ErrorSpy.new()
	OS.add_logger(spy)
	assert_true(s.lobby.host_set_team_mode("squads", 6, 3), "team mode change (no broadcast RPC)")
	assert_true(s.lobby.start_match(), "start_match in solo")
	OS.remove_logger(spy)
	assert_true(spy.errors.is_empty(), "no RPC attempted (no engine errors): %s" % [spy.errors])
	assert_eq(starting[0], 1, "match_starting fired locally")
	assert_true(AppFlow.lobby != null and AppFlow.lobby.started, "the started state reached AppFlow")
	assert_true(not s.has_enet_peer(), "no ENet peer")
	s.queue_free()
	AppFlow.session = null
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _frames(1)
