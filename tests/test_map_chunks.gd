extends "res://tests/test_case.gd"
## M2P1A: the map's looks (inner cover, ring cover, world kit structures, rim decor) drawn as one batch per chunk,
## source and type (MapChunks); bodies, colliders and the cover contract stay per piece.

const SCENE_WALLS := ["CitadelWallN", "CitadelWallS", "CitadelWallE", "CitadelWallW", "InnerWall", "CampBlockA", "CampBlockB", "CampBlockC"]


func _map() -> Node3D:
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	tree.root.add_child(map)
	return map


func _chunks(map: Node) -> MapChunks:
	return map.get_node("ArtBuilder/Chunks") as MapChunks


## The pieces the builder placed, per source: [entry, ...] from the same files the builder reads.
func _pieces(map: Node) -> Dictionary:
	var reg := DataRegistry.new()
	var map_def := reg.load_file(String(map.get_node("ArtBuilder").get("map_json")))
	var placed := reg.load_file(String(map_def.get("cover_data", "res://data/maps/alesia_cover.json")))
	return {"cover": placed["pieces"], "ring": placed.get("ring_pieces", []), "structure": WorldKit.pieces_for(map_def)}


## The decor batch types the name rule gives a decor list, worked out here from the data alone:
## {"types": {id: "<kind>_<n>"}, "counts": {type: entries}}, n = the size's index among its kind's distinct
## sizes, first seen first. tests/test_map_300.gd uses it too.
static func decor_expected(decor: Array) -> Dictionary:
	var sizes := {}  # kind -> [size, ...] in first-seen order
	var types := {}
	var counts := {}
	for entry: Dictionary in decor:
		var kind := String(entry["kind"])
		if not sizes.has(kind):
			sizes[kind] = []
		var seen: Array = sizes[kind]
		var size := LowpolyKit.vec(entry["size"])
		var n := seen.find(size)
		if n < 0:
			n = seen.size()
			seen.append(size)
		var type := "%s_%d" % [kind, n]
		types[String(entry["id"])] = type
		counts[type] = int(counts.get(type, 0)) + 1
	return {"types": types, "counts": counts}


## Checks the decor batches of a built map against its decor list: totals per kind and size, the builder's
## decor_types, and one instance per entry at the entry's transform.
func check_decor_totals(map: Node, decor: Array, label: String) -> void:
	var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
	var builder := map.get_node("ArtBuilder")
	var expected := decor_expected(decor)
	var counts: Dictionary = expected["counts"]
	assert_true(not counts.is_empty(), label + ": nonvacuous decor")
	var total := 0
	for type: String in counts:
		assert_eq(chunks.instance_total("decor", type), int(counts[type]), label + " decor " + type + ": one instance per entry of that kind and size")
		total += int(counts[type])
	assert_eq(chunks.instance_total("decor"), total, label + ": no stray decor type")
	assert_eq(total, decor.size(), label + ": one decor instance per entry")
	assert_eq(builder.decor_types, expected["types"], label + ": decor_types follows the name rule")
	for entry: Dictionary in decor:
		var xform := Transform3D(Basis.from_euler(Vector3(0.0, deg_to_rad(float(entry["yaw"])), 0.0)), LowpolyKit.vec(entry["at"]))
		assert_true(chunks.batch_of("decor", String(expected["types"][entry["id"]]), xform) != null, label + " " + String(entry["id"]) + ": drawn in its chunk's decor batch")


func test_chunk_index_follows_the_formula() -> void:
	assert_eq(MapChunks.count_for(160.0, 50.0), 4, "160 m in 50 m chunks")
	assert_eq(MapChunks.count_for(300.0, 50.0), 6, "300 m in 50 m chunks")
	assert_eq(MapChunks.count_for(1000.0, 50.0), 20, "1 km in 50 m chunks")
	assert_eq(MapChunks.count_for(100.0, 50.0), 2, "an exact fit adds no chunk")
	assert_eq(MapChunks.count_for(0.0, 50.0), 1, "no ground: one chunk")
	var half := 80.0
	var n := MapChunks.count_for(160.0, 50.0)
	assert_eq(MapChunks.index_for(0.0, 0.0, half, 50.0, n), Vector2i(1, 1), "centre")
	assert_eq(MapChunks.index_for(-80.0, -80.0, half, 50.0, n), Vector2i(0, 0), "corner")
	assert_eq(MapChunks.index_for(-30.0, 19.9, half, 50.0, n), Vector2i(1, 1), "on the lower edge and below the upper edge")
	assert_eq(MapChunks.index_for(20.0, -30.01, half, 50.0, n), Vector2i(2, 0), "just past an edge")
	assert_eq(MapChunks.index_for(79.9, 79.9, half, 50.0, n), Vector2i(3, 3), "far corner")
	assert_eq(MapChunks.index_for(80.0, 80.0, half, 50.0, n), Vector2i(3, 3), "the ground's edge stays in the last chunk")
	for p: Vector2 in [Vector2(-500.0, 0.0), Vector2(500.0, -500.0), Vector2(200.0, 200.0), Vector2(-80.01, 80.01)]:
		var index := MapChunks.index_for(p.x, p.y, half, 50.0, n)
		assert_true(index.x >= 0 and index.x <= 3 and index.y >= 0 and index.y <= 3, "outside the ground clamps into the grid: " + str(p))


