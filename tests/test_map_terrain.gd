extends "res://tests/test_case.gd"
## M2P1B commit 2: terrain as data (MapTerrain, map json "terrain") and the chunked terrain look.

const ALESIA := "res://data/maps/alesia_section.json"
const MAP := "res://data/maps/test_300.json"
const TMP_DIR := "user://p1b_terrain_tmp/"


func _def() -> Dictionary:
	return DataRegistry.parse_quiet(MAP)


func _terrain() -> MapTerrain:
	return MapTerrain.for_map(_def())


func _hill() -> Dictionary:
	return _def()["terrain"]["height_source"]["hills"][0]


func _build(json_path: String) -> Node3D:
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load(String(DataRegistry.parse_quiet(json_path)["scene"])).instantiate()
	map.get_node("ArtBuilder").set("map_json", json_path)
	tree.root.add_child(map)
	return map


func _pos(t: MapTerrain, ix: int, iz: int) -> Vector2:
	return Vector2(-t.size_m * 0.5 + ix * t.resolution_m, -t.size_m * 0.5 + iz * t.resolution_m)


func test_centre_is_flat_and_boundary_is_zero() -> void:
	var t := _terrain()
	assert_true(t != null, "test_300 has a terrain")
	if t == null:
		return
	assert_eq(t.samples, 301, "301 samples per side")
	assert_eq(t.heights.size(), 301 * 301, "one height per sample")
	assert_eq(t.height_at(0.0, 0.0), 0.0, "h(0, 0) is exactly 0")
	var worst := 0.0
	var edge_worst := 0.0
	for iz in t.samples:
		for ix in t.samples:
			var p := _pos(t, ix, iz)
			if p.length() <= 80.0:
				worst = maxf(worst, absf(t.sample(ix, iz)))
			if ix == 0 or iz == 0 or ix == t.samples - 1 or iz == t.samples - 1:
				edge_worst = maxf(edge_worst, absf(t.sample(ix, iz)))
	print("TERRAIN_CENTRE max_abs_m=", worst)
	assert_true(worst <= 0.05, "|h| <= 0.05 m within 80 m (got %f)" % worst)
	assert_eq(edge_worst, 0.0, "h = 0 on the ground's boundary")


func test_hill_height_and_place() -> void:
	var t := _terrain()
	var hill := _hill()
	var centre := Vector2(float(hill["centre"][0]), float(hill["centre"][1]))
	var peak := -INF
	var peak_at := Vector2.ZERO
	var nearest_raised := INF
	for iz in t.samples:
		for ix in t.samples:
			var h := t.sample(ix, iz)
			var p := _pos(t, ix, iz)
			if h > peak:
				peak = h
				peak_at = p
			if h > 1.0:
				nearest_raised = minf(nearest_raised, p.length())
	assert_true(peak >= 12.0 and peak <= 15.0, "hill peak 12-15 m (got %f)" % peak)
	assert_true(peak_at.distance_to(centre) <= 5.0, "peak near the hill centre (at %s)" % str(peak_at))
	assert_true(nearest_raised > 80.0, "every raised sample is more than 80 m out (nearest %f)" % nearest_raised)


## Footprint: quads whose centre lies within max(radius_m, outer_radius_m) of the hill centre (the hill adds
## nothing outside that disc). Each quad is measured at both triangle centroids; a point is on the gentle half
## when (point - centre) . (origin - centre) >= 0.
func test_hill_slopes() -> void:
	var t := _terrain()
	var hill := _hill()
	var c := Vector2(float(hill["centre"][0]), float(hill["centre"][1]))
	var reach := maxf(float(hill["radius_m"]), float(hill.get("outer_radius_m", hill["radius_m"])))
	var gentle := 0.0
	var outer := 0.0
	var res := t.resolution_m
	for iz in t.samples - 1:
		for ix in t.samples - 1:
			var corner := _pos(t, ix, iz)
			if (corner + Vector2(0.5, 0.5) * res).distance_to(c) >= reach:
				continue
			for f: Vector2 in [Vector2(1.0, 1.0) / 3.0, Vector2(2.0, 2.0) / 3.0]:
				var p := corner + f * res
				var slope := t.slope_deg_at(p.x, p.y)
				if (p - c).dot(-c) >= 0.0:
					gentle = maxf(gentle, slope)
				else:
					outer = maxf(outer, slope)
	var peak := t.height_at(c.x, c.y)
	print("TERRAIN_SLOPE gentle_max_deg=", gentle, " outer_max_deg=", outer, " peak_m=", peak)
	assert_true(gentle <= 25.0, "gentle half max slope <= 25 deg (got %f)" % gentle)
	assert_true(outer > gentle, "outer half steeper than the gentle half (%f vs %f)" % [outer, gentle])
	assert_true(outer < 40.0, "outer half max slope < 40 deg (got %f)" % outer)


