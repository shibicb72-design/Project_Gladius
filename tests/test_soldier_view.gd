extends "res://tests/test_case.gd"

func _screen_bounds(camera: Camera3D, transform: Transform3D, bounds: AABB) -> Rect2:
	var result := Rect2()
	for corner in 8:
		var point := camera.unproject_position(transform * bounds.get_endpoint(corner))
		result = Rect2(point, Vector2.ZERO) if corner == 0 else result.expand(point)
	return result


func test_own_arms_and_rifle_clear_crosshair_cpu_poses() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var previous_size := tree.root.size
	for size in [Vector2i(1512, 648), Vector2i(2520, 1080), Vector2i(1152, 959), Vector2i(2176, 1812)]:
		tree.root.size = size
		var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
		tree.root.add_child(pawn)
		pawn.set_physics_process(false)
		pawn.shot_fx.set_physics_process(false)
		var rig: CameraRig = load("res://scenes/player/camera_rig.tscn").instantiate()
		pawn.add_child(rig)
		assert_true(rig.ensure_current(), "own third-person camera current")
		var model := pawn.get_node("SoldierModel") as SoldierModel
		model.set_process(false)
		model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		var camera: Camera3D = tree.root.get_camera_3d()
		var pose_bounds: Array[AABB] = []
		pose_bounds.resize(model.part_bounds.size())
		for aim in [false, true]:
			rig.set_aim_blend(1.0 if aim else 0.0, float(pawn.registry.get_aim_cfg()["aim_fov_mult"]))
			await tree.physics_frame
			await tree.process_frame
			var minimum := INF
			var drift := {"idle": 0.0, "walk": 0.0, "fire": 0.0}
			for clip in ["idle", "walk", "fire"]:
				model.animation_tree.set("parameters/locomotion/blend_position", Vector2(0, -1) if clip == "walk" else Vector2.ZERO)
				if clip == "fire":
					pawn.show_shot_fx(pawn.get_muzzle_position(), Vector3(0, 1, -10))
				for sample in 9:
					var delta := 0.0 if sample == 0 else float(SoldierRig.config()["locomotion"]["walk_s"]) / 8.0 if clip != "fire" else float(pawn.shot_fx._cfg["viewmodel_recoil_recover_s"]) / 8.0
					model._update_recoil(delta)
					pawn.shot_fx._physics_process(delta)
					model.animation_tree.advance(delta)
					await tree.process_frame
					await tree.process_frame
					model.posed_bounds(pose_bounds)
					var rectangles: Array[Rect2] = [_screen_bounds(camera, model.rifle.global_transform, model.rifle.get_aabb())]
					for i in pose_bounds.size():
						var bone_name := String(model.skeleton.get_bone_name(model.part_bones[i]))
						if bone_name.contains("Arm") or bone_name.contains("Hand"):
							rectangles.append(_screen_bounds(camera, Transform3D.IDENTITY, pose_bounds[i]))
					var center := tree.root.get_visible_rect().get_center()
					for rect in rectangles:
						assert_true(not rect.has_point(center), "own posed arm/rifle avoids crosshair at %s aim=%s clip=%s rect=%s" % [size, aim, clip, rect])
						var nearest := center.clamp(rect.position, rect.end)
						minimum = minf(minimum, center.distance_to(nearest))
					var box := pawn.shot_fx.weapon_mesh
					var legacy_tip := box.global_transform * Vector3(0, 0, -(box.mesh as BoxMesh).size.z * 0.5)
					drift[clip] = maxf(float(drift[clip]), legacy_tip.distance_to(model.barrel_tip.global_position))
			print("RIG_VIEW ", size, " ads=", aim, " min_canvas_px_gap=", minimum, " screen_scale=", tree.root.get_screen_transform().get_scale(), " barrel_drift_m=", drift)
		pawn.free()
	tree.root.size = previous_size
