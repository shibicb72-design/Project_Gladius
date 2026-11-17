extends "res://tests/test_case.gd"
## M2 AN3 stage C: the free crouch of the third-person soldier. The model reads Pawn.crouch_amount() only when the pawn
## has it (the parallel slice H1c adds it; here tests/crouch_stub_pawn.gd stands in), else the cover crouch in cover.
## - With the method at crouch 1 and the Head node lowered (as H1c will lower the head hitbox), the helmet centre sits
##   on the Head node within head.limits.helmet_tolerance_m and the stage-B neck rules hold (gap, neck-chest angle),
##   crouched idle and crouch walking; the crouch walk's foot slide is measured.
## - With the method but a Head node that does not lower, only head.free_crouch.unmoved_head_share of the crouch shows
##   and the neck still holds.
## - Without the method (the fallback): the amount is the cover crouch in cover, 0 out of it, and the free crouch stays
##   off in cover (CoverAnim keeps showing the cover crouch exactly as before).
## Stepped at a fixed 1/60 s like tests/test_soldier_head_motion.gd.

const DT := 1.0 / 60.0
const STUB := "res://tests/crouch_stub_pawn.gd"

var _pawn: Pawn
var _model: SoldierModel
var _neck_from_chest := Transform3D.IDENTITY


func _cfg() -> Dictionary:
	return SoldierRig.config()["head"]


func _spawn(stub: bool) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	_pawn = load("res://scenes/player/pawn.tscn").instantiate()
	if stub:
		_pawn.set_script(load(STUB))
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
	_pawn.velocity = velocity
	_pawn.global_position += velocity * DT
	_model._process(DT)
	_model.animation_tree.advance(DT)
	_model.skeleton.advance(DT)
	await (Engine.get_main_loop() as SceneTree).process_frame


func _bone(name: String) -> Transform3D:
	return _model.pose_cache[_model.skeleton.find_bone(name)]


## Crouches the stub over 0.3 s (lowering the Head node by `drop` with it), then runs `frames` frames at `velocity`;
## returns the worst {gap, angle, helmet} over those frames and the world sole points per frame.
func _crouch(drop: float, frames: int, velocity: Vector3) -> Dictionary:
	var head := _pawn.get_node("Head") as Node3D
	var standing := head.position.y
	for i in 18:
		var amount := (i + 1) / 18.0
		_pawn.set("crouch_value", amount)
		head.position.y = standing - drop * amount
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
	var drop := float(_cfg()["free_crouch"]["nominal_head_drop_m"])
	await _spawn(true)
	assert_true(_model.crouch_amount() == 0.0, "standing: the stub's crouch_amount() is 0")
	var idle: Dictionary = await _crouch(drop, 40, Vector3.ZERO)
	assert_true(_model.crouch_amount() == 1.0 and absf(_model.crouch_shown - 1.0) < 0.001, "the method's amount drives the crouch clip fully once the head is down (%.3f)" % _model.crouch_shown)
	_check("idle", idle)
	await _free()
	await _spawn(true)
	var speed := _pawn.get_move_speed() * 0.4  # a crouch walk speed (H1c's is not known here)
	var walk: Dictionary = await _crouch(drop, 100, Vector3.FORWARD * speed)
	_check("walk", walk)
	var slide := _slide((walk["soles"] as Array).slice(30))
	var limit := float(SoldierRig.config()["gait"]["foot_slide_max_m"])
	print("CROUCH_FOOTSLIDE walk speed=%.2f max_m=%.3f limit=%.3f" % [speed, slide, limit])
	assert_true(slide <= limit, "crouch walk: stance drift %.3f m within the foot-slide limit" % slide)
	await _free()


func test_unmoved_head_shows_part_of_the_crouch_and_no_stretch() -> void:
	SoldierRig.head_legacy = false
	await _spawn(true)
	var worst: Dictionary = await _crouch(0.0, 40, Vector3.ZERO)
	var share := float(_cfg()["free_crouch"]["unmoved_head_share"])
	assert_true(absf(_model.crouch_shown - share) < 0.001, "an unmoved head shows unmoved_head_share of the crouch (%.3f vs %.3f)" % [_model.crouch_shown, share])
	_check("unmoved", worst)
	await _free()


