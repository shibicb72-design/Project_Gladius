extends "res://tests/test_case.gd"
## GBTN5: tools/button_capture.gd _place_far_target, loaded as the real script (not SpawnLane alone). The capture
## tool aims the player at the neighbouring spawn spot from data/maps/alesia_section.json; it must put the target
## pawn far_target_distance_m (data/ui.json capture) along that line, or STOP (false, no pawn, one push_error).

const _Capture := preload("res://tools/button_capture.gd")
const STOP_MSG := "[button_capture] STOP, no usable lane"


## Counts the push_error lines whose text starts with STOP_MSG (exact prefix; the reason text follows it).
class _StopCatcher extends Logger:
	var hits: int = 0
	var others: Array[String] = []

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := rationale if rationale != "" else code
		if text.begins_with(STOP_MSG):
			hits += 1
		else:
			others.append(text)


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _spawns() -> Dictionary:
	return DataRegistry.new().load_file(DataRegistry.MAP_PATH)["spawns"]


func _spot(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## A started match with its player pawn moved onto the real spawn spot `spot_id` from the map JSON.
func _rig(spot_id: String) -> Dictionary:
	var m: MatchRoot = load("res://scenes/match/match.tscn").instantiate()
	m.auto_start = false
	m.bake_navmesh = false
	m.fill_bots = false
	_tree().root.add_child(m)
	await _tree().physics_frame
	m.director.load_config()
	m.begin()
	var pawn: Pawn = m.local_player
	pawn.set_physics_process(false)
	pawn.global_position = _spot(_spawns()[spot_id])
	await _tree().physics_frame
	await _tree().physics_frame
	return {"m": m, "pawn": pawn}


func _pawn_count(m: Node) -> int:
	var n := 0
	for c in m.get_children():
		if c is Pawn:
			n += 1
	return n


func _far_dist() -> float:
	return float(DataRegistry.new().load_file("res://data/ui.json")["capture"]["far_target_distance_m"])


## Own copy of the lane rule, from the map JSON: the first of (next, previous) ring neighbour whose muzzle ray is clear.
func _expected_dir(m: MatchRoot, pawn: Pawn, ids: Array, spawns: Dictionary, dist: float, here_idx: int) -> Dictionary:
	var here := pawn.global_position
	for step in [1, ids.size() - 1]:
		var spot := _spot(spawns[ids[(here_idx + step) % ids.size()]])
		var flat := Vector3(spot.x - here.x, 0.0, spot.z - here.z)
		var dir := flat.normalized()
		var muzzle := pawn.get_muzzle_position()
		var q := PhysicsRayQueryParameters3D.create(muzzle, muzzle + dir * dist, Hitscan.MASK_WORLD)
		if flat.length() >= dist and m.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			return {"dir": dir, "is_next": step == 1}
	return {}


func test_place_far_target_sits_toward_the_neighbour_spawn_spot() -> void:
	var spawns := _spawns()
	var ids: Array = spawns.keys()
	ids.sort()
	var rig := await _rig(ids[0])
	var m: MatchRoot = rig["m"]
	var pawn: Pawn = rig["pawn"]
	var dist := _far_dist()
	var next_cases := 0
	for i in ids.size():
		pawn.global_position = _spot(spawns[ids[i]])
		await _tree().physics_frame
		var exp := _expected_dir(m, pawn, ids, spawns, dist, i)
		if exp.is_empty():
			continue
		var want: Vector3 = exp["dir"]
		next_cases += 1 if exp["is_next"] else 0
		var before := _pawn_count(m)
		var cap = _Capture.new()
		var ok: bool = cap._place_far_target(m, pawn)
		cap.free()
		assert_true(ok, "%s: _place_far_target returns true on a clear lane" % ids[i])
		assert_eq(_pawn_count(m), before + 1, "%s: one target pawn added" % ids[i])
		var target: Pawn = null
		for c in m.get_children():
			if c is Pawn and c != pawn and c.squad_id == 1:
				target = c
		assert_true(target != null, "%s: target pawn is in squad 1" % ids[i])
		if target == null:
			continue
		var offset: Vector3 = target.global_position - pawn.global_position
		assert_true(offset.is_equal_approx(want * dist), "%s: target at pawn + dir * far_target_distance_m (%s vs %s)" % [ids[i], offset, want * dist])
		var fwd: Vector3 = -pawn.global_transform.basis.z
		assert_true(fwd.dot(want) > 0.9999, "%s: pawn faces the neighbour spot (forward %s, want %s)" % [ids[i], fwd, want])
		assert_eq(pawn.pitch, 0.0, "%s: pitch levelled" % ids[i])
		target.free()
	# The old PI/3 chord always pointed at the previous ring spot, so it only differs where the next lane is clear.
	assert_true(next_cases > 0, "at least one spawn spot has a clear lane to the next spot")
	m.queue_free()
	await _tree().physics_frame


func test_place_far_target_stops_when_no_lane_is_usable() -> void:
	var spawns := _spawns()
	var ids: Array = spawns.keys()
	ids.sort()
	var rig := await _rig(ids[0])
	var m: MatchRoot = rig["m"]
	var pawn: Pawn = rig["pawn"]
	# Fence the pawn in with world-layer walls so both ring-neighbour lanes are blocked.
	var fence := Node3D.new()
	m.add_child(fence)
	fence.global_position = pawn.global_position
	for off in [Vector3(4, 0, 0), Vector3(-4, 0, 0), Vector3(0, 0, 4), Vector3(0, 0, -4)]:
		var body := StaticBody3D.new()
		body.collision_layer = Hitscan.MASK_WORLD
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.5, 20.0, 12.0) if off.x != 0.0 else Vector3(12.0, 20.0, 0.5)
		shape.shape = box
		body.add_child(shape)
		fence.add_child(body)
		body.position = off
	await _tree().physics_frame
	await _tree().physics_frame
	var before := _pawn_count(m)
	var catcher := _StopCatcher.new()
	OS.add_logger(catcher)
	var cap = _Capture.new()
	var ok: bool = cap._place_far_target(m, pawn)
	OS.remove_logger(catcher)
	assert_true(not ok, "_place_far_target returns false when no lane is usable")
	assert_eq(_pawn_count(m), before, "no target pawn added on STOP")
	assert_eq(catcher.hits, 1, "the exact STOP push_error fired exactly once")
	assert_eq(catcher.others.size(), 0, "no other error logged: %s" % str(catcher.others))
	cap.free()
	m.queue_free()
	await _tree().physics_frame
