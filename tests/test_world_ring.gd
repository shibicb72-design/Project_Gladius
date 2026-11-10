extends "res://tests/test_case.gd"
## W3: the outer ring's landmarks (data/maps/alesia_landmarks.json). Four named places, each with something
## tall and cover around it; every landmark reachable from every other on the baked navmesh; no long stretch
## without cover on the routes between them. The ring's band, gap and overlap rules: tests/test_world_dense.gd.
const LANDMARKS := "res://data/maps/alesia_landmarks.json"


func _tree() -> SceneTree:
	return Engine.get_main_loop()


func _cfg() -> Dictionary:
	return DataRegistry.new().load_file(LANDMARKS)


func _map() -> Node3D:
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	_tree().root.add_child(map)
	return map


func _flat(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


func test_landmark_names_and_positions_live_once_in_placeholder_data() -> void:
	var cfg := _cfg()
	assert_true(bool(cfg["_placeholder"]) and String(cfg["_todo"]).contains("OQ-3D-LANDMARKS") and String(cfg["_todo"]).contains("OQ-WORLD-DENSE"), "landmark data is placeholder data with its OQ ids")
	var landmarks: Array = cfg["landmarks"]
	assert_eq(landmarks.size(), 4, "four landmarks")
	var ring: Dictionary = DataRegistry.new().load_file("res://data/maps/alesia_cover.json")["ring_rules"]
	var ids := {}
	var names := {}
	for landmark: Dictionary in landmarks:
		ids[landmark["id"]] = true
		names[landmark["name"]] = true
		assert_true(String(landmark["id"]) != "" and String(landmark["name"]) != "", "id and name set")
		var at := _flat(landmark["at"])
		assert_true(at.length() >= float(ring["min_radius_m"]) and at.length() <= float(ring["max_radius_m"]), "%s lies in the ring band (r %.1f)" % [landmark["id"], at.length()])
		var anchor := LowpolyKit.vec(landmark["anchor"])
		assert_true(Vector2(anchor.x, anchor.z).distance_to(at) <= float(landmark["radius_m"]), String(landmark["id"]) + ": anchor inside the place")
		for other: Dictionary in landmarks:
			if other != landmark:
				assert_true(at.distance_to(_flat(other["at"])) >= float(landmark["radius_m"]) + float(other["radius_m"]), "%s and %s do not share ground" % [landmark["id"], other["id"]])
	assert_true(ids.size() == 4 and names.size() == 4, "ids and names are unique")
	# The map names its landmark file; the loot clusters name landmarks by id and hold no coordinates.
	var map_def: Dictionary = DataRegistry.new().load_file(DataRegistry.MAP_PATH)
	assert_eq(String(map_def.get("landmarks", "")), LANDMARKS, "the map definition points at the landmark file")
	var clusters: Array = DataRegistry.new().load_file("res://data/loot.json")["clusters"]
	assert_true(not clusters.is_empty(), "loot clusters exist")
	for cluster: Dictionary in clusters:
		assert_true(ids.has(cluster["landmark"]), "loot cluster names a known landmark: " + String(cluster["landmark"]))
		for key: String in cluster:
			assert_true(key in ["landmark", "items"], "a loot cluster holds a landmark id and a count, no position (found key %s)" % key)


func test_every_landmark_is_a_place_with_height_structures_and_cover() -> void:
	var map := _map()
	await _tree().physics_frame
	await _tree().physics_frame
	var cfg := _cfg()
	var rules: Dictionary = cfg["rules"]
	var solids := WorldRing.solids(map)
	var space := map.get_world_3d().direct_space_state
	for landmark: Dictionary in cfg["landmarks"]:
		var at := _flat(landmark["at"])
		var radius := float(landmark["radius_m"])
		var tall := 0
		var structures := 0
		var cover := 0
		for solid in solids:
			if WorldRing.rect_distance(at, solid["rect"]) > radius:
				continue
			var body: StaticBody3D = solid["body"]
			if body.has_meta(&"structure_type"):
				structures += 1
				if float(solid["top"]) + 0.00001 >= float(rules["tall_height_m"]):
					tall += 1
			elif body.is_in_group(&"cover_wall"):
				cover += 1
		assert_true(tall >= int(rules["tall_minimum"]), "%s: something at least %s m tall to steer by (%d)" % [landmark["id"], rules["tall_height_m"], tall])
		assert_true(structures >= int(rules["structures_minimum"]), "%s: at least %s structures (%d)" % [landmark["id"], rules["structures_minimum"], structures])
		assert_true(cover >= int(rules["cover_minimum"]), "%s: at least %s cover pieces (%d)" % [landmark["id"], rules["cover_minimum"], cover])
		# The anchor is open ground: a ray from above lands on the ground body.
		var anchor := LowpolyKit.vec(landmark["anchor"])
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(anchor + Vector3.UP * 40.0, anchor - Vector3.UP * 2.0, Hitscan.MASK_WORLD))
		assert_true(not hit.is_empty() and hit["collider"] == map.get_node("Nav/Ground"), String(landmark["id"]) + ": anchor is open ground under open sky")
		print("WORLD_LANDMARK ", landmark["id"], " \"", landmark["name"], "\" tall=", tall, " structures=", structures, " cover=", cover)
	map.free()


