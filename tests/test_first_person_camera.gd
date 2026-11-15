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
func _fixture(with_rig: bool = true, with_brain: bool = false, with_cover: bool = true) -> void:
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
	# Into cover: push at the wall until the controller snaps, enters and the blend reaches third person.
	var reached_third := false
	var saw_entering := false
	for i in 150:
		await _tick(Vector2(0, -1))
		meter.sample(cam, _pawn)
		saw_entering = saw_entering or _pawn.cover.state == CoverController.State.ENTERING
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0:
			reached_third = true
			break
	assert_true(saw_entering and reached_third, "real cover entry reached third person (state %s, weight %s)" % [_pawn.cover.state, _rig.get_first_person_weight()])
	assert_true(not _rig.is_first_person(), "in cover: third person wanted")
	assert_true(absf(_rig.get_spring_length() - hip) < EPS, "in cover: spring back at the cover value %s (got %s)" % [hip, _rig.get_spring_length()])
	var enter := [meter.max_m, meter.max_deg, meter.max_pawn_m, meter.max_still_m]
	# Settle the cover follow, then leave: one frame of back input starts EXITING, then no input.
	for i in 30:
		await _tick(Vector2.ZERO)
		meter.sample(cam, _pawn)
	await _tick(Vector2(0, 1))
	meter.sample(cam, _pawn)
	assert_eq(_pawn.cover.state, CoverController.State.EXITING, "back input starts the real exit")
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
		await _tick(Vector2(0, -1))
		if _pawn.cover.state == CoverController.State.IN_COVER and _rig.get_first_person_weight() == 0.0:
			break
	for i in 30:
		await _tick(Vector2.ZERO)
	var meter := Meter.new()
	meter.sample(cam, _pawn)
	var reached_first := false
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
