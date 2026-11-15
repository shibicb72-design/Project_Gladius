extends "res://tests/test_case.gd"
## M2 C1a stage 1: the CameraRig first-person mode and its blend (data/camera.json first_person, OQ-FIRST-PERSON).
## First person = the local pawn (rig, no Brain) ALIVE, on the ground, cover FREE; third person everywhere else,
## including a rig with no Pawn parent. Fixture style follows tests/test_cover_pawn.gd (manual pawn ticks).

const DT := 1.0 / 60.0
const EPS := 1e-4
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")

var _root: Node3D
var _pawn: Pawn
var _rig: CameraRig


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cam_cfg() -> Dictionary:
	return DataRegistry.new().get_camera_cfg()


func _fp(key: String) -> float:
	return float(_cam_cfg()["first_person"][key]["value"])


## Floor, a cover wall whose face is at z = 0 (as in test_cover_pawn.gd), a pawn in front of it facing it.
func _fixture(with_rig: bool = true, with_brain: bool = false, with_cover: bool = true, parent: Node = null) -> void:
	_root = Node3D.new()
	(parent if parent != null else _tree().root).add_child(_root)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(30, 0.2, 30)
	floor_shape.shape = floor_box
	floor_body.position.y = -0.1
	floor_body.add_child(floor_shape)
	_root.add_child(floor_body)
	var wall := StaticBody3D.new()
	wall.add_to_group(&"cover_wall")
	wall.position = Vector3(0, 1.1, -0.5)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, 2.2, 1)
	shape.shape = box
	wall.add_child(shape)
	_root.add_child(wall)
	_pawn = _PawnScene.instantiate()
	_pawn.position = Vector3(0, 0, 0.6)
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	if with_cover:
		_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	if with_brain:
		var brain := Node.new()
		brain.name = "Brain"
		_pawn.add_child(brain)
	if with_rig:
		_rig = _RigScene.instantiate()
		_rig.name = "CameraRig"
		_pawn.add_child(_rig)
	await _tree().physics_frame
	await _tree().physics_frame


func _tick(move: Vector2) -> void:
	var frame := InputFrame.new()
	frame.move = move
	_pawn.set_frame(frame)
	_pawn._physics_process(DT)
	await _tree().physics_frame


func _cleanup() -> void:
	_root.queue_free()
	_root = null
	_rig = null
	await _tree().process_frame


func _frames(n: int) -> void:
	for i in n:
		await _tree().physics_frame


func _eye() -> Vector3:
	return _pawn.global_transform * Vector3(0, _fp("eye_height_m"), 0)


## Per-frame camera motion over a sequence of moves; returns [max step m, max turn deg, max pawn step m].
class Meter:
	var last: Transform3D
	var last_pawn: Vector3
	var started := false
	var max_m := 0.0
	var max_deg := 0.0
	var max_pawn_m := 0.0
	## Largest camera step on a frame in which the pawn itself did not move (pure blend / follow).
	var max_still_m := 0.0

	func sample(cam: Camera3D, pawn: Node3D) -> void:
		var xf := cam.global_transform
		var p := pawn.global_position
		if started:
			var step := xf.origin.distance_to(last.origin)
			var turn := rad_to_deg((last.basis.get_rotation_quaternion().inverse() * xf.basis.get_rotation_quaternion()).get_angle())
			var pawn_step := p.distance_to(last_pawn)
			max_m = maxf(max_m, step)
			max_deg = maxf(max_deg, turn)
			max_pawn_m = maxf(max_pawn_m, pawn_step)
			if pawn_step < 1e-5:
				max_still_m = maxf(max_still_m, step)
		last = xf
		last_pawn = p
		started = true


## Fix 7: a real FREE -> cover -> FREE cycle, no look input, no knockback; the camera moves under smooth_max_step_m
## and turns under smooth_max_step_deg on every physics frame, and the cycle really reaches third and first person.
func test_free_cover_free_cycle_is_smooth() -> void:
	await _fixture()
	var cfg := _cam_cfg()
	var max_m := _fp("smooth_max_step_m")
	var max_deg := _fp("smooth_max_step_deg")
	var hip := float(cfg["arm_length_m"])
	var cam := _rig.get_camera()
	assert_eq(_rig.get_first_person_weight(), 1.0, "local pawn starts in first person (snap, no blend)")
	assert_true(_rig.get_spring_length() == 0.0, "first person: spring 0")
	var meter := Meter.new()
	meter.sample(cam, _pawn)
	# Into cover: push at the wall until the controller auto-snaps, then let go of the stick (M2 C1b: the automatic
	# turn looks along the wall, so a held forward stick would now slide) while the blend reaches third person.
	var reached_third := false
	var saw_entering := false
	for i in 150:
		await _tick(Vector2(0, -1) if _pawn.cover.state == CoverController.State.FREE and not saw_entering else Vector2.ZERO)
		meter.sample(cam, _pawn)
		saw_entering = saw_entering or _pawn.cover.state == CoverController.State.ENTERING
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0:
			reached_third = true
			break
	assert_true(saw_entering and reached_third, "real cover entry reached third person (state %s, weight %s)" % [_pawn.cover.state, _rig.get_first_person_weight()])
	assert_true(not _rig.is_first_person(), "in cover: third person wanted")
	# M2 C1b stage 2: the close cover view (camera.json cover.distance_m), not today's arm_length_m.
	var cover_len := float(cfg["cover"]["distance_m"]["value"])
	assert_true(hip > cover_len and absf(_rig.get_spring_length() - cover_len) < EPS, "in cover: spring at the cover value %s (got %s)" % [cover_len, _rig.get_spring_length()])
	var enter := [meter.max_m, meter.max_deg, meter.max_pawn_m, meter.max_still_m]
	# Settle the cover follow, then leave with the Cover button (M2 C1b: the new exit method), then no input.
	for i in 30:
		await _tick(Vector2.ZERO)
		meter.sample(cam, _pawn)
	_pawn.handle_action_press("cover")
	await _tick(Vector2.ZERO)
	meter.sample(cam, _pawn)
	assert_eq(_pawn.cover.state, CoverController.State.EXITING, "the Cover button starts the real exit")
	var reached_first := false
	for i in 150:
		await _tick(Vector2.ZERO)
		meter.sample(cam, _pawn)
		if _pawn.cover.state == CoverController.State.FREE and _rig.get_first_person_weight() == 1.0:
			reached_first = true
			break
	assert_true(reached_first, "exit returned to first person (state %s, weight %s)" % [_pawn.cover.state, _rig.get_first_person_weight()])
	assert_true(_rig.get_spring_length() == 0.0, "back in first person: spring 0")
	assert_true(cam.global_position.distance_to(_eye()) < 0.001, "back in first person: camera at the eye (%s vs %s)" % [cam.global_position, _eye()])
	print("FP SMOOTH cycle max_step_m=%.4f max_turn_deg=%.4f max_pawn_step_m=%.4f max_step_pawn_still_m=%.4f | enter: max_step_m=%.4f max_turn_deg=%.4f max_pawn_step_m=%.4f max_step_pawn_still_m=%.4f (limits %.2f m, %.1f deg, blend_s %.2f)" % [
			meter.max_m, meter.max_deg, meter.max_pawn_m, meter.max_still_m, enter[0], enter[1], enter[2], enter[3], max_m, max_deg, _fp("blend_s")])
	assert_true(meter.max_m < max_m, "per-frame camera move %.4f m < %.2f m" % [meter.max_m, max_m])
	assert_true(meter.max_deg < max_deg, "per-frame camera turn %.4f deg < %.1f deg" % [meter.max_deg, max_deg])
	await _cleanup()


