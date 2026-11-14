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
			# Stop 5: near ends at the swap, the far sibling begins there and has no end (never culled).
			var far := root.get_node_or_null("Chunk_%d_%d/Far" % [ix, iz]) as MeshInstance3D
			assert_true(far != null, "Chunk_%d_%d has a far mesh" % [ix, iz])
			if far != null:
				assert_true(mi.visibility_range_begin == 0.0 and mi.visibility_range_end > 0.0 and is_equal_approx(far.visibility_range_begin, mi.visibility_range_end) and far.visibility_range_end == 0.0, "Chunk_%d_%d: near ends where far begins, far never ends" % [ix, iz])
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
	bad["list"]["cover_small"]["range_m"] = -1
	(bad["list"]["paving"] as Dictionary).erase("cast_shadows")
	bad["sight_floor_m"] = 0
	var problems := MapChunks.class_problems(bad)
	for needle in ["unknown class nope", "by_source has no ring", "class cover_small: range_m", "class paving: cast_shadows", "sight_floor_m"]:
		assert_true(" | ".join(problems).contains(needle), "a bad block is reported: " + needle)
	assert_eq(MapChunks.class_of("decor", "arch_1", classes), "decor_solid", "a decor type finds its kind")
	assert_eq(MapChunks.class_of("decor", "box_0", classes), "paving", "an unlisted decor kind takes its source's class")
	assert_eq(MapChunks.class_of("cover", "crate", classes), "cover_small", "small cover by source")
	assert_eq(MapChunks.class_of("cover", "tall_wall", classes), "cover_big", "big cover by type")
	assert_eq(MapChunks.class_of("ring", "wreck_truck", classes), "ring_big", "big ring by type")


## M2P1C stop 4: the big-cover rule, worked out from the cover types' sizes (alesia_cover.json "types", the same
## types both maps and the ring use): a type at least 1.8 m tall is in a *_big class, every other in *_small.
func test_big_cover_classes_follow_the_size_rule() -> void:
	var classes := _classes()
	var types: Dictionary = DataRegistry.new().load_file("res://data/maps/alesia_cover.json")["types"]
	var big := 0
	for type: String in types:
		var tall := LowpolyKit.vec(types[type]["size"]).y >= 1.8 - 1e-6
		big += 1 if tall else 0
		for source: String in ["cover", "ring"]:
			assert_eq(MapChunks.class_of(source, type, classes), source + ("_big" if tall else "_small"), "%s/%s: %s by its height" % [source, type, "big" if tall else "small"])
	assert_true(big > 0 and big < types.size(), "both sides nonvacuous")


func test_every_batch_casts_shadows_by_its_class() -> void:
	var classes := _classes()
	var list: Dictionary = classes["list"]
	for json_path: String in MAPS:
		var label := _label(json_path)
		var map := _build(json_path)
		var casting := 0
		var colliding_off := 0
		for batch in (map.get_node("ArtBuilder/Chunks") as MapChunks).batches():
			var spec: Dictionary = list[String(batch.get_meta(&"class"))]
			var casts := batch.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			assert_eq(casts, bool(spec["cast_shadows"]), "%s %s/%s: shadow from its class" % [label, batch.get_parent().name, batch.name])
			casting += 1 if casts else 0
			colliding_off += 1 if (not casts and bool(batch.get_meta(&"collides"))) else 0
		assert_true(casting > 0 and colliding_off > 0, "%s: some batches cast, some colliding ones do not (%d, %d)" % [label, casting, colliding_off])
		var terrain := map.get_node_or_null("ArtBuilder/Terrain")
		if terrain != null:
			for mi: MeshInstance3D in terrain.find_children("*", "MeshInstance3D", true, false):
				assert_eq(mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, bool(MapChunks.config()["terrain"]["cast_shadows"]), "terrain shadows stay terrain.cast_shadows")
		map.free()


