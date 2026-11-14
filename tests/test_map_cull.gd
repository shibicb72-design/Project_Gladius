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
			assert_true(mi.visibility_range_begin == 0.0 and mi.visibility_range_end == 0.0, "Chunk_%d_%d: terrain is never culled (stop 2)" % [ix, iz])
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


# --- M2P1C stop 2: per-class visibility ranges and the sight floor ---

func _classes() -> Dictionary:
	return MapChunks.config()["classes"]


## Half the diagonal of the world AABB of a batch's instances, worked out here from the meta and the mesh.
func _radius(batch: MultiMeshInstance3D) -> float:
	var local := batch.multimesh.mesh.get_aabb()
	var box := AABB()
	var first := true
	for xform: Transform3D in batch.get_meta(&"transforms"):
		var placed: AABB = batch.global_transform * (xform * local)
		box = placed if first else box.merge(placed)
		first = false
	return box.size.length() * 0.5


func test_class_data_is_a_placeholder_and_valid() -> void:
	var classes := _classes()
	assert_true(bool(classes["_placeholder"]) and String(classes["_todo"]).contains("OQ-MAP-CULL"), "classes are placeholders with their open question")
	assert_eq(MapChunks.class_problems(classes), PackedStringArray(), "the shipped classes block is valid")
	assert_true(float(classes["sight_floor_m"]) > 0.0 and float(classes["margin_m"]) >= 0.0, "floor and margin from data")
	var bad := classes.duplicate(true)
	bad["by_type"]["decor/arch"] = "nope"
	(bad["by_source"] as Dictionary).erase("ring")
	bad["list"]["cover"]["range_m"] = -1
	bad["sight_floor_m"] = 0
	var problems := MapChunks.class_problems(bad)
	for needle in ["unknown class nope", "by_source has no ring", "class cover: range_m", "sight_floor_m"]:
		assert_true(" | ".join(problems).contains(needle), "a bad block is reported: " + needle)
	assert_eq(MapChunks.class_of("decor", "arch_1", classes), "decor_solid", "a decor type finds its kind")
	assert_eq(MapChunks.class_of("decor", "box_0", classes), "paving", "an unlisted decor kind takes its source's class")
	assert_eq(MapChunks.class_of("cover", "crate", classes), "cover", "cover by source")


func test_every_batch_follows_its_class_rule() -> void:
	var classes := _classes()
	var list: Dictionary = classes["list"]
	var floor_m := float(classes["sight_floor_m"])
	var margin_m := float(classes["margin_m"])
	for json_path: String in MAPS:
		var label := _label(json_path)
		var map := _build(json_path)
		var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
		var seen := {}
		for batch in chunks.batches():
			var tag := "%s %s/%s" % [label, batch.get_parent().name, batch.name]
			var cls := String(batch.get_meta(&"class", ""))
			assert_eq(cls, MapChunks.class_of(String(batch.get_meta(&"source")), String(batch.get_meta(&"type")), classes), tag + ": class from the data")
			assert_true(list.has(cls), tag + ": a known class (" + cls + ")")
			seen[cls] = true
			var want := MapChunks.effective_range(float(list.get(cls, {}).get("range_m", 0.0)), bool(batch.get_meta(&"collides")), floor_m)
			assert_true(is_equal_approx(float(batch.get_meta(&"range_m")), want), tag + ": range_m is the class range (floor applied)")
			var radius := _radius(batch)
			assert_true(is_equal_approx(float(batch.get_meta(&"radius_m")), radius), tag + ": radius is half the world AABB diagonal")
			var end := 0.0 if want <= 0.0 else want + radius + margin_m
			assert_true(is_equal_approx(batch.visibility_range_end, end), "%s: end %.3f = range + radius + margin %.3f" % [tag, batch.visibility_range_end, end])
			assert_true(is_equal_approx(batch.visibility_range_end_margin, margin_m if want > 0.0 else 0.0), tag + ": end margin from data")
			assert_eq(batch.visibility_range_begin, 0.0, tag + ": no begin range")
			assert_eq(batch.visibility_range_fade_mode, GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED, tag + ": fade disabled")
		print("MAP_CULL map=", label, " classes=", seen.keys())
		map.free()


