extends "res://tests/test_case.gd"
## M2 C1b stage 2: the close third-person cover camera (data/camera.json cover, cover_blend_s), the automatic look
## turn along the wall on entry (pawn.gd _tick_cover_turn), the blended exits (camera_rig.gd), the wall-hug pose
## (cover_anim.gd) and the automatic crouch from the wall height (cover_controller.gd _update_crouch). OQ-COVER.
## Fixture style follows tests/test_first_person_camera.gd (manual pawn ticks, the rig on real physics frames).

const DT := 1.0 / 60.0
const EPS := 1e-4
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")

var _root: Node3D
var _pawn: Pawn
var _rig: CameraRig
var _wall: StaticBody3D


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cam_cfg() -> Dictionary:
	return DataRegistry.new().get_camera_cfg()


func _cover_cam(key: String) -> float:
	return float(_cam_cfg()["cover"][key]["value"])


func _blend_s() -> float:
	return float(_cam_cfg()["cover_blend_s"]["value"])


func _fp(key: String) -> float:
	return float(_cam_cfg()["first_person"][key]["value"])


func _cover_cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/cover.json")


## Floor, a 4 m cover wall whose face is on z = 0 (normal +z, tangent +x, edges at x = -2 and x = 2) of the given
## height, and the local pawn (rig, no Brain) at `at` with yaw `yaw_deg` (0 = facing the wall, -z).
func _fixture(at: Vector3 = Vector3(0, 0, 0.6), height: float = 2.2, yaw_deg: float = 0.0) -> void:
	_root = Node3D.new()
	_tree().root.add_child(_root)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(30, 0.2, 30)
	floor_shape.shape = floor_box
	floor_body.position.y = -0.1
	floor_body.add_child(floor_shape)
	_root.add_child(floor_body)
	_wall = StaticBody3D.new()
	_wall.add_to_group(&"cover_wall")
	_wall.position = Vector3(0, height * 0.5, -0.5)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, height, 1)
	shape.shape = box
	_wall.add_child(shape)
	_root.add_child(_wall)
	_pawn = _PawnScene.instantiate()
	_pawn.position = at
	_pawn.rotation.y = deg_to_rad(yaw_deg)
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	_pawn.enable_cover(_cover_cfg())
	_rig = _RigScene.instantiate()
	_rig.name = "CameraRig"
	_pawn.add_child(_rig)
	await _tree().physics_frame
	await _tree().physics_frame


func _tick(move: Vector2 = Vector2.ZERO, look: Vector2 = Vector2.ZERO) -> void:
	var frame := InputFrame.new()
	frame.move = move
	frame.look = look
	_pawn.set_frame(frame)
	_pawn._physics_process(DT)
	await _tree().physics_frame


func _cleanup() -> void:
	_root.queue_free()
	_root = null
	_rig = null
	await _tree().process_frame


func _forward() -> Vector3:
	var f := -_pawn.global_basis.z
	f.y = 0.0
	return f.normalized()


## Per-frame camera move and turn (the test_first_person_camera.gd Meter).
class Meter:
	var last: Transform3D
	var started := false
	var max_m := 0.0
	var max_deg := 0.0

	func sample(cam: Camera3D) -> void:
		var xf := cam.global_transform
		if started:
			max_m = maxf(max_m, xf.origin.distance_to(last.origin))
			max_deg = maxf(max_deg, rad_to_deg((last.basis.get_rotation_quaternion().inverse() * xf.basis.get_rotation_quaternion()).get_angle()))
		last = xf
		started = true


## Ticks with no input until the pawn is IN_COVER, the blend is at third person and the entry turn is over.
func _settle_in_cover(meter: Meter = null, max_ticks: int = 150) -> bool:
	for i in max_ticks:
		await _tick()
		if meter != null:
			meter.sample(_rig.get_camera())
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0 and not _pawn.is_cover_turning():
			return true
	return false


## Ticks with no input until FREE and full first person.
func _settle_free(meter: Meter = null, max_ticks: int = 150) -> bool:
	for i in max_ticks:
		await _tick()
		if meter != null:
			meter.sample(_rig.get_camera())
		if _pawn.cover.state == CoverController.State.FREE and _rig.get_first_person_weight() == 1.0:
			return true
	return false