func test_every_landmark_is_reachable_from_every_other_and_the_routes_have_cover() -> void:
	var map := _map()
	var nav := map.get_node("Nav") as NavigationRegion3D
	nav.bake_navigation_mesh(false)
	var cfg := _cfg()
	var rules: Dictionary = cfg["rules"]
	var landmarks: Array = cfg["landmarks"]
	var probe := LowpolyKit.vec(landmarks[0]["anchor"])
	# Baking is synchronous; the server publishes the region in a later iteration (as tests/test_astra_map.gd waits).
	for frame in 120:
		await _tree().physics_frame
		if NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0 \
				and NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), probe) == nav.get_rid():
			break
	assert_eq(NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), probe), nav.get_rid(), "baked region published")
	var rects := WorldRing.cover_rects(map, float(rules["cover_min_height_m"]))
	var step := float(rules["route_sample_step_m"])
	var reach := float(rules["cover_reach_m"])
	var limit := float(rules["max_open_stretch_m"])
	var none: Array[Rect2] = []
	var routes := 0
	var worst := 0.0
	var bare_worst := 0.0
	for i in landmarks.size():
		for j in i:
			var from := LowpolyKit.vec(landmarks[j]["anchor"])
			var to := LowpolyKit.vec(landmarks[i]["anchor"])
			var label := "%s -> %s" % [landmarks[j]["id"], landmarks[i]["id"]]
			var path := NavigationServer3D.map_get_path(nav.get_navigation_map(), from, to, true)
			assert_true(not path.is_empty(), label + ": nonempty baked path")
			var miss := INF if path.is_empty() else path[path.size() - 1].distance_to(to)
			assert_true(miss <= float(rules["anchor_reach_m"]), "%s: the path ends within %s m of the landmark (%.2f)" % [label, rules["anchor_reach_m"], miss])
			var points := WorldRing.resample(path, step)
			var longest := WorldRing.longest(WorldRing.open_stretches(points, rects, reach, step))
			assert_true(longest <= limit, "%s: longest stretch with no cover within %s m is %.1f m (limit %s)" % [label, reach, longest, limit])
			worst = maxf(worst, longest)
			bare_worst = maxf(bare_worst, WorldRing.longest(WorldRing.open_stretches(points, none, reach, step)))
			routes += 1
			print("WORLD_ROUTE ", label, " length_m=", points.size() * step, " end_miss_m=", snappedf(miss, 0.01), " longest_open_m=", longest)
	assert_eq(routes, 6, "every pair of the four landmarks")
	assert_true(bare_worst > limit, "nonvacuous: with no cover counted the same routes break the limit (%.1f m)" % bare_worst)
	print("WORLD_ROUTES routes=", routes, " longest_open_m=", worst, " limit_m=", limit, " cover_within_m=", reach)
	map.free()
