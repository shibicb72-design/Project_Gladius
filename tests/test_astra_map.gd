extends "res://tests/test_case.gd"

const BASELINE := {
	"Ground": [[160, 1, 160], [0, -0.5, 0]],
	"CitadelWallN": [[12, 4, 1], [0, 2, -14]],
	"CitadelWallS": [[12, 4, 1], [0, 2, 14]],
	"CitadelWallE": [[1, 4, 12], [14, 2, 0]],
	"CitadelWallW": [[1, 4, 12], [-14, 2, 0]],
	"InnerWall": [[30, 5, 2], [0, 2.5, -26]],
	"CampBlockA": [[6, 3, 6], [30, 1.5, 15]],
	"CampBlockB": [[6, 3, 6], [-30, 1.5, -12]],
	"CampBlockC": [[6, 3, 6], [10, 1.5, 45]]
}

func _tree() -> SceneTree:
	return Engine.get_main_loop()

func _map() -> Node3D:
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	return map

func test_cover_footprints_colliders_and_literal_baseline() -> void:
	var map := _map()
	var nav := map.get_node("Nav")
	var cfg := DataRegistry.new().load_file("res://data/maps/alesia_cover.json")
	var rules: Dictionary = cfg["rules"]
	var bodies: Array = map.get_node("ArtBuilder").cover_bodies
	assert_true(bodies.size() >= int(rules["minimum_count"]), "at least 24 cover pieces")
	assert_eq(bodies.size(), cfg["pieces"].size(), "JSON cover mirror")
	for key: String in BASELINE:
		var body := nav.get_node(key) as StaticBody3D
		assert_eq(body.transform, Transform3D(Basis.IDENTITY, LowpolyKit.vec(BASELINE[key][1])), key + " transform locked")
		assert_eq((body.get_node("Shape").shape as BoxShape3D).size, LowpolyKit.vec(BASELINE[key][0]), key + " shape locked")
	var min_r := INF
	var max_r := 0.0
	var cache := {}
	for i in bodies.size():
		var body: StaticBody3D = bodies[i]
		var entry: Dictionary = cfg["pieces"][i]
		assert_eq(String(body.name), entry["id"], "cover id")
		assert_eq(body.position, LowpolyKit.vec(entry["at"]), "cover position mirror")
		assert_eq(body.collision_layer, 1, "world collision only")
		var size := (body.get_node("Shape").shape as BoxShape3D).size
		assert_eq(size, LowpolyKit.vec(cfg["types"][entry["type"]]["size"]), "collider size mirror")
		var near := Vector2(maxf(absf(body.position.x) - size.x * 0.5, 0), maxf(absf(body.position.z) - size.z * 0.5, 0)).length()
		var far := Vector2(absf(body.position.x) + size.x * 0.5, absf(body.position.z) + size.z * 0.5).length()
		min_r = minf(min_r, near)
		max_r = maxf(max_r, far)
		assert_true(near >= float(rules["min_radius_m"]) and far <= float(rules["max_radius_m"]), "entire footprint in band")
		if near < float(rules["hill_radius_m"]):
			assert_true(body.position.y + size.y * 0.5 <= float(rules["hill_max_height_m"]), "hill cover low")
		var bounds := AABB(body.position - size * 0.5, size)
		for key: String in BASELINE:
			if key == "Ground":
				continue
			var old_size := LowpolyKit.vec(BASELINE[key][0])
			assert_true(not bounds.intersects(AABB(LowpolyKit.vec(BASELINE[key][1]) - old_size * 0.5, old_size)), "no overlap with " + key)
		var mesh: Mesh = body.get_node("Mesh").mesh
		assert_true(mesh is ArrayMesh and mesh.get_surface_count() > 0, "real kit mesh")
		if cache.has(entry["type"]):
			assert_true(mesh == cache[entry["type"]], "repeated cover shares mesh")
		cache[entry["type"]] = mesh
	for node in map.get_node("Decor").get_children():
		assert_true(node is MeshInstance3D and node.get_child_count() == 0, "decor collider free")
	print("ASTRA_COVER count=", bodies.size(), " footprint_radius_min=", min_r, " max=", max_r)
	map.free()

func test_spawn_lanes_and_baked_paths() -> void:
	var map := _map()
	var nav := map.get_node("Nav") as NavigationRegion3D
	nav.bake_navigation_mesh(false)
	await _tree().physics_frame
	await _tree().physics_frame
	await _tree().process_frame
	# Baking is synchronous; the server publishes the region in a subsequent async iteration.
	# Wait for this region (not merely the world's initial empty iteration), bounded for CI.
	for frame in 120:
		if NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), Vector3(40, 0.1, 0)) == nav.get_rid():
			break
		await _tree().physics_frame
	assert_eq(NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), Vector3(40, 0.1, 0)), nav.get_rid(), "baked region published")
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	_tree().root.add_child(pawn)
	pawn.set_physics_process(false)
	var expected := ["spot_5", "spot_2", "spot_3", "spot_2", "spot_5", "spot_0"]
	var results := {}
	var paths := {}
	for i in 6:
		var id := "spot_%d" % i
		var spot := map.get_node("SquadSpawns/" + id) as Marker3D
		pawn.global_position = spot.global_position
		await _tree().physics_frame
		var lane := SpawnLane.neighbour_lane(pawn, 35.0)
		assert_true(lane["ok"], id + " usable neighbour lane")
		assert_eq(lane.get("spot_id", ""), expected[i], id + " baseline neighbour unchanged")
		results[id] = lane.get("spot_id", "")
		var path := NavigationServer3D.map_get_path(nav.get_navigation_map(), spot.global_position, Vector3.ZERO, true)
		assert_true(not path.is_empty(), id + " nonempty baked path")
		var distance := INF if path.is_empty() else path[path.size() - 1].distance_to(Vector3.ZERO)
		assert_true(distance <= 8.0, id + " path reaches hill")
		paths[id] = distance
	print("ASTRA_LANES ", results, " NAV_DISTANCE ", paths)
	pawn.free()
	map.free()

func test_kit_families_nonempty_and_deterministic() -> void:
	for kind in ["box", "low_wall", "sandbags", "crate", "camp", "barrier", "pillar", "arch", "rubble", "rock"]:
		var mesh := LowpolyKit.build(kind, Vector3(2, 1, 1))
		assert_true(mesh is ArrayMesh and mesh.surface_get_array_len(0) > 0, kind + " vertices")
		assert_eq(mesh.surface_get_arrays(0), LowpolyKit.build(kind, Vector3(2, 1, 1)).surface_get_arrays(0), kind + " deterministic")
