extends "res://tests/test_case.gd"
const DT := 1.0 / 60.0

func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/cover.json")

func _probe(at: Vector3 = Vector3(0, 0, 0.45), basis: Basis = Basis.IDENTITY) -> Dictionary:
	return {"hit": true, "wall_key": 1, "normal": Vector3.BACK, "point": Vector3.ZERO, "position": at, "basis": basis, "distance_m": at.z, "left_m": at.x + 2.0, "right_m": 2.0 - at.x, "height_m": 2.2, "slide_speed_mps": 4.1783}

func _enter(c: CoverController) -> void:
	for i in 47:
		c.tick(DT, Vector2(0, -1), false, _probe())
	assert_eq(c.state, CoverController.State.IN_COVER, "fixture enters cover")

func _step(c: CoverController, pos: Vector3, move: Vector2, basis: Basis = Basis.IDENTITY) -> Vector3:
	c.tick(DT, move, false, _probe(pos, basis))
	var wish := basis * Vector3(move.x, 0, move.y) * 4.7
	var velocity := c.movement_velocity(pos, wish, 6.3, DT)
	var next := pos + velocity * DT
	assert_true(velocity.length() <= 6.301, "every phase speed bounded")
	assert_true(NetValidator.new().validate_move(pos, next, DT, 6.3), "existing host movement check")
	return next

func test_snap_timing_breaks_and_data_override() -> void:
	var c := CoverController.new(_cfg())
	for i in 29:
		c.tick(DT, Vector2(0, -1), false, _probe())
	assert_eq(c.state, CoverController.State.FREE, "still free before half second")
	c.tick(DT, Vector2(0, -1), false, _probe())
	assert_eq(c.state, CoverController.State.ENTERING, "snap within one tick")
	for i in 15:
		c.tick(DT, Vector2.ZERO, false, _probe())
	assert_eq(c.state, CoverController.State.IN_COVER, "enter duration")
	c.reset()
	for i in 18:
		c.tick(DT, Vector2(0, -1), false, _probe())
	c.tick(DT, Vector2.ZERO, false, _probe())
	for i in 29:
		c.tick(DT, Vector2(0, -1), false, _probe())
	assert_eq(c.state, CoverController.State.FREE, "release reset hold")
	var cfg := _cfg()
	cfg["snap_hold_s"] = 0.3
	c = CoverController.new(cfg)
	for i in 18:
		c.tick(DT, Vector2(0, -1), false, _probe())
	assert_eq(c.state, CoverController.State.ENTERING, "data controls snap timing")

func test_no_wall_far_wall_angle_height_and_continuity_reject_snap() -> void:
	for key in ["hit", "distance_m", "height_m", "basis", "wall_key"]:
		var c := CoverController.new(_cfg())
		for i in 60:
			var p := _probe()
			match key:
				"hit": p[key] = false
				"distance_m": p[key] = 0.71
				"height_m": p[key] = 0.8
				"basis": p[key] = Basis(Vector3.UP, deg_to_rad(60))
				"wall_key": p[key] = i % 2
			c.tick(DT, Vector2(0, -1), false, p)
		assert_eq(c.state, CoverController.State.FREE, "invalid probe " + key)

func test_lock_slide_edge_and_current_yaw_stick_frame() -> void:
	var c := CoverController.new(_cfg())
	_enter(c)
	var pos := Vector3(0, 0, 0.45)
	for i in 60:
		pos = _step(c, pos, Vector2(0, -1))
	assert_true(absf(pos.z - 0.45) < 0.02, "forward cannot penetrate or leave plane")
	var yaw := Basis(Vector3.UP, deg_to_rad(45))
	for i in 10:
		pos = _step(c, pos, Vector2(1, 0), yaw)
	assert_true(pos.x > 0 and absf(pos.z - 0.45) < 0.02, "current 45 degree yaw projected onto wall")
	# Below peek threshold, sliding stops at the configured margin.
	for i in 120:
		pos = _step(c, pos, Vector2(0.49, 0))
	assert_true(absf(pos.x - (2.0 - float(_cfg()["edge_margin_m"]))) < 0.001, "slide stops at own wall edge")
	assert_eq(c.state, CoverController.State.IN_COVER, "small stick does not peek")
	pos = _step(c, pos, Vector2(0, 1), yaw)
	assert_eq(c.state, CoverController.State.EXITING, "back projection uses current yaw")