func test_class_shadow_override() -> void:
	var chunks := MapChunks.new()
	chunks.setup(0.0)
	chunks.classes_override = {"sight_floor_m": 250.0, "margin_m": 0.0, "by_source": {"cover": "on", "ring": "off", "structure": "off", "decor": "off"},
			"list": {"on": {"range_m": 0.0, "cast_shadows": true}, "off": {"range_m": 0.0, "cast_shadows": false}}}
	var box := BoxMesh.new()
	chunks.add("cover", "c", box, null, Transform3D.IDENTITY, true)
	chunks.add("structure", "s", box, null, Transform3D.IDENTITY, true)
	chunks.build()
	assert_eq((chunks.get_node("Chunk_0_0/Batch_cover_c") as GeometryInstance3D).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "a casting class casts")
	assert_eq((chunks.get_node("Chunk_0_0/Batch_structure_s") as GeometryInstance3D).cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "a non-casting class wins over the old structure data")
	chunks.free()


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
			"list": {"low": {"range_m": 60.0, "cast_shadows": false}, "never": {"range_m": 0.0, "cast_shadows": false}}}
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	chunks.add("cover", "c", box, null, Transform3D(Basis.IDENTITY, Vector3(-30, 1, -30)), true)
	chunks.add("decor", "paving_0", box, null, Transform3D(Basis.IDENTITY, Vector3(-30, 1, -30)), false)
	chunks.add("ring", "r", box, null, Transform3D(Basis.IDENTITY, Vector3(-30, 1, -30)), true)
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


# --- M2P1C stop 3: chunk_size_m as the lever ---

const EYE_M := 1.7
const SIZES := [50.0, 75.0, 100.0]


func test_visible_at_follows_the_renderer_rule() -> void:
	var map := Node3D.new()
	var builder := Node3D.new()
	builder.name = "ArtBuilder"
	map.add_child(builder)
	(Engine.get_main_loop() as SceneTree).root.add_child(map)  # range_centre reads global transforms
	var chunks := MapChunks.new()
	chunks.name = "Chunks"
	builder.add_child(chunks)
	chunks.setup(0.0)
	chunks.classes_override = {"sight_floor_m": 250.0, "margin_m": 0.0, "by_source": {"cover": "solid", "decor": "early", "ring": "never", "structure": "never"},
			"list": {"solid": {"range_m": 100.0, "cast_shadows": true}, "early": {"range_m": 60.0, "cast_shadows": false}, "never": {"range_m": 0.0, "cast_shadows": false}}}
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	chunks.add("decor", "paving_0", box, null, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)), false)
	chunks.add("cover", "c", box, null, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)), true)
	chunks.add("ring", "r", box, null, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)), true)
	chunks.build()
	var radius := Vector3(2, 2, 2).length() * 0.5
	var near := MapChunks.visible_at(map, Vector3(0, 1, 60.0 + radius - 0.01))
	assert_eq(near["batches"], 3, "all three in range just inside the early end")
	assert_eq([near["colliding"], near["non_colliding"], near["shadow"]], [2, 1, 1], "split by colliders and shadows")
	var mid := MapChunks.visible_at(map, Vector3(0, 1, 60.0 + radius + 0.01))
	assert_eq(mid["per_class"], {"solid": 1, "never": 1}, "the early batch ends at its end, measured from its AABB centre")
	var far := MapChunks.visible_at(map, Vector3(0, 1, 5000.0))
	assert_eq([far["batches"], far["batches_total"], far["per_class"]], [1, 3, {"never": 1}], "far away: only the never-culled batch (floor raised the solid one to 250 m)")
	assert_eq(MapChunks.visible_at(map, Vector3(0, 1, 250.0 + radius - 0.01))["colliding"], 2, "the solid batch is drawn out to the floor")
	# Stop 5: a terrain near/far pair (near end = far begin = 80 m from the near AABB centre; far uses it as
	# custom_aabb) and begin honoured.
	var terrain := Node3D.new()
	terrain.name = "Terrain"
	builder.add_child(terrain)
	var cell := Node3D.new()
	cell.name = "Chunk_0_0"
	terrain.add_child(cell)
	var near_mi := MeshInstance3D.new()
	near_mi.name = "Mesh"
	near_mi.mesh = box
	near_mi.visibility_range_end = 80.0
	cell.add_child(near_mi)
	var far_mi := MeshInstance3D.new()
	far_mi.name = "Far"
	far_mi.mesh = BoxMesh.new()
	far_mi.position = Vector3(30, 0, 0)  # its own AABB elsewhere: the custom AABB decides
	far_mi.custom_aabb = AABB(Vector3(-31, -1, -1), Vector3(2, 2, 2))
	far_mi.visibility_range_begin = 80.0
	cell.add_child(far_mi)
	var in_near := MapChunks.visible_at(map, Vector3(0, 0, 79.0))
	var in_far := MapChunks.visible_at(map, Vector3(0, 0, 81.0))
	assert_eq([in_near["terrain_near"], in_near["terrain_far"], in_near["terrain"], in_near["terrain_total"]], [1, 0, 1, 1], "inside the swap: near only")
	assert_eq([in_far["terrain_near"], in_far["terrain_far"], in_far["terrain"]], [0, 1, 1], "beyond the swap: far only, the chunk still drawn")
	assert_eq(in_near["terrain_tris"], 12, "triangles of the meshes in range")
	map.free()


