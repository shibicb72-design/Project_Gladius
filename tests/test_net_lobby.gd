extends "res://tests/test_case.gd"
## NetLobby over two isolated NetSessions on loopback.


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _wait_until(cond: Callable, timeout_s: float) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > int(timeout_s * 1000.0):
			return false
		await _tree().process_frame
	return true


func _make_session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_tree().root.add_child(s)
	return s


## Returns {host, client}; the client has registered with the host.
func _connect_pair(tag: String) -> Dictionary:
	var host := _make_session("LHost" + tag)
	var client := _make_session("LClient" + tag)
	var timeout := float(host.cfg["connect_timeout_s"])
	host.host_game()
	host.lobby.host_open(2, 3, "Host")
	client.join_game("127.0.0.1")
	await _wait_until(func() -> bool: return client.is_connected_to_host(), timeout)
	client.lobby.submit_local("Cli", "hastati")
	await _wait_until(func() -> bool: return client.lobby.state.humans.size() == 2, timeout)
	return {"host": host, "client": client}


func _teardown(host: NetSession, client: NetSession) -> void:
	client.leave()
	host.leave()
	host.queue_free()
	client.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _tree().process_frame


func test_lobby_client_registers_with_own_peer_id() -> void:
	var p: Dictionary = await _connect_pair("1")
	var host: NetSession = p["host"]
	var client: NetSession = p["client"]
	var cid := client.get_unique_id()
	assert_true(cid > 1, "client has an assigned id")
	assert_eq(host.lobby.state.find_human(1), 0, "host entry uses id 1")
	assert_true(host.lobby.state.find_human(cid) >= 0, "host holds the client under its own id")
	assert_true(client.lobby.state.find_human(cid) >= 0, "client sees itself under its own id")
	await _teardown(host, client)


func test_lobby_name_and_class_sync_to_all_peers() -> void:
	var p: Dictionary = await _connect_pair("2")
	var host: NetSession = p["host"]
	var client: NetSession = p["client"]
	var cid := client.get_unique_id()
	client.lobby.submit_local("Renamed", "sagittarii")
	var timeout := float(host.cfg["connect_timeout_s"])
	var ok: bool = await _wait_until(func() -> bool:
		var i: int = host.lobby.state.find_human(cid)
		var j: int = client.lobby.state.find_human(cid)
		return i >= 0 and j >= 0 and host.lobby.state.humans[i]["class_id"] == "sagittarii" \
				and client.lobby.state.humans[j]["class_id"] == "sagittarii", timeout)
	assert_true(ok, "class change reached host and client")
	assert_eq(host.lobby.state.humans[host.lobby.state.find_human(cid)]["name"], "Renamed", "name synced on host")
	assert_eq(client.lobby.state.to_dict()["humans"], host.lobby.state.to_dict()["humans"], "same humans on both")
	await _teardown(host, client)


func test_lobby_rejects_edit_of_other_player() -> void:
	var p: Dictionary = await _connect_pair("3")
	var host: NetSession = p["host"]
	var client: NetSession = p["client"]
	var timeout := float(host.cfg["connect_timeout_s"])
	# The client asks for a change; the host applies it only to the client's own entry, never the host's.
	client.lobby.submit_local("Cli2", "sagittarii")
	await _wait_until(func() -> bool: return host.lobby.state.humans[1]["name"] == "Cli2", timeout)
	assert_eq(host.lobby.state.humans[0]["class_id"], "hastati", "host entry class untouched")
	assert_eq(host.lobby.state.humans[0]["name"], "Host", "host entry name untouched")
	# An unknown class id is refused.
	client.lobby.submit_local("Cli2", "emperor")
	await _wait_until(func() -> bool: return false, 0.3)
	assert_eq(host.lobby.state.humans[1]["class_id"], "sagittarii", "invalid class ignored")
	await _teardown(host, client)


func test_bot_class_override_state() -> void:
	var l := LobbyState.new()
	l.setup(2, 3)
	l.add_human(1, "Me")
	var base := l.assign()
	assert_true(l.set_bot_class(1, "sagittarii"), "override accepted")
	var slots := l.assign()
	assert_eq(slots[1]["class_id"], "sagittarii", "slot 1 overridden")
	for i in [2, 3, 4, 5]:
		assert_eq(slots[i]["class_id"], base[i]["class_id"], "rotation default for slot %d" % i)
	var copy := LobbyState.from_dict(l.to_dict())
	assert_eq(copy.assign()[1]["class_id"], "sagittarii", "override survives to_dict/from_dict")
	assert_true(not l.set_bot_class(2, "emperor"), "invalid class refused")
	assert_true(not l.set_bot_class(0, "sagittarii"), "human slot refused")
	# A human joining into the overridden slot keeps their own class.
	l.add_human(7, "Joiner")
	assert_eq(l.assign()[1]["class_id"], "hastati", "joiner keeps own class")
	assert_eq(l.assign()[1]["is_bot"], false, "slot now human")


func test_bot_override_reaches_client() -> void:
	var p: Dictionary = await _connect_pair("5")
	var host: NetSession = p["host"]
	var client: NetSession = p["client"]
	var timeout := float(host.cfg["connect_timeout_s"])
	assert_true(host.lobby.set_bot_class(3, "sagittarii"), "host sets bot class")
	var ok: bool = await _wait_until(func() -> bool: return client.lobby.state.bot_classes.get(3, "") == "sagittarii", timeout)
	assert_true(ok, "override reached client")
	assert_eq(client.lobby.state.assign()[3]["class_id"], "sagittarii", "client assigns override")
	assert_true(not client.lobby.set_bot_class(4, "sagittarii"), "client cannot change bots")
	await _teardown(host, client)


func test_start_match_delivers_same_lobby_and_seed() -> void:
	var p: Dictionary = await _connect_pair("4")
	var host: NetSession = p["host"]
	var client: NetSession = p["client"]
	var fired := {"host": false, "client": false}
	host.lobby.match_starting.connect(func() -> void: fired["host"] = true)
	client.lobby.match_starting.connect(func() -> void: fired["client"] = true)
	var timeout := float(host.cfg["connect_timeout_s"])
	assert_true(host.lobby.start_match(), "host starts the match")
	var ok: bool = await _wait_until(func() -> bool: return fired["host"] and fired["client"], timeout)
	assert_true(ok, "match_starting fired on both peers")
	assert_eq(client.lobby.state.to_dict(), host.lobby.state.to_dict(), "equal lobby dicts")
	assert_eq(client.lobby.match_seed, host.lobby.match_seed, "same seed")
	assert_eq(AppFlow.match_seed, host.lobby.match_seed, "seed stored in AppFlow")
	assert_true(AppFlow.lobby != null and AppFlow.lobby.started, "lobby stored in AppFlow")
	assert_true(not host.lobby.state.add_human(999, "Late"), "joins rejected after start")
	await _teardown(host, client)
