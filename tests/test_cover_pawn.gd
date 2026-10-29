extends "res://tests/test_case.gd"
const DT := 1.0 / 60.0
var _root: Node3D
var _pawn: Pawn
var _wall: StaticBody3D

func _tree() -> SceneTree:
	return Engine.get_main_loop()

func _fixture(enable: bool = true) -> void:
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
	_wall.position = Vector3(0, 1.1, -0.5)
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = Vector3(4, 2.2, 1)
	shape.shape = box
	_wall.add_child(shape)
	_root.add_child(_wall)
	_pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_pawn.position = Vector3(0, 0, 0.6)
	_root.add_child(_pawn)
	_pawn.set_physics_process(false)
	if enable:
		_pawn.enable_cover(DataRegistry.new().load_file("res://data/cover.json"))
	await _tree().physics_frame
	await _tree().physics_frame

func _tick(move: Vector2, fire: bool = false, reload: bool = false, sprint: bool = false) -> void:
	var frame := InputFrame.new()
	frame.move = move
	frame.fire_pressed = fire
	frame.reload_just_pressed = reload
	frame.sprint = sprint
	_pawn.set_frame(frame)
	var previous := _pawn.global_position
	_pawn._physics_process(DT)
	var pos := _pawn.global_position
	assert_true(Vector2(pos.x - previous.x, pos.z - previous.z).length() <= _pawn.get_max_move_speed() * DT + 0.00001, "all cover displacement speed bounded")
	assert_true(NetValidator.new().validate_move(previous, pos, DT, _pawn.get_max_move_speed(), float(_pawn._movement["jump_velocity"]), _pawn.floor_max_angle), "existing host speed check")
	await _tree().physics_frame

func _enter(sprint: bool = false) -> void:
	for i in 60:
		await _tick(Vector2(0, -1), false, false, sprint)
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "real wall snap and enter")

func _cleanup() -> void:
	_root.queue_free()
	await _tree().process_frame

func test_real_wall_snap_lock_slide_peek_fire_and_exit() -> void:
	await _fixture()
	_pawn.loadout.get_active().fire_mode = "semi"
	await _enter()
	var start := _pawn.global_position
	for i in 60:
		await _tick(Vector2(0, -1))
	assert_true(absf(_pawn.global_position.z - start.z) < 0.02, "forward cannot leave plane")
	assert_true(absf(_pawn.global_position.z - float(_pawn.cover.config["wall_offset_m"])) < 0.05, "wall offset")
	var weapon := _pawn.loadout.get_active()
	var ammo := weapon.ammo_in_mag
	for i in 60:
		await _tick(Vector2.ZERO, true)
	assert_eq(weapon.ammo_in_mag, ammo, "in-cover fire blocked")
	await _tick(Vector2.ZERO)
	for i in 100:
		await _tick(Vector2(0.49, 0))
	assert_true(absf(_pawn.global_position.x - 1.65) < 0.01, "slide ends at edge margin")
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "slide threshold below peek")
	for i in 30:
		await _tick(Vector2(0.6, 0))
	assert_eq(_pawn.cover.state, CoverController.State.PEEK_RIGHT, "real peek")
	assert_true(absf(_pawn.global_position.x - 2.65) < 0.02, "peek out past edge")
	var events := [0, 0]
	_pawn.fired.connect(func(): events[0] += 1)
	_pawn.shot.connect(func(origin: Vector3, direction: Vector3, _id: String):
		events[1] += 1
		var ray := PhysicsRayQueryParameters3D.create(origin, origin + direction * weapon.def.range_m, 1, [_pawn.get_rid()])
		var hit := _pawn.get_world_3d().direct_space_state.intersect_ray(ray)
		assert_true(hit.is_empty() or hit["collider"] != _wall, "shot ray clears cover wall")
	)
	await _tick(Vector2(0.6, 0), true)
	assert_eq(events, [1, 1], "fired and shot emitted while peeked (pre-CR1 source)")
	assert_eq(weapon.ammo_in_mag, ammo - 1, "one semi round spent")
	for i in 45:
		await _tick(Vector2(1, 0))
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "continued push exits")
	assert_true(_pawn.global_position.x > 2.65, "normal movement continues")
	await _cleanup()

func test_reload_completes_in_cover_and_lifecycle_resets() -> void:
	await _fixture()
	await _enter()
	var weapon := _pawn.loadout.get_active()
	weapon.ammo_in_mag -= 3
	await _tick(Vector2.ZERO, false, true)
	assert_true(weapon.reloading, "reload begins")
	for i in ceili(weapon.def.reload_s / DT) + 2:
		await _tick(Vector2.ZERO)
	assert_true(not weapon.reloading, "reload update still ticks while cover blocks trigger")
	assert_eq(weapon.ammo_in_mag, weapon.def.magazine, "reload refill")
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "reload preserves cover")
	_pawn.set_active(false)
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "deactivation resets cover")
	_pawn.respawn_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.6)))
	_pawn.set_physics_process(false)
	assert_eq(_pawn.cover.state, CoverController.State.FREE, "respawn resets cover")
	_pawn.disable_cover()
	assert_true(_pawn.cover == null, "explicit disable removes controller")
	await _cleanup()