func _assert_smooth(meter: Meter, tag: String) -> void:
	var max_m := _fp("smooth_max_step_m")
	var max_deg := _fp("smooth_max_step_deg")
	print("C1B CAMERA %s max_step_m=%.4f max_turn_deg=%.4f (limits %.2f m, %.1f deg, cover_blend_s %.2f)" % [tag, meter.max_m, meter.max_deg, max_m, max_deg, _blend_s()])
	assert_true(meter.max_m < max_m, "%s: per-frame camera move %.4f m < %.2f m" % [tag, meter.max_m, max_m])
	assert_true(meter.max_deg < max_deg, "%s: per-frame camera turn %.4f deg < %.1f deg" % [tag, meter.max_deg, max_deg])


# ---- data --------------------------------------------------------------------------------------

func test_cover_camera_data_keys_are_oq_cover_placeholders() -> void:
	var cfg := _cam_cfg()
	assert_eq(float(cfg["cover_blend_s"]["value"]), 0.6, "cover_blend_s 0.6 [Shibi default]")
	assert_true(str(cfg["cover_blend_s"]["note"]).contains("OQ-COVER"), "cover_blend_s carries OQ-COVER")
	assert_eq(float(cfg["first_person"]["blend_s"]["value"]), 0.35, "C1a's blend_s stays for the other modes")
	assert_true(str(cfg["cover"]["_todo"]).contains("OQ-COVER"), "the cover block carries OQ-COVER")
	for key in ["distance_m", "side_offset_m", "height_m", "crouch_height_m", "out_distance_m", "out_side_offset_m",
			"out_ease_s", "side_ease_s", "turn_cancel_look_deg"]:
		assert_true(cfg["cover"].has(key) and (cfg["cover"][key] as Dictionary).has("value"), "camera.json cover." + key)
	assert_true(_cover_cam("distance_m") < float(cfg["arm_length_m"]), "the cover view is closer than today's third person")
	assert_true(_cover_cam("out_distance_m") <= _cover_cam("distance_m"), "leaned out is tighter")
	assert_true(_cover_cfg()["animation"].has("hug_out_deg"), "cover.json animation.hug_out_deg")


# ---- the cover view ----------------------------------------------------------------------------

## By the Cover button from 1.45 m: the close third person behind the soldier, on the open side, looking along the wall.
func test_cover_view_is_close_third_person_behind_the_soldier() -> void:
	await _fixture(Vector3(1.0, 0, 1.45))
	_pawn.handle_action_press("cover")
	assert_true(_pawn.in_cover(), "the Cover button enters from 1.45 m")
	assert_true(await _settle_in_cover(), "settled in cover")
	var side := float(_pawn.cover.side)
	assert_eq(side, 1.0, "the nearer edge is the right one (x = 2)")
	assert_true(not _rig.is_first_person() and _rig.in_cover_view(), "third person in cover")
	assert_true(absf(_rig.get_spring_length() - _cover_cam("distance_m")) < EPS, "spring at cover.distance_m (%s)" % _rig.get_spring_length())
	var arm := _rig.get_node("SpringArm3D") as Node3D
	assert_true(absf(arm.position.x - _cover_cam("side_offset_m") * side) < EPS, "side offset toward the open side (%s)" % arm.position.x)
	assert_true(absf(_rig.position.y - _cover_cam("height_m")) < 0.01, "pivot at cover.height_m behind high cover (%s)" % _rig.position.y)
	var cam := _rig.get_camera()
	var to_cam := cam.global_position - _pawn.global_position
	var along := _pawn.cover.tangent * side
	assert_true(to_cam.dot(along) < -1.0, "the camera is behind the soldier along the wall (%s)" % to_cam.dot(along))
	assert_true(to_cam.dot(_pawn.cover.normal) > 0.3, "the camera is on the open side, away from the wall (%s)" % to_cam.dot(_pawn.cover.normal))
	var look := -cam.global_basis.z
	look.y = 0.0
	assert_true(look.normalized().dot(along) > cos(deg_to_rad(2.0)), "the view looks along the wall toward the nearer edge")
	assert_true(not _rig.get_view_model().visible, "the first-person view model is hidden in cover")
	await _cleanup()


