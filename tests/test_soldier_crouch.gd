extends "res://tests/test_case.gd"
## M2 AN3 stage C, M2 FIX1: the free crouch (H1c) of the third-person soldier on the REAL pawn. The Crouch press
## (Pawn.handle_action_press("crouch")) sets Pawn.free_crouch; Pawn._tick_free_crouch, stepped every frame here (the
## pawn's physics is off), eases free_crouch_amount and lowers the head hitbox with it. SoldierModel shows only the free
## crouch's own share (free_crouch_amount, faded out by the cover layer); CoverAnim shows the cover crouch.
## - Crouched (idle and crouch walking at the real crouch speed) the helmet centre sits on the Head node within
##   head.limits.helmet_tolerance_m and the stage-B neck rules hold (gap, neck-chest angle); the crouch walk's foot
##   slide is measured.
## - The free crouch never leaks into the cover crouch: in the settled cover crouch the pose matches a reference whose
##   free-crouch outputs are forced to 0, also with free_crouch_amount forced to 1; forcing the outputs on must differ.
## Stepped at a fixed 1/60 s like tests/test_soldier_head_motion.gd.

const DT := 1.0 / 60.0

var _pawn: Pawn
var _model: SoldierModel
var _neck_from_chest := Transform3D.IDENTITY


func _cfg() -> Dictionary:
	return SoldierRig.config()["head"]


func _spawn() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	_pawn = load("res://scenes/player/pawn.tscn").instantiate()
	tree.root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_model = _pawn.get_node("SoldierModel") as SoldierModel
	_model.set_process(false)
	_model.animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_model.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var skeleton := _model.skeleton
	_neck_from_chest = skeleton.get_bone_global_rest(skeleton.find_bone("Chest")).affine_inverse() * skeleton.get_bone_global_rest(skeleton.find_bone("Neck"))


func _free() -> void:
	_pawn.free()
	await (Engine.get_main_loop() as SceneTree).process_frame


func _step(velocity: Vector3) -> void:
	_pawn._tick_free_crouch(DT)
	_pawn.velocity = velocity
	_pawn.global_position += velocity * DT
	_model._process(DT)
	_model.animation_tree.advance(DT)
	_model.skeleton.advance(DT)
	await (Engine.get_main_loop() as SceneTree).process_frame


func _bone(name: String) -> Transform3D:
	return _model.pose_cache[_model.skeleton.find_bone(name)]


## Presses Crouch and lets the real pawn ease all the way down (stats.json movement.crouch.blend_s), then runs `frames`
## frames at `velocity`; returns the worst {gap, angle, helmet} over those frames and the world sole points per frame.
func _crouch(frames: int, velocity: Vector3) -> Dictionary:
	var head := _pawn.get_node("Head") as Node3D
	_pawn.handle_action_press("crouch")
	assert_true(_pawn.free_crouch, "fixture: the Crouch press crouches the real pawn")
	for i in ceili(float(_pawn._crouch_cfg()["blend_s"]) / DT) + 1:
		await _step(Vector3.ZERO)
	var worst := {"gap": 0.0, "angle": 0.0, "helmet": 0.0, "soles": []}
	var soles := SoldierClips.sole_points(_model.skeleton)
	for f in frames:
		await _step(velocity)
		var chest := _bone("Chest")
		var neck := _bone("Neck")
		worst["gap"] = maxf(worst["gap"], neck.origin.distance_to((chest * _neck_from_chest).origin))
		worst["angle"] = maxf(worst["angle"], rad_to_deg(chest.basis.get_rotation_quaternion().angle_to(neck.basis.get_rotation_quaternion())))
		var hitbox := _model.skeleton.global_transform.affine_inverse() * head.global_position
		worst["helmet"] = maxf(worst["helmet"], _bone("Head").origin.distance_to(hitbox))
		var world: Array[Vector3] = []
		for p in SoldierClips.contacts(_model.pose_cache, soles):
			world.append(_model.skeleton.global_transform * p)
		(worst["soles"] as Array).append(world)
	return worst


## The farthest a sole point drifts on the ground during one contact (the measure of tests/test_soldier_footslide.gd).
static func _slide(track: Array) -> float:
	var contact_m := float(SoldierRig.config()["gait"]["contact_height_m"])
	var floor_y := INF
	for world: Array in track:
		for p: Vector3 in world:
			floor_y = minf(floor_y, p.y)
	var worst := 0.0
	for point in (track[0] as Array).size():
		var start := Vector3.INF
		var far := 0.0
		var down_frames := 0
		for i in track.size() + 1:
			var down := i < track.size() and (track[i][point] as Vector3).y <= floor_y + contact_m
			if down:
				var p: Vector3 = track[i][point]
				if down_frames == 0:
					start = p
				down_frames += 1
				far = maxf(far, Vector2(p.x - start.x, p.z - start.z).length())
			elif down_frames > 0:
				if down_frames >= 3:
					worst = maxf(worst, far)
				down_frames = 0
				far = 0.0
	return worst