func test_height_at_follows_the_triangles() -> void:
	var t := _terrain()
	for ixz: Vector2i in [Vector2i(220, 220), Vector2i(205, 231), Vector2i(0, 0), Vector2i(300, 150), Vector2i(150, 150)]:
		var p := _pos(t, ixz.x, ixz.y)
		assert_true(absf(t.height_at(p.x, p.y) - t.sample(ixz.x, ixz.y)) < 1e-5, "height_at equals the sample at node %s" % str(ixz))
	assert_eq(MapTerrain.SPLIT_ANTI_DIAGONAL, true, "starts on the (ix+1, iz)-(ix, iz+1) diagonal")
	# Off-node points on the hill's slope, one in each triangle of their quad: the plane through the three corners.
	for at: Vector2 in [Vector2(70.2, 80.3), Vector2(70.8, 80.7), Vector2(105.45, 61.1), Vector2(105.9, 61.6)]:
		var ix := floori((at.x + 150.0) / t.resolution_m)
		var iz := floori((at.y + 150.0) / t.resolution_m)
		var fx := (at.x + 150.0) / t.resolution_m - ix
		var fz := (at.y + 150.0) / t.resolution_m - iz
		var corner := func(dx: int, dz: int) -> Vector3:
			var q := _pos(t, ix + dx, iz + dz)
			return Vector3(q.x, t.sample(ix + dx, iz + dz), q.y)
		var tri: Array = [corner.call(0, 0), corner.call(1, 0), corner.call(0, 1)] if fx + fz <= 1.0 else [corner.call(1, 0), corner.call(1, 1), corner.call(0, 1)]
		var plane := Plane(tri[0], tri[1], tri[2])
		var expected := (plane.d - plane.normal.x * at.x - plane.normal.z * at.y) / plane.normal.y
		assert_true(absf(t.height_at(at.x, at.y) - expected) < 1e-4, "height_at %s matches the triangle (%f vs %f)" % [str(at), t.height_at(at.x, at.y), expected])
		assert_true(t.normal_at(at.x, at.y).distance_to(plane.normal * signf(plane.normal.y)) < 1e-4, "normal_at %s is the triangle's" % str(at))
	assert_true(t.slope_deg_at(70.2, 80.3) > 1.0, "the probe points are on the slope")
	assert_eq(t.height_at(-500.0, 900.0), t.height_at(-150.0, 150.0), "height_at clamps to the ground square")


func test_heights_are_deterministic() -> void:
	var block: Dictionary = _def()["terrain"]
	var a := MapTerrain.from_block(block)
	var b := MapTerrain.from_block(block)
	assert_true(a != null and b != null, "both build")
	assert_true(a.heights == b.heights, "two builds give identical heights")
	assert_true(a.heights == _terrain().heights, "the cached terrain has the same heights")
	var other := block.duplicate(true)
	other["height_source"]["seed"] = 12345
	assert_true(MapTerrain.from_block(other).heights != a.heights, "a different seed changes the heights")


func test_heights_file_round_trip() -> void:
	var t := _terrain()
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	for file: String in ["heights.json", "heights.res"]:
		var path := TMP_DIR + file
		assert_eq(MapTerrain.save_heights(t, path), OK, "saved %s" % file)
		var block: Dictionary = _def()["terrain"].duplicate(true)
		block["height_source"] = {"type": "file", "path": path}
		assert_eq(DataRegistry.validate_terrain(block).size(), 0, "file block is clean: " + ", ".join(DataRegistry.validate_terrain(block)))
		var loaded := MapTerrain.from_block(block)
		assert_true(loaded != null and loaded.heights == t.heights, "%s round-trips the heights" % file)
		var wrong := block.duplicate(true)
		wrong["size_m"] = 200
		assert_true(MapTerrain.from_block(wrong) == null, "%s with another size gives no terrain" % file)
	for file in DirAccess.get_files_at(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR + file)
	DirAccess.remove_absolute(TMP_DIR)