## The yaw eases along the wall toward the nearer edge, over cover_blend_s, monotonic, without overshoot; both sides.
func test_entry_turn_eases_along_the_wall_toward_the_nearer_edge() -> void:
	for x: float in [1.2, -1.2]:
		await _fixture(Vector3(x, 0, 0.6))
		_pawn.handle_action_press("cover")
		var expect_side := 1 if x > 0.0 else -1
		assert_eq(_pawn.cover.side, expect_side, "x %s: side toward the nearer edge" % x)
		var target := _pawn.cover.tangent * float(expect_side)
		var last_dot := _forward().dot(target)
		var frames := 0
		var monotonic := true
		while _pawn.is_cover_turning() and frames < 200:
			await _tick()
			frames += 1
			var d := _forward().dot(target)
			monotonic = monotonic and d >= last_dot - 1e-5
			last_dot = d
		var expected_frames := ceili(_blend_s() / DT - 0.0001)
		assert_true(absi(frames - expected_frames) <= 1, "x %s: the turn lasts cover_blend_s (%d frames, expected %d)" % [x, frames, expected_frames])
		assert_true(monotonic, "x %s: the turn never swings back" % x)
		assert_true(_forward().dot(target) > 0.9999, "x %s: facing along the wall toward the edge (%s)" % [x, _forward()])
		assert_eq(_pawn.pitch, 0.0, "x %s: pitch stays the player's" % x)
		await _cleanup()


func test_look_input_cancels_the_rest_of_the_turn() -> void:
	await _fixture(Vector3(1.2, 0, 0.6))
	_pawn.handle_action_press("cover")
	for i in 5:
		await _tick()
	assert_true(_pawn.is_cover_turning(), "the turn is running")
	var yaw_before := _pawn.global_rotation.y
	await _tick(Vector2.ZERO, Vector2(0.02, 0.0))
	assert_true(not _pawn.is_cover_turning(), "a look input cancels the turn (no lock)")
	assert_true(absf(angle_difference(yaw_before - 0.02, _pawn.global_rotation.y)) < 1e-5, "the look input itself applied in full")
	var yaw_after := _pawn.global_rotation.y
	for i in 40:
		await _tick()
	assert_true(absf(angle_difference(yaw_after, _pawn.global_rotation.y)) < 1e-6, "no automatic turn after the cancel")
	# Below the noise floor: the turn keeps going.
	await _cleanup()
	await _fixture(Vector3(1.2, 0, 0.6))
	_pawn.handle_action_press("cover")
	var floor_rad := deg_to_rad(_cover_cam("turn_cancel_look_deg"))
	await _tick(Vector2.ZERO, Vector2(floor_rad * 0.5, 0.0))
	assert_true(_pawn.is_cover_turning(), "look noise under turn_cancel_look_deg does not cancel")
	await _cleanup()


func test_no_turn_on_exit() -> void:
	await _fixture(Vector3(1.2, 0, 0.6))
	_pawn.handle_action_press("cover")
	assert_true(await _settle_in_cover(), "in cover")
	await _tick(Vector2.ZERO, Vector2(0.3, 0.0))  # the player looks away
	var yaw := _pawn.global_rotation.y
	_pawn.handle_action_press("cover")
	assert_true(await _settle_free(), "back to first person")
	assert_true(absf(angle_difference(yaw, _pawn.global_rotation.y)) < 1e-6, "the exit never turns the view")
	await _cleanup()


## The cover camera side follows CoverController.side, eased over cover.side_ease_s; swap_shoulder is ignored in cover.
func test_side_follows_the_controller_side() -> void:
	await _fixture(Vector3(1.2, 0, 0.6))
	_pawn.handle_action_press("cover")
	assert_true(await _settle_in_cover(), "in cover")
	var arm := _rig.get_node("SpringArm3D") as Node3D
	assert_eq(_rig.get_cover_side(), 1.0, "side +1")
	var shoulder := _rig.shoulder_side
	_rig.swap_shoulder()
	assert_eq(_rig.shoulder_side, shoulder, "swap_shoulder ignored in cover")
	_pawn.cover.side = -1  # the lean side changes (the controller owns side; a test seam)
	var ticks := 0
	var max_dx := 0.0
	var last_x := arm.position.x
	while _rig.get_cover_side() != -1.0 and ticks < 120:
		await _tick()
		ticks += 1
		max_dx = maxf(max_dx, absf(arm.position.x - last_x))
		last_x = arm.position.x
	var expected := ceili(_cover_cam("side_ease_s") / DT - 0.0001)
	assert_true(absi(ticks - expected) <= 1, "the side eases over side_ease_s (%d frames, expected %d)" % [ticks, expected])
	assert_true(absf(arm.position.x + _cover_cam("side_offset_m")) < EPS, "offset now on the left (%s)" % arm.position.x)
	assert_true(max_dx < 2.0 * _cover_cam("side_offset_m") * 0.2, "eased, not a cut (largest step %.4f m)" % max_dx)
	await _cleanup()


