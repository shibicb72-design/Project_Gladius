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
	assert_true(slide <= limit * 2.0, "crouch walk: stance drift %.3f m within twice the foot-slide limit (as the strafes)" % slide)
	await _free()


func test_unmoved_head_shows_part_of_the_crouch_and_no_stretch() -> void:
	SoldierRig.head_legacy = false
	await _spawn(true)
	var worst: Dictionary = await _crouch(0.0, 40, Vector3.ZERO)
	var share := float(_cfg()["free_crouch"]["unmoved_head_share"])
	assert_true(absf(_model.crouch_shown - share) < 0.001, "an unmoved head shows unmoved_head_share of the crouch (%.3f vs %.3f)" % [_model.crouch_shown, share])
	_check("unmoved", worst)
	await _free()


func test_without_the_method_the_cover_crouch_is_unchanged() -> void:
	SoldierRig.head_legacy = false
	await _spawn(false)
	assert_true(not _pawn.has_method(&"crouch_amount"), "fixture: a pawn without crouch_amount() (H1c not merged)")
	assert_eq(_model.crouch_amount(), 0.0, "no cover: no crouch")
	_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	var anim := _pawn.get_node("CoverAnim") as CoverAnim
	anim.set_process(false)
	_pawn.cover.state = CoverController.State.IN_COVER
	_pawn.cover.crouch_amount = 1.0
	_pawn.cover.crouched = true
	_pawn._apply_cover_shapes()  # the head hitbox lowers to the cover crouch, as the pawn's tick does
	var most := 0.0
	for i in 20:
		anim.sync_pose(DT)
		await _step(Vector3.ZERO)
		if i >= 6:  # once the cover layer has faded in (cover_mix_fade_s)
			most = maxf(most, maxf(_model.crouch_shown, _model.gait.head_drop))
	assert_eq(_model.crouch_amount(), 1.0, "the fallback reads the cover crouch in cover")
	assert_true(most == 0.0, "in cover the free crouch stays off: CoverAnim keeps the cover crouch as before (%.4f)" % most)
	_pawn.cover.state = CoverController.State.FREE
	assert_eq(_model.crouch_amount(), 0.0, "out of cover the fallback is 0")
	await _free()
