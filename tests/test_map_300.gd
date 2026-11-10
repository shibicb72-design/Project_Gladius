extends "res://tests/test_case.gd"
## M2P1A: the TEST-ONLY 300 m performance map (data/maps/test_300.json, scenes/maps/test_300.tscn) and its
## generator (tools/gen_test_map.gd). One map is built at a time and freed before the next (static caches are
## keyed per map).

const _Gen := preload("res://tools/gen_test_map.gd")
const _MatchScene := preload("res://scenes/match/match.tscn")
const _Chunks := preload("res://tests/test_map_chunks.gd")
const MAP := "res://data/maps/test_300.json"
const ALESIA := "res://data/maps/alesia_section.json"
const COVER_TYPES := "res://data/maps/alesia_cover.json"
const TMP_DIR := "user://p1a_test_tmp/"
const NO_FILE := "user://p1a_test_tmp/does_not_exist.json"
const PAWN_GAP_M := 0.55  # pawn origin to the cover face, as in tests/test_cover_controller.gd (0.5 m)


func _def() -> Dictionary:
	return DataRegistry.parse_quiet(MAP)


func _gen() -> Dictionary:
	return _def()["generator"]


## The test map's scene names no map of its own (MatchRoot, or a loader like this one, sets ArtBuilder.map_json
## before add_child), so a missing hand-off shows up as alesia pieces.
func _build(scene_path: String) -> Node3D:
	var tree: SceneTree = Engine.get_main_loop()
	var map: Node3D = load(scene_path).instantiate()
	if scene_path.ends_with("test_300.tscn"):
		map.get_node("ArtBuilder").set("map_json", MAP)
	tree.root.add_child(map)
	return map


func _round_trip(data: Dictionary) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(data)))


func _cover_cfg() -> Dictionary:
	return DataRegistry.parse_quiet(COVER_TYPES)


## Spawn spots sorted by id on the ground plane, and their ids.
func _spots() -> Array:
	var spawns: Dictionary = _def()["spawns"]
	var ids: Array = spawns.keys()
	ids.sort()
	var spots: Array[Vector2] = []
	for id: String in ids:
		spots.append(Vector2(float(spawns[id][0]), float(spawns[id][2])))
	return [spots, ids]


func test_generator_is_deterministic_and_matches_the_files() -> void:
	var def := _def()
	assert_true(bool(def["_placeholder"]) and String(def["_note"]).contains("TEST-ONLY"), "the map says it is test-only")
	assert_true(bool(def["generator"]["_placeholder"]), "the generator numbers are placeholders")
	var a: Dictionary = _Gen.generate(def)
	var b: Dictionary = _Gen.generate(def)
	assert_eq(_round_trip(a), _round_trip(b), "two runs give the same pieces")
	assert_eq(_round_trip(a["cover"]), _round_trip(DataRegistry.parse_quiet(String(def["cover_data"]))), "the committed cover file is the generator's output")
	assert_eq(_round_trip(a["structures"]), _round_trip(DataRegistry.parse_quiet(String(def["structure_data"]))), "the committed structures file is the generator's output")
	for file: Dictionary in [a["cover"], a["structures"]]:
		assert_true(int(file["version"]) == 1 and bool(file["_placeholder"]) and String(file["_note"]).contains("gen_test_map"), "piece file header")
	var counts: Dictionary = _Gen.counts_of(a)
	var targets: Dictionary = _gen()["targets"]
	var tolerance := float(_gen()["tolerance"])
	assert_eq(tolerance, 0.15, "targets within 15 %")
	for key: String in targets:
		var want := float(targets[key])
		assert_true(absf(float(counts[key]) - want) <= want * tolerance, "%s count %d within 15 %% of %d" % [key, counts[key], want])
	var cover_types: Dictionary = _cover_cfg()["types"]
	var kit_types: Dictionary = WorldKit.config()["types"]
	var decor_kinds := {}
	for entry: Dictionary in _cover_cfg()["decor"]:
		decor_kinds[entry["kind"]] = true
	var ids := {}
	var lists := {"cover": a["cover"]["pieces"], "ring": a["cover"]["ring_pieces"], "decor": a["cover"]["decor"], "structures": a["structures"]["pieces"]}
	for list: String in lists:
		for entry: Dictionary in lists[list]:
			var id := String(entry["id"])
			assert_true(not ids.has(id), "unique id " + id)
			ids[id] = true
			match list:
				"cover", "ring":
					assert_true(cover_types.has(entry["type"]), id + ": an alesia cover type")
					if cover_types.has(entry["type"]):
						assert_eq(float(entry["at"][1]), float(cover_types[entry["type"]]["size"][1]) * 0.5, id + ": stands on the ground")
				"structures":
					assert_true(kit_types.has(entry["type"]), id + ": an alesia world kit type")
					assert_eq(float(entry["at"][1]), 0.0, id + ": on the ground")
					assert_true(is_zero_approx(fmod(float(entry["yaw"]), float(WorldKit.config()["rules"]["yaw_step_deg"]))), id + ": yaw in steps")
				"decor":
					assert_true(decor_kinds.has(entry["kind"]), id + ": an alesia decor kind")
	print("MAP_300_GEN counts=", counts)