## Leaned out (PEEK) the view tightens to out_distance_m / out_side_offset_m.
func test_leaned_out_view_is_tighter() -> void:
	await _fixture(Vector3(1.6, 0, 0.6))
	_pawn.handle_action_press("cover")
	assert_true(await _settle_in_cover(), "in cover")
	_pawn.cover.state = CoverController.State.PEEK_RIGHT  # test seam: the lean state (stage 4 drives it from Fire)
	for i in ceili(_cover_cam("out_ease_s") / DT) + 2:
		_rig._tick_cover_pose(DT)
	assert_true(absf(_rig.get_spring_length() - _cover_cam("out_distance_m")) < EPS, "spring at out_distance_m (%s)" % _rig.get_spring_length())
	var arm := _rig.get_node("SpringArm3D") as Node3D
	assert_true(absf(arm.position.x - _cover_cam("out_side_offset_m")) < EPS, "offset at out_side_offset_m (%s)" % arm.position.x)
	_pawn.cover.state = CoverController.State.IN_COVER
	await _cleanup()


## cover_blend_s for the entry and every exit; first_person.blend_s for the other modes (downed here).
func test_cover_blend_s_is_used_both_ways_and_only_for_cover() -> void:
	await _fixture(Vector3(0, 0, 0.6))
	var expected := ceili(_blend_s() / DT - 0.0001)
	_pawn.handle_action_press("cover")
	var frames := 0
	while _rig.get_first_person_weight() > 0.0 and frames < 200:
		await _tick()
		frames += 1
	assert_true(absi(frames - expected) <= 1, "entry blend lasts cover_blend_s (%d frames, expected %d)" % [frames, expected])
	assert_true(await _settle_in_cover(), "in cover")
	_pawn.handle_action_press("cover")
	assert_eq(_pawn.cover.state, CoverController.State.EXITING, "exit begins")
	frames = 0
	var first_person_at_exiting := false
	while _rig.get_first_person_weight() < 1.0 and frames < 200:
		await _tick()
		frames += 1
		if frames == 1:
			first_person_at_exiting = _pawn.cover.state == CoverController.State.EXITING and _rig.is_first_person() and _rig.get_first_person_weight() > 0.0
	assert_true(first_person_at_exiting, "the rig wants first person as soon as EXITING begins (fix 32)")
	assert_true(absi(frames - expected) <= 1, "exit blend lasts cover_blend_s (%d frames, expected %d)" % [frames, expected])
	assert_true(_rig.get_camera().global_position.distance_to(_pawn.global_transform * Vector3(0, _fp("eye_height_m"), 0)) < 0.001, "back at the eye")
	# Another mode change keeps C1a's blend_s.
	_pawn.life = Pawn.Life.DOWNED
	frames = 0
	while _rig.get_first_person_weight() > 0.0 and frames < 200:
		await _tick()
		frames += 1
	var fp_expected := ceili(_fp("blend_s") / DT - 0.0001)
	assert_true(absi(frames - fp_expected) <= 1, "downed blend lasts first_person.blend_s (%d frames, expected %d)" % [frames, fp_expected])
	_pawn.life = Pawn.Life.ALIVE
	await _cleanup()


# ---- smoothness (C1a's limits, not loosened) ---------------------------------------------------

## Entry by auto-snap and exit by the Cover button, the automatic turn included (90 deg).
func test_auto_snap_cycle_never_snaps() -> void:
	await _fixture(Vector3(0.8, 0, 0.6))
	var meter := Meter.new()
	meter.sample(_rig.get_camera())
	for i in 60:
		await _tick(Vector2(0, -1))
		meter.sample(_rig.get_camera())
		if _pawn.cover.state != CoverController.State.FREE:
			break
	assert_true(_pawn.in_cover(), "auto-snap entered")
	assert_true(await _settle_in_cover(meter), "in cover")
	_assert_smooth(meter, "auto-snap entry")
	var exit_meter := Meter.new()
	exit_meter.sample(_rig.get_camera())
	_pawn.handle_action_press("cover")
	assert_true(await _settle_free(exit_meter), "exit reached first person")
	_assert_smooth(exit_meter, "exit by Cover")
	await _cleanup()