func test_both_peeks_hold_and_release_return_to_anchor() -> void:
	for side in [-1, 1]:
		var c := CoverController.new(_cfg())
		_enter(c)
		var pos := Vector3(side * (2.0 - float(_cfg()["edge_margin_m"])), 0, 0.45)
		for i in 120:
			pos = _step(c, pos, Vector2(side * 0.6, 0))
		assert_eq(c.state, CoverController.State.PEEK_LEFT if side < 0 else CoverController.State.PEEK_RIGHT, "sustained sub-exit stick stays peeked")
		assert_true(absf(pos.x - side * (2.0 + float(_cfg()["peek_offset_m"]))) < 0.001, "completed position past edge")
		assert_true(not c.blocks_fire(), "completed peek may fire before CR1 source switch")
		for i in 20:
			pos = _step(c, pos, Vector2.ZERO)
		assert_eq(c.state, CoverController.State.IN_COVER, "release returns")
		assert_true(absf(pos.x - side * (2.0 - float(_cfg()["edge_margin_m"]))) < 0.001, "returns to pre-peek anchor")
		assert_true(c.blocks_fire(), "wall pose blocks fire")

func test_midwall_does_not_peek_and_fire_blocked_during_motion() -> void:
	var c := CoverController.new(_cfg())
	_enter(c)
	c.tick(DT, Vector2(0.6, 0), true, _probe())
	assert_eq(c.state, CoverController.State.IN_COVER, "mid wall must slide first")
	c.tick(DT, Vector2(0.6, 0), true, _probe(Vector3(1.65, 0, 0.45)))
	assert_eq(c.state, CoverController.State.PEEK_RIGHT, "edge initiates peek")
	assert_true(c.blocks_fire(), "no fire during lean movement")

func test_exit_hold_short_hold_back_and_reset_signals() -> void:
	var c := CoverController.new(_cfg())
	var events: Array[String] = []
	c.entered.connect(func(): events.append("entered"))
	c.peeked.connect(func(_side: int): events.append("peeked"))
	c.exited.connect(func(): events.append("exited"))
	_enter(c)
	var pos := Vector3(1.65, 0, 0.45)
	for i in 17:
		pos = _step(c, pos, Vector2(1, 0))
	assert_eq(c.state, CoverController.State.PEEK_RIGHT, "short hold does not exit")
	for i in 3:
		pos = _step(c, pos, Vector2(1, 0))
	assert_eq(c.state, CoverController.State.EXITING, "continued push exits")
	for i in 18:
		pos = _step(c, pos, Vector2(1, 0))
	assert_eq(c.state, CoverController.State.FREE, "exit animation duration then free")
	var before := pos
	pos = _step(c, pos, Vector2(1, 0))
	assert_true(pos.x > before.x, "normal movement continues")
	assert_eq(events, ["entered", "peeked", "exited"], "one signal per transition")
	_enter(c)
	c.tick(DT, Vector2(0, 1), false, _probe())
	assert_eq(c.state, CoverController.State.EXITING, "back exits")
	c.reset()
	assert_eq(c.state_name(), "FREE", "death/disable reset")
	assert_true(not c.blocks_fire(), "free behavior unaffected")

func test_lost_wall_requires_more_than_one_tick() -> void:
	var c := CoverController.new(_cfg())
	_enter(c)
	var p := _probe()
	p["hit"] = false
	c.tick(DT, Vector2.ZERO, false, p)
	assert_eq(c.state, CoverController.State.IN_COVER, "one missed probe tolerated")
	c.tick(DT, Vector2.ZERO, false, p)
	assert_eq(c.state, CoverController.State.FREE, "second miss drops cover")

func test_probe_requires_tag_and_keeps_checking_locked_wall() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var root := Node3D.new()
	tree.root.add_child(root)
	var wall := StaticBody3D.new()
	wall.position = Vector3(0, 1, 0)
	wall.collision_layer = 1
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, 2, 0.2)
	shape.shape = box
	wall.add_child(shape)
	root.add_child(wall)
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	pawn.position = Vector3(0, 0, 0.6)
	root.add_child(pawn)
	pawn.set_physics_process(false)
	await tree.physics_frame
	await tree.physics_frame
	var probe := CoverProbe.new()
	assert_true(not probe.sample(pawn, _cfg(), false)["hit"], "untagged world geometry cannot snap")
	wall.add_to_group(&"cover_wall")
	var result := probe.sample(pawn, _cfg(), false)
	assert_true(result["hit"], "tagged box wall detected")
	assert_true(is_equal_approx(result["height_m"], 2.0), "wall height")
	assert_true(is_equal_approx(result["left_m"], 2.0) and is_equal_approx(result["right_m"], 2.0), "edge distances")
	assert_true(probe.sample(pawn, _cfg(), true)["hit"], "locked wall rechecked by ray")
	wall.remove_from_group(&"cover_wall")
	assert_true(not probe.sample(pawn, _cfg(), true)["hit"], "lost group invalidates lock")
	root.queue_free()
	await tree.process_frame
