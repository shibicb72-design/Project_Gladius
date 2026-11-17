extends "res://tests/test_case.gd"
## M2 AN3 (OQ-ANIM-HEAD): the bobblehead fix. A REAL pawn and SoldierModel are stepped by hand at a fixed 1/60 s (the
## pawn's physics off; the test forces the read-only state the visuals read, as tools/head_motion_measure.gd does),
## and every frame's final pose (SoldierModel.pose_cache, after every modifier) is checked against
## data/anim_third_person.json head.limits:
## - the Neck stays within neck_chest_max_deg of the Chest, turning at most neck_chest_rate_max_dps against it;
## - the gap (Neck origin vs the chest top: the Chest with the rest Neck offset) stays under gap_max_m;
## - the helmet centre (the Head bone's origin) stays on the pawn's head hitbox (its Head Area3D) within
##   helmet_tolerance_m, in every state where it did before AN3 too (not downed / revive, not the landing dip);
## - after a step input (an aim pitch step, a flinch, a jog start and stop, entering the fall) the SoldierNeck low-pass
##   never passes its target (no overshoot) and the neck settles monotonically toward its end pose;
## - a flinch moves only the flinch layer's bones (Spine, Chest, LeftUpperArm, RightUpperArm), the left arm's IK chain
##   that follows the gun (LeftForeArm, LeftHand) and, through SoldierNeck, the Neck and Head (bounded);
## - SoldierRig.head_legacy restores the old, clearly larger gap (the switch is real).

const DT := 1.0 / 60.0
const SETTLE := 10
const FLINCH_BONES: Array[String] = ["Spine", "Chest", "LeftUpperArm", "RightUpperArm"]
const IK_BONES: Array[String] = ["LeftForeArm", "LeftHand"]
const FOLLOWER_BONES: Array[String] = ["Neck", "Head"]
## Float comparison floor, not a tunable: two identical runs differ by up to ~0.04 deg in angle_to (float precision
## of nearly equal quaternions) and well under 0.1 mm.
const NOISE_DEG := 0.1
const NOISE_M := 0.0001

var _pawn: Pawn
var _model: SoldierModel
var _cover: CoverAnim
var _neck_from_chest := Transform3D.IDENTITY


func _limits() -> Dictionary:
	return SoldierRig.config()["head"]["limits"]


func _spawn(cover: bool = false) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	_pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_model = _pawn.get_node("SoldierModel") as SoldierModel
	_model.set_process(false)
	_model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	_cover = null
	if cover:
		_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
		_cover = _pawn.get_node("CoverAnim") as CoverAnim
		_cover.set_process(false)
	var skeleton := _model.skeleton
	_neck_from_chest = skeleton.get_bone_global_rest(skeleton.find_bone("Chest")).affine_inverse() * skeleton.get_bone_global_rest(skeleton.find_bone("Neck"))
	for i in SETTLE:
		await _step(Vector3.ZERO)


func _free() -> void:
	_pawn.free()
	_pawn = null
	await (Engine.get_main_loop() as SceneTree).process_frame


func _step(velocity: Vector3) -> void:
	_pawn.velocity = velocity
	_pawn.global_position += Vector3(velocity.x, 0.0, velocity.z) * DT
	if _cover != null:
		_cover.sync_pose(DT)
	_model._process(DT)
	_model.animation_tree.advance(DT)
	_model.skeleton.advance(DT)
	await (Engine.get_main_loop() as SceneTree).process_frame


func _bone(name: String) -> Transform3D:
	return _model.pose_cache[_model.skeleton.find_bone(name)]


## This frame: [neck-vs-chest rotation, gap m, helmet centre off the hitbox m, neck global rotation].
func _frame() -> Array:
	var chest := _bone("Chest")
	var neck := _bone("Neck")
	var relative := chest.basis.get_rotation_quaternion().inverse() * neck.basis.get_rotation_quaternion()
	var gap := neck.origin.distance_to((chest * _neck_from_chest).origin)
	var hitbox := _model.skeleton.global_transform.affine_inverse() * (_pawn.get_node("Head") as Node3D).global_position
	return [relative, gap, _bone("Head").origin.distance_to(hitbox), neck.basis.get_rotation_quaternion()]


## Runs `frames` frames of a state (`each` sets the inputs per frame and returns the ground velocity) and returns
## {angle, rate, gap, helmet}: the worst of each.
func _run(frames: int, each: Callable) -> Dictionary:
	var worst := {"angle": 0.0, "rate": 0.0, "gap": 0.0, "helmet": 0.0}
	var previous: Variant = null
	for f in frames:
		await _step(each.call(f))
		var now := _frame()
		worst["angle"] = maxf(worst["angle"], rad_to_deg((now[0] as Quaternion).get_angle()))
		if previous != null:
			worst["rate"] = maxf(worst["rate"], rad_to_deg((previous as Quaternion).angle_to(now[0])) / DT)
		previous = now[0]
		worst["gap"] = maxf(worst["gap"], float(now[1]))
		worst["helmet"] = maxf(worst["helmet"], float(now[2]))
	return worst