## Measured only (not fix 7's still cycle): backing out of cover with the stick held the whole time, so the pawn walks
## while the cover follow lags and the blend runs. Prints the maxima; asserts only that first person returns.
func test_moving_exit_measured() -> void:
	await _fixture()
	var cam := _rig.get_camera()
	for i in 150:
		await _tick(Vector2(0, -1) if _pawn.cover.state == CoverController.State.FREE else Vector2.ZERO)
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0:
			break
	for i in 30:
		await _tick(Vector2.ZERO)
	var meter := Meter.new()
	meter.sample(cam, _pawn)
	var reached_first := false
	# M2 C1b stage 2: the Cover button starts the exit (the automatic turn means back stick no longer points away from
	# the wall); the stick is then held back the whole time, so the pawn walks while the exit blend runs.
	_pawn.handle_action_press("cover")
	for i in 150:
		await _tick(Vector2(0, 1))
		meter.sample(cam, _pawn)
		if _pawn.cover.state == CoverController.State.FREE and _rig.get_first_person_weight() == 1.0:
			reached_first = true
			break
	assert_true(reached_first, "moving exit returned to first person")
	print("FP SMOOTH moving exit max_step_m=%.4f max_turn_deg=%.4f max_pawn_step_m=%.4f" % [meter.max_m, meter.max_deg, meter.max_pawn_m])
	await _cleanup()


func test_rig_without_pawn_parent_stays_third_person() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var rig: CameraRig = _RigScene.instantiate()
	root.add_child(rig)
	await _frames(2)
	var cfg := _cam_cfg()
	assert_true(not rig.is_first_person(), "no Pawn parent: third person")
	assert_eq(rig.get_first_person_weight(), 0.0, "no Pawn parent: weight 0")
	assert_true(absf(rig.get_spring_length() - float(cfg["arm_length_m"])) < EPS, "today's hip spring length")
	assert_true(absf(rig.position.y - float(cfg["height_m"])) < EPS, "today's rig height")
	assert_true(absf(rig.get_node("SpringArm3D").position.x - float(cfg["shoulder_offset_m"]["value"])) < EPS, "today's shoulder offset")
	root.queue_free()
	await _tree().process_frame


func test_pawn_with_brain_stays_third_person() -> void:
	await _fixture(true, true, false)
	assert_true(not _rig.is_first_person(), "bot pawn (Brain): third person")
	assert_eq(_rig.get_first_person_weight(), 0.0, "bot pawn: weight 0")
	assert_true(absf(_rig.get_spring_length() - float(_cam_cfg()["arm_length_m"])) < EPS, "bot pawn: hip spring length")
	await _cleanup()


func test_local_pawn_free_is_first_person_at_the_eye() -> void:
	await _fixture()
	var cam := _rig.get_camera()
	assert_true(_rig.is_first_person(), "local pawn FREE: first person")
	assert_eq(_rig.get_first_person_weight(), 1.0, "weight 1")
	assert_eq(_rig.get_spring_length(), 0.0, "spring 0")
	assert_eq(_rig.get_node("SpringArm3D").position.x, 0.0, "no shoulder side offset in first person")
	assert_true(cam.global_position.distance_to(_eye()) < 0.001, "camera at the eye (%s vs %s)" % [cam.global_position, _eye()])
	assert_true(absf(cam.fov - _rig.base_fov * _fp("fov_mult")) < EPS, "first-person FOV = base_fov * fov_mult")
	await _cleanup()


func test_downed_aboard_and_falling_are_third_person() -> void:
	var settle := ceili(_fp("blend_s") / DT) + 3
	for mode in ["downed", "aboard", "falling"]:
		await _fixture(true, false, false)
		match mode:
			"downed":
				_pawn.life = Pawn.Life.DOWNED
			"aboard":
				_pawn.drop_state = Pawn.Drop.ABOARD
			"falling":
				_pawn.drop_state = Pawn.Drop.FALLING
		assert_true(not _rig.is_first_person(), "%s: third person wanted" % mode)
		await _frames(settle)
		assert_eq(_rig.get_first_person_weight(), 0.0, "%s: blended to third person" % mode)
		assert_true(absf(_rig.get_spring_length() - float(_cam_cfg()["arm_length_m"])) < EPS, "%s: hip spring length" % mode)
		_pawn.life = Pawn.Life.ALIVE
		_pawn.drop_state = Pawn.Drop.NONE
		await _frames(settle)
		assert_eq(_rig.get_first_person_weight(), 1.0, "%s: back to first person" % mode)
		await _cleanup()


func test_swap_shoulder_ignored_in_first_person() -> void:
	await _fixture(true, false, false)
	var side := _rig.shoulder_side
	_rig.swap_shoulder()
	_rig.set_shoulder_side("left" if side == "right" else "right")
	await _frames(3)
	assert_eq(_rig.shoulder_side, side, "first person ignores the shoulder swap")
	assert_eq(_rig.get_node("SpringArm3D").position.x, 0.0, "no side offset after a swap in first person")
	# Third person (downed) still swaps.
	_pawn.life = Pawn.Life.DOWNED
	_rig.swap_shoulder()
	assert_true(_rig.shoulder_side != side, "third person still swaps")
	await _cleanup()


func test_ads_in_first_person_keeps_spring_zero_and_zooms() -> void:
	await _fixture(true, false, false)
	var hip_fov := _rig.get_fov()
	_rig.set_aim_blend(1.0, 0.6)
	assert_eq(_rig.get_spring_length(), 0.0, "ADS in first person: spring stays 0")
	assert_true(absf(_rig.get_fov() - hip_fov * 0.6) < EPS, "ADS zooms the FOV by aim_fov_mult (%s vs %s)" % [_rig.get_fov(), hip_fov * 0.6])
	await _frames(2)
	assert_eq(_rig.get_spring_length(), 0.0, "ADS in first person: spring stays 0 after physics frames")
	_rig.set_aim_blend(0.0, 0.6)
	assert_true(absf(_rig.get_fov() - hip_fov) < EPS, "ADS off restores the FOV")
	await _cleanup()


