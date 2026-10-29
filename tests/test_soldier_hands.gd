extends "res://tests/test_case.gd"

func test_modifier_api_available_in_project_binary() -> void:
	assert_true(ClassDB.class_exists("TwoBoneIK3D"), "built-in two-bone solver available")
	var callback := false
	for item in ClassDB.class_get_method_list("SkeletonModifier3D", true):
		callback = callback or item["name"] == "_process_modification_with_delta"
	assert_true(callback, "delta modifier callback verified")


func test_rifle_attachment_and_left_hand_ik_across_motion() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	assert_true(model.rifle.get_parent() is BoneAttachment3D, "rifle is attached to a bone")
	assert_eq(model.hand_attachment.bone_name, &"RightHand", "right hand owns rifle")
	assert_true(model.left_ik is SkeletonModifier3D and model.left_ik.get_parent() == model.skeleton, "native IK in modifier pipeline")
	var maximum := 0.0
	var stock_gap := 0.0
	var stock_point := Vector3.ZERO
	for part: Dictionary in LowpolyKit.config()["rifle"]["parts"]:
		if part["name"] == "stock":
			stock_point = LowpolyKit.vec(part["at"]) + Vector3.BACK * float(part["size"][2]) * 0.5
	for pose in [Vector2.ZERO, Vector2(0, -1), Vector2(0, -pawn.get_max_move_speed() / pawn.get_move_speed())]:
		model.animation_tree.set("parameters/locomotion/blend_position", pose)
		for pitch in [-1.0, 0.0, 1.0]:
			model.animation_tree.set("parameters/aim/blend_position", pitch)
			for sample in 8:
				model.animation_tree.advance(0.05)
				await tree.process_frame
				await tree.process_frame
				maximum = maxf(maximum, model.hand_error_m)
				assert_true(model.hand_error_m <= float(SoldierRig.config()["hands"]["ik_tolerance_m"]), "left hand reaches rifle grip, error=" + str(model.hand_error_m))
				var shoulder := (model.skeleton.global_transform * model.pose_cache[model.skeleton.find_bone("RightUpperArm")]).origin
				stock_gap = maxf(stock_gap, shoulder.distance_to(model.rifle.global_transform * stock_point))
				assert_true(stock_gap <= float(SoldierRig.config()["hands"]["stock_shoulder_tolerance_m"]), "stock rests near visual shoulder")
	print("RIG_IK max_hand_error_m=", maximum)
	print("RIG_STOCK max_shoulder_gap_m=", stock_gap)
	# The hand-held origin fails the locked tracer visibility floor. Keep legacy FX origin per launch brief.
	var box := pawn.shot_fx.weapon_mesh
	var legacy_tip := box.global_transform * Vector3(0, 0, -(box.mesh as BoxMesh).size.z * 0.5)
	pawn.show_shot_fx(pawn.get_muzzle_position(), Vector3(0, 1, -10))
	assert_true(pawn.shot_fx.flash.global_position.is_equal_approx(legacy_tip), "flash keeps legacy visual origin")
	assert_true(pawn.shot_fx.get_tracer_endpoints()[0].is_equal_approx(legacy_tip), "tracer keeps legacy visual origin")
	print("RIG_BARREL legacy_to_handheld_m=", legacy_tip.distance_to(model.barrel_tip.global_position))
	pawn.free()