func test_generation_and_mesh_timing() -> void:
	var block: Dictionary = _def()["terrain"]
	var start := Time.get_ticks_usec()
	var t := MapTerrain.from_block(block)
	var gen_ms := (Time.get_ticks_usec() - start) / 1000.0
	var chunk_m := float(MapChunks.config()["chunk_size_m"])
	var side := MapChunks.count_for(t.size_m, chunk_m)
	start = Time.get_ticks_usec()
	var verts := 0
	var tris := 0
	for iz in side:
		for ix in side:
			var arrays := t.chunk_mesh(Vector2i(ix, iz), chunk_m, side).surface_get_arrays(0)
			verts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			tris += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	var mesh_ms := (Time.get_ticks_usec() - start) / 1000.0
	print("TERRAIN_TIME gen_ms=", gen_ms, " chunk_meshes_ms=", mesh_ms, " chunks=", side * side, " vertices=", verts, " triangles=", tris, " per_chunk_vertices=", verts / (side * side), " per_chunk_triangles=", tris / (side * side))
	assert_eq(tris, 2 * 300 * 300, "two triangles per grid quad")


func test_look_on_test_300() -> void:
	var map := _build(MAP)
	var builder := map.get_node("ArtBuilder")
	var t: MapTerrain = builder.terrain
	var chunks := builder.chunks as MapChunks
	var root := map.get_node_or_null("ArtBuilder/Terrain")
	assert_true(t != null and root != null, "test_300 builds a Terrain node")
	if t == null or root == null:
		map.free()
		return
	var side := chunks.per_side
	assert_eq(root.get_child_count(), side * side, "one terrain chunk per grid cell")
	var material: ShaderMaterial = builder.ground_material
	assert_true(material != null, "the builder exposes the ground material")
	var half := t.size_m * 0.5
	var cs := chunks.chunk_size_m
	var tris := 0
	var edge := {}  # Vector2 -> [position, normal] of a vertex seen in an earlier chunk
	var shared := 0
	for iz in side:
		for ix in side:
			var chunk := root.get_node_or_null("Chunk_%d_%d" % [ix, iz]) as Node3D
			var mi := chunk.get_node_or_null("Mesh") as MeshInstance3D if chunk != null else null
			assert_true(mi != null, "Chunk_%d_%d/Mesh exists" % [ix, iz])
			if mi == null:
				continue
			assert_true(chunk.transform == Transform3D.IDENTITY and mi.transform == Transform3D.IDENTITY, "identity transforms")
			assert_true(mi.material_override == material, "chunk %d,%d has the ground material" % [ix, iz])
			assert_eq(mi.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "terrain casts no shadow by default")
			var box := mi.get_aabb()
			var lo := Vector2(-half + ix * cs, -half + iz * cs)
			assert_true(box.position.x >= lo.x - 1e-3 and box.end.x <= lo.x + cs + 1e-3 and box.position.z >= lo.y - 1e-3 and box.end.z <= lo.y + cs + 1e-3, "chunk %d,%d AABB inside its cell" % [ix, iz])
			var arrays := mi.mesh.surface_get_arrays(0)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			tris += idx.size() / 3
			for i in pos.size():
				var key := Vector2(pos[i].x, pos[i].z)
				if edge.has(key):
					shared += 1
					assert_true(edge[key][0] == pos[i] and edge[key][1] == nor[i], "shared edge vertex %s matches" % str(key))
				elif is_equal_approx(fposmod(pos[i].x + half, cs), 0.0) or is_equal_approx(fposmod(pos[i].z + half, cs), 0.0):
					edge[key] = [pos[i], nor[i]]
			if ix == 0 and iz == 0:
				_check_winding(pos, idx)
	assert_eq(tris, 2 * (t.samples - 1) * (t.samples - 1), "triangle total is 2 * cells^2")
	assert_true(shared > 0, "neighbouring chunks share edge vertices")
	for chunk in chunks.get_children():
		assert_true(chunk.has_meta(&"index"), "ArtBuilder/Chunks holds only its own chunk nodes (%s)" % chunk.name)
		for node in chunk.get_children():
			assert_true(node is MultiMeshInstance3D, "ArtBuilder/Chunks holds only batches (%s)" % node.name)
	var flat := map.get_node("Nav/Ground/Mesh") as MeshInstance3D
	assert_true(not flat.visible and flat.material_override == material, "the old box ground is hidden but keeps the material")
	map.free()