func _match_count(node: Node, splits: int, out: Vector3i) -> Vector3i:
	# The rules of tests/test_astra_perf.gd _count: x = draws (surfaces x (1 + shadow splits when casting)),
	# y = the shadow part of x, z = triangles.
	if node is GeometryInstance3D and node.is_visible_in_tree() and node.layers != 0:
		var mesh: Mesh
		var instances := 1
		if node is MeshInstance3D:
			mesh = node.mesh
		elif node is MultiMeshInstance3D and node.multimesh != null:
			mesh = node.multimesh.mesh
			instances = node.multimesh.instance_count
		elif node is CPUParticles3D:
			mesh = node.mesh
			instances = node.amount
		if mesh != null:
			var shadow := splits if node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF else 0
			out.x += mesh.get_surface_count() * (1 + shadow)
			out.y += mesh.get_surface_count() * shadow
			out.z += preload("res://tests/test_astra_perf.gd").triangles(mesh) * instances
	for child in node.get_children():
		out = _match_count(child, splits, out)
	return out


func _short(v: Dictionary) -> String:
	return "%d/%d(col=%d,non=%d,shadow=%d) terrain=%d/%d(near=%d,far=%d)" % [v["batches"], v["batches_total"], v["colliding"], v["non_colliding"], v["shadow"], v["terrain"], v["terrain_total"], v["terrain_near"], v["terrain_far"]]


## Report only: chunk sizes 50, 75 and 100 m on both maps, through MapChunks.size_override_m (never the json).
func test_chunk_size_report_only() -> void:
	var perf := preload("res://tests/test_astra_perf.gd").new()
	for size_m: float in SIZES:
		for json_path: String in MAPS:
			MapChunks.size_override_m = size_m
			var label := _label(json_path)
			var map := _build(json_path)
			var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
			assert_eq(chunks.chunk_size_m, size_m, label + ": the override sets the chunk size")
			var proxies := MapChunks.proxies(map)
			var pm: Dictionary = proxies["per_map"]
			var pc: Dictionary = proxies["per_chunk"]
			var per_batch_max := 0
			for batch in chunks.batches():
				per_batch_max = maxi(per_batch_max, batch.multimesh.instance_count)
			var terrain_tris := 0
			var terrain := map.get_node_or_null("ArtBuilder/Terrain")
			if terrain != null:
				for mi: MeshInstance3D in terrain.find_children("*", "MeshInstance3D", true, false):
					terrain_tris = maxi(terrain_tris, preload("res://tests/test_astra_perf.gd").triangles(mi.mesh))
			var centre := MapChunks.visible_at(map, Vector3(0, EYE_M, 0))
			var corner := MapChunks.visible_at(map, Vector3(-chunks.half_m, EYE_M, -chunks.half_m))
			var per_side := chunks.per_side
			map.free()
			var setup: Array = await perf._full_match(json_path)
			var match_scene: MatchRoot = setup[0]
			var counts := _match_count(match_scene, setup[1], Vector3i.ZERO)
			match_scene.free()
			MapChunks.size_override_m = 0.0
			print("CHUNK_SIZE map=%s size_m=%d per_side=%d chunks=%d batches=%d instances=%d per_batch=%.2f max=%d draw=%d shadow=%d tris=%d centre=%s corner=%s per_chunk_max=mm%d,mi%d,mat%d,bodies%d per_map=mm%d,mi%d,mat%d,bodies%d terrain_tris_per_chunk=%d" % [
					label, int(size_m), per_side, pm["chunks"], pm["batches"], pm["batch_instances"], float(pm["batch_instances"]) / maxf(1.0, float(pm["batches"])), per_batch_max,
					counts.x, counts.y, counts.z, _short(centre), _short(corner), pc["multimesh"], pc["mesh_instances"], pc["materials"], pc["bodies"],
					pm["multimesh"], pm["mesh_instances"], pm["materials"], pm["bodies"], terrain_tris])
	MapChunks.size_override_m = 0.0
	failures.append_array(perf.failures)