func _check(state: String, worst: Dictionary) -> void:
	var limits := _limits()
	print("HEAD_MOTION %s neck_chest_max_deg=%.2f rate_max_dps=%.1f gap_max_m=%.4f helmet_off_m=%.4f" % [state, worst["angle"], worst["rate"], worst["gap"], worst["helmet"]])
	assert_true(float(worst["angle"]) <= float(limits["neck_chest_max_deg"]), "%s: neck-chest %.2f deg within %s" % [state, worst["angle"], limits["neck_chest_max_deg"]])
	assert_true(float(worst["rate"]) <= float(limits["neck_chest_rate_max_dps"]), "%s: neck-chest rate %.1f deg/s within %s" % [state, worst["rate"], limits["neck_chest_rate_max_dps"]])
	assert_true(float(worst["gap"]) <= float(limits["gap_max_m"]), "%s: gap %.4f m within %s" % [state, worst["gap"], limits["gap_max_m"]])
	assert_true(float(worst["helmet"]) <= float(limits["helmet_tolerance_m"]), "%s: helmet %.4f m off the head hitbox (tolerance %s)" % [state, worst["helmet"], limits["helmet_tolerance_m"]])


func test_neck_stays_connected_and_the_helmet_on_the_hitbox() -> void:
	SoldierRig.head_legacy = false
	var cases: Array = ["idle", "walk", "jog", "sprint", "strafe", "turn", "aim_down", "aim_level", "aim_up", "fire", "hit", "fall", "cover_hug", "cover_lean"]
	for state: String in cases:
		await _spawn(state.begins_with("cover"))
		var speed := _pawn.get_move_speed()
		var limit := deg_to_rad(float(SoldierRig.config()["upper_body"]["aim_pitch_limit_deg"]))
		var frames := 60
		var each := func(_f: int) -> Vector3: return Vector3.ZERO
		match state:
			"walk":
				each = func(_f: int) -> Vector3: return Vector3.FORWARD * speed * float(SoldierRig.config()["gait"]["walk_slow_blend"])
			"jog":
				each = func(_f: int) -> Vector3: return Vector3.FORWARD * speed
			"sprint":
				each = func(_f: int) -> Vector3: return Vector3.FORWARD * _pawn.get_max_move_speed()
			"strafe":
				each = func(_f: int) -> Vector3: return Vector3.RIGHT * speed
			"turn":
				frames = 90
				each = func(f: int) -> Vector3:
					_pawn.rotation.y = deg_to_rad(90.0) * sin(TAU * f * DT / 1.5)
					return Vector3.FORWARD * speed
			"aim_down", "aim_level", "aim_up":
				_pawn.pitch = limit * (-1.0 if state == "aim_down" else 1.0 if state == "aim_up" else 0.0)
			"fire":
				each = func(f: int) -> Vector3:
					if f % 8 == 0:
						_model._on_shot_shown(Vector3.ZERO, Vector3.FORWARD)
					return Vector3.ZERO
			"hit":
				each = func(f: int) -> Vector3:
					if f == 0 or f == 30:
						_model.flinch(f == 30)
					return Vector3.ZERO
			"fall":
				_pawn.drop_state = Pawn.Drop.FALLING
				frames = 75
				each = func(f: int) -> Vector3: return Vector3(0, -15, 0) + (-_pawn.global_transform.basis.z * 8.0 if f >= 40 else Vector3.ZERO)
			"cover_hug", "cover_lean":
				var controller := _pawn.cover
				controller.side = 1
				controller.tangent = Vector3.RIGHT
				controller.normal = Vector3.BACK
				controller.state = CoverController.State.IN_COVER
				for i in 30:  # the cover entry blend (not asserted: a forced snap into cover)
					await _step(Vector3.ZERO)
				if state == "cover_lean":
					controller.state = CoverController.State.PEEK_RIGHT
					each = func(f: int) -> Vector3:
						controller.aim_out_amount = clampf(f / 15.0, 0.0, 1.0)
						return Vector3.ZERO
		_check(state, await _run(frames, each))
		await _free()


