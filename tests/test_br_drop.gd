extends "res://tests/test_case.gd"
## M1 S3: drop from the sky. Everyone boards the carrier, humans drop with Jump, bots at a seeded moment,
## everyone left drops at the end of the path; falling pawns glide, cannot fire, and land.

const _MatchScene := preload("res://scenes/match/match.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame


## Short, low drop so the tests stay fast. Zone harmless.
func _drop_match(carrier_s: float = 2.0, altitude: float = 25.0) -> MatchRoot:  # call with await
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.seed_override = 777
	m.drop_from_sky = true
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	m.director.mode_cfg["zone"] = {"start_center": [0, 0], "start_radius_m": 5000.0, "damage_skips_shield": false,
			"phases": [{"wait_s": 1000.0, "shrink_s": 10.0, "radius_m": 2500.0, "damage_per_s": 0.0}]}
	var drop: Dictionary = m.director.mode_cfg["drop"]
	drop["carrier_s"] = carrier_s
	drop["altitude_m"] = altitude
	drop["path_length_m"] = 60.0
	drop["max_fall_mps"] = 20.0
	return m


func test_everyone_boards_the_carrier() -> void:
	var m := await _drop_match()
	assert_true(m.begin(), "begin")
	assert_true(m.director.drop_active, "drop running")
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		assert_eq(p.drop_state, Pawn.Drop.ABOARD, "player %d aboard" % id)
		assert_true(not p.visible and p.collision_layer == 0, "aboard pawns are hidden and not hittable")
		assert_true(absf(p.global_position.y - 25.0) < 0.01, "aboard at the carrier altitude")
	await _tree().process_frame
	m.hud.refresh_pawn()
	assert_eq(m.hud.downed_label.text, "Jump to drop", "HUD tells the player how to drop")
	var before := m.director.carrier_position()
	await _frames(10)
	assert_true(m.director.carrier_position().distance_to(before) > 0.5, "the carrier moves")
	assert_true(m.local_player.global_position.distance_to(m.director.carrier_position()) < 0.01, "riders move with it")
	m.queue_free()


func test_jump_drops_the_local_player() -> void:
	var m := await _drop_match(30.0)  # slow carrier: bots stay aboard for a while
	assert_true(m.begin(), "begin")
	await _frames(2)
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	await _frames(1)
	assert_eq(m.local_player.drop_state, Pawn.Drop.FALLING, "Jump (through the input layer) starts the fall")
	assert_true(m.local_player.visible, "visible while falling")
	m.queue_free()


func test_all_drop_and_land_and_cannot_fire_while_falling() -> void:
	var m := await _drop_match()
	assert_true(m.begin(), "begin")
	var bot: Pawn = m.bots[0]
	var brain := bot.get_node_or_null("Brain")
	if brain != null:
		brain.set_physics_process(false)
	var falling_seen := false
	for i in 900:
		await _tree().physics_frame
		if bot.drop_state == Pawn.Drop.FALLING and not falling_seen:
			falling_seen = true
			var w := bot.loadout.get_active()
			var ammo := w.ammo_in_mag if w != null else 0
			var f := InputFrame.new()
			f.fire_pressed = true
			f.fire_just_pressed = true
			bot.set_frame(f)
			await _tree().physics_frame
			assert_eq(w.ammo_in_mag if w != null else 0, ammo, "no shot while falling")
			bot.set_frame(InputFrame.new())
		var all_down := true
		for id in m.director.all_players():
			if m.director.player(id).is_dropping():
				all_down = false
		if all_down:
			break
	assert_true(falling_seen, "the bot fell")
	assert_true(not m.director.drop_active, "the carrier emptied")
	for id in m.director.all_players():
		var p: Pawn = m.director.player(id)
		assert_eq(p.drop_state, Pawn.Drop.NONE, "player %d landed" % id)
		# Landing on a wall top or roof is fine; the pawn must stand on something far below the carrier.
		assert_true(p.is_on_floor() and p.global_position.y < 10.0, "player %d stands on a floor (y %.2f)" % [id, p.global_position.y])
	m.queue_free()


func test_no_drop_without_opt_in() -> void:
	var m := await _drop_match()
	m.drop_from_sky = false
	assert_true(m.begin(), "begin")
	assert_true(not m.director.drop_active, "tests that do not opt in start on the ground")
	assert_eq(m.local_player.drop_state, Pawn.Drop.NONE, "local player on the ground")
	m.queue_free()


func test_real_drop_and_zone_numbers_stay_on_the_map() -> void:
	# The real br.json numbers (no test overrides): every carrier line and every zone circle lies on the
	# M1 map (data drop.map_half_m), for 200 seeds.
	var reg := DataRegistry.new()
	var cfg := ModeRegistry.merged_config(MatchDirector.MODE_ID, reg.load_file("res://data/modes.json"))
	var half := float(cfg["drop"]["map_half_m"])
	for s in 200:
		var rng := RandomNumberGenerator.new()
		rng.seed = s
		for p in MatchDirector.carrier_path(cfg, rng):
			assert_true(absf(p.x) <= half and absf(p.z) <= half, "seed %d: carrier point %s on the map" % [s, p])
		var rules := ModeRegistry.create(MatchDirector.MODE_ID, {MatchDirector.MODE_ID: cfg}) as BrRules
		rules.set_seed(s)
		for i in rules.phase_count():
			var c: Dictionary = rules.phase_circle(i)
			var center: Vector2 = c["center"]
			assert_true(center.length() + float(c["radius"]) <= half + 1e-3, "seed %d: circle %d on the map" % [s, i])
			assert_true(absf(center.x) <= half and absf(center.y) <= half, "seed %d: circle %d center on the ground" % [s, i])


func test_a_pawn_below_the_map_is_caught() -> void:
	var m := await _drop_match()
	m.drop_from_sky = false
	assert_true(m.begin(), "begin")
	var bot: Pawn = m.bots[0]
	bot.get_node("Brain").set_physics_process(false)
	bot.global_position = Vector3(500.0, -20.0, -500.0)
	await _frames(2)
	var half := float(m.director.mode_cfg["drop"]["map_half_m"])
	assert_true(bot.global_position.y > -5.0, "lifted back up")
	assert_true(absf(bot.global_position.x) <= half and absf(bot.global_position.z) <= half, "back on the map")
	m.queue_free()