## Entry by the Cover button from 1.45 m (the pawn walks 1 m onto the wall), and the worst-case turn: facing 70 deg off
## the wall normal with the nearer edge behind, so the automatic turn is about 160 deg.
func test_button_entries_never_snap_including_the_worst_turn() -> void:
	for case in [[Vector3(0.5, 0, 1.45), 0.0, "button from 1.45 m"], [Vector3(1.5, 0, 0.45), 70.0, "button worst turn"]]:
		await _fixture(case[0], 2.2, case[1])
		var meter := Meter.new()
		meter.sample(_rig.get_camera())
		var start_forward := _forward()
		_pawn.handle_action_press("cover")
		assert_true(_pawn.in_cover(), "%s: entered" % case[2])
		var turn_deg := rad_to_deg(start_forward.angle_to(_pawn.cover.tangent * float(_pawn.cover.side)))
		assert_true(await _settle_in_cover(meter), "%s: in cover" % case[2])
		print("C1B CAMERA %s automatic turn %.1f deg" % [case[2], turn_deg])
		_assert_smooth(meter, case[2])
		if case[1] > 0.0:
			assert_true(turn_deg > 150.0, "the worst case really turns more than 150 deg (%.1f)" % turn_deg)
		await _cleanup()


## A walking exit (stick held the whole time) and an exit that skips EXITING (reset, as a lost wall does today): the
## follow's lag eases out, the camera never snaps, and it ends parent-exact at the eye.
func test_every_exit_blends_without_a_snap() -> void:
	for kind in ["walking", "reset"]:
		await _fixture(Vector3(0.0, 0, 0.6))
		_pawn.handle_action_press("cover")
		assert_true(await _settle_in_cover(), "%s: in cover" % kind)
		var meter := Meter.new()
		meter.sample(_rig.get_camera())
		if kind == "walking":
			_pawn.handle_action_press("cover")
			for i in 90:
				await _tick(Vector2(0, 1))
				meter.sample(_rig.get_camera())
		else:
			_pawn.cover.reset()
		assert_true(await _settle_free(meter), "%s: back in first person" % kind)
		_assert_smooth(meter, "exit " + kind)
		assert_true(_rig.position.distance_to(Vector3(0, _fp("eye_height_m"), 0)) < 1e-4, "%s: the rig is parent-exact at the eye (%s)" % [kind, _rig.position])
		await _cleanup()


# ---- pose --------------------------------------------------------------------------------------

## Only the visual model turns: it faces along the wall toward the side, turned out by hug_out_deg.
func test_soldier_hugs_the_wall_facing_along_it() -> void:
	await _fixture(Vector3(1.2, 0, 0.6))
	_pawn.handle_action_press("cover")
	assert_true(await _settle_in_cover(), "in cover")
	var model := _pawn.get_node("SoldierModel") as Node3D
	var anim := _pawn.get_node("CoverAnim") as CoverAnim
	for i in 60:
		anim.sync_pose(DT)
	# The model's facing at rest is the pawn's; its turn away from rest is the pose's world yaw minus the pawn's.
	var yaw := _pawn.global_rotation.y + model.rotation.y - anim._rest_yaw
	var model_forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var out := deg_to_rad(float(_cover_cfg()["animation"]["hug_out_deg"]))
	var want := (_pawn.cover.tangent * float(_pawn.cover.side) * cos(out) + _pawn.cover.normal * sin(out)).normalized()
	assert_true(model_forward.dot(want) > 0.999, "the soldier faces along the wall, turned out by hug_out_deg (%s vs %s)" % [model_forward, want])
	assert_true(model_forward.dot(-_pawn.cover.normal) < 0.0, "its back, not its face, is toward the wall")
	assert_eq(_pawn.global_rotation.x, 0.0, "the pawn itself only yaws")
	await _cleanup()


# ---- automatic crouch --------------------------------------------------------------------------

func _capsule() -> CapsuleShape3D:
	return _pawn.get_node("CollisionShape3D").shape as CapsuleShape3D


