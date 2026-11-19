extends "res://tests/test_case.gd"
## The yaw changes without translating the pawn. Count heel and toe drift through
## each actual ground contact on the posed mesh, including starts and reversals.

const DT := 1.0 / 60.0
const SETTLE_FRAMES := 20
## Just over the pivot's idle_speed_mps: the release happens while the locomotion blend is still near idle.
const WALK_OFF_MPS := 0.2


func test_stationary_turn_plants_the_feet_and_holds_the_head() -> void:
	for reversing in [false, true]:
		await _measure_turn(reversing)


func _measure_turn(reversing: bool) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var skeleton := model.skeleton
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var neck := skeleton.find_bone("Neck")
	var chest := skeleton.find_bone("Chest")
	var helmet := skeleton.find_bone("Head")
	var neck_offset := skeleton.get_bone_global_rest(chest).affine_inverse() * skeleton.get_bone_global_rest(neck)
	var hitbox := pawn.get_node("Head") as Node3D
	var soles := SoldierClips.sole_points(skeleton)
	var samples: Array[PackedVector3Array] = []
	var floor_y := INF
	var gap := 0.0
	var angle := 0.0
	var rate := 0.0
	var helmet_off := 0.0
	var previous := Quaternion.IDENTITY
	for frame in 200:
		var t := clampf((frame - SETTLE_FRAMES) * DT, 0.0, 2.5)
		pawn.rotation.y = deg_to_rad(90.0 * sin(TAU * t / 1.5) if reversing else 120.0 * t)
		model._process(DT)
		model.animation_tree.advance(DT)
		skeleton.advance(DT)
		await tree.process_frame
		# Initialize the live animation tree before timing the first stance.
		if frame < SETTLE_FRAMES:
			continue
		var points := PackedVector3Array()
		for point in SoldierClips.contacts(model.pose_cache, soles):
			var at := skeleton.to_global(point)
			points.append(at)
			floor_y = minf(floor_y, at.y)
		samples.append(points)
		var chest_pose := model.pose_cache[chest]
		var neck_pose := model.pose_cache[neck]
		var relative := chest_pose.basis.get_rotation_quaternion().inverse() * neck_pose.basis.get_rotation_quaternion()
		angle = maxf(angle, rad_to_deg(Quaternion.IDENTITY.angle_to(relative)))
		if frame > SETTLE_FRAMES:
			rate = maxf(rate, rad_to_deg(previous.angle_to(relative)) / DT)
		previous = relative
		gap = maxf(gap, neck_pose.origin.distance_to((chest_pose * neck_offset).origin))
		helmet_off = maxf(helmet_off, skeleton.to_global(model.pose_cache[helmet].origin).distance_to(hitbox.global_position))
	var gait: Dictionary = SoldierRig.config()["gait"]
	var band := float(gait["contact_height_m"])
	var contact := _measure_contacts(samples, floor_y + band)
	var highest_support := -INF
	for points in samples:
		highest_support = maxf(highest_support, minf(minf(points[0].y, points[1].y), minf(points[2].y, points[3].y)))
	var limits: Dictionary = SoldierRig.head_cfg()["limits"]
	var label := "reversing" if reversing else "steady"
	print("PIVOT %s stance_drift_m=%.4f contacts=%d support_m=%.4f gap_m=%.4f neck_deg=%.2f neck_rate_dps=%.1f helmet_off_m=%.4f" %
		[label, contact.x, int(contact.y), highest_support, gap, angle, rate, helmet_off])
	assert_true(contact.y >= 12.0, "%s: both boots step more than once" % label)
	assert_true(contact.x <= float(gait["foot_slide_max_m"]), "%s: the grounded foot stays planted" % label)
	assert_true(highest_support <= floor_y + band, "%s: one boot supports every frame" % label)
	assert_true(gap <= float(limits["gap_max_m"]), "%s: neck gap remains within the upright limit" % label)
	assert_true(angle <= float(limits["neck_chest_max_deg"]), "%s: neck angle remains within the upright limit" % label)
	assert_true(rate <= float(limits["neck_chest_rate_max_dps"]), "%s: neck rate remains within the upright limit" % label)
	assert_true(helmet_off <= float(limits["helmet_tolerance_m"]), "%s: helmet stays on the hitbox" % label)
	pawn.free()


## Walking off a planted turn hands the feet back to the clip without a one-frame pop. The control walks off from
## a still stance (no turn), so it holds only the clip's own walk-start motion.
func test_walking_off_a_turn_hands_the_feet_back_without_a_pop() -> void:
	var control := await _walk_off_step(false)
	var turned := await _walk_off_step(true)
	print("PIVOT walk_off max_foot_step_m turned=%.4f control=%.4f" % [turned, control])
	assert_true(turned <= control + 0.015, "walking off a turn moves each foot no more per frame than a still start, plus 1.5 cm")


func _walk_off_step(turn_first: bool) -> float:
	var tree := Engine.get_main_loop() as SceneTree
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(pawn)
	pawn.set_physics_process(false)
	var model := pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var skeleton := model.skeleton
	model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var feet := [skeleton.find_bone("LeftFoot"), skeleton.find_bone("RightFoot")]
	var start := SETTLE_FRAMES + 50  # the turn stops mid-stride and the walk starts on the same frame
	var previous: Array = []
	var worst := 0.0
	for frame in start + 15:
		if frame >= start:
			var forward := -pawn.global_transform.basis.z
			pawn.velocity = forward * WALK_OFF_MPS
			pawn.global_position += pawn.velocity * DT
		elif turn_first:
			pawn.rotation.y = deg_to_rad(120.0 * clampf((frame - SETTLE_FRAMES) * DT, 0.0, 2.5))
		model._process(DT)
		model.animation_tree.advance(DT)
		skeleton.advance(DT)
		await tree.process_frame
		var at: Array = [model.pose_cache[feet[0]].origin, model.pose_cache[feet[1]].origin]
		if frame >= start and not previous.is_empty():
			for side in 2:
				worst = maxf(worst, (at[side] as Vector3).distance_to(previous[side]))
		previous = at
	pawn.free()
	return worst


static func _measure_contacts(samples: Array[PackedVector3Array], contact_y: float) -> Vector2:
	var worst := 0.0
	var contacts := 0
	for point in 4:
		var start := Vector2.ZERO
		var frames := 0
		var distance := 0.0
		for i in samples.size() + 1:
			if i < samples.size() and samples[i][point].y <= contact_y:
				var at := samples[i][point]
				var flat := Vector2(at.x, at.z)
				if frames == 0:
					start = flat
				frames += 1
				distance = maxf(distance, flat.distance_to(start))
			elif frames > 0:
				if frames >= 3:
					contacts += 1
					worst = maxf(worst, distance)
				frames = 0
				distance = 0.0
	return Vector2(worst, float(contacts))
