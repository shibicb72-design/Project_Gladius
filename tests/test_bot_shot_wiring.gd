extends "res://tests/test_case.gd"
## Bot shots reach the clients through the real entry point: MatchRoot.begin() on a hosted networked
## match must wire every bot pawn's shot into the host bridge (no direct call to the wiring helper).

const _MatchScene := preload("res://scenes/match/match.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _make_session(node_name: String) -> NetSession:
	var s := NetSession.new()
	s.name = node_name
	s.isolated = true
	_tree().root.add_child(s)
	return s


func test_begin_wires_bot_shots_to_the_host_bridge() -> void:
	var host := _make_session("WireHost")
	host.host_game()
	host.lobby.host_open(2, 3, "Host")
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_tree().root.add_child(vp)
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = true
	m.session_override = host
	m.lobby_override = host.lobby.state
	m.seed_override = host.lobby.match_seed
	vp.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	m.director.match_cfg["spawn_protection_s"] = 0.0
	if not m.begin():
		failures.append("match did not begin")
	assert_true(m.bots.size() >= 1, "the hosted match has at least one bot")
	assert_true(m.roster != null and m.roster.bridge != null and is_instance_valid(m.roster.bridge),
			"the roster has a host bridge")
	if m.bots.size() >= 1 and m.roster != null and m.roster.bridge != null:
		var bot: Pawn = m.bots[0]
		var bot_id := -1
		var all: Dictionary = m.director.all_players()
		for id in all:
			if all[id] == bot:
				bot_id = int(id)
		assert_true(bot_id != -1, "the director knows the bot's player id")
		var seen: Array = []
		m.roster.bridge.shot_announced.connect(func(id: int, _o: Vector3, _e: Vector3) -> void: seen.append(id))
		bot.fire_shot()
		assert_eq(seen.size(), 1, "one bot shot -> exactly one announce through begin()'s wiring")
		assert_eq(seen[0] if seen.size() > 0 else -1, bot_id, "announced with the bot's player id")
	m.queue_free()
	host.leave()
	host.queue_free()
	vp.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _tree().process_frame
	await _tree().process_frame