func test_auto_crouch_behind_low_cover_and_standing_behind_high_cover() -> void:
	var cfg := _cover_cfg()
	var muzzle := float(DataRegistry.new().get_movement_cfg()["muzzle_height_m"])
	for height: float in [1.0, 2.2]:
		await _fixture(Vector3(0, 0, 0.6), height)
		var standing := _capsule().height
		var head_y := (_pawn.get_node("Head") as Node3D).position.y
		_pawn.handle_action_press("cover")
		assert_true(await _settle_in_cover(), "height %s: in cover" % height)
		for i in ceili(float(cfg["crouch_blend_s"]) / DT) + 2:
			await _tick()
		var low: bool = height < muzzle
		assert_eq(_pawn.cover.crouched, low, "height %s: crouched iff below muzzle_height_m %s" % [height, muzzle])
		assert_eq(_pawn.cover.crouch_amount, 1.0 if low else 0.0, "height %s: crouch amount" % height)
		var want_h := maxf(float(cfg["crouch_height_m"]), _capsule().radius * 2.0) if low else standing
		assert_true(absf(_capsule().height - want_h) < EPS, "height %s: capsule follows the crouch (%s)" % [height, _capsule().height])
		var want_head := float(cfg["crouch_head_y_m"]) if low else head_y
		assert_true(absf((_pawn.get_node("Head") as Node3D).position.y - want_head) < EPS, "height %s: the head hitbox follows" % height)
		if low:
			assert_true(absf(_rig.position.y - _cover_cam("crouch_height_m")) < 0.02, "the camera pivot is lower behind low cover (%s)" % _rig.position.y)
		# The crouch press does nothing in cover. M2 C1b stage 4: CoverController.toggle_crouch is deleted (was also
		# called here and asserted ignored).
		_pawn.handle_action_press("crouch")
		for i in ceili(float(cfg["crouch_blend_s"]) / DT) + 2:
			await _tick()
		assert_eq(_pawn.cover.crouched, low, "height %s: the crouch press is ignored in cover" % height)
		assert_true(not _pawn.cover.has_method("toggle_crouch"), "the old crouch toggle is gone")
		# Leaving cover stands up.
		_pawn.handle_action_press("cover")
		assert_true(await _settle_free(), "height %s: exit" % height)
		assert_true(not _pawn.cover.crouched and absf(_capsule().height - standing) < EPS, "height %s: standing after the exit" % height)
		await _cleanup()


## Pure controller: the stance follows a height change (a low to a high section), and standing waits for stand_clear.
func test_crouch_follows_a_height_change_and_respects_stand_clear() -> void:
	var cfg := _cover_cfg()
	var c := CoverController.new(cfg)
	var facts := {"hit": true, "wall_key": 1, "normal": Vector3.BACK, "point": Vector3.ZERO, "position": Vector3(0, 0, 0.45),
		"basis": Basis.IDENTITY, "distance_m": 0.45, "left_m": 2.0, "right_m": 2.0, "height_m": 1.0, "muzzle_height_m": 1.3,
		"slide_speed_mps": 4.0, "shot_clear": true, "stand_clear": true}
	assert_true(c.request_cover(facts), "entered")
	var ticks := ceili(float(cfg["crouch_blend_s"]) / DT) + 2
	for i in ticks:
		c.tick(DT, Vector2.ZERO, false, facts)
	assert_true(c.crouched and c.crouch_amount == 1.0, "low: crouched")
	facts["height_m"] = 2.2
	facts["stand_clear"] = false
	for i in ticks:
		c.tick(DT, Vector2.ZERO, false, facts)
	assert_true(not c.crouched and c.crouch_amount == 1.0, "high but blocked overhead: stays down")
	facts["stand_clear"] = true
	for i in ticks:
		c.tick(DT, Vector2.ZERO, false, facts)
	assert_eq(c.crouch_amount, 0.0, "high and clear: stands")
	facts["height_m"] = 1.0
	for i in ticks:
		c.tick(DT, Vector2.ZERO, false, facts)
	assert_eq(c.crouch_amount, 1.0, "low again: crouches")
	var lost := facts.duplicate()
	lost.erase("height_m")
	c.tick(DT, Vector2.ZERO, false, lost)
	assert_true(c.crouched, "a tick without the height keeps the stance")