## The test_camera_knockback rule in first person: a kick in progress never moves get_aim_point.
func test_first_person_kick_never_moves_the_aim_point() -> void:
	for with_wall in [true, false]:
		await _fixture(true, false, false)
		_pawn.rotation.y = 0.7
		_pawn.global_position = Vector3(2.0, 0.0, 5.0)
		await _frames(2)
		_rig.set_pitch(0.05)
		var cam := _rig.get_camera()
		assert_eq(_rig.get_first_person_weight(), 1.0, "kick case runs in first person")
		if with_wall:
			var wall := StaticBody3D.new()
			wall.collision_layer = Hitscan.MASK_WORLD
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(40.0, 40.0, 0.5)
			shape.shape = box
			wall.add_child(shape)
			_root.add_child(wall)
			var xf := cam.global_transform
			wall.global_transform = Transform3D(xf.basis, xf.origin - xf.basis.z * 10.0)
			await _tree().physics_frame
		var tag := "fp wall" if with_wall else "fp far point"
		var exclude: Array[RID] = _pawn.hitscan_exclude()
		var fwd_before := -cam.global_transform.basis.z
		var aim_before := _rig.get_aim_point(exclude)
		_rig.knockback.pitch_rad = deg_to_rad(4.0)
		_rig.knockback.yaw_rad = deg_to_rad(3.0)
		_rig.apply_knockback()
		var fwd_after := -cam.global_transform.basis.z
		assert_true(fwd_before.angle_to(fwd_after) > deg_to_rad(3.0), "%s: the view turned" % tag)
		var aim_after := _rig.get_aim_point(exclude)
		var tol := 1e-3 if with_wall else 1e-2
		assert_true(aim_after.distance_to(aim_before) < tol, "%s: aim point unchanged by the kick (%s vs %s)" % [tag, aim_after, aim_before])
		if with_wall:
			assert_true(aim_before.distance_to(cam.global_position) < 12.0, "%s: the aim ray hit the wall (%s)" % [tag, aim_before])
		_rig.knockback.reset()
		_rig.set_pitch(0.05)
		assert_true(_rig.get_aim_point(exclude).distance_to(aim_before) < tol, "%s: same point again at rest" % tag)
		await _cleanup()


# --- stage 2: the view model (scripts/visual/view_model.gd, data/camera.json first_person.view_model) ---------------

func _vm_cfg() -> Dictionary:
	return _cam_cfg()["first_person"]["view_model"]


func _vm_f(key: String) -> float:
	return float(_vm_cfg()[key]["value"])


func _vm_frames(seconds: float) -> int:
	return ceili(seconds / DT) + 3


func _view_models(cam: Camera3D) -> Array:
	return cam.find_children("*", "", true, false).filter(func(n: Node) -> bool: return n is ViewModel)


## Exactly one view model under the local pawn's camera; none for a Brain pawn, a rig without a pawn, or before the
## Brain is removed (test_cover_pawn.gd:133-141 order: rig added, then the Brain removed).
func test_view_model_only_for_the_local_pawn() -> void:
	await _fixture(true, false, false)
	var vms := _view_models(_rig.get_camera())
	assert_eq(vms.size(), 1, "local pawn: exactly one view model under the camera")
	assert_true(vms.size() == 1 and vms[0].get_parent() == _rig.get_camera(), "it rides on the rig's Camera3D")
	assert_true(_rig.get_view_model() == vms[0], "the rig reports it")
	await _frames(5)
	assert_eq(_view_models(_rig.get_camera()).size(), 1, "still one after more frames")
	await _cleanup()
	await _fixture(true, true, false)
	assert_eq(_view_models(_rig.get_camera()).size(), 0, "Brain pawn: no view model")
	var brain := _pawn.get_node("Brain")
	_pawn.remove_child(brain)
	brain.free()
	await _frames(2)
	assert_eq(_view_models(_rig.get_camera()).size(), 1, "Brain removed after the rig: the view model arrives lazily")
	await _cleanup()
	var root := Node3D.new()
	_tree().root.add_child(root)
	var rig: CameraRig = _RigScene.instantiate()
	root.add_child(rig)
	await _frames(2)
	assert_eq(_view_models(rig.get_camera()).size(), 0, "rig without a pawn: no view model")
	assert_true(rig.get_view_model() == null, "rig without a pawn reports none")
	root.queue_free()
	await _tree().process_frame


func test_view_model_shown_in_first_person_only() -> void:
	var settle := _vm_frames(_fp("blend_s"))
	await _fixture(true, false, false)
	var vm := _rig.get_view_model()
	assert_true(vm.visible, "first person: visible")
	for mode in ["downed", "falling"]:
		if mode == "downed":
			_pawn.life = Pawn.Life.DOWNED
		else:
			_pawn.drop_state = Pawn.Drop.FALLING
		await _frames(settle)
		assert_true(not vm.is_visible_in_tree(), "%s: hidden" % mode)
		_pawn.life = Pawn.Life.ALIVE
		_pawn.drop_state = Pawn.Drop.NONE
		await _frames(settle)
		assert_true(vm.is_visible_in_tree(), "%s over: shown again" % mode)
	await _cleanup()
	# Real cover entry: hidden once the blend has gone below show_weight, and in cover.
	await _fixture()
	vm = _rig.get_view_model()
	var hid_at := -1.0
	for i in 150:
		await _tick(Vector2(0, -1))
		if hid_at < 0.0 and not vm.visible:
			hid_at = _rig.get_first_person_weight()
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0:
			break
	assert_true(not vm.is_visible_in_tree(), "in cover: hidden")
	assert_true(hid_at >= 0.0 and hid_at < _vm_f("show_weight"), "hid below show_weight (at %s)" % hid_at)
	await _cleanup()


## The active weapon is shown; weapon_switched lowers, swaps at the half and raises; reload_started runs for the
## weapon's real reload_s; fired swings the blade and kicks a gun; every motion ends.
func test_view_model_follows_weapon_and_motions() -> void:
	await _fixture(true, false, false)
	var vm := _rig.get_view_model()
	var gun := _pawn.loadout.get_active()
	assert_eq(vm.get_shown_weapon_id(), gun.def.id, "shows the active weapon (%s)" % gun.def.id)
	# Reload: the gun's own reload time.
	_pawn.reload_started.emit()
	assert_true(vm.is_reloading(), "reload_started starts the reload motion")
	await _frames(ceili(gun.def.reload_s / DT) - 6)
	assert_true(vm.is_reloading(), "the reload motion lasts about reload_s (%s s)" % gun.def.reload_s)
	await _frames(10)
	assert_true(not vm.is_reloading(), "the reload motion ends")
	# Gun shot: a kick that recovers.
	_pawn.fired.emit()
	assert_true(vm.is_recoiling() and not vm.is_swinging(), "fired with a gun: kick, no swing")
	await _frames(_vm_frames(_vm_f("recoil_s")))
	assert_true(not vm.is_recoiling(), "the kick recovers")
	# Swap to the blade.
	assert_true(_pawn.loadout.swap(), "the loadout has a second weapon")
	var blade := _pawn.loadout.get_active()
	_pawn.weapon_switched.emit(_pawn.loadout.active)
	assert_true(vm.is_swapping(), "weapon_switched starts the swap motion")
	await _frames(2)
	assert_eq(vm.get_shown_weapon_id(), gun.def.id, "the old weapon goes down first")
	await _frames(_vm_frames(_vm_f("swap_s")))
	assert_true(not vm.is_swapping(), "the swap motion ends")
	assert_eq(vm.get_shown_weapon_id(), blade.def.id, "then the new weapon is shown (%s)" % blade.def.id)
	assert_true(blade.def.is_melee(), "the second weapon is the blade")
	# Melee: fired plays the swing (fix 9).
	_pawn.reload_started.emit()
	assert_true(not vm.is_reloading(), "no reload motion for the blade")
	_pawn.fired.emit()
	assert_true(vm.is_swinging() and not vm.is_recoiling(), "fired with the blade: swing, no kick")
	await _frames(_vm_frames(_vm_f("swing_s")))
	assert_true(not vm.is_swinging(), "the swing ends")
	await _cleanup()