func test_chunk_nodes_and_batches_on_alesia() -> void:
	var cfg := MapChunks.config()
	assert_true(float(cfg["chunk_size_m"]) > 0.0, "chunk size from data")
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-MAP-CHUNK"), "the chunk size is a placeholder with its open question")
	var map := _map()
	var chunks := _chunks(map)
	var ground_size := (map.get_node("Nav/Ground/Mesh") as MeshInstance3D).get_aabb().size.x
	assert_eq(chunks.chunk_size_m, float(cfg["chunk_size_m"]), "grid uses the data's chunk size")
	assert_eq(chunks.per_side, MapChunks.count_for(ground_size, chunks.chunk_size_m), "chunks per side from the ground size")
	assert_eq(chunks.transform, Transform3D.IDENTITY, "Chunks at the origin")
	assert_true(chunks.get_child_count() > 0, "nonvacuous")
	var batch_count := 0
	var instances := 0
	for chunk: Node3D in chunks.get_children():
		var index: Vector2i = chunk.get_meta(&"index")
		assert_eq(String(chunk.name), "Chunk_%d_%d" % [index.x, index.y], "chunk named from its index")
		assert_eq(chunk.transform, Transform3D.IDENTITY, String(chunk.name) + " at the origin")
		assert_true(chunk.get_child_count() > 0, String(chunk.name) + " holds something")
		for batch: MultiMeshInstance3D in chunk.get_children():
			var source := String(batch.get_meta(&"source"))
			var type := String(batch.get_meta(&"type"))
			assert_eq(String(batch.name), "Batch_%s_%s" % [source, type], "batch named from source and type")
			var placed: Array = batch.get_meta(&"transforms")
			assert_true(batch.multimesh.instance_count > 0 and placed.size() == batch.multimesh.instance_count, String(batch.name) + ": one transform per instance")
			for xform: Transform3D in placed:
				assert_eq(MapChunks.index_for(xform.origin.x, xform.origin.z, chunks.half_m, chunks.chunk_size_m, chunks.per_side), index, String(batch.name) + ": instance in its chunk")
			batch_count += 1
			instances += batch.multimesh.instance_count
	print("MAP_CHUNKS map=alesia_section chunk_size_m=", chunks.chunk_size_m, " per_side=", chunks.per_side, " chunks=", chunks.get_child_count(), " batches=", batch_count, " instances=", instances)
	map.free()


func test_batch_totals_match_the_pieces_and_every_body_is_drawn() -> void:
	var map := _map()
	var chunks := _chunks(map)
	var builder := map.get_node("ArtBuilder")
	var pieces := _pieces(map)
	var bodies := {"cover": builder.cover_bodies, "ring": builder.ring_bodies, "structure": builder.structure_bodies}
	for source: String in pieces:
		var per_type := {}
		for entry: Dictionary in pieces[source]:
			per_type[entry["type"]] = int(per_type.get(entry["type"], 0)) + 1
		assert_true(not per_type.is_empty(), source + ": nonvacuous")
		var total := 0
		for type: String in per_type:
			assert_eq(chunks.instance_total(source, type), int(per_type[type]), source + " " + type + ": one instance per piece")
			total += int(per_type[type])
		assert_eq(chunks.instance_total(source), total, source + ": no stray type")
		var list: Array = bodies[source]
		assert_eq(list.size(), (pieces[source] as Array).size(), source + ": one body per piece")
		for i in list.size():
			var body: StaticBody3D = list[i]
			var type := String(pieces[source][i]["type"])
			var index := chunks.index_of(body.position)
			var batch := chunks.get_node_or_null("Chunk_%d_%d/Batch_%s_%s" % [index.x, index.y, source, type]) as MultiMeshInstance3D
			var found := false
			if batch != null:
				for xform: Transform3D in batch.get_meta(&"transforms"):
					found = found or xform.is_equal_approx(body.transform)
			assert_true(found, String(body.name) + ": drawn in its chunk's " + source + " batch")
	map.free()


