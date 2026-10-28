extends "res://tests/test_case.gd"
## Path A phase 2, Goal A: Kenney Starter-Kit-FPS camera knockback on fire, made to recover and driven by
## data/camera.json camera_knockback_* (Shibi-approved industry defaults, OQ-CAM-KNOCKBACK). CameraKnockback is the
## pure kick/recover math; CameraRig adds it to its rotation and keeps the aim point on the un-kicked camera (view
## only); Pawn.fire_shot kicks the local rig for ranged shots only.

const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _Rig := preload("res://tests/button_rig.gd")
const EPS := 1e-5


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _knock(pitch_deg: float, yaw_deg: float, recover_s: float) -> CameraKnockback:
	var k := CameraKnockback.new()
	k.configure({"camera_knockback_pitch_deg": {"value": pitch_deg}, "camera_knockback_yaw_deg": {"value": yaw_deg},
			"camera_knockback_recover_s": {"value": recover_s}})
	k.rng.seed = 12345
	return k


func _add_rig(parent: Node) -> CameraRig:
	var rig: CameraRig = _RigScene.instantiate()
	rig.name = "CameraRig"
	parent.add_child(rig)
	return rig


func _cfg_value(key: String) -> float:
	return float(DataRegistry.new().get_camera_cfg()[key]["value"])


func test_kick_adds_the_data_pitch_and_a_random_sign_yaw() -> void:
	var k := _knock(2.0, 1.0, 0.2)
	var signs := {}
	for i in 40:
		k.reset()
		var add := k.kick()
		assert_true(absf(add.x - deg_to_rad(2.0)) < EPS, "pitch kick is camera_knockback_pitch_deg (got %s)" % add.x)
		assert_true(absf(absf(add.y) - deg_to_rad(1.0)) < EPS, "yaw kick size is camera_knockback_yaw_deg (got %s)" % add.y)
		assert_true(k.offset.is_equal_approx(add), "offset right after a kick is the kick")
		signs[signf(add.y)] = true
	assert_true(signs.has(1.0) and signs.has(-1.0), "yaw sign varies between kicks (Kenney random_vec2): %s" % [signs.keys()])


func test_offset_recovers_linearly_to_zero_over_recover_s() -> void:
	var k := _knock(2.0, 1.0, 0.2)
	var add := k.kick()
	k.tick(0.05)
	assert_true(k.offset.is_equal_approx(add * 0.75), "a quarter of recover_s in, 75%% is left (got %s)" % k.offset)
	k.tick(0.1)
	assert_true(k.offset.is_equal_approx(add * 0.25), "three quarters in, 25%% is left (got %s)" % k.offset)
	k.tick(0.05)
	assert_eq(k.offset, Vector2.ZERO, "at rest once recover_s has passed")
	k.tick(1.0)
	assert_eq(k.offset, Vector2.ZERO, "stays at rest")


func test_kicks_stack_but_stay_bounded_under_sustained_fire() -> void:
	var k := _knock(1.0, 0.0, 0.2)
	var interval := 0.05
	var kick := deg_to_rad(1.0)
	var top := 0.0
	for i in 200:
		k.kick()
		top = maxf(top, k.offset.x)
		k.tick(interval)
	assert_true(top > kick * 1.5, "kicks inside recover_s stack (peak %s rad)" % top)
	# Each kick restarts a linear recovery from the current peak, so the peak converges to kick * recover_s / interval.
	assert_true(top <= kick * 0.2 / interval + 1e-4, "peak %s rad stays under kick * recover_s / interval" % top)
	k.tick(0.2)
	assert_eq(k.offset, Vector2.ZERO, "at rest recover_s after the last kick")


func test_missing_keys_or_zero_recover_turn_knockback_off() -> void:
	var none := CameraKnockback.new()
	none.configure({})
	assert_eq(none.kick(), Vector2.ZERO, "no keys: no kick")
	assert_eq(none.offset, Vector2.ZERO, "no keys: no offset")
	var zero := _knock(2.0, 1.0, 0.0)
	assert_eq(zero.kick(), Vector2.ZERO, "recover_s 0: knockback off")
	assert_eq(zero.offset, Vector2.ZERO, "recover_s 0: no offset")


