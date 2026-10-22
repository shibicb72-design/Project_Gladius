extends "res://tests/test_case.gd"
## Walls, pawns, hitscan rays, the head Area3D and the hill Area3D must behave the same on Jolt (G1).

const _Range := preload("res://scenes/test/weapon_range.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _ticks(n: int) -> void:
	for i in n:
		await _tree().physics_frame


func _world() -> Node3D:
	var scene: Node3D = _Range.instantiate()
	_tree().root.add_child(scene)
	return scene


func test_wall_blocks_pawn() -> void:
	var scene := _world()
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 4.0, 0.5)
	cs.shape = box
	wall.add_child(cs)
	scene.add_child(wall)
	wall.global_position = Vector3(20.0, 2.0, -3.0)
	var player: Pawn = scene.get_node("Player")
	player.global_position = Vector3(20.0, 0.0, 0.0)
	var f := InputFrame.new()
	f.move = Vector2(0.0, -1.0)
	player.set_frame(f)
	await _ticks(120)
	# Wall front face is at z = -2.75; the capsule radius is 0.4.
	assert_true(player.global_position.z > -2.75 + 0.4 - 0.05, "pawn stopped at the wall (z=%.3f)" % player.global_position.z)
	assert_true(player.global_position.z < -2.0, "pawn reached the wall (z=%.3f)" % player.global_position.z)
	scene.queue_free()


func test_pawns_do_not_block_each_other() -> void:
	# Current layout (pawn.tscn:21-22): pawns are on layer 2 and collide with the world (layer 1) only.
	var scene := _world()
	var player: Pawn = scene.get_node("Player")
	var f := InputFrame.new()
	f.move = Vector2(0.0, -1.0)
	player.set_frame(f)
	await _ticks(180)
	assert_true(player.global_position.z < -11.0, "player walked through the dummy at z=-10 (z=%.2f)" % player.global_position.z)
	scene.queue_free()


func test_hitscan_body_head_miss_and_world() -> void:
	var scene := _world()
	await _ticks(3)
	var player: Pawn = scene.get_node("Player")
	var dummy: Pawn = scene.get_node("Dummy")
	var def: WeaponDef = player.loadout.get_active().def
	var space := player.get_world_3d().direct_space_state
	var ex := player.hitscan_exclude()
	var body := Hitscan.cast(space, Vector3(0.0, 0.8, 0.0), Vector3(0.0, 0.0, -1.0), def, ex)
	assert_true(not body.is_empty() and body["target"] == dummy and not body["is_headshot"], "chest ray hits the dummy body")
	var head := Hitscan.cast(space, Vector3(0.0, 1.75, 0.0), Vector3(0.0, 0.0, -1.0), def, ex)
	assert_true(not head.is_empty() and head["target"] == dummy and head["is_headshot"], "head-height ray hits the head Area3D")
	var sky := Hitscan.cast(space, Vector3(0.0, 1.75, 0.0), Vector3(0.0, 1.0, 0.0), def, ex)
	assert_true(sky.is_empty(), "upward ray misses")
	var ground := Hitscan.cast(space, Vector3(5.0, 1.0, 0.0), Vector3(0.0, -1.0, 0.0), def, ex)
	assert_true(not ground.is_empty() and ground["target"] == null, "downward ray hits the world only")
	assert_true(absf(float(ground["position"].y)) < 0.01, "floor top is at y=0 (y=%.3f)" % float(ground["position"].y))
	var self_hit := Hitscan.cast(space, Vector3(0.0, 1.75, 0.0), Vector3(0.0, 0.0, 1.0), def, ex)
	assert_true(self_hit.is_empty() or self_hit["target"] != player, "own body and head are excluded")
	scene.queue_free()


func test_head_and_hill_area_layers() -> void:
	# Jolt reports Area3D/SoftBody3D overlaps (breaking-changes.md:27); there is no SoftBody3D, and these
	# areas only ever look at layer 2 (pawn bodies) or nothing.
	var scene := _world()
	var head := scene.get_node("Player/Head") as Area3D
	assert_eq(head.collision_layer, 4, "head area is on layer 4")
	assert_eq(head.collision_mask, 0, "head area detects nothing")
	var hill := HillZone.new()
	assert_eq(hill.collision_layer, 0, "hill is on no layer")
	assert_eq(hill.collision_mask, 2, "hill detects pawn bodies only")
	hill.free()
	scene.queue_free()


func test_hill_detects_pawns() -> void:
	var scene := _world()
	var hill := HillZone.new()
	scene.add_child(hill)
	hill.configure(Vector3(0.0, 0.0, -10.0), 3.0, 2.0)
	await _ticks(5)
	var dummy: Pawn = scene.get_node("Dummy")
	var occ := hill.occupancy()
	assert_eq(occ, {1: 1}, "only the dummy (squad 1) stands on the hill")
	dummy.set_active(false)
	await _ticks(5)
	assert_eq(hill.occupancy(), {}, "an inactive pawn leaves the hill")
	dummy.set_active(true)
	dummy.global_position = Vector3(30.0, 0.0, -10.0)
	await _ticks(5)
	assert_eq(hill.occupancy(), {}, "a pawn outside the hill is not counted")
	scene.queue_free()