func _check(label: String, worst: Dictionary) -> void:
	var limits: Dictionary = _cfg()["limits"]
	print("CROUCH %s gap_max_m=%.4f neck_chest_max_deg=%.2f helmet_off_m=%.4f shown=%.2f" % [label, worst["gap"], worst["angle"], worst["helmet"], _model.crouch_shown])
	assert_true(float(worst["helmet"]) <= float(limits["helmet_tolerance_m"]), "%s: the helmet sits on the Head node (%.4f m)" % [label, worst["helmet"]])
	assert_true(float(worst["gap"]) <= float(limits["gap_max_m"]), "%s: gap %.4f m within %s" % [label, worst["gap"], limits["gap_max_m"]])
	assert_true(float(worst["angle"]) <= float(limits["neck_chest_max_deg"]), "%s: neck-chest %.2f deg within %s" % [label, worst["angle"], limits["neck_chest_max_deg"]])


func test_free_crouch_follows_the_lowered_head_node() -> void:
	SoldierRig.head_legacy = false
	await _spawn()
	assert_true(_model.crouch_amount() == 0.0, "standing: Pawn.crouch_amount() is 0")
	var idle: Dictionary = await _crouch(40, Vector3.ZERO)
	var crouch_y := float(DataRegistry.new().load_file("res://data/cover.json")["crouch_head_y_m"])
	assert_true(absf((_pawn.get_node("Head") as Node3D).position.y - crouch_y) < 0.0001, "nonvacuous: the real pawn lowered its head hitbox to crouch_head_y_m")
	assert_true(_model.crouch_amount() == 1.0 and absf(_model.crouch_shown - 1.0) < 0.001, "free_crouch_amount drives the crouch clip fully once down (%.3f)" % _model.crouch_shown)
	_check("idle", idle)
	await _free()
	await _spawn()
	var speed := _pawn.get_move_speed() * float(_pawn._crouch_cfg()["speed_multiplier"])  # the real crouch walk speed
	var walk: Dictionary = await _crouch(100, Vector3.FORWARD * speed)
	_check("walk", walk)
	var slide := _slide((walk["soles"] as Array).slice(30))
	var limit := float(SoldierRig.config()["gait"]["foot_slide_max_m"])
	print("CROUCH_FOOTSLIDE walk speed=%.2f max_m=%.3f limit=%.3f" % [speed, slide, limit])
	assert_true(slide <= limit, "crouch walk: stance drift %.3f m within the foot-slide limit" % slide)
	await _free()


