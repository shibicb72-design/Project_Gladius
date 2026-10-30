extends "res://tests/test_case.gd"

const MAP = preload("res://assets/anim/soldier_bone_map.tres")

func _target() -> Skeleton3D:
	return SoldierRig.build(LowpolyKit.config()["soldier"]["parts"], Vector3(0, 1.75, 0))

func _source(target: Skeleton3D) -> Skeleton3D:
	var source := Skeleton3D.new()
	var turn := Basis(Vector3.UP, PI)
	var global: Array[Transform3D] = []
	for i in target.get_bone_count():
		var name := String(target.get_bone_name(i)).replace("ForeArm", "LowerArm")
		source.add_bone(name)
		var parent := target.get_bone_parent(i)
		# Source has a conventional connected neck, unlike the target's two roots.
		if name == "Neck":
			parent = target.find_bone("Chest")
		source.set_bone_parent(i, parent)
		var origin := turn * target.get_bone_global_rest(i).origin
		for side in ["Left", "Right"]:
			var root := turn * target.get_bone_global_rest(target.find_bone(side + "UpperArm")).origin
			var sign := 1.0 if side == "Left" else -1.0
			if name == side + "LowerArm":
				origin = root + Vector3.RIGHT * sign * 0.3
			elif name == side + "Hand":
				origin = root + Vector3.RIGHT * sign * 0.55
		var rest := Transform3D(Basis(Vector3.UP, 0.13 * (i + 1)), origin)
		global.append(rest)
		source.set_bone_rest(i, rest if parent < 0 else global[parent].affine_inverse() * rest)
	source.reset_bone_poses()
	return source

func _pose(source: Skeleton3D, down: bool, thigh: bool = false) -> Animation:
	var clip := Animation.new()
	var global: Array[Quaternion] = []
	for i in source.get_bone_count():
		var name := String(source.get_bone_name(i))
		var rest := source.get_bone_global_rest(i).basis.get_rotation_quaternion()
		var rotation := rest
		if down and (name.contains("Arm") or name.ends_with("Hand")):
			var direction := Vector3.RIGHT if name.begins_with("Left") else Vector3.LEFT
			rotation = Quaternion(direction, Vector3.DOWN) * rest
		if thigh and name == "LeftUpperLeg":
			rotation = Quaternion(Vector3.LEFT, deg_to_rad(30.0)) * rest
		global.append(rotation)
		var parent := source.get_bone_parent(i)
		var local := rotation if parent < 0 else global[parent].inverse() * rotation
		var track := clip.add_track(Animation.TYPE_ROTATION_3D)
		clip.track_set_path(track, NodePath("%GeneralSkeleton:" + name))
		clip.rotation_track_insert_key(track, 0.0, local)
	if thigh:
		var position := clip.add_track(Animation.TYPE_POSITION_3D)
		clip.track_set_path(position, NodePath("%GeneralSkeleton:Hips"))
		clip.position_track_insert_key(position, 0.0, source.get_bone_rest(source.find_bone("Hips")).origin + Vector3(3, 0.2, 4))
	return clip

func test_target_bone_map_and_native_capability() -> void:
	var target := _target()
	assert_true(MAP.profile is SkeletonProfileHumanoid, "humanoid profile")
	var count := 0
	for i in MAP.profile.bone_size:
		var profile := MAP.profile.get_bone_name(i)
		var bone := MAP.get_skeleton_bone_name(profile)
		if not String(bone).is_empty():
			count += 1
			assert_true(target.find_bone(bone) >= 0, "mapped target bone " + bone)
	assert_eq(count, 17, "all existing bones mapped without renaming")
	assert_eq(String(MAP.get_skeleton_bone_name(&"LeftLowerArm")), "LeftForeArm", "left forearm mapping")
	assert_eq(String(MAP.get_skeleton_bone_name(&"RightLowerArm")), "RightForeArm", "right forearm mapping")
	assert_eq(MAP.profile.find_bone(&"LeftForeArm"), -1, "source profile uses LowerArm")
	# A connected source can have ankle pivots behind Hips while its toes point forward.
	var source := _source(target)
	for side in ["Left", "Right"]:
		var foot := source.find_bone(side + "Foot")
		var ankle := source.get_bone_global_rest(foot)
		ankle.origin.z = -0.3
		source.set_bone_rest(foot, source.get_bone_global_rest(source.get_bone_parent(foot)).affine_inverse() * ankle)
		var toes := source.add_bone(side + "Toes")
		source.set_bone_parent(toes, foot)
		var desired := source.get_bone_global_rest(foot)
		desired.origin.z = 0.3
		source.set_bone_rest(toes, source.get_bone_global_rest(foot).affine_inverse() * desired)
	var change := AnimRetarget.basis_change(source, target)
	assert_true(change.get("valid", false), "toe-based source heading")
	if change.get("valid", false):
		assert_true(((change["rotation"] as Quaternion) * Vector3.BACK).distance_to(Vector3.FORWARD) < 0.0001, "source toes determine front")
	source.free()
	print("RETARGET native_modifier=", ClassDB.class_exists(&"RetargetModifier3D"), "; UAL map/import validation deferred: archive not acquired")
	target.free()

