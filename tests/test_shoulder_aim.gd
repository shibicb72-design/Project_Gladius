extends "res://tests/test_case.gd"
## GBTN4: right-shoulder camera and host-validated aim point.
## - the shoulder offset really lands on the camera (SpringArm3D rewrites a child camera's position),
## - the host rejects an aim point whose muzzle ray is blocked by world geometry (no shot, nothing announced),
## - at the Fold sizes the tracer's far end is outside the shooter pawn's screen rect.

const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _Rig := preload("res://tests/button_rig.gd")
const _RigScene := preload("res://scenes/player/camera_rig.tscn")
const PEER := 77
const PID := 5


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _host_rig() -> Dictionary:
	var root := Node.new()
	_tree().root.add_child(root)
	var director := MatchDirector.new()
	root.add_child(director)
	var bridge := NetMatchBridge.new()
	bridge.name = "Bridge"
	root.add_child(bridge)
	bridge.set_physics_process(false)
	bridge.setup(director)
	var pawn: Pawn = _PawnScene.instantiate()
	root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = Vector3(0, 0.1, 0)
	director.add_player(PID, pawn)
	bridge.register_peer(PEER, PID)
	return {"root": root, "bridge": bridge, "pawn": pawn}


func _wall(root: Node, z: float) -> void:
	var wall := StaticBody3D.new()
	wall.collision_layer = Hitscan.MASK_WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 6.0, 0.5)
	shape.shape = box
	wall.add_child(shape)
	root.add_child(wall)
	wall.global_position = Vector3(0, 3.0, z)


func _frame_with_point(p: Vector3) -> Array:
	var f := InputFrame.new()
	f.has_aim_point = true
	f.aim_point = p
	return f.to_array()


func _fire(bridge: NetMatchBridge, pawn: Pawn) -> Dictionary:
	return bridge.host_handle_fire(PEER, pawn.get_muzzle_position(), Vector3(0, 0, -1),
			pawn.loadout.get_active().def.id)


func test_shoulder_offset_is_on_the_arm_and_survives_physics_frames() -> void:
	var rig: Node3D = _RigScene.instantiate()
	_tree().root.add_child(rig)
	for i in 5:
		await _tree().physics_frame
	var cam: Camera3D = rig.get_node("SpringArm3D/Camera3D")
	var want := float(DataRegistry.new().get_camera_cfg()["shoulder_offset_m"]["value"])
	var in_rig := rig.global_transform.affine_inverse() * cam.global_position
	assert_true(absf(in_rig.x - want) < 0.001, "camera x in the rig is the shoulder offset (%s vs %s)" % [in_rig.x, want])
	assert_true(want > 0.0, "right shoulder: positive x")
	rig.queue_free()


func test_host_rejects_aim_point_behind_a_wall_and_spawns_no_shot() -> void:
	var r := _host_rig()
	var bridge: NetMatchBridge = r["bridge"]
	var pawn: Pawn = r["pawn"]
	_wall(r["root"], -5.0)
	await _tree().physics_frame
	await _tree().physics_frame
	var announced: Array = []
	bridge.shot_announced.connect(func(_id: int, o: Vector3, e: Vector3) -> void: announced.append([o, e]))
	var ammo := pawn.loadout.get_active().ammo_in_mag
	bridge.host_note_input(PEER, _frame_with_point(Vector3(0.0, 1.3, -12.0)))
	var res := _fire(bridge, pawn)
	assert_true(not res["ok"], "aim point behind the wall is rejected")
	assert_eq(res["reason"], "aim_blocked", "reason names the blocked muzzle ray")
	assert_eq(announced.size(), 0, "no shot spawned or announced")
	assert_eq(pawn.loadout.get_active().ammo_in_mag, ammo, "no ammo spent")
	r["root"].queue_free()


func test_host_accepts_clear_aim_point_and_fires_from_the_muzzle_toward_it() -> void:
	var r := _host_rig()
	var bridge: NetMatchBridge = r["bridge"]
	var pawn: Pawn = r["pawn"]
	_wall(r["root"], -5.0)
	await _tree().physics_frame
	await _tree().physics_frame
	var announced: Array = []
	bridge.shot_announced.connect(func(_id: int, o: Vector3, e: Vector3) -> void: announced.append([o, e]))
	var point := Vector3(1.5, 1.3, -3.0)
	bridge.host_note_input(PEER, _frame_with_point(point))
	var res := _fire(bridge, pawn)
	assert_true(res["ok"], "clear aim point accepted")
	assert_eq(announced.size(), 1, "one shot announced")
	if announced.size() == 1:
		assert_true((announced[0][0] as Vector3).is_equal_approx(pawn.get_muzzle_position()), "shot starts at the muzzle")
		var dir: Vector3 = ((announced[0][1] as Vector3) - (announced[0][0] as Vector3)).normalized()
		var want := (point - pawn.get_muzzle_position()).normalized()
		assert_true(dir.dot(want) > 0.999, "shot heads for the validated point")
	r["root"].queue_free()


func _screen_rect(cam: Camera3D, pawn: Pawn) -> Rect2:
	var aabb := (pawn.get_node("Body") as MeshInstance3D).get_aabb()
	var xf := (pawn.get_node("Body") as MeshInstance3D).global_transform
	var rect := Rect2()
	for i in 8:
		var p := cam.unproject_position(xf * aabb.get_endpoint(i))
		rect = Rect2(p, Vector2.ZERO) if i == 0 else rect.expand(p)
	return rect


func test_far_tracer_ends_outside_the_shooter_screen_rect_at_fold_sizes() -> void:
	var dist := float(DataRegistry.new().load_file("res://data/ui.json")["capture"]["far_target_distance_m"])
	for size in _Rig.SIZES:
		var ctx: Dictionary = await _Rig.setup(size, "custom")
		var pawn: Pawn = ctx["pawn"]
		var lane := SpawnLane.neighbour_lane(pawn, dist)
		assert_true(lane["ok"], "%s: usable lane to a neighbouring spawn spot (%s)" % [size, lane["reason"]])
		if lane["ok"]:
			var dir: Vector3 = lane["dir"]
			pawn.rotation.y = atan2(-dir.x, -dir.z)
			pawn.pitch = 0.0
			await _Rig.frames(3)
			pawn.fire_shot()
			var cam := pawn.get_viewport().get_camera_3d()
			var ep: PackedVector3Array = pawn.shot_fx.get_tracer_endpoints()
			assert_true(pawn.shot_fx.is_tracer_visible(), "%s: tracer drawn" % size)
			assert_true(not cam.is_position_behind(ep[1]), "%s: far end is in front of the camera" % size)
			var far_px := cam.unproject_position(ep[1])
			var rect := _screen_rect(cam, pawn)
			assert_true(not rect.has_point(far_px), "%s: far end %s outside shooter rect %s" % [size, far_px, rect])
		await _Rig.teardown(ctx)
