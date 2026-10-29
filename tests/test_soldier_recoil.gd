extends "res://tests/test_case.gd"

func test_visual_shot_kicks_own_bot_replica_and_ignores_melee() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var match_scene: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	match_scene.auto_start = false
	match_scene.bake_navmesh = false
	tree.root.add_child(match_scene)
	await tree.physics_frame
	assert_true(match_scene.begin(), "real bot roster starts")
	match_scene.set_physics_process(false)
	match_scene.director.running = false
	for pawn: Pawn in match_scene.director.all_players().values():
		pawn.set_physics_process(false)
		if pawn.has_node("Brain"):
			pawn.get_node("Brain").set_physics_process(false)
	var replica: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	match_scene.add_child(replica)
	replica.net_mode = Pawn.NetMode.REPLICA
	replica.set_physics_process(false)
	await tree.process_frame
	await tree.process_frame
	for pawn: Pawn in [match_scene.local_player, match_scene.bots[0], replica]:
		var model := pawn.get_node("SoldierModel") as SoldierModel
		model.set_process(false)
		model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		var fired := [0]
		pawn.fired.connect(func() -> void: fired[0] += 1)
		pawn.show_shot_fx(pawn.get_muzzle_position(), pawn.global_position + Vector3(0, 1, -10))
		assert_eq(fired[0], 0, "recoil doesn't depend on fired (including replica)")
		assert_true(model.recoil_left_s > 0.0 and model.rifle.position.distance_to(model._rifle_rest.origin) > 0.0, "same flash-frame rifle kick")
		assert_true(model.rifle.rotation.x > 0.0, "muzzle tilts up")
		var maximum := 0.0
		for sample in 9:
			model._update_recoil(0.0 if sample == 0 else model._recoil_recover_s / 8.0)
			model.animation_tree.advance(0.0 if sample == 0 else model._recoil_recover_s / 8.0)
			await tree.process_frame
			await tree.process_frame
			maximum = maxf(maximum, model.hand_error_m)
			var shell := (pawn.get_node("Head") as Node3D).global_transform * (pawn.get_node("Head/HeadMesh") as MeshInstance3D).get_aabb().grow(0.02)
			assert_true(not shell.intersects(model.rifle.global_transform * model.rifle.get_aabb()), "kicked rifle clear of shell")
		assert_true(model.rifle.transform.is_equal_approx(model._rifle_rest), "rifle recovers to rest")
		assert_true(maximum <= float(SoldierRig.config()["hands"]["ik_tolerance_m"]), "IK follows recoil, max=" + str(maximum))
		print("RIG_RECOIL role=", "replica" if pawn == replica else "own" if pawn == match_scene.local_player else "bot", " max_hand_error_m=", maximum)
		pawn.loadout.swap()
		pawn.fire_shot()
		assert_eq(model.recoil_left_s, 0.0, "blade does not recoil")
	match_scene.free()


func test_semi_and_auto_every_round_starts_model_recoil() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	for mode in ["semi", "auto"]:
		var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
		tree.root.add_child(pawn)
		pawn.set_physics_process(false)
		var model := pawn.get_node("SoldierModel") as SoldierModel
		model.set_process(false)
		var weapon := pawn.loadout.get_active()
		weapon.fire_mode = mode
		var fired := [0]
		pawn.fired.connect(func() -> void: fired[0] += 1)
		var rounds := 0
		for tick in 300:
			model._update_recoil(model._recoil_recover_s)
			pawn._clock = tick / float(Engine.physics_ticks_per_second)
			var frame := InputFrame.new()
			frame.fire_pressed = mode == "auto" or tick % 2 == 0
			frame.fire_just_pressed = frame.fire_pressed and (mode == "semi" or tick == 0)
			pawn.set_frame(frame)
			var ammo := weapon.ammo_in_mag
			pawn._apply_weapon()
			if weapon.ammo_in_mag < ammo:
				assert_true(model.recoil_left_s > 0.0, "%s round %s recoil" % [mode, rounds])
				assert_eq(model.animation_tree.get("parameters/fire/request"), AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE, "every round requests upper-body fire")
				rounds += 1
			if rounds == 10:
				break
		assert_eq(rounds, 10, "ten model kicks in " + mode)
		assert_eq(fired[0], rounds, "every semi/auto round emits fired")
		pawn.free()
