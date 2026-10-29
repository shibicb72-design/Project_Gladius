extends "res://tests/test_case.gd"

func test_aim_fire_reload_and_cancel_use_the_animation_tree() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var animation := model.animation_tree
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	animation.advance(0.0)
	await tree.process_frame
	await tree.process_frame
	assert_true(model.skeleton.get_bone_pose_rotation(model.skeleton.find_bone("RightUpperArm")).angle_to(Quaternion.IDENTITY) > 0.1, "aim shoulders the arms")
	pawn.pitch = 1.0
	model._process(0.01)
	assert_eq(animation.get("parameters/aim/blend_position"), 1.0, "read-only pitch clamped for shell clearance")
	pawn.show_shot_fx(pawn.get_muzzle_position(), Vector3(0, 1, -10))
	assert_eq(animation.get("parameters/fire/request"), AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE, "per-shot visual hook triggers fire")
	animation.advance(0.01)
	assert_true(animation.get("parameters/fire/active"), "fire OneShot active")
	pawn.reload_started.emit()
	var weapon := pawn.loadout.get_active()
	assert_eq(model.reload_duration_s, weapon.def.reload_s, "runtime WeaponDef duration")
	assert_eq(animation.get_animation(&"reload").length, weapon.def.reload_s, "reload clip length from weapon data")
	animation.advance(0.0)
	animation.advance(weapon.def.reload_s * 0.5)
	assert_true(animation.get("parameters/reload/active"), "reload at half duration")
	animation.advance(weapon.def.reload_s)
	assert_true(not animation.get("parameters/reload/active"), "reload ends at its weapon duration")
	pawn.reload_started.emit()
	animation.advance(0.0)
	pawn.weapon_switched.emit(1)
	animation.advance(0.0)
	assert_true(not animation.get("parameters/reload/active"), "swap cancels reload")
	pawn.reload_started.emit()
	animation.advance(0.0)
	pawn.set_active(false)
	animation.advance(0.0)
	assert_true(not animation.get("parameters/reload/active"), "death cancels reload")
	pawn.free()


func test_cpu_upper_body_bounds_clear_fixed_shell_across_clips() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var animation := model.animation_tree
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var bounds: Array[AABB] = []
	bounds.resize(model.part_bounds.size())
	model.posed_bounds(bounds)
	model.skeleton.skeleton_updated.connect(model.posed_bounds.bind(bounds))
	var shell := (pawn.get_node("Head") as Node3D).global_transform * (pawn.get_node("Head/HeadMesh") as MeshInstance3D).get_aabb().grow(0.02)
	for pitch in [-1.0, 0.0, 1.0]:
		animation.set("parameters/aim/blend_position", pitch)
		for action in ["aim", "fire", "reload"]:
			if action == "fire":
				pawn.show_shot_fx(pawn.get_muzzle_position(), Vector3(0, 1, -10))
			elif action == "reload":
				pawn.reload_started.emit()
			for sample in 20:
				animation.advance(0.05)
				await tree.process_frame
				await tree.process_frame
				for i in bounds.size():
					if shell.intersects(bounds[i]):
						assert_true(false, "CPU %s %s pitch=%s sample=%s box=%s shell=%s" % [action, model.get_meta("parts")[i], pitch, sample, bounds[i], shell])
						pawn.free()
						return
	pawn.free()


func test_engine_two_bone_capability_probe() -> void:
	var found: Array[String] = []
	for name in ClassDB.get_class_list():
		if String(name).contains("TwoBone") and String(name).ends_with("3D"):
			found.append(String(name))
	print("RIG_IK_CLASSDB ", found)
	for name in found:
		assert_true(ClassDB.is_parent_class(name, "SkeletonModifier3D"), "built-in solver uses modifier pipeline")
