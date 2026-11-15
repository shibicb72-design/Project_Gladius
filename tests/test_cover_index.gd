extends "res://tests/test_case.gd"
## M2P1C stop 6: CoverProbe's join of coplanar boxes through CoverIndex gives exactly the old whole-group
## walk's result. OldProbe below is the pre-stop-6 cover_probe.gd copied verbatim (the reference); every
## sample compares the two probes' whole out dictionaries with ==, unlocked and then locked.

const ALESIA := "res://data/maps/alesia_section.json"
const MAP_300 := "res://data/maps/test_300.json"
const FRACS := [-0.4, 0.0, 0.4]
const NORMALS := [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]


## The pre-stop-6 scripts/systems/cover_probe.gd, unchanged (the join walks every node of group cover_wall).
class OldProbe extends RefCounted:
	var _wall: StaticBody3D
	var _normal := Vector3.ZERO
	var _movement := DataRegistry.new().get_movement_cfg()
	var joins := 0  # test counter only: join expansions so far

	func reset() -> void:
		_wall = null
		_normal = Vector3.ZERO

	func sample(pawn: Pawn, cfg: Dictionary, locked: bool) -> Dictionary:
		var out := {"hit": false, "position": pawn.global_position, "basis": pawn.global_basis, "slide_speed_mps": pawn.get_move_speed() * float(_movement["strafe_back_ratio"]["value"])}
		out["shot_clear"] = shot_clear(pawn)
		out["stand_clear"] = standing_clear(pawn)
		out["muzzle_height_m"] = float(_movement["muzzle_height_m"])
		var weapon := pawn.loadout.get_active()
		if weapon != null:
			# M2 C1b stage 4: the live probe's weapon facts (weapon_hold_s / weapon_repeats gone, weapon_ready added).
			out["weapon_ready"] = weapon.has_ammo() and not weapon.reloading
			out["weapon_pending"] = weapon.has_ammo() and not weapon.reloading and (weapon._semi_armed or weapon._burst_left > 0)
		if not locked:
			reset()
			var from := pawn.global_position + Vector3.UP * float(cfg["probe_height_m"])
			var ahead := -pawn.global_basis.z
			ahead.y = 0
			var query := PhysicsRayQueryParameters3D.create(from, from + ahead.normalized() * float(cfg["probe_m"]), 1, [pawn.get_rid()])
			var hit := pawn.get_world_3d().direct_space_state.intersect_ray(query)
			if hit.is_empty() or not hit["collider"] is StaticBody3D or not hit["collider"].is_in_group(&"cover_wall"):
				return out
			_wall = hit["collider"]
			_normal = hit["normal"]
		if not is_instance_valid(_wall) or not _wall.is_inside_tree() or not _wall.is_in_group(&"cover_wall"):
			return out
		var shape := _wall.get_node_or_null("Shape") as CollisionShape3D
		if _wall.collision_layer & 1 == 0 or shape == null or shape.disabled or not shape.shape is BoxShape3D:
			return out
		var size := (shape.shape as BoxShape3D).size
		var center := shape.global_position
		var extent := size * 0.5
		var tangent := Vector3.UP.cross(_normal).normalized()
		var along_extent := absf(tangent.x) * extent.x + absf(tangent.z) * extent.z
		var normal_extent := absf(_normal.x) * extent.x + absf(_normal.z) * extent.z
		var point := center + _normal * normal_extent
		point.y = pawn.global_position.y
		var along := (pawn.global_position - center).dot(tangent)
		if locked:
			var inset := float(cfg["motion_epsilon_m"])
			var face := point + tangent * clampf(along, -along_extent + inset, along_extent - inset)
			face.y += float(cfg["probe_height_m"])
			var query := PhysicsRayQueryParameters3D.create(face + _normal * float(cfg["probe_m"]), face - _normal * inset, 1, [pawn.get_rid()])
			var hit := pawn.get_world_3d().direct_space_state.intersect_ray(query)
			if hit.is_empty() or hit["collider"] != _wall:
				return out
		out.merge({"hit": true, "normal": _normal, "point": point, "distance_m": absf((pawn.global_position - point).dot(_normal)), "left_m": along + along_extent, "right_m": along_extent - along, "height_m": center.y + extent.y - pawn.global_position.y, "wall_key": _wall.get_instance_id()}, true)
		var ends := Vector2(-along_extent, along_extent)
		var epsilon := float(cfg["motion_epsilon_m"])
		var changed := true
		while changed:
			changed = false
			for body in pawn.get_tree().get_nodes_in_group(&"cover_wall"):
				if not body is StaticBody3D or body == _wall:
					continue
				var other := body.get_node_or_null("Shape") as CollisionShape3D
				if other == null or other.disabled or not other.shape is BoxShape3D or body.collision_layer & 1 == 0:
					continue
				var half := (other.shape as BoxShape3D).size * 0.5
				var face := other.global_position + _normal * (absf(_normal.x) * half.x + absf(_normal.z) * half.z)
				if absf((face - point).dot(_normal)) > epsilon or other.global_position.y + half.y <= pawn.global_position.y:
					continue
				var mid := (other.global_position - center).dot(tangent)
				var radius := absf(tangent.x) * half.x + absf(tangent.z) * half.z
				if mid - radius > ends.y + epsilon or mid + radius < ends.x - epsilon:
					continue
				var expanded := Vector2(minf(ends.x, mid - radius), maxf(ends.y, mid + radius))
				if expanded != ends:
					ends = expanded
					changed = true
					joins += 1  # test counter only (not in the old file)
		out["usable_left_m"] = along - ends.x if _edge_clear(pawn, cfg, center, tangent, ends.x, -1) else INF
		out["usable_right_m"] = ends.y - along if _edge_clear(pawn, cfg, center, tangent, ends.y, 1) else INF
		return out

	func _edge_clear(pawn: Pawn, cfg: Dictionary, center: Vector3, tangent: Vector3, edge: float, side: int) -> bool:
		var start := center + tangent * edge
		start += _normal * ((pawn.global_position - center).dot(_normal))
		start.y = pawn.global_position.y + float(cfg["probe_height_m"])
		var query := PhysicsRayQueryParameters3D.create(start, start + tangent * side * float(cfg["peek_offset_m"]), 1, [pawn.get_rid()])
		return pawn.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

	func shot_clear(pawn: Pawn) -> bool:
		var weapon := pawn.loadout.get_active()
		if weapon == null:
			return false
		var start := pawn.get_muzzle_position()
		var query := PhysicsRayQueryParameters3D.create(start, start + pawn.get_aim_direction() * weapon.def.range_m, 1, [pawn.get_rid()])
		var hit := pawn.get_world_3d().direct_space_state.intersect_ray(query)
		return hit.is_empty() or not hit["collider"].is_in_group(&"cover_wall")

	func standing_clear(pawn: Pawn) -> bool:
		var body := pawn.get_node("CollisionShape3D") as CollisionShape3D
		var capsule := body.shape.duplicate() as CapsuleShape3D
		capsule.height = pawn.cover_standing_height()
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = capsule
		query.transform = Transform3D(pawn.global_basis, pawn.global_position + Vector3.UP * capsule.height * 0.5)
		query.collision_mask = 1
		query.exclude = [pawn.get_rid()]
		if not pawn.get_world_3d().direct_space_state.intersect_shape(query).is_empty():
			return false
		query.shape = pawn.get_node("Head/CollisionShape3D").shape
		query.transform.origin = pawn.global_position + Vector3.UP * pawn.cover_standing_head_y()
		return pawn.get_world_3d().direct_space_state.intersect_shape(query).is_empty()


