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
			# GBTN4: this test stages the bot on the claimed fire direction (0,0,-1). The client's real camera would
			# send its own aim point in every InputFrame and the host would shoot at that instead (covered by
			# tests/test_shoulder_aim.gd), so the client camera is removed here: no aim point is sent.
			var client_rig := cm.local_player.get_node_or_null("CameraRig")
			if client_rig != null:
				client_rig.free()
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
		# No spawn protection in battle royale: an enemy hit lands at once.
		assert_true(not host_copy.bridge.spawn_protected, "never protected")
		var def: WeaponDef = host_copy.loadout.get_active().def
		var before: float = host_copy.bridge.state.shield
		var res := host_copy.receive_hit(def, false, enemy_squad)
		assert_eq(res.blocked_reason, "", "enemy hit not blocked")
		assert_true(host_copy.bridge.state.shield < before, "host copy's shield went down")
	await _teardown(p)


## M2 L1b: one crate and one chest with the same ids on both peers' worlds (50 m up, out of every pawn's reach). The
## host breaks the crate and opens the chest; ev_world_prop brings both states to the client, whose crate leaves its
## world and whose chest looks open, with no loot rolled there; a client cannot break or open by itself.
func _world_props_pair(m: MatchRoot, tag: String) -> Dictionary:
	var crate := Breakable.make({"id": "Breakable_980", "type": "breakable_crate", "at": [3.0, 50.0, 3.0], "size": [1.2, 1.2, 1.2]},
			WorldProps.config()["breakables"]["breakable_crate"])
	var spare := Breakable.make({"id": "Breakable_981", "type": "breakable_crate", "at": [-3.0, 50.0, 3.0], "size": [1.2, 1.2, 1.2]},
			WorldProps.config()["breakables"]["breakable_crate"])
	var chest := LootChest.make({"id": "Chest_980", "at": [3.0, 50.0, -3.0], "size": [1.4, 0.9, 0.9], "yaw": 0.0}, "camp")
	var other := LootChest.make({"id": "Chest_981", "at": [-3.0, 50.0, -3.0], "size": [1.4, 0.9, 0.9], "yaw": 0.0}, "camp")
	for body: StaticBody3D in [crate, spare, chest, other]:
		body.name = String(body.name) + tag
		m.map.add_child(body)
	m.world_props.register_breakable(crate)
	m.world_props.register_breakable(spare)
	m.world_props.register_chest(chest)
	m.world_props.register_chest(other)
	return {"crate": crate, "spare": spare, "chest": chest, "other": other}


func test_e2e_world_props_host_and_client_agree() -> void:
	var p: Dictionary = await _start_pair("WP")
	if p["ok"]:
		var hm: MatchRoot = p["hm"]
		var cm: MatchRoot = p["cm"]
		for b in hm.bots + cm.bots:
			var brain := b.get_node_or_null("Brain")
			if brain != null:
				brain.set_physics_process(false)
		var h := _world_props_pair(hm, "H")
		var c := _world_props_pair(cm, "C")
		# These matches run without ground loot: give both WorldProps a loot field so a roll would show on either peer.
		for m: MatchRoot in [hm, cm]:
			if m.world_props.loot == null:
				var field := LootField.new()
				field.setup(DataRegistry.new().load_file(MatchDirector.LOOT_PATH), 7)
				field.placed = true
				m.add_child(field)
				m.world_props.loot = field
		assert_true(hm.world_props.authority and not cm.world_props.authority, "the host is the props authority, the client is not")
		await _tree().physics_frame
		await _tree().physics_frame
		assert_true(hm.roster.bridge._props == hm.world_props and cm.roster.bridge._props == cm.world_props, "both bridges wired their WorldProps")
		var host_crate: Breakable = h["crate"]
		var client_crate: Breakable = c["crate"]
		var client_chest: LootChest = c["chest"]
		var client_spilled := cm.world_props.spilled.size()
		host_crate.take_hit(host_crate.health)
		assert_true(hm.world_props.open_chest("Chest_980"), "the host opens the chest")
		var synced: bool = await _wait_until(func() -> bool:
			return cm.world_props.state_of("Breakable_980") == WorldProps.BROKEN and cm.world_props.state_of("Chest_980") == WorldProps.OPEN, TIMEOUT_S)
		assert_true(synced, "the client received both states")
		assert_eq(cm.world_props.states, hm.world_props.states, "both peers end with the same WorldProps states")
		await _tree().process_frame
		assert_true(not is_instance_valid(client_crate) or not client_crate.is_inside_tree(), "the client's crate left its world")
		assert_true(client_chest.is_open, "the client's chest looks open")
		assert_eq(cm.world_props.spilled.size(), client_spilled, "the client rolled no loot")
		assert_true(hm.world_props.spilled.size() >= 1, "nonvacuous: the host spilled the chest's roll")
		# A client cannot open or break by itself.
		assert_true(not cm.world_props.open_chest("Chest_981"), "a client's WorldProps opens nothing")
		assert_true(not cm.director.try_open_chest(cm.roster.local_player_id), "a client's director opens nothing")
		var spare: Breakable = c["spare"]
		var rifle := DataRegistry.new().get_weapon_def("sagittarii_rifle")
		var space := cm.map.get_world_3d().direct_space_state
		var res := Hitscan.fire(space, null, spare.global_position + Vector3(0, 5, 0), Vector3.DOWN, rifle, [] as Array[RID], Callable(), null, 0.0)
		assert_true(res.get("collider") == spare, "nonvacuous: the client's ray hits its spare crate")
		assert_true(not spare.is_broken and spare.health == spare.max_health, "a client's shot does not damage a breakable")
		await _wait_until(func() -> bool: return false, 0.3)
		assert_eq(cm.world_props.state_of("Chest_981"), WorldProps.INTACT, "the other chest stays closed on the client")
		assert_eq(hm.world_props.state_of("Chest_981"), WorldProps.INTACT, "and on the host")
		assert_eq(hm.world_props.state_of("Breakable_981"), WorldProps.INTACT, "the spare crate stays whole on the host")
	await _teardown(p)
