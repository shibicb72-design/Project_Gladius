extends "res://tests/test_case.gd"

func test_velocity_directions_sprint_and_position_only_replicas() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var speed := pawn.get_move_speed()
	for v in [Vector3.ZERO, Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD * pawn.get_max_move_speed() / speed]:
		pawn.velocity = v * speed
		model._process(0.1)
		var blend: Vector2 = model.animation_tree.get("parameters/locomotion/blend_position")
		assert_true(blend.is_equal_approx(Vector2(v.x, v.z)), "velocity blend follows " + str(v))
	pawn.rotation.y = PI * 0.5
	pawn.velocity = pawn.global_transform.basis * Vector3.FORWARD * speed
	model._process(0.1)
	assert_true((model.animation_tree.get("parameters/locomotion/blend_position") as Vector2).is_equal_approx(Vector2(0, -1)), "pawn-local direction")
	pawn.rotation.y = 0.0
	pawn.velocity = Vector3.ZERO
	pawn.net_mode = Pawn.NetMode.REPLICA
	for i in 20:
		pawn.global_position += Vector3.FORWARD * speed * 0.1
		model._process(0.1)
	var observed: Vector2 = model.animation_tree.get("parameters/locomotion/blend_position")
	assert_true(observed.distance_to(Vector2(0, -1)) < 0.001, "position-only replica walks")
	for i in 20:
		model._process(0.1)
	assert_true((model.animation_tree.get("parameters/locomotion/blend_position") as Vector2).length() < 0.001, "stationary replica settles to idle")
	assert_eq(model.transform, Transform3D.IDENTITY, "no whole-body sway")
	pawn.free()


func test_tree_leg_cycle_runs_when_advanced_without_frame_time() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var animation := model.animation_tree
	assert_true(animation.active and animation is AnimationMixer, "active mixer")
	assert_eq(animation.callback_mode_process, AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE, "runtime idle mode")
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	animation.set("parameters/locomotion/blend_position", Vector2(0, -1))
	animation.advance(0.0)
	animation.advance(float(SoldierRig.config()["locomotion"]["walk_s"]) * 0.25)
	await model.skeleton.skeleton_updated
	var leg := model.skeleton.find_bone("LeftUpperLeg")
	assert_true(model.skeleton.get_bone_pose_rotation(leg).angle_to(Quaternion.IDENTITY) > 0.1, "tree actually changes leg pose")
	for name in ["idle", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd"]:
		assert_true(animation.has_animation(name), "swappable clip " + name)
	pawn.queue_free()
	await tree.process_frame