## SoldierNeck's low-pass never passes its target, and a settling neck approaches its end pose monotonically.
func test_step_inputs_have_no_overshoot() -> void:
	SoldierRig.head_legacy = false
	var eps := deg_to_rad(float(_limits()["monotonic_eps_deg"]))
	for case: String in ["aim_step", "flinch", "jog_start_stop", "fall_entry"]:
		await _spawn()
		var speed := _pawn.get_move_speed()
		var limit := deg_to_rad(float(SoldierRig.config()["upper_body"]["aim_pitch_limit_deg"]))
		var overshoot := 0.0
		var poses: Array[Quaternion] = []
		var settle_from := 0
		for f in 120:
			var velocity := Vector3.ZERO
			match case:
				"aim_step":
					_pawn.pitch = limit if f >= 10 else 0.0
				"flinch":
					if f == 10:
						_model.flinch(false)
				"jog_start_stop":
					velocity = Vector3.FORWARD * speed if f >= 10 and f < 60 else Vector3.ZERO
					settle_from = 60
				"fall_entry":
					if f == 10:
						_pawn.drop_state = Pawn.Drop.FALLING
					velocity = Vector3(0, -15, 0) if f >= 10 else Vector3.ZERO
					settle_from = 10
			var before := _model.neck.shown
			await _step(velocity)
			var reach := before.angle_to(_model.neck.target)
			# No overshoot: the shown neck ends no farther from this frame's target than it started, and never moves
			# by more than the distance to it.
			overshoot = maxf(overshoot, _model.neck.shown.angle_to(_model.neck.target) - reach)
			overshoot = maxf(overshoot, before.angle_to(_model.neck.shown) - reach)
			poses.append(_frame()[3])
		# Monotonic settling toward the end pose once the input has stepped (the fall: its pose blend in).
		var reversal := 0.0
		var end: Quaternion = poses[-1]
		var best := INF
		for i in range(settle_from, poses.size()):
			var away := poses[i].angle_to(end)
			if away > best:
				reversal = maxf(reversal, away - best)
			best = minf(best, away)
		print("HEAD_STEP %s overshoot_deg=%.4f reversal_deg=%.4f" % [case, rad_to_deg(overshoot), rad_to_deg(reversal)])
		assert_true(overshoot <= eps, "%s: the neck low-pass never passes its target (%.4f deg)" % [case, rad_to_deg(overshoot)])
		if case != "flinch":  # a flinch is a pulse: it goes out and comes back (the overshoot check covers it)
			assert_true(reversal <= eps, "%s: the neck settles monotonically (%.4f deg back)" % [case, rad_to_deg(reversal)])
		await _free()


## Local pose of every bone, from the final global poses.
func _locals() -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var skeleton := _model.skeleton
	for i in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(i)
		out.append(_model.pose_cache[i] if parent < 0 else _model.pose_cache[parent].affine_inverse() * _model.pose_cache[i])
	return out


func test_flinch_moves_only_the_torso_bones() -> void:
	SoldierRig.head_legacy = false
	var runs: Array = []
	var skeleton_names: Array[String] = []
	for flinch: bool in [false, true]:
		await _spawn()
		if skeleton_names.is_empty():
			for i in _model.skeleton.get_bone_count():
				skeleton_names.append(String(_model.skeleton.get_bone_name(i)))
		var frames: Array = []
		for f in 40:
			if flinch and f == 2:
				_model.flinch(false)
			await _step(Vector3.ZERO)
			frames.append(_locals())
		runs.append(frames)
		await _free()
	var moved := {}
	for f in (runs[0] as Array).size():
		for i in skeleton_names.size():
			var a: Transform3D = runs[0][f][i]
			var b: Transform3D = runs[1][f][i]
			var turn := rad_to_deg(a.basis.get_rotation_quaternion().angle_to(b.basis.get_rotation_quaternion()))
			var shift := a.origin.distance_to(b.origin)
			if turn > NOISE_DEG or shift > NOISE_M:
				moved[skeleton_names[i]] = maxf(float(moved.get(skeleton_names[i], 0.0)), turn)
	print("HEAD_FLINCH moved (max deg vs no flinch): ", moved)
	assert_true(moved.has("Chest") or moved.has("Spine"), "nonvacuous: the flinch moves the torso")
	for bone: String in moved:
		assert_true(FLINCH_BONES.has(bone) or IK_BONES.has(bone) or FOLLOWER_BONES.has(bone), "the flinch moves only its bones, the left-arm IK and the neck follower: %s moved" % bone)
	for bone: String in FOLLOWER_BONES:
		assert_true(float(moved.get(bone, 0.0)) <= float(_limits()["flinch_neck_max_deg"]), "%s follows the flinch by at most %s deg (%.2f)" % [bone, _limits()["flinch_neck_max_deg"], moved.get(bone, 0.0)])


func test_legacy_switch_restores_the_old_gap() -> void:
	var gaps := {}
	for legacy: bool in [true, false]:
		SoldierRig.head_legacy = legacy
		await _spawn()
		var worst: Dictionary = await _run(60, func(_f: int) -> Vector3: return Vector3.FORWARD * _pawn.get_max_move_speed())
		gaps[legacy] = float(worst["gap"])
		await _free()
	SoldierRig.head_legacy = false
	print("HEAD_LEGACY sprint gap legacy=%.4f now=%.4f" % [gaps[true], gaps[false]])
	assert_true(float(gaps[true]) >= float(gaps[false]) * float(_limits()["legacy_gap_ratio"]), "the legacy switch restores the old, larger gap (%.4f vs %.4f)" % [gaps[true], gaps[false]])
