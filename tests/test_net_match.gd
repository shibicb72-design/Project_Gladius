extends "res://tests/test_case.gd"
## End-to-end hotspot match on loopback: a host and a client in one process, each MatchRoot in its own
## SubViewport world (otherwise the host's raycasts would hit the client's copies of the pawns).

const _MatchScene := preload("res://scenes/match/match.tscn")
const TIMEOUT_S := 5.0


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


func _build_match(session: NetSession, viewports: Array) -> MatchRoot:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.size = Vector2i(64, 64)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_tree().root.add_child(vp)
	viewports.append(vp)
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.session_override = session
	m.lobby_override = session.lobby.state
	m.seed_override = session.lobby.match_seed
	vp.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	m.director.match_cfg["spawn_protection_s"] = 0.0
	if not m.begin():
		failures.append("match did not begin")
	return m


## Returns {host, client, hm, cm, viewports}; the lobby has started and both match scenes run.
func _start_pair(tag: String) -> Dictionary:
	var host := _make_session("EHost" + tag)
	var client := _make_session("EClient" + tag)
	var out := {"host": host, "client": client, "viewports": [], "ok": false}
	host.host_game()
	host.lobby.host_open(2, 3, "Host")
	client.join_game("127.0.0.1")
	if not await _wait_until(func() -> bool: return client.is_connected_to_host(), TIMEOUT_S):
		failures.append("client did not connect")
		return out
	client.lobby.submit_local("Cli", "sagittarii")
	if not await _wait_until(func() -> bool: return host.lobby.state.humans.size() == 2, TIMEOUT_S):
		failures.append("client did not reach the lobby")
		return out
	var started := {"host": false, "client": false}
	host.lobby.match_starting.connect(func() -> void: started["host"] = true)
	client.lobby.match_starting.connect(func() -> void: started["client"] = true)
	host.lobby.start_match()
	if not await _wait_until(func() -> bool: return started["host"] and started["client"], TIMEOUT_S):
		failures.append("match_starting did not reach both peers")
		return out
	out["hm"] = await _build_match(host, out["viewports"])
	out["cm"] = await _build_match(client, out["viewports"])
	out["ok"] = true
	return out


func _teardown(p: Dictionary) -> void:
	for key in ["client", "host"]:
		p[key].leave()
		p[key].queue_free()
	for vp in p["viewports"]:
		vp.queue_free()
	AppFlow.lobby = null
	AppFlow.match_seed = 0
	await _tree().process_frame
	await _tree().process_frame


func _pawn_set(m: MatchRoot) -> Dictionary:
	var out := {}
	for id in m.director.all_players():
		var pawn: Pawn = m.director.all_players()[id]
		out[id] = [pawn.squad_id, pawn.class_id]
	return out


func test_e2e_client_join_start_same_pawn_set() -> void:
	var p: Dictionary = await _start_pair("1")
	if p["ok"]:
		var hm: MatchRoot = p["hm"]
		var cm: MatchRoot = p["cm"]
		var cid: int = p["client"].get_unique_id()
		assert_true(hm.director.all_players().size() >= 2, "host has pawns")
		assert_eq(_pawn_set(cm), _pawn_set(hm), "same player ids, squads and classes on both peers")
		assert_eq(cm.local_player.class_id, "sagittarii", "client pawn uses the client's class")
		var host_copy: Pawn = hm.director.player(hm.roster.bridge.peer_to_player.get(cid, -1))
		assert_true(host_copy != null, "host maps the client's peer id to a pawn")
		if host_copy != null:
			assert_eq(host_copy.net_mode, Pawn.NetMode.HOST_REMOTE, "remote human is net-driven on the host")
			assert_eq(host_copy.class_id, "sagittarii", "host copy has the client's class")
		assert_true(not cm.local_player.hit_authority.is_valid(), "client local hits are presentation only")
	await _teardown(p)


func test_e2e_host_drop_runs_client_handler_and_goes_to_menu() -> void:
	var p: Dictionary = await _start_pair("HD")
	if p["ok"]:
		var cm: MatchRoot = p["cm"]
		var went := {"scene": ""}
		cm.go_scene = func(path: String) -> void: went["scene"] = path
		assert_true(not cm.host_lost_handled, "handler not yet run")
		p["host"].leave()  # closes the loopback host
		var ok: bool = await _wait_until(func() -> bool: return cm.host_lost_handled, TIMEOUT_S)
		assert_true(ok, "client session.host_lost ran MatchRoot._on_host_lost")
		assert_eq(went["scene"], AppFlow.MENU_SCENE, "host drop changes to the menu scene")
	await _teardown(p)


func test_e2e_client_input_moves_pawn_on_host() -> void:
	var p: Dictionary = await _start_pair("2")
	if p["ok"]:
		var hm: MatchRoot = p["hm"]
		var cm: MatchRoot = p["cm"]
		var pid: int = cm.roster.local_player_id
		var host_copy: Pawn = hm.director.player(pid)
		# Let the first snapshot snap the client onto the host's spawn position.
		await _wait_until(func() -> bool: return cm.roster.bridge.last_snapshot_tick >= 0, TIMEOUT_S)
		await _tree().physics_frame
		var start: Vector3 = cm.local_player.global_position
		assert_true(start.distance_to(host_copy.global_position) < 0.5, "client starts on the host's position")
		var target := start + Vector3(3.0, 0.0, 0.0)
		for i in 50:  # 0.06 m per 60 Hz tick = 3.6 m/s, inside the speed check
			await _tree().physics_frame
			cm.local_player.global_position.x += 0.06
		var moved: bool = await _wait_until(func() -> bool:
			return absf(host_copy.global_position.x - cm.local_player.global_position.x) < 0.3 \
					and host_copy.global_position.x > start.x + 2.0, TIMEOUT_S)
		assert_true(moved, "host's copy followed the client (x %.2f, target %.2f)" % [host_copy.global_position.x, target.x])
	await _teardown(p)


