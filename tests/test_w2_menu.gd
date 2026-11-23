extends "res://tests/test_case.gd"
## W2 commit 3: the menu and lobby on the web. Relay detection (PlatformServices.set_relay_info simulates the /lan.json
## answer, also arriving late), can_lan() / uses_relay() rules, the transport choice (WebRTC only on web + relay),
## async web Host / Join with plain messages, Join without an IP (last_ip untouched), the lobby's join URLs, the
## debug-only ?autohost / ?autojoin requests (WebArgs.parse_lan, the menu's autojoin retry, the lobby's autohost Start).
## Sessions run against the in-memory relay of tests/w2_fakes.gd (isolated, fake peer connections). PlatformServices
## simulate_web / relay_info, WebArgs, NetSession.lost_notice and AppFlow are globals: every test restores them.
## Profile writes go to TMP only.

const _Fakes := preload("res://tests/w2_fakes.gd")
const _WebArgs := preload("res://scripts/platform/web_args.gd")
const TMP := "user://test_w2_menu_profile.json"
const URL := "wss://192.168.1.5:8443/signal"
const RELAY_ANSWER := {"lan": true, "proto": 1, "urls": ["https://192.168.1.5:47443/"], "max_peers": 8}


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
	if FileAccess.file_exists(TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


func _restore(old_profile: Dictionary) -> void:
	AppFlow.end_session()
	AppFlow.session = null
	AppFlow.lobby = null
	AppFlow.solo = false
	AppFlow.match_seed = 0
	AppFlow.profile = old_profile
	PlatformServices.simulate_web = false
	PlatformServices.reset_relay_for_tests()
	NetSession.lost_notice = ""
	_WebArgs.reset_for_tests()
	_WebArgs._taken = true  # as after the first menu of the run
	_WebArgs._lan_taken = true
	_remove_tmp()


## An isolated WebRTC-capable session on `relay` (fake sockets and peer connections), added to the tree.
func _fake_session(node_name: String, relay: Object, tag: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	s.relay_url = URL
	s.socket_factory = relay.new_socket
	var f = _Fakes.FakeRtcFactory.new()
	f.tag = tag
	s.rtc_factory = f
	_root().add_child(s)
	return s


func _menu(went: Array) -> MainMenu:
	var menu: MainMenu = load("res://scenes/ui/main_menu.tscn").instantiate()
	menu.save = SaveService.new(TMP)
	menu.go_scene = func(p: String) -> void: went.append(p)
	_root().add_child(menu)
	return menu


## Makes the menu's Host / Join use fake sessions on `relay` (a fresh one after each end_session).
func _use_relay(menu: MainMenu, relay: Object, made: Array) -> void:
	menu.make_session = func() -> NetSession:
		var s := _fake_session("W2MenuSession%d" % made.size(), relay, "m%d" % made.size())
		made.append(s)
		return s


func _free_sessions(made: Array) -> void:
	for s: Variant in made:
		if is_instance_valid(s):
			(s as NetSession).leave()
			(s as NetSession).queue_free()
	await _frames(1)


# ---- detection and can_lan ------------------------------------------------------------------

func test_can_lan_rules() -> void:
	var old_profile: Dictionary = AppFlow.profile
	PlatformServices.reset_relay_for_tests()
	var ps := PlatformServices.new()
	assert_true(ps.can_lan() and not ps.uses_relay(), "desktop: LAN (ENet), no relay")
	PlatformServices.simulate_web = true
	assert_true(not ps.can_lan() and not ps.uses_relay(), "web without a relay answer (the default): no LAN")
	PlatformServices.set_relay_info(RELAY_ANSWER)
	assert_true(ps.can_lan() and ps.uses_relay(), "web with a relay: LAN through the relay")
	assert_eq(PlatformServices.relay_info["urls"], PackedStringArray(RELAY_ANSWER["urls"]), "urls kept")
	PlatformServices.set_relay_info({"lan": true, "proto": 2, "urls": []})
	assert_true(not ps.can_lan(), "another protocol version is not a relay")
	PlatformServices.set_relay_info({"lan": false, "proto": 1})
	assert_true(not ps.can_lan(), "lan false is not a relay")
	PlatformServices.set_relay_info("<html>404</html>")
	assert_true(not ps.can_lan(), "a non-object is not a relay")
	PlatformServices.set_relay_info(RELAY_ANSWER)
	PlatformServices.simulate_web = false
	assert_true(ps.can_lan() and not ps.uses_relay(), "off the web a stale relay answer never selects the relay")
	_restore(old_profile)


func test_parse_relay_answer() -> void:
	assert_true(PlatformServices.parse_relay_answer(JSON.stringify(RELAY_ANSWER)).get("lan") == true, "the relay's body")
	assert_true(PlatformServices.parse_relay_answer("not found").is_empty(), "a 404 text body")
	assert_true(PlatformServices.parse_relay_answer("<!doctype html><html></html>").is_empty(), "an HTML page")
	assert_true(PlatformServices.parse_relay_answer("{\"lan\":true}").is_empty(), "no proto")
	assert_true(PlatformServices.parse_relay_answer("[1,2]").is_empty(), "not an object")


func test_probe_does_nothing_off_the_real_web() -> void:
	var old_profile: Dictionary = AppFlow.profile
	PlatformServices.reset_relay_for_tests()
	PlatformServices.simulate_web = true
	PlatformServices.start_relay_probe(_tree())
	await _frames(1)
	assert_true(_root().get_node_or_null("LanRelayProbe") == null, "no request headless (simulate_web alone)")
	assert_true(PlatformServices.relay_info.is_empty(), "no relay")
	_restore(old_profile)


# ---- menu states ----------------------------------------------------------------------------

func test_menu_on_web_without_relay_keeps_the_w0_note() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	PlatformServices.simulate_web = true
	var menu := _menu([])
	await _frames(1)
	assert_true(menu.host_button.disabled and menu.join_button.disabled, "Host and Join disabled")
	assert_true(menu.lan_note.visible and menu.lan_note.text == MainMenu.LAN_LATER_NOTE, "W0's note")
	assert_true(menu.ip_edit.visible and not menu.ip_edit.editable, "the IP field as in W0")
	menu.free()
	_restore(old_profile)


func test_menu_relay_answer_arriving_later_enables_lan() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	PlatformServices.simulate_web = true
	var menu := _menu([])
	await _frames(1)
	assert_true(menu.host_button.disabled, "disabled before the answer")
	PlatformServices.set_relay_info(RELAY_ANSWER)  # the /lan.json answer arrives
	assert_true(not menu.host_button.disabled and not menu.join_button.disabled, "Host and Join enabled")
	assert_true(not menu.lan_note.visible, "the W0 note is gone")
	assert_true(not menu.ip_edit.visible and not menu.ip_caption.visible, "no IP field on a relay page")
	assert_true(not menu.solo_button.disabled, "Play solo still there")
	PlatformServices.set_relay_info({})
	assert_true(menu.host_button.disabled and menu.lan_note.visible and menu.ip_edit.visible, "back to W0 without it")
	menu.free()
	await _frames(1)
	PlatformServices.set_relay_info(RELAY_ANSWER)  # a freed menu is no longer listening (no error)
	_restore(old_profile)


func test_desktop_menu_unchanged_with_a_stale_relay_answer() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	PlatformServices.set_relay_info(RELAY_ANSWER)
	var menu := _menu([])
	await _frames(1)
	assert_true(not menu.host_button.disabled and not menu.join_button.disabled, "desktop: enabled")
	assert_true(menu.ip_edit.visible and menu.ip_edit.editable and menu.ip_caption.visible, "desktop: the IP field")
	assert_true(not menu.lan_note.visible, "desktop: no note")
	menu.free()
	_restore(old_profile)


func test_lan_error_texts() -> void:
	var host := {"relay_unreachable": "Relay not reachable", "relay_lost": "Relay not reachable",
			"timeout": "Relay not reachable", "bad_relay": "Relay not reachable", "host_exists": "A game is already hosted"}
	for code: String in host:
		assert_eq(MainMenu.lan_error_text(code, false), host[code], "host " + code)
	var join := {"relay_unreachable": "Relay not reachable", "relay_lost": "Relay not reachable",
			"bad_relay": "Relay not reachable", "room_full": "Room full", "no_host": "No game is hosted yet",
			"host_left": "Host left", "connection_failed": "Could not connect", "timeout": "Could not connect"}
	for code: String in join:
		assert_eq(MainMenu.lan_error_text(code, true), join[code], "join " + code)


# ---- transport choice -----------------------------------------------------------------------

## Records the transport at host / join time and fails at once (no network).
class _RecordSession extends NetSession:
	var seen: Array = []

	func host_game(_port: int = -1) -> int:
		seen.append(["host", transport])
		return FAILED

	func join_game(_address: String, _port: int = -1) -> int:
		seen.append(["join", transport])
		return FAILED


func test_transport_stays_enet_unless_web_with_relay() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	var menu := _menu([])
	await _frames(1)
	var rec := _RecordSession.new()
	rec.name = "W2RecordSession"
	rec.isolated = true
	_root().add_child(rec)
	menu.make_session = func() -> NetSession: return rec
	menu.ip_edit.text = "10.0.0.9"
	menu.host_button.pressed.emit()
	menu.join_button.pressed.emit()
	PlatformServices.set_relay_info(RELAY_ANSWER)  # desktop + a relay answer: still ENet
	menu.host_button.pressed.emit()
	PlatformServices.simulate_web = true
	PlatformServices.set_relay_info({})  # web alone: no LAN, no session work at all
	menu.host_button.pressed.emit()
	PlatformServices.set_relay_info(RELAY_ANSWER)  # web + relay: WebRTC
	menu.host_button.pressed.emit()
	menu.join_button.pressed.emit()
	assert_eq(rec.seen, [["host", "enet"], ["join", "enet"], ["host", "enet"], ["host", "webrtc"], ["join", "webrtc"]],
			"transport per press")
	menu.free()
	rec.queue_free()
	_restore(old_profile)


# ---- async web Host -------------------------------------------------------------------------

func test_web_host_opens_the_lobby_only_on_host_ready() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	PlatformServices.simulate_web = true
	PlatformServices.set_relay_info(RELAY_ANSWER)
	var went: Array = []
	var menu := _menu(went)
	await _frames(1)
	var relay = _Fakes.FakeRelay.new()
	var made: Array = []
	_use_relay(menu, relay, made)
	menu.host_button.pressed.emit()
	assert_true(went.is_empty(), "no lobby before the relay answers")
	assert_eq(menu.status_label.text, "Starting...", "waiting")
	assert_true(menu.lan_busy, "busy")
	assert_eq(AppFlow.session.transport, NetSession.TRANSPORT_WEBRTC, "WebRTC")
	var ok: bool = await _wait_until(func() -> bool: return not went.is_empty(), 2.0)
	assert_true(ok, "host_ready came")
	assert_eq(went, [AppFlow.LOBBY_SCENE], "the lobby opens on host_ready")
	assert_true(AppFlow.session.is_host and not menu.lan_busy, "hosting")
	assert_eq(AppFlow.session.join_urls, PackedStringArray(relay.urls), "join URLs from the relay")
	menu.free()
	await _free_sessions(made)
	_restore(old_profile)


func test_web_host_errors_stay_on_the_menu() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	PlatformServices.simulate_web = true
	PlatformServices.set_relay_info(RELAY_ANSWER)
	var went: Array = []
	var menu := _menu(went)
	await _frames(1)
	var made: Array = []
	# Someone else already hosts on this relay.
	var relay = _Fakes.FakeRelay.new()
	var other := _fake_session("W2OtherHost", relay, "o")
	other.transport = NetSession.TRANSPORT_WEBRTC
	other.host_game()
	await _wait_until(func() -> bool: return other.is_host, 2.0)
	_use_relay(menu, relay, made)
	menu.host_button.pressed.emit()
	var ok: bool = await _wait_until(func() -> bool: return not menu.lan_busy, 2.0)
	assert_true(ok, "answered")
	assert_eq(menu.status_label.text, "A game is already hosted", "host_exists")
	assert_true(went.is_empty() and AppFlow.session == null, "stays on the menu, session ended")
	# The relay does not answer the socket.
	var dead = _Fakes.FakeRelay.new()
	dead.reachable = false
	_use_relay(menu, dead, made)
	menu.host_button.pressed.emit()
	ok = await _wait_until(func() -> bool: return not menu.lan_busy, 2.0)
	assert_eq(menu.status_label.text, "Relay not reachable", "relay_unreachable")
	# The socket cannot even start.
	var refused = _Fakes.FakeRelay.new()
	refused.refuse_connect = true
	_use_relay(menu, refused, made)
	menu.host_button.pressed.emit()
	assert_eq(menu.status_label.text, "Relay not reachable", "a non-OK host_game return")
	assert_true(not menu.lan_busy and AppFlow.session == null, "not busy, no session")
	assert_true(went.is_empty(), "never left the menu")
	menu.free()
	other.leave()
	other.queue_free()
	await _free_sessions(made)
	_restore(old_profile)


# ---- web Join -------------------------------------------------------------------------------

func test_web_join_needs_no_ip_and_keeps_last_ip() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	SaveService.new(TMP).save_profile({"gamertag": "Gaius", "last_ip": "10.0.0.7"})
	AppFlow.profile = {}
	AppFlow.session = null
	PlatformServices.simulate_web = true
	PlatformServices.set_relay_info(RELAY_ANSWER)
	var went: Array = []
	var menu := _menu(went)
	await _frames(1)
	var relay = _Fakes.FakeRelay.new()
	var made: Array = []
	_use_relay(menu, relay, made)
	menu.ip_edit.text = ""  # hidden on a relay page; whatever it holds is not used or saved
	menu.join_button.pressed.emit()
	assert_true(menu.status_label.text != "Enter the host IP", "no IP needed")
	assert_eq(menu.status_label.text, "Connecting...", "joining")
	var ok: bool = await _wait_until(func() -> bool: return not menu.lan_busy, 2.0)
	assert_true(ok, "answered")
	assert_eq(menu.status_label.text, "No game is hosted yet", "no_host")
	assert_eq(str(SaveService.new(TMP).load_profile()["last_ip"]), "10.0.0.7", "the saved last_ip is untouched")
	# A host appears: Join goes through once the guest is connected.
	var host := _fake_session("W2JoinHost", relay, "h")
	host.transport = NetSession.TRANSPORT_WEBRTC
	host.host_game()
	await _wait_until(func() -> bool: return host.is_host, 2.0)
	menu.join_button.pressed.emit()
	var guest: NetSession = AppFlow.session
	ok = await _wait_until(func() -> bool: return guest.get_unique_id() == 2, 2.0)
	assert_true(ok, "the guest got its id")
	assert_true(went.is_empty(), "no lobby before connected")
	(guest.multiplayer as SceneMultiplayer).connected_to_server.emit()  # the fake pcs never connect by themselves
	assert_eq(went, [AppFlow.LOBBY_SCENE], "the lobby opens on connected")
	assert_eq(str(SaveService.new(TMP).load_profile()["last_ip"]), "10.0.0.7", "still untouched")
	menu.free()
	host.leave()
	host.queue_free()
	await _free_sessions(made)
	_restore(old_profile)


func test_web_join_room_full_and_handshake_timeout() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	PlatformServices.simulate_web = true
	PlatformServices.set_relay_info(RELAY_ANSWER)
	var menu := _menu([])
	await _frames(1)
	var relay = _Fakes.FakeRelay.new()
	relay.max_peers = 1
	var host := _fake_session("W2FullHost", relay, "h")
	host.transport = NetSession.TRANSPORT_WEBRTC
	host.host_game()
	await _wait_until(func() -> bool: return host.is_host, 2.0)
	var made: Array = []
	_use_relay(menu, relay, made)
	menu.join_button.pressed.emit()
	await _wait_until(func() -> bool: return not menu.lan_busy, 2.0)
	assert_eq(menu.status_label.text, "Room full", "room_full")
	relay.max_peers = 8
	menu.make_session = func() -> NetSession:
		var s := _fake_session("W2SlowGuest", relay, "s")
		s.cfg = s.cfg.duplicate(true)
		s.cfg["connect_timeout_s"] = 0.3  # the fake pcs never connect: the handshake times out
		made.append(s)
		return s
	menu.join_button.pressed.emit()
	var ok: bool = await _wait_until(func() -> bool: return not menu.lan_busy, 3.0)
	assert_true(ok, "timed out")
	assert_eq(menu.status_label.text, "Could not connect", "timeout during the WebRTC handshake")
	menu.free()
	host.leave()
	host.queue_free()
	await _free_sessions(made)
	_restore(old_profile)


func test_host_left_is_shown_on_the_menu() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	var relay = _Fakes.FakeRelay.new()
	var host := _fake_session("W2LeftHost", relay, "h")
	host.transport = NetSession.TRANSPORT_WEBRTC
	host.host_game()
	await _wait_until(func() -> bool: return host.is_host, 2.0)
	var guest := _fake_session("W2LeftGuest", relay, "g")
	guest.transport = NetSession.TRANSPORT_WEBRTC
	AppFlow.session = guest
	guest.join_game("")
	await _wait_until(func() -> bool: return guest.get_unique_id() == 2, 2.0)
	relay.close_host()
	var ok: bool = await _wait_until(func() -> bool: return NetSession.lost_notice != "", 2.0)
	assert_true(ok, "the app's session noted the loss")
	assert_eq(NetSession.lost_notice, "host_left", "host_left")
	AppFlow.end_session()  # what the lobby / match do before going to the menu
	var menu := _menu([])
	await _frames(1)
	assert_eq(menu.status_label.text, "Host left", "shown once on the menu")
	assert_eq(NetSession.lost_notice, "", "taken")
	menu.free()
	var menu2 := _menu([])
	await _frames(1)
	assert_eq(menu2.status_label.text, "", "not shown again")
	menu2.free()
	host.leave()
	host.queue_free()
	await _frames(1)
	_restore(old_profile)


func test_a_session_that_is_not_the_apps_leaves_no_notice() -> void:
	var old_profile: Dictionary = AppFlow.profile
	AppFlow.session = null
	var relay = _Fakes.FakeRelay.new()
	var host := _fake_session("W2NnHost", relay, "h")
	host.transport = NetSession.TRANSPORT_WEBRTC
	host.host_game()
	await _wait_until(func() -> bool: return host.is_host, 2.0)
	var guest := _fake_session("W2NnGuest", relay, "g")
	guest.transport = NetSession.TRANSPORT_WEBRTC
	var lost := [false]
	guest.host_lost.connect(func() -> void: lost[0] = true)
	guest.join_game("")
	await _wait_until(func() -> bool: return guest.get_unique_id() == 2, 2.0)
	relay.close_host()
	await _wait_until(func() -> bool: return lost[0], 2.0)
	assert_true(lost[0], "host_lost fired")
	assert_eq(NetSession.lost_notice, "", "no menu notice for a session that is not AppFlow.session")
	for s: NetSession in [guest, host]:
		s.leave()
		s.queue_free()
	await _frames(1)
	_restore(old_profile)


# ---- lobby ----------------------------------------------------------------------------------

func test_lobby_shows_the_relay_join_urls() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.profile = {"gamertag": "Host"}
	var relay = _Fakes.FakeRelay.new()
	relay.urls = ["https://192.168.1.5:47443/"]
	var s := _fake_session("W2LobbyHost", relay, "h")
	s.transport = NetSession.TRANSPORT_WEBRTC
	s.host_game()
	await _wait_until(func() -> bool: return s.is_host, 2.0)
	AppFlow.session = s
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	lobby.go_scene = func(_p: String) -> void: pass
	_root().add_child(lobby)
	lobby.save = SaveService.new(TMP)
	assert_eq(lobby.ips_label.text, "Players join at https://192.168.1.5:47443/", "the join URL")
	lobby.free()
	var enet := NetSession.new()
	assert_true(Lobby.host_address_text(enet).begins_with("Your IP: "), "ENet host: this device's IPs")
	enet.free()
	_restore(old_profile)


# ---- debug-only smoke hooks -----------------------------------------------------------------

func test_webargs_parse_lan_only_in_debug_web() -> void:
	assert_eq(_WebArgs.parse_lan("?autohost=1&mode=squads", true, true), {"role": "host", "mode": "squads"}, "autohost")
	assert_eq(_WebArgs.parse_lan("?autohost=1&mode=SOLO", true, true), {"role": "host", "mode": "solo"}, "mode case")
	assert_eq(_WebArgs.parse_lan("?autohost=1&mode=duos", true, true), {"role": "host", "mode": ""}, "unknown mode")
	assert_eq(_WebArgs.parse_lan("?autohost=1", true, true), {"role": "host", "mode": ""}, "no mode")
	assert_eq(_WebArgs.parse_lan("?autojoin=1", true, true), {"role": "guest"}, "autojoin")
	assert_eq(_WebArgs.parse_lan("?autojoin=1&autohost=1", true, true).get("role"), "host", "autohost wins")
	assert_true(_WebArgs.parse_lan("?autohost=1&mode=squads", false, true).is_empty(), "release ignores it")
	assert_true(_WebArgs.parse_lan("?autojoin=1", true, false).is_empty(), "off the web ignored")
	assert_true(_WebArgs.parse_lan("?autojoin=0", true, true).is_empty(), "must be 1")
	assert_true(_WebArgs.parse("?autohost=1", true, true).is_empty(), "not an autosolo request")


func test_take_lan_once() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_WebArgs.reset_for_tests()
	_WebArgs.simulate_query = "?autojoin=1"
	_WebArgs.simulate_debug = true
	_WebArgs.simulate_web = true
	assert_eq(_WebArgs.take_lan(), {"role": "guest"}, "first take")
	assert_true(_WebArgs.take_lan().is_empty(), "handed out once")
	_restore(old_profile)


func test_autojoin_retries_until_a_game_is_hosted() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.session = null
	PlatformServices.simulate_web = true
	var went: Array = []
	var menu := _menu(went)
	await _frames(1)
	var relay = _Fakes.FakeRelay.new()
	var made: Array = []
	_use_relay(menu, relay, made)
	menu._lan_request = {"role": "guest"}
	await _frames(2)
	assert_true(made.is_empty(), "nothing before LAN is available")
	PlatformServices.set_relay_info(RELAY_ANSWER)  # the relay answer arrives: autojoin presses Join
	var ok: bool = await _wait_until(func() -> bool: return menu.status_label.text == "No game is hosted yet", 2.0)
	assert_true(ok, "first try: no host yet")
	var host := _fake_session("W2AutoHost", relay, "h")
	host.transport = NetSession.TRANSPORT_WEBRTC
	host.host_game()
	ok = await _wait_until(func() -> bool:
			return AppFlow.session != null and is_instance_valid(AppFlow.session) and AppFlow.session.get_unique_id() == 2, 4.0)
	assert_true(ok, "a retry joined once the host was up")
	assert_true(made.size() >= 2, "retried with a fresh session (%d)" % made.size())
	(AppFlow.session.multiplayer as SceneMultiplayer).connected_to_server.emit()
	assert_eq(went, [AppFlow.LOBBY_SCENE], "lobby")
	menu.free()
	host.leave()
	host.queue_free()
	await _free_sessions(made)
	_restore(old_profile)


func test_autohost_menu_hosts_and_lobby_starts_once_a_guest_is_in() -> void:
	var old_profile: Dictionary = AppFlow.profile
	_remove_tmp()
	AppFlow.profile = {"gamertag": "Host"}
	AppFlow.session = null
	PlatformServices.simulate_web = true
	PlatformServices.set_relay_info(RELAY_ANSWER)
	var went: Array = []
	var menu := _menu(went)
	await _frames(1)
	var relay = _Fakes.FakeRelay.new()
	var made: Array = []
	_use_relay(menu, relay, made)
	menu._lan_request = {"role": "host", "mode": "squads"}
	menu.apply_lan_availability()
	var ok: bool = await _wait_until(func() -> bool: return not went.is_empty(), 2.0)
	assert_true(ok, "autohost pressed Host and host_ready came")
	assert_eq(_WebArgs.pending_lan.get("mode"), "squads", "the request waits for the lobby")
	menu.free()
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	var lobby_went: Array = []
	lobby.go_scene = func(p: String) -> void: lobby_went.append(p)
	_root().add_child(lobby)
	lobby.save = SaveService.new(TMP)
	assert_true(_WebArgs.pending_lan.is_empty(), "the lobby took it")
	assert_eq(lobby.state.team_mode, "squads", "the requested mode")
	await _tree().create_timer(0.6).timeout
	assert_true(lobby_went.is_empty(), "no Start while the host is alone")
	lobby.net_lobby._apply(2, "Guest", "hastati")  # a guest's entry arrives
	ok = await _wait_until(func() -> bool: return not lobby_went.is_empty(), 4.0)
	assert_true(ok, "Start pressed")
	assert_eq(lobby_went, [AppFlow.MATCH_SCENE], "the match starts")
	lobby.free()
	await _free_sessions(made)
	_restore(old_profile)