const POSE_BONES: Array[String] = ["Hips", "Spine", "Chest", "Neck", "Head", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot"]


## The settled cover crouch (IN_COVER, crouch_amount 1, the head hitbox lowered as the pawn's tick does): the model-frame
## poses of POSE_BONES after 20 frames, plus the free crouch's outputs. `free`: Pawn.free_crouch_amount held there every
## frame (1: a free crouch left over in cover, which the visuals must not show). force < 0: the model as it is;
## force >= 0: every frame, after SoldierModel._process, the free crouch's outputs (the crouch clip blend,
## SoldierGait.free_crouch, head_drop, hips_drop, SoldierPose.head_drop) are overwritten with what _drive_crouch would
## set with the free crouch fully in at `force` (0: none of it, the reference; 1: all of it, a deliberate leak).
func _cover_crouch_pose(free: float, force: float) -> Dictionary:
	await _spawn()
	_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	var anim := _pawn.get_node("CoverAnim") as CoverAnim
	anim.set_process(false)
	_pawn.cover.state = CoverController.State.IN_COVER
	_pawn.cover.crouch_amount = 1.0
	_pawn.cover.crouched = true
	_pawn.free_crouch_amount = free
	_pawn._apply_body_shapes()  # the head hitbox lowers to the crouch, as the pawn's tick does
	var head := _pawn.get_node("Head") as Node3D
	var raw := _model.skeleton.get_bone_global_rest(_model.skeleton.find_bone("Head")).origin.y - head.position.y
	var most := 0.0
	for i in 20:
		anim.sync_pose(DT)
		_pawn.velocity = Vector3.ZERO
		_pawn.free_crouch_amount = free
		_model._process(DT)
		if force >= 0.0:
			_model.animation_tree.set("parameters/crouch/blend_amount", force)
			_model.gait.free_crouch = force
			_model.gait.head_drop = raw * force
			_model.gait.hips_drop = raw * force * float(_cfg()["free_crouch"]["hips_drop_per_head"])
			_model.pose.head_drop = raw * force
		_model.animation_tree.advance(DT)
		_model.skeleton.advance(DT)
		await (Engine.get_main_loop() as SceneTree).process_frame
		if i >= 6:  # once the cover layer has faded in (cover_mix_fade_s)
			most = maxf(most, maxf(maxf(_model.crouch_shown, _model.gait.head_drop), float(_model.animation_tree.get("parameters/crouch/blend_amount"))))
	var poses := {}
	for bone in POSE_BONES:
		poses[bone] = _bone(bone)
	var out := {"poses": poses, "most": most, "amount": _model.crouch_amount()}
	await _free()
	return out


## The largest difference between two pose sets: [max angle deg, max distance m, the bone].
static func _pose_diff(a: Dictionary, b: Dictionary) -> Array:
	var worst := [0.0, 0.0, ""]
	for bone: String in a:
		var x: Transform3D = a[bone]
		var y: Transform3D = b[bone]
		var turn := rad_to_deg(x.basis.get_rotation_quaternion().angle_to(y.basis.get_rotation_quaternion()))
		var shift := x.origin.distance_to(y.origin)
		if turn > float(worst[0]) or shift > float(worst[1]):
			worst[2] = bone
		worst[0] = maxf(float(worst[0]), turn)
		worst[1] = maxf(float(worst[1]), shift)
	return worst


## M2 FIX1 (was test_without_the_method_the_cover_crouch_is_unchanged, a pawn without crouch_amount(), gone with H1c):
## the real pawn in the settled cover crouch shows CoverAnim's cover crouch alone. Compared with a reference run whose
## free-crouch outputs are forced to 0 every frame, the pose (Hips, Spine, Chest, Neck, Head, legs) must match, also with
## Pawn.free_crouch_amount held at 1 in cover; a run that forces the free crouch's outputs fully on must differ (so the
## compared bones see a leak). This fails if any path lets the free crouch into the cover crouch: the 1 - cover_mix
## "open" in SoldierModel._drive_crouch dropped, the cover crouch read into the free share (Pawn.crouch_amount() or the
## Head node's drop), a non-zero crouch clip blend, head_drop or hips_drop reaching SoldierGait or SoldierPose.
func test_the_free_crouch_never_leaks_into_the_cover_crouch() -> void:
	SoldierRig.head_legacy = false
	await _spawn()
	assert_eq(_model.crouch_amount(), 0.0, "no cover, no free crouch: no crouch")
	_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	_pawn.cover.state = CoverController.State.IN_COVER
	_pawn.cover.crouch_amount = 1.0
	assert_eq(_model.crouch_amount(), 1.0, "in cover the amount is the cover crouch (Pawn.crouch_amount())")
	await _free()
	var model: Dictionary = await _cover_crouch_pose(0.0, -1.0)
	var reference: Dictionary = await _cover_crouch_pose(0.0, 0.0)
	var leaked: Dictionary = await _cover_crouch_pose(0.0, 1.0)
	var held: Dictionary = await _cover_crouch_pose(1.0, -1.0)
	var same := _pose_diff(model["poses"], reference["poses"])
	var leak := _pose_diff(model["poses"], leaked["poses"])
	var with_free := _pose_diff(model["poses"], held["poses"])
	print("CROUCH_COVER vs reference %s, vs a leaked free crouch %s, vs free_crouch_amount 1 %s; free crouch outputs %.4f / %.4f" % [same, leak, with_free, model["most"], held["most"]])
	assert_true(float(model["most"]) == 0.0, "in cover the free crouch's outputs stay 0 (%.4f)" % model["most"])
	assert_true(float(held["most"]) == 0.0, "in cover a held free_crouch_amount 1 shows nothing either (%.4f)" % held["most"])
	assert_true(float(same[0]) <= 0.1 and float(same[1]) <= 0.0001, "the cover crouch pose is the reference's (%s)" % [same])
	assert_true(float(with_free[0]) <= 0.1 and float(with_free[1]) <= 0.0001, "with free_crouch_amount 1 the settled cover crouch is the same (%s)" % [with_free])
	assert_true(float(leak[0]) > 1.0 or float(leak[1]) > 0.01, "nonvacuous: a leaked free crouch moves the compared bones (%s)" % [leak])
