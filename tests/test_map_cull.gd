extends "res://tests/test_case.gd"
## M2P1C: draw limits for a big map. Stop 1 pins the placement the visibility range relies on. Godot 4.7.2
## measures visibility_range_end from the camera to the centre of an instance's WORLD AABB
## (tools/vis_range_probe.gd, windowed), so the batches and terrain chunk meshes stay at the origin with world-space
## instance transforms and vertices: their AABB centre is their own content, inside or next to their chunk cell.

const MAPS := ["res://data/maps/alesia_section.json", "res://data/maps/test_300.json"]


func _build(json_path: String) -> Node3D:
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load(String(DataRegistry.parse_quiet(json_path)["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", json_path)
	tree.root.add_child(map)
	return map


func _label(json_path: String) -> String:
	return json_path.get_file().get_basename()


## The x, z centre of chunk cell `index` on the world ground plane.
func _cell_centre(chunks: MapChunks, index: Vector2i) -> Vector2:
	var cs := chunks.chunk_size_m
	if chunks.per_side <= 1:
		return Vector2.ZERO
	return Vector2(-chunks.half_m + (index.x + 0.5) * cs, -chunks.half_m + (index.y + 0.5) * cs)


func test_batches_stay_at_the_origin_and_measure_from_their_content() -> void:
	for json_path: String in MAPS:
		var label := _label(json_path)
		var map := _build(json_path)
		var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
		assert_true(chunks.global_transform.is_equal_approx(Transform3D.IDENTITY), label + ": Chunks at the world origin")
		var batches := chunks.batches()
		assert_true(batches.size() > 0, label + ": nonvacuous")
		for batch in batches:
			var tag := "%s %s/%s" % [label, batch.get_parent().name, batch.name]
			var index: Vector2i = batch.get_parent().get_meta(&"index")
			assert_true(batch.get_parent().transform == Transform3D.IDENTITY and batch.transform == Transform3D.IDENTITY, tag + ": chunk and batch nodes keep identity transforms")
			assert_true(batch.global_transform.is_equal_approx(Transform3D.IDENTITY), tag + ": world = instance transform")
			var placed: Array = batch.get_meta(&"transforms")
			assert_eq(placed.size(), batch.multimesh.instance_count, tag + ": one world transform per instance")
			# The renderer measures from the world AABB centre: it must lie in the chunk cell, grown by the largest
			# instance's half extent (an instance origin is always in its cell).
			var local := batch.multimesh.mesh.get_aabb()
			var reach := 0.0
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for xform: Transform3D in placed:
				var box: AABB = batch.global_transform * (xform * local)
				reach = maxf(reach, maxf(box.size.x, box.size.z) * 0.5)
				lo = Vector2(minf(lo.x, box.position.x), minf(lo.y, box.position.z))
				hi = Vector2(maxf(hi.x, box.end.x), maxf(hi.y, box.end.z))
			var centre := MapChunks.range_centre(batch)
			assert_true(is_equal_approx(centre.x, (lo.x + hi.x) * 0.5) and is_equal_approx(centre.z, (lo.y + hi.y) * 0.5), tag + ": range_centre is the centre of the instances' world AABB")
			var cell := _cell_centre(chunks, index)
			var half := chunks.chunk_size_m * 0.5 + reach + 1e-3 if chunks.per_side > 1 else INF
			assert_true(absf(centre.x - cell.x) <= half and absf(centre.z - cell.y) <= half, "%s: measured from its content %s, near its cell centre %s" % [tag, str(centre), str(cell)])
		map.free()


func test_terrain_chunks_stay_at_the_origin_and_measure_from_their_cell() -> void:
	var map := _build(MAPS[1])
	var builder := map.get_node("ArtBuilder")
	var chunks := builder.chunks as MapChunks
	var root := map.get_node_or_null("ArtBuilder/Terrain") as Node3D
	assert_true(root != null, "test_300 has terrain")
	if root == null:
		map.free()
		return
	assert_true(root.global_transform.is_equal_approx(Transform3D.IDENTITY), "Terrain at the world origin")
	var checked := 0
	for iz in chunks.per_side:
		for ix in chunks.per_side:
			var mi := root.get_node_or_null("Chunk_%d_%d/Mesh" % [ix, iz]) as MeshInstance3D
			if mi == null:
				assert_true(false, "Chunk_%d_%d/Mesh exists" % [ix, iz])
				continue
			assert_true(mi.global_transform.is_equal_approx(Transform3D.IDENTITY), "Chunk_%d_%d: world-space vertices" % [ix, iz])
			var centre: Vector3 = mi.global_transform * mi.get_aabb().get_center()
			var cell := _cell_centre(chunks, Vector2i(ix, iz))
			assert_true(absf(centre.x - cell.x) < 1e-3 and absf(centre.z - cell.y) < 1e-3, "Chunk_%d_%d: the range is measured from its cell centre (%s vs %s)" % [ix, iz, str(centre), str(cell)])
			checked += 1
	assert_eq(checked, chunks.per_side * chunks.per_side, "every terrain chunk checked")
	map.free()


func test_no_visibility_fade_anywhere() -> void:
	for json_path: String in MAPS:
		var map := _build(json_path)
		var count := 0
		for node in map.find_children("*", "GeometryInstance3D", true, false):
			count += 1
			assert_eq((node as GeometryInstance3D).visibility_range_fade_mode, GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED, "%s %s: no visibility fade (alpha blending on Mobile)" % [_label(json_path), map.get_path_to(node)])
		assert_true(count > 0, _label(json_path) + ": nonvacuous")
		map.free()