func test_camera_json_knockback_keys_are_locked_industry_defaults() -> void:
	# Shibi-approved industry defaults 2026-10-28 (OQ-CAM-KNOCKBACK), not DESIGN.md values.
	var cfg := DataRegistry.new().get_camera_cfg()
	var keys: Array[String] = ["camera_knockback_pitch_deg", "camera_knockback_yaw_deg", "camera_knockback_recover_s"]
	var shipped: Array[float] = [2.0, 1.2, 0.22]
	for i in keys.size():
		var key := keys[i]
		assert_true(cfg.has(key), "camera.json has %s" % key)
		if cfg.has(key):
			var e: Dictionary = cfg[key]
			assert_true(not e.has("_placeholder"), "%s is no longer marked _placeholder" % key)
			var value := float(e.get("value", -1.0))
			assert_true(is_equal_approx(value, shipped[i]), "%s ships %s (got %s)" % [key, shipped[i], value])
	assert_true(_cfg_value("camera_knockback_recover_s") > 0.0, "the shipped knockback recovers (recover_s > 0)")
	assert_true(_cfg_value("camera_knockback_pitch_deg") > 0.0, "the shipped knockback kicks the view up")
	assert_true(_cfg_value("camera_knockback_pitch_deg") < 5.0, "the kick is small (under 5 deg)")


func test_rig_kick_tilts_the_view_and_recovers_within_recover_s() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var rig := _add_rig(root)
	await _tree().physics_frame
	rig.set_pitch(0.1)
	rig.knockback.rng.seed = 7
	var add := rig.apply_knockback()
	assert_true(absf(add.x - deg_to_rad(_cfg_value("camera_knockback_pitch_deg"))) < EPS, "kick pitch from camera.json")
	assert_true(absf(absf(add.y) - deg_to_rad(_cfg_value("camera_knockback_yaw_deg"))) < EPS, "kick yaw from camera.json")
	assert_true(absf(rig.rotation.x - (0.1 + add.x)) < EPS, "rig pitch = look pitch + kick (%s)" % rig.rotation.x)
	assert_true(absf(rig.rotation.y - add.y) < EPS, "rig yaw = yaw kick (%s)" % rig.rotation.y)
	rig.set_pitch(0.1)  # the pawn re-sends its pitch every tick; the kick stays on top
	assert_true(absf(rig.rotation.x - (0.1 + add.x)) < EPS, "set_pitch keeps the kick on top")
	await _tree().physics_frame
	assert_true(rig.get_knockback().is_equal_approx(add), "the kick's own physics frame shows it whole")
	var ticks := int(ceil(_cfg_value("camera_knockback_recover_s") * Engine.physics_ticks_per_second)) + 2
	for i in ticks:
		await _tree().physics_frame
	assert_eq(rig.get_knockback(), Vector2.ZERO, "at rest after recover_s")
	assert_true(absf(rig.rotation.x - 0.1) < EPS and absf(rig.rotation.y) < EPS, "rig back at the look pitch, no yaw (%s)" % rig.rotation)
	root.queue_free()


func test_kick_keeps_the_pitch_inside_the_data_limits() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	var rig := _add_rig(root)
	await _tree().physics_frame
	var hi := deg_to_rad(float(DataRegistry.new().get_camera_cfg()["pitch_max_deg"]))
	rig.set_pitch(hi)
	rig.apply_knockback()
	assert_true(rig.rotation.x <= hi + EPS, "kicked pitch %s stays under pitch_max_deg %s" % [rig.rotation.x, hi])
	root.queue_free()


## A wall facing the rig camera `dist_m` ahead of it, perpendicular to the view.
func _wall_ahead(root: Node, cam: Camera3D, dist_m: float) -> void:
	var wall := StaticBody3D.new()
	wall.collision_layer = Hitscan.MASK_WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 40.0, 0.5)
	shape.shape = box
	wall.add_child(shape)
	root.add_child(wall)
	var xf := cam.global_transform
	wall.global_transform = Transform3D(xf.basis, xf.origin - xf.basis.z * dist_m)