func test_cover_contract_and_colliders_stay_per_piece() -> void:
	var map := _map()
	var builder := map.get_node("ArtBuilder")
	var walls := 0
	for node in map.get_tree().get_nodes_in_group(&"cover_wall"):
		if not map.is_ancestor_of(node):
			continue
		walls += 1
		assert_true(node is StaticBody3D, String(node.name) + ": a body")
		var shape := node.get_node_or_null("Shape") as CollisionShape3D
		assert_true(shape != null and shape.shape is BoxShape3D, String(node.name) + ": a Shape holding a box")
		assert_true((node as CollisionObject3D).get_collision_layer_value(1), String(node.name) + ": on collision layer 1")
	assert_true(walls > 0, "nonvacuous")
	for list: Array in [builder.cover_bodies, builder.ring_bodies]:
		for body: StaticBody3D in list:
			assert_eq(body.get_child_count(), 1, String(body.name) + ": its Shape only")
	map.free()


func test_shadows_and_materials_per_source() -> void:
	var map := _map()
	var chunks := _chunks(map)
	var structure_shadows := bool(WorldKit.config()["batches"]["cast_shadows"])
	var cover_types: Dictionary = DataRegistry.new().load_file("res://data/maps/alesia_cover.json")["types"]
	for source: String in ["cover", "ring", "structure", "decor"]:
		assert_true(not chunks.batches(source).is_empty(), source + ": batches present")
	for batch: MultiMeshInstance3D in chunks.batches():
		var source := String(batch.get_meta(&"source"))
		var type := String(batch.get_meta(&"type"))
		var casts := batch.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if source == "decor":
			assert_true(not casts, String(batch.name) + ": decor casts no shadow")
			assert_true(batch.material_override == null and batch.multimesh.mesh is ArrayMesh, String(batch.name) + ": kit mesh with its own material")
		elif source == "structure":
			assert_eq(casts, structure_shadows, String(batch.name) + ": shadows from the world kit data")
			assert_true(batch.material_override == null and batch.multimesh.mesh == WorldKit.mesh_for(type), String(batch.name) + ": kit mesh with its own material")
		else:
			assert_true(casts, String(batch.name) + ": cover casts shadows")
			assert_true(batch.multimesh.mesh is ArrayMesh and WorldSurface.is_lit(batch.material_override), String(batch.name) + ": kit mesh with the lit cover material")
			var palette := String(cover_types[type].get("palette", "citadel"))
			assert_true(batch.material_override == WorldSurface.palette_material(palette), String(batch.name) + ": its type's palette material (" + palette + ")")
	map.free()


func test_no_whole_map_batches_and_no_cover_meshes_under_nav() -> void:
	var map := _map()
	assert_true(map.get_node_or_null("ArtBuilder/Structures") == null, "no whole-map structure batches")
	assert_true(map.get_node_or_null("ArtBuilder/RingCover") == null, "no whole-map ring batches")
	var with_mesh: Array[String] = []
	for body in map.get_node("Nav").get_children():
		if body.get_node_or_null("Mesh") != null:
			with_mesh.append(String(body.name))
	with_mesh.sort()
	var expected: Array[String] = ["Ground"]
	for wall: String in SCENE_WALLS:
		expected.append(wall)
	expected.sort()
	assert_eq(with_mesh, expected, "only the ground and the scene-authored walls keep a Mesh child")
	map.free()


func test_decor_batches_on_alesia() -> void:
	var map := _map()
	var chunks := _chunks(map)
	var builder := map.get_node("ArtBuilder")
	var decor: Array = DataRegistry.new().load_file("res://data/maps/alesia_cover.json")["decor"]
	check_decor_totals(map, decor, "alesia")
	var kinds := {}
	for entry: Dictionary in decor:
		kinds[String(entry["kind"])] = true
	var rule := RegEx.create_from_string("^Batch_decor_(.+)_(\\d+)$")
	for batch: MultiMeshInstance3D in chunks.batches("decor"):
		var batch_name := String(batch.name)
		var found := rule.search(batch_name)
		assert_true(found != null and kinds.has(found.get_string(1)) and batch_name == "Batch_decor_" + String(batch.get_meta(&"type")), batch_name + ": Batch_decor_<kind>_<n>")
		assert_true(not batch_name.contains("."), batch_name + ": no '.' in the name")
		assert_true(batch.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and batch.material_override == null, batch_name + ": no shadow, no material_override")
	assert_eq(map.get_node("Decor").get_child_count(), 0, "the scene's Decor node stays empty")
	assert_true(not builder.decor_bodies.is_empty(), "nonvacuous solid decor")
	for body: StaticBody3D in builder.decor_bodies:
		var matches := 0
		for batch: MultiMeshInstance3D in chunks.batches("decor"):
			for xform: Transform3D in batch.get_meta(&"transforms"):
				if xform.is_equal_approx(body.transform):
					matches += 1
		assert_eq(matches, 1, String(body.name) + ": its transform is the transform of exactly one decor instance")
	map.free()