func test_every_piece_on_the_ground_with_gaps_and_clearances() -> void:
	var map := _build("res://scenes/maps/test_300.tscn")
	var builder := map.get_node("ArtBuilder")
	var gen := _gen()
	var half := float(gen["ground_size_m"]) * 0.5
	var ground := Rect2(-half, -half, half * 2.0, half * 2.0)
	var gap_min := float(gen["minimum_gap_m"])
	var spot_data := _spots()
	var spots: Array[Vector2] = spot_data[0]
	var bodies: Array = []
	bodies.append_array(builder.cover_bodies)
	bodies.append_array(builder.ring_bodies)
	bodies.append_array(builder.structure_bodies)
	bodies.append_array(builder.decor_bodies)
	assert_true(bodies.size() > 500, "nonvacuous: %d bodies" % bodies.size())
	var rects: Array[Rect2] = []
	for body: StaticBody3D in bodies:
		var rect: Rect2 = WorldRing.footprint(body)["rect"]
		assert_true(ground.encloses(rect), String(body.name) + ": whole footprint on the ground " + str(rect))
		for s in spots.size():
			assert_true(WorldRing.rect_distance(spots[s], rect) + 0.00001 >= float(gen["spawn_clear_m"]), String(body.name) + " keeps clear of " + String(spot_data[1][s]))
			var lane := WorldRing.rect_segment_distance(rect, spots[s], spots[(s + 1) % spots.size()])
			assert_true(lane + 0.00001 >= float(gen["lane_clear_m"]), String(body.name) + " keeps clear of a lane (%.2f m)" % lane)
		rects.append(rect)
	# The generator keeps its minimum gap between every pair of footprints (cover, ring, structure, solid decor).
	var worst := INF
	for i in rects.size():
		for j in i:
			var gap := WorldRing.rect_gap(rects[i], rects[j])
			worst = minf(worst, gap)
			if gap + 0.00001 < gap_min:
				assert_true(false, "%s/%s keep the minimum gap (%.2f m)" % [bodies[i].name, bodies[j].name, gap])
	var decor_looks := 0
	for batch: MultiMeshInstance3D in (map.get_node("ArtBuilder/Chunks") as MapChunks).batches("decor"):
		for xform: Transform3D in batch.get_meta(&"transforms"):
			decor_looks += 1
			assert_true(ground.has_point(Vector2(xform.origin.x, xform.origin.z)), String(batch.name) + ": decor look on the ground " + str(xform.origin))
	assert_true(decor_looks > 0, "nonvacuous: decor looks")
	print("MAP_300_GAPS bodies=", bodies.size(), " smallest_gap_m=", worst)
	map.free()