# --- M2P1C stop 5: near and far terrain ---

static func _tris(mesh: ArrayMesh) -> int:
	return mesh.surface_get_array_index_len(0) / 3 if mesh != null and mesh.get_surface_count() > 0 else 0


## Border vertices of a chunk mesh: Vector2(x, z) -> y for every vertex on the rim of `box` (x, z).
static func _rim(mesh: ArrayMesh, box: AABB) -> Dictionary:
	var out := {}
	for p: Vector3 in mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		if is_equal_approx(p.x, box.position.x) or is_equal_approx(p.x, box.end.x) or is_equal_approx(p.z, box.position.z) or is_equal_approx(p.z, box.end.z):
			out[Vector2(p.x, p.z)] = p.y
	return out


func test_far_terrain_pairs_on_test_300() -> void:
	var cfg: Dictionary = MapChunks.config()["terrain"]
	assert_true(String(cfg["_far_todo"]).contains("OQ-MAP-CULL") and float(cfg["far_swap_m"]) > 0.0 and float(cfg["far_step_m"]) > 0.0, "far terrain data are placeholders")
	var margin_m := float(_classes()["margin_m"])
	var swap_m := float(cfg["far_swap_m"])
	var map := _build(MAPS[1])
	var builder := map.get_node("ArtBuilder")
	var chunks := builder.chunks as MapChunks
	var t: MapTerrain = builder.terrain
	var shape := (map.get_node("Nav/Ground/Shape") as CollisionShape3D).shape as HeightMapShape3D
	var fresh := MapTerrain.from_block(DataRegistry.parse_quiet(MAPS[1])["terrain"])
	assert_true(shape.map_data == fresh.heights and shape.map_width == fresh.samples and shape.map_depth == fresh.samples, "the collider keeps the full height field")
	var lines := PackedStringArray()
	var near_total := 0
	for chunk in map.get_node("ArtBuilder/Terrain").get_children():
		var tag := "test_300 " + String(chunk.name)
		var near := chunk.get_node("Mesh") as MeshInstance3D
		var far := chunk.get_node_or_null("Far") as MeshInstance3D
		assert_true(far != null and chunk.get_child_count() == 2, tag + ": Mesh and Far")
		if far == null:
			continue
		var box := near.get_aabb()
		var end := swap_m + box.size.length() * 0.5 + margin_m
		assert_true(is_equal_approx(near.visibility_range_end, end) and is_equal_approx(near.visibility_range_end_margin, margin_m) and near.visibility_range_begin == 0.0, tag + ": near ends at swap + radius + margin")
		assert_true(is_equal_approx(far.visibility_range_begin, end) and is_equal_approx(far.visibility_range_begin_margin, margin_m) and far.visibility_range_end == 0.0, tag + ": far begins there and never ends")
		assert_true(far.custom_aabb.is_equal_approx(box), tag + ": far measures from the near mesh's AABB centre")
		for mi: MeshInstance3D in [near, far]:
			assert_eq(mi.visibility_range_fade_mode, GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED, tag + ": no fade")
			assert_true(mi.material_override == builder.ground_material, tag + ": the ground material")
		# No crack: the far rim is the near rim, vertex for vertex (same full-resolution samples, same heights).
		var near_rim := _rim(near.mesh, box)
		var far_rim := _rim(far.mesh, box)
		assert_true(near_rim.size() > 0 and near_rim == far_rim, "%s: far border = near border (%d vs %d vertices)" % [tag, near_rim.size(), far_rim.size()])
		# The far surface covers the cell exactly once, every triangle facing up like the near mesh's.
		var arrays := (far.mesh as ArrayMesh).surface_get_arrays(0)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var near_arrays := (near.mesh as ArrayMesh).surface_get_arrays(0)
		var npos: PackedVector3Array = near_arrays[Mesh.ARRAY_VERTEX]
		var nidx: PackedInt32Array = near_arrays[Mesh.ARRAY_INDEX]
		var up := signf((npos[nidx[1]] - npos[nidx[0]]).cross(npos[nidx[2]] - npos[nidx[0]]).y)
		var area := 0.0
		var flipped := 0
		for i in range(0, idx.size(), 3):
			var c := (pos[idx[i + 1]] - pos[idx[i]]).cross(pos[idx[i + 2]] - pos[idx[i]])
			area += absf(c.y) * 0.5
			flipped += 1 if signf(c.y) != up else 0
		assert_true(is_equal_approx(area, box.size.x * box.size.z) and flipped == 0, "%s: far triangles tile the cell once, all up (area %.2f of %.2f, flipped %d)" % [tag, area, box.size.x * box.size.z, flipped])
		var nt := _tris(near.mesh)
		var ft := _tris(far.mesh)
		near_total += nt
		assert_true(ft > 0 and ft < nt, tag + ": far is cheaper")
		lines.append("%s near_tris=%d far_tris=%d" % [chunk.name, nt, ft])
	var centre := MapChunks.visible_at(map, Vector3(0, EYE_M, 0))
	var corner := MapChunks.visible_at(map, Vector3(-chunks.half_m, EYE_M, -chunks.half_m))
	assert_true(int(corner["terrain_far"]) > 0, "the swap happens on test_300 (from the corner)")
	assert_eq(int(corner["terrain"]), chunks.per_side * chunks.per_side, "every chunk drawn from the corner, near or far")
	print("TERRAIN_LOD far_step_m=%s far_swap_m=%s %s" % [cfg["far_step_m"], cfg["far_swap_m"], " ".join(lines)])
	print("TERRAIN_LOD in_range before(all near)=%d centre=%d (near=%d far=%d) corner=%d (near=%d far=%d)" % [near_total,
			centre["terrain_tris"], centre["terrain_near"], centre["terrain_far"], corner["terrain_tris"], corner["terrain_near"], corner["terrain_far"]])
	assert_true(t != null, "test_300 terrain")
	map.free()


