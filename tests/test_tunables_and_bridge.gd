extends "res://tests/test_case.gd"
## Review L4 leftovers: replica application, director start failure path, pitch clamp from data.

const _PawnScene := preload("res://scenes/player/pawn.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func test_bridge_snapshot_applies_replica() -> void:
	var tree := _tree()
	var director := MatchDirector.new()
	tree.root.add_child(director)
	var local: Pawn = _PawnScene.instantiate()
	var remote: Pawn = _PawnScene.instantiate()
	tree.root.add_child(local)
	tree.root.add_child(remote)
	local.setup("hastati", 0)
	remote.setup("hastati", 1)
	director.add_player(0, local)
	director.add_player(1, remote)
	local.global_position = Vector3(1.0, 0.0, 2.0)
	remote.global_position = Vector3.ZERO
	var b := NetMatchBridge.new()
	tree.root.add_child(b)
	await tree.physics_frame
	b.setup(director)
	b.snapshot(1, [
		[0, Vector3(50.0, 0.0, 50.0), 1.0, 10.0, 20.0, true],
		[1, Vector3(7.0, 0.0, -3.0), 0.5, 11.0, 22.0, true],
	])
	b.apply_replica(0)
	assert_true(remote.global_position.is_equal_approx(Vector3(7.0, 0.0, -3.0)), "non-local pawn moved to replica")
	assert_true(absf(remote.rotation.y - 0.5) < 0.0001, "non-local pawn yaw from replica")
	assert_eq(remote.bridge.state.shield, 11.0, "non-local shield from replica")
	assert_eq(remote.bridge.state.health, 22.0, "non-local health from replica")
	assert_true(local.global_position.is_equal_approx(Vector3(1.0, 0.0, 2.0)), "local pawn left alone")
	b.detach()
	b.queue_free()
	director.queue_free()
	local.queue_free()
	remote.queue_free()
	await tree.physics_frame


func test_match_director_start_fails_with_more_squads_than_spots() -> void:
	var tree := _tree()
	var d := MatchDirector.new()
	tree.root.add_child(d)
	d.load_config()
	var spots := {"only": Transform3D.IDENTITY}
	var ok := d.start([0, 1, 2], spots, null)
	assert_eq(ok, false, "start returns false with 3 squads on 1 spot")
	assert_eq(d.running, false, "match not running after failed start")
	d.queue_free()
	await tree.physics_frame


func test_pitch_clamp_uses_camera_data() -> void:
	var cam: Dictionary = DataRegistry.new().get_camera_cfg()
	var p: Pawn = _PawnScene.instantiate()
	p.setup("hastati", 0)
	var up := InputFrame.new()
	up.look = Vector2(0.0, -10.0)  # pitch - look.y: looks far up
	p.set_frame(up)
	p._apply_look()
	assert_true(absf(p.pitch - deg_to_rad(float(cam["pitch_max_deg"]))) < 0.0001, "clamped to camera.json pitch_max_deg")
	var down := InputFrame.new()
	down.look = Vector2(0.0, 10.0)
	p.set_frame(down)
	p._apply_look()
	assert_true(absf(p.pitch - deg_to_rad(float(cam["pitch_min_deg"]))) < 0.0001, "clamped to camera.json pitch_min_deg")
	# The clamp follows the data, not a constant.
	p._camera = {"pitch_min_deg": -30.0, "pitch_max_deg": 40.0}
	p.set_frame(up)
	p._apply_look()
	assert_true(absf(p.pitch - deg_to_rad(40.0)) < 0.0001, "overridden max respected")
	p.free()