const POSE_BONES: Array[String] = ["Hips", "Spine", "Chest", "Neck", "Head", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot"]


## The settled cover crouch (IN_COVER, crouch_amount 1, the head hitbox lowered as the pawn's tick does): the model-frame
## poses of POSE_BONES after 20 frames, plus the free crouch's outputs. force < 0: the model as it is; force >= 0: every
## frame, after SoldierModel._process, the free crouch's outputs (the crouch clip blend, SoldierGait.free_crouch,
## head_drop, hips_drop, SoldierPose.head_drop) are overwritten with what _drive_crouch would set with the free crouch
## open at `force` (0: none of it, the reference; 1: all of it, a deliberate leak).
func _cover_crouch_pose(stub: bool, force: float) -> Dictionary:
	await _spawn(stub)
	_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	var anim := _pawn.get_node("CoverAnim") as CoverAnim
	anim.set_process(false)
	_pawn.cover.state = CoverController.State.IN_COVER
	_pawn.cover.crouch_amount = 1.0
	_pawn.cover.crouched = true
	if stub:
		_pawn.set("crouch_value", 1.0)
	_pawn._apply_cover_shapes()  # the head hitbox lowers to the cover crouch, as the pawn's tick does
	var head := _pawn.get_node("Head") as Node3D
	var raw := _model.skeleton.get_bone_global_rest(_model.skeleton.find_bone("Head")).origin.y - head.position.y
	var most := 0.0
	for i in 20:
		anim.sync_pose(DT)
		_pawn.velocity = Vector3.ZERO
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


## The fallback (no Pawn.crouch_amount()) in the settled cover crouch shows CoverAnim's cover crouch alone. Compared
## with a reference run whose free-crouch outputs are forced to 0 every frame, the pose (Hips, Spine, Chest, Neck, Head,
## legs) must match; a run that forces the free crouch fully on must differ (so the compared bones see a leak). This
## fails if any path lets the free crouch into the cover crouch: the has_method gate or the 1 - cover_mix "open" in
## SoldierModel._drive_crouch dropped, a non-zero crouch clip blend, head_drop or hips_drop reaching SoldierGait or
## SoldierPose. The stub pawn (with the method, at crouch 1) in the same cover crouch must match too (open is 0 there).
func test_without_the_method_the_cover_crouch_is_unchanged() -> void:
	SoldierRig.head_legacy = false
	await _spawn(false)
	assert_true(not _pawn.has_method(&"crouch_amount"), "fixture: a pawn without crouch_amount() (H1c not merged)")
	assert_eq(_model.crouch_amount(), 0.0, "no cover: no crouch")
	_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	_pawn.cover.state = CoverController.State.IN_COVER
	_pawn.cover.crouch_amount = 1.0
	assert_eq(_model.crouch_amount(), 1.0, "the fallback reads the cover crouch in cover")
	_pawn.cover.state = CoverController.State.FREE
	_pawn.cover.crouch_amount = 0.0
	assert_eq(_model.crouch_amount(), 0.0, "out of cover the fallback is 0")
	await _free()
	var model: Dictionary = await _cover_crouch_pose(false, -1.0)
	var reference: Dictionary = await _cover_crouch_pose(false, 0.0)
	var leaked: Dictionary = await _cover_crouch_pose(false, 1.0)
	var stub: Dictionary = await _cover_crouch_pose(true, -1.0)
	var same := _pose_diff(model["poses"], reference["poses"])
	var leak := _pose_diff(model["poses"], leaked["poses"])
	var with_method := _pose_diff(model["poses"], stub["poses"])
	print("CROUCH_FALLBACK vs reference %s, vs a leaked free crouch %s, vs the stub %s; free crouch outputs %.4f" % [same, leak, with_method, model["most"]])
	assert_true(float(model["most"]) == 0.0, "in cover the free crouch's outputs stay 0 (%.4f)" % model["most"])
	assert_true(float(same[0]) <= 0.1 and float(same[1]) <= 0.0001, "the fallback's cover crouch pose is the reference's (%s)" % [same])
	assert_true(float(with_method[0]) <= 0.1 and float(with_method[1]) <= 0.0001, "with the method at crouch 1 the settled cover crouch is the same (%s)" % [with_method])
	assert_true(float(leak[0]) > 1.0 or float(leak[1]) > 0.01, "nonvacuous: a leaked free crouch moves the compared bones (%s)" % [leak])