## Every body under Nav that a batch draws (not Ground, not a scene wall with its own Mesh), matched to the
## batches of its chunk that hold an instance at its origin: the real colliders, not the builder's meta.
func test_sight_floor_holds_for_every_batch_with_real_colliders() -> void:
	var floor_m := float(_classes()["sight_floor_m"])
	var margin_m := float(_classes()["margin_m"])
	for json_path: String in MAPS:
		var label := _label(json_path)
		var map := _build(json_path)
		var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
		var backed := {}  # batch -> true
		var bodies := 0
		for body in map.get_node("Nav").get_children():
			if not body is StaticBody3D or body.name == &"Ground" or body.get_node_or_null("Mesh") != null:
				continue
			bodies += 1
			var index := chunks.index_of(body.global_position)
			var chunk := chunks.get_node_or_null("Chunk_%d_%d" % [index.x, index.y])
			var found := false
			if chunk != null:
				for batch: MultiMeshInstance3D in chunk.get_children():
					for xform: Transform3D in batch.get_meta(&"transforms"):
						if xform.origin.is_equal_approx(body.global_position):
							backed[batch] = true
							found = true
			assert_true(found, "%s %s: its look is in a batch of its chunk" % [label, body.name])
		assert_true(bodies > 0 and not backed.is_empty(), label + ": nonvacuous")
		for batch: MultiMeshInstance3D in backed:
			var tag := "%s %s/%s" % [label, batch.get_parent().name, batch.name]
			var end := batch.visibility_range_end
			var meaning := end - float(batch.get_meta(&"radius_m")) - margin_m
			assert_true(end == 0.0 or meaning >= floor_m - 1e-3, "%s: drawn to at least the sight floor (%.1f m)" % [tag, meaning])
			assert_true(bool(batch.get_meta(&"collides")), tag + ": a body-backed batch is marked collides")
		for batch in chunks.batches():
			if bool(batch.get_meta(&"collides")):
				assert_true(backed.has(batch), "%s %s/%s: marked collides and has a real body" % [label, batch.get_parent().name, batch.name])
		map.free()


func test_a_collidable_class_below_the_floor_is_raised() -> void:
	assert_eq(MapChunks.effective_range(100.0, true, 250.0), 250.0, "colliding: raised to the floor")
	assert_eq(MapChunks.effective_range(100.0, false, 250.0), 100.0, "not colliding: may end early")
	assert_eq(MapChunks.effective_range(0.0, true, 250.0), 0.0, "0 stays never culled")
	assert_eq(MapChunks.effective_range(400.0, true, 250.0), 400.0, "above the floor: unchanged")
	var chunks := MapChunks.new()
	chunks.setup(100.0)
	chunks.classes_override = {"sight_floor_m": 250.0, "margin_m": 4.0, "by_source": {"cover": "low", "ring": "never", "structure": "low", "decor": "low"},
			"list": {"low": {"range_m": 60.0}, "never": {"range_m": 0.0}}}
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	var off := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	chunks.add("cover", "c", box, null, off, Transform3D(Basis.IDENTITY, Vector3(-30, 1, -30)), true)
	chunks.add("decor", "paving_0", box, null, off, Transform3D(Basis.IDENTITY, Vector3(-30, 1, -30)), false)
	chunks.add("ring", "r", box, null, off, Transform3D(Basis.IDENTITY, Vector3(-30, 1, -30)), true)
	chunks.build()
	var radius := Vector3(2, 2, 2).length() * 0.5
	var cover := chunks.get_node("Chunk_0_0/Batch_cover_c") as MultiMeshInstance3D
	var decor := chunks.get_node("Chunk_0_0/Batch_decor_paving_0") as MultiMeshInstance3D
	var ring := chunks.get_node("Chunk_0_0/Batch_ring_r") as MultiMeshInstance3D
	assert_eq(float(cover.get_meta(&"range_m")), 250.0, "a colliding batch of a 60 m class is raised to the floor")
	assert_true(is_equal_approx(cover.visibility_range_end, 250.0 + radius + 4.0), "its end is floor + radius + margin")
	assert_eq(float(decor.get_meta(&"range_m")), 60.0, "a batch without colliders keeps its early end")
	assert_true(is_equal_approx(decor.visibility_range_end, 60.0 + radius + 4.0), "early end + radius + margin")
	assert_eq(ring.visibility_range_end, 0.0, "range 0: never culled")
	chunks.free()


func test_early_classes_end_before_the_floor() -> void:
	var floor_m := float(_classes()["sight_floor_m"])
	for json_path: String in MAPS:
		var map := _build(json_path)
		var early := 0
		for batch in (map.get_node("ArtBuilder/Chunks") as MapChunks).batches():
			var range_m := float(batch.get_meta(&"range_m"))
			if range_m > 0.0 and range_m < floor_m:
				assert_true(not bool(batch.get_meta(&"collides")), "%s %s: only batches without colliders end early" % [_label(json_path), batch.name])
				early += 1
		assert_true(early > 0, _label(json_path) + ": some looks without colliders end before the sight floor")
		map.free()