## Fix 1: a real ranged shot shows the view model's own tracer from its muzzle to the shot's end, and it expires; the
## third-person ShotFx tracer still runs. Hidden (third person): no view-model tracer.
func test_view_model_tracer_from_its_muzzle() -> void:
	await _fixture(true, false, false)
	var vm := _rig.get_view_model()
	await _frames(2)
	var seen := {}
	_pawn.shot_fx.shot_shown.connect(func(_o: Vector3, e: Vector3) -> void:
		seen["end"] = e
		seen["muzzle"] = vm.get_muzzle_position())
	var res := _pawn.fire_shot()
	assert_true(res.has("position"), "the shot hit the wall ahead")
	assert_true(vm.is_tracer_visible() and vm.is_flash_visible(), "view-model tracer and flash shown")
	assert_true(_pawn.shot_fx.is_tracer_visible(), "the third-person ShotFx tracer still runs (stage 4 hides it by layer)")
	var ep := vm.get_tracer_endpoints()
	assert_true(ep[0].distance_to(seen["muzzle"]) < 0.001, "tracer starts at the view-model muzzle (%s vs %s)" % [ep[0], seen["muzzle"]])
	assert_true(ep[1].distance_to(seen["end"]) < 0.001, "tracer ends at the shot end (%s vs %s)" % [ep[1], seen["end"]])
	assert_true(ep[0].distance_to(_rig.get_camera().global_position) < _vm_f("max_reach_m"), "the muzzle is near the eye")
	assert_true(ep[0].distance_to(_pawn.get_muzzle_position()) > 0.05, "not the gameplay muzzle (presentation only)")
	await _frames(_vm_frames(maxf(_vm_f("tracer_s"), _vm_f("flash_s"))))
	assert_true(not vm.is_tracer_visible() and not vm.is_flash_visible(), "tracer and flash expire")
	_pawn.life = Pawn.Life.DOWNED
	await _frames(_vm_frames(_fp("blend_s")))
	_pawn.show_shot_fx(_pawn.get_muzzle_position(), _pawn.get_muzzle_position() + Vector3(0, 0, -10))
	assert_true(not vm.is_tracer_visible(), "third person: no view-model tracer")
	await _cleanup()


## Presentation only: no physics bodies or shapes, and get_aim_point is the same with and without the view model.
func test_view_model_adds_no_bodies_and_keeps_the_aim_point() -> void:
	await _fixture(true, false, false)
	var vm := _rig.get_view_model()
	assert_eq(vm.find_children("*", "CollisionObject3D", true, false).size(), 0, "no collision objects")
	assert_eq(vm.find_children("*", "CollisionShape3D", true, false).size(), 0, "no collision shapes")
	var exclude: Array[RID] = _pawn.hitscan_exclude()
	var aim_with := _rig.get_aim_point(exclude)
	var muzzle_with := _pawn.get_muzzle_position()
	vm.free()
	var aim_without := _rig.get_aim_point(exclude)
	assert_true(aim_with.distance_to(aim_without) < 1e-4, "aim point unchanged (%s vs %s)" % [aim_with, aim_without])
	assert_true(muzzle_with.distance_to(_pawn.get_muzzle_position()) < 1e-6, "gameplay muzzle unchanged")
	await _cleanup()