var _cfg: Dictionary = DataRegistry.new().load_file("res://data/cover.json")
var _mismatches := 0
var _hits := 0
var _joined := 0


func _tree() -> SceneTree:
	return Engine.get_main_loop()


## Same build as tests/test_terrain_pieces.gd: the map scene of a map json, in the tree, after two physics frames.
func _build(json_path: String) -> Node3D:
	var map: Node3D = load(String(DataRegistry.parse_quiet(json_path)["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", json_path)
	_tree().root.add_child(map)
	await _tree().physics_frame
	await _tree().physics_frame
	return map


func _pawn(parent: Node) -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	parent.add_child(pawn)
	pawn.set_physics_process(false)
	return pawn


## True when the two out dictionaries are equal (exact ==, key by key); records the first few differences.
func _same(new_out: Dictionary, old_out: Dictionary, label: String) -> bool:
	var ok := new_out.size() == old_out.size()
	for key in old_out:
		if not new_out.has(key) or new_out[key] != old_out[key]:
			ok = false
			if _mismatches < 5:
				failures.append("%s: key %s new %s old %s" % [label, key, str(new_out.get(key)), str(old_out[key])])
	if not ok:
		_mismatches += 1
	return ok


## Samples both probes (unlocked, then locked on the wall that was found) at the pawn's current transform.
func _compare_at(pawn: Pawn, probe: CoverProbe, old: OldProbe, label: String) -> void:
	var a := probe.sample(pawn, _cfg, false)
	var joins_before := old.joins
	var b := old.sample(pawn, _cfg, false)
	_same(a, b, label + " unlocked")
	if bool(b["hit"]):
		_hits += 1
		if old.joins > joins_before:
			_joined += 1  # the old walk joined at least one other box on this sample
		_same(probe.sample(pawn, _cfg, true), old.sample(pawn, _cfg, true), label + " locked")


## Pawn transforms facing every cover_wall face (both sides of each axis) at three points along it.
func _stands(map: Node3D, terrain: MapTerrain) -> Array:
	var out: Array = []
	for node in _tree().get_nodes_in_group(&"cover_wall"):
		if not node is StaticBody3D or not map.is_ancestor_of(node):
			continue
		var shape := node.get_node_or_null("Shape") as CollisionShape3D
		if shape == null or not shape.shape is BoxShape3D:
			continue
		var half := (shape.shape as BoxShape3D).size * 0.5
		var c := shape.global_position
		for n: Vector3 in NORMALS:
			var t := Vector3.UP.cross(n)
			var depth := absf(n.x) * half.x + absf(n.z) * half.z
			var width := absf(t.x) * half.x + absf(t.z) * half.z
			for f: float in FRACS:
				var at := Vector3(c.x, 0.0, c.z) + n * (depth + 0.55) + t * (f * 2.0 * width)
				at.y = terrain.height_at(at.x, at.z) if terrain != null else 0.0
				out.append(Transform3D(Basis.looking_at(-n), at))
	return out


func _compare_map(map: Node3D, label: String, limit: int = 1 << 30) -> int:
	var builder := map.get_node("ArtBuilder")
	var pawn := _pawn(map)
	var probe := CoverProbe.new()
	var old := OldProbe.new()
	var count := 0
	for xf: Transform3D in _stands(map, builder.get("terrain")):
		if count >= limit:
			break
		pawn.global_transform = xf
		_compare_at(pawn, probe, old, "%s #%d at %s" % [label, count, str(xf.origin)])
		count += 1
	pawn.free()
	return count


func test_both_maps_every_face_equals_the_old_walk() -> void:
	for path: String in [ALESIA, MAP_300]:
		_mismatches = 0
		_hits = 0
		_joined = 0
		var map := await _build(path)
		# The map walls alone never join from these stands (no coplanar neighbours), so every 5th one gets a
		# twin box abutting it along x (same size, plane and height): its stands then join the twin.
		var twins := 0
		var walls: Array = []
		for node in _tree().get_nodes_in_group(&"cover_wall"):
			if node is StaticBody3D and map.is_ancestor_of(node):
				walls.append(node)
		for i in range(0, walls.size(), 5):
			var shape := (walls[i] as Node).get_node_or_null("Shape") as CollisionShape3D
			if shape == null or not shape.shape is BoxShape3D:
				continue
			var size := (shape.shape as BoxShape3D).size
			_box(map, shape.global_position + Vector3(size.x, 0.0, 0.0) - map.global_position, size)
			twins += 1
		await _tree().physics_frame
		var samples := _compare_map(map, path.get_file())
		print("COVER_INDEX map=%s walls=%d (of which twins %d) samples=%d hits=%d joined=%d mismatches=%d" % [path.get_file(), _tree().get_node_count_in_group(&"cover_wall"), twins, samples, _hits, _joined, _mismatches])
		assert_true(samples > 300 and _hits > 100 and _joined > 10, "%s: nonvacuous (samples %d, hits %d, joined %d)" % [path, samples, _hits, _joined])
		assert_eq(_mismatches, 0, path + ": every sample equals the old walk")
		map.free()


## A wall box under `root` in group cover_wall.
func _box(root: Node3D, at: Vector3, size: Vector3, tag: bool = true) -> StaticBody3D:
	var body := StaticBody3D.new()
	if tag:
		body.add_to_group(&"cover_wall")
	body.position = at
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	return body


func _floor(root: Node3D) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 0.2, 400)
	shape.shape = box
	body.position = Vector3(50, -0.1, 0)
	body.add_child(shape)
	root.add_child(body)


## The chain fixture: 16 boxes 2 m wide along x from 87 to 119 (across the 96/112 index cell borders and the
## 100 m chunk border), a chain along z across z = 32/48, and one across x = 0 (negative cells).
func _chain_fixture(root: Node3D) -> Array:
	_floor(root)
	var chain: Array = []
	for i in 16:
		chain.append(_box(root, Vector3(88.0 + 2.0 * i, 1.0, -0.3), Vector3(2, 2, 0.6)))
	for i in 12:
		_box(root, Vector3(29.7, 1.0, 29.0 + 2.0 * i), Vector3(0.6, 2, 2))
	for i in 20:
		_box(root, Vector3(-19.0 + 2.0 * i, 1.0, -40.3), Vector3(2, 2, 0.6))
	return chain


func _probe_points() -> Array:
	return [Transform3D(Basis.IDENTITY, Vector3(100.0, 0.0, 0.55)), Transform3D(Basis.IDENTITY, Vector3(111.3, 0.0, 0.55)),
			Transform3D(Basis.looking_at(Vector3.LEFT), Vector3(30.55, 0.0, 40.2)), Transform3D(Basis.IDENTITY, Vector3(0.4, 0.0, -39.45)),
			Transform3D(Basis.IDENTITY, Vector3(-15.0, 0.0, -39.45))]


func _compare_points(pawn: Pawn, probe: CoverProbe, old: OldProbe, label: String) -> void:
	var i := 0
	for xf: Transform3D in _probe_points():
		pawn.global_transform = xf
		_compare_at(pawn, probe, old, "%s point %d" % [label, i])
		i += 1


func test_chain_across_cell_and_chunk_borders_and_live_changes() -> void:
	_mismatches = 0
	_hits = 0
	_joined = 0
	var root := Node3D.new()
	_tree().root.add_child(root)
	var chain := _chain_fixture(root)
	var pawn := _pawn(root)
	await _tree().physics_frame
	await _tree().physics_frame
	var probe := CoverProbe.new()
	var old := OldProbe.new()
	_compare_points(pawn, probe, old, "chain")
	pawn.global_transform = _probe_points()[0]
	var out := probe.sample(pawn, _cfg, false)
	assert_true(bool(out["hit"]) and is_equal_approx(float(out["usable_left_m"]), 13.0) and is_equal_approx(float(out["usable_right_m"]), 19.0),
			"the chain joins across the cell and chunk borders: ends 87..119 (got %s / %s)" % [out.get("usable_left_m"), out.get("usable_right_m")])
	var index := CoverIndex.of(_tree())
	var builds := index.builds
	# A wall added after the index was built, extending the chain (no frame in between).
	var added := _box(root, Vector3(120.0, 1.0, -0.3), Vector3(2, 2, 0.6))
	_compare_points(pawn, probe, old, "added")
	pawn.global_transform = _probe_points()[0]
	assert_true(is_equal_approx(float(probe.sample(pawn, _cfg, false)["usable_right_m"]), 21.0), "the added wall joins at once")
	assert_true(index.builds > builds, "the added wall rebuilt the index")
	# An untagged body tagged later (no node_added): the group array check sees it.
	var late := _box(root, Vector3(122.0, 1.0, -0.3), Vector3(2, 2, 0.6), false)
	_compare_points(pawn, probe, old, "untagged")
	late.add_to_group(&"cover_wall")
	_compare_points(pawn, probe, old, "tagged later")
	pawn.global_transform = _probe_points()[0]
	var got := float(probe.sample(pawn, _cfg, false)["usable_right_m"])
	assert_true(is_equal_approx(got, 23.0), "the late-tagged wall joins (got %s)" % got)
	# A disabled shape and a wall off layer 1 break the chain (live checks).
	(chain[12].get_node("Shape") as CollisionShape3D).disabled = true
	_compare_points(pawn, probe, old, "disabled")
	(chain[12].get_node("Shape") as CollisionShape3D).disabled = false
	chain[3].collision_layer = 2
	_compare_points(pawn, probe, old, "layer")
	chain[3].collision_layer = 1
	# Removed from the tree, then freed.
	root.remove_child(chain[10])
	_compare_points(pawn, probe, old, "removed")
	root.add_child(chain[10])
	_compare_points(pawn, probe, old, "re-added")
	chain[2].free()
	_compare_points(pawn, probe, old, "freed")
	added.queue_free()
	await _tree().process_frame
	_compare_points(pawn, probe, old, "queue_freed")
	# A silent move (the body itself, its Shape child, or an ancestor; no tree change, no signal) is seen from
	# the next frame on (the once-per-frame full validation, see CoverIndex): after one physics frame every
	# sample equals the old walk exactly. Within the frame of the move, the samples cost no full validation and
	# no rebuild (deterministic: no frame passes between these lines); their results are not asserted.
	chain[14].position = Vector3(60.0, 1.0, -0.3)
	var v_before := index.validations
	var b_before := index.builds
	pawn.global_transform = _probe_points()[0]
	probe.sample(pawn, _cfg, false)
	probe.sample(pawn, _cfg, false)
	assert_eq(index.validations, v_before, "a sample in the frame of a silent move runs no full validation")
	assert_eq(index.builds, b_before, "a silent move is not rebuilt within its frame (documented rule)")
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "moved away")
	assert_true(index.builds > b_before, "the moved wall rebuilt the index after one frame")
	chain[14].position = Vector3(116.0, 1.0, -0.3)
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "moved back")
	var far := _box(root, Vector3(-80.0, 1.0, -0.3), Vector3(2, 2, 0.6))
	_compare_points(pawn, probe, old, "far wall")
	far.position = Vector3(120.0, 1.0, -0.3)  # fills the gap `added` left: the chain runs on through `late` to 123
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "moved in")
	pawn.global_transform = _probe_points()[0]
	assert_true(is_equal_approx(float(probe.sample(pawn, _cfg, false)["usable_right_m"]), 23.0), "the wall moved in joins after one frame (right end 123)")
	(chain[7].get_node("Shape") as CollisionShape3D).position = Vector3(0.0, 0.0, 30.0)
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "shape moved")
	(chain[7].get_node("Shape") as CollisionShape3D).position = Vector3.ZERO
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "shape moved back")
	var holder := Node3D.new()
	root.add_child(holder)
	var held := _box(holder, Vector3(-60.0, 1.0, -0.3), Vector3(2, 2, 0.6))
	_compare_points(pawn, probe, old, "held far")
	holder.position = Vector3(184.0, 0.0, 0.0)  # moves `held` to x = 124 through its parent only
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "parent moved")
	pawn.global_transform = _probe_points()[0]
	assert_true(is_equal_approx(float(probe.sample(pawn, _cfg, false)["usable_right_m"]), 25.0), "a wall moved by its parent joins after one frame (right end 125)")
	# A resize through the same box resource is seen at once (its `changed` signal), no frame in between.
	((chain[0].get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size = Vector3(30, 2, 0.6)
	_compare_points(pawn, probe, old, "resized")
	# A far wall resized (same box resource) and another given a new box, both reaching into the chain.
	var grown := _box(root, Vector3(40.0, 1.0, -0.3), Vector3(2, 2, 0.6))
	var swapped := _box(root, Vector3(-40.0, 1.0, -0.3), Vector3(2, 2, 0.6))
	_compare_points(pawn, probe, old, "before growing")
	((grown.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size = Vector3(110, 2, 0.6)  # -15..95
	_compare_points(pawn, probe, old, "grown")
	pawn.global_transform = _probe_points()[0]
	got = float(probe.sample(pawn, _cfg, false)["usable_left_m"])
	assert_true(is_equal_approx(got, 115.0), "a wall resized in place joins at once (left end -15, got %s)" % got)
	# A Shape given another box resource (no signal) is seen from the next frame on, like a silent move.
	var big_box := BoxShape3D.new()
	big_box.size = Vector3(60, 2, 0.6)  # -70..-10
	(swapped.get_node("Shape") as CollisionShape3D).shape = big_box
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "box swapped")
	pawn.global_transform = _probe_points()[0]
	got = float(probe.sample(pawn, _cfg, false)["usable_left_m"])
	assert_true(is_equal_approx(got, 170.0), "a wall given a new box joins after one frame (left end -70, got %s)" % got)
	(chain[1].get_node("Shape") as CollisionShape3D).shape = BoxShape3D.new()
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "small box swapped")
	await _tree().physics_frame
	_compare_points(pawn, probe, old, "after a frame")
	# A shape renamed away and back (node_renamed).
	var shape := chain[5].get_node("Shape") as CollisionShape3D
	shape.name = "NotShape"
	_compare_points(pawn, probe, old, "renamed away")
	shape.name = "Shape"
	_compare_points(pawn, probe, old, "renamed back")
	print("COVER_INDEX chain samples hits=%d joined=%d mismatches=%d" % [_hits, _joined, _mismatches])
	assert_true(_hits > 60 and _joined > 40, "nonvacuous: probes hit walls (%d) and join boxes (%d)" % [_hits, _joined])
	assert_eq(_mismatches, 0, "every chain sample equals the old walk")
	root.free()


## Many samples within one frame cost at most one full (O(walls)) validation; the next frame costs one more.
func test_samples_in_one_frame_cost_one_full_validation() -> void:
	var root := Node3D.new()
	_tree().root.add_child(root)
	_chain_fixture(root)
	var pawn := _pawn(root)
	await _tree().physics_frame
	await _tree().physics_frame
	var probe := CoverProbe.new()
	var index := CoverIndex.of(_tree())
	var v0 := index.validations
	var b0 := index.builds
	var hits := 0
	for i in 200:
		pawn.global_transform = _probe_points()[i % _probe_points().size()]
		if bool(probe.sample(pawn, _cfg, false)["hit"]):
			hits += 1
	assert_true(hits >= 40, "nonvacuous: the samples hit walls (%d)" % hits)
	assert_true(index.validations - v0 <= 1, "200 samples in one frame: at most one full validation (got %d)" % (index.validations - v0))
	assert_true(index.builds - b0 <= 1, "200 samples in one frame: at most one build (the new walls) (got %d)" % (index.builds - b0))
	await _tree().physics_frame
	var v1 := index.validations
	var b1 := index.builds
	for i in 200:
		pawn.global_transform = _probe_points()[i % _probe_points().size()]
		probe.sample(pawn, _cfg, false)
	assert_eq(index.validations - v1, 1, "the next frame's 200 samples: exactly one full validation")
	assert_eq(index.builds, b1, "static walls: no rebuild")
	root.free()


func test_two_maps_in_one_process() -> void:
	_mismatches = 0
	_hits = 0
	var alesia := await _build(ALESIA)
	_compare_map(alesia, "alesia alone", 200)
	var index := CoverIndex.of(_tree())
	var alone := index.size()
	# Both maps in the tree at once: the old walk saw every cover_wall in the tree, so must the index.
	var big := await _build(MAP_300)
	_compare_map(alesia, "alesia beside test_300", 200)
	_compare_map(big, "test_300 beside alesia", 200)
	assert_true(index.size() > alone, "the index holds both maps' walls while both are in the tree")
	alesia.free()
	_compare_map(big, "test_300 after alesia freed", 300)
	assert_eq(index.size(), _static_walls(), "no freed wall of the first map stays in the index")
	big.free()
	var again := await _build(ALESIA)
	_compare_map(again, "alesia rebuilt", 200)
	assert_eq(index.size(), _static_walls(), "a rebuilt map holds only its own walls")
	assert_true(_hits > 200, "nonvacuous (%d hits)" % _hits)
	assert_eq(_mismatches, 0, "every sample equals the old walk across maps")
	again.free()


## The old walk's per-wall acceptance (geometry part) against `ends`, for the superset test.
func _old_accepts(other: CollisionShape3D, n: Vector3, point: Vector3, center: Vector3, t: Vector3, ends: Vector2, eps: float) -> bool:
	var half := (other.shape as BoxShape3D).size * 0.5
	var face := other.global_position + n * (absf(n.x) * half.x + absf(n.z) * half.z)
	if absf((face - point).dot(n)) > eps or other.global_position.y + half.y <= point.y:
		return false
	var mid := (other.global_position - center).dot(t)
	var radius := absf(t.x) * half.x + absf(t.z) * half.z
	return not (mid - radius > ends.y + eps or mid + radius < ends.x - eps)


## Seeded random walls (thin, long, square, huge, y-rotated) and random queries (any horizontal direction,
## tiny tilts, targeted at a wall's face or anywhere): every wall the old test accepts is among
## walls_near's candidates, and the candidates are far fewer than all walls.
func test_walls_near_never_misses_an_accepted_wall() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 60606
	var root := Node3D.new()
	_tree().root.add_child(root)
	var shapes: Array = []
	for i in 400:
		var size := Vector3(rng.randf_range(0.05, 6.0), rng.randf_range(0.5, 3.0), rng.randf_range(0.05, 6.0))
		match i % 5:
			0: size.x = rng.randf_range(8.0, 40.0)  # long along x
			1: size.z = rng.randf_range(8.0, 40.0)  # long along z
			2: size = Vector3(rng.randf_range(10.0, 30.0), size.y, rng.randf_range(10.0, 30.0))
		if i == 7:
			size = Vector3(600.0, 2.0, 0.6)  # bigger than MAX_CELLS_PER_WALL: always checked
		var body := _box(root, Vector3(rng.randf_range(-150.0, 150.0), rng.randf_range(-1.0, 3.0), rng.randf_range(-150.0, 150.0)), size)
		body.rotation.y = rng.randf_range(-PI, PI) if i % 3 == 0 else 0.0
		shapes.append(body.get_node("Shape"))
	var index := CoverIndex.of(_tree())
	index.refresh()
	var accepted := 0
	var queries := 0
	var candidates := 0
	var missed := 0
	for q in 3000:
		var a := rng.randf_range(-PI, PI) if q % 2 == 0 else float(rng.randi_range(0, 7)) * PI * 0.25
		var n := Vector3(cos(a), 0.0, sin(a))
		if q % 7 == 0:
			n = Vector3(n.x, rng.randf_range(-0.0009, 0.0009), n.z).normalized()
		var eps := [0.01, 0.05, 0.3][q % 3] as float
		var center: Vector3
		var point: Vector3
		var pawn_y := rng.randf_range(-1.0, 2.0)
		if q % 4 != 3:
			var s: CollisionShape3D = shapes[rng.randi_range(0, shapes.size() - 1)]
			var half := (s.shape as BoxShape3D).size * 0.5
			center = s.global_position
			point = center + n * (absf(n.x) * half.x + absf(n.z) * half.z)
		else:
			center = Vector3(rng.randf_range(-150.0, 150.0), 0.0, rng.randf_range(-150.0, 150.0))
			point = center + n * rng.randf_range(0.0, 5.0)
		point.y = pawn_y
		var t := Vector3.UP.cross(n).normalized()
		var ends := Vector2(-rng.randf_range(0.0, 30.0), rng.randf_range(0.0, 30.0))
		var near := index.walls_near(n, point, center, t, ends, eps)
		var near_set := {}
		for b in near:
			near_set[b] = true
		candidates += near.size()
		queries += 1
		for s: CollisionShape3D in shapes:
			if _old_accepts(s, n, point, center, t, ends, eps):
				accepted += 1
				if not near_set.has(s.get_parent()):
					missed += 1
					if missed <= 5:
						failures.append("missed wall at %s size %s for n %s ends %s" % [s.global_position, (s.shape as BoxShape3D).size, n, ends])
	print("COVER_INDEX superset queries=%d accepted=%d missed=%d mean_candidates=%.1f of %d walls" % [queries, accepted, missed, float(candidates) / queries, shapes.size()])
	assert_true(accepted > 1000,"nonvacuous: the old test accepts many walls (%d)" % accepted)
	assert_eq(missed, 0, "walls_near never misses a wall the old test accepts")
	assert_true(float(candidates) / queries < shapes.size() * 0.5, "the index narrows the candidates")
	root.free()


func _static_walls() -> int:
	var n := 0
	for node in _tree().get_nodes_in_group(&"cover_wall"):
		if node is StaticBody3D:
			n += 1
	return n


## Report only: microseconds per CoverProbe.sample, old walk vs index, same samples, same process, warm.
func test_cover_time_proxy() -> void:
	for path: String in [ALESIA, MAP_300]:
		var map := await _build(path)
		var pawn := _pawn(map)
		var probe := CoverProbe.new()
		var old := OldProbe.new()
		var set_: Array = []
		for xf: Transform3D in _stands(map, map.get_node("ArtBuilder").get("terrain")):
			pawn.global_transform = xf
			if bool(old.sample(pawn, _cfg, false)["hit"]):
				set_.append(xf)
			if set_.size() >= 400:
				break
		var olds: Array = []
		var news: Array = []
		var valids: Array = []
		var index := CoverIndex.of(_tree())
		var builds := -1
		var validated := 0
		for run in 7:
			# Each run starts on a new frame, so each pays one full validation, spread over its samples.
			await _tree().physics_frame
			var t0 := Time.get_ticks_usec()
			for xf: Transform3D in set_:
				pawn.global_transform = xf
				old.sample(pawn, _cfg, false)
			var t1 := Time.get_ticks_usec()
			var v0 := index.validations
			for xf: Transform3D in set_:
				pawn.global_transform = xf
				probe.sample(pawn, _cfg, false)
			var t2 := Time.get_ticks_usec()
			if run > 0:
				validated += index.validations - v0
			var members := _tree().get_nodes_in_group(&"cover_wall")
			assert_true(members == index._members and index._valid(), "index valid")
			var t3 := Time.get_ticks_usec()
			if run == 0:
				builds = index.builds
			olds.append(float(t1 - t0) / set_.size())
			news.append(float(t2 - t1) / set_.size())
			valids.append(float(t3 - t2))
		olds.sort()
		news.sort()
		valids.sort()
		assert_eq(index.builds, builds, "warm runs never rebuild the index (static walls)")
		assert_eq(validated, 6, "one full validation per warm run (one frame each)")
		print("COVER_TIME map=%s walls=%d samples=%d old_us=%.1f index_us=%.1f full_validation_us=%.1f once per frame (per-sample share ~%.2f at %d samples per frame) (median of 7, whole CoverProbe.sample on a hit)" % [path.get_file(), index.size(), set_.size(), olds[3], news[3], valids[3], valids[3] / set_.size(), set_.size()])
		assert_true(set_.size() > 100, "nonvacuous time set")
		pawn.free()
		map.free()
