extends "res://tests/test_case.gd"
## Battle royale in the real match scene: zone damage, solo kill, squads down, 18-player cap, a full fast match.

const _MatchScene := preload("res://scenes/match/match.tscn")


## Test config: one slow zone phase (no shrink damage unless a test asks), fixed seed.
static func _zone(radius: float, damage: float, skips: bool = false) -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": radius, "damage_skips_shield": skips,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": radius * 0.5, "damage_per_s": damage}]}


func _new_match(zone: Dictionary, mode: String = "solo") -> MatchRoot:  # call with await
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 12345
	var tree: SceneTree = Engine.get_main_loop()
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = zone
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	return m


func _idle_bots(m: MatchRoot) -> void:
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)


func _frames(n: int) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for i in n:
		await tree.physics_frame


func _hit(attacker: Pawn, victim: Pawn) -> void:
	var def := DataRegistry.new().get_weapon_def("sagittarii_rifle")
	victim.receive_hit(def, true, attacker.squad_id, attacker.player_id)


func test_eighteen_players_both_roster_paths() -> void:
	var m := await _new_match(_zone(5000.0, 0.0))
	assert_true(m.begin(), "begin")
	assert_eq(m.director.all_players().size(), 18, "standalone solo: 18 players")
	assert_eq(m.director.squads_alive(), 18, "solo: 18 squads")
	m.queue_free()
	var s := await _new_match(_zone(5000.0, 0.0), "squads")
	assert_true(s.begin(), "begin squads")
	assert_eq(s.director.all_players().size(), 18, "standalone squads: 18 players")
	assert_eq(s.director.squads_alive(), 6, "squads: 6 squads of 3")
	s.queue_free()
	var lobby := LobbyState.new()
	var layout := MatchDirector.team_layout(s.director.mode_cfg, s.director.match_cfg)
	lobby.setup(int(layout["squad_count"]), int(layout["squad_size"]))
	lobby.max_humans = int(s.director.match_cfg["max_humans"])
	for i in 10:
		lobby.add_human(i + 1, "p%d" % i)
	assert_eq(lobby.humans.size(), 8, "human cap is max_humans (8)")
	assert_eq(lobby.assign().size(), 18, "lobby path: 18 slots")


func test_zone_damage_outside_not_inside() -> void:
	var m := await _new_match(_zone(5.0, 20.0))
	assert_true(m.begin(), "begin")
	_idle_bots(m)
	var inside := m.local_player
	var outside: Pawn = m.bots[0]
	inside.global_position = Vector3(0.0, 0.1, 0.0)
	outside.global_position = Vector3(80.0, 0.1, 80.0)
	var before_in: float = inside.bridge.state.health + inside.bridge.state.shield
	var before_out: float = outside.bridge.state.health + outside.bridge.state.shield
	await _frames(20)
	assert_true(inside.bridge.state.health + inside.bridge.state.shield >= before_in - 1e-4, "inside takes no zone damage")
	assert_true(outside.bridge.state.health + outside.bridge.state.shield < before_out - 1.0, "outside takes zone damage")
	m.queue_free()


func test_zone_damage_skips_shield_when_flagged() -> void:
	var m := await _new_match(_zone(5.0, 20.0, true))
	assert_true(m.begin(), "begin")
	_idle_bots(m)
	var p: Pawn = m.bots[0]
	p.global_position = Vector3(80.0, 0.1, 80.0)
	var shield: float = p.bridge.state.shield
	var health: float = p.bridge.state.health
	await _frames(10)
	assert_true(absf(p.bridge.state.shield - shield) < 1e-4, "shield untouched")
	assert_true(p.bridge.state.health < health - 0.5, "health lowered")
	m.queue_free()


func test_solo_hit_to_zero_kills() -> void:
	var m := await _new_match(_zone(5000.0, 0.0))
	assert_true(m.begin(), "begin")
	_idle_bots(m)
	await _frames(2)  # rules start on the first tick; earlier zero-health reports are ignored
	var victim: Pawn = m.bots[0]
	var killers: Array = []
	m.director.player_eliminated.connect(func(id: int, k: int, c: String) -> void: killers.append([id, k, c]))
	victim.bridge.state.shield = 0.0
	victim.bridge.state.health = 1.0
	_hit(m.local_player, victim)
	assert_true(not victim.is_alive(), "zero health counts as not alive at once")
	await _frames(2)
	assert_eq(victim.life, Pawn.Life.DEAD, "dead after the next tick")
	assert_true(not victim.visible, "deactivated")
	assert_eq(killers.size(), 1, "one elimination")
	if killers.size() == 1:
		assert_eq(killers[0][1], 0, "credited to the local player")
	m.queue_free()


func test_squads_hit_to_zero_downs_and_blocks_fire() -> void:
	var m := await _new_match(_zone(5000.0, 0.0), "squads")
	assert_true(m.begin(), "begin")
	_idle_bots(m)
	await _frames(2)  # rules start on the first tick
	var victim: Pawn = m.bots[0]
	var enemy: Pawn = m.bots[m.bots.size() - 1]
	assert_true(enemy.squad_id != victim.squad_id, "enemy is in another squad")
	victim.bridge.state.shield = 0.0
	victim.bridge.state.health = 1.0
	_hit(enemy, victim)
	await _frames(2)
	assert_true(victim.is_downed(), "downed, not dead")
	assert_true(not victim.is_alive(), "downed pawn is not alive (cannot fire)")
	m.queue_free()


## One fast match: short phases, high damage; ends in a winner or a draw with consistent final states.
func test_fast_match_ends_with_consistent_state() -> void:
	var zone := {"start_center": [0, 0], "start_radius_m": 40.0, "damage_skips_shield": true,
			"phases": [{"wait_s": 0.3, "shrink_s": 0.5, "radius_m": 20.0, "damage_per_s": 60.0},
					{"wait_s": 0.2, "shrink_s": 0.5, "radius_m": 0.5, "damage_per_s": 400.0}]}
	var m := await _new_match(zone)
	var results: Array = []
	m.director.match_over.connect(func(r: Dictionary) -> void: results.append(r))
	assert_true(m.begin(), "begin")
	var tree: SceneTree = Engine.get_main_loop()
	var n := 0
	while results.is_empty() and n < 900:
		await tree.physics_frame
		n += 1
	assert_eq(results.size(), 1, "match_over emitted once")
	if results.size() == 1:
		var r: Dictionary = results[0]
		assert_true(bool(r["draw"]) or int(r["winner"]) >= 0, "a winner or a draw")
		assert_eq((r["placements"] as Dictionary).size(), 18, "placements cover every squad")
		var winner_alive := false
		for id in m.director.all_players():
			var p: Pawn = m.director.player(id)
			if not bool(r["draw"]) and p.squad_id == int(r["winner"]):
				winner_alive = winner_alive or p.life != Pawn.Life.DEAD
			else:
				assert_eq(p.life, Pawn.Life.DEAD, "pawn %d is dead" % id)
				assert_true(not p.visible, "pawn %d inactive" % id)
		assert_true(bool(r["draw"]) or winner_alive, "winner squad has a living pawn")
	m.queue_free()