## Every triangle's front face (Godot: Plane(v0, v1, v2), clockwise seen from the front) points up; the
## convention is checked against SurfaceTool.generate_normals on the first triangle.
func _check_winding(pos: PackedVector3Array, idx: PackedInt32Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 3:
		st.add_vertex(pos[idx[k]])
	st.generate_normals()
	var generated: PackedVector3Array = st.commit_to_arrays()[Mesh.ARRAY_NORMAL]
	assert_true(generated[0].y > 0.0, "SurfaceTool reads the first triangle as facing up")
	var down := 0
	for k in range(0, idx.size(), 3):
		if Plane(pos[idx[k]], pos[idx[k + 1]], pos[idx[k + 2]]).normal.y <= 0.0:
			down += 1
	assert_eq(down, 0, "every triangle's front face points up")


func test_alesia_stays_flat() -> void:
	var map := _build(ALESIA)
	var builder := map.get_node("ArtBuilder")
	assert_true(builder.terrain == null, "alesia has no terrain")
	assert_true(map.get_node_or_null("ArtBuilder/Terrain") == null, "alesia has no Terrain node")
	var ground := map.get_node("Nav/Ground/Mesh") as MeshInstance3D
	assert_true(builder.ground_material != null and ground.material_override == builder.ground_material, "alesia's ground mesh has the builder's material")
	assert_true(ground.visible, "alesia's ground mesh stays visible")
	assert_true(MapTerrain.for_map(DataRegistry.parse_quiet(ALESIA)) == null, "no terrain block, no terrain")
	map.free()


func test_generator_size_matches_terrain() -> void:
	var def := _def()
	assert_true(not def.has("ground_size_m"), "test_300 has no top-level ground_size_m")
	assert_eq(float(def["generator"]["ground_size_m"]), float(def["terrain"]["size_m"]), "generator.ground_size_m equals terrain.size_m")


func test_validator_terrain_rules() -> void:
	var def := _def()
	assert_eq(DataRegistry.validate_map_def(def).size(), 0, "test_300 is clean: " + ", ".join(DataRegistry.validate_map_def(def)))
	var cases := {
		"size 0": func(d: Dictionary) -> void: d["terrain"]["size_m"] = 0,
		"resolution not dividing": func(d: Dictionary) -> void: d["terrain"]["resolution_m"] = 7,
		"one cell": func(d: Dictionary) -> void: d["terrain"]["resolution_m"] = 300,
		"unknown source": func(d: Dictionary) -> void: d["terrain"]["height_source"]["type"] = "image",
		"unknown falloff": func(d: Dictionary) -> void: d["terrain"]["height_source"]["hills"][0]["falloff"] = "cliff",
		"hill radius 0": func(d: Dictionary) -> void: d["terrain"]["height_source"]["hills"][0]["radius_m"] = 0,
		"outer radius 0": func(d: Dictionary) -> void: d["terrain"]["height_source"]["hills"][0]["outer_radius_m"] = 0,
		"bad centre": func(d: Dictionary) -> void: d["terrain"]["height_source"]["hills"][0]["centre"] = [1],
		"missing heights file": func(d: Dictionary) -> void: d["terrain"]["height_source"] = {"type": "file", "path": "res://data/maps/no_such_heights.json"},
		"image heights file": func(d: Dictionary) -> void: d["terrain"]["height_source"] = {"type": "file", "path": "res://icon.png"},
		"ground size disagrees": func(d: Dictionary) -> void: d["ground_size_m"] = 200,
		"slope limit 0": func(d: Dictionary) -> void: d["terrain"]["max_piece_slope_deg"] = 0,
		"no seed": func(d: Dictionary) -> void: d["terrain"]["height_source"].erase("seed"),
		"wavelength 0": func(d: Dictionary) -> void: d["terrain"]["height_source"]["noise"]["wavelength_m"] = 0,
		"negative blend": func(d: Dictionary) -> void: d["terrain"]["height_source"]["edge_blend_m"] = -1,
		"not a dictionary": func(d: Dictionary) -> void: d["terrain"] = "hilly",
	}
	for label: String in cases:
		var copy := def.duplicate(true)
		(cases[label] as Callable).call(copy)
		assert_true(DataRegistry.validate_map_def(copy).size() > 0, "%s is reported" % label)
		assert_true(MapTerrain.from_block(copy["terrain"], copy) == null, "%s gives no terrain" % label)