## Fix 12 option (a): at rest every view-model vertex of each weapon lies between the camera near plane and max_reach_m
## from the eye, inside the pawn's capsule radius, so walls held off by the capsule never cut the model.
func test_view_model_stays_inside_the_capsule() -> void:
	var reach := _vm_f("max_reach_m")
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(true, false, false)
		if class_id != "hastati":
			_pawn.setup(class_id, 0)
		var capsule := (_pawn.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
		var cam := _rig.get_camera()
		var vm := _rig.get_view_model()
		for slot in 2:
			await _frames(_vm_frames(_vm_f("swap_s")))
			var to_cam := cam.global_transform.affine_inverse()
			var far := 0.0
			var near := INF
			var meshes := 0
			for mi in vm.mesh_instances():
				if mi == vm.tracer or mi == vm.flash or not mi.is_visible_in_tree():
					continue
				meshes += 1
				var xf := to_cam * mi.global_transform
				for v in mi.mesh.get_faces():
					var d := (xf * v).length()
					far = maxf(far, d)
					near = minf(near, d)
			var id := vm.get_shown_weapon_id()
			print("FP VIEW MODEL %s reach_m=%.4f nearest_m=%.4f meshes=%d (limit %.2f, capsule %.2f, near %.3f, nodes %d)" % [
					id, far, near, meshes, reach, capsule.radius, cam.near, vm.find_children("*", "", true, false).size()])
			assert_true(meshes >= 2, "%s: weapon and arm meshes shown" % id)
			assert_true(far < reach and reach < capsule.radius, "%s: reach %.4f < %.2f < capsule %.2f" % [id, far, reach, capsule.radius])
			assert_true(near > cam.near, "%s: nearest vertex %.4f beyond the near plane %.3f" % [id, near, cam.near])
			_pawn.loadout.swap()
			_pawn.weapon_switched.emit(_pawn.loadout.active)
		await _cleanup()


# --- stage 3: aiming and ADS in first person (spec item 4, fix 8) ---------------------------------------------------

## The Fold cover / phone row, a 4:3 tablet row and the Fold inner row of camera.json fov_table.
const ADS_SIZES: Array[Vector2i] = [Vector2i(2520, 1080), Vector2i(2048, 1536), Vector2i(2176, 1812)]
const DOT_TOL_PX := 2.0


func _aim_cfg() -> Dictionary:
	return DataRegistry.new().load_file(DataRegistry.STATS_PATH)["aim"]


## Physics ticks for aim_blend to go all the way (stats.json aim.aim_zoom_s) plus a margin.
func _aim_ticks() -> int:
	return ceili(float(_aim_cfg()["aim_zoom_s"]) / DT) + 3


## One manual pawn tick with ADS held (InputFrame.aim_pressed, as AimToggle resolves the tap toggle), optionally with
## the trigger pulled this tick.
func _tick_aim(aim: bool, fire: bool = false) -> void:
	var frame := InputFrame.new()
	frame.aim_pressed = aim
	frame.fire_pressed = fire
	frame.fire_just_pressed = fire
	_pawn.set_frame(frame)
	_pawn._physics_process(DT)
	await _tree().physics_frame


func _aim_down(aim: bool) -> void:
	for i in _aim_ticks():
		await _tick_aim(aim)


## At full ADS in first person the red dot projects to the screen centre (within DOT_TOL_PX) in front of the near plane,
## the gun points straight ahead, the FOV is zoomed by aim_fov_mult and spread is aim_spread_mult; ADS off restores
## them. Each size runs in a SubViewport of that size (test only), so the rig takes that size's fov_table row.
func test_full_ads_puts_the_red_dot_on_the_screen_centre() -> void:
	var aim := _aim_cfg()
	for sz in ADS_SIZES:
		for class_id in ["hastati", "sagittarii"]:
			var svp := SubViewport.new()
			svp.size = sz
			_tree().root.add_child(svp)
			await _fixture(true, false, false, svp)
			if class_id != "hastati":
				_pawn.setup(class_id, 0)
				await _frames(2)
			var cam := _rig.get_camera()
			var vm := _rig.get_view_model()
			var id := vm.get_shown_weapon_id()
			var tag := "%s %dx%d" % [id, sz.x, sz.y]
			var centre := Vector2(sz) * 0.5
			assert_true(absf(_rig.base_fov - CameraRig.fov_for_aspect(_cam_cfg(), float(sz.x) / sz.y)) < EPS,
					"%s: the rig uses this size's fov row (%s)" % [tag, _rig.base_fov])
			var hip_fov := cam.fov
			assert_true(vm.get_red_dot() != null and vm.get_ads_weight() == 0.0, "%s: a gun with a red dot, at the hip" % tag)
			await _tick_aim(true)
			var mid_px := cam.unproject_position(vm.get_red_dot().global_position).distance_to(centre)
			await _aim_down(true)
			assert_true(_pawn.aiming and _pawn.aim_blend == 1.0 and vm.get_ads_weight() == 1.0, "%s: full ADS" % tag)
			var dot := vm.get_red_dot()
			var px := cam.unproject_position(dot.global_position)
			var depth := -(cam.global_transform.affine_inverse() * dot.global_position).z
			var gun := dot.get_parent().get_parent() as Node3D
			var turn := rad_to_deg((-gun.global_basis.z).angle_to(-cam.global_basis.z))
			print("FP ADS DOT %s fov=%.1f->%.1f dot_px=%s err_px=%.3f (first ADS tick %.1f px) depth_m=%.4f near=%.3f gun_turn_deg=%.4f" % [
					tag, hip_fov, cam.fov, px, px.distance_to(centre), mid_px, depth, cam.near, turn])
			assert_true(dot.is_visible_in_tree(), "%s: the red dot is shown" % tag)
			assert_true(px.distance_to(centre) <= DOT_TOL_PX, "%s: dot %s on the screen centre %s" % [tag, px, centre])
			assert_true(depth > cam.near, "%s: dot depth %.4f in front of the near plane %.3f" % [tag, depth, cam.near])
			assert_true(turn < 0.5, "%s: the gun points straight ahead (%.3f deg off)" % [tag, turn])
			assert_true(absf(cam.fov - hip_fov * float(aim["aim_fov_mult"])) < 1e-3, "%s: FOV zoomed by aim_fov_mult" % tag)
			assert_true(absf(_pawn.get_spread_mult() - float(aim["aim_spread_mult"])) < EPS, "%s: aim_spread_mult while aiming" % tag)
			await _aim_down(false)
			assert_true(vm.get_ads_weight() == 0.0 and absf(cam.fov - hip_fov) < 1e-3, "%s: ADS off: hip pose and FOV" % tag)
			assert_eq(_pawn.get_spread_mult(), 1.0, "%s: ADS off: hip spread" % tag)
			await _cleanup()
			svp.queue_free()
			await _tree().process_frame


## Item 4 in first person: the aim point is on the camera's centre ray from the eye; a real ADS shot moves the real aim
## (stats.json recoil) as today, while the view-model kick and the camera knockback leave get_aim_point on the
## un-kicked look ray.
func test_first_person_ads_aim_point_recoil_and_kick() -> void:
	await _fixture(true, false, false)
	var cam := _rig.get_camera()
	var vm := _rig.get_view_model()
	var exclude: Array[RID] = _pawn.hitscan_exclude()
	await _aim_down(true)
	assert_true(vm.get_ads_weight() == 1.0, "full ADS")
	assert_true(cam.global_position.distance_to(_eye()) < 1e-3, "the camera is at the eye (%s vs %s)" % [cam.global_position, _eye()])
	var aim := _rig.get_aim_point(exclude)
	var off := rad_to_deg((aim - cam.global_position).angle_to(-cam.global_basis.z))
	assert_true(off < 0.05, "aim point on the camera's centre ray (%.4f deg off)" % off)
	var w := _pawn.loadout.get_active()
	var recoil: Dictionary = DataRegistry.new().load_file(DataRegistry.STATS_PATH)["weapons"][w.def.id]["recoil"]
	var pitch_before := _pawn.pitch
	var yaw_before := _pawn.global_rotation.y
	var ammo_before := w.ammo_in_mag
	await _tick_aim(true, true)
	assert_eq(w.ammo_in_mag, ammo_before - 1, "a real shot was fired while aiming")
	var climb := rad_to_deg(_pawn.pitch - pitch_before)
	var drift := rad_to_deg(absf(wrapf(_pawn.global_rotation.y - yaw_before, -PI, PI)))
	print("FP ADS RECOIL %s climb_deg=%.4f drift_deg=%.4f knockback=%s vm_kick=%s" % [w.def.id, climb, drift, _rig.get_knockback(), vm.is_recoiling()])
	assert_true(absf(climb - float(recoil["pitch_deg"])) < 1e-3, "real recoil climbs pawn.pitch by pitch_deg (%.4f)" % climb)
	assert_true(drift <= float(recoil["yaw_deg"]) + 1e-3, "real recoil drifts the yaw by at most yaw_deg (%.4f)" % drift)
	assert_true(vm.is_recoiling() and _rig.get_knockback() != Vector2.ZERO, "the view-model kick and the camera knockback run")
	var look_dir := _pawn.global_basis * Basis.from_euler(Vector3(_pawn.pitch, 0.0, 0.0)) * Vector3.FORWARD
	var kicked := rad_to_deg((-cam.global_basis.z).angle_to(look_dir))
	var aim_after := _rig.get_aim_point(exclude)
	var aim_off := rad_to_deg((aim_after - _eye()).angle_to(look_dir))
	assert_true(kicked > 0.5, "the view is kicked off the look ray (%.3f deg)" % kicked)
	assert_true(aim_off < 0.05, "the aim point stays on the un-kicked look ray from the eye (%.4f deg off)" % aim_off)
	await _cleanup()


## Fix 8: the HUD crosshair hides at full ADS in first person with a gun and returns after ADS off; the threshold is
## camera.json first_person.crosshair_hide_aim_blend. Third person (falling), the blade and a HUD whose pawn has no rig
## keep today's crosshair, ADS included.
func test_crosshair_hides_at_full_ads_in_first_person_only() -> void:
	await _fixture(true, false, false)
	if _pawn.bridge == null:
		_pawn.setup("hastati", 0)
	var game: GameHud = load("res://scenes/ui/hud.tscn").instantiate()
	_tree().root.add_child(game)
	game.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	game.size = Vector2(1512, 648)
	var director := MatchDirector.new()
	game.bind(director, _pawn)
	game.refresh_pawn()
	assert_true(game.crosshair.is_visible_in_tree(), "first person at the hip: shown")
	await _aim_down(true)
	game.refresh_pawn()
	assert_true(_rig.is_first_person() and _pawn.aim_blend == 1.0, "full ADS in first person")
	assert_true(not game.crosshair.is_visible_in_tree(), "full ADS in first person: hidden (the red dot takes over)")
	await _aim_down(false)
	game.refresh_pawn()
	assert_true(game.crosshair.is_visible_in_tree(), "ADS off: shown again")
	var at := _fp("crosshair_hide_aim_blend")
	_pawn.aim_blend = at - 0.01
	game.refresh_pawn()
	assert_true(game.crosshair.is_visible_in_tree(), "aim_blend just under %s: shown" % at)
	_pawn.aim_blend = at
	game.refresh_pawn()
	assert_true(not game.crosshair.is_visible_in_tree(), "aim_blend at %s: hidden" % at)
	# Third person (falling: CameraRig.is_first_person false) with full ADS: exactly as today.
	_pawn.drop_state = Pawn.Drop.FALLING
	_pawn.aim_blend = 1.0
	game.refresh_pawn()
	assert_true(game.crosshair.is_visible_in_tree(), "third person with full ADS: shown as today")
	_pawn.drop_state = Pawn.Drop.NONE
	game.refresh_pawn()
	assert_true(not game.crosshair.is_visible_in_tree(), "back in first person with full ADS: hidden")
	# The blade: ADS still zooms (the game aims with any weapon) but keeps the crosshair and the hip pose.
	assert_true(_pawn.loadout.swap() and _pawn.loadout.get_active().def.is_melee(), "the blade is out")
	await _aim_down(true)
	game.refresh_pawn()
	assert_true(game.crosshair.is_visible_in_tree(), "blade with full ADS: shown as today")
	assert_eq(_rig.get_view_model().get_ads_weight(), 0.0, "blade: no ADS pose, the hip pose stays")
	assert_true(_rig.get_view_model().get_red_dot() == null, "blade: no red dot")
	game.free()
	director.free()
	# No rig (HUD tests bind pawns without one): ADS never hides the crosshair.
	var lone := Pawn.new()
	lone.setup("hastati", 0)
	var game2: GameHud = load("res://scenes/ui/hud.tscn").instantiate()
	_tree().root.add_child(game2)
	var director2 := MatchDirector.new()
	game2.bind(director2, lone)
	lone.aiming = true
	lone.aim_blend = 1.0
	game2.refresh_pawn()
	assert_true(game2.crosshair.is_visible_in_tree(), "no rig with full ADS: shown as today")
	game2.free()
	lone.free()
	director2.free()
	await _cleanup()


## Fix 12 in the ADS pose: at aim blends 0..1 and at every fov_table row, every view-model vertex of both guns stays
## inside max_reach_m (under the capsule radius) and beyond the near plane, and no triangle crosses the near plane
## inside the view (no visible near-plane cut).
func test_ads_pose_stays_inside_the_capsule_and_past_the_near_plane() -> void:
	var reach := _vm_f("max_reach_m")
	var fov_mult := float(_aim_cfg()["aim_fov_mult"])
	for class_id in ["hastati", "sagittarii"]:
		await _fixture(true, false, false)
		if class_id != "hastati":
			_pawn.setup(class_id, 0)
		await _frames(3)
		var capsule := (_pawn.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
		var cam := _rig.get_camera()
		var vm := _rig.get_view_model()
		var id := vm.get_shown_weapon_id()
		assert_true(vm.get_red_dot() != null, "%s: a gun with a red dot" % id)
		for blend: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
			for sz in ADS_SIZES:
				var aspect := float(sz.x) / sz.y
				_rig.base_fov = CameraRig.fov_for_aspect(_cam_cfg(), aspect)
				_rig.set_aim_blend(blend, fov_mult)
				await _tree().physics_frame
				var m := _measure_view_model(cam, vm, aspect)
				var tag := "%s blend %.2f fov %.1f" % [id, blend, cam.fov]
				print("FP ADS REACH %s reach_m=%.4f nearest_m=%.4f nearest_depth_in_view_m=%.4f near_cuts=%d (limit %.2f, capsule %.2f, near %.3f)" % [
						tag, m["far"], m["nearest"], m["min_depth"], m["cuts"], reach, capsule.radius, cam.near])
				assert_true(m["far"] < reach and reach < capsule.radius, "%s: reach %.4f < %.2f < capsule %.2f" % [tag, m["far"], reach, capsule.radius])
				assert_true(m["nearest"] > cam.near, "%s: nearest vertex %.4f beyond the near plane" % [tag, m["nearest"]])
				assert_eq(m["cuts"], 0, "%s: no triangle cut by the near plane inside the view" % tag)
		await _cleanup()


## Reach, nearest vertex, nearest in-view depth and near-plane cuts of the shown view model in camera space.
func _measure_view_model(cam: Camera3D, vm: ViewModel, aspect: float) -> Dictionary:
	var to_cam := cam.global_transform.affine_inverse()
	var near := cam.near
	var tan_h := tan(deg_to_rad(cam.fov) * 0.5)
	var tan_w := tan_h * aspect
	var out := {"far": 0.0, "nearest": INF, "min_depth": INF, "cuts": 0}
	for mi in vm.mesh_instances():
		if mi == vm.tracer or mi == vm.flash or not mi.is_visible_in_tree():
			continue
		var xf := to_cam * mi.global_transform
		var faces := mi.mesh.get_faces()
		for t in range(0, faces.size(), 3):
			var tri: Array[Vector3] = [xf * faces[t], xf * faces[t + 1], xf * faces[t + 2]]
			for v in tri:
				out["far"] = maxf(out["far"], v.length())
				out["nearest"] = minf(out["nearest"], v.length())
				var d := -v.z
				if d > 0.0 and absf(v.x) <= d * tan_w and absf(v.y) <= d * tan_h:
					out["min_depth"] = minf(out["min_depth"], d)
					if d < near:
						out["cuts"] += 1
			if _crosses_near_rect(tri, near, near * tan_w, near * tan_h):
				out["cuts"] += 1
	return out


## True iff the triangle (camera space) crosses the plane at depth `near` inside the near rectangle.
static func _crosses_near_rect(tri: Array[Vector3], near: float, half_w: float, half_h: float) -> bool:
	var pts: Array[Vector2] = []
	for i in 3:
		var a := tri[i]
		var b := tri[(i + 1) % 3]
		var da := -a.z - near
		var db := -b.z - near
		if (da < 0.0) != (db < 0.0):
			var q := a.lerp(b, da / (da - db))
			pts.append(Vector2(q.x, q.y))
	if pts.size() < 2:
		return false
	# Liang-Barsky: does the segment pts[0]..pts[1] meet the rectangle [-half_w, half_w] x [-half_h, half_h]?
	var d := pts[1] - pts[0]
	var p := [-d.x, d.x, -d.y, d.y]
	var q := [pts[0].x + half_w, half_w - pts[0].x, pts[0].y + half_h, half_h - pts[0].y]
	var t0 := 0.0
	var t1 := 1.0
	for i in 4:
		if absf(p[i]) < 1e-12:
			if q[i] < 0.0:
				return false
		else:
			var r: float = q[i] / p[i]
			if p[i] < 0.0:
				t0 = maxf(t0, r)
			else:
				t1 = minf(t1, r)
			if t0 > t1:
				return false
	return true


# --- stage 4: the local body render layer and the Shoulder hide ---------------------------------------------------

const _ButtonRig := preload("res://tests/button_rig.gd")


func _body_layer() -> int:
	return int(_fp("body_layer"))


func _body_bit() -> int:
	return 1 << (_body_layer() - 1)


## Every node that must sit on the body layer for a local pawn (Body, HeadMesh, every SoldierModel VisualInstance3D,
## the ShotFx tracer and flash). The ShotFx weapon box is layers 0 (SoldierModel.add_rifle) and stays 0.
func _body_nodes(pawn: Pawn) -> Array:
	var out: Array = [pawn.get_node("Body"), pawn.get_node("Head/HeadMesh"), pawn.shot_fx.tracer, pawn.shot_fx.flash]
	for n in pawn.get_node("SoldierModel").find_children("*", "VisualInstance3D", true, false):
		out.append(n)
	return out


func _on_default_layer(nodes: Array) -> bool:
	for n in nodes:
		if ((n as VisualInstance3D).layers & 1) == 0 or ((n as VisualInstance3D).layers & _body_bit()) != 0:
			return false
	return true


func _on_body_layer(nodes: Array) -> bool:
	for n in nodes:
		if not LocalBodyLayer.is_on_layer(n, _body_layer()):
			return false
	return true


func _cam_draws_body() -> bool:
	return (_rig.get_camera().cull_mask & _body_bit()) != 0


## Spec item 3, fixes 3, 10: the local pawn's body is on the body layer; the rig camera leaves it out in first person
## and draws it in third person (downed, falling, a real cover entry incl. ENTERING), switching on the same physics
## frame as the view model; back in first person it is left out again. Collision layers are untouched.
func test_local_body_on_the_layer_and_the_camera_mask_follows_the_mode() -> void:
	var layer := _body_layer()
	assert_true(layer >= 1 and layer <= 20, "camera.json first_person.body_layer is a render layer (%d)" % layer)
	var fresh: Pawn = _PawnScene.instantiate()  # collision reference: a pawn nobody touched
	await _fixture(true, false, false)
	var nodes := _body_nodes(_pawn)
	assert_true(nodes.size() > 4, "SoldierModel has meshes (%d nodes)" % nodes.size())
	assert_true(_on_body_layer(nodes), "local pawn: Body, HeadMesh, SoldierModel meshes, ShotFx tracer and flash on layer %d only" % layer)
	assert_eq(_pawn.shot_fx.weapon_mesh.layers, 0, "the ShotFx weapon box stays layers 0 (drawn by no camera, as today)")
	for n in [_pawn.shot_fx.impact, _pawn.shot_fx.sparks, _pawn.shot_fx.dust]:
		assert_eq((n as VisualInstance3D).layers, 1, "%s stays on the default layer (the hit is seen in first person)" % n.name)
	for vi in _rig.get_view_model().find_children("*", "VisualInstance3D", true, false):
		assert_true(((vi as VisualInstance3D).layers & _body_bit()) == 0, "the view model is not on the body layer (%s)" % vi.name)
	assert_true(_rig.is_body_hidden() and not _cam_draws_body(), "first person: the rig camera leaves layer %d out" % layer)
	assert_true((_rig.get_camera().cull_mask & 1) != 0, "first person: the default layer is still drawn")
	assert_eq(_pawn.collision_layer, fresh.collision_layer, "pawn collision layer unchanged")
	assert_eq(_pawn.collision_mask, fresh.collision_mask, "pawn collision mask unchanged")
	assert_eq((_pawn.get_node("Head") as Area3D).collision_layer, (fresh.get_node("Head") as Area3D).collision_layer, "head hitbox layer unchanged")
	fresh.free()
	var settle := _vm_frames(_fp("blend_s"))
	for mode in ["downed", "falling"]:
		if mode == "downed":
			_pawn.life = Pawn.Life.DOWNED
		else:
			_pawn.drop_state = Pawn.Drop.FALLING
		await _frames(settle)
		assert_true(_cam_draws_body(), "%s (third person): the rig camera draws the body" % mode)
		_pawn.life = Pawn.Life.ALIVE
		_pawn.drop_state = Pawn.Drop.NONE
		await _frames(settle)
		assert_true(not _cam_draws_body(), "%s over (first person): left out again" % mode)
	await _cleanup()
	# A real cover entry and exit: on every frame the camera draws the body exactly while the view model is hidden.
	await _fixture()
	var vm := _rig.get_view_model()
	var mismatches := 0
	var drawn_entering := false
	var swap_weight := -1.0
	for i in 150:
		await _tick(Vector2(0, -1) if _pawn.cover.state == CoverController.State.FREE else Vector2.ZERO)
		if _cam_draws_body() == vm.visible:
			mismatches += 1
		# M2 C1b stage 1: ENTERING is capped at cover.json input_lock_max_s (0.15 s), shorter than the 0.35 s blend, so
		# the body now appears during the entry blend just after ENTERING settles; the check is "during the blend".
		if _pawn.cover.state != CoverController.State.FREE and _rig.get_first_person_weight() > 0.0 and _cam_draws_body():
			drawn_entering = true
		if swap_weight < 0.0 and _cam_draws_body():
			swap_weight = _rig.get_first_person_weight()
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0:
			break
	assert_true(_cam_draws_body(), "in cover: the rig camera draws the soldier")
	assert_true(drawn_entering, "entry blend (third person): drawn before the blend completes")
	assert_true(swap_weight >= 0.0 and swap_weight < _vm_f("show_weight"), "the body appears below show_weight (at %s)" % swap_weight)
	for i in 30:
		await _tick(Vector2.ZERO)
	_pawn.handle_action_press("cover")  # M2 C1b stage 2: the Cover button exit (was one frame of back stick)
	for i in 150:
		await _tick(Vector2.ZERO)
		if _cam_draws_body() == vm.visible:
			mismatches += 1
		if _pawn.cover.state == CoverController.State.FREE and _rig.get_first_person_weight() == 1.0:
			break
	assert_eq(mismatches, 0, "body and view model swap on the same physics frame, both ways")
	assert_true(not _cam_draws_body(), "back in first person: left out again")
	print("FP BODY layer=%d swap_weight=%.3f show_weight=%.2f" % [layer, swap_weight, _vm_f("show_weight")])
	await _cleanup()


## Bots (Brain), rig-less pawns keep full soldiers on the default layer; a Brain removed later makes the pawn local
## and its body moves then (test_cover_pawn.gd:133-141 order). A rig without a pawn draws the layer.
func test_body_layer_only_for_the_local_pawn() -> void:
	await _fixture(true, true, false)
	await _frames(3)
	assert_true(_on_default_layer(_body_nodes(_pawn)), "Brain pawn: every body node on the default layer")
	assert_true(_cam_draws_body(), "Brain pawn's rig (third person): draws the layer")
	var brain := _pawn.get_node("Brain")
	_pawn.remove_child(brain)
	brain.free()
	await _frames(2)
	assert_true(_on_body_layer(_body_nodes(_pawn)), "Brain removed later: the body moves to the layer")
	await _frames(_vm_frames(_fp("blend_s")))
	assert_true(not _cam_draws_body(), "and once the blend reaches first person the camera leaves it out")
	await _cleanup()
	await _fixture(false, false, false)
	await _frames(3)
	assert_true(_on_default_layer(_body_nodes(_pawn)), "rig-less pawn: every body node on the default layer")
	await _cleanup()
	var root := Node3D.new()
	_tree().root.add_child(root)
	var rig: CameraRig = _RigScene.instantiate()
	root.add_child(rig)
	await _frames(2)
	assert_true((rig.get_camera().cull_mask & _body_bit()) != 0 and not rig.is_body_hidden(), "rig without a pawn draws the layer")
	root.queue_free()
	await _tree().process_frame


## Meshes SoldierModel (or anyone) adds under the tracked body later carry the layer; a real shot keeps the ShotFx
## tracer and flash node-visible on the layer while the impact is on the default layer; the melee SwingVisual bar goes
## on the layer (the view model plays its own swing); a replaced ShotFx is followed. The SpectatorCamera draws it.
func test_body_layer_follows_new_meshes_shots_and_swings() -> void:
	await _fixture(true, false, false)
	var model := _pawn.get_node("SoldierModel") as SoldierModel
	var late := MeshInstance3D.new()
	late.mesh = BoxMesh.new()
	model.skeleton.add_child(late)
	assert_true(LocalBodyLayer.is_on_layer(late, _body_layer()), "a mesh added under SoldierModel later is on the layer at once")
	var holder := Node3D.new()
	var nested := MeshInstance3D.new()
	nested.mesh = BoxMesh.new()
	holder.add_child(nested)
	model.add_child(holder)
	var deeper := MeshInstance3D.new()
	deeper.mesh = BoxMesh.new()
	nested.add_child(deeper)
	assert_true(LocalBodyLayer.is_on_layer(nested, _body_layer()) and LocalBodyLayer.is_on_layer(deeper, _body_layer()), "nested and deeper meshes follow")
	late.reparent(model.hand_attachment)
	assert_true(LocalBodyLayer.is_on_layer(late, _body_layer()), "a reparented mesh keeps it")
	SoldierSquadColour.apply(model.armor, 2)
	assert_true(LocalBodyLayer.is_on_layer(model.armor, _body_layer()), "squad colour keeps the armor on the layer")
	await _frames(2)
	var res := _pawn.fire_shot()
	assert_true(res.has("position"), "the shot hit the wall ahead")
	assert_true(_pawn.shot_fx.is_tracer_visible() and _pawn.shot_fx.is_flash_visible(), "ShotFx tracer and flash still node-visible")
	assert_true(LocalBodyLayer.is_on_layer(_pawn.shot_fx.tracer, _body_layer()) and LocalBodyLayer.is_on_layer(_pawn.shot_fx.flash, _body_layer()), "on the body layer after the shot")
	assert_true(_pawn.shot_fx.is_impact_visible() and _pawn.shot_fx.impact.layers == 1, "impact visible on the default layer")
	assert_true(_pawn.loadout.swap() and _pawn.loadout.get_active().def.is_melee(), "the blade is out")
	_pawn.fire_shot()
	var swings := _pawn.get_children().filter(func(n: Node) -> bool: return n is SwingVisual)
	assert_eq(swings.size(), 1, "the swing visual is under the pawn")
	var bars: Array = swings[0].find_children("*", "VisualInstance3D", true, false) if swings.size() == 1 else []
	assert_true(not bars.is_empty() and _on_body_layer(bars), "the SwingVisual bar is on the body layer")
	# A replaced ShotFx (made after the rig) is followed on the next physics frame.
	var fx := ShotFx.new()
	fx.name = "ShotFx2"
	_pawn.add_child(fx)
	_pawn.shot_fx = fx
	await _frames(2)
	assert_true(LocalBodyLayer.is_on_layer(fx.tracer, _body_layer()) and LocalBodyLayer.is_on_layer(fx.flash, _body_layer()), "a later ShotFx's tracer and flash follow")
	assert_eq(fx.impact.layers, 1, "its impact stays on the default layer")
	var spectator := SpectatorCamera.new()
	assert_true((spectator.cull_mask & _body_bit()) != 0, "SpectatorCamera's cull mask includes the body layer")
	spectator.free()
	await _cleanup()


## Spec item 5, fix 2, in the real match HUD (tests/button_rig.gd): in first person the Shoulder button is hidden and
## a tap at its slot centre does nothing (no swap, no shot, no ammo spent, no look turn, no look touch); in third person
## (DOWNED) it is back and presses swap_shoulder as today; back in first person it hides again.
## M2 C1b stage 1 (fixes 8, 20, 30): C1a hid the Shoulder button in first person and its slot swallowed taps; on the
## ground the slot is now the visible Cover button (it presses "cover", never a look, a shot or a swap).
func test_shoulder_slot_is_the_cover_button_in_first_person() -> void:
	for sz in _ButtonRig.SIZES:
		var ctx: Dictionary = await _ButtonRig.setup(sz, "virtual")
		var tag: String = ctx["tag"]
		var pawn: Pawn = ctx["pawn"]
		var touch: Control = ctx["touch"]
		var rig := pawn.get_node("CameraRig") as CameraRig
		var b: Button = touch._buttons["swap_shoulder"]
		assert_true(rig.is_first_person(), "%s: the match pawn walks in first person" % tag)
		assert_true((rig.get_camera().cull_mask & _body_bit()) == 0, "%s: the match camera leaves the body layer out" % tag)
		assert_true(b.visible and not touch.is_first_person_slot_hidden("swap_shoulder") and touch._action_of("swap_shoulder") == "cover", "%s: first person on the ground: the slot is the visible Cover button" % tag)
		var c: Vector2 = touch.get_button_rect("swap_shoulder").get_center()
		assert_true(touch.get_button_rect("swap_shoulder").size.x > 0.0, "%s: its slot rect stays reserved" % tag)
		var w := pawn.loadout.get_active()
		var ammo := w.ammo_in_mag
		var shots := [0]
		var count := func(_o: Vector3, _d: Vector3, _id: String) -> void: shots[0] += 1
		pawn.shot.connect(count)
		var yaw := pawn.rotation.y
		var pitch := pawn.pitch
		var side := rig.shoulder_side
		print("FP SHOULDER %s slot=%s in_look_zone=%s" % [tag, c, touch._zone_hit_rect("look_zone").has_point(c)])
		_ButtonRig.touch(_ButtonRig.BUTTON_TOUCH, c, true)
		await _ButtonRig.frames(2)
		# The slot hit-tests as its element key and presses "cover" (tests/test_fold_window_coords.gd needs a pressed
		# action); it is not a look touch.
		assert_eq(touch._button_at(c), "swap_shoulder", "%s: the slot takes the tap" % tag)
		assert_true(Input.is_action_pressed("cover") and not Input.is_action_pressed("swap_shoulder"), "%s: the slot presses cover, not swap_shoulder" % tag)
		assert_eq(touch._look_touch, -1, "%s: the tap does not reach the look area" % tag)
		_ButtonRig.touch(_ButtonRig.BUTTON_TOUCH, c, false)
		await _ButtonRig.frames(12)
		assert_eq(shots[0], 0, "%s: the tap does not fire" % tag)
		assert_eq(w.ammo_in_mag, ammo, "%s: ammo unchanged" % tag)
		assert_true(absf(pawn.rotation.y - yaw) < 1e-6 and absf(pawn.pitch - pitch) < 1e-6, "%s: the look did not turn" % tag)
		assert_eq(rig.shoulder_side, side, "%s: no swap" % tag)
		assert_true(is_equal_approx(b.scale.x, 1.0), "%s: no Shoulder press pulse on the Cover button" % tag)
		# Third person (DOWNED): the button is back and presses as today.
		pawn.life = Pawn.Life.DOWNED
		await _ButtonRig.frames(3)
		assert_true(not rig.is_first_person() and b.visible, "%s: third person (downed): Shoulder shown" % tag)
		_ButtonRig.touch(_ButtonRig.BUTTON_TOUCH, c, true)
		assert_true(Input.is_action_pressed("swap_shoulder"), "%s: third person: the tap presses swap_shoulder" % tag)
		assert_true(b.scale.x < 1.0, "%s: third person: the press pulse runs" % tag)
		_ButtonRig.touch(_ButtonRig.BUTTON_TOUCH, c, false)
		await _ButtonRig.frames(2)
		assert_true(not Input.is_action_pressed("swap_shoulder"), "%s: released" % tag)
		pawn.life = Pawn.Life.ALIVE
		await _ButtonRig.frames(3)
		assert_true(rig.is_first_person() and b.visible and touch._action_of("swap_shoulder") == "cover", "%s: back in first person: the Cover button again" % tag)
		pawn.shot.disconnect(count)
		await _ButtonRig.teardown(ctx)