func test_lazy_gate_excludes_bots_remote_and_replicas() -> void:
	await _fixture(false)
	assert_true(_pawn.cover == null, "not decided in ready")
	var brain := Node.new()
	brain.name = "Brain"
	_pawn.add_child(brain)
	var rig: CameraRig = load("res://scenes/player/camera_rig.tscn").instantiate()
	_pawn.add_child(rig)
	for i in 120:
		await _tick(Vector2(0, -1))
	assert_true(_pawn.cover == null, "bot pressing into cover for two seconds never gets controller")
	_pawn.remove_child(brain)
	brain.free()
	_pawn.net_mode = Pawn.NetMode.HOST_REMOTE
	await _tick(Vector2(0, -1))
	assert_true(_pawn.cover == null, "host remote never simulates cover")
	_pawn.net_mode = Pawn.NetMode.REPLICA
	await _tick(Vector2(0, -1))
	assert_true(_pawn.cover == null, "replica never simulates cover")
	_pawn.net_mode = Pawn.NetMode.LOCAL
	await _tick(Vector2.ZERO)
	assert_true(_pawn.cover != null, "local human gate passes on first eligible tick")
	_pawn.disable_cover()
	await _tick(Vector2.ZERO)
	assert_true(_pawn.cover == null, "explicit disable persists")
	await _cleanup()

func test_sprint_lock_forward_intent_snaps_and_stays_in_cover() -> void:
	await _fixture()
	await _enter(true)
	var start := _pawn.global_position
	for i in 60:
		await _tick(Vector2(0, -1), false, false, true)
	assert_eq(_pawn.cover.state, CoverController.State.IN_COVER, "sprint lock does not exit cover")
	assert_true(absf(_pawn.global_position.z - start.z) < 0.02, "sprint lock adds no normal motion")
	await _cleanup()

func test_cover_animation_nested_playback_preserves_existing_paths_and_head() -> void:
	await _fixture()
	var presentation := _pawn.get_node("CoverAnim") as CoverAnim
	presentation.set_process(false)
	var model := _pawn.get_node("SoldierModel") as SoldierModel
	model.set_process(false)
	var tree := model.animation_tree
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var graph := tree.tree_root as AnimationNodeBlendTree
	assert_true(graph.has_node(&"locomotion") and graph.has_node(&"upper") and graph.has_node(&"fire") and graph.has_node(&"reload"), "animation dig graph nodes preserved")
	assert_true(graph.get_node(&"cover") is AnimationNodeStateMachine and graph.get_node(&"cover_mix") is AnimationNodeBlend2, "one nested machine and one mix")
	tree.set("parameters/locomotion/blend_position", Vector2(0, -1))
	assert_eq(tree.get("parameters/locomotion/blend_position"), Vector2(0, -1), "locomotion parameter unchanged")
	assert_true(tree.get("parameters/fire/request") != null and tree.get("parameters/reload/request") != null, "OneShot request paths preserved")
	var head := _pawn.get_node("Head") as Node3D
	var head_transform := head.transform
	var body_shape: Shape3D = _pawn.get_node("CollisionShape3D").shape
	_pawn.cover.normal = Vector3.BACK
	for pair in [[CoverController.State.FREE, 1], [CoverController.State.ENTERING, 1], [CoverController.State.IN_COVER, -1], [CoverController.State.IN_COVER, 1], [CoverController.State.PEEK_LEFT, -1], [CoverController.State.PEEK_RIGHT, 1], [CoverController.State.EXITING, 1], [CoverController.State.FREE, 1]]:
		_pawn.cover.state = pair[0]
		_pawn.cover.side = pair[1]
		var expected := CoverAnim.state_clip(_pawn.cover.state, _pawn.cover.side)
		for i in ceili(float(_pawn.cover.config["animation"]["xfade_s"]) / DT) + 2:
			presentation.sync_pose(DT)
			tree.advance(DT)
			await _tree().process_frame
		if expected.is_empty():
			assert_eq(tree.get("parameters/cover_mix/blend_amount"), 0.0, "FREE original output")
			assert_eq(model.rotation.y, 0.0, "FREE visual yaw restored")
		else:
			assert_eq(String(presentation.playback.get_current_node()), expected, "actual nested playback after transition")
			assert_eq(tree.get("parameters/cover_mix/blend_amount"), 1.0, "cover layer active")
		assert_eq(head.transform, head_transform, "head hitbox and yellow shell unchanged")
		var bone_head := model.skeleton.global_transform * model.skeleton.get_bone_global_pose(model.skeleton.find_bone("Head")).origin
		assert_true(bone_head.distance_to(head.global_position) < 0.00001, "rig head stays at fixed hitbox")
		assert_true(_pawn.get_node("CollisionShape3D").shape == body_shape, "body hit shape unchanged")
		assert_eq(_pawn.rotation, Vector3.ZERO, "presentation never rotates Pawn")
	await _cleanup()
