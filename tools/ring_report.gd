extends SceneTree
## W3 layout aid: bakes the map as MatchRoot.begin does, walks the navmesh route between every pair of
## landmarks (data/maps/alesia_landmarks.json) and prints where a route runs with no cover near it. The same
## numbers tests/test_world_ring.gd asserts.
## godot --headless --path . --script res://tools/ring_report.gd


func _initialize() -> void:
	await process_frame
	var map: Node3D = load("res://scenes/maps/alesia_section.tscn").instantiate()
	root.add_child(map)
	var nav := map.get_node("Nav") as NavigationRegion3D
	nav.bake_navigation_mesh(false)
	var cfg: Dictionary = DataRegistry.new().load_file("res://data/maps/alesia_landmarks.json")
	var rules: Dictionary = cfg["rules"]
	var landmarks: Array = cfg["landmarks"]
	var probe := LowpolyKit.vec(landmarks[0]["anchor"])
	for frame in 240:
		await physics_frame
		if NavigationServer3D.map_get_iteration_id(nav.get_navigation_map()) > 0 \
				and NavigationServer3D.map_get_closest_point_owner(nav.get_navigation_map(), probe) == nav.get_rid():
			break
	if OS.get_cmdline_user_args().has("--solids"):
		for solid in WorldRing.solids(map):
			var rect: Rect2 = solid["rect"]
			var radial := WorldRing.radial_range(rect)
			if radial.y >= 33.0:
				print("RING_SOLID %s x %.1f..%.1f z %.1f..%.1f top %.1f r %.1f..%.1f" % [solid["name"], rect.position.x, rect.end.x, rect.position.y, rect.end.y, solid["top"], radial.x, radial.y])
	var rects := WorldRing.cover_rects(map, float(rules["cover_min_height_m"]))
	var step := float(rules["route_sample_step_m"])
	var reach := float(rules["cover_reach_m"])
	var worst := 0.0
	for i in landmarks.size():
		for j in i:
			var from := LowpolyKit.vec(landmarks[j]["anchor"])
			var to := LowpolyKit.vec(landmarks[i]["anchor"])
			var path := NavigationServer3D.map_get_path(nav.get_navigation_map(), from, to, true)
			var miss := INF if path.is_empty() else path[path.size() - 1].distance_to(to)
			var points := WorldRing.resample(path, step)
			var stretches := WorldRing.open_stretches(points, rects, reach, step)
			worst = maxf(worst, WorldRing.longest(stretches))
			print("RING_ROUTE %s -> %s length_m=%d end_miss_m=%.2f longest_open_m=%.1f" % [landmarks[j]["id"], landmarks[i]["id"], points.size() * step, miss, WorldRing.longest(stretches)])
			var corners := PackedStringArray()
			for p in path:
				corners.append("(%.1f, %.1f)" % [p.x, p.z])
			print("  path ", " ".join(corners))
			for stretch in stretches:
				if float(stretch["length"]) >= 4.0:
					print("  open %.0f m from (%.1f, %.1f) to (%.1f, %.1f)" % [stretch["length"], stretch["from"].x, stretch["from"].y, stretch["to"].x, stretch["to"].y])
	print("RING_ROUTES longest_open_m=%.1f limit_m=%s cover_within_m=%s solids=%d" % [worst, rules["max_open_stretch_m"], reach, rects.size()])
	map.free()
	quit(0)