func test_scene_layout_and_body_counts() -> void:
	var def := _def()
	var scene: Node = load(String(def["scene"])).instantiate()
	var markers := {}
	for c in scene.get_node("SquadSpawns").get_children():
		markers[str(c.name)] = c
	var spawns: Dictionary = def["spawns"]
	assert_eq(markers.size(), spawns.size(), "one marker per spawn")
	for id: String in spawns:
		var p: Array = spawns[id]
		assert_true(markers.has(id) and markers[id].position.distance_to(Vector3(p[0], p[1], p[2])) < 0.05, "marker and position of " + id)
	assert_eq(scene.get_node("ArtBuilder").get("map_json"), MatchRoot.MAP_PATH, "the scene names no map of its own: whoever loads it sets map_json (review B1)")
	var ground := scene.get_node("Nav/Ground") as StaticBody3D
	var mesh_size := ((ground.get_node("Mesh") as MeshInstance3D).mesh as BoxMesh).size
	var shape_size := ((ground.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
	assert_eq(mesh_size, Vector3(300, 1, 300), "ground mesh 300 x 1 x 300")
	assert_eq(shape_size, Vector3(300, 1, 300), "ground shape 300 x 1 x 300")
	assert_true(is_zero_approx(ground.position.y + shape_size.y * 0.5), "ground top at y = 0")
	assert_eq(scene.get_node("Nav").get_child_count(), 1, "no scene walls: Nav holds only the ground")
	scene.free()
	var map := _build(String(def["scene"]))
	var builder := map.get_node("ArtBuilder")
	var cover := DataRegistry.parse_quiet(String(def["cover_data"]))
	var structures := DataRegistry.parse_quiet(String(def["structure_data"]))
	assert_eq(builder.cover_bodies.size(), (cover["pieces"] as Array).size(), "one cover body per piece")
	assert_eq(builder.ring_bodies.size(), (cover["ring_pieces"] as Array).size(), "one ring body per piece")
	assert_eq(builder.structure_bodies.size(), (structures["pieces"] as Array).size(), "one structure body per piece")
	assert_eq((map.get_node("ArtBuilder/Chunks") as MapChunks).instance_total("decor"), (cover["decor"] as Array).size(), "one decor look per entry")
	assert_eq(map.get_node("Decor").get_child_count(), 0, "the scene's Decor node stays empty")
	var solid: Dictionary = _cover_cfg()["decor_colliders"]
	var solid_count := 0
	for entry: Dictionary in cover["decor"]:
		if solid.has(entry["kind"]):
			solid_count += 1
	assert_true(solid_count > 0, "nonvacuous solid decor")
	assert_eq(builder.decor_bodies.size(), solid_count, "one solid body per solid decor entry")
	assert_eq(float(builder.ground_size_m), 300.0, "builder reads the 300 m ground")
	map.free()


func test_chunks_on_test_300() -> void:
	var map := _build("res://scenes/maps/test_300.tscn")
	var chunks := map.get_node("ArtBuilder/Chunks") as MapChunks
	var builder := map.get_node("ArtBuilder")
	var size := float(MapChunks.config()["chunk_size_m"])
	var ground_size := (map.get_node("Nav/Ground/Mesh") as MeshInstance3D).get_aabb().size.x
	assert_eq(chunks.per_side, ceili(ground_size / size), "chunks per side from the data")
	if is_equal_approx(size, 50.0):
		assert_eq(chunks.per_side, 6, "300 m in 50 m chunks")
	var def := _def()
	var cover := DataRegistry.parse_quiet(String(def["cover_data"]))
	var pieces := {"cover": cover["pieces"], "ring": cover["ring_pieces"], "structure": WorldKit.pieces_for(def)}
	for source: String in pieces:
		var per_type := {}
		for entry: Dictionary in pieces[source]:
			per_type[entry["type"]] = int(per_type.get(entry["type"], 0)) + 1
		for type: String in per_type:
			assert_eq(chunks.instance_total(source, type), int(per_type[type]), source + " " + type + ": one instance per piece")
		assert_eq(chunks.instance_total(source), (pieces[source] as Array).size(), source + ": no stray type")
	var batch_count := 0
	var instances := 0
	for chunk: Node3D in chunks.get_children():
		var index: Vector2i = chunk.get_meta(&"index")
		for batch: MultiMeshInstance3D in chunk.get_children():
			for xform: Transform3D in batch.get_meta(&"transforms"):
				assert_eq(MapChunks.index_for(xform.origin.x, xform.origin.z, chunks.half_m, chunks.chunk_size_m, chunks.per_side), index, String(batch.name) + ": instance in its chunk")
			batch_count += 1
			instances += batch.multimesh.instance_count
	# Decor: one instance per entry, totals per kind and size by the name rule (tests/test_map_chunks.gd).
	var decor: Array = cover["decor"]
	var decor_expected: Dictionary = _Chunks.decor_expected(decor)
	var decor_counts: Dictionary = decor_expected["counts"]
	assert_true(not decor_counts.is_empty(), "nonvacuous decor")
	for type: String in decor_counts:
		assert_eq(chunks.instance_total("decor", type), int(decor_counts[type]), "decor " + type + ": one instance per entry of that kind and size")
	assert_eq(chunks.instance_total("decor"), decor.size(), "decor: no stray type")
	assert_eq(builder.decor_types, decor_expected["types"], "decor_types follows the name rule")
	var expected: int = builder.cover_bodies.size() + builder.ring_bodies.size() + builder.structure_bodies.size() + decor.size()
	assert_eq(instances, expected, "every cover, ring and structure body and every decor entry drawn once")
	print("MAP_CHUNKS map=test_300 chunk_size_m=", chunks.chunk_size_m, " per_side=", chunks.per_side, " chunks=", chunks.get_child_count(), " batches=", batch_count, " instances=", instances)
	map.free()


## True when nothing but the ground (and `pawn`) touches a pawn-sized box standing at `at` (y = 0).
func _free_ground(map: Node3D, pawn: Pawn, at: Vector3) -> bool:
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 1.6, 0.8)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(Basis.IDENTITY, at + Vector3(0, 0.9, 0))
	query.collision_mask = 1
	var ground := map.get_node("Nav/Ground") as CollisionObject3D
	query.exclude = [ground.get_rid(), pawn.get_rid()]
	return map.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


## Places `pawn` PAWN_GAP_M in front of one long face of a box body, facing it. Returns false if neither long
## face has free ground in front.
func _stand_at_face(map: Node3D, pawn: Pawn, body: StaticBody3D) -> bool:
	var size := ((body.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
	var normals := [Vector3.BACK, Vector3.FORWARD] if size.x >= size.z else [Vector3.RIGHT, Vector3.LEFT]
	var half_short := minf(size.x, size.z) * 0.5
	for normal: Vector3 in normals:
		var at := Vector3(body.position.x, 0.0, body.position.z) + normal * (half_short + PAWN_GAP_M)
		if _free_ground(map, pawn, at):
			pawn.global_transform = Transform3D(Basis.looking_at(-normal), at)
			return true
	return false


func test_cover_contract_and_probe_on_real_pieces() -> void:
	var tree: SceneTree = Engine.get_main_loop()
	var map := _build("res://scenes/maps/test_300.tscn")
	var builder := map.get_node("ArtBuilder")
	var walls := 0
	for node in tree.get_nodes_in_group(&"cover_wall"):
		if not map.is_ancestor_of(node):
			continue
		walls += 1
		assert_true(node is StaticBody3D, String(node.name) + ": a body")
		var shape := node.get_node_or_null("Shape") as CollisionShape3D
		assert_true(shape != null and shape.shape is BoxShape3D, String(node.name) + ": a Shape holding a box")
		assert_true((node as CollisionObject3D).get_collision_layer_value(1), String(node.name) + ": on collision layer 1")
	assert_eq(walls, builder.cover_bodies.size() + builder.ring_bodies.size(), "every cover and ring body is a cover wall (all alesia cover types are coverable)")
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	pawn.position = Vector3(0, 0, -149)
	map.add_child(pawn)
	pawn.set_physics_process(false)
	await tree.physics_frame
	await tree.physics_frame
	var cfg := DataRegistry.new().load_file("res://data/cover.json")
	var probe := CoverProbe.new()
	# Candidates in build order: the first coverable bodies with a pawn-sized box of free ground in front of a
	# long face (a shape query); every candidate that passes must give a probe hit on that very body.
	for list: String in ["cover_bodies", "ring_bodies"]:
		var hits := 0
		for body: StaticBody3D in builder.get(list):
			if hits >= 3:
				break
			if not body.is_in_group(&"cover_wall") or not _stand_at_face(map, pawn, body):
				continue
			await tree.physics_frame
			await tree.physics_frame
			var result := probe.sample(pawn, cfg, false)
			assert_true(bool(result["hit"]) and int(result.get("wall_key", 0)) == body.get_instance_id(), "%s: the probe finds %s (%s)" % [list, body.name, body.get_meta(&"cover_palette", "")])
			print("MAP_300_COVER_PROBE ", list, " ", body.name, " hit=", result["hit"])
			hits += 1
		assert_eq(hits, 3, list + ": three real pieces probed")
	# A world kit structure, approached the same way: the ray reaches its collider, but it is not cover.
	var structure_checked := false
	for body: StaticBody3D in builder.structure_bodies:
		if structure_checked:
			break
		assert_true(body.is_in_group(&"structure") and not body.is_in_group(&"cover_wall"), String(body.name) + ": a structure, not cover")
		var rect: Rect2 = WorldRing.footprint(body)["rect"]
		var centre := rect.get_center()
		for side: Vector3 in [Vector3.BACK, Vector3.FORWARD, Vector3.RIGHT, Vector3.LEFT]:
			var reach := absf(side.x) * rect.size.x * 0.5 + absf(side.z) * rect.size.y * 0.5
			var at := Vector3(centre.x, 0.0, centre.y) + side * (reach + PAWN_GAP_M)
			if not _free_ground(map, pawn, at):
				continue
			pawn.global_transform = Transform3D(Basis.looking_at(-side), at)
			await tree.physics_frame
			await tree.physics_frame
			var from := at + Vector3.UP * float(cfg["probe_height_m"])
			var ray := PhysicsRayQueryParameters3D.create(from, from - side * float(cfg["probe_m"]), 1, [pawn.get_rid()])
			var hit := map.get_world_3d().direct_space_state.intersect_ray(ray)
			if hit.is_empty() or hit["collider"] != body:
				continue
			assert_true(not probe.sample(pawn, cfg, false)["hit"], String(body.name) + ": the probe does not snap to a structure")
			print("MAP_300_COVER_PROBE structure ", body.name, " (", body.get_meta(&"structure_type"), ") hit=false")
			structure_checked = true
			break
	assert_true(structure_checked, "one structure approached with its collider in reach")
	pawn.free()
	map.free()


func _write(name: String, text: String) -> String:
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var path := TMP_DIR + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path


func _clean() -> void:
	for file in DirAccess.get_files_at(TMP_DIR):
		DirAccess.remove_absolute(TMP_DIR + file)
	DirAccess.remove_absolute(TMP_DIR)


func test_map_selection_with_a_second_map() -> void:
	var select := _write("select.json", JSON.stringify({"map": ALESIA}))
	var override := _write("override", MAP + "\n")
	var chosen := MatchRoot.select_map(select, override)
	assert_eq(chosen["path"], MAP, "the override picks the test map over alesia")
	assert_eq(chosen["error"], "", "override is clean")
	var direct := MatchRoot.select_map(_write("select_test.json", JSON.stringify({"map": MAP})), NO_FILE)
	assert_eq(direct["path"], MAP, "a select json naming the test map")
	assert_eq(direct["error"], "", "select is clean")
	var reg := DataRegistry.new()
	assert_eq(reg.validate_map(MAP).size(), 0, "test map is clean: " + ", ".join(reg.validate_map(MAP)))
	assert_eq(reg.validate().size(), 0, "validate is clean: " + ", ".join(reg.validate()))
	var no_decor := _write("no_decor.json", JSON.stringify({"pieces": []}))
	var bad := _def().duplicate(true)
	bad["cover_data"] = no_decor
	assert_true(DataRegistry.validate_map_def(bad).size() > 0, "a cover file without decor is reported")
	var bad_kit := _def().duplicate(true)
	bad_kit["structure_data"] = _write("no_pieces.json", JSON.stringify({"version": 1}))
	assert_true(DataRegistry.validate_map_def(bad_kit).size() > 0, "a structures file without pieces is reported")
	_clean()


## {size, material, image} of one map scene's ground, read after the build.
func _ground_of(scene_path: String) -> Dictionary:
	var map := _build(scene_path)
	var builder := map.get_node("ArtBuilder")
	var material := (map.get_node("Nav/Ground/Mesh") as MeshInstance3D).material_override as ShaderMaterial
	var out := {"size": float(material.get_shader_parameter("map_size_m")), "builder_size": float(builder.ground_size_m), "material": material, "image": builder.ground_paint}
	map.free()
	return out


func test_two_maps_in_one_process() -> void:
	var first := _ground_of("res://scenes/maps/alesia_section.tscn")
	assert_eq(first["size"], 160.0, "alesia ground material size")
	assert_eq(first["builder_size"], 160.0, "alesia builder ground size")
	var test := _ground_of("res://scenes/maps/test_300.tscn")
	assert_eq(test["size"], 300.0, "test map ground material size")
	assert_eq(test["builder_size"], 300.0, "test map builder ground size")
	assert_true(test["material"] != first["material"], "a ground material per map")
	assert_true(test["image"] != null and test["image"] != first["image"], "a ground paint per map")
	var again := _ground_of("res://scenes/maps/alesia_section.tscn")
	assert_eq(again["size"], 160.0, "alesia keeps 160 after the test map")
	assert_eq(again["builder_size"], 160.0, "alesia builder keeps 160")


func test_short_bot_match_on_test_300() -> void:
	var started_ms := Time.get_ticks_msec()
	var tree: SceneTree = Engine.get_main_loop()
	var m: MatchRoot = _MatchScene.instantiate()
	m.auto_start = false
	m.bake_navmesh = true
	m.fill_bots = true
	m.map_path_override = MAP
	tree.root.add_child(m)
	await tree.physics_frame
	m.director.load_config()
	var result := {}
	m.director.match_over.connect(func(r: Dictionary) -> void: result = r)
	var bake_from := Time.get_ticks_msec()
	assert_true(m.begin(), "begin succeeds on the test map")
	var bake_ms := Time.get_ticks_msec() - bake_from
	assert_eq(m.map_path, MAP, "the match loaded the test map")
	# Review B1: MatchRoot hands its map to ArtBuilder (match_root.gd:144-145). The scene names no map, so without the
	# hand-off the builder would build alesia's 75 cover pieces on the 300 m ground.
	assert_eq(m.map.get_node("ArtBuilder").get("map_json"), MAP, "MatchRoot handed the test map to ArtBuilder")
	var cover_pieces: int = (DataRegistry.new().load_file(String(_def()["cover_data"]))["pieces"] as Array).size()
	var cover_bodies := 0
	for node in tree.get_nodes_in_group(&"cover_wall"):
		if m.map.is_ancestor_of(node) and not node.is_in_group(&"ring_cover"):
			cover_bodies += 1
	assert_true(cover_bodies >= cover_pieces, "the test map's own cover was built (%d bodies, %d pieces)" % [cover_bodies, cover_pieces])
	var players := m.director.all_players().size()
	assert_eq(players, int(m.director.match_cfg["max_players"]), "a full lobby with bots")
	var frames := 240
	for i in frames:
		await tree.physics_frame
	assert_true(m.director.running or not result.is_empty(), "the match is still running or has a result")
	var wall_ms := Time.get_ticks_msec() - started_ms
	assert_true(wall_ms < 60000, "the short match takes under 60 s (%d ms)" % wall_ms)
	print("MAP_300_MATCH players=", players, " frames=", frames, " wall_ms=", wall_ms, " bake_ms=", bake_ms)
	m.queue_free()
	await tree.process_frame