func test_nonidentity_t_pose_rest_maps_to_source_directions() -> void:
	var target := _target()
	var source := _source(target)
	var clip := _pose(source, false)
	var baked := AnimRetarget.bake(clip, source, target)
	assert_true(baked != null, "synthetic source bakes")
	if baked != null:
		var poses := AnimRetarget.sample_globals(baked, target, 0.0)
		var change := AnimRetarget.basis_change(source, target)
		var rotation: Quaternion = change["rotation"]
		assert_true((rotation * Vector3.BACK).distance_to(Vector3.FORWARD) < 0.0001, "+Z source becomes -Z target")
		for parent in ["Hips", "Spine", "Neck", "LeftUpperArm", "LeftLowerArm", "RightUpperArm", "RightLowerArm", "LeftUpperLeg", "LeftLowerLeg", "RightUpperLeg", "RightLowerLeg"]:
			var source_index := source.find_bone(parent)
			var target_index := target.find_bone(MAP.get_skeleton_bone_name(parent))
			var children: Array[int] = []
			for child in target.get_bone_count():
				if target.get_bone_parent(child) == target_index:
					children.append(child)
			if children.size() != 1:
				continue
			var child := children[0]
			var profile_child := String(target.get_bone_name(child)).replace("ForeArm", "LowerArm")
			var expected := rotation * (source.get_bone_global_rest(source.find_bone(profile_child)).origin - source.get_bone_global_rest(source_index).origin).normalized()
			var actual := (poses[child].origin - poses[target_index].origin).normalized()
			assert_true(rad_to_deg(actual.angle_to(expected)) < 2.0, "rest direction " + parent)
		print("RETARGET synthetic R=", rotation, " source rest=T pose with nonidentity bases; target rest=arms down")
	source.free()
	target.free()

func test_arms_down_and_forward_thigh_preserve_direction_and_in_place() -> void:
	var target := _target()
	var source := _source(target)
	var clip := _pose(source, true, true)
	var baked := AnimRetarget.bake(clip, source, target)
	assert_true(baked != null, "posed source bakes")
	if baked != null:
		var poses := AnimRetarget.sample_globals(baked, target, 0.0)
		for side in ["Left", "Right"]:
			for pair in [["UpperArm", "ForeArm"], ["ForeArm", "Hand"]]:
				var direction := poses[target.find_bone(side + pair[1])].origin - poses[target.find_bone(side + pair[0])].origin
				assert_true(rad_to_deg(direction.angle_to(Vector3.DOWN)) < 2.0, "arms down " + side + pair[0])
		var hip := target.find_bone("LeftUpperLeg")
		var knee := target.find_bone("LeftLowerLeg")
		var before := target.get_bone_global_rest(knee).origin - target.get_bone_global_rest(hip).origin
		var after := poses[knee].origin - poses[hip].origin
		assert_true(after.z < before.z, "left knee moves toward target -Z")
		assert_true(absf(rad_to_deg(before.angle_to(after)) - 30.0) < 2.0, "thigh rotates 30 degrees")
		var hips := target.find_bone("Hips")
		assert_true(Vector2(poses[hips].origin.x, poses[hips].origin.z).distance_to(Vector2(target.get_bone_global_rest(hips).origin.x, target.get_bone_global_rest(hips).origin.z)) < 0.0001, "in place Hips")
		var scale := target.get_bone_global_rest(hips).origin.y / source.get_bone_global_rest(source.find_bone("Hips")).origin.y
		assert_true(absf(poses[hips].origin.y - target.get_bone_global_rest(hips).origin.y - 0.2 * scale) < 0.0001, "Hips vertical displacement scaled once")
		assert_eq(AnimRetarget.bake(clip, source, target), baked, "static bake cache")
	source.free()
	target.free()