func test_e2e_client_fire_damages_on_host_only() -> void:
	var p: Dictionary = await _start_pair("3")
	if p["ok"]:
		var hm: MatchRoot = p["hm"]
		var cm: MatchRoot = p["cm"]
		var pid: int = cm.roster.local_player_id
		var host_copy: Pawn = hm.director.player(pid)
		await _wait_until(func() -> bool: return cm.roster.bridge.last_snapshot_tick >= 0, TIMEOUT_S)
		for i in 3:
			await _tree().physics_frame
		# Host bots stand still; one is placed 6 m in front of the shooter.
		var bot: Pawn = null
		for b in hm.bots:
			var brain := b.get_node_or_null("Brain")
			if brain != null:
				brain.set_physics_process(false)
			b.set_physics_process(false)
			if b.squad_id == host_copy.squad_id:
				b.global_position += Vector3(0.0, 30.0, 0.0)  # teammates must not block the ray
			if bot == null and b.squad_id != host_copy.squad_id:
				bot = b
		assert_true(bot != null, "an enemy bot exists")
		# Squad spots depend on the random lobby seed, so the host's own (non-bot) pawn can spawn in the
		# line of fire and soak up the shot. Park every non-bot pawn other than the shooter out of the way.
		for id in hm.director.all_players():
			var other: Pawn = hm.director.all_players()[id]
			if other != host_copy and not hm.bots.has(other):
				other.set_physics_process(false)
				other.global_position += Vector3(0.0, 30.0, 0.0)
		if bot != null:
			bot.global_position = host_copy.global_position + Vector3(0.0, 0.0, -6.0)
			var bot_id := -1
			for id in hm.director.all_players():
				if hm.director.all_players()[id] == bot:
					bot_id = id
			var client_bot: Pawn = cm.director.player(bot_id)
			var full: float = bot.bridge.state.shield
			var chb: NetMatchBridge = cm.roster.bridge
			var hb: NetMatchBridge = hm.roster.bridge
			# Hold the host's snapshots so the client's view can only change through them.
			hb.snapshot_interval_s = 1000000.0
			var w := cm.local_player.loadout.get_active()
			var muzzle := host_copy.get_muzzle_position()
			var hit := false
			for attempt in 6:  # weapon spread can miss; fire spacing is validated by the host
				chb.send_fire(muzzle, Vector3(0, 0, -1), w.def.id)
				hit = await _wait_until(func() -> bool: return bot.bridge.state.shield < full, 0.7)
				if hit:
					break
			var diag := ""
			if not hit:
				var q := PhysicsRayQueryParameters3D.create(muzzle, muzzle + Vector3(0, 0, -20.0), 7)
				q.collide_with_areas = true
				q.exclude = host_copy.hitscan_exclude()
				var ray := hm.get_world_3d().direct_space_state.intersect_ray(q)
				diag = " [muzzle %s bot %s ray_hit %s]" % [muzzle, bot.global_position,
						str(ray.get("collider")) + " @ " + str(ray.get("position"))]
			assert_true(hit, "host applied the client's shot to the bot's shield" + diag)
			var host_shield: float = bot.bridge.state.shield
			await _wait_until(func() -> bool: return false, 0.3)
			assert_eq(client_bot.bridge.state.shield, full, "client copy unchanged before a snapshot")
			hb.snapshot_interval_s = 0.02
			var synced: bool = await _wait_until(func() -> bool:
				return is_equal_approx(client_bot.bridge.state.shield, host_shield), TIMEOUT_S)
			assert_true(synced, "client sees the new shield after a snapshot")
	await _teardown(p)


func test_e2e_client_fire_ends_spawn_protection_on_host() -> void:
	var p: Dictionary = await _start_pair("3")
	if p["ok"]:
		var hm: MatchRoot = p["hm"]
		var cm: MatchRoot = p["cm"]
		var pid: int = cm.roster.local_player_id
		var host_copy: Pawn = hm.director.player(pid)
		await _wait_until(func() -> bool: return cm.roster.bridge.last_snapshot_tick >= 0, TIMEOUT_S)
		var enemy_squad := -1
		for b in hm.bots:
			var brain := b.get_node_or_null("Brain")
			if brain != null:
				brain.set_physics_process(false)
			b.set_physics_process(false)
			if enemy_squad < 0 and b.squad_id != host_copy.squad_id:
				enemy_squad = b.squad_id
		assert_true(enemy_squad >= 0, "an enemy squad exists")
		var rules: SpawnRules = hm.director.spawn_rules
		rules.protection_s = 1000.0
		rules.spawn_now(pid)
		for i in 2:
			await _tree().physics_frame
		assert_true(rules.is_protected(pid), "client's pawn protected on the host")
		var def: WeaponDef = host_copy.loadout.get_active().def
		var res := host_copy.receive_hit(def, false, enemy_squad)
		assert_eq(res.blocked_reason, "protected", "enemy hit blocked while protected")
		cm.roster.bridge.send_fire(host_copy.get_muzzle_position(), Vector3(0, 0, -1),
				cm.local_player.loadout.get_active().def.id)
		var ended: bool = await _wait_until(func() -> bool: return not rules.is_protected(pid), TIMEOUT_S)
		assert_true(ended, "the client's shot ended protection on the host")
		for i in 2:
			await _tree().physics_frame
		var before: float = host_copy.bridge.state.shield
		res = host_copy.receive_hit(def, false, enemy_squad)
		assert_eq(res.blocked_reason, "", "enemy hit no longer blocked")
		assert_true(host_copy.bridge.state.shield < before, "host copy's shield went down")
	await _teardown(p)
