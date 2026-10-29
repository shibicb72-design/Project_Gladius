extends "res://tests/test_case.gd"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


## Actual offline match with its filled bot roster. Freeze simulation, then shoot through real hitscan/damage.
func _match() -> MatchRoot:
	var m: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	_tree().root.add_child(m)
	await _tree().physics_frame
	assert_true(m.begin(), "offline match begins")
	m.set_physics_process(false)
	m.director.running = false
	var index := 0
	for p: Pawn in m.director.all_players().values():
		p.set_physics_process(false)
		if p.has_node("Brain"):
			p.get_node("Brain").set_physics_process(false)
		p.bridge.spawn_protected = false
		p.position = Vector3(60, 0.1, 65 + index * 3)
		index += 1
	m.local_player.position = Vector3(60, 0.1, 60)
	m.local_player.rotation = Vector3.ZERO
	m.local_player.set_frame(InputFrame.new())
	# Let Area3D discard overlaps at each freshly instantiated pawn's original transform.
	for i in 3:
		await _tree().physics_frame
	await _tree().process_frame
	await _tree().process_frame
	m.hud.banner_label.visible = false
	m.hud._banner_left_s = 0.0
	return m


func _enemy(m: MatchRoot) -> Pawn:
	for p: Pawn in m.bots:
		if p.squad_id != m.local_player.squad_id:
			return p
	return null


func _aim_at_bot(m: MatchRoot) -> Pawn:
	var victim := _enemy(m)
	assert_true(victim != null, "enemy bot in real roster")
	victim.position = m.local_player.position + Vector3(0, 0, -4)
	await _tree().physics_frame
	await _tree().physics_frame
	await _tree().process_frame
	await _tree().process_frame
	assert_true(not m.hud.banner_label.visible, "no pre-shot banner: %s" % m.hud.banner_label.text)
	return victim


func test_offline_local_fire_kill_shows_and_expires() -> void:
	var m := await _match()
	var victim := await _aim_at_bot(m)
	victim.bridge.state.shield = 0.0
	victim.bridge.state.health = 1.0
	var hit := m.local_player.fire_shot()
	assert_eq(hit.get("target"), victim, "real shot hits the bot")
	assert_true(not victim.is_alive(), "authority killed bot")
	assert_true(m.hud.banner_label.visible, "offline local kill banner visible")
	assert_eq(m.hud.banner_label.text, String(m.hud._banner_cfg["kill_text"]), "kill copy from data")
	var duration := float(m.hud._banner_cfg["duration_s"])
	await _tree().create_timer(duration + 0.1).timeout
	assert_true(not m.hud.banner_label.visible, "banner clears after data duration")
	m.free()


func test_nonlethal_local_shot_has_no_kill_banner() -> void:
	var m := await _match()
	var victim := await _aim_at_bot(m)
	var shield_before := victim.bridge.state.shield
	var hit := m.local_player.fire_shot()
	assert_eq(hit.get("target"), victim, "nonlethal shot hits")
	assert_true(victim.bridge.state.shield < shield_before and victim.is_alive(), "real damage but alive")
	assert_true(not m.hud.banner_label.visible, "no kill banner on nonlethal")
	m.free()


func test_other_shooter_kill_and_local_death_have_no_banner() -> void:
	var m := await _match()
	var victim := await _aim_at_bot(m)
	var other: Pawn
	for p: Pawn in m.bots:
		if p != victim and p.squad_id == m.local_player.squad_id:
			other = p
	assert_true(other != null, "squad bot shooter")
	other.position = m.local_player.position + Vector3(0, 0, -2)
	other.rotation = Vector3.ZERO
	other.set_frame(InputFrame.new())
	victim.bridge.state.shield = 0.0
	victim.bridge.state.health = 1.0
	await _tree().physics_frame
	await _tree().physics_frame
	var hit := other.fire_shot()
	assert_eq(hit.get("target"), victim, "other shooter hits")
	assert_true(not victim.is_alive(), "other shooter kills")
	assert_true(not m.hud.banner_label.visible, "no global kill feed")
	m.local_player.bridge.state.shield = 0.0
	m.local_player.bridge.state.health = 1.0
	m.local_player.receive_hit(victim.loadout.get_active().def, false, victim.squad_id)
	assert_true(not m.local_player.is_alive(), "local death fixture")
	assert_true(not m.hud.banner_label.visible, "own death is left to respawn UI")
	m.free()


func test_client_bridge_filters_local_killer_and_placeholder_copy() -> void:
	var hud := GameHud.new()
	_tree().root.add_child(hud)
	var bridge := NetMatchBridge.new()
	bridge.local_player_id = 7
	hud.bind_kill_bridge(bridge)
	bridge.kill_event.emit(3, 8)
	assert_true(not hud.banner_label.visible, "other killer filtered")
	bridge.kill_event.emit(3, 7)
	assert_true(not hud.banner_label.visible, "own death filtered")
	bridge.kill_event.emit(7, 8)
	assert_true(hud.banner_label.visible, "local client kill visible")
	assert_true(bool(hud._banner_cfg["_placeholder"]), "copy/style remain placeholders")
	hud.free()
	bridge.free()


func test_late_roster_pawn_melee_kill_uses_existing_signals() -> void:
	var m := await _match()
	var victim: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	victim.squad_id = 1
	m.add_child(victim)
	victim.set_physics_process(false)
	victim.position = m.local_player.position + Vector3(0, 0, -1)
	m.director.add_player(999, victim)  # Added after HUD.bind; fired must discover it immediately.
	victim.bridge.spawn_protected = false
	victim.bridge.state.shield = 0.0
	victim.bridge.state.health = 1.0
	m.local_player.loadout.swap()
	var hit := m.local_player.fire_shot()
	assert_true(bool(hit.get("melee", false)), "real melee swing")
	assert_true(not victim.is_alive(), "late enemy killed")
	assert_true(m.hud.banner_label.visible, "melee kill banner")
	assert_eq(m.hud.banner_label.text, String(m.hud._banner_cfg["kill_text"]), "local kill copy")
	m.free()


func test_objective_banner_only_on_state_change() -> void:
	var m := await _match()
	m.local_player.position = Vector3(0, 0.1, 0)
	for i in 3:
		await _tree().physics_frame
	m.hud.refresh_pawn()
	assert_eq(m.hud.banner_label.text, String(m.hud._banner_cfg["secured_text"]), "hill secured")
	m.hud._tick_feedback(float(m.hud._banner_cfg["duration_s"]) + 0.1)
	m.director.score_changed.emit({0: 2, 1: 0})
	m.hud.refresh_pawn()
	assert_true(not m.hud.banner_label.visible, "score tick never repeats banner")
	var enemy := _enemy(m)
	enemy.position = Vector3(1, 0.1, 0)
	for i in 3:
		await _tree().physics_frame
	m.hud.refresh_pawn()
	assert_eq(m.hud.banner_label.text, String(m.hud._banner_cfg["contested_text"]), "contested transition")
	assert_true(m.hud.banner_label.visible, "contested banner visible")
	m.free()
