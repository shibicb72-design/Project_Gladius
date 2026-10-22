extends "res://tests/test_case.gd"

const _PawnScene := preload("res://scenes/player/pawn.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _registry() -> DataRegistry:
	return DataRegistry.new()


# ---- pure ---------------------------------------------------------------------------------

func test_lobby_assigns_humans_then_bots() -> void:
	var l := LobbyState.new()
	l.setup(2, 3, ["hastati", "sagittarii"])
	assert_true(l.add_human(10, "A"), "first human joins")
	assert_true(l.add_human(11, "B"), "second human joins")
	assert_true(not l.add_human(10, "dup"), "duplicate peer rejected")
	l.set_class(11, "sagittarii")
	var slots := l.assign()
	assert_eq(slots.size(), 6, "2x3 slots")
	assert_eq(slots[0]["is_bot"], false, "slot 0 human")
	assert_eq(slots[1]["is_bot"], false, "slot 1 human")
	assert_eq(slots[1]["class_id"], "sagittarii", "chosen class kept")
	var bots := 0
	var classes: Array = []
	for s in slots:
		if s["is_bot"]:
			bots += 1
			classes.append(s["class_id"])
	assert_eq(bots, 4, "bots fill the rest")
	assert_eq(classes, ["hastati", "sagittarii", "hastati", "sagittarii"], "bots rotate classes")
	assert_eq(slots[3]["squad_id"], 1, "slot 3 is in squad 1")
	assert_true(l.start(), "start with a human")
	assert_true(not l.add_human(12, "late"), "no join after start")


func test_lobby_state_roundtrip_serialization() -> void:
	var l := LobbyState.new()
	l.setup(2, 3, ["hastati", "sagittarii"])
	l.add_human(1, "Host")
	l.add_human(22, "Guest")
	l.start()
	var json := JSON.stringify(l.to_dict())
	var back := LobbyState.from_dict(JSON.parse_string(json))
	assert_eq(back.to_dict().hash(), l.to_dict().hash(), "roundtrip equal")
	assert_true(back.started, "started flag kept")
	assert_eq(back.slots.size(), 6, "slots kept")


func test_fire_request_validation_rejects_wrong_weapon_or_rate() -> void:
	var cfg: Dictionary = _registry().load_file("res://data/net.json")["validation"]
	var v := NetValidator.new(cfg)
	var w := WeaponDef.new()
	w.id = "gladius_lux"
	w.fire_interval_s = 0.5
	var o := Vector3(0, 1.3, 0)
	var d := Vector3(0, 0, -1)
	assert_true(v.validate_fire(1, "pilum", w, 0.0, o, o, d)["ok"] == false, "wrong weapon rejected")
	assert_true(v.validate_fire(1, "gladius_lux", w, 0.0, o, o, d)["ok"], "first shot ok")
	var fast := v.validate_fire(1, "gladius_lux", w, 0.1, o, o, d)
	assert_eq(fast["reason"], "rate", "too fast rejected")
	assert_true(v.validate_fire(1, "gladius_lux", w, 0.6, o, o, d)["ok"], "after interval ok")
	assert_eq(v.validate_fire(2, "gladius_lux", w, 0.0, o + Vector3(50, 0, 0), o, d)["reason"], "bad_origin",
			"far origin rejected")
	assert_true(v.validate_move(Vector3.ZERO, Vector3(0.2, 0, 0), 0.1, 5.0), "plausible move ok")
	assert_true(not v.validate_move(Vector3.ZERO, Vector3(30, 0, 0), 0.1, 5.0), "teleport rejected")


# ---- loopback -----------------------------------------------------------------------------

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


func test_loopback_host_and_client_connect() -> void:
	var host := _make_session("HostA")
	var client := _make_session("ClientA")
	var state := {"connected": false}
	client.connected.connect(func() -> void: state["connected"] = true)
	var timeout := float(host.cfg["connect_timeout_s"])
	assert_eq(host.host_game(), OK, "host starts on the net.json port")
	assert_eq(client.join_game("127.0.0.1"), OK, "client starts joining")
	var ok: bool = await _wait_until(func() -> bool: return state["connected"], timeout)
	assert_true(ok, "client connected within the timeout")
	assert_true(client.is_connected_to_host(), "client status connected")
	client.leave()
	host.leave()
	host.queue_free()
	client.queue_free()
	await _tree().process_frame


func test_host_authoritative_damage() -> void:
	var host := _make_session("HostB")
	var client := _make_session("ClientB")
	var state := {"connected": false}
	client.connected.connect(func() -> void: state["connected"] = true)

	var host_dir := MatchDirector.new()
	var client_dir := MatchDirector.new()
	host.add_child(host_dir)
	client.add_child(client_dir)
	var hb := NetMatchBridge.new()
	hb.name = "Bridge"
	host.add_child(hb)
	hb.setup(host_dir)
	var cb := NetMatchBridge.new()
	cb.name = "Bridge"
	client.add_child(cb)
	cb.setup(client_dir)

	var shooter: Pawn = _PawnScene.instantiate()
	shooter.squad_id = 0
	var target: Pawn = _PawnScene.instantiate()
	target.squad_id = 1
	host.add_child(shooter)
	host.add_child(target)
	shooter.set_physics_process(false)
	target.set_physics_process(false)
	shooter.global_position = Vector3(0, 0.1, 0)
	target.global_position = Vector3(0, 0.1, -5)
	host_dir.add_player(0, shooter)
	host_dir.add_player(1, target)
	hb.register_peer(0, 0)  # placeholder, replaced once the client id is known
	for i in 3:
		await _tree().physics_frame

	assert_eq(host.host_game(), OK, "host starts")
	assert_eq(client.join_game("127.0.0.1"), OK, "client joins")
	var timeout := float(host.cfg["connect_timeout_s"])
	var ok: bool = await _wait_until(func() -> bool: return state["connected"], timeout)
	assert_true(ok, "connected")
	if ok:
		hb.peer_to_player.clear()
		hb.register_peer(client.get_unique_id(), 0)
		var before: float = target.bridge.state.shield
		var w := shooter.loadout.get_active()
		cb.send_fire(shooter.get_muzzle_position(), Vector3(0, 0, -1), w.def.id)
		var hit: bool = await _wait_until(func() -> bool: return target.bridge.state.shield < before, 3.0)
		assert_true(hit, "host applied damage to the target shield")
		var host_shield: float = target.bridge.state.shield
		var synced: bool = await _wait_until(func() -> bool:
				return cb.replica.has(1) and is_equal_approx(cb.replica[1]["shield"], host_shield), 3.0)
		assert_true(synced, "client received the replicated shield")
		# Wrong weapon id from the client must not damage anyone.
		var after: float = target.bridge.state.shield
		cb.send_fire(shooter.get_muzzle_position(), Vector3(0, 0, -1), "not_a_weapon")
		for i in 20:
			await _tree().process_frame
		assert_eq(target.bridge.state.shield, after, "invalid fire request ignored")

	client.leave()
	host.leave()
	host.queue_free()
	client.queue_free()
	await _tree().process_frame
