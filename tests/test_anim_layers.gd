extends "res://tests/test_case.gd"

func test_lower_stand_keeps_live_locomotion_paths_and_replica_ground_state() -> void:
	var scene: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	scene.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var tree := model.animation_tree
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var graph := tree.tree_root as AnimationNodeBlendTree
	assert_true(graph.get_node(&"locomotion") is AnimationNodeBlendSpace2D, "root blend space stays live")
	var lower := graph.get_node(&"lower") as AnimationNodeTransition
	assert_true(lower != null, "lower transition exists")
	if lower != null:
		assert_eq(lower.input_count, 1, "only stand: no acquired airborne source")
		assert_eq(lower.get_input_name(0), "stand", "stand input name")
	var links: Array = graph.get("node_connections")
	assert_true(_connection(links, "lower", 0, "locomotion"), "stand receives original blend space")
	assert_true(_connection(links, "upper", 0, "lower"), "lower replaces previous upper input")
	for mode in [Pawn.NetMode.LOCAL, Pawn.NetMode.REPLICA, Pawn.NetMode.HOST_REMOTE]:
		pawn.net_mode = mode
		for speed in [pawn.get_move_speed(), pawn.get_max_move_speed()]:
			pawn.velocity = Vector3.FORWARD * speed
			model._process(0.1)
			tree.advance(0.0)
			assert_eq(String(tree.get("parameters/lower/current_state")), "stand", "stand for simulated and observed roles")
			assert_true((tree.get("parameters/locomotion/blend_position") as Vector2).is_equal_approx(Vector2(0, -speed / pawn.get_move_speed())), "unmodified speed blend")
	for path in ["locomotion/blend_position", "aim/blend_position", "upper/blend_amount", "fire/request", "fire/active", "reload/request", "reload/active"]:
		assert_true(tree.get("parameters/" + path) != null, "KEEP path " + path)
	pawn.velocity = Vector3.ZERO
	model._process(0.1)
	tree.advance(0.0)
	assert_eq(String(tree.get("parameters/lower/current_state")), "stand", "flat stationary replica does not enter air")
	print("ANIM_GRAPH root connections=", links, "; lower inputs=[stand]")
	pawn.free()

func _connection(links: Array, to: String, input: int, from: String) -> bool:
	for i in range(0, links.size(), 3):
		if String(links[i]) == to and int(links[i + 1]) == input and String(links[i + 2]) == from:
			return true
	return false

func test_upper_filters_modifier_order_fire_reload_and_both_layer_directions() -> void:
	var scene: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	scene.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var tree := model.animation_tree
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var graph := tree.tree_root as AnimationNodeBlendTree
	for node in ["upper", "fire", "reload"]:
		var layer := graph.get_node(node)
		assert_true(layer.filter_enabled, node + " filter enabled")
		for i in model.skeleton.get_bone_count():
			var bone := String(model.skeleton.get_bone_name(i))
			var lower := bone == "Hips" or bone.contains("Leg") or bone.contains("Foot")
			assert_eq(layer.is_path_filtered(NodePath("Skeleton3D:" + bone)), not lower, node + " bone " + bone)
	var sync := model.skeleton.get_node("HandTargetSync")
	assert_true(sync.get_index() < model.left_ik.get_index(), "hand target sync before IK")
	for child in model.skeleton.get_children():
		if child is SkeletonModifier3D and child != sync and child != model.left_ik:
			assert_true(child.get_index() < sync.get_index(), "any other modifier precedes hand sync")
	tree.set("parameters/locomotion/blend_position", Vector2(0, -1))
	tree.advance(0.0)
	tree.advance(float(SoldierRig.config()["locomotion"]["walk_s"]) * 0.25)
	await scene.process_frame
	await scene.process_frame
	var leg := model.skeleton.find_bone("LeftUpperLeg")
	var leg_pose := model.skeleton.get_bone_pose_rotation(leg)
	var arm := model.skeleton.find_bone("RightUpperArm")
	var arm_pose := model.skeleton.get_bone_pose_rotation(arm)
	assert_true(leg_pose.angle_to(Quaternion.IDENTITY) > 0.1, "lower body locomotion remains live under upper layer")
	tree.set("parameters/locomotion/blend_position", Vector2.ZERO)
	tree.advance(0.0)
	await scene.process_frame
	await scene.process_frame
	assert_true(model.skeleton.get_bone_pose_rotation(arm).angle_to(arm_pose) < 0.0001, "lower idle cannot displace aimed upper arm")
	pawn.show_shot_fx(pawn.get_muzzle_position(), Vector3(0, 1, -10))
	assert_eq(tree.get("parameters/fire/request"), AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE, "visual shot requests fire")
	assert_true(model.recoil_left_s > 0.0, "rifle recoil still runs")
	tree.advance(0.0)
	await scene.process_frame
	await scene.process_frame
	assert_true(model.skeleton.get_bone_pose_rotation(leg).angle_to(Quaternion.IDENTITY) < 0.0001, "upper fire does not move idle leg")
	pawn.reload_started.emit()
	tree.advance(0.0)
	assert_true(tree.get("parameters/reload/active"), "reload starts")
	assert_eq(tree.get_animation(&"reload").length, pawn.loadout.get_active().def.reload_s, "reload swap remains weapon-timed")
	pawn.weapon_switched.emit(1)
	tree.advance(0.0)
	assert_true(not tree.get("parameters/reload/active") and not tree.get("parameters/fire/active"), "switch aborts both shots")
	assert_true(model.hand_error_m <= float(SoldierRig.config()["hands"]["ik_tolerance_m"]), "foregrip stays solved")
	var clips := tree.get_meta(&"clip_library") as ClipLibrary
	for name in ["idle", "walk_fwd", "walk_back", "strafe_l", "strafe_r", "run_fwd", "aim_down", "aim", "aim_up", "fire", "reload"]:
		assert_eq(clips.source_for(name), "procedural", "honest default source " + name)
	pawn.free()

func test_shared_library_clip_timing_and_additive_conversion() -> void:
	var clip := Animation.new()
	clip.length = 1.0
	var track := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(track, NodePath("Skeleton3D:Chest"))
	clip.rotation_track_insert_key(track, 0.0, Quaternion(Vector3.RIGHT, 0.4))
	clip.rotation_track_insert_key(track, 1.0, Quaternion(Vector3.RIGHT, 0.6))
	var fire := ClipLibrary.fit(clip, 2.0, Animation.LOOP_NONE, true)
	assert_true(fire.rotation_track_interpolate(track, 0.0).angle_to(Quaternion.IDENTITY) < 0.0001, "fire starts as a delta")
	assert_true(fire.rotation_track_interpolate(track, 2.0).angle_to(Quaternion(Vector3.RIGHT, 0.2)) < 0.0001, "fire adds change from first frame")
	assert_eq(fire.track_get_key_time(track, 1), 2.0, "expanded timing")
	var reload := ClipLibrary.fit(clip, 0.5, Animation.LOOP_NONE)
	assert_eq(reload.track_get_key_time(track, 1), 0.5, "compressed timing")
	assert_eq(reload.length, 0.5, "weapon duration can be applied at each reload")
	assert_eq(clip.length, 1.0, "cached clip not modified")
	assert_true(clip.rotation_track_interpolate(track, 0.0).angle_to(Quaternion(Vector3.RIGHT, 0.4)) < 0.0001, "cached absolute pose not modified")
