extends "res://tests/test_case.gd"

const _MatchScene := preload("res://scenes/match/match.tscn")


func _lobby() -> LobbyState:
	var cfg := DataRegistry.new().load_file("res://data/match.json")
	var l := LobbyState.new()
	l.setup(int(cfg.get("squads", 2)), int(cfg.get("squad_size", 3)))
	l.add_human(11, "A")
	l.add_human(12, "B")
	l.add_human(13, "C")
	l.set_class(12, "sagittarii")
	return l


func _new_match(with_lobby: bool, seed_value: int = 0) -> MatchRoot:  # call with await
	AppFlow.lobby = _lobby() if with_lobby else null
	AppFlow.match_seed = seed_value
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = with_lobby
	var tree: SceneTree = Engine.get_main_loop()
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	return m


func _frames(n: int) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for i in n:
		await tree.physics_frame


func test_match_root_spawns_one_pawn_per_lobby_human() -> void:
	var m := await _new_match(true)
	assert_true(m.begin(), "begin succeeds")
	var slots: Array = AppFlow.lobby.slots
	var players := m.director.all_players()
	assert_eq(players.size(), slots.size(), "one pawn per lobby slot (humans + bots fill)")
	for s in slots:
		var pawn: Pawn = m.director.player(int(s["player_id"]))
		assert_true(pawn != null, "pawn for player %d" % int(s["player_id"]))
		if pawn != null:
			assert_eq(pawn.squad_id, int(s["squad_id"]), "squad of player %d" % int(s["player_id"]))
			assert_eq(pawn.class_id, str(s["class_id"]), "class of player %d" % int(s["player_id"]))
			assert_eq(pawn.get_node_or_null("Brain") != null, bool(s["is_bot"]), "brain only on bots")
	assert_eq(m.bots.size(), 3, "three bots fill squad 1")
	assert_eq(m.local_player, m.director.player(0), "offline: first human is the local pawn")
	assert_true(m.local_player.get_node_or_null("CameraRig") != null, "local pawn has the camera rig")
	assert_true(m.director.player(1).get_node_or_null("CameraRig") == null, "remote human has no camera rig")
	m.queue_free()
	AppFlow.lobby = null
	await _frames(1)


func test_match_root_same_seed_same_squad_spots() -> void:
	var positions: Array = []
	for run in 2:
		var m := await _new_match(true, 424242)
		assert_true(m.begin(), "begin succeeds")
		var snap: Dictionary = {}
		for id in m.director.all_players():
			snap[id] = m.director.player(id).global_position
		positions.append(snap)
		m.queue_free()
		await _frames(2)
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	assert_eq(positions[0].size(), positions[1].size(), "same pawn count")
	for id in positions[0]:
		assert_true(positions[1].has(id) and positions[0][id].is_equal_approx(positions[1][id]),
				"player %s at the same spawn spot" % id)


func test_client_director_is_passive() -> void:
	var m := await _new_match(false)
	m.director.mode_cfg["score_to_win"] = 1
	assert_true(m.begin(), "begin succeeds")
	m.director.authoritative = false
	var seen: Array = []
	m.director.match_over.connect(func(r): seen.append(r))
	await _frames(2)
	m.local_player.global_position = Vector3(0.0, 0.1, 0.0)
	await _frames(130)
	assert_eq(float(m.director.rules.scores[0]), 0.0, "passive director does not score")
	assert_eq(seen.size(), 0, "passive director emits no match_over")
	m.director.apply_remote_match_over({"winner": 0})
	assert_eq(seen.size(), 1, "host's match over is replayed")
	m.queue_free()
	await _frames(1)


func test_bridge_handlers_ignore_missing_director() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var b := NetMatchBridge.new()
	tree.root.add_child(b)
	await tree.physics_frame
	b.submit_input([], Vector3.ZERO, 0.0, 0)
	b.request_fire(Vector3.ZERO, Vector3.FORWARD, "pilum", 0)
	var res := b.host_handle_fire(2, Vector3.ZERO, Vector3.FORWARD, "pilum")
	assert_eq(res["ok"], false, "fire without a director is rejected")
	b.snapshot(1, [])
	b.apply_replica(0)
	b.unregister_peer(2)
	b.ev_respawn(0)
	b.ev_score({0: 1})
	await tree.physics_frame
	assert_true(b.director == null, "still no director, no error")
	b.queue_free()