## View only: while the camera is kicked, get_aim_point (the InputFrame aim point the host validates) stays the point
## the un-kicked camera aims at, on a wall and at the far point, under a turned and moved parent (the pawn's yaw).
func test_kick_never_moves_the_aim_point() -> void:
	for with_wall in [true, false]:
		var root := Node3D.new()
		_tree().root.add_child(root)
		root.position = Vector3(2.0, 0.0, -1.0)
		root.rotation.y = 0.7
		var rig := _add_rig(root)
		await _tree().physics_frame
		await _tree().physics_frame
		rig.set_pitch(0.05)
		var cam := rig.get_camera()
		if with_wall:
			_wall_ahead(root, cam, 10.0)
			await _tree().physics_frame
		var tag := "wall" if with_wall else "far point"
		var fwd_before := -cam.global_transform.basis.z
		var aim_before := rig.get_aim_point([])
		rig.knockback.pitch_rad = deg_to_rad(4.0)
		rig.knockback.yaw_rad = deg_to_rad(3.0)
		rig.apply_knockback()
		var fwd_after := -cam.global_transform.basis.z
		assert_true(fwd_before.angle_to(fwd_after) > deg_to_rad(3.0), "%s: the camera view turned (%s rad)" % [tag, fwd_before.angle_to(fwd_after)])
		var aim_after := rig.get_aim_point([])
		var tol := 1e-3 if with_wall else 1e-2
		assert_true(aim_after.distance_to(aim_before) < tol, "%s: aim point unchanged by the kick (%s vs %s)" % [tag, aim_after, aim_before])
		if with_wall:
			assert_true(aim_before.distance_to(cam.global_position) < 12.0, "wall case: the aim ray hit the wall (%s)" % aim_before)
		rig.knockback.reset()
		rig.set_pitch(0.05)
		assert_true(rig.get_aim_point([]).distance_to(aim_before) < tol, "%s: same point again at rest" % tag)
		root.queue_free()
		await _tree().process_frame


func test_ranged_shot_kicks_the_local_rig_melee_and_rigless_pawns_do_not() -> void:
	var pawn: Pawn = _PawnScene.instantiate()
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	var rig := _add_rig(pawn)
	var bot: Pawn = _PawnScene.instantiate()
	_tree().root.add_child(bot)
	bot.set_physics_process(false)
	bot.global_position = Vector3(5.0, 0.0, 0.0)
	await _tree().physics_frame
	assert_true(not pawn.loadout.get_active().def.is_melee(), "start weapon is ranged")
	pawn.fire_shot()
	assert_true(rig.get_knockback().x > 0.0, "a ranged shot kicks the camera up (%s)" % rig.get_knockback())
	rig.knockback.reset()
	rig.set_pitch(0.0)
	pawn.loadout.swap()
	assert_true(pawn.loadout.get_active().def.is_melee(), "secondary is the melee blade")
	pawn.fire_shot()
	assert_eq(rig.get_knockback(), Vector2.ZERO, "a melee swing does not kick")
	bot.fire_shot()  # no CameraRig child (bots, host-side remote pawns, replicas): fires, nothing to kick
	assert_true(bot.shot_fx.is_tracer_visible(), "a rig-less pawn still shoots and draws its tracer")
	pawn.queue_free()
	bot.queue_free()


## Through the match: tapping Fire (touch HUD -> InputMap -> InputFrame -> Pawn) kicks the local CameraRig, and the
## kick is gone once the shots stop.
func test_fire_button_kicks_the_match_camera_and_it_recovers() -> void:
	var ctx: Dictionary = await _Rig.setup(_Rig.SIZES[0], "virtual")
	var tag: String = ctx["tag"]
	var rig := (ctx["pawn"] as Pawn).get_node("CameraRig") as CameraRig
	assert_eq(rig.get_knockback(), Vector2.ZERO, "%s: at rest before firing" % tag)
	_Rig.press(ctx, "fire", true)
	await _Rig.frames(2)
	assert_true(rig.get_knockback().x > 0.0, "%s: firing kicked the camera up (%s)" % [tag, rig.get_knockback()])
	_Rig.press(ctx, "fire", false)
	await _Rig.frames(40)
	assert_eq(rig.get_knockback(), Vector2.ZERO, "%s: at rest after the shots stop" % tag)
	assert_true(rig.ensure_current(), "%s: the rig camera stays current" % tag)
	await _Rig.teardown(ctx)
