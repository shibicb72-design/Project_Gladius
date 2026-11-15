extends "res://tests/test_case.gd"
const DT := 1.0 / 60.0

func _cfg() -> Dictionary:
	return DataRegistry.new().load_file("res://data/cover.json")

func _probe(at: Vector3 = Vector3(0, 0, 0.45), basis: Basis = Basis.IDENTITY) -> Dictionary:
	return {"hit": true, "wall_key": 1, "normal": Vector3.BACK, "point": Vector3.ZERO, "position": at, "basis": basis, "distance_m": at.z, "left_m": at.x + 2.0, "right_m": 2.0 - at.x, "height_m": 2.2, "slide_speed_mps": 4.1783, "shot_clear": true, "stand_clear": true}

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
	# M2 C1b stage 1: the hold comes from data (snap_hold_s 0.25 s, was a fixed 30 ticks for 0.5 s).
	var hold := ceili(float(_cfg()["snap_hold_s"]) / DT - 0.0001)
	var c := CoverController.new(_cfg())
	for i in hold - 1:
		c.tick(DT, Vector2(0, -1), false, _probe())
	assert_eq(c.state, CoverController.State.FREE, "still free before snap_hold_s")
	c.tick(DT, Vector2(0, -1), false, _probe())
	assert_eq(c.state, CoverController.State.ENTERING, "snap within one tick")
	for i in 15:
		c.tick(DT, Vector2.ZERO, false, _probe())
	assert_eq(c.state, CoverController.State.IN_COVER, "enter duration")
	# A fresh controller: reset() after cover now starts the re-entry cooldown, which would mask the hold reset.
	c = CoverController.new(_cfg())
	for i in hold - 2:
		c.tick(DT, Vector2(0, -1), false, _probe())
	c.tick(DT, Vector2.ZERO, false, _probe())
	for i in hold - 1:
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
	# M2 C1b stage 3: any lateral stick slides (no peek threshold any more); sliding stops at the configured margin.
	for i in 120:
		pos = _step(c, pos, Vector2(1, 0))
	assert_true(absf(pos.x - (2.0 - float(_cfg()["edge_margin_m"]))) < 0.001, "slide stops at own wall edge")
	assert_eq(c.state, CoverController.State.IN_COVER, "a full push at the edge does not peek")
	# M2 C1b stage 3: the away push must be held exit_away_hold_s (was: one tick exited).
	var hold := ceili(float(_cfg()["exit_away_hold_s"]) / DT - 0.0001)
	for i in hold - 1:
		pos = _step(c, pos, Vector2(0, 1), yaw)
	assert_eq(c.state, CoverController.State.IN_COVER, "back projection: shorter than the hold stays")
	pos = _step(c, pos, Vector2(0, 1), yaw)
	assert_eq(c.state, CoverController.State.EXITING, "back projection uses current yaw")

## M2 C1b stage 3: was test_both_peeks_hold_and_release_return_to_anchor (the stick peek is gone; leaning is Fire / Aim
## only, stage 4). A sustained lateral push at either end now stays IN_COVER, clamped edge_margin_m short of the end.
func test_both_ends_clamp_the_slide_and_never_peek() -> void:
	for side in [-1, 1]:
		var c := CoverController.new(_cfg())
		_enter(c)
		var pos := Vector3(side * (2.0 - float(_cfg()["edge_margin_m"])), 0, 0.45)
		for i in 120:
			pos = _step(c, pos, Vector2(side * 0.6, 0))
		assert_eq(c.state, CoverController.State.IN_COVER, "sustained lateral stick stays in cover")
		assert_true(absf(pos.x - side * (2.0 - float(_cfg()["edge_margin_m"]))) < 0.001, "clamped at the edge margin")
		assert_true(c.blocks_fire(), "wall pose blocks fire")

## M2 C1b stage 3: was test_midwall_does_not_peek_and_fire_blocked_during_motion ("edge initiates peek" is gone).
func test_midwall_and_edge_push_slide_and_fire_stays_blocked() -> void:
	var c := CoverController.new(_cfg())
	_enter(c)
	c.tick(DT, Vector2(0.6, 0), true, _probe())
	assert_eq(c.state, CoverController.State.IN_COVER, "mid wall slides")
	c.tick(DT, Vector2(0.6, 0), true, _probe(Vector3(1.65, 0, 0.45)))
	assert_eq(c.state, CoverController.State.IN_COVER, "a push at the edge does not peek")
	assert_true(c.blocks_fire(), "no fire from the wall pose")

## M2 C1b stage 3: was the peek continued-push exit; now the away push held exit_away_hold_s exits.
func test_exit_hold_short_hold_back_and_reset_signals() -> void:
	var c := CoverController.new(_cfg())
	var events: Array[String] = []
	c.entered.connect(func(): events.append("entered"))
	c.peeked.connect(func(_side: int): events.append("peeked"))
	c.exited.connect(func(): events.append("exited"))
	_enter(c)
	var pos := Vector3(1.0, 0, 0.45)
	var hold := ceili(float(_cfg()["exit_away_hold_s"]) / DT - 0.0001)
	for i in hold - 1:
		pos = _step(c, pos, Vector2(0, 1))
	assert_eq(c.state, CoverController.State.IN_COVER, "short hold does not exit")
	pos = _step(c, pos, Vector2(0, 1))
	assert_eq(c.state, CoverController.State.EXITING, "held away push exits")
	for i in ceili(c.exit_duration() / DT - 0.0001):
		pos = _step(c, pos, Vector2(0, 1))
	assert_eq(c.state, CoverController.State.FREE, "exit duration then free")
	var before := pos
	pos = _step(c, pos, Vector2(0, 1))
	assert_true(pos.z > before.z, "normal movement continues")
	assert_eq(events, ["entered", "exited"], "one signal per transition")
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
