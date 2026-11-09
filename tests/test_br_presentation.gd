extends "res://tests/test_case.gd"
## M1 S2: Solo/Squads choice in the lobby, spectating after elimination, and the zone wall.

const _MatchScene := preload("res://scenes/match/match.tscn")


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


static func _zone(radius: float, damage: float) -> Dictionary:
	return {"start_center": [0, 0], "start_radius_m": radius, "damage_skips_shield": false,
			"phases": [{"wait_s": 2.0, "shrink_s": 4.0, "radius_m": radius * 0.5, "damage_per_s": damage}]}


func _new_match(zone: Dictionary, mode: String = "solo") -> MatchRoot:  # call with await
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 4242
	_root().add_child(m)
	await (Engine.get_main_loop() as SceneTree).physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = zone
	m.director.mode_cfg["teams"]["mode"]["value"] = mode
	return m


func test_lobby_state_team_mode_layout_and_wire_format() -> void:
	var l := LobbyState.new()
	l.setup(18, 1)
	assert_true(l.add_human(1, "Host"), "host joins")
	assert_true(l.set_team_mode("squads", 6, 3), "squads accepted")
	assert_eq([l.team_mode, l.squad_count, l.squad_size], ["squads", 6, 3], "squads layout")
	assert_true(not l.set_team_mode("duos", 9, 2), "unknown mode refused")
	var back := LobbyState.from_dict(l.to_dict())
	assert_eq(back.team_mode, "squads", "team mode survives the wire format")
	assert_eq(LobbyState.from_dict({"team_mode": "chaos"}).team_mode, "solo", "bad wire value falls back to solo")
	assert_true(l.start(), "start")
	assert_true(not l.set_team_mode("solo", 18, 1), "refused after start")


func test_lobby_mode_button_toggles_solo_and_squads() -> void:
	var s := NetSession.new()
	s.name = "BrPresentationSession"
	s.isolated = true
	_root().add_child(s)
	AppFlow.session = s
	s.host_game()
	var lobby: Lobby = load("res://scenes/ui/lobby.tscn").instantiate()
	_root().add_child(lobby)
	assert_true(lobby.mode_button.visible, "host sees the Mode button")
	assert_eq(lobby.state.team_mode, "solo", "data default: solo")
	assert_eq(lobby.mode_button.text, "Mode: Solo", "button shows solo")
	assert_eq(lobby.slot_buttons.size(), 18, "solo: 18 slots of 1")
	lobby.mode_button.pressed.emit()
	assert_eq(lobby.state.team_mode, "squads", "toggled to squads")
	assert_eq([lobby.state.squad_count, lobby.state.squad_size], [6, 3], "squads: 6 x 3")
	assert_eq(lobby.mode_button.text, "Mode: Squads", "button shows squads")
	lobby.mode_button.pressed.emit()
	assert_eq(lobby.state.team_mode, "solo", "back to solo")
	lobby.free()
	AppFlow.end_session()
	AppFlow.lobby = null


func test_match_uses_the_lobby_team_mode() -> void:
	var m := await _new_match(_zone(5000.0, 0.0))
	var l := LobbyState.new()
	l.setup(6, 3)
	l.add_human(0, "Host")
	assert_true(l.set_team_mode("squads", 6, 3), "squads")
	m.lobby_override = l
	assert_true(m.begin(), "begin")
	assert_eq(m.director.team_mode(), "squads", "director plays squads")
	assert_eq(m.director.squads_alive(), 6, "6 squads")
	m.queue_free()


func test_pick_spectate_target_order() -> void:
	var squads := {1: 10, 2: 10, 3: 11, 4: 12, 5: 13}
	var alive := {1: false, 2: true, 3: true, 4: true, 5: true}
	var sq := func(i: int) -> int: return int(squads.get(i, -1))
	var in_match := func(i: int) -> bool: return bool(alive.get(i, false))
	var ids := [5, 4, 3, 2, 1]
	assert_eq(SpectatorCamera.pick_target(1, 4, ids, sq, in_match), 2, "living squad mate first")
	alive[2] = false
	assert_eq(SpectatorCamera.pick_target(1, 4, ids, sq, in_match), 4, "then the killer")
	alive[4] = false
	assert_eq(SpectatorCamera.pick_target(1, 4, ids, sq, in_match), 3, "then the lowest id still in")
	for k in alive:
		alive[k] = false
	assert_eq(SpectatorCamera.pick_target(1, 4, ids, sq, in_match), -1, "nobody left")


func test_zone_wall_follows_the_zone() -> void:
	var m := await _new_match(_zone(60.0, 0.0))
	assert_true(m.begin(), "begin")
	assert_true(m.zone_wall != null and m.zone_wall.visible, "zone wall built")
	assert_true(absf(ZoneWall.drawn_radius(m.zone_wall.wall) - 60.0) < 1e-3, "wall at the start radius")
	await (Engine.get_main_loop() as SceneTree).physics_frame
	assert_true(absf(ZoneWall.drawn_radius(m.zone_wall.target_ring) - m.director.rules.zone_target_radius()) < 1e-3, "ring at the target circle")
	m.director.rules.tick(4.0, {"positions": {}, "reviving": {}})  # 2 s wait + half of the 4 s shrink
	m.zone_wall.refresh()
	assert_true(absf(ZoneWall.drawn_radius(m.zone_wall.wall) - m.director.rules.zone_radius()) < 1e-3, "wall follows the shrinking circle")
	assert_true(ZoneWall.drawn_radius(m.zone_wall.wall) < 60.0, "and it is smaller")
	m.queue_free()


func test_local_elimination_starts_spectating() -> void:
	var m := await _new_match(_zone(5000.0, 0.0))
	assert_true(m.begin(), "begin")
	for b in m.bots:
		var brain := b.get_node_or_null("Brain")
		if brain != null:
			brain.set_physics_process(false)
	await (Engine.get_main_loop() as SceneTree).physics_frame
	var killer: Pawn = m.bots[0]
	m.director.rules.report_zero_health(0, killer.player_id, "hit")  # solo: straight to DEAD
	for i in 3:
		await (Engine.get_main_loop() as SceneTree).physics_frame
	assert_eq(m.local_player.life, Pawn.Life.DEAD, "local player eliminated")
	assert_true(m.spectator != null, "spectator camera created")
	assert_true(m.spectator.target == killer, "solo: follows the killer")
	assert_true(m.spectator.current, "spectator camera is current")
	await (Engine.get_main_loop() as SceneTree).process_frame  # the HUD refreshes on render frames
	m.hud.refresh_pawn()
	assert_true(m.hud.downed_label.text.begins_with("Spectating "), "HUD says who is watched: '%s'" % m.hud.downed_label.text)
	m.queue_free()