func test_far_step_rules() -> void:
	assert_eq(MapTerrain.far_step_problem(5.0, 1.0, 100.0), "", "5 m on a 1 m grid in 100 m chunks")
	assert_eq(MapTerrain.far_step_problem(50.0, 1.0, 100.0), "", "two steps per chunk is enough")
	for bad: Vector3 in [Vector3(1, 1, 100), Vector3(2.5, 1, 100), Vector3(30, 1, 100), Vector3(100, 1, 100), Vector3(0, 1, 100)]:
		assert_true(MapTerrain.far_step_problem(bad.x, bad.y, bad.z) != "", "rejected: step %s, grid %s, chunk %s" % [bad.x, bad.y, bad.z])
	var t := MapTerrain.from_block(DataRegistry.parse_quiet(MAPS[1])["terrain"])
	var side := MapChunks.count_for(t.size_m, 70.0)
	assert_true(t.far_chunk_mesh(Vector2i(0, 0), 70.0, side, 7.0) != null, "a full 70 m cell in 7 m steps")
	assert_true(t.far_chunk_mesh(Vector2i(side - 1, side - 1), 70.0, side, 7.0) == null, "a partial edge cell (20 m) gets no far mesh")


func test_no_terrain_no_far_meshes_on_alesia() -> void:
	var map := _build(MAPS[0])
	assert_true(map.get_node_or_null("ArtBuilder/Terrain") == null, "alesia: no terrain built")
	assert_eq(map.find_children("Far", "", true, false).size(), 0, "alesia: no far meshes")
	map.free()


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
